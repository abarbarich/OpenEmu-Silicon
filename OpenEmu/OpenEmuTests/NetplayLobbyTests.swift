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

import XCTest
import OpenEmuKit
@testable import OpenEmu

final class NetplayLobbyTests: XCTestCase {

    // MARK: - Server address

    func testAddressWithoutPortUsesDefaultLobbyPort() {
        let parsed = NetplayLobbyClient.parseAddress("192.168.1.20")
        XCTAssertEqual(parsed?.host, "192.168.1.20")
        XCTAssertEqual(parsed?.port, NetplayLobbyClient.defaultLobbyPort)
    }

    func testAddressWithPortAndSurroundingSpaces() {
        let parsed = NetplayLobbyClient.parseAddress("  myserver.local:46000 ")
        XCTAssertEqual(parsed?.host, "myserver.local")
        XCTAssertEqual(parsed?.port, 46000)
    }

    func testUnusableAddressesAreRejected() {
        for address in ["", "   ", "host:", ":45000", "host:0", "host:70000", "host:abc", "ws://host", "a b", "1:2:3"] {
            XCTAssertNil(NetplayLobbyClient.parseAddress(address), "\"\(address)\" should be rejected")
        }
    }

    // MARK: - Player number

    func testPlayerNumberIsTheSlotInTheServersList() {
        let names = ["Anton", "", "Kristian", ""]
        XCTAssertEqual(NetplayLobbyClient.playerNumber(of: "Anton", in: names), 1)
        XCTAssertEqual(NetplayLobbyClient.playerNumber(of: "Kristian", in: names), 3)
        XCTAssertNil(NetplayLobbyClient.playerNumber(of: "Nobody", in: names))
    }

    // MARK: - Wire format

    func testRequestUsesTheServersFieldNamesAndOmitsUnsetFields() throws {
        var message = NetplayLobbyMessage(type: NetplayLobbyClient.MessageType.joinRoom,
                                          room: .init(md5: "abc123", port: 45001))
        message.playerName = "Anton"
        message.netplayVersion = NetplayLobbyClient.apiVersion

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "request_join_room")
        XCTAssertEqual(json["player_name"] as? String, "Anton")
        XCTAssertEqual(json["netplay_version"] as? Int, 17)
        XCTAssertNil(json["rooms"])
        XCTAssertNil(json["accept"])

        let room = try XCTUnwrap(json["room"] as? [String: Any])
        XCTAssertEqual(room["MD5"] as? String, "abc123")
        XCTAssertEqual(room["port"] as? Int, 45001)
        XCTAssertNil(room["room_name"])
    }

    func testDecodesServerReplies() throws {
        let rooms = """
        {"type":"reply_get_rooms","accept":0,"rooms":[
          {"features":null,"game_name":"Diddy Kong Racing","protected":false,
           "room_name":"Anton's Diddy Kong Racing","MD5":"b31f8cca","port":45001}]}
        """
        let reply = try JSONDecoder().decode(NetplayLobbyMessage.self, from: Data(rooms.utf8))
        XCTAssertEqual(reply.type, NetplayLobbyClient.MessageType.getRoomsReply)
        XCTAssertEqual(reply.accept, 0)
        XCTAssertEqual(reply.rooms?.first?.roomName, "Anton's Diddy Kong Racing")
        XCTAssertEqual(reply.rooms?.first?.md5, "b31f8cca")
        XCTAssertEqual(reply.rooms?.first?.port, 45001)
        XCTAssertEqual(reply.rooms?.first?.isProtected, false)

        let players = #"{"type":"reply_players","accept":0,"player_names":["Anton","Kristian","",""]}"#
        let playersReply = try JSONDecoder().decode(NetplayLobbyMessage.self, from: Data(players.utf8))
        XCTAssertEqual(playersReply.playerNames, ["Anton", "Kristian", "", ""])
    }

    // MARK: - Startup info

    func testStartupInfoCarriesNetplayRoomToTheHelper() throws {
        let url = URL(fileURLWithPath: "/tmp/game.z64")
        let info = OEGameStartupInfo(romURL: url, romMD5: "abc", romHeader: "", romSerial: "",
                                     systemRegion: "North America", displayModeInfo: nil,
                                     shaderURL: url, shaderParameters: [:],
                                     corePluginURL: url, systemPluginURL: url,
                                     netplayHost: "192.168.1.20", netplayPort: 45001, netplayPlayer: 2)

        let data = try NSKeyedArchiver.archivedData(withRootObject: info, requiringSecureCoding: true)
        let decoded = try XCTUnwrap(NSKeyedUnarchiver.unarchivedObject(ofClass: OEGameStartupInfo.self, from: data))
        XCTAssertEqual(decoded.netplayHost, "192.168.1.20")
        XCTAssertEqual(decoded.netplayPort, 45001)
        XCTAssertEqual(decoded.netplayPlayer, 2)
    }

    func testStartupInfoWithoutNetplayStaysOffline() throws {
        let url = URL(fileURLWithPath: "/tmp/game.z64")
        let info = OEGameStartupInfo(romURL: url, romMD5: "abc", romHeader: "", romSerial: "",
                                     systemRegion: "North America", displayModeInfo: nil,
                                     shaderURL: url, shaderParameters: [:],
                                     corePluginURL: url, systemPluginURL: url)

        let data = try NSKeyedArchiver.archivedData(withRootObject: info, requiringSecureCoding: true)
        let decoded = try XCTUnwrap(NSKeyedUnarchiver.unarchivedObject(ofClass: OEGameStartupInfo.self, from: data))
        XCTAssertNil(decoded.netplayHost)
        XCTAssertEqual(decoded.netplayPort, 0)
    }
}
