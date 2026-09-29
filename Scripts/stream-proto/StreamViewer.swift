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

// PROTOTYPE stream play viewer: shows a game streamed by OpenEmu's StreamHost (see
// OpenEmuKit/Source/StreamHost.swift for the wire format) and sends this Mac's controller
// or keyboard back as player 2. Build with Scripts/stream-proto/build-viewer.sh.

import Cocoa
import AVFoundation
import CoreMedia
import GameController
import Network

// MARK: - Wire helpers

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

/// N64 buttons, numbered like OEN64Button.
enum N64 {
    static let dUp = 0, dDown = 1, dLeft = 2, dRight = 3
    static let cUp = 4, cDown = 5, cLeft = 6, cRight = 7
    static let a = 8, b = 9, l = 10, r = 11, z = 12, start = 13
}

// MARK: - Audio

/// Plays the host's 16-bit PCM, keeping only a small backlog so sound stays close to the picture.
final class StreamAudio {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var sampleRate = 0.0, channels: UInt32 = 0
    private let lock = NSLock()
    private var pending = Data()

    func play(_ pcm: Data, sampleRate: Double, channels: UInt32) {
        if sampleRate != self.sampleRate || channels != self.channels {
            restart(sampleRate: sampleRate, channels: channels)
        }
        lock.lock()
        pending.append(pcm)
        // Keep at most ~120 ms queued: drop the oldest audio rather than fall behind
        let maxBytes = Int(sampleRate * 0.12) * Int(channels) * 2
        if pending.count > maxBytes { pending.removeFirst(pending.count - maxBytes) }
        lock.unlock()
    }

    private func restart(sampleRate: Double, channels: UInt32) {
        engine.stop()
        if let source { engine.detach(source) }
        self.sampleRate = sampleRate
        self.channels = channels
        lock.lock(); pending.removeAll(); lock.unlock()

        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: channels, interleaved: true)
        else { return }
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, bufferList in
            guard let self else { return noErr }
            let buffer = bufferList.pointee.mBuffers
            let wanted = Int(frameCount) * Int(channels) * 2
            self.lock.lock()
            let available = min(wanted, self.pending.count)
            self.pending.withUnsafeBytes { src in
                if let dst = buffer.mData, available > 0 { memcpy(dst, src.baseAddress!, available) }
            }
            self.pending.removeFirst(available)
            self.lock.unlock()
            if available < wanted, let dst = buffer.mData { memset(dst + available, 0, wanted - available) }
            bufferList.pointee.mBuffers.mDataByteSize = UInt32(wanted)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        source = node
        try? engine.start()
    }
}

// MARK: - Viewer

