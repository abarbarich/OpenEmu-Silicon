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

import Cocoa

private let NetplayServerAddressKey = "netplayServerAddress"
private let NetplayPlayerNameKey = "netplayPlayerName"

/// The Host Netplay / Join Netplay sheet: creates or joins a room on the player's netplay
/// server, shows who is in it, and hands back a `NetplaySession` once the host starts the game.
final class NetplayLobbyWindowController: NSWindowController {

    enum Mode {
        case host
        case join
    }

    private enum Stage: Equatable {
        case form
        case connecting
        case browsing
        case joining
        case inRoom(port: Int)
        case starting(port: Int)
    }

    private let mode: Mode
    private let gameTitle: String
    private let romMD5: String

    private var client: NetplayLobbyClient?
    private var stage: Stage = .form { didSet { updateControls() } }
    private var rooms: [NetplayLobbyMessage.Room] = []
    private var playerNames: [String] = []
    private var completion: ((NetplaySession?) -> Void)?

    private let serverField = NSTextField()
    private let nameField = NSTextField()
    private let roomsTable = NSTableView()
    private let roomsScrollView = NSScrollView()
    private let roomsLabel = NSTextField(labelWithString: NSLocalizedString("Rooms for this game:", comment: "Netplay join sheet: label above the room list"))
    private let playersLabel = NSTextField(labelWithString: NSLocalizedString("Players:", comment: "Netplay sheet: label above the player list"))
    private let playersList = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let primaryButton = NSButton(title: "", target: nil, action: nil)
    private let cancelButton = NSButton(title: NSLocalizedString("Cancel", comment: ""), target: nil, action: nil)

    init(mode: Mode, gameTitle: String, romMD5: String) {
        self.mode = mode
        self.gameTitle = gameTitle
        self.romMD5 = romMD5

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: true)
        window.isReleasedWhenClosed = false
        super.init(window: window)

        buildContent()
        updateControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows the sheet on `parentWindow`. `completion` gets the session when the game starts,
    /// or nil when the player cancels.
    func beginSheet(on parentWindow: NSWindow, completion: @escaping (NetplaySession?) -> Void) {
        guard let window else { return }
        self.completion = completion
        parentWindow.beginSheet(window) { _ in }
        window.makeFirstResponder(serverField.stringValue.isEmpty ? serverField : nameField)
    }

    // MARK: - Layout

    private func buildContent() {
        let titleLabel = NSTextField(labelWithString: mode == .host
            ? NSLocalizedString("Host Netplay", comment: "Netplay host sheet title")
            : NSLocalizedString("Join Netplay", comment: "Netplay join sheet title"))
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 2)

        let gameLabel = NSTextField(labelWithString: gameTitle)
        gameLabel.textColor = .secondaryLabelColor
        gameLabel.lineBreakMode = .byTruncatingTail

