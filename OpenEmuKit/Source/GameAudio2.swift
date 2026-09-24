// Copyright (c) 2022, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the OpenEmu Team nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import Foundation
import AVFoundation
@_implementationOnly import Atomics
internal import os
import OpenEmuBase.OEGameCore
import OpenEmuBase.OERingBuffer

@available(macOS 11.0, iOS 14.0, *)
private var log = Logger(subsystem: "org.openemu.OpenEmuKit", category: "GameAudio2")

@available(macOS 11.0, iOS 14.0, *)
final public class GameAudio2: GameAudioProtocol {
    public var volume: Float {
        didSet {
            engine.mainMixerNode.outputVolume = volume
        }
    }
    
    private let engine = AVAudioEngine()
    private var src: AVAudioSourceNode?
    /// Converts the core's samples to float so `varispeed` can take them.
    private let converter = AVAudioMixerNode()
    /// Plays slightly faster or slower to keep the core's buffer near a small target fill.
    private let varispeed = AVAudioUnitVarispeed()
    private var rateTimer: DispatchSourceTimer?
    /// Bytes the output asked for in its latest render (written on the audio thread).
    private let lastRequestBytes = ManagedAtomic<Int>(0)
    private var smoothedFill = 0.0
    private weak var gameCore: OEGameCore!
    private var isDefaultOutputDevice = true
    private var isRunning = false
    
    public init(withCore gameCore: OEGameCore) {
        self.gameCore = gameCore
        volume = 1.0
        engine.attach(converter)
        engine.attach(varispeed)
    }
    
    deinit {
        stopMonitoringEngineConfiguration()
        rateTimer?.cancel()
    }
    
    @objc public func audioSampleRateDidChange() {
        // Before startAudio there is nothing to update; it reads the current rate itself.
        guard src != nil else { return }

        // Rebuild at the new rate even while audio isn't running yet. Cores often change rate
        // right after starting (N64 games set their DAC rate while booting), which can land in
        // the 20 ms between startAudio and its delayed resume. Ignoring it left playback at the
        // old rate, pulling samples faster than the core produced them: constant underflow,
        // heard as crackling. A pending resume starts the rebuilt engine.
        let wasRunning = isRunning
        engine.stop()
        updateSourceNode()
        connectNodes()
        engine.prepare()
        if wasRunning {
            performResumeAudio()
        }
        startRateControl()
    }
    
    public func startAudio() {
        precondition(gameCore.audioBufferCount == 1,
                     "nly one buffer supported; got \(gameCore.audioBufferCount)")
        
        updateSourceNode()
        connectNodes()
        setOutputDeviceID(outputDeviceID)
        
        engine.prepare()
        // per the following, we need to wait before resuming to allow devices to start 🤦🏻‍♂️
        //  https://github.com/AudioKit/AudioKit/blob/f2a404ff6cf7492b93759d2cd954c8a5387c8b75/Examples/macOS/OutputSplitter/OutputSplitter/Audio/Output.swift#L88-L95
        performResumeAudio()
        startMonitoringEngineConfiguration()
        startRateControl()
    }
    
    public func stopAudio() {
        stopRateControl()
        engine.stop()
        destroyNodes()
        isRunning = true
    }
    
    public func pauseAudio() {
        engine.pause()
        isRunning = false
    }
    
    private func performResumeAudio() {
        DispatchQueue.main
            .asyncAfter(deadline: .now() + 0.020) {
                self.resumeAudio()
            }
    }
    