final class Viewer: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static let port: UInt16 = 47100

    private var window: NSWindow!
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let audio = StreamAudio()
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "StreamViewer")
    private var receiveBuffer = Data()
    private var formatDescription: CMVideoFormatDescription?
    private var host = ""

    // Input state, sent to the host
    private var keyboardButtons: UInt32 = 0
    private var keyboardStick = (x: 0, y: 0)
    private var lastSent: (UInt32, Int8, Int8) = (0, 0, 0)
    private var lastSendTime = Date.distantPast

    // Stats for the title bar
    private var framesThisSecond = 0
    private var rttMilliseconds: Double?

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "OpenEmu Stream Viewer"
        window.delegate = self
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = view.bounds
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(displayLayer)
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        installKeyboard()
        GCController.startWirelessControllerDiscovery {}
        Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.sendInputIfNeeded() }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }

        askForHostAndConnect()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func askForHostAndConnect() {
        // `--host <address>` skips the prompt (handy for testing)
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--host"), flag + 1 < arguments.count {
            host = arguments[flag + 1]
            connect()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Connect to OpenEmu"
        alert.informativeText = "Address of the Mac running the game (e.g. 192.168.50.52)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = UserDefaults.standard.string(forKey: "host") ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Quit")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { NSApp.terminate(nil); return }
        host = field.stringValue.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(host, forKey: "host")
        connect()
    }

    private func connect() {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: Self.port)!,
                                      using: NWParameters(tls: nil, tcp: tcp))
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async { self?.connectionChanged(state) }
        }
        connection.start(queue: queue)
        receive()
    }

    private func connectionChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            window.title = "Connected to \(host) — waiting for the game…"
        case .failed(let error), .waiting(let error):
            window.title = "Can't reach \(host): \(error.localizedDescription) — retrying"
            connection?.cancel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connect() }
        default:
            break
        }
    }

    // MARK: Receiving

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.receiveBuffer.append(data); self.processMessages() }
            if isComplete || error != nil { return }  // stateUpdateHandler reconnects
            self.receive()
        }
    }

    private func processMessages() {
        while receiveBuffer.count >= 5 {
            let start = receiveBuffer.startIndex
            let length = Int(receiveBuffer.readLE(UInt32.self, at: start + 1))
            guard receiveBuffer.count >= 5 + length else { return }
            let type = receiveBuffer[start]
            let payload = receiveBuffer.subdata(in: (start + 5)..<(start + 5 + length))
            receiveBuffer.removeSubrange(start..<(start + 5 + length))
            switch type {
            case 1: handleVideo(payload)
            case 2: handleAudio(payload)
            case 5: handlePong(payload)
            default: break
            }
        }
    }

    private func handleVideo(_ payload: Data) {
        var index = payload.startIndex
        let flags = payload[index]; index += 1
        index += 4  // width, height (the stream's format description carries them too)
        if flags & 1 != 0 {
            var sets: [Data] = []
            for _ in 0..<2 {
                let size = Int(payload.readLE(UInt16.self, at: index)); index += 2
                sets.append(payload.subdata(in: index..<(index + size))); index += size
            }
            formatDescription = makeFormatDescription(sps: sets[0], pps: sets[1])
        }
        guard let formatDescription else { return }
        let frame = payload.subdata(in: index..<payload.endIndex)
        guard let sample = makeSampleBuffer(frame, format: formatDescription) else { return }
        let flipped = flags & 2 != 0
        DispatchQueue.main.async {
            self.displayLayer.setAffineTransform(flipped ? CGAffineTransform(scaleX: 1, y: -1) : .identity)
            if self.displayLayer.status == .failed { self.displayLayer.flush() }
            self.displayLayer.enqueue(sample)
            self.framesThisSecond += 1
        }
    }

    private func makeFormatDescription(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var description: CMVideoFormatDescription?
        sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers = [spsBytes.bindMemory(to: UInt8.self).baseAddress!, ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers,
                                                                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        return description
    }

    private func makeSampleBuffer(_ frame: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: frame.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: frame.count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block
        else { return nil }
        frame.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: frame.count) }
        var sample: CMSampleBuffer?
        var size = frame.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample
        else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as NSArray?,
           let first = attachments.firstObject as? NSMutableDictionary {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        return sample
    }

    private func handleAudio(_ payload: Data) {
        guard payload.count > 9 else { return }
        let rate = Double(bitPattern: payload.readLE(UInt64.self, at: payload.startIndex))
        let channels = UInt32(payload[payload.startIndex + 8])
        audio.play(payload.subdata(in: (payload.startIndex + 9)..<payload.endIndex), sampleRate: rate, channels: channels)
    }

    private func handlePong(_ payload: Data) {
        guard payload.count == 8 else { return }
        let sent = payload.readLE(UInt64.self, at: payload.startIndex)
        let rtt = Double(DispatchTime.now().uptimeNanoseconds &- sent) / 1_000_000
        DispatchQueue.main.async { self.rttMilliseconds = rtt }
    }

    // MARK: Sending

    private func send(type: UInt8, payload: Data) {
        var message = Data()
        message.append(type)
        message.appendLE(UInt32(payload.count))
        message.append(payload)
        connection?.send(content: message, completion: .contentProcessed { _ in })
    }

    private func tick() {
        var ping = Data()
        ping.appendLE(DispatchTime.now().uptimeNanoseconds)
        send(type: 4, payload: ping)
        if connection?.state == .ready {
            let rtt = rttMilliseconds.map { String(format: "%.1f ms", $0) } ?? "–"
            let pad = GCController.controllers().first?.vendorName ?? "keyboard"
            window.title = "\(host) · round trip \(rtt) · \(framesThisSecond) fps · \(pad)"
            print("stats: \(framesThisSecond) fps, round trip \(rtt), input \(pad)")
            fflush(stdout)
        }
        framesThisSecond = 0
    }

    private func sendInputIfNeeded() {
        var buttons = keyboardButtons
        var x = keyboardStick.x, y = keyboardStick.y
        if let pad = GCController.controllers().first?.extendedGamepad {
            func set(_ bit: Int, _ on: Bool) { if on { buttons |= 1 << UInt32(bit) } }
            set(N64.dUp, pad.dpad.up.isPressed); set(N64.dDown, pad.dpad.down.isPressed)
            set(N64.dLeft, pad.dpad.left.isPressed); set(N64.dRight, pad.dpad.right.isPressed)
            set(N64.cUp, pad.rightThumbstick.yAxis.value > 0.5); set(N64.cDown, pad.rightThumbstick.yAxis.value < -0.5)
            set(N64.cLeft, pad.rightThumbstick.xAxis.value < -0.5); set(N64.cRight, pad.rightThumbstick.xAxis.value > 0.5)
            set(N64.a, pad.buttonA.isPressed)
            set(N64.b, pad.buttonB.isPressed || pad.buttonX.isPressed)
            set(N64.l, pad.leftShoulder.isPressed); set(N64.r, pad.rightShoulder.isPressed)
            set(N64.z, pad.leftTrigger.isPressed || pad.rightTrigger.isPressed)
            set(N64.start, pad.buttonMenu.isPressed)
            let px = Int(pad.leftThumbstick.xAxis.value * 127), py = Int(pad.leftThumbstick.yAxis.value * 127)
            if abs(px) > abs(x) { x = px }
            if abs(py) > abs(y) { y = py }
        }
        let state = (buttons, Int8(clamping: x), Int8(clamping: y))
        // Send on every change, and at least every 100 ms so a lost update can't stick
        guard state != lastSent || Date().timeIntervalSince(lastSendTime) > 0.1 else { return }
        var payload = Data()
        payload.appendLE(state.0)
        payload.append(UInt8(bitPattern: state.1))
        payload.append(UInt8(bitPattern: state.2))
        send(type: 3, payload: payload)
        lastSent = state
        lastSendTime = Date()
    }

    /// Keyboard: arrows = stick, X = A, Z = B, A = Z, Return = Start, Q/W = L/R, I/J/K/L = C buttons, T/F/G/H = d-pad.
    private func installKeyboard() {
        let buttonKeys: [UInt16: Int] = [7: N64.a, 6: N64.b, 0: N64.z, 36: N64.start, 12: N64.l, 13: N64.r,
                                         34: N64.cUp, 40: N64.cDown, 38: N64.cLeft, 37: N64.cRight,
                                         17: N64.dUp, 5: N64.dDown, 3: N64.dLeft, 4: N64.dRight]
        var arrows = Set<UInt16>()
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, !event.modifierFlags.contains(.command) else { return event }
            let down = event.type == .keyDown
            if let bit = buttonKeys[event.keyCode] {
                if down { self.keyboardButtons |= 1 << UInt32(bit) } else { self.keyboardButtons &= ~(1 << UInt32(bit)) }
                return nil
            }
            if [123, 124, 125, 126].contains(event.keyCode) {  // left, right, down, up
                if down { arrows.insert(event.keyCode) } else { arrows.remove(event.keyCode) }
                self.keyboardStick = ((arrows.contains(124) ? 127 : 0) - (arrows.contains(123) ? 127 : 0),
                                      (arrows.contains(126) ? 127 : 0) - (arrows.contains(125) ? 127 : 0))
                return nil
            }
            return event
        }
    }
}

let app = NSApplication.shared
let viewer = Viewer()
app.delegate = viewer
app.setActivationPolicy(.regular)
app.run()
