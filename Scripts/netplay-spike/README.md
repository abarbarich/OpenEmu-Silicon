# N64 netplay spike (Phase 0) — work in progress

Not for merging. Notes so the spike can be picked up again.

## Pieces
- Netplay server: https://github.com/gopher64/gopher64-netplay-server (Go, GPL-3.0, archived).
  Build: `git clone … && go build -o gopher64-netplay-server .`
  Run:   `./gopher64-netplay-server --name "OpenEmu test" --disable-broadcast` (ports 45000+).
- `lobbytool.go`: stand-in for a lobby UI. Copy into the server repo as `cmd/lobbytool/main.go`
  and `go build -o lobbytool ./cmd/lobbytool` (it uses the server's websocket dependency).
- Core: `MupenGameCore -OE_joinNetplayRoomIfRequested` joins the room named in
  `~/Library/Application Support/OpenEmu/netplay-spike.json` ({"host": "...", "port": 45001}),
  retrying for 30 s, taking the first free player slot. DELETE that file after testing, or every
  N64 game waits 30 s at startup.

## Status (2026-09-24)
- Works: core connects, registers as player 1/2, settings sync, save file sync, both emulators run.
- Fixed: settings block padded to 24 bytes (server size); gratuitous input packets (type 3).
- OpenEmu pauses games in the background: turn off `backgroundPause` for tests
  (`defaults write org.openemu.OpenEmu.debug backgroundPause -bool false`).
- OPEN: player 2 falls further and further behind (makes no progress, spins in
  netplay_process).
- Fixed in Compatibility/SDL/SDLStubs.m: SDL_GetTicks returned seconds instead of ms, so the
  10 s input-request timeout was ~2.8 h and a stall never became a disconnect; and
  SDL_CreateThread passed its context through one shared static (racy for workqueue.c, which
  starts several threads in a row). Not yet retested with two players.
- Next suspect: macOS App Nap / timer throttling on the background copy. Test with
  `defaults write <bundle-id> NSAppSleepDisabled -bool YES` on player 2's copy, or keep both
  windows visible.