        serverField.placeholderString = NSLocalizedString("e.g. 192.168.1.20 or myserver.local", comment: "Netplay server address placeholder")
        serverField.stringValue = UserDefaults.standard.string(forKey: NetplayServerAddressKey) ?? ""
        nameField.placeholderString = NSLocalizedString("Shown to the other players", comment: "Netplay player name placeholder")
        nameField.stringValue = UserDefaults.standard.string(forKey: NetplayPlayerNameKey)
            ?? NSFullUserName().components(separatedBy: " ").first ?? ""
        for field in [serverField, nameField] {
            field.target = self
            field.action = #selector(primaryAction(_:))
            NotificationCenter.default.addObserver(self, selector: #selector(fieldsDidChange(_:)),
                                                   name: NSControl.textDidChangeNotification, object: field)
        }

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: NSLocalizedString("Server:", comment: "Netplay server address label")), serverField],
            [NSTextField(labelWithString: NSLocalizedString("Your name:", comment: "Netplay player name label")), nameField],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.column(at: 1).width = 300

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("room"))
        roomsTable.addTableColumn(column)
        roomsTable.headerView = nil
        roomsTable.dataSource = self
        roomsTable.delegate = self
        roomsTable.target = self
        roomsTable.doubleAction = #selector(primaryAction(_:))
        roomsScrollView.documentView = roomsTable
        roomsScrollView.hasVerticalScroller = true
        roomsScrollView.borderType = .bezelBorder
        roomsScrollView.heightAnchor.constraint(equalToConstant: 100).isActive = true

        playersList.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        playersList.maximumNumberOfLines = 4

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.preferredMaxLayoutWidth = 400

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false

        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        primaryButton.target = self
        primaryButton.action = #selector(primaryAction(_:))
        primaryButton.keyEquivalent = "\r"

        let buttons = NSStackView(views: [progressIndicator, NSView(), cancelButton, primaryButton])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [titleLabel, gameLabel, grid, roomsLabel, roomsScrollView, playersLabel, playersList, statusLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(2, after: titleLabel)
        stack.setCustomSpacing(4, after: roomsLabel)
        stack.setCustomSpacing(4, after: playersLabel)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for view in [roomsScrollView, statusLabel, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }

        let contentView = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            contentView.widthAnchor.constraint(equalToConstant: 440),
        ])
        window?.contentView = contentView
    }

    private func updateControls() {
        let isConnected = client != nil
        serverField.isEnabled = !isConnected
        nameField.isEnabled = !isConnected

        let showsRooms = mode == .join && (stage == .browsing || stage == .joining)
        roomsLabel.isHidden = !showsRooms
        roomsScrollView.isHidden = !showsRooms

        var showsPlayers = false
        if case .inRoom = stage { showsPlayers = true }
        if case .starting = stage { showsPlayers = true }
        playersLabel.isHidden = !showsPlayers
        playersList.isHidden = !showsPlayers
        playersList.stringValue = playersDescription

        let isBusy: Bool
        switch stage {
        case .connecting, .joining, .starting: isBusy = true
        default: isBusy = false
        }
        isBusy ? progressIndicator.startAnimation(nil) : progressIndicator.stopAnimation(nil)

        let fieldsFilled = NetplayLobbyClient.parseAddress(serverField.stringValue) != nil && !playerName.isEmpty
        switch (mode, stage) {
        case (.host, .form), (.host, .connecting):
            primaryButton.title = NSLocalizedString("Create Room", comment: "Netplay host sheet button")
            primaryButton.isEnabled = stage == .form && fieldsFilled
        case (.host, .inRoom):
            primaryButton.title = NSLocalizedString("Start Game", comment: "Netplay host sheet button")
            primaryButton.isEnabled = joinedPlayerCount >= 2
        case (.host, .starting):
            primaryButton.title = NSLocalizedString("Start Game", comment: "Netplay host sheet button")
            primaryButton.isEnabled = false
        case (.join, .form), (.join, .connecting), (.join, .browsing):
            let joinsRoom = stage == .browsing && roomsTable.selectedRow >= 0
            primaryButton.title = joinsRoom
                ? NSLocalizedString("Join Room", comment: "Netplay join sheet button")
                : NSLocalizedString("Find Rooms", comment: "Netplay join sheet button")
            primaryButton.isEnabled = stage != .connecting && fieldsFilled
        case (.join, _):
            primaryButton.title = NSLocalizedString("Join Room", comment: "Netplay join sheet button")
            primaryButton.isEnabled = false
        default:
            primaryButton.isEnabled = false
        }
    }

    private var playerName: String {
        nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var joinedPlayerCount: Int {
        playerNames.filter { !$0.isEmpty }.count
    }

    private var playersDescription: String {
        (0..<4).map { index -> String in
            let name = index < playerNames.count ? playerNames[index] : ""
            if name.isEmpty {
                return String(format: NSLocalizedString("Player %d: —", comment: "Netplay sheet: empty player slot"), index + 1)
            }
            let you = name == playerName ? NSLocalizedString(" (you)", comment: "Netplay sheet: marks this player in the list") : ""
            return String(format: NSLocalizedString("Player %d: %@", comment: "Netplay sheet: player slot"), index + 1, name) + you
        }.joined(separator: "\n")
    }

    private func showStatus(_ text: String, isError: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    // MARK: - Actions

    @objc private func fieldsDidChange(_ notification: Notification) {
        updateControls()
    }

    @objc private func primaryAction(_ sender: Any?) {
        guard primaryButton.isEnabled else { return }
        switch (mode, stage) {
        case (.host, .form):
            connect()
            showStatus(NSLocalizedString("Creating the room…", comment: "Netplay host sheet status"))
            client?.send(NetplayLobbyMessage(type: NetplayLobbyClient.MessageType.createRoom,
                                             room: .init(gameName: gameTitle, roomName: roomName, md5: romMD5)))
        case (.host, .inRoom(let port)):
            stage = .starting(port: port)
            showStatus(NSLocalizedString("Starting the game…", comment: "Netplay host sheet status"))
            client?.send(NetplayLobbyMessage(type: NetplayLobbyClient.MessageType.beginGame, room: .init(port: port)))
        case (.join, .form):
            connect()
            requestRooms()
        case (.join, .browsing):
            let row = roomsTable.selectedRow
            if row >= 0, row < rooms.count, let port = rooms[row].port {
                stage = .joining
                showStatus(NSLocalizedString("Joining the room…", comment: "Netplay join sheet status"))
                client?.send(NetplayLobbyMessage(type: NetplayLobbyClient.MessageType.joinRoom,
                                                 room: .init(md5: romMD5, port: port)))
            } else {
                requestRooms()
            }
        default:
            break
        }
    }

    @objc private func cancel(_ sender: Any?) {
        client?.close()
        client = nil
        end(with: nil)
    }

    private var roomName: String {
        String(format: NSLocalizedString("%@'s %@", comment: "Netplay room name: <player>'s <game>"), playerName, gameTitle)
    }

    private func connect() {
        guard let client = NetplayLobbyClient(address: serverField.stringValue, playerName: playerName) else { return }
        UserDefaults.standard.set(serverField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: NetplayServerAddressKey)
        UserDefaults.standard.set(playerName, forKey: NetplayPlayerNameKey)

        client.onMessage = { [weak self] message in self?.handle(message) }
        client.onDisconnect = { [weak self] error in self?.handleDisconnect(error) }
        self.client = client
        stage = .connecting
        client.connect()
    }

    private func requestRooms() {
        stage = .connecting
        showStatus(NSLocalizedString("Looking for rooms…", comment: "Netplay join sheet status"))
        client?.send(NetplayLobbyMessage(type: NetplayLobbyClient.MessageType.getRooms))
    }

    private func requestPlayers(port: Int) {
        client?.send(NetplayLobbyMessage(type: NetplayLobbyClient.MessageType.players, room: .init(port: port)))
    }

    // MARK: - Lobby messages

    private func handle(_ message: NetplayLobbyMessage) {
        let accepted = (message.accept ?? 0) == 0
        typealias Kind = NetplayLobbyClient.MessageType

        switch message.type {
        case Kind.createRoomReply:
            guard accepted, let port = message.room?.port else {
                return fail(message.message ?? NSLocalizedString("The server couldn't create the room.", comment: "Netplay error"))
            }
            stage = .inRoom(port: port)
            showStatus(NSLocalizedString("Waiting for other players to join. Start the game when everyone is here.", comment: "Netplay host sheet status"))
            requestPlayers(port: port)

        case Kind.getRoomsReply:
            guard accepted else {
                return fail(message.message ?? NSLocalizedString("The server couldn't list its rooms.", comment: "Netplay error"))
            }
            rooms = (message.rooms ?? []).filter {
                $0.md5?.caseInsensitiveCompare(romMD5) == .orderedSame && $0.isProtected != true && $0.port != nil
            }
            roomsTable.reloadData()
            stage = .browsing
            showStatus(rooms.isEmpty
                ? NSLocalizedString("Nobody is hosting this game on the server yet. Ask the host to create a room, then click Find Rooms again.", comment: "Netplay join sheet status")
                : NSLocalizedString("Choose a room to join.", comment: "Netplay join sheet status"))

        case Kind.joinRoomReply:
            guard accepted, let port = message.room?.port else {
                stage = .browsing
                return showStatus(message.message ?? NSLocalizedString("Couldn't join the room.", comment: "Netplay error"), isError: true)
            }
            stage = .inRoom(port: port)
            showStatus(NSLocalizedString("Waiting for the host to start the game.", comment: "Netplay join sheet status"))
            // The server only shares the player list when asked; asking also tells the host we're in
            requestPlayers(port: port)

        case Kind.playersReply:
            playerNames = message.playerNames ?? []
            updateControls()

        case Kind.beginGameReply:
            guard accepted else {
                if case .starting(let port) = stage { stage = .inRoom(port: port) }
                return showStatus(message.message ?? NSLocalizedString("The game couldn't be started.", comment: "Netplay error"), isError: true)
            }
            startGame()

        default:
            break
        }
    }

    private func startGame() {
        let port: Int
        switch stage {
        case .inRoom(let roomPort), .starting(let roomPort): port = roomPort
        default: return
        }
        guard let client, let player = NetplayLobbyClient.playerNumber(of: playerName, in: playerNames) else {
            return fail(NSLocalizedString("The server didn't say which player you are.", comment: "Netplay error"))
        }
        let session = NetplaySession(host: client.host, port: port, player: player)
        // The game carries on without the lobby connection once it has started
        client.close()
        self.client = nil
        end(with: session)
    }

    private func handleDisconnect(_ error: Error?) {
        let wasConnecting = stage == .connecting && rooms.isEmpty && playerNames.isEmpty
        client = nil
        fail(wasConnecting
            ? String(format: NSLocalizedString("Couldn't reach a netplay server at %@. Check the address and that the server is running.", comment: "Netplay error"), serverField.stringValue)
            : NSLocalizedString("Lost the connection to the netplay server.", comment: "Netplay error"))
    }

    /// Shows the error and goes back to the start, closing any lobby connection.
    private func fail(_ text: String) {
        client?.close()
        client = nil
        rooms = []
        playerNames = []
        roomsTable.reloadData()
        stage = .form
        showStatus(text, isError: true)
    }

    private func end(with session: NetplaySession?) {
        NotificationCenter.default.removeObserver(self)
        if let window, let parent = window.sheetParent {
            parent.endSheet(window)
        }
        let completion = self.completion
        self.completion = nil
        completion?(session)
    }
}

// MARK: - Room list

extension NetplayLobbyWindowController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        rooms.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: rooms[row].roomName ?? "")
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateControls()
    }
}
