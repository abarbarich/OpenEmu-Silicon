// lobbytool: Phase 0 netplay spike helper for OpenEmu.
//
// Stands in for a lobby UI: creates or joins a room on a gopher64-netplay-server and,
// for the host, starts the game once enough players have joined. It then writes
// ~/Library/Application Support/OpenEmu/netplay-spike.json so the OpenEmu N64 core joins
// the room when the game is started, and stays connected until Ctrl-C.
//
//	host:  lobbytool -server 100.x.y.z -md5 <ROM MD5> -name Anton -host -players 2
//	guest: lobbytool -server 100.x.y.z -md5 <ROM MD5> -name Kristian
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"

	"github.com/gorilla/websocket"
)

type roomData struct {
	GameName string `json:"game_name"`
	RoomName string `json:"room_name"`
	MD5      string `json:"MD5"`
	Port     int    `json:"port"`
	Password string `json:"password,omitempty"`
}

type message struct {
	Type           string     `json:"type"`
	Message        string     `json:"message,omitempty"`
	ClientSha      string     `json:"client_sha,omitempty"`
	Emulator       string     `json:"emulator,omitempty"`
	PlayerName     string     `json:"player_name,omitempty"`
	PlayerNames    []string   `json:"player_names,omitempty"`
	Room           *roomData  `json:"room,omitempty"`
	Rooms          []roomData `json:"rooms,omitempty"`
	Accept         int        `json:"accept"`
	NetplayVersion int        `json:"netplay_version,omitempty"`
}

const (
	netplayAPIVersion = 17
	emulatorName      = "OpenEmu"
	clientSha         = "openemu-netplay-spike"
	roomName          = "openemu-spike"
)

func main() {
	server := flag.String("server", "127.0.0.1", "netplay server address (e.g. the host's Tailscale IP)")
	lobbyPort := flag.Int("port", 45000, "lobby port")
	md5 := flag.String("md5", "", "MD5 of the ROM (both players must use the same file)")
	name := flag.String("name", "", "player name")
	host := flag.Bool("host", false, "create the room and start the game")
	players := flag.Int("players", 2, "host only: start once this many players have joined")
	flag.Parse()
	if *md5 == "" || *name == "" {
		flag.Usage()
		os.Exit(2)
	}

	url := fmt.Sprintf("ws://%s:%d/", *server, *lobbyPort)
	ws, _, err := websocket.DefaultDialer.Dial(url, nil)
	if err != nil {
		log.Fatalf("could not connect to lobby at %s: %v", url, err)
	}
	defer ws.Close()

	send := func(m message) {
		m.NetplayVersion = netplayAPIVersion
		m.Emulator = emulatorName
		m.ClientSha = clientSha
		m.PlayerName = *name
		if err := ws.WriteJSON(m); err != nil {
			log.Fatalf("send %s: %v", m.Type, err)
		}
	}
	receive := func() message {
		var m message
		if err := ws.ReadJSON(&m); err != nil {
			log.Fatalf("lobby connection closed: %v", err)
		}
		return m
	}

	var gamePort int
	if *host {
		send(message{Type: "request_create_room", Room: &roomData{RoomName: roomName, GameName: "N64", MD5: *md5}})
		for {
			m := receive()
			if m.Type == "reply_create_room" {
				if m.Accept != 0 || m.Room == nil {
					log.Fatalf("could not create room: %s", m.Message)
				}
				gamePort = m.Room.Port
				log.Printf("room created on port %d; waiting for %d players", gamePort, *players)
				break
			}
		}
		send(message{Type: "request_players", Room: &roomData{Port: gamePort}})
		for {
			m := receive()
			if m.Type == "reply_players" {
				joined := 0
				for _, p := range m.PlayerNames {
					if p != "" {
						joined++
					}
				}
				log.Printf("players: %v", m.PlayerNames)
				if joined >= *players {
					send(message{Type: "request_begin_game", Room: &roomData{Port: gamePort}})
				}
			}
			if m.Type == "reply_begin_game" {
				if m.Accept != 0 {
					log.Fatalf("could not start game: %s", m.Message)
				}
				break
			}
		}
	} else {
		send(message{Type: "request_get_rooms"})
		for gamePort == 0 {
			m := receive()
			if m.Type == "reply_get_rooms" {
				for _, r := range m.Rooms {
					if r.RoomName == roomName {
						gamePort = r.Port
					}
				}
				if gamePort == 0 {
					log.Fatalf("no %q room on the server; start the host first", roomName)
				}
			}
		}
		send(message{Type: "request_join_room", Room: &roomData{Port: gamePort, MD5: *md5}})
		for {
			m := receive()
			if m.Type == "reply_join_room" {
				if m.Accept != 0 {
					log.Fatalf("could not join room: %s", m.Message)
				}
				log.Printf("joined room on port %d; waiting for the host to start", gamePort)
				// The lobby only sends the player list when asked; this tells the host we're in
				send(message{Type: "request_players", Room: &roomData{Port: gamePort}})
			}
			if m.Type == "reply_players" {
				log.Printf("players: %v", m.PlayerNames)
			}
			if m.Type == "reply_begin_game" {
				break
			}
		}
	}

	support, err := os.UserConfigDir() // ~/Library/Application Support on macOS
	if err != nil {
		log.Fatal(err)
	}
	configPath := filepath.Join(support, "OpenEmu", "netplay-spike.json")
	config, _ := json.Marshal(map[string]any{"host": *server, "port": gamePort})
	if err := os.WriteFile(configPath, config, 0o644); err != nil {
		log.Fatalf("could not write %s: %v", configPath, err)
	}
	log.Printf("game started. Wrote %s. Now start the game in OpenEmu. Ctrl-C when done.", configPath)

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt)
	go func() {
		for {
			var m message
			if err := ws.ReadJSON(&m); err != nil {
				return
			}
		}
	}()
	<-stop
	os.Remove(configPath)
	log.Printf("removed %s", configPath)
}
