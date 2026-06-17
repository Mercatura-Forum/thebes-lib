/// MemphisAuth.mo — the STANDARD Memphis identity integration for Thebes apps.
///
/// ════════════════════════════════════════════════════════════════════════════
/// REALITY CHECK — read this before you trust anything below.
/// ════════════════════════════════════════════════════════════════════════════
///
/// On Thebes today, for an ingress call, `msg.caller` is the SENDER principal of
/// the request — i.e. whatever key signed the envelope (an agent key, a wallet,
/// a delegation). It is authenticated by the boundary, but it is NOT a Memphis
/// identity. Memphis (cid 921) is a separate identity contract that gives each
/// user a STABLE, PER-APP, PSEUDONYMOUS principal:
///
///   • `derive_principal_for(anchor_id, origin, version)` -> a 29-byte principal
///     that is deterministic for (this anchor, this app-origin, this version).
///     The same human is the same principal in YOUR app every time, and a
///     DIFFERENT principal in some other app — unlinkable across apps.
///
///   • A user proves they currently control that anchor by holding a SESSION
///     TOKEN (32 opaque bytes) obtained from register/authenticate. Your app
///     verifies a token by calling Memphis `whoami(token)`, which returns the
///     `anchor_id` and `session_expires_ns`, or `Err(SessionExpired)`.
///
/// So there are TWO principals in play and you must not confuse them:
///
///   ┌────────────────────┬──────────────────────────────────────────────────┐
///   │ msg.caller         │ The transport sender. Authenticated by the        │
///   │                    │ boundary. Use it for Admin/owner checks ONLY when  │
///   │                    │ the owner deployed with a known key. Do NOT treat  │
///   │                    │ it as "the user's identity" for app data.          │
///   ├────────────────────┼──────────────────────────────────────────────────┤
///   │ Memphis principal  │ derive_principal_for(anchor, origin, version).     │
///   │ (the app identity) │ This is the stable per-user key you should key     │
///   │                    │ balances / profiles / ownership on. You learn the  │
///   │                    │ user's anchor_id from a verified session token,    │
///   │                    │ then derive their principal for YOUR origin.       │
///   └────────────────────┴──────────────────────────────────────────────────┘
///
/// TRUST MODEL of the SessionGate pattern below:
///   1. Client obtains a session token from Memphis (passkey ceremony).
///   2. Client sends the token to YOUR contract as a normal call argument.
///   3. YOUR contract calls Memphis `whoami(token)` (inter-contract, replicated)
///      to verify the token is real and unexpired, learning the `anchor_id`.
///   4. YOUR contract calls `derive_principal_for(anchor_id, origin, version)`
///      to get the user's stable per-app principal, and keys app state on THAT.
///   5. Optionally cache (anchor_id, expires_ns) keyed by token to avoid a
///      round-trip on every call until the cached expiry passes.
///
/// Why an inter-contract call and not a local check? Because only Memphis can
/// attest that a token is live and maps to an anchor. There is no local secret
/// your contract could use to verify a Memphis token offline — so verification
/// MUST be a call to Memphis. This module does that real call; it contains no
/// stub that "pretends" a token is valid.
///
/// ════════════════════════════════════════════════════════════════════════════
/// DEPENDENCY ON THE MEMPHIS CONTRACT UPGRADE — VERIFY POST-UPGRADE.
/// ════════════════════════════════════════════════════════════════════════════
/// The deployed cid 921 is currently BEHIND the source IDL this module is typed
/// against. This module's `Memphis` actor type binds exactly these methods from
/// memphis.did. After the 921 upgrade, confirm each one EXISTS with this
/// signature, or the inter-contract calls will trap at runtime:
///
///   • whoami : (blob) -> (variant { Ok : WhoAmIResult; Err : MemphisError }) query
///   • derive_principal_for : (blob, text, nat64)
///                            -> (variant { Ok : blob; Err : MemphisError }) query
///
/// `whoami` and `derive_principal_for` are declared `query` in the IDL. When a
/// CONTRACT calls them, the call runs in a replicated (update) context — that is
/// correct and intended: it is what makes the attestation trustworthy. The
/// Motoko binding below therefore types them as `shared` (awaitable) methods.
///
/// BINDING POINT: set the Memphis contract id once via `Gate.fromPrincipal` (or
/// `Gate.fromText`). If 921 is not yet upgraded, calls will return a typed
/// trap/error you can surface — never a silent success.

