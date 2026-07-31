/// Policy.mo — the policy suite (policy properties) + the Region/free-list
/// behavior half of the storage-independence suite (heap-independence itself is measured in
/// the replica suite, where GC runs between messages).
///
/// Every scenario runs on a FRESH store; every assertion is a hard bound
/// stated in the comment above it. Can-fail controls: (a) inverse
/// scenarios inside this file, (b) test/run-wasi.sh --teeth compiles this
/// suite against deliberately-broken Media.mo copies (dedup off,
/// reclaim off) and requires RED.

import Media "../../src/Media";
import Admin "../../src/Admin";
import Fix "MediaFixtures";
import Blob "mo:core/Blob";
import Text "mo:core/Text";
import Array "mo:core/Array";
import VarArray "mo:core/VarArray";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
// Nat64 not needed directly
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Map "mo:core/Map";
import Debug "mo:core/Debug";
import Prim "mo:⛔";

// ── helpers ──

func p(tag : Nat8) : Principal {
  // Synthetic principals, mirroring the Rust tests' vec![tag; 10] (lib.rs:1271).
  Prim.principalOfBlob(Blob.fromArray(Array.repeat<Nat8>(tag, 10)));
};

func freshAdmin(owner : Principal) : Admin.State {
  let a = Admin.init();
  assert (Admin.claimOwner(a, owner));
  a;
};

let adminP = p(0xA0);

/// body = base image bytes ++ deterministic filler to exactly `target`
/// bytes (header-bounded validation permits trailing bytes; distinct seeds
/// give distinct hashes).
func padded(base : Blob, target : Nat, seed : Nat8) : Blob {
  let b = Blob.toArray(base);
  assert (target >= b.size());
  let out = VarArray.repeat<Nat8>(0, target);
  var i = 0;
  for (byte in b.vals()) { out[i] := byte; i += 1 };
  while (i < target) {
    out[i] := Nat8.fromNat((Nat8.toNat(seed) + i) % 256);
    i += 1;
  };
  Blob.fromArray(VarArray.toArray(out));
};

func chunksOf(body : Blob) : [Blob] {
  let bytes = Blob.toArray(body);
  let n = bytes.size();
  if (n == 0) { return [Blob.fromArray([])] };
  let count = (n + Media.MAX_CHUNK_BYTES - 1) / Media.MAX_CHUNK_BYTES;
  Array.tabulate<Blob>(
    count,
    func(i : Nat) : Blob {
      let start = i * Media.MAX_CHUNK_BYTES;
      let end = Nat.min(start + Media.MAX_CHUNK_BYTES, n);
      Blob.fromArray(Array.sliceToArray<Nat8>(bytes, start, end));
    },
  );
};

