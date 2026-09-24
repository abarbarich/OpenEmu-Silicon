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

/// A started netplay room that a game document joins: the server, the room's game port,
/// and this player's number (1-4) in the room.
@objc final class NetplaySession: NSObject {
    let host: String
    let port: Int
    let player: Int

    init(host: String, port: Int, player: Int) {
        self.host = host
        self.port = port
        self.player = player
    }
}

/// One message of the gopher64-netplay-server lobby protocol (JSON over a WebSocket).
/// Requests and replies share this shape; unused fields are left out of the JSON.
struct NetplayLobbyMessage: Codable, Equatable {

    struct Room: Codable, Equatable {
        var gameName: String?
        var roomName: String?
        var md5: String?
        var port: Int?
        var isProtected: Bool?

        enum CodingKeys: String, CodingKey {
            case gameName = "game_name"
            case roomName = "room_name"
            case md5 = "MD5"
            case port
            case isProtected = "protected"
        }
    }

    var type: String
    var message: String?
    var clientSHA: String?
    var emulator: String?
    var playerName: String?
    var playerNames: [String]?
    var room: Room?
    var rooms: [Room]?
    /// 0 when the server accepted the request.
    var accept: Int?
    var netplayVersion: Int?

    enum CodingKeys: String, CodingKey {
        case type, message
        case clientSHA = "client_sha"
        case emulator
        case playerName = "player_name"
        case playerNames = "player_names"
        case room, rooms, accept
        case netplayVersion = "netplay_version"
    }

    init(type: String, room: Room? = nil) {
        self.type = type
        self.room = room
    }
}

/// Talks to the lobby of a gopher64-netplay-server: creating, listing and joining rooms,
/// and starting the game. The game itself then connects to the room's port from the core.
///
/// All callbacks arrive on the main queue.
final class NetplayLobbyClient {

    /// The lobby protocol version the server checks (gopher64-netplay-server's NetplayAPIVersion).
    static let apiVersion = 17
    static let emulatorName = "OpenEmu"
    static let defaultLobbyPort = 45000

    enum MessageType {
        static let createRoom = "request_create_room"
        static let createRoomReply = "reply_create_room"
        static let getRooms = "request_get_rooms"
        static let getRoomsReply = "reply_get_rooms"
        static let joinRoom = "request_join_room"
        static let joinRoomReply = "reply_join_room"
        static let players = "request_players"
        static let playersReply = "reply_players"
        static let beginGame = "request_begin_game"
        static let beginGameReply = "reply_begin_game"
    }

    /// Server host (no port), as typed by the player. The game connects here too.
    let host: String
    let lobbyPort: Int
    let playerName: String

    var onMessage: ((NetplayLobbyMessage) -> Void)?
    /// Called once when the connection fails or the server closes it; not called after close().
    var onDisconnect: ((Error?) -> Void)?

    private let session = URLSession(configuration: .ephemeral)
    private var task: URLSessionWebSocketTask?
    private var isClosed = false

    /// Rooms only accept players running the same OpenEmu build, so different versions can't
    /// end up in one game and desync.
    static var clientSHA: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "OpenEmu \(version) (\(build))"
    }

    /// Splits "host" or "host:port" into its parts; nil when the address can't be used.
    static func parseAddress(_ address: String) -> (host: String, port: Int)? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" "), !trimmed.contains("/") else { return nil }

        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            return (trimmed, defaultLobbyPort)
        case 2:
            guard !parts[0].isEmpty, let port = Int(parts[1]), (1...65535).contains(port) else { return nil }
            return (String(parts[0]), port)
        default:
            return nil
        }
    }

    /// This player's number (1-4): the server lists players by their slot in the room.
    static func playerNumber(of name: String, in playerNames: [String]) -> Int? {
        guard let index = playerNames.firstIndex(of: name), index < 4 else { return nil }
        return index + 1
    }

    init?(address: String, playerName: String) {
        guard let (host, port) = Self.parseAddress(address) else { return nil }
        self.host = host
        self.lobbyPort = port
        self.playerName = playerName
    }

    func connect() {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host
        components.port = lobbyPort
        components.path = "/"
        guard let url = components.url else {
            finish(with: URLError(.badURL))
            return
        }

        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveNext()
    }

    func close() {
        isClosed = true
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session.invalidateAndCancel()
    }

    func send(_ message: NetplayLobbyMessage) {
        var message = message
        message.netplayVersion = Self.apiVersion
        message.emulator = Self.emulatorName
        message.clientSHA = Self.clientSHA
        message.playerName = playerName

        guard let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8)
        else { return }

        task?.send(.string(text)) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async { self?.finish(with: error) }
        }
    }

    // MARK: - Private

    private func receiveNext() {
        task?.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.isClosed else { return }
                switch result {
                case .success(let frame):
                    if let message = Self.decode(frame) {
                        self.onMessage?(message)
                    }
                    self.receiveNext()
                case .failure(let error):
                    self.finish(with: error)
                }
            }
        }
    }

    private static func decode(_ frame: URLSessionWebSocketTask.Message) -> NetplayLobbyMessage? {
        let data: Data?
        switch frame {
        case .string(let text): data = text.data(using: .utf8)
        case .data(let bytes): data = bytes
        @unknown default: data = nil
        }
        return data.flatMap { try? JSONDecoder().decode(NetplayLobbyMessage.self, from: $0) }
    }

    private func finish(with error: Error?) {
        guard !isClosed else { return }
        close()
        onDisconnect?(error)
    }
}
