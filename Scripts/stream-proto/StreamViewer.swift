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
import CoreVideo

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

/// The viewer presents itself to the host as a Nintendo Switch Pro Controller: these are OpenEmu's
/// control names for it, which the host maps to the system being played through its default bindings.
enum SwitchPro {
    static let prefix = "OEControllerNintendoSwitchProController"
    // Face buttons by position, as OpenEmu labels a real Switch Pro: B bottom, A right, Y left, X top
    static let bottom = prefix + "ButtonB", right = prefix + "ButtonA", left = prefix + "ButtonY", top = prefix + "ButtonX"
    static let l = prefix + "ButtonL", r = prefix + "ButtonR", zl = prefix + "ButtonZL", zr = prefix + "ButtonZR"
    static let plus = prefix + "ButtonPlus", minus = prefix + "ButtonMinus", home = prefix + "ButtonHome"
    static let leftStickButton = prefix + "ButtonLeftAnalog", rightStickButton = prefix + "ButtonRightAnalog"
    static func dpad(_ dir: String) -> String { prefix + "DPad" + dir }
    static func leftStick(_ dir: String) -> String { prefix + "LeftAnalog" + dir }
    static func rightStick(_ dir: String) -> String { prefix + "RightAnalog" + dir }
}

// MARK: - Audio

