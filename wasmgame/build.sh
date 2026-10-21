#!/bin/sh
# Builds Freeciv (https://www.freeciv.org/, GPL-2.0-or-later) for the site,
# from the 3.2.6 release with the Emscripten support it carries
# (platforms/emscripten), as two programs: the SDL2 client, which runs on the
# play page, and the server, which runs in a Web Worker (server-worker.js).
# The changes are in freeciv.diff beside this script:
# - the client and the server talk over MessagePorts instead of TCP
#   (platforms/emscripten/wgpipe.js stands in for Emscripten's WebSocket
#   sockets), select() sleeps until a port has news, and the client asks the
#   page to start the server instead of forking one; both build without
#   threads, so the page needs no cross-origin isolation;
# - the server gives the page's client full control of the game, as it does
#   for a client that started it, since the two can't share the file that
#   proves it;
# - the server hands each save to the page, which keeps the player's saved
#   games and the newest autosave; for Resume the page asks the server to
#   save the game in progress (wg_snapshot), and starts the client with that
#   save (--file), which then carries on playing;
# - the page sizes the game (Module.wgSize) and owns full screen: the
#   Fullscreen and Screen resolution options are left out;
# - the main menu leaves out Join Game, Join Pubserver, Join LAN Server and
#   Quit, and the options dialog its Quit button: the game is single player,
#   and the page is its window, so there is nothing to quit to;
# - the client writes its options when the page asks (wg_save_options), since
#   it never quits; the page holds it still with Module.wgHeld.
# main() of each is run by the play page (INVOKE_RUN=0).
#
# The data zip holds what the two read for a civ2civ3 game: the ruleset,
# nations and flags, a tileset for each kind of map (Hexemplio for the default
# isometric hex map, Amplio2 for square maps, Hex2T for flat hex maps) with
# their buildings, wonders and misc graphics, the SDL2 client's theme with its
# DejaVu Sans font, the help texts, and the standard sounds and menu music.
# Left out: the other rulesets and tilesets (Trident only for its units),
# scenarios, the CJK fonts (the client shows English only) and the art sources
# under data/graphics.
#
# Needs git, a host C compiler, meson, ninja, python3, zip and emsdk 4.0.7
# (source emsdk_env.sh first).
# Usage: sh build.sh [work dir]
# Writes freeciv-sdl2.js/.wasm, freeciv-server.js/.wasm and server-worker.js
# next to this script, and the data zip for R2 to <work dir>/r2/freeciv/
# (upload it to wasmgame-files under the same key). For a newer Freeciv, copy
# this folder to freeciv-<new rev>-p1 and change the tag below; a change to
# the build here takes the next -p number.
set -eu

FREECIV_TAG=R3_2_6
FREECIV_REV=2c4304c742aa81f1d73a5d604ed83237d57804a1
EMSDK_VERSION=4.0.7

here=$(cd "$(dirname "$0")" && pwd)
work=${1:-${TMPDIR:-/tmp}/freeciv-build}
src=$work/freeciv

case "$(emcc --version | head -1)" in
  *" $EMSDK_VERSION "*) ;;
  *) echo "warning: built and tested with emsdk $EMSDK_VERSION" >&2 ;;
esac

# Emscripten fetches these ports as GitHub archives; clone them instead.
. "$here/ports.sh"
port zlib madler/zlib v1.3.1 zlib-1.3.1 https://github.com/madler/zlib/archive/refs/tags/v1.3.1.tar.gz
port sdl2 libsdl-org/SDL release-2.32.0 SDL-release-2.32.0 https://github.com/libsdl-org/SDL/archive/release-2.32.0.zip
port sdl2_image libsdl-org/SDL_image release-2.6.0 SDL_image-release-2.6.0 https://github.com/libsdl-org/SDL_image/archive/refs/tags/release-2.6.0.zip
port sdl2_ttf libsdl-org/SDL_ttf release-2.20.2 SDL_ttf-release-2.20.2 https://github.com/libsdl-org/SDL_ttf/archive/release-2.20.2.zip
port sdl2_mixer libsdl-org/SDL_mixer release-2.8.0 SDL_mixer-release-2.8.0 https://github.com/libsdl-org/SDL_mixer/archive/release-2.8.0.zip
port freetype freetype/freetype VER-2-13-3 freetype-VER-2-13-3 https://github.com/freetype/freetype/archive/VER-2-13-3.zip
port ogg emscripten-ports/ogg version_1 Ogg-version_1 https://github.com/emscripten-ports/ogg/archive/version_1.zip
port vorbis emscripten-ports/vorbis version_1 Vorbis-version_1 https://github.com/emscripten-ports/vorbis/archive/version_1.zip
# SDL2_gfx is pinned to a commit, not a tag.
gfx_rev=2b147ffef10ec541d3eace326eafe11a54e635f8
gfx=$(em-config CACHE)/ports/sdl2_gfx
gfx_src=$gfx/sdl2_gfx-$gfx_rev
gfx_url=https://github.com/svn2github/sdl2_gfx/archive/$gfx_rev.zip
if [ "$(cat "$gfx/.emscripten_url" 2>/dev/null)" != "$gfx_url" ]; then
  rm -rf "$gfx"
  mkdir -p "$gfx_src"
  git -C "$gfx_src" init -q
  git -C "$gfx_src" fetch -q --depth 1 https://github.com/svn2github/sdl2_gfx.git "$gfx_rev"
  git -C "$gfx_src" -c advice.detachedHead=false checkout -q FETCH_HEAD
  echo "$gfx_url" > "$gfx/.emscripten_url"
