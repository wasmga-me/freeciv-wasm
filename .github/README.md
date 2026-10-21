# Freeciv in the browser

This fork is the web build of [Freeciv](https://github.com/freeciv/freeciv) that runs on wasmga.me. Play it at **https://wasmga.me/games/freeciv**.

It is Freeciv 3.2.6 built with Emscripten as two programs: the SDL2 client, which runs on the page, and the server, which runs in a Web Worker. They talk over MessagePorts instead of TCP, and neither uses threads. It is for single player: joining other servers and Quit are left out, the page owns full screen and sizes the game, the server hands each save to the page, and the client can start from a save the server wrote for the page to resume a game.

## What's here

- Branch `claude/project-thread-h95krr` (this one) starts with one commit holding the tree of upstream tag `R3_2_6` ([`2c4304c`](https://github.com/freeciv/freeciv/commit/2c4304c742aa81f1d73a5d604ed83237d57804a1)), with our changes on top as commits, so `git log` and the diff against the first commit show everything we changed.
- [`wasmgame/`](../wasmgame) holds the build script and the same changes as `freeciv.diff` against that tag. `build.sh` starts from a fresh upstream checkout, applies it and builds, and its header comment lists each change.

## Building

Needs git, a host C compiler, meson, ninja, python3, zip and emsdk 4.0.7 (source `emsdk_env.sh` first).

```sh
sh wasmgame/build.sh /tmp/freeciv-build
```

It builds tolua for the host, then the client and the server, and writes `freeciv-sdl2.js/.wasm`, `freeciv-server.js/.wasm` and `server-worker.js` next to the script. Under `<work dir>/r2/freeciv/` goes the data zip: the civ2civ3 ruleset, a tileset for each kind of map, the SDL2 theme, the help texts, sounds and music.

## Running it

The page runs the client's `main()` itself (`INVOKE_RUN=0`), after writing the data zip to `/` and the player's files to `/home/web_user/.freeciv`. When the client starts a game it calls `Module.wgStartServer(args)`; the page starts `platforms/emscripten/server-worker.js` with those arguments and the files the server reads, and `Module.wgPipe.connect(port)` hands the client a MessagePort to it (`platforms/emscripten/wgpipe.js`). The worker posts `saved` with each save's bytes, and on `snapshot` saves the game in progress to `/wg/`. The client follows `Module.wgSize`, `wg_save_options()` writes its options, `wg_playing()` says whether a game is running, and `--file <save>` starts it from a save.

## Licence

Same as upstream: GPL-2.0-or-later (see `COPYING`). Our changes are under the same licence as the files they change.
