#!/usr/bin/env bash
# run-replica.sh — the storage-independence and upgrade-survival suites
# (upgrade survival through a REAL dfx local-replica actor upgrade).
# Bounds live in test/replica/run-replica.py. LOCAL replica only — no
# network deploy of any kind.
set -euo pipefail
cd "$(dirname "$0")/replica"

MOC=~/.cache/mops/moc/1.4.1/moc

# Build the integration actor with the lib's pinned moc (dfx's bundled moc
# is 1.1.0, which rejects the registry core@2.5.0 artifact — known trap).
$MOC --package core ../../.mops/core@2.5.0/src -o media_app.wasm --idl app.mo
# Heap-measurement build (the storage-independence suite): classical persistence + copying GC
# + --force-gc = a FULL collection after every update message, so
# heapSize() reports LIVE bytes. The EOP build above keeps the default
# incremental GC (whose lazily-swept garbage is what the first measurement
# attempt read — 35 MB of transient chunk/assembly arrays).
$MOC --legacy-persistence --copying-gc --force-gc --package core ../../.mops/core@2.5.0/src -o media_app_heap.wasm app.mo 2> /dev/null

dfx stop > /dev/null 2>&1 || true
dfx start --clean --background > /dev/null 2>&1
trap 'dfx stop > /dev/null 2>&1 || true' EXIT

dfx canister create media_app > /dev/null
dfx canister create media_app_heap > /dev/null
dfx canister install media_app --wasm media_app.wasm > /dev/null
dfx canister install media_app_heap --wasm media_app_heap.wasm > /dev/null

python3 run-replica.py
