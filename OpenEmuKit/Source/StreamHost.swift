// Copyright (c) 2026, OpenEmu Team
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
import Metal
import CoreVideo
import CoreMedia
import VideoToolbox
import Network
internal import os.log
import OpenEmuBase

/// PROTOTYPE (stream play): sends the game's picture and sound to a remote Stream Viewer and
/// plays that viewer's controller as player 2, so only this Mac runs the game.
///
/// Turned on with `defaults write org.openemu.OpenEmu OEStreamHostEnabled -bool true`;
/// N64 only for now. Wire format, all integers little-endian, each message
/// `[type: UInt8][length: UInt32][payload]`:
///   host → viewer  1 video  `[flags: keyframe=1, flipped=2][width: UInt16][height: UInt16]`
///                           `[if keyframe: spsLen: UInt16, sps, ppsLen: UInt16, pps][AVCC H.264 frame]`
///                  2 audio  `[sampleRate: Float64][channels: UInt8][16-bit PCM]`
///                  5 pong   echo of a ping payload
///   viewer → host  3 input  `[buttons: UInt32, bit n = OEN64Button n][stickX: Int8][stickY: Int8]` (y up)
///                  4 ping   8 opaque bytes
@available(macOS 11.3, *)
final class StreamHost {
    static let port: UInt16 = 47100

    static var isEnabled: Bool {
        UserDefaults(suiteName: "org.openemu.OpenEmu")?.bool(forKey: "OEStreamHostEnabled") ?? false
    }

    /// The running host, for the audio tap in GameAudio2.
    static var current: StreamHost?