/// Plays the host's 16-bit PCM through a small jitter buffer: playback waits until ~60 ms is
/// queued, and after running dry waits to refill rather than stuttering through every late packet.
final class StreamAudio {
    private var primed = false
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
        // Keep at most ~200 ms queued: drop the oldest audio rather than fall further behind
        let frameBytes = Int(channels) * 2
        let maxBytes = Int(sampleRate * 0.2) * frameBytes
        if pending.count > maxBytes { pending.removeFirst(pending.count - maxBytes) }
        lock.unlock()
    }

    private func restart(sampleRate: Double, channels: UInt32) {
        engine.stop()
        if let source { engine.detach(source) }
        self.sampleRate = sampleRate
        self.channels = channels
        lock.lock(); pending.removeAll(); primed = false; lock.unlock()

        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: channels, interleaved: true)
        else { return }
        let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, bufferList in
            guard let self else { return noErr }
            let buffer = bufferList.pointee.mBuffers
            let wanted = Int(frameCount) * Int(channels) * 2
            let target = Int(sampleRate * 0.06) * Int(channels) * 2
            self.lock.lock()
            if !self.primed && self.pending.count >= target { self.primed = true }
            if self.primed && self.pending.count < wanted { self.primed = false }  // ran dry: refill first
            let available = self.primed ? min(wanted, self.pending.count) : 0
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

    // Input state, sent to the host as it changes: control name → value (buttons 0/1, stick directions 0…1)
    private var keyboardState: [String: Float] = [:]
    private var sentState: [String: Float] = [:]
    private var player: UInt8 = 2

    // Video jitter buffer: frames wait here and go on screen one per 1/60 s, in step with the display
    private let frameLock = NSLock()
    private var frameQueue: [(CMSampleBuffer, Bool)] = []
    private var framesPrimed = false
    private var lastShown: CFTimeInterval = 0
    private var displayLink: CVDisplayLink?

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
        startDisplayLink()
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
            case 8:
                if let info = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                    if let p = info["player"] as? Int { player = UInt8(p) }
                    print("session: system \(info["system"] ?? "?"), you are player \(player)"); fflush(stdout)
                }
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
        guard let formatDescription else { requestKeyframe(); return }
        let frame = payload.subdata(in: index..<payload.endIndex)
        guard let sample = makeSampleBuffer(frame, format: formatDescription) else { return }
        let flipped = flags & 2 != 0
        frameLock.lock()
        frameQueue.append((sample, flipped))
        // Never hold more than ~4 frames: if the queue backs up, skip ahead to keep the delay short.
        // Skipped frames must still be decoded (later frames are built on them), just not shown.
        var skipped: [CMSampleBuffer] = []
        if frameQueue.count > 4 { skipped = frameQueue.prefix(frameQueue.count - 2).map(\.0); frameQueue.removeFirst(frameQueue.count - 2) }
        frameLock.unlock()
        if !skipped.isEmpty {
            DispatchQueue.main.async {
                for sample in skipped {
                    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as NSArray?,
                       let first = attachments.firstObject as? NSMutableDictionary {
                        first[kCMSampleAttachmentKey_DoNotDisplay] = true
                    }
                    self.displayLayer.enqueue(sample)
                }
            }
        }
    }

    /// Called on every display refresh; shows at most one frame per 1/60 s.
    private func displayRefresh() {
        let now = CACurrentMediaTime()
        guard now - lastShown >= 1.0 / 60 * 0.9 else { return }  // 120 Hz displays: every other refresh
        frameLock.lock()
        if !framesPrimed && frameQueue.count >= 2 { framesPrimed = true }  // start with one frame in reserve
        if framesPrimed && frameQueue.isEmpty { framesPrimed = false }   // ran dry: rebuild the reserve
        let next = framesPrimed ? frameQueue.removeFirst() : nil
        frameLock.unlock()
        guard let (sample, flipped) = next else { return }
        lastShown = now
        DispatchQueue.main.async {
            self.displayLayer.setAffineTransform(flipped ? CGAffineTransform(scaleX: 1, y: -1) : .identity)
            if self.displayLayer.status == .failed {
                // The decoder lost its place: start again from a fresh full frame
                self.displayLayer.flush()
                self.requestKeyframe()
            }
            self.displayLayer.enqueue(sample)
            self.framesThisSecond += 1
        }
    }

    private func startDisplayLink() {
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let displayLink else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(displayLink, { _, _, _, _, _, context in
            Unmanaged<Viewer>.fromOpaque(context!).takeUnretainedValue().displayRefresh()
            return kCVReturnSuccess
        }, context)
        CVDisplayLinkStart(displayLink)
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

    private var lastKeyframeRequest = Date.distantPast

    private func requestKeyframe() {
        guard Date().timeIntervalSince(lastKeyframeRequest) > 0.5 else { return }
        lastKeyframeRequest = Date()
        send(type: 6, payload: Data())
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
        var state = keyboardState
        if let pad = GCController.controllers().first?.extendedGamepad {
            func button(_ name: String, _ on: Bool) { if on { state[name] = 1 } }
            func stick(_ name: (String) -> String, _ x: Float, _ y: Float) {
                for (dir, v) in [("Right", x), ("Left", -x), ("Up", y), ("Down", -y)] where v > 0.02 {
                    state[name(dir)] = max(state[name(dir)] ?? 0, min(v, 1))
                }
            }
            button(SwitchPro.bottom, pad.buttonA.isPressed); button(SwitchPro.right, pad.buttonB.isPressed)
            button(SwitchPro.left, pad.buttonX.isPressed); button(SwitchPro.top, pad.buttonY.isPressed)
            button(SwitchPro.l, pad.leftShoulder.isPressed); button(SwitchPro.r, pad.rightShoulder.isPressed)
            button(SwitchPro.zl, pad.leftTrigger.isPressed); button(SwitchPro.zr, pad.rightTrigger.isPressed)
            button(SwitchPro.plus, pad.buttonMenu.isPressed); button(SwitchPro.minus, pad.buttonOptions?.isPressed ?? false)
            button(SwitchPro.home, pad.buttonHome?.isPressed ?? false)
            button(SwitchPro.leftStickButton, pad.leftThumbstickButton?.isPressed ?? false)
            button(SwitchPro.rightStickButton, pad.rightThumbstickButton?.isPressed ?? false)
            button(SwitchPro.dpad("Up"), pad.dpad.up.isPressed); button(SwitchPro.dpad("Down"), pad.dpad.down.isPressed)
            button(SwitchPro.dpad("Left"), pad.dpad.left.isPressed); button(SwitchPro.dpad("Right"), pad.dpad.right.isPressed)
            stick(SwitchPro.leftStick, pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value)
            stick(SwitchPro.rightStick, pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value)
        }
        // Send only what changed. Buttons: press/release. Stick directions: analog value.
        for name in Set(state.keys).union(sentState.keys) {
            let value = state[name] ?? 0, previous = sentState[name] ?? 0
            let isStick = name.contains("Analog") && !name.contains("ButtonLeftAnalog") && !name.contains("ButtonRightAnalog")
            if isStick {
                guard abs(value - previous) >= 0.02 || (value == 0) != (previous == 0) else { continue }
                sendKey(name, kind: 2, value: value)
            } else {
                guard (value > 0.5) != (previous > 0.5) else { continue }
                sendKey(name, kind: value > 0.5 ? 1 : 0, value: value)
            }
            if value == 0 { sentState[name] = nil } else { sentState[name] = value }
        }
    }

    private func sendKey(_ name: String, kind: UInt8, value: Float) {
        var payload = Data()
        payload.append(player)
        payload.append(kind)
        payload.appendLE(value.bitPattern)
        payload.append(contentsOf: Array(name.utf8))
        send(type: 7, payload: payload)
    }

    /// Keyboard, laid out like a Switch Pro: arrows = left stick, X = bottom button, Z = right button,
    /// C = left, V = top, A = ZL, S = ZR, Q / W = L / R, Return = +, Backspace = −,
    /// I J K L = right stick (C buttons on N64), T F G H = d-pad.
    private func installKeyboard() {
        let keys: [UInt16: String] = [
            7: SwitchPro.bottom, 6: SwitchPro.right, 8: SwitchPro.left, 9: SwitchPro.top,
            0: SwitchPro.zl, 1: SwitchPro.zr, 12: SwitchPro.l, 13: SwitchPro.r,
            36: SwitchPro.plus, 51: SwitchPro.minus,
            34: SwitchPro.rightStick("Up"), 40: SwitchPro.rightStick("Down"), 38: SwitchPro.rightStick("Left"), 37: SwitchPro.rightStick("Right"),
            17: SwitchPro.dpad("Up"), 5: SwitchPro.dpad("Down"), 3: SwitchPro.dpad("Left"), 4: SwitchPro.dpad("Right"),
            126: SwitchPro.leftStick("Up"), 125: SwitchPro.leftStick("Down"), 123: SwitchPro.leftStick("Left"), 124: SwitchPro.leftStick("Right"),
        ]
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, !event.modifierFlags.contains(.command), let name = keys[event.keyCode] else { return event }
            if event.type == .keyDown { self.keyboardState[name] = 1 } else { self.keyboardState[name] = nil }
            return nil
        }
    }
}

let app = NSApplication.shared
let viewer = Viewer()
app.delegate = viewer
app.setActivationPolicy(.regular)
app.run()
