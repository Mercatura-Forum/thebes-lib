/// MemphisAuth.mo — the STANDARD Memphis identity integration for Thebes apps.
///
/// ════════════════════════════════════════════════════════════════════════════
/// THE IDENTITY MODEL
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
///     verifies a token by calling Memphis `whoami_scoped_u(token, audience)`,
///     which returns the `anchor_id` and `session_expires_ns`, or an `Err`.
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
///   1. Client obtains an ORIGIN-SCOPED token from Memphis for YOUR origin
///      (passkey ceremony, then `issue_scoped_session`).
///   2. Client sends that token to YOUR contract as a normal call argument.
///   3. YOUR contract calls `whoami_scoped_u(token, audience)` (inter-contract,
///      replicated) to verify the token is real, unexpired, AND was minted for
///      your web origin — learning the `anchor_id`.
///   4. YOUR contract calls `derive_principal_for(anchor_id, origin, version)`
///      to get the user's stable per-app principal, and keys app state on THAT.
///   5. Optionally cache (anchor_id, expires_ns) keyed by token to avoid a
///      round-trip on every call until the cached expiry passes.
///
/// Why an inter-contract call and not a local check? Because only Memphis can
/// attest that a token is live and maps to an anchor. There is no local secret
/// your contract could use to verify a Memphis token offline — so verification
/// MUST be a call to Memphis.
///
/// ════════════════════════════════════════════════════════════════════════════
/// BREAKING CHANGE — TOKENS ARE NOW BOUND TO YOUR ORIGIN
/// ════════════════════════════════════════════════════════════════════════════
/// Earlier versions of this module called `whoami(token)`, which resolves a
/// token at ANY origin. That made a token you were handed usable by you at
/// every other Thebes app, as that user — the confused-deputy problem. This
/// version calls `whoami_scoped_u(token, audience)` instead, and Memphis
/// refuses a token minted for someone else.
///
/// Two consequences when you upgrade:
///
///   • A MASTER session token now FAILS verification. That is the point, not a
///     bug. Clients must obtain a scoped token for your origin.
///
///   • Verification now needs an AUDIENCE, and it is security-critical. It is
///     the WEB ORIGIN your app is served from — the thing Memphis compares
///     against, byte-exactly, so a trailing slash, port or case difference is
///     a mismatch.
///
///     It is NOT the same as `origin`. `origin` is your pseudonym namespace and
///     may be any stable label ("my-app"); changing it rotates every user's
///     principal, so it must not be touched. `audience` is where your app
///     lives.
///
///     The audience is a PER-CALL ARGUMENT to `verifyWithAudience`, not a field
///     of `State`. That is deliberate and you should copy the pattern: adding a
///     field to a stable record hits M0170 (incompatible stable variable) —
///     `?Text` does not help, Motoko rejects an added record field either way —
///     and marking the holding variable `transient` to dodge it hits M0169 (a
///     stable variable cannot be implicitly discarded). Both walls exist for a
///     value that never needed to persist. Compile-time config belongs in an
///     argument; reserve `State` for what genuinely must survive an upgrade.
///
///     `verify(s, token)` defers to `verifyWithAudience(s, token, s.origin)`,
///     which is correct ONLY when your namespace already IS the URL. Otherwise
///     call `verifyWithAudience` and pass the URL.
///
/// ════════════════════════════════════════════════════════════════════════════
/// THE MEMPHIS INTERFACE THIS MODULE BINDS
/// ════════════════════════════════════════════════════════════════════════════
/// The `Memphis` actor type below mirrors these methods from memphis.did:
///
///   • whoami_scoped_u : (blob, text)
///                       -> (variant { Ok : WhoAmIResult; Err : MemphisError })
///   • derive_principal_for_u : (blob, text, nat64)
///                              -> (variant { Ok : blob; Err : MemphisError })
///   • whoami : (blob) -> (variant { Ok : WhoAmIResult; Err : MemphisError }) query
///     (mirrored for completeness; this module no longer calls it)
///
/// ⚠️ BOTH METHODS THIS MODULE CALLS ARE THE `_u` (UPDATE) FORMS, AND THAT IS
/// NOT OPTIONAL. Memphis exports each of them twice — a `query` for the browser
/// to poll cheaply, and a `_u` update with the identical body for contracts.
/// A contract-to-contract `await` on a Thebes `query` export does not deliver a
/// reply: the substrate's replicated-query fallback has no inter-contract reply
/// path, and the call fails as `method 'canister_update <name>' not found`.
/// Bind `whoami_scoped_u` and `derive_principal_for_u`, never `whoami` or
/// `derive_principal_for`.
///
/// ⚠️ Probing the query form over the boundary's `POST /api/query` SUCCEEDS,
/// which makes a wrong binding look fine. That path exercises the callee's
/// QUERY entry point, not the path a contract actually takes.
///
/// BINDING POINT: set the Memphis contract id once via `initFromCid` (or
/// `initFromText` / `init`), then pass the resulting `State` to `verify`. Every
/// failure path returns a typed `AuthError` you can surface to the caller.

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

  /// The subset of the Memphis service this module calls. THIS is the
  /// binding-point type — if 921's upgraded interface differs, the actor
  /// reference below will fail to typecheck against the live contract and the
  /// call will trap. That is by design: no silent drift.
  ///
  /// The two methods `verify` calls are bound to the UPDATE (`_u`) forms, for
  /// the reason set out in the header: a contract-to-contract await on a query
  /// export gets no reply on this substrate. `whoami` is mirrored so the type
  /// stays a faithful picture of the service; it is never called here.
  public type Memphis = actor {
    whoami : query (Blob) -> async ({ #Ok : WhoAmIResult; #Err : MemphisError });
    whoami_scoped_u : (Blob, Text) -> async ({ #Ok : WhoAmIResult; #Err : MemphisError });
    derive_principal_for_u : (Blob, Text, Nat64) -> async ({ #Ok : Blob; #Err : MemphisError });
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
    // PSEUDONYM NAMESPACE. Feeds derive_principal_for, so it decides your
    // users' principals. It is an arbitrary stable label — often a URL, but
    // "my-app" is equally valid. NEVER change it on a live app: every user's
    // principal would change with it and their data would be orphaned.
    origin : Text;
    version : Nat64; // pseudonym scheme version (start at 0/1)
    // token -> (anchorId, principal, expiresNs). Avoids a round-trip per call
    // until the cached expiry passes. Keyed by the opaque session token bytes.
    var cache : Map.Map<Blob, Identity>;
  };

  /// Build a gate whose pseudonym namespace and audience are the SAME string.
  /// Correct only when your namespace already IS the web origin your app is
  /// served from (e.g. both "https://my-app.com"). If they differ — and they do
  /// whenever the namespace is a label like "my-app" — call
  /// `verifyWithAudience` and pass your URL, or every verification will fail
  /// with #Unauthorized.
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
  ///
  /// There is deliberately no `…WithAudience` constructor: the audience is not
  /// gate state, it is an argument to `verifyWithAudience`. See the header.
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


  /// Verify a token, presenting `s.origin` as the audience.
  ///
  /// Correct ONLY when your pseudonym namespace is literally the web origin
  /// your app is served from. If it is a label like "my-app", this always
  /// fails with #Unauthorized — use `verifyWithAudience` and pass the URL.
  ///
  /// ⚠️ `async*`, not `async`, and you MUST call it with `await*`. A module-level
  /// `async` helper that awaits another contract loses the caller's
  /// continuation: the engine replies with the INNER awaited value instead of
  /// your handler's own return, and post-await state mutations are dropped. The
  /// symptom is a client-side Candid decode error naming a field your method
  /// never declared — it is decoding this module's Result, not yours.
  public func verify(s : State, token : Blob) : async* Result.Result<Identity, AuthError> {
    await* verifyWithAudience(s, token, s.origin);
  };

  /// VERIFY a token that was minted for `audience`, and return the user's stable per-app
  /// Identity. This is the function every authenticated method calls.
  ///
  /// Flow (all real work, no shortcuts):
  ///   1. Fast path: return a cached, unexpired identity if present.
  ///   2. Call Memphis `whoami_scoped_u(token, audience)`. On `Err`, surface
  ///      `#Memphis(err)`. On `Ok`, check the returned `session_expires_ns` is
  ///      in the future (defensive: Memphis already enforces this, but we
  ///      re-check locally so a clock-skew/replay window cannot slip through)
  ///      — else `#Expired`.
  ///   3. Call Memphis `derive_principal_for_u(anchor_id, origin, version)` to
  ///      get the stable per-app principal. On `Err`, surface `#Memphis(err)`.
  ///   4. Cache (token -> Identity) keyed by token and return the Identity.
  ///
  /// Cost: two inter-contract calls on a cache miss, zero on a cache hit.
  ///
  /// ⚠️ `async*` — call it with `await*`. See `verify` above for what breaks
  /// if this is a plain `async`.
  public func verifyWithAudience(s : State, token : Blob, audience : Text) : async* Result.Result<Identity, AuthError> {
    // Time.now() is nanoseconds-since-epoch as an Int (always positive on IC);
    // Memphis expiries are Nat64, so we compare in the Nat64 domain.
    let nowNs : Nat64 = Nat64.fromNat(Int.toNat(Time.now()));

    switch (cachedFresh(s, token, nowNs)) {
      case (?id) { return #ok(id) };
      case null {};
    };

    let m = actorOf(s);

    // Step 2: who does this token belong to, is it live, and was it minted
    // FOR THIS APP? Passing `s.origin` is what makes the token unusable
    // anywhere else: Memphis compares it against the origin recorded when the
    // token was minted and returns #Unauthorized on a mismatch.
    let who = switch (await m.whoami_scoped_u(token, audience)) {
      case (#Err(e)) { return #err(#Memphis(e)) };
      case (#Ok(w)) { w };
    };
    if (who.session_expires_ns <= nowNs) { return #err(#Expired) };

    // Step 3: derive the user's stable principal for THIS app. Note `s.origin`
    // (the pseudonym namespace), NOT `audience` — mixing these up rotates every
    // user's principal and orphans their data.
    let principalBytes = switch (await m.derive_principal_for_u(who.anchor_id, s.origin, s.version)) {
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
