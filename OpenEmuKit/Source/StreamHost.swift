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
import OpenEmuSystem

/// PROTOTYPE (stream play): sends the game's picture and sound to a remote Stream Viewer and
/// plays that viewer's controller as player 2, so only this Mac runs the game.
///
/// Turned on with `defaults write org.openemu.OpenEmu OEStreamHostEnabled -bool true`;
/// Works for every system: the viewer sends named buttons, played through the system responder.
/// Wire format, all integers little-endian, each message
/// `[type: UInt8][length: UInt32][payload]`:
///   host → viewer  1 video  `[flags: keyframe=1, flipped=2][width: UInt16][height: UInt16]`
///                           `[if keyframe: spsLen: UInt16, sps, ppsLen: UInt16, pps][AVCC H.264 frame]`
///                  2 audio  `[sampleRate: Float64][channels: UInt8][16-bit PCM]`
///                  5 pong   echo of a ping payload
///                  8 session `JSON {"system": <system identifier>, "player": <this viewer's player number>}`
///   viewer → host  4 ping   8 opaque bytes
///                  6 keyframe request (the viewer lost its place: send a full frame)
///                  7 key event `[player: UInt8][kind: UInt8 0=release 1=press 2=analog][value: Float32][name: UTF-8]`
///                    `name` is a system button name (e.g. "OESNESButtonA", from the system plugin's
///                    OEGenericControlNamesKey) or, for a viewer without OpenEmu, a Nintendo Switch Pro
///                    Controller control name (e.g. "OEControllerNintendoSwitchProControllerButtonB"), which
///                    the host maps through the system's default Switch Pro bindings.
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
    private let systemController: OESystemController
    private weak var responder: OESystemResponder?

    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache?
    private var pool: CVPixelBufferPool?
    private var poolSize = (width: 0, height: 0)
    private var session: VTCompressionSession?
    private var pendingFrames = 0          // guarded by lock
    private var needsKeyframe = true       // guarded by lock
    private var receiveBuffer = Data()

    /// Keys the viewer currently holds, so a disconnect releases them all (main thread only).
    private var heldKeys: [String: OESystemKey] = [:]
    private var analogKeys: [String: OESystemKey] = [:]
    /// Switch Pro control name → system key, built on first use (see `keyDescription(for:)`).
    private var switchProKeys: [String: OEKeyBindingDescription]?

    init(device: MTLDevice, gameCore: OEGameCore, systemController: OESystemController, responder: OESystemResponder) {
        self.device = device
        self.gameCore = gameCore
        self.systemController = systemController
        self.responder = responder
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
        sendSession()
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
            case 7 where payload.count >= 7:
                let player = UInt(payload[payload.startIndex])
                let kind = payload[payload.startIndex + 1]
                let value = CGFloat(Float(bitPattern: payload.readLE(UInt32.self, at: payload.startIndex + 2)))
                guard let name = String(data: payload.subdata(in: (payload.startIndex + 6)..<payload.endIndex), encoding: .utf8) else { break }
                DispatchQueue.main.async { self.applyKeyEvent(name: name, player: player, kind: kind, value: value) }
            case 4:
                send(type: 5, payload: payload)
            case 6:
                lock.lock(); needsKeyframe = true; lock.unlock()
            default:
                break
            }
        }
    }

    // MARK: - Input

    private static let switchProIdentifier = "OEControllerNintendoSwitchProController"
    static let guestPlayer: UInt = 2

    private func sendSession() {
        let info: [String: Any] = ["system": systemController.systemIdentifier ?? "", "player": Self.guestPlayer]
        if let json = try? JSONSerialization.data(withJSONObject: info) { send(type: 8, payload: json) }
    }

    /// Presses, releases or moves one system button for a player, as a real controller would through
    /// the system responder. `kind`: 0 release, 1 press, 2 analog with `value` 0…1.
    private func applyKeyEvent(name: String, player: UInt, kind: UInt8, value: CGFloat) {
        guard let responder, player == Self.guestPlayer, let description = keyDescription(for: name),
              let key = OESystemKey(key: description.index, player: player, isAnalogic: description.isAnalogic)
        else { return }
        let id = "\(player):\(description.name)"
        switch kind {
        case 1:
            heldKeys[id] = key
            responder.pressEmulatorKey(key)
        case 2:
            if value > 0 { analogKeys[id] = key } else { analogKeys[id] = nil }
            responder.changeAnalogEmulatorKey(key, value: min(max(value, 0), 1))
        default:
            heldKeys[id] = nil
            responder.releaseEmulatorKey(key)
        }
    }

    private func releaseAllButtons() {
        DispatchQueue.main.async {
            guard let responder = self.responder else { return }
            for key in self.heldKeys.values { responder.releaseEmulatorKey(key) }
            for key in self.analogKeys.values { responder.changeAnalogEmulatorKey(key, value: 0) }
            self.heldKeys.removeAll()
            self.analogKeys.removeAll()
        }
    }

    /// A system button by its own name, or by the Switch Pro control that the system maps to it by default.
    private func keyDescription(for name: String) -> OEKeyBindingDescription? {
        if let description = systemController.allKeyBindingsDescriptions[name] { return description }
        if switchProKeys == nil { switchProKeys = buildSwitchProKeys() }
        return switchProKeys?[name]
    }

    /// Reverses the system's default Switch Pro bindings (system key → control) into control → key.
    /// The defaults list one direction of each d-pad and stick and imply the rest, so those are
    /// expanded here: the opposite axis key, and every key of a hat switch.
    private func buildSwitchProKeys() -> [String: OEKeyBindingDescription] {
        var keys: [String: OEKeyBindingDescription] = [:]
        let defaults = systemController.defaultDeviceControls[Self.switchProIdentifier] ?? [:]
        for (keyName, control) in defaults {
            guard let description = systemController.allKeyBindingsDescriptions[keyName] else { continue }
            keys[control] = description
            if description.axisGroup != nil, let opposite = description.oppositeKey,
               let (dir, _) = Self.trailingDirection(of: control), let oppositeDir = Self.opposite[dir] {
                keys[Self.replacingTrailingDirection(of: control, with: oppositeDir)] = opposite
            }
            if description.hatSwitchGroup != nil, let hatKeys = description.hatSwitchKeys,
               Self.trailingDirection(of: control) != nil {
                for hatKey in hatKeys {
                    if let (dir, _) = Self.trailingDirection(of: hatKey.name) {
                        keys[Self.replacingTrailingDirection(of: control, with: dir)] = hatKey
                    }
                }
            }
        }
        if keys.isEmpty {
            log.error("No default Switch Pro bindings for \(self.systemController.systemIdentifier ?? "?", privacy: .public); a viewer without OpenEmu can't play")
        }
        return keys
    }

    private static let directions = ["Up", "Down", "Left", "Right"]
    private static let opposite = ["Up": "Down", "Down": "Up", "Left": "Right", "Right": "Left"]

    private static func trailingDirection(of name: String) -> (String, String)? {
        for direction in directions where name.hasSuffix(direction) {
            return (direction, String(name.dropLast(direction.count)))
        }
        return nil
    }

    private static func replacingTrailingDirection(of name: String, with direction: String) -> String {
        guard let (_, stem) = trailingDirection(of: name) else { return name }
        return stem + direction
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
        // Retro consoles are small pictures; ~4 Mbps looks the same as more and keeps Wi-Fi from queuing
        // (`defaults write org.openemu.OpenEmu OEStreamBitrate -int <bits per second>` to experiment)
        let bitrate = UserDefaults(suiteName: "org.openemu.OpenEmu")?.integer(forKey: "OEStreamBitrate") ?? 0
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_AverageBitRate, value: (bitrate > 0 ? bitrate : 4_000_000) as CFNumber)
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        // No periodic keyframes: a full frame is many times bigger than the rest and arrives late over
        // Wi-Fi, a visible skip. Send one when a viewer connects or asks for it instead.
        VTSessionSetProperty(newSession, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 0 as CFNumber)
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