    private let log = Logger(subsystem: "org.openemu.OpenEmuKit", category: "StreamHost")
    private let queue = DispatchQueue(label: "org.openemu.StreamHost")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connection: NWConnection?  // guarded by lock
    private weak var gameCore: OEGameCore?

    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache?
    private var pool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)
    private var session: VTCompressionSession?
    private var pendingFrames = 0          // guarded by lock
    private var needsKeyframe = true       // guarded by lock
    private var receiveBuffer = Data()
    private var lastButtons: UInt32 = 0

    init(device: MTLDevice, gameCore: OEGameCore) {
        self.device = device
        self.gameCore = gameCore
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    func start() {
        do {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let listener = try NWListener(using: NWParameters(tls: nil, tcp: tcp), on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.newConnectionHandler = { [weak self] in self?.accept($0) }
            listener.start(queue: queue)
            self.listener = listener
            Self.current = self
            log.notice("Stream host listening on port \(Self.port, privacy: .public)")
        } catch {
            log.error("Stream host could not listen: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        listener?.cancel()
        lock.lock(); connection?.cancel(); connection = nil; lock.unlock()
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
        if Self.current === self { Self.current = nil }
    }

    // MARK: - Connection

    private func accept(_ newConnection: NWConnection) {
        lock.lock()
        connection?.cancel()  // one viewer at a time: the newest wins
        connection = newConnection
        needsKeyframe = true
        pendingFrames = 0
        lock.unlock()
        receiveBuffer = Data()
        releaseAllButtons()

        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            if case .failed = state, let newConnection { self?.drop(newConnection) }
            if case .cancelled = state, let newConnection { self?.drop(newConnection) }
        }
        newConnection.start(queue: queue)
        receive(on: newConnection)
        log.notice("Stream viewer connected from \(String(describing: newConnection.endpoint), privacy: .public)")
    }

    private func drop(_ old: NWConnection) {
        lock.lock()
        let wasCurrent = connection === old
        if wasCurrent { connection = nil }
        lock.unlock()
        if wasCurrent {
            releaseAllButtons()
            log.notice("Stream viewer disconnected")
        }
    }

    private func send(type: UInt8, payload: Data) {
        lock.lock(); let connection = self.connection; lock.unlock()
        guard let connection else { return }
        var message = Data(capacity: payload.count + 5)
        message.append(type)
        message.appendLE(UInt32(payload.count))
        message.append(payload)
        connection.send(content: message, completion: .contentProcessed { _ in })
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.receiveBuffer.append(data); self.processReceived() }
            if isComplete || error != nil { self.drop(connection); return }
            self.receive(on: connection)
        }
    }

    private func processReceived() {
        while receiveBuffer.count >= 5 {
            let start = receiveBuffer.startIndex
            let length = Int(receiveBuffer.readLE(UInt32.self, at: start + 1))
            guard receiveBuffer.count >= 5 + length else { return }
            let type = receiveBuffer[start]
            let payload = receiveBuffer.subdata(in: (start + 5)..<(start + 5 + length))
            receiveBuffer.removeSubrange(start..<(start + 5 + length))
            switch type {
            case 3 where payload.count >= 6:
                let buttons = payload.readLE(UInt32.self, at: payload.startIndex)
                let x = Int8(bitPattern: payload[payload.startIndex + 4])
                let y = Int8(bitPattern: payload[payload.startIndex + 5])
                DispatchQueue.main.async { self.applyInput(buttons: buttons, x: x, y: y) }
            case 4:
                send(type: 5, payload: payload)
            default:
                break
            }
        }
    }

    // MARK: - Input (player 2)

    private static let player: UInt = 2
    private static let buttonCount: UInt32 = 14  // OEN64ButtonDPadUp ... OEN64ButtonStart
    private static let analogUp: Int32 = 14, analogDown: Int32 = 15, analogLeft: Int32 = 16, analogRight: Int32 = 17

    private func applyInput(buttons: UInt32, x: Int8, y: Int8) {
        guard let core = gameCore as AnyObject? else { return }
        let changed = buttons ^ lastButtons
        for button in 0..<Self.buttonCount where changed & (1 << button) != 0 {
            if buttons & (1 << button) != 0 {
                core.didPushN64Button?(Int32(button), forPlayer: Self.player)
            } else {
                core.didReleaseN64Button?(Int32(button), forPlayer: Self.player)
            }
        }
        lastButtons = buttons
        let fx = CGFloat(x) / 127, fy = CGFloat(y) / 127
        core.didMoveN64JoystickDirection?(Self.analogRight, withValue: max(fx, 0), forPlayer: Self.player)
        core.didMoveN64JoystickDirection?(Self.analogLeft, withValue: max(-fx, 0), forPlayer: Self.player)
        core.didMoveN64JoystickDirection?(Self.analogUp, withValue: max(fy, 0), forPlayer: Self.player)
        core.didMoveN64JoystickDirection?(Self.analogDown, withValue: max(-fy, 0), forPlayer: Self.player)
    }

    private func releaseAllButtons() {
        DispatchQueue.main.async { self.applyInput(buttons: 0, x: 0, y: 0) }
    }

    // MARK: - Video

    /// Copies the finished frame (in `commandBuffer`, before it's committed) and encodes it once the GPU is done.
    func submit(frame source: MTLTexture, flipped: Bool, commandBuffer: MTLCommandBuffer) {
        lock.lock()
        let connected = connection != nil
        let busy = pendingFrames >= 2  // the encoder or network is behind: drop this frame
        if connected && !busy { pendingFrames += 1 }
        lock.unlock()
        guard connected, !busy else { return }

        guard source.pixelFormat == .bgra8Unorm,
              let pixelBuffer = makePixelBuffer(width: source.width, height: source.height),
              let target = metalTexture(for: pixelBuffer),
              let blit = commandBuffer.makeBlitCommandEncoder()
        else { finishFrame(); return }

        blit.copy(from: source, to: target)
        blit.endEncoding()
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.queue.async { self?.encode(pixelBuffer, flipped: flipped) }
        }
    }

    private func finishFrame() {
        lock.lock(); pendingFrames = max(0, pendingFrames - 1); lock.unlock()
    }

    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize != (width, height) {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            poolSize = (width, height)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    private func metalTexture(for pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let textureCache else { return nil }
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer, nil, .bgra8Unorm,
                                                  CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &cvTexture)
        return cvTexture.flatMap(CVMetalTextureGetTexture)
    }

    private func encode(_ pixelBuffer: CVPixelBuffer, flipped: Bool) {
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        if session == nil || poolSize != (width, height) || sessionSize != (width, height) {
            makeSession(width: width, height: height)
        }
        guard let session else { finishFrame(); return }

        lock.lock()
        let keyframe = needsKeyframe
        needsKeyframe = false
        lock.unlock()
        let properties = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        frameCount += 1
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer,
                                                     presentationTimeStamp: CMTime(value: frameCount, timescale: 60),
                                                     duration: .invalid, frameProperties: properties, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard let self else { return }
            defer { self.finishFrame() }
            guard status == noErr, let sample else { return }
            self.sendVideo(sample, flipped: flipped, width: width, height: height)
        }
        if status != noErr { finishFrame() }
    }

    private var frameCount: Int64 = 0
    private var sessionSize = (width: 0, height: 0)

    private func makeSession(width: Int, height: Int) {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
        let specification = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        var newSession: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                         codecType: kCMVideoCodecType_H264, encoderSpecification: specification,
                                         imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &newSession) == noErr,
              let newSession
        else { log.error("Could not create the stream encoder"); return }
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_AverageBitRate, value: 12_000_000 as CFNumber)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 120 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(newSession)
        session = newSession
        sessionSize = (width, height)
        lock.lock(); needsKeyframe = true; lock.unlock()
        log.notice("Stream encoder \(width, privacy: .public)x\(height, privacy: .public)")
    }

    private func sendVideo(_ sample: CMSampleBuffer, flipped: Bool, width: Int, height: Int) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sample) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

        var payload = Data()
        payload.append(UInt8((keyframe ? 1 : 0) | (flipped ? 2 : 0)))
        payload.appendLE(UInt16(width))
        payload.appendLE(UInt16(height))
        if keyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            for index in 0..<2 {  // SPS, PPS
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                   parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                payload.appendLE(UInt16(size))
                if let pointer { payload.append(pointer, count: size) }
            }
        }
        let length = CMBlockBufferGetDataLength(dataBuffer)
        var frame = Data(count: length)
        frame.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        payload.append(frame)
        send(type: 1, payload: payload)
    }

    // MARK: - Audio

    /// Called on the audio render thread with each block the host plays.
    func audio(_ bytes: UnsafeRawPointer, count: Int, sampleRate: Double, channels: UInt32) {
        guard count > 0 else { return }
        var payload = Data(capacity: count + 9)
        payload.appendLE(sampleRate.bitPattern)
        payload.append(UInt8(channels))
        payload.append(bytes.assumingMemoryBound(to: UInt8.self), count: count)
        queue.async { self.send(type: 2, payload: payload) }
    }
}

/// The N64 system responder calls, looked up at run time (the N64 plugin isn't linked into OpenEmuKit).
@objc private protocol StreamN64Input {
    @objc optional func didPushN64Button(_ button: Int32, forPlayer player: UInt)
    @objc optional func didReleaseN64Button(_ button: Int32, forPlayer player: UInt)
    @objc optional func didMoveN64JoystickDirection(_ button: Int32, withValue value: CGFloat, forPlayer player: UInt)
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func readLE<T: FixedWidthInteger>(_ type: T.Type, at index: Index) -> T {
        var value: T = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { copyBytes(to: $0, from: index..<(index + MemoryLayout<T>.size)) }
        return T(littleEndian: value)
    }
}
