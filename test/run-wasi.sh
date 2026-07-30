#!/usr/bin/env bash
# run-wasi.sh — the Media.mo wasi suite driver (policy, region behaviour,
# image validation, SHA vectors). PASS bound: every suite compiles and exits
# 0 with its final "…PASS"/"…as expected" line printed.
#
# --teeth: prove the suite can fail — compile the SAME suite against
# three deliberately-broken copies of Media.mo (dedup off, free-list reclaim
# off, refcount-free off) and require every one of them to go RED.
set -euo pipefail
cd "$(dirname "$0")/.."

MOC=~/.cache/mops/moc/1.4.1/moc
WASMTIME=~/.cache/mops/wasmtime/45.0.2/wasmtime
CORE=.mops/core@2.5.0/src
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

run_suite() { # $1 = source file, $2 = src dir for Media/Admin
  local name wasm
  name=$(basename "$1" .mo)
  wasm="$OUT/$name.wasm"
  # Compile from a staged tree so the suite's relative ../../src imports
  # resolve against the (possibly patched) module copy in $2.
  local stage="$OUT/stage-$name-$RANDOM"
  mkdir -p "$stage/test/wasi" "$stage/src"
  cp "$2"/*.mo "$stage/src/"
  cp test/wasi/*.mo "$stage/test/wasi/"
  cp "$1" "$stage/test/wasi/$(basename "$1")"
  (cd "$stage" && $MOC -wasi-system-api --package core "$OLDPWD/$CORE" \
    -o "$wasm" "test/wasi/$(basename "$1")") 2> "$OUT/moc-$name.log" || {
    cat "$OUT/moc-$name.log" >&2; return 2; }
  timeout 600 $WASMTIME run "$wasm"
}

if [[ "${1:-}" == "--teeth" ]]; then
  declare -A PATCHES=(
    [dedup-off]='s|        if (meta.refcount < 0xFFFF_FFFF) { meta.refcount += 1 };\n        return #ok;|        if (meta.refcount < 0xFFFF_FFFF) { meta.refcount += 1 };|'
    [reclaim-off]='s|func regionFree(s : Store, offset : Nat64, len : Nat64) {\n    if (len == 0) { return };|func regionFree(s : Store, offset : Nat64, len : Nat64) {\n    if (true) { return };|'
    [free-off]='s|        if (meta.refcount == 0) {|        if (false) {|'
  )
  for name in dedup-off reclaim-off free-off; do
    patched="$OUT/patched-$name"
    mkdir -p "$patched"
    cp src/*.mo "$patched/"
    python3 - "$patched/Media.mo" "$name" << 'EOF'
import sys
path, name = sys.argv[1], sys.argv[2]
src = open(path).read()
if name == "dedup-off":
    needle = "        if (meta.refcount < 0xFFFF_FFFF) { meta.refcount += 1 };\n        return #ok;"
    assert needle in src, "dedup anchor missing"
    src = src.replace(needle, "        if (meta.refcount < 0xFFFF_FFFF) { meta.refcount += 1 };")
elif name == "reclaim-off":
    needle = "  func regionFree(s : Store, offset : Nat64, len : Nat64) {\n    if (len == 0) { return };"
    assert needle in src, "reclaim anchor missing"
    src = src.replace(needle, "  func regionFree(s : Store, offset : Nat64, len : Nat64) {\n    if (len >= 0) { return };")
elif name == "free-off":
    needle = "        if (meta.refcount == 0) {"
    assert needle in src, "free anchor missing"
    src = src.replace(needle, "        if (false) {")
open(path, "w").write(src)
EOF
    if run_suite test/wasi/Policy.mo "$patched" > "$OUT/teeth-$name.log" 2>&1; then
      echo "TEETH FAILURE: policy suite stayed GREEN against broken Media.mo ($name)" >&2
      exit 1
    else
      echo "TEETH OK ($name): suite went RED against the broken copy — $(grep -m1 'assertion failed\|UNEXPECTED\|FAIL' "$OUT/teeth-$name.log" | head -c 100)"
    fi
  done
  exit 0
fi

run_suite test/wasi/Sha.mo src
run_suite test/wasi/Policy.mo src | tail -1
run_suite test/wasi/Image.mo src | tail -1
echo "WASI SUITE GREEN"