    public func resumeAudio() {
        isRunning = true
        do {
            try engine.start()
        } catch {
            log.error("Unable to start AVAudioEngine: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    private func readBlockForBuffer(_ buffer: OEAudioBuffer) -> OEAudioBufferReadBlock {
        if buffer.responds(to: #selector(OEAudioBuffer.readBlock)) {
            return buffer.readBlock!()
        }
        return { buf, max -> UInt in
            buffer.read(buf, maxLength: max)
        }
    }
    
    private var streamDescription: AudioStreamBasicDescription {
        let channelCount    = UInt32(gameCore.channelCount(forBuffer: 0))
        let bytesPerSample  = UInt32(gameCore.audioBitDepth / 8)
        
        let formatFlags: AudioFormatFlags = bytesPerSample == 4
            // assume 32-bit float
            ? kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked
            : kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian
        
        return AudioStreamBasicDescription(mSampleRate: gameCore.audioSampleRate(forBuffer: 0),
                                           mFormatID: kAudioFormatLinearPCM,
                                           mFormatFlags: formatFlags,
                                           mBytesPerPacket: bytesPerSample * channelCount,
                                           mFramesPerPacket: 1,
                                           mBytesPerFrame: bytesPerSample * channelCount,
                                           mChannelsPerFrame: channelCount,
                                           mBitsPerChannel: 8 * bytesPerSample,
                                           mReserved: 0)
    }
    
    private var renderFormat: AVAudioFormat {
        var desc = streamDescription
        return AVAudioFormat(streamDescription: &desc)!
        
    }
    
    // MARK: - Helpers
    
    private func updateSourceNode() {
        if let src {
            engine.detach(src)
            self.src = nil
        }
        
        let read = readBlockForBuffer(gameCore.audioBuffer(at: 0))
        let sd   = streamDescription
        let bytesPerFrame = sd.mBytesPerFrame
        let channelCount  = sd.mChannelsPerFrame
        let lastRequestBytes = lastRequestBytes
        
        src = AVAudioSourceNode(format: renderFormat) { _, _, frameCount, inputData in
            let bytesRequested = UInt(frameCount * bytesPerFrame)
            lastRequestBytes.store(Int(bytesRequested), ordering: .relaxed)
            let bytesCopied    = read(inputData.pointee.mBuffers.mData, bytesRequested)
            
            inputData.pointee.mBuffers.mDataByteSize    = UInt32(bytesCopied)
            inputData.pointee.mBuffers.mNumberChannels  = channelCount
            
            return noErr
        }
        
        if let src {
            engine.attach(src)
        }
    }
    
    private func destroyNodes() {
        if let src {
            engine.detach(src)
        }
        src = nil
    }
    
    private func connectNodes() {
        guard let src else { fatalError("Expected src node") }
        // core samples → float at the core's rate → varispeed → main mixer (converts to the device)
        let format = renderFormat
        let floatFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: format.channelCount)
        engine.connect(src, to: converter, format: format)
        engine.connect(converter, to: varispeed, format: floatFormat)
        engine.connect(varispeed, to: engine.mainMixerNode, format: floatFormat)
        engine.mainMixerNode.outputVolume = volume
    }
    
    // MARK: - Latency control
    
    /// The core's emulated audio clock never exactly matches the output device's, so its buffer
    /// slowly fills (adding latency until it overflows) or drains (underflowing). Playing up to
    /// half a percent faster or slower keeps it near a small target; that's too little to hear.
    private static let maxRateAdjustment = 0.005
    
    private func startRateControl() {
        stopRateControl()
        // Only OERingBuffer, which almost every core uses, reports how full it is
        guard let ring = gameCore.audioBuffer(at: 0) as? OERingBuffer else { return }
        lastRequestBytes.store(0, ordering: .relaxed)
        smoothedFill = Double(ring.availableBytes)
        
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            self?.adjustRate(for: ring)
        }
        timer.resume()
        rateTimer = timer
    }
    
    private func stopRateControl() {
        rateTimer?.cancel()
        rateTimer = nil
        varispeed.rate = 1
    }
    
    private func adjustRate(for ring: OERingBuffer) {
        let request = lastRequestBytes.load(ordering: .relaxed)
        guard request > 0 else { return }
        
        // The ring buffer returns silence below two requests, and cores write a frame at a time,
        // so keep a few requests (or two frames) in hand.
        let perFrame = Int(gameCore.audioBufferSize(forBuffer: 0))
        let target = Double(max(4 * request, 2 * perFrame))
        let fill = Double(ring.availableBytes)
        
        // A backlog (audio produced before playback started) would take many seconds to play
        // off at half a percent, so drop it at once, a whole request at a time to keep the
        // channels aligned.
        if fill > 3 * target {
            var scratch = [UInt8](repeating: 0, count: request)
            // Stop a couple of requests above target: playback keeps draining meanwhile
            while Double(ring.availableBytes) > target + Double(2 * request),
                  ring.read(&scratch, maxLength: UInt(request)) > 0 {}
            smoothedFill = Double(ring.availableBytes)
            return
        }
        
        smoothedFill += 0.2 * (fill - smoothedFill)
        let error = (smoothedFill - target) / target
        let adjustment = min(max(2 * Self.maxRateAdjustment * error, -Self.maxRateAdjustment), Self.maxRateAdjustment)
        varispeed.rate = Float(1 + adjustment)
    }
    
    private var token: NSObjectProtocol?
    
    private func startMonitoringEngineConfiguration() {
        token = NotificationCenter.default
            .addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                guard let self = self else { return }
                
                log.debug("AVAudioEngine configuration change")
                self.setOutputDeviceID(self.outputDeviceID)
            }
    }
    
    private func stopMonitoringEngineConfiguration() {
        if let token = token {
            NotificationCenter.default.removeObserver(token)
            self.token = nil
        }
    }
    
    private var defaultAudioOutputDeviceID: AudioDeviceID {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID()
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        return deviceID
    }
    
    func setOutputDeviceID(_ newOutputDeviceID: AudioDeviceID) {
        let id: AudioDeviceID
        if newOutputDeviceID == 0 {
            id = defaultAudioOutputDeviceID
            isDefaultOutputDevice = true
            log.debug("Using default audio device \(id)")
        } else {
            id = newOutputDeviceID
            isDefaultOutputDevice = false
        }
        
        engine.stop()
        
        do {
            try engine.outputNode.auAudioUnit.setDeviceID(id)
        } catch {
            log.error("Unable to set output device ID \(id): \(error.localizedDescription, privacy: .public)")
        }
        
        connectNodes()
        
        if isRunning && !engine.isRunning {
            engine.prepare()
            performResumeAudio()
        }
    }
    
    var outputDeviceID: AudioDeviceID {
        isDefaultOutputDevice ? 0 : engine.outputNode.auAudioUnit.deviceID
    }
}