/// Full chunked upload through the public API (mirrors the Rust test
/// helper, lib.rs:1331-1349).
func upload(
  s : Media.Store,
  a : Admin.State,
  caller : Principal,
  id : Text,
  class_ : Media.Class,
  ct : Text,
  body : Blob,
) : Result.Result<Media.FinishReply, Media.MediaError> {
  let cs = chunksOf(body);
  switch (Media.startUpload(s, a, caller, id, class_, ct, cs.size())) {
    case (#err(e)) { return #err(e) };
    case (#ok) {};
  };
  var i = 0;
  for (c in cs.vals()) {
    switch (Media.storeChunk(s, a, caller, id, i, c)) {
      case (#err(e)) { return #err(e) };
      case (#ok) {};
    };
    i += 1;
  };
  Media.finishUpload(s, a, caller, id);
};

func ok(r : Result.Result<Media.FinishReply, Media.MediaError>) : Media.FinishReply {
  switch (r) {
    case (#ok(rep)) rep;
    case (#err(e)) { Debug.print("UNEXPECTED ERR: " # Media.errorText(e)); assert false; loop {} };
  };
};

/// Assert the error is #Validation AND its reason carries `needle`. The
/// VARIANT is half the contract: a suite that only matched prose would stay
/// green if a variant were swapped while its rendered text was preserved.
func errValidation(r : Result.Result<Media.FinishReply, Media.MediaError>, needle : Text) {
  switch (r) {
    case (#ok(rep)) { Debug.print("UNEXPECTED OK: " # rep.path); assert false };
    case (#err(#Validation(v))) {
      if (not Text.contains(v.reason, #text needle)) {
        Debug.print("reason \"" # v.reason # "\" missing \"" # needle # "\"");
        assert false;
      };
    };
    case (#err(e)) {
      Debug.print("expected #Validation, got: " # Media.errorText(e)); assert false;
    };
  };
};

func errIsNotAdmin(r : Result.Result<Media.FinishReply, Media.MediaError>) {
  switch (r) { case (#err(#NotAdmin)) {}; case (_) { Debug.print("expected #NotAdmin"); assert false } };
};
func errIsNotOwner(r : Result.Result<Media.FinishReply, Media.MediaError>) {
  switch (r) { case (#err(#NotOwner)) {}; case (_) { Debug.print("expected #NotOwner"); assert false } };
};
func errIsQuota(r : Result.Result<Media.FinishReply, Media.MediaError>, scope : Text, limit : Nat) {
  switch (r) {
    case (#err(#QuotaExceeded(q))) { assert (q.scope == scope); assert (q.limit == limit) };
    case (_) { Debug.print("expected #QuotaExceeded(" # scope # ")"); assert false };
  };
};

var scenario = 0;
func begin(name : Text) : (Media.Store, Admin.State) {
  scenario += 1;
  Debug.print("— " # Nat.toText(scenario) # ": " # name);
  (Media.init(), freshAdmin(adminP));
};

// ═══ 1. avatar roundtrip + serve path resolves + served bytes identical ═══
do {
  let (s, a) = begin("avatar roundtrip, served byte-identical from Region");
  let alice = p(0x01);
  let body = Fix.jpeg_ok_64;
  let rep = ok(upload(s, a, alice, "u1", #avatar, "image/jpeg", body));
  assert (Text.startsWith(rep.path, #text "/avatar/"));
  assert (rep.path == "/avatar/" # Principal.toText(alice));
  assert (rep.size == body.size());
  assert (rep.contentType == "image/jpeg");
  // Served bytes come back from the Region byte-identical.
  let resp = Media.httpRequest(s, { method = "GET"; url = rep.path; headers = []; body = "" });
  assert (resp.statusCode == 200);
  assert (resp.body == body);
  assert (resp.headers == [("content-type", "image/jpeg"), ("cache-control", "no-cache, must-revalidate")]);
  // Query-string stripped + missing leading slash normalized.
  assert (Media.httpRequest(s, { method = "GET"; url = rep.path # "?w=64"; headers = []; body = "" }).statusCode == 200);
  let noSlash = Text.trimStart(rep.path, #char '/');
  assert (Media.httpRequest(s, { method = "GET"; url = noSlash; headers = []; body = "" }).statusCode == 200);
  // 404 shape.
  let miss = Media.httpRequest(s, { method = "GET"; url = "/nope"; headers = []; body = "" });
  assert (miss.statusCode == 404);
  assert (miss.body == Text.encodeUtf8("not found: /nope"));
  // getAvatar mirrors the path index (text-keyed, lib.rs:1022-1039).
  switch (Media.getAvatar(s, Principal.toText(alice))) {
    case (?got) { assert (got.path == rep.path); assert (got.sha256Hex == rep.sha256Hex) };
    case null { assert false };
  };
  assert (Media.getAvatar(s, "2vxsx-fae") == null);
};

// ═══ 2. dedup: identical bytes stored once, refcount via observable frees ═══
do {
  let (s, a) = begin("dedup identical bytes → one blob; refcount drops observably");
  let alice = p(0x10);
  let bob = p(0x11);
  let body = Fix.png_ok_64;
  let ra = ok(upload(s, a, alice, "x", #avatar, "image/png", body));
  let rb = ok(upload(s, a, bob, "y", #avatar, "image/png", body));
  assert (ra.sha256Hex == rb.sha256Hex);
  let st1 = Media.storageStats(s);
  // Identical bytes → ONE blob, counted once (lib.rs:1401-1414 parity).
  assert (st1.blobCount == 1);
  assert (st1.totalBytes == body.size());
  assert (st1.pathCount == 2);
  // Control (inverse): a DIFFERENT body makes blobCount 2 — the measurement
  // can distinguish.
  let carol = p(0x12);
  ignore ok(upload(s, a, carol, "z", #avatar, "image/png", padded(Fix.png_ok_64, 8000, 77)));
  assert (Media.storageStats(s).blobCount == 2);
  // Refcount: alice clears — blob must SURVIVE for bob (refcount 2→1)…
  assert (Media.clearAvatar(s, alice));
  assert (Media.mediaInfo(s, rb.path) != null);
  assert (Media.storageStats(s).blobCount == 2);
  // …bob clears — last ref drops, bytes freed, budget reclaimed.
  assert (Media.clearAvatar(s, bob));
  let st2 = Media.storageStats(s);
  assert (st2.blobCount == 1); // carol's only
  assert (st2.totalBytes == 8000);
};

// ═══ 3. replacing an avatar frees the old blob (lib.rs:1416-1430) ═══
do {
  let (s, a) = begin("avatar replace frees old bytes; idempotent re-set");
  let alice = p(0x20);
  let old = ok(upload(s, a, alice, "x", #avatar, "image/jpeg", Fix.jpeg_ok_64));
  assert (Media.storageStats(s).totalBytes == Fix.jpeg_ok_64.size());
  let new_ = ok(upload(s, a, alice, "y", #avatar, "image/png", Fix.png_ok_64));
  let st = Media.storageStats(s);
  // Old bytes freed, exactly the new body accounted.
  assert (st.blobCount == 1);
  assert (st.totalBytes == Fix.png_ok_64.size());
  assert (Media.mediaInfo(s, old.path) != null); // same path, repointed
  assert (new_.path == old.path);
  // Idempotent re-set (lib.rs:1432-1442): same bytes again → refcount NOT
  // inflated, proven by a single clear fully freeing.
  ignore ok(upload(s, a, alice, "z", #avatar, "image/png", Fix.png_ok_64));
  assert (Media.storageStats(s).blobCount == 1);
  assert (Media.clearAvatar(s, alice));
  let st2 = Media.storageStats(s);
  assert (st2.blobCount == 0);
  assert (st2.totalBytes == 0);
  assert (Media.mediaInfo(s, old.path) == null);
};

// ═══ 4. caller gating (lib.rs:1445-1473) ═══
do {
  let (s, a) = begin("caller gating: foreign chunk/finish/reset all refused");
  let alice = p(0x30);
  let bob = p(0x31);
  assert (Result.isOk(Media.startUpload(s, a, alice, "u", #avatar, "image/webp", 1)));
  switch (Media.storeChunk(s, a, bob, "u", 0, Fix.webp_lossy_64)) {
    case (#err(#NotOwner)) {}; case (_) { assert false };
    case (#ok) { assert false };
  };
  assert (Result.isOk(Media.storeChunk(s, a, alice, "u", 0, Fix.webp_lossy_64)));
  errIsNotOwner(Media.finishUpload(s, a, bob, "u"));
  // Bob cannot reset alice's staging; alice can.
  assert (not Media.resetStaging(s, bob, "u"));
  assert (Media.chunkProgress(s, "u") != null);
  assert (Media.resetStaging(s, alice, "u"));
  assert (Media.chunkProgress(s, "u") == null);
  assert (not Media.resetStaging(s, alice, "u")); // absent now
};

// ═══ 5. photos: multi-chunk 512 KiB, quota idempotency, delete semantics ═══
do {
  let (s, a) = begin("photo: 16-chunk max-size roundtrip + delete frees + reclaim");
  let alice = p(0x40);
  let body = padded(Fix.jpeg_ok_64, Media.PHOTO_MAX_BYTES, 5); // exactly 512 KiB
  assert (chunksOf(body).size() == 16);
  let rep = ok(upload(s, a, alice, "big", #photo, "image/jpeg", body));
  assert (Text.startsWith(rep.path, #text "/photo/"));
  assert (rep.size == Media.PHOTO_MAX_BYTES);
  let resp = Media.httpRequest(s, { method = "GET"; url = rep.path; headers = []; body = "" });
  assert (resp.body == body); // 512 KiB round-tripped byte-identical
  // Same photo re-uploaded by the same owner: idempotent, no double count.
  ignore ok(upload(s, a, alice, "big2", #photo, "image/jpeg", body));
  assert (Media.storageStats(s).blobCount == 1);
  assert (Media.storageStats(s).totalBytes == Media.PHOTO_MAX_BYTES);
  // Foreign delete refused, blob survives (lib.rs:1511-1520).
  let bob = p(0x41);
  switch (Media.deletePhoto(s, bob, rep.sha256Hex)) {
    case (#ok(deleted)) { assert (not deleted) };
    case (#err(_)) { assert false };
  };
  assert (Media.mediaInfo(s, rep.path) != null);
  // Bad hash text is an error, not a false.
  switch (Media.deletePhoto(s, alice, "zz")) {
    case (#err(#Validation(v))) { assert (Text.contains(v.reason, #text "64 hex")) };
    case (_) { assert false };
    case (#ok(_)) { assert false };
  };
  // Owner delete frees bytes + path + budget (lib.rs:1497-1509).
  switch (Media.deletePhoto(s, alice, rep.sha256Hex)) {
    case (#ok(deleted)) { assert deleted };
    case (#err(_)) { assert false };
  };
  assert (Media.mediaInfo(s, rep.path) == null);
  assert (Media.storageStats(s).totalBytes == 0);
  // Deleting again is a no-op false.
  switch (Media.deletePhoto(s, alice, rep.sha256Hex)) {
    case (#ok(deleted)) { assert (not deleted) };
    case (#err(_)) { assert false };
  };
};

// ═══ 6. shared content-addressed path: refcount-zero unlisting (v0.4.0) ═══
// This scenario previously pinned the Rust reference's behaviour, in which the
// FIRST delete unlisted the shared path for every owner while the bytes lived
// on. That was ruled a defect rather than a quirk to port: one owner's delete
// must not stop serving another owner's live media. The path is now unlisted
// only when the last reference drops. Scenario 28 asserts the same property
// from the serving side.
do {
  let (s, a) = begin("shared photo path: unlisted only at refcount zero");
  let alice = p(0x50);
  let bob = p(0x51);
  let body = Fix.gif_ok_64;
  let ra = ok(upload(s, a, alice, "x", #photo, "image/gif", body));
  ignore ok(upload(s, a, bob, "y", #photo, "image/gif", body));
  assert (Media.storageStats(s).blobCount == 1);
  assert (Media.storageStats(s).pathCount == 1);
  // Alice deletes: her ownership goes, bob's media keeps serving.
  switch (Media.deletePhoto(s, alice, ra.sha256Hex)) {
    case (#ok(d)) { assert d };
    case (#err(_)) { assert false };
  };
  assert (Media.mediaInfo(s, ra.path) != null);
  assert (Media.storageStats(s).blobCount == 1);
  assert (Media.storageStats(s).totalBytes == body.size());
  // Bob deletes: last reference drops, path and bytes both go.
  switch (Media.deletePhoto(s, bob, ra.sha256Hex)) {
    case (#ok(d)) { assert d };
    case (#err(_)) { assert false };
  };
  assert (Media.mediaInfo(s, ra.path) == null);
  assert (Media.storageStats(s).blobCount == 0);
  assert (Media.storageStats(s).totalBytes == 0);
};

// ═══ 7. caps: start-time ceilings + chunk-size gate (cap+1 impossible) ═══
do {
  let (s, a) = begin("caps: chunk ceilings, 32 KiB chunk gate, cap-exact pass");
  let alice = p(0x60);
  // avatar ceiling = 2 chunks (65536/32768); 3 rejected at START, before
  // any byte is staged (lib.rs:1476-1486).
  switch (Media.startUpload(s, a, alice, "x", #avatar, "image/jpeg", 3)) {
    case (#err(#Validation(v))) { assert (Text.contains(v.reason, #text "exceeds ceiling")) };
    case (_) { assert false };
    case (#ok) { assert false };
  };
  assert (Media.chunkProgress(s, "x") == null);
  // photo ceiling = 16; 17 rejected.
  switch (Media.startUpload(s, a, alice, "y", #photo, "image/jpeg", 17)) {
    case (#err(#Validation(v))) { assert (Text.contains(v.reason, #text "exceeds ceiling")) };
    case (_) { assert false };
    case (#ok) { assert false };
  };
  // chunk > 32 KiB rejected (checked FIRST, before existence — lib.rs:580).
  switch (Media.storeChunk(s, a, alice, "nonexistent", 0, padded(Fix.jpeg_ok_64, 32769, 9))) {
    case (#err(#ChunkTooLarge(c))) { assert (c.limit == Media.MAX_CHUNK_BYTES); assert (c.got == 32769) };
    case (_) { assert false };
    case (#ok) { assert false };
  };
  // total_chunks = 0 rejected; bad content type rejected; id length gates.
  errValidation(upload(s, a, alice, "", #avatar, "image/jpeg", Fix.jpeg_ok_64), "1..=128");
  switch (Media.startUpload(s, a, alice, "z", #avatar, "image/jpeg", 0)) {
    case (#err(#Validation(v))) { assert (Text.contains(v.reason, #text "must be > 0")) };
    case (_) { assert false };
    case (#ok) { assert false };
  };
  switch (Media.startUpload(s, a, alice, "h", #avatar, "text/html", 1)) {
    case (#err(#Validation(v))) { assert (Text.contains(v.reason, #text "not allowed")) };
    case (_) { assert false };
    case (#ok) { assert false };
  };
  var longId = "";
  for (_ in Nat.range(0, 129)) { longId := longId # "a" };
  switch (Media.startUpload(s, a, alice, longId, #avatar, "image/jpeg", 1)) {
    case (#err(#Validation(v))) { assert (Text.contains(v.reason, #text "1..=128")) };
    case (_) { assert false };
    case (#ok) { assert false };
  };
  // Cap-exact avatar (65536 bytes = exactly 2 chunks) PASSES.
  let capBody = padded(Fix.jpeg_ok_64, Media.AVATAR_MAX_BYTES, 3);
  let rep = ok(upload(s, a, alice, "cap", #avatar, "image/jpeg", capBody));
  assert (rep.size == Media.AVATAR_MAX_BYTES);
  // (cap+1 is unreachable through the API: 2×32768 == the cap and a 3rd
  // chunk / a 32769-byte chunk are both rejected above — the finalize
  // size check is defense-in-depth, as in the Rust reference.)
};

// ═══ 8. staging caps + duplicate ids (lib.rs:1549-1560) ═══
do {
  let (s, a) = begin("staging caps: per-principal 4 + duplicate id");
  let alice = p(0x70);
  for (i in Nat.range(0, Media.MAX_STAGED_PER_PRINCIPAL)) {
    assert (Result.isOk(Media.startUpload(s, a, alice, "u" # Nat.toText(i), #avatar, "image/webp", 1)));
  };
  switch (Media.startUpload(s, a, alice, "overflow", #avatar, "image/webp", 1)) {
    case (#err(#QuotaExceeded(q))) {
      assert (q.scope == "staged uploads for this principal");
      assert (q.limit == Media.MAX_STAGED_PER_PRINCIPAL);
    };
    case (_) { assert false };
    case (#ok) { assert false };
  };
  // Duplicate upload id (from another principal too) is rejected.
  let bob = p(0x71);
  switch (Media.startUpload(s, a, bob, "u0", #avatar, "image/webp", 1)) {
    case (#err(#Validation(v))) { assert (Text.contains(v.reason, #text "already in progress")) };
    case (_) { assert false };
    case (#ok) { assert false };
  };
};
do {
  // Global cap. FINDING (holds for the Rust reference too, same constants
  // + same gc placement): with STAGING_GC_TICKS == MAX_CONCURRENT_STAGED
  // == 64, an honest call timeline can never present 64 live uploads to
  // the check — keeping 64 alive needs 64 touches within a 63-tick window
  // plus the attempt itself (pigeonhole). The check is faithful defense-
  // in-depth; to exercise it the test warm-resets the staged entries'
  // last-activity ticks directly.
  let (s, a) = begin("staging global cap 64 (warm-reset to reach the check)");
  var tag : Nat8 = 0x80;
  for (k in Nat.range(0, 16)) {
    let q = p(tag);
    tag += 1;
    for (i in Nat.range(0, 4)) {
      assert (Result.isOk(Media.startUpload(s, a, q, "g" # Nat.toText(k) # "-" # Nat.toText(i), #avatar, "image/webp", 1)));
    };
  };
  assert (Map.size(s.staging) == 64);
  for (up in Map.values(s.staging)) { up.lastActivityTicks := s.tick };
  let carol = p(0xF0);
  switch (Media.startUpload(s, a, carol, "past-global", #avatar, "image/webp", 1)) {
    case (#err(#QuotaExceeded(q))) {
      assert (q.scope == "concurrent staged uploads");
      assert (q.limit == Media.MAX_CONCURRENT_STAGED_UPLOADS);
      assert (q.usage == Media.MAX_CONCURRENT_STAGED_UPLOADS);
    };
    case (_) { assert false };
  };
};

// ═══ 9. missing chunks + progress + retry (lib.rs:1534-1547) ═══
do {
  let (s, a) = begin("missing chunk: precise error, staging retained, retry succeeds");
  let alice = p(0x90);
  let body = padded(Fix.jpeg_ok_64, 90000, 11); // 3 chunks
  let cs = chunksOf(body);
  assert (cs.size() == 3);
  assert (Result.isOk(Media.startUpload(s, a, alice, "u", #photo, "image/jpeg", 3)));
  assert (Result.isOk(Media.storeChunk(s, a, alice, "u", 0, cs[0])));
  assert (Result.isOk(Media.storeChunk(s, a, alice, "u", 2, cs[2])));
  switch (Media.finishUpload(s, a, alice, "u")) {
    case (#err(e)) {
      assert (e == #IncompleteUpload({ missing = 1; firstMissing = [1] }));
    };
    case (#ok(_)) { assert false };
  };
  // Staged state preserved for retry, with exact progress accounting.
  switch (Media.chunkProgress(s, "u")) {
    case (?prog) {
      assert (prog.receivedCount == 2);
      assert (prog.receivedIndices == [0, 2]);
      assert (prog.receivedBytes == cs[0].size() + cs[2].size());
      assert (prog.mediaClass == "photo");
      assert (prog.totalChunks == 3);
    };
    case null { assert false };
  };
  // chunk_index out of range.
  switch (Media.storeChunk(s, a, alice, "u", 3, cs[0])) {
    case (#err(#Validation(v))) { assert (Text.contains(v.reason, #text "out of range")) };
    case (_) { assert false };
    case (#ok) { assert false };
  };
  // Re-storing an existing index replaces bytes without double-counting.
  assert (Result.isOk(Media.storeChunk(s, a, alice, "u", 0, cs[0])));
  switch (Media.chunkProgress(s, "u")) {
    case (?prog) { assert (prog.receivedCount == 2) };
    case null { assert false };
  };
  assert (Result.isOk(Media.storeChunk(s, a, alice, "u", 1, cs[1])));
  let rep = ok(Media.finishUpload(s, a, alice, "u"));
  assert (rep.size == 90000);
  // Last-write-wins on a re-stored chunk: 1-chunk avatar stored twice with
  // different bodies hashes to the SECOND body.
  let b1 = Fix.jpeg_ok_64;
  let b2 = padded(Fix.jpeg_ok_64, 5000, 42);
  assert (Result.isOk(Media.startUpload(s, a, alice, "w", #avatar, "image/jpeg", 1)));
  assert (Result.isOk(Media.storeChunk(s, a, alice, "w", 0, b1)));
  assert (Result.isOk(Media.storeChunk(s, a, alice, "w", 0, b2)));
  let rep2 = ok(Media.finishUpload(s, a, alice, "w"));
  assert (rep2.size == 5000);
  assert (rep2.sha256Hex == Media.hexEncode(Media.sha256(Blob.toArray(b2))));
};

// ═══ 10. tick-based GC of abandoned uploads — exact 64-tick boundary ═══
do {
  let (s, a) = begin("staging GC at exactly STAGING_GC_TICKS mutating calls");
  let alice = p(0xA1);
  let ghost = p(0xA2); // no avatar — clearAvatar is a pure tick bump
  assert (Result.isOk(Media.startUpload(s, a, alice, "u", #avatar, "image/webp", 1))); // tick 1, last=1
  for (_ in Nat.range(0, 62)) { ignore Media.clearAvatar(s, ghost) }; // tick 63
  // startUpload ticks to 64 and GCs: age(u) = 63 < 64 → u SURVIVES.
  assert (Result.isOk(Media.startUpload(s, a, alice, "v", #avatar, "image/webp", 1)));
  assert (Media.chunkProgress(s, "u") != null);
  // Next gc-bearing call ticks to 65: age(u) = 64 ≥ 64 → u GC'd; v (age 1) lives.
  assert (Result.isOk(Media.startUpload(s, a, alice, "w", #avatar, "image/webp", 1)));
  assert (Media.chunkProgress(s, "u") == null);
  assert (Media.chunkProgress(s, "v") != null);
  // A GC'd id is reusable (the duplicate check runs after gc, lib.rs:549).
  assert (Result.isOk(Media.startUpload(s, a, alice, "u", #photo, "image/jpeg", 1)));
};

// ═══ 11. storage budget: clean rejection, zero mutation (lib.rs:1587-1595) ═══
do {
  let (s, a) = begin("storage budget: clean 'storage full', no mutation");
  let alice = p(0xB0);
  s.totalBytes := Media.MAX_MEDIA_BYTES - 10;
  let r = upload(s, a, alice, "u", #avatar, "image/jpeg", Fix.jpeg_ok_64);
  switch (r) {
    case (#err(#StorageFull(f))) { assert (f.requestedBytes == Fix.jpeg_ok_64.size()) };
    case (_) { assert false };
  };
  assert (s.totalBytes == Media.MAX_MEDIA_BYTES - 10); // untouched
  assert (Media.storageStats(s).blobCount == 0);
  assert (Media.listPaths(s).size() == 0);
  // Avatar slot not recorded either.
  assert (Media.getAvatar(s, Principal.toText(alice)) == null);
};

// ═══ 12. logo class: admin gate, named slots, cap, delete ═══
do {
  let (s, a) = begin("logo: admin-gated writes, named slots, MAX_LOGOS cap");
  let user = p(0xC0);
  // Non-admin rejected at START.
  switch (Media.startUpload(s, a, user, "l", #logo("brand"), "image/png", 1)) {
    case (#err(#NotAdmin)) {}; case (_) { assert false };
    case (#ok) { assert false };
  };
  // Bad names rejected.
  switch (Media.startUpload(s, a, adminP, "l", #logo("Bad Name!"), "image/png", 1)) {
    case (#err(#Validation(v))) { assert (Text.contains(v.reason, #text "logo name")) };
    case (_) { assert false };
    case (#ok) { assert false };
  };
  switch (Media.startUpload(s, a, adminP, "l", #logo(""), "image/png", 1)) {
    case (#err(#Validation(v))) { assert (Text.contains(v.reason, #text "logo name")) };
    case (_) { assert false };
    case (#ok) { assert false };
  };
  // Admin uploads a logo to a named slot.
  let rep = ok(upload(s, a, adminP, "l1", #logo("brand.dark"), "image/png", Fix.png_ok_64));
  assert (rep.path == "/logo/brand.dark");
  switch (Media.getLogo(s, "brand.dark")) {
    case (?got) { assert (got.sha256Hex == rep.sha256Hex) };
    case null { assert false };
  };
  // Admin-revoked-mid-upload: finish is the security boundary; staging is
  // kept for a retry after re-grant.
  let helper = p(0xC1);
  assert (Admin.addAdmin(a, adminP, helper));
  assert (Result.isOk(Media.startUpload(s, a, helper, "l2", #logo("brand.light"), "image/png", 1)));
  assert (Result.isOk(Media.storeChunk(s, a, helper, "l2", 0, Fix.png_ok_64)));
  assert (Admin.removeAdmin(a, adminP, helper));
  errIsNotAdmin(Media.finishUpload(s, a, helper, "l2"));
  assert (Media.chunkProgress(s, "l2") != null); // retryable
  assert (Admin.addAdmin(a, adminP, helper));
  ignore ok(Media.finishUpload(s, a, helper, "l2"));
  // Logo replace + idempotent re-set share the avatar-slot semantics.
  ignore ok(upload(s, a, adminP, "l3", #logo("brand.dark"), "image/jpeg", Fix.jpeg_ok_64));
  assert (Media.storageStats(s).blobCount == 2); // dark(jpeg) + light(png)
  // Delete: non-admin refused; admin deletes; absent → false.
  switch (Media.deleteLogo(s, a, user, "brand.dark")) {
    case (#err(#NotAdmin)) {}; case (_) { assert false };
    case (#ok(_)) { assert false };
  };
  switch (Media.deleteLogo(s, a, adminP, "brand.dark")) {
    case (#ok(d)) { assert d };
    case (#err(_)) { assert false };
  };
  assert (Media.getLogo(s, "brand.dark") == null);
  switch (Media.deleteLogo(s, a, adminP, "brand.dark")) {
    case (#ok(d)) { assert (not d) };
    case (#err(_)) { assert false };
  };
  // MAX_LOGOS bound: fill to 64 named slots, 65th rejected, re-set of an
  // existing slot still allowed at the cap.
  let (s2, a2) = begin("logo cap 64");
  for (i in Nat.range(0, Media.MAX_LOGOS)) {
    ignore ok(upload(s2, a2, adminP, "cap" # Nat.toText(i), #logo("slot" # Nat.toText(i)), "image/jpeg", padded(Fix.jpeg_ok_64, 4000 + i, 21)));
  };
  errIsQuota(
    upload(s2, a2, adminP, "cap65", #logo("slot-too-many"), "image/jpeg", Fix.jpeg_ok_64),
    "logo slots", Media.MAX_LOGOS,
  );
  ignore ok(upload(s2, a2, adminP, "capr", #logo("slot0"), "image/jpeg", Fix.jpeg_ok_64));
};

// ═══ 13. photo quota: exactly MAX_PHOTOS_PER_PRINCIPAL, then the cap ═══
do {
  let (s, a) = begin("photo quota 256 exact, idempotent re-upload exempt");
  let alice = p(0xD0);
  var lastHex = "";
  for (i in Nat.range(0, Media.MAX_PHOTOS_PER_PRINCIPAL)) {
    let rep = ok(upload(s, a, alice, "q" # Nat.toText(i), #photo, "image/jpeg", padded(Fix.jpeg_ok_64, 3400 + i, 33)));
    lastHex := rep.sha256Hex;
  };
  assert (Media.storageStats(s).blobCount == Media.MAX_PHOTOS_PER_PRINCIPAL);
  // 257th distinct photo → quota error, nothing stored.
  errIsQuota(
    upload(s, a, alice, "q256", #photo, "image/jpeg", padded(Fix.jpeg_ok_64, 9999, 34)),
    "photos for this principal", Media.MAX_PHOTOS_PER_PRINCIPAL,
  );
  assert (Media.storageStats(s).blobCount == Media.MAX_PHOTOS_PER_PRINCIPAL);
  // Re-uploading an ALREADY-OWNED photo at the cap is idempotent-allowed
  // (the quota check only runs for not-yet-owned hashes, lib.rs:642-655).
  ignore ok(upload(s, a, alice, "again", #photo, "image/jpeg", padded(Fix.jpeg_ok_64, 3400 + 255, 33)));
  // Another principal has an independent quota.
  let bob = p(0xD1);
  ignore ok(upload(s, a, bob, "bq", #photo, "image/jpeg", padded(Fix.jpeg_ok_64, 12345, 35)));
};

// ═══ 14. Region free-list: reuse, next/prev coalesce, tail shrink, absorb ═══
// Layout per scenario: A=100000 B=50000 C=30000 D=20000 sequential.
func fourPhotos(s : Media.Store, a : Admin.State, who : Principal) : [Media.FinishReply] {
  [
    ok(upload(s, a, who, "A", #photo, "image/jpeg", padded(Fix.jpeg_ok_64, 100000, 1))),
    ok(upload(s, a, who, "B", #photo, "image/jpeg", padded(Fix.jpeg_ok_64, 50000, 2))),
    ok(upload(s, a, who, "C", #photo, "image/jpeg", padded(Fix.jpeg_ok_64, 30000, 3))),
    ok(upload(s, a, who, "D", #photo, "image/jpeg", padded(Fix.jpeg_ok_64, 20000, 4))),
  ];
};
func delPhoto(s : Media.Store, who : Principal, rep : Media.FinishReply) {
  switch (Media.deletePhoto(s, who, rep.sha256Hex)) {
    case (#ok(d)) { assert d };
    case (#err(_)) { assert false };
  };
};
do {
  let (s, a) = begin("free-list: middle free is recorded, then reused first-fit");
  let alice = p(0xE0);
  let reps = fourPhotos(s, a, alice);
  let pages0 = Media.storageStats(s).regionPages;
  assert (Media.storageStats(s).freeListBytes == 0);
  delPhoto(s, alice, reps[1]); // B (middle) → recorded extent
  let st = Media.storageStats(s);
  assert (st.freeListBytes == 50000);
  assert (st.regionPages == pages0);
  // Exact-fit re-upload reuses the hole: free list drains, NO page growth.
  ignore ok(upload(s, a, alice, "E", #photo, "image/jpeg", padded(Fix.jpeg_ok_64, 50000, 6)));
  let st2 = Media.storageStats(s);
  assert (st2.freeListBytes == 0);
  assert (st2.regionPages == pages0);
  // A bigger blob cannot fit any hole → appends → pages grow.
  ignore ok(upload(s, a, alice, "F", #photo, "image/jpeg", padded(Fix.jpeg_ok_64, 120000, 7)));
  assert (Media.storageStats(s).regionPages > pages0);
};
do {
  let (s, a) = begin("free-list: adjacent frees coalesce (next-merge order)");
  let alice = p(0xE1);
  let reps = fourPhotos(s, a, alice);
  let pages0 = Media.storageStats(s).regionPages;
  delPhoto(s, alice, reps[2]); // C first
  delPhoto(s, alice, reps[1]); // then B → B+C must merge into one 80000 extent
  assert (Media.storageStats(s).freeListBytes == 80000);
  // An 80000-byte blob fits ONLY IF coalesced into one extent.
  ignore ok(upload(s, a, alice, "G", #photo, "image/jpeg", padded(Fix.jpeg_ok_64, 80000, 8)));
  let st = Media.storageStats(s);
  assert (st.freeListBytes == 0);
  assert (st.regionPages == pages0);
};
do {
  let (s, a) = begin("free-list: adjacent frees coalesce (prev-merge order)");
  let alice = p(0xE2);
  let reps = fourPhotos(s, a, alice);
  let pages0 = Media.storageStats(s).regionPages;
  delPhoto(s, alice, reps[1]); // B first
  delPhoto(s, alice, reps[2]); // then C → prev-merge
  assert (Media.storageStats(s).freeListBytes == 80000);
  ignore ok(upload(s, a, alice, "G", #photo, "image/jpeg", padded(Fix.jpeg_ok_64, 80000, 8)));
  assert (Media.storageStats(s).freeListBytes == 0);
  assert (Media.storageStats(s).regionPages == pages0);
};
do {
  let (s, a) = begin("free-list: tail delete shrinks high-water (no extent left)");
  let alice = p(0xE3);
  let reps = fourPhotos(s, a, alice);
  delPhoto(s, alice, reps[3]); // D at the top → tail shrink, NOT a free extent
  assert (Media.storageStats(s).freeListBytes == 0);
  delPhoto(s, alice, reps[2]); // C now at the top → tail shrink again
  assert (Media.storageStats(s).freeListBytes == 0);
  // Reclaimed tail is reused: a 45000-byte blob appends where C/D were,
  // without page growth beyond the original envelope.
  let pages0 = Media.storageStats(s).regionPages;
  ignore ok(upload(s, a, alice, "E", #photo, "image/jpeg", padded(Fix.jpeg_ok_64, 45000, 9)));
  assert (Media.storageStats(s).regionPages == pages0);
};
do {
  let (s, a) = begin("free-list: absorb loop — mid extent absorbed on tail delete");
  let alice = p(0xE4);
  let reps = fourPhotos(s, a, alice);
  delPhoto(s, alice, reps[2]); // C (middle) → extent (30000)
  assert (Media.storageStats(s).freeListBytes == 30000);
  delPhoto(s, alice, reps[3]); // D (top): shrink + absorb C's extent
  assert (Media.storageStats(s).freeListBytes == 0);
};

// ═══ 15. getMediaWithWitness: certified read + absent shape ═══
do {
  let (s, a) = begin("certified read: witness verifies, absent 404 shape exact");
  let alice = p(0xF1);
  let body = Fix.jpeg_ok_64;
  let rep = ok(upload(s, a, alice, "u", #avatar, "image/jpeg", body));
  ignore ok(upload(s, a, p(0xF2), "v", #photo, "image/png", Fix.png_ok_64));
  let cert = Media.getMediaWithWitness(s, rep.path);
  assert (cert.statusCode == 200);
  assert (cert.contentType == "image/jpeg");
  assert (cert.bodyBase64 == Media.base64Encode(Blob.toArray(body)));
  assert (cert.bodySha256Hex == rep.sha256Hex);
  assert (cert.assetTreeRootHex == Media.hexEncode(Media.root(s)));
  assert (cert.witness.leafPath == rep.path);
  assert (cert.witness.leafBodySha256Hex == rep.sha256Hex);
  // The typed witness verifies against the root.
  switch (Media.witnessFor(Media.currentLeaves(s), rep.path)) {
    case (?w) { assert (Media.verifyWitness(w, Media.root(s))) };
    case null { assert false };
  };
  // Absent path: 404 with root, zero leaf hash, zero steps (lib.rs:1152-1166).
  let miss = Media.getMediaWithWitness(s, "/absent");
  assert (miss.statusCode == 404);
  assert (miss.contentType == "text/plain; charset=utf-8");
  assert (miss.bodyBase64 == Media.base64Encode(Blob.toArray(Text.encodeUtf8("not found: /absent"))));
  assert (miss.witness.leafBodySha256Hex == "0000000000000000000000000000000000000000000000000000000000000000");
  assert (miss.witness.steps.size() == 0);
  assert (miss.assetTreeRootHex == Media.hexEncode(Media.root(s)));
  // listPaths in byte order.
  let paths = Media.listPaths(s);
  assert (paths.size() == 2);
  assert (paths[0] == rep.path); // "/avatar/…" < "/photo/…"
};

// ═══ 16. root changes on every served-set mutation (certification seam) ═══
do {
  let (s, a) = begin("root tracks mutations; empty root is the domain constant");
  assert (Media.hexEncode(Media.root(s)) == "780506d46396392d17db4a5f059886a487eba1be03364073265a23fd2a671da4");
  let alice = p(0xF5);
  let r0 = Media.root(s);
  ignore ok(upload(s, a, alice, "u", #avatar, "image/jpeg", Fix.jpeg_ok_64));
  let r1 = Media.root(s);
  assert (r1 != r0);
  ignore ok(upload(s, a, alice, "v", #photo, "image/png", Fix.png_ok_64));
  let r2 = Media.root(s);
  assert (r2 != r1);
  assert (Media.clearAvatar(s, alice));
  let r3 = Media.root(s);
  assert (r3 != r2);
  // Same set → same root (content-defined, not history-defined).
  ignore ok(upload(s, a, alice, "w", #avatar, "image/jpeg", Fix.jpeg_ok_64));
  assert (Media.root(s) == r2);
};

// ═══ 17. Nat64 heap telemetry sanity: stored bytes live in the Region ═══
do {
  let (s, a) = begin("region accounting: totalBytes == sum of distinct stored bytes");
  let alice = p(0xF7);
  ignore ok(upload(s, a, alice, "u", #photo, "image/jpeg", padded(Fix.jpeg_ok_64, 400000, 50)));
  ignore ok(upload(s, a, alice, "v", #photo, "image/jpeg", padded(Fix.jpeg_ok_64, 300000, 51)));
  let st = Media.storageStats(s);
  assert (st.totalBytes == 700000);
  // Region holds at least the stored bytes (pages × 64 KiB ≥ totalBytes).
  assert (st.regionPages * 65536 >= st.totalBytes);
  Debug.print("  region pages=" # Nat.toText(st.regionPages) # " heap=" # Nat.toText(Prim.rts_heap_size()));
};

// ═══ v0.4.0 gates — each asserted on the TYPED error, not on prose ═══

// 24. anonymous principal refused at every write arm.
do {
  let (s, a) = begin("anonymous principal refused (start / chunk / finish / delete)");
  let anon = Prim.principalOfBlob(Blob.fromArray([0x04 : Nat8])); // 2vxsx-fae
  assert (Principal.isAnonymous(anon));
  switch (Media.startUpload(s, a, anon, "u", #avatar, "image/jpeg", 1)) {
    case (#err(#Anonymous)) {};
    case (_) { Debug.print("anonymous start NOT refused"); assert false };
  };
  // Nothing staged, nothing stored.
  assert (Media.chunkProgress(s, "u") == null);
  assert (Media.storageStats(s).blobCount == 0);
  // A named principal stages legitimately; the anonymous one still cannot write into it.
  let alice = p(0x11);
  assert (Result.isOk(Media.startUpload(s, a, alice, "v", #avatar, "image/jpeg", 1)));
  switch (Media.storeChunk(s, a, anon, "v", 0, Fix.jpeg_ok_64)) {
    case (#err(#Anonymous)) {};
    case (_) { Debug.print("anonymous chunk NOT refused"); assert false };
  };
  switch (Media.finishUpload(s, a, anon, "v")) {
    case (#err(#Anonymous)) {};
    case (_) { Debug.print("anonymous finish NOT refused"); assert false };
  };
  switch (Media.deletePhoto(s, anon, "00" # "00000000000000000000000000000000000000000000000000000000000000")) {
    case (#err(#Anonymous)) {};
    case (_) { Debug.print("anonymous delete NOT refused"); assert false };
  };
};

// 25. pause blocks the WHOLE upload path — including chunk writes.
do {
  let (s, a) = begin("pause blocks start AND chunk AND finish");
  let alice = p(0x12);
  // Stage a live upload first, then pause mid-flight.
  assert (Result.isOk(Media.startUpload(s, a, alice, "u", #photo, "image/jpeg", 2)));
  assert (Result.isOk(Media.storeChunk(s, a, alice, "u", 0, Fix.jpeg_ok_64)));
  assert (Admin.setPaused(a, adminP, true));
  // The arm that matters: staged storage must not keep growing while paused.
  switch (Media.storeChunk(s, a, alice, "u", 1, Fix.png_ok_64)) {
    case (#err(#Paused)) {};
    case (_) { Debug.print("paused chunk NOT refused — storage can still grow"); assert false };
  };
  switch (Media.startUpload(s, a, alice, "w", #avatar, "image/jpeg", 1)) {
    case (#err(#Paused)) {};
    case (_) { assert false };
  };
  switch (Media.finishUpload(s, a, alice, "u")) {
    case (#err(#Paused)) {};
    case (_) { assert false };
  };
  assert (Media.storageStats(s).blobCount == 0);
  // Unpause and the same upload completes — pause is a gate, not a corruption.
  assert (Admin.setPaused(a, adminP, false));
  assert (Result.isOk(Media.storeChunk(s, a, alice, "u", 1, Fix.png_ok_64)));
  switch (Media.finishUpload(s, a, alice, "u")) {
    case (#ok(_)) {};
    case (#err(e)) { Debug.print("post-unpause finish failed: " # Media.errorText(e)); assert false };
  };
};

// 26. quota errors carry limit AND usage (M-1: a panel renders them).
do {
  let (s, a) = begin("typed quota error carries scope, limit and usage");
  let alice = p(0x13);
  for (i in Nat.range(0, Media.MAX_STAGED_PER_PRINCIPAL)) {
    assert (Result.isOk(Media.startUpload(s, a, alice, "s" # Nat.toText(i), #avatar, "image/jpeg", 1)));
  };
  switch (Media.startUpload(s, a, alice, "over", #avatar, "image/jpeg", 1)) {
    case (#err(#QuotaExceeded(q))) {
      assert (q.limit == Media.MAX_STAGED_PER_PRINCIPAL);
      assert (q.usage == Media.MAX_STAGED_PER_PRINCIPAL);
      assert (q.scope == "staged uploads for this principal");
    };
    case (_) { Debug.print("staging cap did not return a typed quota error"); assert false };
  };
  // Storage budget carries its three numbers.
  let (s2, a2) = begin("typed storage-full error carries cap, used and requested");
  s2.totalBytes := Media.MAX_MEDIA_BYTES - 10;
  switch (upload(s2, a2, p(0x14), "u", #avatar, "image/jpeg", Fix.jpeg_ok_64)) {
    case (#err(#StorageFull(f))) {
      assert (f.capBytes == 4026531840);
      assert (f.usedBytes == 4026531840 - 10);
      assert (f.requestedBytes == Fix.jpeg_ok_64.size());
    };
    case (_) { Debug.print("budget did not return a typed StorageFull"); assert false };
  };
};

// 27. admin-scoped listing (M-3).
do {
  let (s, a) = begin("listPathsFor is admin-scoped; bytes stay public by design");
  let alice = p(0x15);
  ignore ok(upload(s, a, alice, "u", #avatar, "image/jpeg", Fix.jpeg_ok_64));
  switch (Media.listPathsFor(s, a, alice)) {
    case (#err(#NotAdmin)) {};
    case (_) { Debug.print("non-admin could enumerate"); assert false };
  };
  switch (Media.listPathsFor(s, a, adminP)) {
    case (#ok(paths)) { assert (paths.size() == 1) };
    case (#err(_)) { assert false };
  };
  // The honest limit of that gate: the path itself still serves to anyone.
  let path = Media.listPaths(s)[0];
  assert (Media.httpRequest(s, { method = "GET"; url = path; headers = []; body = "" }).statusCode == 200);
};

// 28. THE DEFECT FIX: a shared content-addressed path is unlisted only at refcount zero.
do {
  let (s, a) = begin("shared photo path survives one owner's delete (fixed)");
  let alice = p(0x16);
  let bob = p(0x17);
  let body = Fix.gif_ok_64;
  let ra = ok(upload(s, a, alice, "x", #photo, "image/gif", body));
  ignore ok(upload(s, a, bob, "y", #photo, "image/gif", body));
  assert (Media.storageStats(s).blobCount == 1);
  assert (Media.storageStats(s).pathCount == 1);
  // Alice deletes: bob's media MUST keep serving.
  switch (Media.deletePhoto(s, alice, ra.sha256Hex)) {
    case (#ok(d)) { assert d };
    case (#err(_)) { assert false };
  };
  assert (Media.mediaInfo(s, ra.path) != null);
  assert (Media.httpRequest(s, { method = "GET"; url = ra.path; headers = []; body = "" }).statusCode == 200);
  assert (Media.storageStats(s).blobCount == 1);
  assert (Media.storageStats(s).totalBytes == body.size());
  // Alice really did lose ownership: deleting again is a no-op.
  switch (Media.deletePhoto(s, alice, ra.sha256Hex)) {
    case (#ok(d)) { assert (not d) };
    case (#err(_)) { assert false };
  };
  // Bob deletes: last reference drops, path unlisted, bytes reclaimed.
  switch (Media.deletePhoto(s, bob, ra.sha256Hex)) {
    case (#ok(d)) { assert d };
    case (#err(_)) { assert false };
  };
  assert (Media.mediaInfo(s, ra.path) == null);
  assert (Media.httpRequest(s, { method = "GET"; url = ra.path; headers = []; body = "" }).statusCode == 404);
  assert (Media.storageStats(s).blobCount == 0);
  assert (Media.storageStats(s).totalBytes == 0);
};

Debug.print("POLICY SUITE: " # Nat.toText(scenario) # " scenarios PASS");
