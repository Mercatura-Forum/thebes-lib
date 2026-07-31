/// Media.mo — on-chain, certified user media (logos, avatars, photos) as a
/// source-import module, ported from the Egypt-L1 Rust media canister.
///
/// A PURE MODULE (no actor, no state of its own). The host actor holds one
/// `Media.Store` in a top-level `let` (stable under `persistent actor`) and
/// passes it in — the `Admin.mo`/`Users.mo` pattern. Apps get media uploads
/// inside their OWN backend contract; no second canister to launch or pay for.
///
/// ## What you get
///   • Chunked uploads (≤ 32 KiB per chunk, begin/put/finalize) for three
///     media classes: `#avatar` (≤ 64 KiB, ≤ 256 px), `#photo` (≤ 512 KiB,
///     ≤ 1600 px) and `#logo name` (≤ 64 KiB, ≤ 256 px, admin-gated,
///     app-wide named slots).
///   • Content-addressed dedup: blobs are keyed by sha256(body) with a
///     refcount — identical bytes are stored once; replacing or deleting
///     media frees the bytes.
///   • Refused for the right reasons, with typed errors: `#Paused` while the
///     app is paused (uploads AND chunk writes — a pause that let staged
///     bytes accumulate would not be a pause), `#Anonymous` for the anonymous
///     principal, `#QuotaExceeded` carrying limit AND usage so a panel can
///     render "23 of 256". `errorText` renders any of them.
///   • Caller-gated writes: a principal writes only its own namespace
///     (`/avatar/{principal}`, its own photo set); logos require the caller
///     to pass the app's `Admin.State` admin check. Serve paths are derived
///     server-side — clients never choose arbitrary paths.
///   • Per-principal quotas (1 avatar slot, ≤ 256 photos), staging caps and
///     tick-based GC of abandoned uploads, and a global distinct-bytes
///     budget with a clean "storage full" error.
///   • Certified serve: a domain-separated binary Merkle tree over
///     `(path, sha256(body))`, byte-identical to the Rust reference
///     (`asset_tree.rs`, tags `thebes-asset-*-v1`), with per-path witnesses.
///
/// ## THE STORAGE CONTRACT (read before using)
/// Blob BYTES live in a `Region` (stable memory) with a free-list allocator —
/// the Motoko heap stays small and independent of how much media is stored.
/// Only the index (hashes, paths, quotas, staging) lives on the heap.
///
/// This module BOUNDS storage; it does NOT transform bytes. The Rust media
/// canister re-encodes images server-side (`media_process.rs`); a JPEG/WebP
/// codec is not feasible in Motoko, so the deliberate split is:
///   • the CLIENT (thebes-sdk `downscaleImage`) decodes + downscales +
///     re-encodes before upload;
///   • this module enforces, at finalize: the class byte cap, magic-byte ↔
///     declared content-type agreement (JPEG/PNG/WebP/GIF), and REAL
///     dimension extraction from the image headers (JPEG SOFn, PNG IHDR,
///     WebP VP8/VP8L/VP8X, GIF logical screen descriptor) against the class
///     dimension cap. What it cannot parse, it rejects.
/// Validation is header-bounded: bytes after the image header do not affect
/// the verdict (no CRC / full-bitstream decode — the cap bounds them).
///
/// ## THE CERTIFICATION SEAM
/// The Rust canister publishes the tree root via `ic0.certified_data_set` on
/// every mutation. A library module must not own that single per-canister
/// slot — the APP does. After any mutating call, the app republishes:
///
/// ```motoko
/// import CertifiedData "mo:core/CertifiedData";
/// CertifiedData.set(Media.root(media));                 // media-only apps
/// // apps certifying more than media combine subtree roots themselves, e.g.
/// // CertifiedData.set(appRoot(Media.root(media), otherRoot));
/// ```
///
/// `getMediaWithWitness` returns the served bytes + root + Merkle steps so a
/// client can verify a served path against the published root (the same
/// witness encoding the Rust canister serves — the browser verifier works
/// unchanged).
///
/// ## Errors
/// Mutating functions return `Result<_, Text>` and NEVER mutate state before
/// returning `#err` (the Rust reference's rollback discipline, kept function
/// by function). At the actor boundary use the `*OrTrap` twins: on this
/// engine `msg_reject` is swallowed (egypt-wasm host.rs:268), so failures
/// must trap — a trap rejects the call and reverts all state changes.
///
/// ## Integration sketch (app logo + per-user avatars)
/// ```motoko
/// persistent actor {
///   let admin = Admin.init();
///   let users = Users.init();
///   let media = Media.init();
///
///   public shared ({ caller }) func startUpload(id : Text, class_ : Media.Class, ct : Text, n : Nat) : async () {
///     Media.startUploadOrTrap(media, admin, caller, id, class_, ct, n);
///   };
///   public shared ({ caller }) func putChunk(id : Text, i : Nat, bytes : Blob) : async () {
///     Media.storeChunkOrTrap(media, caller, id, i, bytes);
///   };
///   public shared ({ caller }) func finishUpload(id : Text) : async Media.FinishReply {
///     let rep = Media.finishUploadOrTrap(media, admin, caller, id);
///     CertifiedData.set(Media.root(media));
///     rep;
///   };
///   public query func http_request(req : Media.HttpRequest) : async Media.HttpResponse {
///     Media.httpRequest(media, req);
///   };
/// }
/// ```
///
/// Ported from the Egypt-L1 media canister (`lib.rs` + `asset_tree.rs`).
/// Every constant and state transition below cites the reference at
/// file:line, and the three deliberate divergences — validate-don't-transcode
/// (see THE STORAGE CONTRACT above), blob bytes in a `Region` rather than the
/// heap, and the app-owned certification seam — are documented where they
/// occur. The certified tree is checked byte for byte against the Rust
/// reference by `test/run-tree-reference.sh`; run it after ANY change to the
/// tree, SHA-256, hex, or path-sort code.

import Map "mo:core/Map";
import Set "mo:core/Set";
import List "mo:core/List";
import Array "mo:core/Array";
import VarArray "mo:core/VarArray";
import Blob "mo:core/Blob";
import Text "mo:core/Text";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Region "mo:core/Region";
import Result "mo:core/Result";
import Char "mo:core/Char";
import Order "mo:core/Order";
import Runtime "mo:core/Runtime";
import Admin "Admin";

