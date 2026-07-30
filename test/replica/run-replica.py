#!/usr/bin/env python3
"""The upgrade-survival suite (upgrade survival — REAL actor upgrade on a dfx local
replica, not simulated) + the storage-independence suite (heap-independence, measured across
messages where the per-message GC runs).

PASS bounds (committed before running):
  A. heap delta across storing 4.5 MiB of photos  < 1_500_000 bytes while
     region-stored bytes grow by exactly 4_718_592 (9 × 512 KiB).
  B. After `--mode upgrade --wasm-memory-persistence keep`:
     root hex, listPaths, storageStats, and the FULL http_request reply for
     a stored photo are ALL byte-identical to their pre-upgrade values; an
     in-flight staged upload (1 of 2 chunks) still reports received=[0]
     and can be completed; deletePhoto still returns true (ownership
     survived) and reclaims into the free list.

Run from test/replica/ with the replica already started (run-replica.sh
orchestrates).
"""
import hashlib
import subprocess
import sys
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(HERE, "..", "image-fixtures")
CHUNK = 32768


def dfx(*args, arg_file=None, input_arg=None):
    cmd = ["dfx"] + list(args)
    if input_arg is not None:
        af = os.path.join(HERE, ".arg.txt")
        with open(af, "w") as f:
            f.write(input_arg)
        cmd += ["--argument-file", af]
    r = subprocess.run(cmd, cwd=HERE, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"DFX FAIL: {' '.join(cmd)}\n{r.stdout}\n{r.stderr}")
        sys.exit(1)
    return r.stdout.strip()


CANISTER = "media_app"


def call(method, arg=None):
    if arg is None:
        return dfx("canister", "call", CANISTER, method)
    return dfx("canister", "call", CANISTER, method, input_arg=arg)


def blob_lit(data: bytes) -> str:
    return 'blob "' + "".join(f"\\{b:02x}" for b in data) + '"'


def padded(base: bytes, target: int, seed: int) -> bytes:
    body = base + bytes((seed + i) & 0xFF for i in range(target - len(base)))
    assert len(body) == target
    return body


def upload(uid, cls, ct, body):
    chunks = [body[i:i + CHUNK] for i in range(0, len(body), CHUNK)] or [b""]
    call("startUpload", f'("{uid}", {cls}, "{ct}", {len(chunks)} : nat)')
    for i, c in enumerate(chunks):
        call("putChunk", f'("{uid}", {i} : nat, {blob_lit(c)})')
    return call("finishUpload", f'("{uid}")')


def get_nat(reply, field):
    pat = rf"{field} = ([\d_]+)" if field else r"\(([\d_]+) : nat\)"
    m = re.search(pat, reply)
    assert m, f"{field} not in {reply}"
    return int(m.group(1).replace("_", ""))


failures = []


def check(label, cond, detail=""):
    tag = "PASS" if cond else "FAIL"
    print(f"  {tag} {label} {detail}")
    if not cond:
        failures.append(label)


jpeg = open(os.path.join(FIX, "jpeg_ok_64.bin"), "rb").read()
png = open(os.path.join(FIX, "png_ok_64.bin"), "rb").read()

print("— wiring: owner claim, user register, logo + avatar —")
me = dfx("identity", "get-principal")
check("claimOwner", call("claimOwner") == "(true)")
call("register", '("integration-user")')
rep = upload("logo-up", 'variant { logo = "app" }', "image/png", png)
check("logo path", '"/logo/app"' in rep, rep[:90])
check("getLogo", "sha256Hex" in call("getLogo", '("app")'))
rep = upload("avatar-up", "variant { avatar }", "image/jpeg", jpeg)
check("avatar path", f'"/avatar/{me}"' in rep)
prof = call("profileOf", f'(principal "{me}")')
check("Users.setAvatar wired", f"/avatar/{me}" in prof, prof[:120])

print("— the storage-independence suite: heap independence while 4.5 MiB lands in the Region —")
# Measured on the classical/copying-GC/--force-gc build, where every
# update ends with a FULL collection: heapSize() == live bytes.
CANISTER = "media_app_heap"
check("heap canister claimOwner", call("claimOwner") == "(true)")
heap0 = get_nat(call("heapSize"), "")
stats0 = call("storageStats")
bytes0 = get_nat(stats0, "totalBytes")
pages0 = get_nat(stats0, "regionPages")
photo_hashes = []
for k in range(9):
    body = padded(jpeg, 512 * 1024, 100 + k)
    rep = upload(f"photo-{k}", "variant { photo }", "image/jpeg", body)
    m = re.search(r'sha256Hex = "([0-9a-f]{64})"', rep)
    photo_hashes.append(m.group(1))
    expected = hashlib.sha256(body).hexdigest()
    if m.group(1) != expected:
        check(f"photo {k} content hash", False, f"{m.group(1)} != {expected}")
