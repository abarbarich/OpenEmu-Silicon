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
- FIXED (see below): player 2 fell further and further behind, spinning in netplay_process.
- Fixed in Compatibility/SDL/SDLStubs.m: SDL_GetTicks returned seconds instead of ms, so the
  10 s input-request timeout was ~2.8 h and a stall never became a disconnect; and
  SDL_CreateThread passed its context through one shared static (racy for workqueue.c, which
  starts several threads in a row).
- Retest 2026-09-24 (release OpenEmu.app as P2, Debug build as P1, Diddy Kong Racing): P2 no longer
  hangs; both stay connected with inputs flowing. But P2 runs slower: server countLag for P2 grew
  0 -> ~1300-1500 frames in 90 s while P1 stayed at 0, and the games visibly desync (server fills
  P2's missing inputs). The two copies weren't set up the same way (release app still had
  backgroundPause on).
- Retest with two Debug instances (`open -n` on the Debug OpenEmu.app, same ROM): both players
  stayed within ~1 frame (countLag 0-1.03, bufferHealth 2-3) over 90 s, no disconnects or desyncs,
  and the games looked in sync on screen. The drift came from the release app's setup, not the
  netplay code. Phase 0 now works on one Mac; test with two identically set up copies.
- Next: Phase 1 — a real lobby UI in OpenEmu instead of lobbytool + netplay-spike.json.
