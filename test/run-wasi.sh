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
  for name in dedup-off reclaim-off free-off anon-off pause-chunk-off unlist-eager listing-open variant-swap; do
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
elif name == "anon-off":
    # drop every anonymous-principal refusal
    needle = "if (Principal.isAnonymous(caller)) { return #err(#Anonymous) };"
    assert needle in src, "anon anchor missing"
    src = src.replace(needle, "// anon gate disabled")
elif name == "pause-chunk-off":
    # keep pause on start/finish, drop it on the chunk arm only — the exact
    # hole the ruling closed (staged storage grows while paused)
    needle = """    // Pause must block chunk writes too: gating only start and finish would
    // still let staged storage grow while the contract is paused, which is
    // the one thing pause exists to stop.
    if (Admin.isPaused(admin)) { return #err(#Paused) };"""
    assert needle in src, "pause-chunk anchor missing"
    src = src.replace(needle, "    // pause gate on chunk disabled")
elif name == "unlist-eager":
    # restore the pre-v0.4.0 defect: unlist regardless of refcount
    needle = "      if (not Map.containsKey(s.blobs, Blob.compare, hash)) {"
    assert needle in src, "unlist anchor missing"
    src = src.replace(needle, "      if (true) {")
elif name == "variant-swap":
    # The typed-error control. Swap #NotOwner for #NotAdmin AND rewrite
    # errorText so the swapped variant renders the ORIGINAL string. Rendered
    # output is therefore byte-identical, so any assertion that only matches
    # prose still passes: ONLY a named-variant assertion can catch this.
    needle = "if (not Principal.equal(up.owner, caller)) { return #err(#NotOwner) };"
    assert src.count(needle) == 2, f"expected 2 NotOwner sites, found {src.count(needle)}"
    src = src.replace(needle, "if (not Principal.equal(up.owner, caller)) { return #err(#NotAdmin) };")
    txt = '      case (#NotAdmin) "caller is not an admin";'
    assert txt in src, "errorText #NotAdmin arm missing"
    src = src.replace(txt, '      case (#NotAdmin) "not the owner of this upload";')
elif name == "listing-open":
    needle = """    if (not Admin.isAdmin(admin, caller)) { return #err(#NotAdmin) };
    #ok(listPaths(s));"""
    assert needle in src, "listing anchor missing"
    src = src.replace(needle, "    #ok(listPaths(s));")
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