heap1 = get_nat(call("heapSize"), "")
stats1 = call("storageStats")
bytes1 = get_nat(stats1, "totalBytes")
pages1 = get_nat(stats1, "regionPages")
check("stored bytes grew by exactly 9×512KiB", bytes1 - bytes0 == 9 * 512 * 1024,
      f"delta={bytes1 - bytes0}")
check("region pages grew to hold them", (pages1 - pages0) * 65536 >= 9 * 512 * 1024,
      f"pages {pages0}→{pages1}")
heap_delta = heap1 - heap0
check("heap delta < 1.5 MB (bound A)", heap_delta < 1_500_000,
      f"heap {heap0}→{heap1} (delta {heap_delta}) vs 4718592 stored")
# Photos for the rest of the suite live on the EOP canister.
CANISTER = "media_app"
photo_hashes = []
for k in range(9):
    body = padded(jpeg, 512 * 1024, 100 + k)
    rep = upload(f"photo-{k}", "variant { photo }", "image/jpeg", body)
    m = re.search(r'sha256Hex = "([0-9a-f]{64})"', rep)
    photo_hashes.append(m.group(1))

print("— pre-upgrade snapshot —")
root0 = call("rootHex")
paths0 = call("listPaths")
stats_pre = call("storageStats")
serve_path = f"/photo/{photo_hashes[0]}"
serve0 = call("http_request", f'(record {{ method = "GET"; url = "{serve_path}"; headers = vec {{}}; body = blob "" }})')
wit0 = call("getMediaWithWitness", f'("{serve_path}")')
# In-flight staged upload: 1 of 2 chunks present across the upgrade.
call("startUpload", '("inflight", variant { avatar }, "image/jpeg", 2 : nat)')
call("putChunk", f'("inflight", 0 : nat, {blob_lit(jpeg)})')
prog0 = call("chunkProgress", '("inflight")')
check("staged pre-upgrade", "receivedIndices = vec { 0 " in prog0 or "receivedIndices = vec { 0;" in prog0 or "receivedIndices = vec { 0 }" in prog0, prog0[:150])

print("— THE UPGRADE (mode=upgrade, wasm-memory-persistence=keep) —")
dfx("canister", "install", "media_app", "--mode", "upgrade",
    "--wasm", "media_app.wasm", "--wasm-memory-persistence", "keep", "--yes")

print("— the upgrade-survival suite: byte-equal state after the real upgrade —")
check("root survives", call("rootHex") == root0)
check("paths survive", call("listPaths") == paths0)
check("stats survive", call("storageStats") == stats_pre)
check("served photo byte-identical", call("http_request", f'(record {{ method = "GET"; url = "{serve_path}"; headers = vec {{}}; body = blob "" }})') == serve0)
check("witness reply identical", call("getMediaWithWitness", f'("{serve_path}")') == wit0)
check("staged upload survives", call("chunkProgress", '("inflight")') == prog0)
# Complete the staged upload post-upgrade.
pad2 = padded(jpeg, 40000, 7)
call("putChunk", f'("inflight", 0 : nat, {blob_lit(pad2[:CHUNK])})')
call("putChunk", f'("inflight", 1 : nat, {blob_lit(pad2[CHUNK:])})')
rep = call("finishUpload", '("inflight")')
check("staged completes post-upgrade",
      hashlib.sha256(pad2).hexdigest() in rep, rep[:100])
# Ownership + free-list functional post-upgrade.
check("deletePhoto post-upgrade (ownership survived)",
      call("deletePhoto", f'("{photo_hashes[8]}")') == "(true)")
stats2 = call("storageStats")
check("free-list reclaims post-upgrade",
      get_nat(stats2, "freeListBytes") > 0 or get_nat(stats2, "totalBytes") == bytes1 - 512 * 1024,
      stats2[:200])

if failures:
    print(f"REPLICA SUITE RED: {len(failures)} failures: {failures}")
    sys.exit(1)
print("REPLICA SUITE GREEN (heap bound A + upgrade bound B)")