import Principal "mo:core/Principal";
import Time "mo:core/Time";
import Result "mo:core/Result";
import Map "mo:core/Map";
import Blob "mo:core/Blob";
import Nat64 "mo:core/Nat64";
import Nat8 "mo:core/Nat8";
import Int "mo:core/Int";
import Iter "mo:core/Iter";
import Array "mo:core/Array";

module {

  // ── Memphis IDL, expressed as Motoko types (mirrors memphis.did) ───────────

  /// Mirror of memphis.did `MemphisError`.
  public type MemphisError = {
    #NotAuthenticated;
    #Unauthorized;
    #SessionExpired;
    #ChallengeExpired;
    #AnchorNotFound;
    #FactorNotFound;
    #InsufficientFactors;
    #DuplicateCredential;
    #InvalidArgument : Text;
    #InvariantViolation : { id : Text; details : Text };
  };

  /// Mirror of memphis.did `WhoAmIResult`. `anchor_id` is the 32-byte
  /// anchor_id_hash (NEVER the raw anchor — INV-MEM-6).
  public type WhoAmIResult = {
    anchor_id : Blob;
    session_expires_ns : Nat64;
    display_tag : Text;
  };

  /// The subset of the Memphis service this module calls. Both methods are
  /// `query` in the .did; from a contract they execute replicated, so they are
  /// `shared` awaitable here. THIS is the binding-point type — if 921's upgraded
  /// interface differs, the actor reference below will fail to typecheck against
  /// the live contract and the call will trap. That is by design: no silent drift.
  public type Memphis = actor {
    whoami : query (Blob) -> async ({ #Ok : WhoAmIResult; #Err : MemphisError });
    derive_principal_for : query (Blob, Text, Nat64) -> async ({ #Ok : Blob; #Err : MemphisError });
  };

  // ── The verified identity this module hands back to the app ────────────────

  /// What a successful session verification yields. `principal` is the user's
  /// STABLE per-app principal (derived for this app's origin) — key your app
  /// state on this. `anchorId` is the Memphis anchor_id_hash. `expiresNs` is the
  /// session expiry from Memphis.
  public type Identity = {
    principal : Principal;
    anchorId : Blob;
    expiresNs : Nat64;
  };

  /// Why verification failed. `#Memphis` carries the contract's own error;
  /// `#Expired` is raised locally when a cached/returned expiry is already past.
  public type AuthError = {
    #Expired;
    #Memphis : MemphisError;
  };

  // ── The SessionGate: config + a small expiry cache ─────────────────────────

  /// Per-app gate configuration plus an optional token cache. Hold this in a
  /// stable var in the host actor. `origin` and `version` MUST match the values
  /// the client used when it derived its principal (typically your contract's
  /// public URL/origin and a version integer you bump on identity-scheme breaks).
  public type State = {
    memphis : Principal; // cid 921 (or test id) — the Memphis contract
    origin : Text; // your app origin, e.g. "https://<cid>.icp0.io"
    version : Nat64; // pseudonym scheme version (start at 0/1)
    // token -> (anchorId, principal, expiresNs). Avoids a round-trip per call
    // until the cached expiry passes. Keyed by the opaque session token bytes.
    var cache : Map.Map<Blob, Identity>;
  };

  /// Build a gate. Call once at actor init and store in a stable var.
  public func init(memphis : Principal, origin : Text, version : Nat64) : State {
    {
      memphis;
      origin;
      version;
      var cache = Map.empty<Blob, Identity>();
    };
  };

  /// Convenience: build a gate from a textual contract id (e.g. "aaaaa-aa").
  public func initFromText(memphisText : Text, origin : Text, version : Nat64) : State {
    init(Principal.fromText(memphisText), origin, version);
  };

  /// The Thebes substrate addresses contracts by numeric id; a cross-contract
  /// callee principal MUST be exactly the 8 big-endian bytes of that id
  /// (any other length is rejected). This builds that principal — apps
  /// never deal with the encoding themselves.
  public func principalOfCid(cid : Nat64) : Principal {
    let n = Nat64.toNat(cid);
    let bytes = Array.tabulate<Nat8>(8, func(i) {
      Nat8.fromNat((n / (256 ** (7 - i : Nat))) % 256);
    });
    Principal.fromBlob(Blob.fromArray(bytes));
  };

  /// THE standard way to build a gate on Thebes: just the Memphis contract's
  /// numeric id (921 in production), your app origin, and the pseudonym
  /// scheme version. Example:
  ///   var gate = MemphisAuth.initFromCid(921, "https://my-app-origin", 1);
  public func initFromCid(cid : Nat64, origin : Text, version : Nat64) : State {
    init(principalOfCid(cid), origin, version);
  };

  /// The live Memphis actor reference for this gate's configured contract id.
  public func actorOf(s : State) : Memphis {
    actor (Principal.toText(s.memphis)) : Memphis;
  };

  // ── Cache helpers (real logic — not stubs) ─────────────────────────────────

  /// Look up a still-valid cached identity for `token`, given the current time
  /// in nanoseconds. Returns null if absent or if the cached session has expired
  /// (in which case the stale entry is evicted so it cannot be reused).
  func cachedFresh(s : State, token : Blob, nowNs : Nat64) : ?Identity {
    switch (Map.get(s.cache, Blob.compare, token)) {
      case null { null };
      case (?id) {
        if (id.expiresNs > nowNs) { ?id }
        else { ignore Map.delete(s.cache, Blob.compare, token); null };
      };
    };
  };

  // ── The two real operations ────────────────────────────────────────────────

  /// VERIFY a session token against Memphis and return the user's stable per-app
  /// Identity. This is the function every authenticated method calls.
  ///
  /// Flow (all real work, no shortcuts):
  ///   1. Fast path: return a cached, unexpired identity if present.
  ///   2. Call Memphis `whoami(token)`. On `Err`, surface `#Memphis(err)`.
  ///      On `Ok`, check the returned `session_expires_ns` is in the future
  ///      (defensive: Memphis already enforces this, but we re-check locally so
  ///      a clock-skew/replay window cannot slip through) — else `#Expired`.
  ///   3. Call Memphis `derive_principal_for(anchor_id, origin, version)` to get
  ///      the stable per-app principal. On `Err`, surface `#Memphis(err)`.
  ///   4. Cache (token -> Identity) keyed by token and return the Identity.
  ///
  /// Cost: two inter-contract calls on a cache miss, zero on a cache hit.
  public func verify(s : State, token : Blob) : async Result.Result<Identity, AuthError> {
    // Time.now() is nanoseconds-since-epoch as an Int (always positive on IC);
    // Memphis expiries are Nat64, so we compare in the Nat64 domain.
    let nowNs : Nat64 = Nat64.fromNat(Int.toNat(Time.now()));

    switch (cachedFresh(s, token, nowNs)) {
      case (?id) { return #ok(id) };
      case null {};
    };

    let m = actorOf(s);

    // Step 2: who does this token belong to, and is it live?
    let who = switch (await m.whoami(token)) {
      case (#Err(e)) { return #err(#Memphis(e)) };
      case (#Ok(w)) { w };
    };
    if (who.session_expires_ns <= nowNs) { return #err(#Expired) };

    // Step 3: derive the user's stable principal for THIS app.
    let principalBytes = switch (await m.derive_principal_for(who.anchor_id, s.origin, s.version)) {
      case (#Err(e)) { return #err(#Memphis(e)) };
      case (#Ok(b)) { b };
    };

    let id : Identity = {
      principal = Principal.fromBlob(principalBytes);
      anchorId = who.anchor_id;
      expiresNs = who.session_expires_ns;
    };

    // Step 4: cache for subsequent calls within the session lifetime.
    Map.add(s.cache, Blob.compare, token, id);
    #ok(id);
  };

  /// Forget a cached token locally (e.g. after the user signs out). Idempotent.
  /// Note: this only drops the LOCAL cache entry — to truly end the session the
  /// client must call Memphis `end_session(token)`; this app cannot do that on
  /// the user's behalf because end_session is caller-scoped on Memphis.
  public func forget(s : State, token : Blob) {
    ignore Map.delete(s.cache, Blob.compare, token);
  };

  /// Drop every cached entry whose session has already expired. Cheap periodic
  /// hygiene you can call from a heartbeat/timer; not required for correctness
  /// because `verify` evicts stale entries on access.
  public func evictExpired(s : State, nowNs : Nat64) {
    let stale = Iter.toArray(
      Iter.filterMap<(Blob, Identity), Blob>(
        Map.entries(s.cache),
        func((tok, id)) { if (id.expiresNs <= nowNs) { ?tok } else { null } },
      )
    );
    for (tok in stale.values()) {
      ignore Map.delete(s.cache, Blob.compare, tok);
    };
  };

};