fi

mkdir -p "$work"
# A checkout left by an earlier build is reset, so this folder's diff is the one applied.
[ -d "$src" ] || git clone -q --depth 1 -b "$FREECIV_TAG" https://github.com/freeciv/freeciv.git "$src"
[ "$(git -C "$src" rev-parse HEAD)" = "$FREECIV_REV" ] || { echo "$FREECIV_TAG is not $FREECIV_REV" >&2; exit 1; }
git -C "$src" checkout -q -f "$FREECIV_REV"
git -C "$src" clean -q -fdx
git -C "$src" apply "$here/freeciv.diff"

# tolua, which writes the Lua bindings, for this computer.
host=$work/host
mkdir -p "$host"
dep=$src/dependencies
# shellcheck disable=SC2046
cc -O1 -o "$host/tolua" -I"$dep/lua-5.4/src" -I"$dep/tolua-5.2/include" -I"$dep/tolua-5.2/src/lib" \
  "$dep"/tolua-5.2/src/bin/tolua.c "$dep"/tolua-5.2/src/bin/toluabind.c "$dep"/tolua-5.2/src/lib/*.c \
  $(ls "$dep"/lua-5.4/src/*.c | grep -v -e '/lua\.c$' -e '/luac\.c$' -e '/onelua\.c$') -lm 2> /dev/null
PATH=$host:$PATH

# The client and the server.
emroot=$(dirname "$(which emcc)")
sed -e "s,<EMSDK_ROOT>/upstream/emscripten,$emroot," "$src/platforms/emscripten/setups/cross-ems.tmpl" > "$work/cross.txt"
rm -rf "$work/build"
meson setup "$work/build" "$src" --cross-file="$work/cross.txt" -Ddefault_library=static \
  -Ddebug=false -Doptimization=s -Daudio=sdl2 -Dclients=sdl2 -Dserver=enabled \
  -Dmwand=false -Dtools=[] -Dfcmp=[] -Dnls=false -Dreadline=false > /dev/null
ninja -C "$work/build" freeciv-sdl2.js freeciv-server.js
cp "$work/build/freeciv-sdl2.js" "$work/build/freeciv-sdl2.wasm" \
  "$work/build/freeciv-server.js" "$work/build/freeciv-server.wasm" \
  "$src/platforms/emscripten/server-worker.js" "$here/"

# The data zip.
stage=$work/data
rm -rf "$stage"
mkdir -p "$stage/data/flags" "$stage/data/themes/gui-sdl2/human"
d=$src/data
cp "$d/helpdata.txt" "$d/civ2civ3.modpack" "$d/amplio2.tilespec" "$d/hexemplio.tilespec" "$d/hex2t.tilespec" "$d/stdsounds.soundspec" "$d/stdmusic.musicspec" "$stage/data/"
for dir in civ2civ3 default nation amplio2 hexemplio hex2t trident misc buildings wonders override stdsounds stdmusic; do
  cp -r "$d/$dir" "$stage/data/"
done
cp "$d"/flags/*.png "$stage/data/flags/"
for f in "$d"/themes/gui-sdl2/human/*; do
  case "$f" in
    */fireflysung.ttf|*/sazanami-gothic.ttf|*/UnDotum.ttf|*/COPYING.fireflysung|*/COPYING.sazanami|*/COPYING.UnDotum) ;;
    *) cp "$f" "$stage/data/themes/gui-sdl2/human/" ;;
  esac
done
find "$stage" -name Makefile.am -delete
cp "$src/COPYING" "$src/AUTHORS" "$stage/"
find "$stage" -exec touch -d 2000-01-01T00:00:00Z {} +
mkdir -p "$work/r2/freeciv"
rm -f "$work/data.zip"
(cd "$stage" && find . -type f | LC_ALL=C sort | sed 's|^\./||' | TZ=UTC zip -q -X -9 -@ "$work/data.zip")
hash=$(sha256sum "$work/data.zip" | cut -c1-12)
mv "$work/data.zip" "$work/r2/freeciv/data-$hash.zip"
ls -l "$work/r2/freeciv/data-$hash.zip"