module {

  // ═══ Config — mirrors the reference canister's lib.rs:65-116; the
  // deliberate divergences are called out per constant ═══

  /// Max bytes per chunk (lib.rs:70 — the thebes-deploy chunk discipline).
  public let MAX_CHUNK_BYTES : Nat = 32768; // 32 KiB

  /// Per-class STORED byte caps. The Rust reference (Pass-3) accepts larger
  /// inputs and transcodes down (lib.rs:76-77); this module stores what it
  /// gets, so the caps are the reference's stored-size discipline
  /// (lib.rs:18-19 doc): avatar/logo ≤ 64 KiB, photo ≤ 512 KiB.
  public let AVATAR_MAX_BYTES : Nat = 65536; // 64 KiB
  public let PHOTO_MAX_BYTES : Nat = 524288; // 512 KiB
  public let LOGO_MAX_BYTES : Nat = 65536; // 64 KiB

  /// Per-class dimension ceilings (longest side), enforced from the image
  /// header at finalize. avatar/logo: lib.rs:82; photo: 1600 per the
  /// ratified SDK contract (diverges from lib.rs:83's 1280 transcode target).
  public let AVATAR_MAX_DIM : Nat = 256;
  public let PHOTO_MAX_DIM : Nat = 1600;
  public let LOGO_MAX_DIM : Nat = 256;

  /// Per-principal owned-photo cap (lib.rs:86). Avatars are one slot.
  public let MAX_PHOTOS_PER_PRINCIPAL : Nat = 256;

  /// App-wide named-logo cap (new class; bounded like every collection).
  public let MAX_LOGOS : Nat = 64;

  /// Global distinct-bytes budget (lib.rs:90-95): reject cleanly below the
  /// engine's hard 4 GiB canister cap, leaving 256 MiB headroom.
  public let MAX_MEDIA_BYTES : Nat64 = 4026531840; // 4 GiB - 256 MiB headroom

  /// Staging caps + GC budget (lib.rs:99-104). Ticks bump on every mutating
  /// call — no wall clock.
  public let MAX_STAGED_PER_PRINCIPAL : Nat = 4;
  public let MAX_CONCURRENT_STAGED_UPLOADS : Nat = 64;
  public let STAGING_GC_TICKS : Nat64 = 64;

  /// Allowed image content types. The reference excludes gif only because
  /// its transcoder cannot re-encode it (lib.rs:106-109); this module
  /// validates instead of transcoding, so GIF is allowed.
  let ALLOWED_IMAGE_TYPES : [Text] = ["image/webp", "image/png", "image/jpeg", "image/gif"];

  // ═══ Types ═══

  /// Media class. `#logo name` carries the app-wide slot name (validated:
  /// 1..=64 chars of [a-z0-9._-]); logos are admin-gated via `Admin.State`.
  public type Class = { #avatar; #photo; #logo : Text };

  /// Why a call was refused. Typed so a caller can render the reason —
  /// `#QuotaExceeded` carries the limit AND the usage at the moment of
  /// refusal, so a panel can show "23 of 256" without parsing prose.
  ///
  /// The `*OrTrap` twins turn any of these into a trap via `errorText`. That
  /// is deliberate and must stay: this engine swallows `msg_reject`, so a
  /// guarded actor method has to trap in order to both reject the call and
  /// roll back its state changes.
  public type MediaError = {
    #Paused;
    #Anonymous;
    #NotOwner;
    #NotAdmin;
    #QuotaExceeded : { scope : Text; limit : Nat; usage : Nat };
    #StorageFull : { capBytes : Nat; usedBytes : Nat; requestedBytes : Nat };
    #ChunkTooLarge : { limit : Nat; got : Nat };
    #IncompleteUpload : { missing : Nat; firstMissing : [Nat] };
    #NotFound : { what : Text };
    #Validation : { reason : Text };
  };

  /// Human-readable form of a `MediaError` (what the `*OrTrap` twins trap with).
  public func errorText(e : MediaError) : Text {
    switch (e) {
      case (#Paused) "contract is paused";
      case (#Anonymous) "the anonymous principal may not write media";
      case (#NotOwner) "not the owner of this upload";
      case (#NotAdmin) "caller is not an admin";
      case (#QuotaExceeded(q)) {
        q.scope # " quota exceeded: " # Nat.toText(q.usage) # " of " # Nat.toText(q.limit) # " used";
      };
      case (#StorageFull(s)) {
        "media storage full: stored " # Nat.toText(s.usedBytes) # " + "
        # Nat.toText(s.requestedBytes) # " would exceed cap " # Nat.toText(s.capBytes) # " bytes";
      };
      case (#ChunkTooLarge(c)) {
        "chunk body " # Nat.toText(c.got) # " bytes exceeds MAX_CHUNK_BYTES=" # Nat.toText(c.limit);
      };
      case (#IncompleteUpload(u)) {
        var idx = "";
        for (i in u.firstMissing.vals()) {
          idx #= (if (idx == "") "" else ", ") # Nat.toText(i);
        };
        "cannot finish: " # Nat.toText(u.missing) # " chunks still missing — indices [" # idx # "]";
      };
      case (#NotFound(n)) n.what # " not found";
      case (#Validation(v)) v.reason;
    };
  };

  /// Region-backed blob record: bytes live at [offset, offset+size) in the
  /// store's region; `refcount` counts pointers (avatar slots + photo-set
  /// memberships + logo slots), lib.rs:256-264.
  public type BlobMeta = {
    contentType : Text;
    offset : Nat64;
    size : Nat64;
    var refcount : Nat32;
  };

  /// In-progress chunked upload, bound to the principal that started it
  /// (lib.rs:266-276).
  public type Staged = {
    owner : Principal;
    mediaClass : Class;
    contentType : Text;
    totalChunks : Nat;
    chunks : [var ?Blob];
    var receivedCount : Nat;
    var lastActivityTicks : Nat64;
  };

  /// The full media state the host actor holds (lib.rs:278-305 + the Region
  /// blob store). All fields are stable types; hold it in a stable field of
  /// a `persistent actor`.
  public type Store = {
    /// Blob bytes (stable memory). Written once per distinct hash, reclaimed
    /// through `freeList` when the last reference drops.
    region : Region.Region;
    /// Next append offset (bytes) in `region`.
    var highWater : Nat64;
    /// Free extents: offset → length (bytes), coalesced on free.
    freeList : Map.Map<Nat64, Nat64>;
    /// Content-addressed index: sha256(body) → meta (+ refcount).
    blobs : Map.Map<Blob, BlobMeta>;
    /// One current avatar per principal.
    avatarOf : Map.Map<Principal, Blob>;
    /// Owned photos per principal (capped), addressed by hash.
    photosOf : Map.Map<Principal, Set.Set<Blob>>;
    /// App-wide named logo slots (admin-gated writes).
    logos : Map.Map<Text, Blob>;
    /// Serve path → blob hash. Single source of truth for BOTH http serving
    /// AND the certified merkle leaf set (lib.rs:293-296).
    pathIndex : Map.Map<Text, Blob>;
    /// In-flight chunked uploads, keyed by client-supplied upload id.
    staging : Map.Map<Text, Staged>;
    /// Monotonic tick; bumps on every mutating call (GC clock).
    var tick : Nat64;
    /// Sum of distinct (deduped) blob bytes currently stored.
    var totalBytes : Nat64;
  };

  public type FinishReply = {
    path : Text;
    sha256Hex : Text;
    size : Nat;
    contentType : Text;
  };

  public type ChunkProgress = {
    uploadId : Text;
    mediaClass : Text;
    contentType : Text;
    totalChunks : Nat;
    receivedCount : Nat;
    receivedIndices : [Nat];
    receivedBytes : Nat;
  };

  public type MediaInfo = {
    path : Text;
    contentType : Text;
    size : Nat;
    sha256Hex : Text;
  };

  public type StorageStats = {
    totalBytes : Nat;
    capBytes : Nat;
    blobCount : Nat;
    pathCount : Nat;
    /// Region telemetry (not in the Rust reply): allocated pages and
    /// free-list bytes, so an app can watch reclaim work.
    regionPages : Nat;
    freeListBytes : Nat;
  };

  public type HttpRequest = {
    method : Text;
    url : Text;
    headers : [(Text, Text)];
    body : Blob;
  };

  public type HttpResponse = {
    statusCode : Nat16;
    headers : [(Text, Text)];
    body : Blob;
  };

  // Certified-tree types — the asset_tree.rs surface (asset_tree.rs:38-127).
  public type Leaf = { path : Text; bodySha256 : Blob };
  public type WitnessStep = { sibling : Blob; siblingIsRight : Bool };
  public type Witness = { leafPath : Text; leafBodySha256 : Blob; steps : [WitnessStep] };

  public type CertifiedMediaReply = {
    statusCode : Nat16;
    contentType : Text;
    bodyBase64 : Text;
    bodySha256Hex : Text;
    assetTreeRootHex : Text;
    witness : {
      leafPath : Text;
      leafBodySha256Hex : Text;
      steps : [{ siblingHex : Text; siblingIsRight : Bool }];
    };
  };

  /// Fresh, empty store. Call once at actor init: `let media = Media.init();`
  public func init() : Store {
    {
      region = Region.new();
      var highWater = 0;
      freeList = Map.empty<Nat64, Nat64>();
      blobs = Map.empty<Blob, BlobMeta>();
      avatarOf = Map.empty<Principal, Blob>();
      photosOf = Map.empty<Principal, Set.Set<Blob>>();
      logos = Map.empty<Text, Blob>();
      pathIndex = Map.empty<Text, Blob>();
      staging = Map.empty<Text, Staged>();
      var tick = 0;
      var totalBytes = 0;
    };
  };

  // ═══ SHA-256 (self-contained; no external package per the vendored-
  // snapshot rule). Verified against NIST vectors in test/Media.test.mo and
  // transitively by the tree byte-for-byte reference check. ═══

  let SHA_K : [Nat32] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  /// One-shot SHA-256 over a byte array.
  public func sha256(msg : [Nat8]) : Blob {
    var h0 : Nat32 = 0x6a09e667;
    var h1 : Nat32 = 0xbb67ae85;
    var h2 : Nat32 = 0x3c6ef372;
    var h3 : Nat32 = 0xa54ff53a;
    var h4 : Nat32 = 0x510e527f;
    var h5 : Nat32 = 0x9b05688c;
    var h6 : Nat32 = 0x1f83d9ab;
    var h7 : Nat32 = 0x5be0cd19;

    let len = msg.size();
    let bitLen : Nat64 = Nat64.fromNat(len) * 8;
    // Total padded length: message + 0x80 + zeros + 8 length bytes.
    let padded = ((len + 8) / 64 + 1) * 64;

    // Byte at logical position i of the padded message.
    func byteAt(i : Nat) : Nat32 {
      if (i < len) {
        Nat32.fromNat(Nat8.toNat(msg[i]));
      } else if (i == len) {
        0x80;
      } else if (i + 8 < padded) {
        0;
      } else {
        // Big-endian 64-bit bit length in the trailing 8 bytes.
        let shift = Nat64.fromNat((padded - 1 - i) * 8);
        Nat32.fromNat(Nat64.toNat((bitLen >> shift) & 0xff));
      };
    };

    let w = VarArray.repeat<Nat32>(0, 64);
    var block = 0;
    let nBlocks = padded / 64;
    while (block < nBlocks) {
      let base = block * 64;
      var t = 0;
      while (t < 16) {
        let o = base + t * 4;
        w[t] := (byteAt(o) << 24) | (byteAt(o + 1) << 16) | (byteAt(o + 2) << 8) | byteAt(o + 3);
        t += 1;
      };
      while (t < 64) {
        let s0 = (w[t - 15] <>> 7) ^ (w[t - 15] <>> 18) ^ (w[t - 15] >> 3);
        let s1 = (w[t - 2] <>> 17) ^ (w[t - 2] <>> 19) ^ (w[t - 2] >> 10);
        w[t] := w[t - 16] +% s0 +% w[t - 7] +% s1;
        t += 1;
      };
      var a = h0; var b = h1; var c = h2; var d = h3;
      var e = h4; var f = h5; var g = h6; var h = h7;
      var r = 0;
      while (r < 64) {
        let S1 = (e <>> 6) ^ (e <>> 11) ^ (e <>> 25);
        let ch = (e & f) ^ (^e & g);
        let temp1 = h +% S1 +% ch +% SHA_K[r] +% w[r];
        let S0 = (a <>> 2) ^ (a <>> 13) ^ (a <>> 22);
        let maj = (a & b) ^ (a & c) ^ (b & c);
        let temp2 = S0 +% maj;
        h := g; g := f; f := e; e := d +% temp1;
        d := c; c := b; b := a; a := temp1 +% temp2;
        r += 1;
      };
      h0 +%= a; h1 +%= b; h2 +%= c; h3 +%= d;
      h4 +%= e; h5 +%= f; h6 +%= g; h7 +%= h;
      block += 1;
    };

    let out = VarArray.repeat<Nat8>(0, 32);
    let hs = [h0, h1, h2, h3, h4, h5, h6, h7];
    var i = 0;
    while (i < 8) {
      out[i * 4] := Nat8.fromNat(Nat32.toNat(hs[i] >> 24));
      out[i * 4 + 1] := Nat8.fromNat(Nat32.toNat((hs[i] >> 16) & 0xff));
      out[i * 4 + 2] := Nat8.fromNat(Nat32.toNat((hs[i] >> 8) & 0xff));
      out[i * 4 + 3] := Nat8.fromNat(Nat32.toNat(hs[i] & 0xff));
      i += 1;
    };
    Blob.fromArray(VarArray.toArray(out));
  };

  // ═══ Wire helpers — lib.rs:1188-1257 ═══

  /// Lowercase hex of a blob (lib.rs:1196).
  public func hexEncode(b : Blob) : Text {
    let hex = "0123456789abcdef";
    let hexChars = Text.toArray(hex);
    let bytes = Blob.toArray(b);
    var s = "";
    for (byte in bytes.vals()) {
      let n = Nat8.toNat(byte);
      s := s # Text.fromArray([hexChars[n / 16], hexChars[n % 16]]);
    };
    s;
  };

  /// Decode a 64-char hex string into a 32-byte blob (lib.rs:1206).
  public func hexDecode32(s : Text) : ?Blob {
    let cs = Text.toArray(s);
    if (cs.size() != 64) { return null };
    func val(c : Char) : ?Nat {
      let n = Nat32.toNat(Char.toNat32(c));
      if (n >= 0x30 and n <= 0x39) { ?(n - 0x30) }
      else if (n >= 0x61 and n <= 0x66) { ?(n - 0x61 + 10) }
      else if (n >= 0x41 and n <= 0x46) { ?(n - 0x41 + 10) }
      else { null };
    };
    let out = VarArray.repeat<Nat8>(0, 32);
    var i = 0;
    while (i < 32) {
      switch (val(cs[2 * i]), val(cs[2 * i + 1])) {
        case (?hi, ?lo) { out[i] := Nat8.fromNat(hi * 16 + lo) };
        case _ { return null };
      };
      i += 1;
    };
    ?Blob.fromArray(VarArray.toArray(out));
  };

  /// Standard base64 with padding (lib.rs:1229).
  public func base64Encode(input : [Nat8]) : Text {
    let alpha = Text.toArray("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/");
    var out = "";
    var i = 0;
    let n = input.size();
    while (i + 3 <= n) {
      let v = Nat8.toNat(input[i]) * 65536 + Nat8.toNat(input[i + 1]) * 256 + Nat8.toNat(input[i + 2]);
      out := out # Text.fromArray([alpha[v / 262144], alpha[(v / 4096) % 64], alpha[(v / 64) % 64], alpha[v % 64]]);
      i += 3;
    };
    let rem : Nat = n - i;
    if (rem == 1) {
      let v = Nat8.toNat(input[i]) * 65536;
      out := out # Text.fromArray([alpha[v / 262144], alpha[(v / 4096) % 64]]) # "==";
    } else if (rem == 2) {
      let v = Nat8.toNat(input[i]) * 65536 + Nat8.toNat(input[i + 1]) * 256;
      out := out # Text.fromArray([alpha[v / 262144], alpha[(v / 4096) % 64], alpha[(v / 64) % 64]]) # "=";
    };
    out;
  };

  func normalizePath(raw : Text) : Text {
    if (Text.startsWith(raw, #text "/")) { raw } else { "/" # raw };
  };

  // ═══ Certified tree — faithful port of asset_tree.rs ═══
  //
  // Domain-separated binary Merkle tree over (path, sha256(body)):
  //   leaf  = sha256("thebes-asset-leaf-v1" || u32_le(|path|) || path || bodyHash)
  //   node  = sha256("thebes-asset-node-v1" || left || right)
  //   empty = sha256("thebes-asset-empty-v1")
  // Leaves sorted by path BYTES (Rust String cmp = UTF-8 byte order); odd
  // level ends duplicate the last node (asset_tree.rs:95-111). The witness
  // step order and side flags match witness_for (asset_tree.rs:133-178).

  let LEAF_TAG : Text = "thebes-asset-leaf-v1";
  let NODE_TAG : Text = "thebes-asset-node-v1";
  let EMPTY_TAG : Text = "thebes-asset-empty-v1";

  func textBytes(t : Text) : [Nat8] { Blob.toArray(Text.encodeUtf8(t)) };

  /// UTF-8 byte-order comparison — EXACT parity with Rust's String cmp,
  /// which is what compute_root sorts by (asset_tree.rs:84).
  func pathCompare(a : Text, b : Text) : Order.Order {
    Blob.compare(Text.encodeUtf8(a), Text.encodeUtf8(b));
  };

  func concatBytes(parts : [[Nat8]]) : [Nat8] {
    var total = 0;
    for (p in parts.vals()) { total += p.size() };
    let out = VarArray.repeat<Nat8>(0, total);
    var pos = 0;
    for (p in parts.vals()) {
      for (byte in p.vals()) { out[pos] := byte; pos += 1 };
    };
    VarArray.toArray(out);
  };

  func u32le(n : Nat) : [Nat8] {
    [
      Nat8.fromNat(n % 256),
      Nat8.fromNat((n / 256) % 256),
      Nat8.fromNat((n / 65536) % 256),
      Nat8.fromNat((n / 16777216) % 256),
    ];
  };

  /// Leaf hash (asset_tree.rs:46-56).
  public func hashLeaf(path : Text, bodySha256 : Blob) : Blob {
    let pb = textBytes(path);
    sha256(concatBytes([textBytes(LEAF_TAG), u32le(pb.size()), pb, Blob.toArray(bodySha256)]));
  };

  /// Internal node hash (asset_tree.rs:59-65).
  public func hashInternal(left : Blob, right : Blob) : Blob {
    sha256(concatBytes([textBytes(NODE_TAG), Blob.toArray(left), Blob.toArray(right)]));
  };

  /// Constant empty-tree root (asset_tree.rs:70-74).
  public func emptyRoot() : Blob {
    sha256(textBytes(EMPTY_TAG));
  };

  func nextLevel(level : List.List<Blob>) : List.List<Blob> {
    let out = List.empty<Blob>();
    let n = List.size(level);
    var i = 0;
    while (i < n) {
      let left = List.at(level, i);
      // Odd level end: duplicate the last node (asset_tree.rs:100-106).
      let right = if (i + 1 < n) { List.at(level, i + 1) } else { List.at(level, i) };
      List.add(out, hashInternal(left, right));
      i += 2;
    };
    out;
  };

  func sortedLeafHashes(leaves : [Leaf]) : (sorted : [Leaf], level : List.List<Blob>) {
    let sorted = Array.sort<Leaf>(
      leaves,
      func(a : Leaf, b : Leaf) : Order.Order { pathCompare(a.path, b.path) },
    );
    let level = List.empty<Blob>();
    for (l in sorted.vals()) { List.add(level, hashLeaf(l.path, l.bodySha256)) };
    (sorted, level);
  };

  /// Root over a leaf set — insert-order independent (asset_tree.rs:79-93).
  public func computeRoot(leaves : [Leaf]) : Blob {
    if (leaves.size() == 0) { return emptyRoot() };
    let (_, l) = sortedLeafHashes(leaves);
    var level = l;
    while (List.size(level) > 1) { level := nextLevel(level) };
    List.at(level, 0);
  };

  /// Merkle proof for `targetPath`, or null if absent (asset_tree.rs:133-178).
  public func witnessFor(leaves : [Leaf], targetPath : Text) : ?Witness {
    if (leaves.size() == 0) { return null };
    let (sorted, l0) = sortedLeafHashes(leaves);
    var targetPos = 0;
    var found = false;
    label search for (i in Nat.range(0, sorted.size())) {
      if (sorted[i].path == targetPath) { targetPos := i; found := true; break search };
    };
    if (not found) { return null };
    let target = sorted[targetPos];

    var level = l0;
    var idx = targetPos;
    let steps = List.empty<WitnessStep>();
    while (List.size(level) > 1) {
      let pairStart = (idx / 2) * 2;
      let isLeft = idx == pairStart;
      let siblingIdx = if (isLeft) {
        if (pairStart + 1 < List.size(level)) { pairStart + 1 } else { pairStart };
      } else { pairStart };
      List.add(steps, { sibling = List.at(level, siblingIdx); siblingIsRight = isLeft });
      level := nextLevel(level);
      idx := idx / 2;
    };
    ?{
      leafPath = target.path;
      leafBodySha256 = target.bodySha256;
      steps = List.toArray(steps);
    };
  };

  /// Verify a witness against a root (asset_tree.rs:187-197).
  public func verifyWitness(w : Witness, root : Blob) : Bool {
    var current = hashLeaf(w.leafPath, w.leafBodySha256);
    for (step in w.steps.vals()) {
      current := if (step.siblingIsRight) {
        hashInternal(current, step.sibling);
      } else {
        hashInternal(step.sibling, current);
      };
    };
    current == root;
  };

  /// Leaves of the currently served set (lib.rs:416-425).
  public func currentLeaves(s : Store) : [Leaf] {
    let out = List.empty<Leaf>();
    for ((path, hash) in Map.entries(s.pathIndex)) {
      List.add(out, { path; bodySha256 = hash });
    };
    List.toArray(out);
  };

  /// The certified-tree root over the served set. The APP publishes this via
  /// `CertifiedData.set` after mutations (see the seam note in the header).
  public func root(s : Store) : Blob {
    computeRoot(currentLeaves(s));
  };

  // ═══ Region blob store (B) — bytes in stable memory, free-list reclaim ═══

  let PAGE_BYTES : Nat64 = 65536;

  func ensureCapacity(s : Store, endOffset : Nat64) {
    let pagesNeeded = (endOffset + PAGE_BYTES - 1) / PAGE_BYTES;
    let have = Region.size(s.region);
    if (pagesNeeded > have) {
      let got = Region.grow(s.region, pagesNeeded - have);
      if (got == 0xFFFF_FFFF_FFFF_FFFF) {
        Runtime.trap("Media: stable memory exhausted (Region.grow failed)");
      };
    };
  };

  /// Allocate `len` bytes: first free extent that fits (offset order), else
  /// append at the high-water mark.
  func regionAlloc(s : Store, len : Nat64) : Nat64 {
    if (len == 0) { return 0 };
    for ((off, elen) in Map.entries(s.freeList)) {
      if (elen >= len) {
        Map.remove(s.freeList, Nat64.compare, off);
        if (elen > len) {
          Map.add(s.freeList, Nat64.compare, off + len, elen - len);
        };
        return off;
      };
    };
    let off = s.highWater;
    ensureCapacity(s, off + len);
    s.highWater += len;
    off;
  };

  /// Return an extent to the free list, coalescing with byte-adjacent
  /// neighbours; extents ending at the high-water mark shrink it instead.
  func regionFree(s : Store, offset : Nat64, len : Nat64) {
    if (len == 0) { return };
    var off = offset;
    var l = len;
    // Merge with the next extent (starts exactly at off+l).
    switch ((Map.entriesFrom(s.freeList, Nat64.compare, off + l)).next()) {
      case (?(nOff, nLen)) {
        if (nOff == off + l) {
          Map.remove(s.freeList, Nat64.compare, nOff);
          l += nLen;
        };
      };
      case null {};
    };
    // Merge with the previous extent (ends exactly at off).
    if (off > 0) {
      switch ((Map.reverseEntriesFrom(s.freeList, Nat64.compare, off - 1)).next()) {
        case (?(pOff, pLen)) {
          if (pOff + pLen == off) {
            Map.remove(s.freeList, Nat64.compare, pOff);
            off := pOff;
            l += pLen;
          };
        };
        case null {};
      };
    };
    if (off + l == s.highWater) {
      // Reclaim the tail; absorb any free extent that now ends at the top.
      s.highWater := off;
      label absorb loop {
        switch ((Map.reverseEntries(s.freeList)).next()) {
          case (?(pOff, pLen)) {
            if (pOff + pLen == s.highWater) {
              Map.remove(s.freeList, Nat64.compare, pOff);
              s.highWater := pOff;
            } else { break absorb };
          };
          case null { break absorb };
        };
      };
    } else {
      Map.add(s.freeList, Nat64.compare, off, l);
    };
  };

  func readBlobBytes(s : Store, meta : BlobMeta) : Blob {
    Region.loadBlob(s.region, meta.offset, Nat64.toNat(meta.size));
  };

  // ═══ Refcount primitives — lib.rs:434-480 ═══

  /// Acquire a reference: dedup bump if the hash is stored; otherwise
  /// enforce the byte budget, write the bytes to the region and index them.
  /// Mutates NOTHING on #err (lib.rs:440-467).
  func acquire(s : Store, hash : Blob, contentType : Text, body : Blob) : Result.Result<(), MediaError> {
    switch (Map.get(s.blobs, Blob.compare, hash)) {
      case (?meta) {
        // Dedup: no new bytes (saturating like the Rust u32).
        if (meta.refcount < 0xFFFF_FFFF) { meta.refcount += 1 };
        return #ok;
      };
      case null {};
    };
    let len = Nat64.fromNat(body.size());
    if (s.totalBytes + len > MAX_MEDIA_BYTES) {
      return #err(#StorageFull({
        capBytes = Nat64.toNat(MAX_MEDIA_BYTES);
        usedBytes = Nat64.toNat(s.totalBytes);
        requestedBytes = Nat64.toNat(len);
      }));
    };
    let offset = regionAlloc(s, len);
    if (len > 0) { Region.storeBlob(s.region, offset, body) };
    Map.add(s.blobs, Blob.compare, hash, { contentType; offset; size = len; var refcount = 1 : Nat32 });
    s.totalBytes += len;
    #ok;
  };

  /// Release a reference; free the extent and reclaim the budget when the
  /// last pointer drops (lib.rs:471-480).
  func release(s : Store, hash : Blob) {
    switch (Map.get(s.blobs, Blob.compare, hash)) {
      case (?meta) {
        if (meta.refcount > 0) { meta.refcount -= 1 };
        if (meta.refcount == 0) {
          Map.remove(s.blobs, Blob.compare, hash);
          regionFree(s, meta.offset, meta.size);
          // Saturating like the Rust u64 (lib.rs:477).
          s.totalBytes := if (meta.size > s.totalBytes) 0 else s.totalBytes - meta.size;
        };
      };
      case null {};
    };
  };

  // ═══ Tick / GC — lib.rs:482-498 ═══

  func bumpTick(s : Store) : Nat64 {
    s.tick += 1;
    s.tick;
  };

  func gcStale(s : Store) {
    let now = s.tick;
    let dead = List.empty<Text>();
    for ((id, up) in Map.entries(s.staging)) {
      // Saturating like the Rust u64 (lib.rs:493).
      let age = if (up.lastActivityTicks > now) 0 : Nat64 else now - up.lastActivityTicks;
      if (age >= STAGING_GC_TICKS) { List.add(dead, id) };
    };
    for (id in List.values(dead)) { Map.remove(s.staging, Text.compare, id) };
  };

  func stagedCountFor(s : Store, owner : Principal) : Nat {
    var n = 0;
    for (up in Map.values(s.staging)) {
      if (Principal.equal(up.owner, owner)) { n += 1 };
    };
    n;
  };

  // ═══ Class policy — lib.rs:118-160 (caps per the ratified design) ═══

  func classMaxBytes(c : Class) : Nat {
    switch (c) {
      case (#avatar) AVATAR_MAX_BYTES;
      case (#photo) PHOTO_MAX_BYTES;
      case (#logo _) LOGO_MAX_BYTES;
    };
  };

  func classMaxDim(c : Class) : Nat {
    switch (c) {
      case (#avatar) AVATAR_MAX_DIM;
      case (#photo) PHOTO_MAX_DIM;
      case (#logo _) LOGO_MAX_DIM;
    };
  };

  /// Chunk-count ceiling = ceil(maxBytes / MAX_CHUNK_BYTES), lib.rs:149-151.
  func classMaxChunks(c : Class) : Nat {
    (classMaxBytes(c) + MAX_CHUNK_BYTES - 1) / MAX_CHUNK_BYTES;
  };

  func classText(c : Class) : Text {
    switch (c) {
      case (#avatar) "avatar";
      case (#photo) "photo";
      case (#logo _) "logo";
    };
  };

  func classAllowsContentType(ct : Text) : Bool {
    // All three classes are image classes.
    for (t in ALLOWED_IMAGE_TYPES.vals()) { if (t == ct) { return true } };
    false;
  };

  func validLogoName(name : Text) : Bool {
    let cs = Text.toArray(name);
    if (cs.size() == 0 or cs.size() > 64) { return false };
    for (c in cs.vals()) {
      let n = Nat32.toNat(Char.toNat32(c));
      let ok = (n >= 0x61 and n <= 0x7a) // a-z
        or (n >= 0x30 and n <= 0x39) // 0-9
        or n == 0x2d or n == 0x5f or n == 0x2e; // - _ .
      if (not ok) { return false };
    };
    true;
  };

  /// Logo writes are admin-gated (the Admin.mo pattern); checked at start
  /// AND at finish — the finish check is the security boundary (admin status
  /// can change mid-upload).
  func requireLogoAuthorized(admin : Admin.State, caller : Principal, c : Class) : Result.Result<(), MediaError> {
    switch (c) {
      case (#logo name) {
        if (not validLogoName(name)) {
          return #err(#Validation({ reason = "logo name must be 1..=64 chars of [a-z0-9._-]" }));
        };
        if (not Admin.isAdmin(admin, caller)) { return #err(#NotAdmin) };
        #ok;
      };
      case _ #ok;
    };
  };

  // ═══ Paths — lib.rs:386-410 ═══

  func avatarPath(caller : Principal) : Text { "/avatar/" # Principal.toText(caller) };
  func photoPath(hash : Blob) : Text { "/photo/" # hexEncode(hash) };
  func logoPath(name : Text) : Text { "/logo/" # name };

  // ═══ Image header validation — the decided replacement for
  // media_process.rs transcode: sniff magic, require declared content-type
  // agreement, extract REAL dimensions from the header, enforce the class
  // dimension cap. Reject anything unparseable. ═══

  type Dims = { mime : Text; width : Nat; height : Nat };

  func be16(b : [Nat8], i : Nat) : Nat { Nat8.toNat(b[i]) * 256 + Nat8.toNat(b[i + 1]) };
  func le16(b : [Nat8], i : Nat) : Nat { Nat8.toNat(b[i]) + Nat8.toNat(b[i + 1]) * 256 };
  func be32(b : [Nat8], i : Nat) : Nat {
    ((Nat8.toNat(b[i]) * 256 + Nat8.toNat(b[i + 1])) * 256 + Nat8.toNat(b[i + 2])) * 256 + Nat8.toNat(b[i + 3]);
  };
  func le24(b : [Nat8], i : Nat) : Nat {
    Nat8.toNat(b[i]) + Nat8.toNat(b[i + 1]) * 256 + Nat8.toNat(b[i + 2]) * 65536;
  };
  func le32(b : [Nat8], i : Nat) : Nat { le24(b, i) + Nat8.toNat(b[i + 3]) * 16777216 };

  func matchesAt(b : [Nat8], i : Nat, pat : [Nat8]) : Bool {
    if (i + pat.size() > b.size()) { return false };
    for (k in Nat.range(0, pat.size())) {
      if (b[i + k] != pat[k]) { return false };
    };
    true;
  };

  /// JPEG: walk the segment stream to the first SOFn frame header
  /// (C0-C3, C5-C7, C9-CB, CD-CF) and read height/width (big-endian).
  func parseJpeg(b : [Nat8]) : Result.Result<Dims, Text> {
    let n = b.size();
    if (n < 4 or b[0] != 0xff or b[1] != 0xd8) {
      return #err("jpeg: missing SOI marker");
    };
    var i = 2;
    label walk while (i + 1 < n) {
      if (b[i] != 0xff) { return #err("jpeg: expected marker at segment boundary") };
      // Skip fill bytes (a marker may be preceded by any number of 0xff).
      var j = i + 1;
      while (j < n and b[j] == 0xff) { j += 1 };
      if (j >= n) { return #err("jpeg: truncated before marker id") };
      let m = Nat8.toNat(b[j]);
      if (m == 0xd8 or m == 0x01 or (m >= 0xd0 and m <= 0xd7)) {
        // Standalone markers with no length field.
        i := j + 1;
        continue walk;
      };
      if (m == 0xd9) { return #err("jpeg: reached EOI without a frame header (SOF)") };
      if (m == 0xda) { return #err("jpeg: reached SOS without a frame header (SOF)") };
      if (j + 2 >= n) { return #err("jpeg: truncated segment length") };
      let segLen = be16(b, j + 1);
      if (segLen < 2) { return #err("jpeg: invalid segment length") };
      let isSof = (m >= 0xc0 and m <= 0xcf) and m != 0xc4 and m != 0xc8 and m != 0xcc;
      if (isSof) {
        if (j + 8 >= n) { return #err("jpeg: truncated SOF segment") };
        let h = be16(b, j + 4);
        let w = be16(b, j + 6);
        if (h == 0) { return #err("jpeg: DNL-deferred height (0) unsupported") };
        return #ok({ mime = "image/jpeg"; width = w; height = h });
      };
      i := j + 1 + segLen;
    };
    #err("jpeg: truncated before a frame header (SOF)");
  };

  /// PNG: 8-byte signature then the mandatory first IHDR chunk
  /// (length 13, type "IHDR", width/height big-endian u32 at 16/20).
  func parsePng(b : [Nat8]) : Result.Result<Dims, Text> {
    if (b.size() < 24) { return #err("png: truncated header") };
    if (be32(b, 8) != 13) { return #err("png: first chunk length is not IHDR's 13") };
    if (not matchesAt(b, 12, [0x49, 0x48, 0x44, 0x52])) {
      return #err("png: first chunk is not IHDR");
    };
    let w = be32(b, 16);
    let h = be32(b, 20);
    #ok({ mime = "image/png"; width = w; height = h });
  };

  /// GIF: "GIF87a"/"GIF89a" then the logical screen descriptor (u16 LE).
  func parseGif(b : [Nat8]) : Result.Result<Dims, Text> {
    if (b.size() < 10) { return #err("gif: truncated header") };
    let is87 = matchesAt(b, 0, [0x47, 0x49, 0x46, 0x38, 0x37, 0x61]);
    let is89 = matchesAt(b, 0, [0x47, 0x49, 0x46, 0x38, 0x39, 0x61]);
    if (not (is87 or is89)) { return #err("gif: bad version (want GIF87a/GIF89a)") };
    #ok({ mime = "image/gif"; width = le16(b, 6); height = le16(b, 8) });
  };

  /// WebP: RIFF/WEBP container; first chunk VP8 (lossy), VP8L (lossless) or
  /// VP8X (extended, canvas size).
  func parseWebp(b : [Nat8]) : Result.Result<Dims, Text> {
    if (b.size() < 30) { return #err("webp: truncated header") };
    if (not matchesAt(b, 8, [0x57, 0x45, 0x42, 0x50])) {
      return #err("webp: RIFF container is not WEBP");
    };
    if (matchesAt(b, 12, [0x56, 0x50, 0x38, 0x20])) { // "VP8 "
      // Lossy: 3-byte frame tag, start code 9d 01 2a, then 14-bit w/h (LE).
      if (not matchesAt(b, 23, [0x9d, 0x01, 0x2a])) {
        return #err("webp: VP8 start code not found");
      };
      let w = le16(b, 26) % 16384;
      let h = le16(b, 28) % 16384;
      return #ok({ mime = "image/webp"; width = w; height = h });
    };
    if (matchesAt(b, 12, [0x56, 0x50, 0x38, 0x4c])) { // "VP8L"
      if (b[20] != 0x2f) { return #err("webp: VP8L signature byte missing") };
      let v = le32(b, 21);
      let w = (v % 16384) + 1;
      let h = ((v / 16384) % 16384) + 1;
      return #ok({ mime = "image/webp"; width = w; height = h });
    };
    if (matchesAt(b, 12, [0x56, 0x50, 0x38, 0x58])) { // "VP8X"
      let w = le24(b, 24) + 1;
      let h = le24(b, 27) + 1;
      return #ok({ mime = "image/webp"; width = w; height = h });
    };
    #err("webp: unknown chunk fourcc (want VP8 /VP8L/VP8X)");
  };

  /// Sniff the container by magic bytes and extract header dimensions.
  func sniffImage(b : [Nat8]) : Result.Result<Dims, Text> {
    if (b.size() >= 3 and b[0] == 0xff and b[1] == 0xd8 and b[2] == 0xff) {
      return parseJpeg(b);
    };
    if (matchesAt(b, 0, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) {
      return parsePng(b);
    };
    if (matchesAt(b, 0, [0x47, 0x49, 0x46])) { return parseGif(b) };
    if (matchesAt(b, 0, [0x52, 0x49, 0x46, 0x46])) { return parseWebp(b) };
    #err("not a recognized image (magic-byte check failed)");
  };

  /// The finalize-time image gate: magic must parse, must AGREE with the
  /// declared content type (spoof reject) and fit the class dimension cap.
  func validateImage(b : [Nat8], declaredCt : Text, maxDim : Nat) : Result.Result<(), MediaError> {
    switch (sniffImage(b)) {
      case (#err(e)) { #err(#Validation({ reason = "image validation failed: " # e })) };
      case (#ok(d)) {
        if (d.mime != declaredCt) {
          return #err(#Validation({
            reason = "content_type mismatch: declared \"" # declaredCt # "\" but magic bytes are " # d.mime;
          }));
        };
        if (d.width == 0 or d.height == 0) {
          return #err(#Validation({ reason = "image has zero dimension" }));
        };
        if (d.width > maxDim or d.height > maxDim) {
          return #err(#Validation({
            reason = "image " # Nat.toText(d.width) # "x" # Nat.toText(d.height)
              # " exceeds max dimension " # Nat.toText(maxDim) # " for this class";
          }));
        };
        #ok;
      };
    };
  };

  // ═══ Uploads — lib.rs:500-611 ═══

  /// Begin a chunked upload. Check order matches do_start_upload
  /// (lib.rs:502-571); the logo admin/name gate runs where the Rust class
  /// parse sits.
  public func startUpload(
    s : Store,
    admin : Admin.State,
    caller : Principal,
    uploadId : Text,
    mediaClass : Class,
    contentType : Text,
    totalChunks : Nat,
  ) : Result.Result<(), MediaError> {
    // Pause stops storage from growing at all — so it gates every arm of the
    // upload path (start, chunk, finish), not just the ends.
    if (Admin.isPaused(admin)) { return #err(#Paused) };
    // The anonymous principal owns no namespace and cannot be held to a
    // quota, so it may not write media.
    if (Principal.isAnonymous(caller)) { return #err(#Anonymous) };
    switch (requireLogoAuthorized(admin, caller, mediaClass)) {
      case (#err(e)) { return #err(e) };
      case (#ok) {};
    };
    if (not classAllowsContentType(contentType)) {
      return #err(#Validation({
        reason = "content_type \"" # contentType # "\" not allowed for media_class " # classText(mediaClass);
      }));
    };
    // Byte length, matching Rust's String::len (lib.rs:522).
    let idBytes = Text.encodeUtf8(uploadId).size();
    if (idBytes == 0 or idBytes > 128) {
      return #err(#Validation({ reason = "upload_id must be 1..=128 chars" }));
    };
    if (totalChunks == 0) {
      return #err(#Validation({ reason = "total_chunks must be > 0" }));
    };
    if (totalChunks > classMaxChunks(mediaClass)) {
      return #err(#Validation({
        reason = "total_chunks exceeds ceiling of " # Nat.toText(classMaxChunks(mediaClass))
          # " for " # classText(mediaClass);
      }));
    };
    ignore bumpTick(s);
    gcStale(s);
    if (Map.size(s.staging) >= MAX_CONCURRENT_STAGED_UPLOADS) {
      return #err(#QuotaExceeded({
        scope = "concurrent staged uploads";
        limit = MAX_CONCURRENT_STAGED_UPLOADS;
        usage = Map.size(s.staging);
      }));
    };
    if (stagedCountFor(s, caller) >= MAX_STAGED_PER_PRINCIPAL) {
      return #err(#QuotaExceeded({
        scope = "staged uploads for this principal";
        limit = MAX_STAGED_PER_PRINCIPAL;
        usage = stagedCountFor(s, caller);
      }));
    };
    if (Map.containsKey(s.staging, Text.compare, uploadId)) {
      return #err(#Validation({
        reason = "upload_id \"" # uploadId # "\" already in progress — use chunk_progress to resume";
      }));
    };
    Map.add(
      s.staging,
      Text.compare,
      uploadId,
      {
        owner = caller;
        mediaClass;
        contentType;
        totalChunks;
        chunks = VarArray.repeat<?Blob>(null, totalChunks);
        var receivedCount = 0;
        var lastActivityTicks = s.tick;
      },
    );
    #ok;
  };

  /// Store one chunk (≤ 32 KiB). Order matches do_store_chunk
  /// (lib.rs:573-611): size gate FIRST, then tick/gc/lookup/owner/range.
  public func storeChunk(
    s : Store,
    admin : Admin.State,
    caller : Principal,
    uploadId : Text,
    chunkIndex : Nat,
    body : Blob,
  ) : Result.Result<(), MediaError> {
    // Pause must block chunk writes too: gating only start and finish would
    // still let staged storage grow while the contract is paused, which is
    // the one thing pause exists to stop.
    if (Admin.isPaused(admin)) { return #err(#Paused) };
    if (Principal.isAnonymous(caller)) { return #err(#Anonymous) };
    if (body.size() > MAX_CHUNK_BYTES) {
      return #err(#ChunkTooLarge({ limit = MAX_CHUNK_BYTES; got = body.size() }));
    };
    let tick = bumpTick(s);
    gcStale(s);
    switch (Map.get(s.staging, Text.compare, uploadId)) {
      case null {
        #err(#NotFound({ what = "upload_id \"" # uploadId # "\" (GC'd or never started)" }));
      };
      case (?up) {
        if (not Principal.equal(up.owner, caller)) { return #err(#NotOwner) };
        if (chunkIndex >= up.totalChunks) {
          return #err(#Validation({
            reason = "chunk_index " # Nat.toText(chunkIndex) # " out of range (total_chunks = "
              # Nat.toText(up.totalChunks) # ")";
          }));
        };
        let firstTime = up.chunks[chunkIndex] == null;
        up.chunks[chunkIndex] := ?body;
        if (firstTime) { up.receivedCount += 1 };
        up.lastActivityTicks := tick;
        #ok;
      };
    };
  };

  // ═══ Finalize — lib.rs:613-800 ═══

  /// The photo arm of do_finish_upload via store_owned_by_hash
  /// (lib.rs:627-658): quota only for NOT-already-owned; acquire before
  /// recording ownership so a rejection leaves no dangling entry.
  func storeOwnedPhoto(
    s : Store,
    caller : Principal,
    hash : Blob,
    contentType : Text,
    body : Blob,
  ) : Result.Result<Text, MediaError> {
    let path = photoPath(hash);
    let ownedSet = Map.get(s.photosOf, Principal.compare, caller);
    let already = switch (ownedSet) {
      case (?set) Set.contains(set, Blob.compare, hash);
      case null false;
    };
    if (not already) {
      let count = switch (ownedSet) { case (?set) Set.size(set); case null 0 };
      if (count >= MAX_PHOTOS_PER_PRINCIPAL) {
        return #err(#QuotaExceeded({
          scope = "photos for this principal"; limit = MAX_PHOTOS_PER_PRINCIPAL; usage = count;
        }));
      };
      switch (acquire(s, hash, contentType, body)) {
        case (#err(e)) { return #err(e) };
        case (#ok) {};
      };
      let set = switch (ownedSet) {
        case (?set) set;
        case null {
          let fresh = Set.empty<Blob>();
          Map.add(s.photosOf, Principal.compare, caller, fresh);
          fresh;
        };
      };
      Set.add(set, Blob.compare, hash);
    };
    Map.add(s.pathIndex, Text.compare, path, hash);
    #ok(path);
  };

  /// Avatar arm (lib.rs:745-759) generalized to any single-slot map —
  /// avatars (key: principal) and logos (key: name) share it. Acquire-new
  /// BEFORE release-old so an identical-byte re-set never transiently frees
  /// a shared blob; idempotent same-hash re-set touches neither.
  func storeSlot<K>(
    s : Store,
    slots : Map.Map<K, Blob>,
    compare : (K, K) -> Order.Order,
    key : K,
    path : Text,
    hash : Blob,
    contentType : Text,
    body : Blob,
    slotCap : ?Nat,
  ) : Result.Result<Text, MediaError> {
    let old = Map.get(slots, compare, key);
    if (old != ?hash) {
      switch (slotCap) {
        case (?cap) {
          if (old == null and Map.size(slots) >= cap) {
            return #err(#QuotaExceeded({
              scope = "logo slots"; limit = cap; usage = Map.size(slots);
            }));
          };
        };
        case null {};
      };
      switch (acquire(s, hash, contentType, body)) {
        case (#err(e)) { return #err(e) };
        case (#ok) {};
      };
      switch (old) { case (?oldHash) { release(s, oldHash) }; case null {} };
      Map.add(slots, compare, key, hash);
    };
    Map.add(s.pathIndex, Text.compare, path, hash);
    #ok(path);
  };

  /// Finalize an upload: assemble, enforce the byte cap, validate the image
  /// header (the validation gate), content-address, dedup/quota, point the serve
  /// path. Mirrors do_finish_upload (lib.rs:662-800) step for step; after a
  /// successful finish the app republishes `Media.root` (the seam).
  public func finishUpload(
    s : Store,
    admin : Admin.State,
    caller : Principal,
    uploadId : Text,
  ) : Result.Result<FinishReply, MediaError> {
    if (Admin.isPaused(admin)) { return #err(#Paused) };
    if (Principal.isAnonymous(caller)) { return #err(#Anonymous) };
    ignore bumpTick(s);
    gcStale(s);
    // Ownership check BEFORE removal (lib.rs:669-678).
    switch (Map.get(s.staging, Text.compare, uploadId)) {
      case null { return #err(#NotFound({ what = "upload_id \"" # uploadId # "\"" })) };
      case (?up) {
        if (not Principal.equal(up.owner, caller)) { return #err(#NotOwner) };
      };
    };
    let up = switch (Map.take(s.staging, Text.compare, uploadId)) {
      case (?u) u;
      case null { Runtime.trap("Media: staging entry vanished") }; // unreachable
    };

    // The finish-time logo gate (the security boundary for #logo).
    switch (requireLogoAuthorized(admin, caller, up.mediaClass)) {
      case (#err(e)) {
        Map.add(s.staging, Text.compare, uploadId, up); // retryable, like missing chunks
        return #err(e);
      };
      case (#ok) {};
    };

    // All chunks present? (lib.rs:681-698 — first ≤16 missing indices,
    // Rust {:?} list format; staging restored for a partial retry.)
    let missing = List.empty<Nat>();
    for (i in Nat.range(0, up.totalChunks)) {
      if (up.chunks[i] == null) { List.add(missing, i) };
    };
    if (List.size(missing) > 0) {
      let previewCount = Nat.min(List.size(missing), 16);
      let preview = Array.tabulate<Nat>(previewCount, func(i : Nat) : Nat { List.at(missing, i) });
      Map.add(s.staging, Text.compare, uploadId, up);
      return #err(#IncompleteUpload({ missing = List.size(missing); firstMissing = preview }));
    };

    // Assemble (lib.rs:700-713) + byte cap.
    var totalLen = 0;
    for (c in up.chunks.vals()) {
      switch (c) { case (?blob) { totalLen += blob.size() }; case null {} };
    };
    if (totalLen > classMaxBytes(up.mediaClass)) {
      return #err(#Validation({
        reason = "assembled body " # Nat.toText(totalLen) # " bytes exceeds " # classText(up.mediaClass)
          # " cap of " # Nat.toText(classMaxBytes(up.mediaClass));
      }));
    };
    let bytes = VarArray.repeat<Nat8>(0, totalLen);
    var pos = 0;
    for (c in up.chunks.vals()) {
      switch (c) {
        case (?blob) {
          for (byte in blob.vals()) { bytes[pos] := byte; pos += 1 };
        };
        case null {};
      };
    };
    let body = VarArray.toArray(bytes);

    // The image gate (replaces the Rust transcode, lib.rs:715-739).
    switch (validateImage(body, up.contentType, classMaxDim(up.mediaClass))) {
      case (#err(e)) { return #err(e) };
      case (#ok) {};
    };

    let bodyBlob = Blob.fromArray(body);
    let hash = sha256(body);
    let size = totalLen;

    let pathResult = switch (up.mediaClass) {
      case (#avatar) {
        storeSlot<Principal>(
          s, s.avatarOf, Principal.compare, caller,
          avatarPath(caller), hash, up.contentType, bodyBlob, null,
        );
      };
      case (#photo) { storeOwnedPhoto(s, caller, hash, up.contentType, bodyBlob) };
      case (#logo name) {
        storeSlot<Text>(
          s, s.logos, Text.compare, name,
          logoPath(name), hash, up.contentType, bodyBlob, ?MAX_LOGOS,
        );
      };
    };
    switch (pathResult) {
      case (#err(e)) { #err(e) };
      case (#ok(path)) {
        #ok({ path; sha256Hex = hexEncode(hash); size; contentType = up.contentType });
      };
    };
  };

  /// Drop the caller's own staged upload (lib.rs:919-936): true = cleared,
  /// false = absent or not the caller's (never an error).
  public func resetStaging(s : Store, caller : Principal, uploadId : Text) : Bool {
    ignore bumpTick(s);
    switch (Map.get(s.staging, Text.compare, uploadId)) {
      case (?up) {
        if (Principal.equal(up.owner, caller)) {
          Map.remove(s.staging, Text.compare, uploadId);
          true;
        } else { false };
      };
      case null false;
    };
  };

  /// Remove the caller's avatar (lib.rs:802-813).
  public func clearAvatar(s : Store, caller : Principal) : Bool {
    ignore bumpTick(s);
    switch (Map.take(s.avatarOf, Principal.compare, caller)) {
      case (?old) {
        Map.remove(s.pathIndex, Text.compare, avatarPath(caller));
        release(s, old);
        true;
      };
      case null false;
    };
  };

  /// Delete one of the caller's photos by content hash (lib.rs:815-828).
  /// Ported quirk kept intentionally: the shared content-addressed path is
  /// unlisted even if another principal still owns the same hash (the bytes
  /// survive via refcount; a re-upload relists) — see the report.
  public func deletePhoto(s : Store, caller : Principal, sha256Hex : Text) : Result.Result<Bool, MediaError> {
    if (Principal.isAnonymous(caller)) { return #err(#Anonymous) };
    let hash = switch (hexDecode32(sha256Hex)) {
      case (?h) h;
      case null { return #err(#Validation({ reason = "sha256_hex must be 64 hex chars" })) };
    };
    ignore bumpTick(s);
    let owned = switch (Map.get(s.photosOf, Principal.compare, caller)) {
      case (?set) Set.delete(set, Blob.compare, hash);
      case null false;
    };
    if (owned) {
      release(s, hash);
      // Photo paths are content-addressed, so two principals uploading
      // identical bytes SHARE one `/photo/{hash}`. Unlist it only when the
      // last reference drops — otherwise one owner's delete would stop
      // serving another owner's live media. `release` removes the blob
      // entry exactly when the refcount reaches zero.
      if (not Map.containsKey(s.blobs, Blob.compare, hash)) {
        Map.remove(s.pathIndex, Text.compare, photoPath(hash));
      };
    };
    #ok(owned);
  };

  /// Delete a named logo slot (admin-gated; new-class analog of clearAvatar).
  public func deleteLogo(s : Store, admin : Admin.State, caller : Principal, name : Text) : Result.Result<Bool, MediaError> {
    if (not Admin.isAdmin(admin, caller)) { return #err(#NotAdmin) };
    ignore bumpTick(s);
    switch (Map.take(s.logos, Text.compare, name)) {
      case (?old) {
        Map.remove(s.pathIndex, Text.compare, logoPath(name));
        release(s, old);
        #ok(true);
      };
      case null { #ok(false) };
    };
  };

  // ═══ Queries — lib.rs:830-858, 960-1093, 1139-1184 ═══

  /// Progress snapshot for a staged upload (lib.rs:830-858).
  public func chunkProgress(s : Store, uploadId : Text) : ?ChunkProgress {
    switch (Map.get(s.staging, Text.compare, uploadId)) {
      case null null;
      case (?up) {
        let idx = List.empty<Nat>();
        var bytes = 0;
        for (i in Nat.range(0, up.totalChunks)) {
          switch (up.chunks[i]) {
            case (?blob) { List.add(idx, i); bytes += blob.size() };
            case null {};
          };
        };
        ?{
          uploadId;
          mediaClass = classText(up.mediaClass);
          contentType = up.contentType;
          totalChunks = up.totalChunks;
          receivedCount = up.receivedCount;
          receivedIndices = List.toArray(idx);
          receivedBytes = bytes;
        };
      };
    };
  };

  /// Look up an avatar by principal TEXT — the text is the path component,
  /// no decode (lib.rs:1022-1039).
  public func getAvatar(s : Store, principalText : Text) : ?{ path : Text; sha256Hex : Text } {
    let path = "/avatar/" # principalText;
    switch (Map.get(s.pathIndex, Text.compare, path)) {
      case (?hash) ?{ path; sha256Hex = hexEncode(hash) };
      case null null;
    };
  };

  /// Look up a named logo slot (new-class analog of getAvatar).
  public func getLogo(s : Store, name : Text) : ?{ path : Text; sha256Hex : Text } {
    let path = logoPath(name);
    switch (Map.get(s.pathIndex, Text.compare, path)) {
      case (?hash) ?{ path; sha256Hex = hexEncode(hash) };
      case null null;
    };
  };

  /// Metadata for a served path (lib.rs:1041-1060).
  public func mediaInfo(s : Store, rawPath : Text) : ?MediaInfo {
    let path = normalizePath(rawPath);
    switch (Map.get(s.pathIndex, Text.compare, path)) {
      case (?hash) {
        switch (Map.get(s.blobs, Blob.compare, hash)) {
          case (?meta) {
            ?{
              path;
              contentType = meta.contentType;
              size = Nat64.toNat(meta.size);
              sha256Hex = hexEncode(hash);
            };
          };
          case null null;
        };
      };
      case null null;
    };
  };

  /// Admin-scoped listing. Refuses a non-admin caller, so a panel can expose
  /// "everything this app stores" without handing an enumeration to anyone
  /// who asks.
  ///
  /// BE CLEAR ABOUT WHAT THIS BUYS. `pathIndex` IS the public serve set:
  /// every path in it is deliberately fetchable by anyone through
  /// `httpRequest` — that is what certified serving means. Gating the listing
  /// buys ENUMERATION RESISTANCE (photo paths are `/photo/{sha256}`, so they
  /// are unguessable), NOT confidentiality. A path that leaks once is public
  /// forever. Media that must stay private needs a different design —
  /// access-checked or encrypted serve — which this module does not do.
  public func listPathsFor(
    s : Store,
    admin : Admin.State,
    caller : Principal,
  ) : Result.Result<[Text], MediaError> {
    if (not Admin.isAdmin(admin, caller)) { return #err(#NotAdmin) };
    #ok(listPaths(s));
  };

  /// All served paths in byte order (lib.rs:1062-1070). Unscoped: for the
  /// host actor's own use. Expose `listPathsFor` to callers.
  public func listPaths(s : Store) : [Text] {
    let out = List.empty<Text>();
    for (path in Map.keys(s.pathIndex)) { List.add(out, path) };
    Array.sort<Text>(List.toArray(out), pathCompare);
  };

  /// Storage budget observability (lib.rs:1072-1093 + region telemetry).
  public func storageStats(s : Store) : StorageStats {
    var freeBytes : Nat64 = 0;
    for (len in Map.values(s.freeList)) { freeBytes += len };
    {
      totalBytes = Nat64.toNat(s.totalBytes);
      capBytes = Nat64.toNat(MAX_MEDIA_BYTES);
      blobCount = Map.size(s.blobs);
      pathCount = Map.size(s.pathIndex);
      regionPages = Nat64.toNat(Region.size(s.region));
      freeListBytes = Nat64.toNat(freeBytes);
    };
  };

  /// Serve a path over the IC HTTP gateway shape (lib.rs:981-1020): strip
  /// the query string, ensure a leading '/', 200 with the blob's
  /// content-type + no-cache revalidate, else a plain-text 404.
  public func httpRequest(s : Store, req : HttpRequest) : HttpResponse {
    var path = normalizePath(req.url);
    switch ((Text.split(path, #char '?')).next()) {
      case (?head) { path := head };
      case null {};
    };
    switch (Map.get(s.pathIndex, Text.compare, path)) {
      case (?hash) {
        switch (Map.get(s.blobs, Blob.compare, hash)) {
          case (?meta) {
            return {
              statusCode = 200;
              headers = [
                ("content-type", meta.contentType),
                ("cache-control", "no-cache, must-revalidate"), // lib.rs:975-979
              ];
              body = readBlobBytes(s, meta);
            };
          };
          case null {};
        };
      };
      case null {};
    };
    {
      statusCode = 404;
      headers = [("content-type", "text/plain")];
      body = Text.encodeUtf8("not found: " # path);
    };
  };

  /// Certified read: served bytes + tree root + Merkle witness
  /// (lib.rs:1139-1184). The 404 shape carries the root, a zero leaf hash
  /// and no steps — exactly the reference's absent reply.
  public func getMediaWithWitness(s : Store, rawPath : Text) : CertifiedMediaReply {
    let path = normalizePath(rawPath);
    let leaves = currentLeaves(s);
    let treeRoot = computeRoot(leaves);
    let served = switch (Map.get(s.pathIndex, Text.compare, path)) {
      case (?hash) {
        switch (Map.get(s.blobs, Blob.compare, hash)) {
          case (?meta) ?(hash, meta);
          case null null;
        };
      };
      case null null;
    };
    switch (served) {
      case null {
        let missBody = textBytes("not found: " # path);
        {
          statusCode = 404;
          contentType = "text/plain; charset=utf-8";
          bodyBase64 = base64Encode(missBody);
          bodySha256Hex = hexEncode(sha256(missBody));
          assetTreeRootHex = hexEncode(treeRoot);
          witness = {
            leafPath = path;
            leafBodySha256Hex = hexEncode(Blob.fromArray(Array.repeat<Nat8>(0, 32)));
            steps = [];
          };
        };
      };
      case (?(hash, meta)) {
        let w = switch (witnessFor(leaves, path)) {
          case (?w) w;
          case null { Runtime.trap("Media: witness_for must succeed for a known path") };
        };
        let steps = Array.map<WitnessStep, { siblingHex : Text; siblingIsRight : Bool }>(
          w.steps,
          func(st : WitnessStep) : { siblingHex : Text; siblingIsRight : Bool } {
            { siblingHex = hexEncode(st.sibling); siblingIsRight = st.siblingIsRight };
          },
        );
        {
          statusCode = 200;
          contentType = meta.contentType;
          bodyBase64 = base64Encode(Blob.toArray(readBlobBytes(s, meta)));
          bodySha256Hex = hexEncode(hash);
          assetTreeRootHex = hexEncode(treeRoot);
          witness = {
            leafPath = w.leafPath;
            leafBodySha256Hex = hexEncode(w.leafBodySha256);
            steps;
          };
        };
      };
    };
  };

  // ═══ *OrTrap twins — the actor-boundary form. This engine swallows
  // msg_reject (host.rs:268), so guarded methods must trap: the trap
  // rejects the call AND rolls back every state change (lib.rs:353-367). ═══

  public func startUploadOrTrap(
    s : Store,
    admin : Admin.State,
    caller : Principal,
    uploadId : Text,
    mediaClass : Class,
    contentType : Text,
    totalChunks : Nat,
  ) {
    switch (startUpload(s, admin, caller, uploadId, mediaClass, contentType, totalChunks)) {
      case (#err(e)) { Runtime.trap("Media: " # errorText(e)) };
      case (#ok) {};
    };
  };

  public func storeChunkOrTrap(
    s : Store,
    admin : Admin.State,
    caller : Principal,
    uploadId : Text,
    chunkIndex : Nat,
    body : Blob,
  ) {
    switch (storeChunk(s, admin, caller, uploadId, chunkIndex, body)) {
      case (#err(e)) { Runtime.trap("Media: " # errorText(e)) };
      case (#ok) {};
    };
  };

  public func finishUploadOrTrap(s : Store, admin : Admin.State, caller : Principal, uploadId : Text) : FinishReply {
    switch (finishUpload(s, admin, caller, uploadId)) {
      case (#err(e)) { Runtime.trap("Media: " # errorText(e)) };
      case (#ok(rep)) rep;
    };
  };

  public func deletePhotoOrTrap(s : Store, caller : Principal, sha256Hex : Text) : Bool {
    switch (deletePhoto(s, caller, sha256Hex)) {
      case (#err(e)) { Runtime.trap("Media: " # errorText(e)) };
      case (#ok(b)) b;
    };
  };

  public func deleteLogoOrTrap(s : Store, admin : Admin.State, caller : Principal, name : Text) : Bool {
    switch (deleteLogo(s, admin, caller, name)) {
      case (#err(e)) { Runtime.trap("Media: " # errorText(e)) };
      case (#ok(b)) b;
    };
  };

};
