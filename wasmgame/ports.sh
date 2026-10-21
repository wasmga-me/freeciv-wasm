# Emscripten ports that download GitHub archive links, which some networks block:
# this clones each at the same tag into the emsdk cache and marks it unpacked.
# Usage: port <name> <repo> <tag> <dir in the archive> <url emscripten fetches>
port() {
  cache=$(em-config CACHE)/ports
  dir="$cache/$1"
  if [ "$(cat "$dir/.emscripten_url" 2>/dev/null)" = "$5" ]; then return; fi
  rm -rf "$dir"
  mkdir -p "$dir"
  git -c advice.detachedHead=false clone -q --depth 1 -b "$3" "https://github.com/$2.git" "$dir/$4"
  echo "$5" > "$dir/.emscripten_url"
}
