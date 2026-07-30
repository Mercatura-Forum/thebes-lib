#!/usr/bin/env bash
# run-all.sh — the FULL Media.mo test suite, one command.
# PASS = every gate below green. Each gate prints its own bound.
#   tree reference check (+ --teeth RED proof)
#   policy / image / region behaviour under wasi (+ --teeth broken-copy RED)
#   storage independence + real upgrade survival (dfx local replica)
#   regression: existing mops test suite, moc --check on every
#       module, zero mo:base imports anywhere in src/.
set -euo pipefail
cd "$(dirname "$0")/.."

MOC=~/.cache/mops/moc/1.4.1/moc

echo "═══ regression ═══"
# Zero mo:base imports (mo:core discipline).
if grep -rn 'mo:base' src/ test/*.mo test/wasi/*.mo test/replica/*.mo 2>/dev/null; then
  echo "RED: mo:base import found" >&2; exit 1
fi
echo "zero mo:base imports: OK"
# Every module type-checks clean (warnings are errors here).
for f in src/*.mo; do
  out=$($MOC --check --package core .mops/core@2.5.0/src "$f" 2>&1)
  if [[ -n "$out" ]]; then
    echo "RED: moc --check not clean for $f:" >&2; echo "$out" >&2; exit 1
  fi
done
echo "moc --check clean on $(ls src/*.mo | wc -l) modules: OK"
# Existing suite (Invoices) still green under the pinned toolchain.
mops test | tail -1

echo "═══ certified-tree reference check ═══"
test/run-tree-reference.sh
TEETH_OUT=$(test/run-tree-reference.sh --teeth)
echo "$TEETH_OUT" | head -1

echo "═══ policy + image suites (wasi) ═══"
test/run-wasi.sh
test/run-wasi.sh --teeth

echo "═══ replica suite ═══"
LOG=$(mktemp)
if test/run-replica.sh > "$LOG" 2>&1; then
  grep -E "PASS heap delta|GREEN" "$LOG"
else
  cat "$LOG" >&2; rm -f "$LOG"; exit 1
fi
rm -f "$LOG"

echo "═══ FULL SUITE GREEN ═══"
