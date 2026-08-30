# thebes-lib

The Motoko backend library for [Thebes Protocol](https://thebesprotocol.com)
applications. It provides the six building blocks a production dapp backend needs —
controller-gated administration, passkey identity, user management, bounded
pagination, invoicing, and on-chain certified media — as pure, composable modules
that hold no state of their own.

Every Thebes example dapp depends on this library; it is the single source for the
backend toolkit.

## Modules

| Module | Responsibility |
| --- | --- |
| `Admin` | Controller-gated operations. A pure module the host actor holds one record of; gates privileged entry points behind the canister's controller set. |
| `MemphisAuth` | Memphis passkey identity. Verifies an **origin-scoped** session token and resolves it to a stable per-app principal the backend can trust. See [Identity, and the two strings you must not confuse](#identity-and-the-two-strings-you-must-not-confuse). |
| `Users` | User registration, profiles, avatars, and role tiers — built on top of `Admin`. |
| `Pagination` | Bounded, offset-cursor paging over an ordered array, so every list read stays within a fixed instruction budget. |
| `Invoices` | Invoicing — line items, on-chain-recomputed totals and tax, a `draft → issued → paid` / `void` lifecycle with per-party guards, and an immutable audit trail. Shared by the commerce and billing examples. |
| `Media` | On-chain, certified user media (logos, avatars, photos) inside the app's own canister — typed refusals (`#Paused`, `#Anonymous`, `#QuotaExceeded` carrying limit and usage), admin-scoped listing — chunked uploads (≤ 32 KiB), content-addressed dedup + refcount, per-principal quotas, image-header validation (JPEG/PNG/WebP/GIF magic + dimensions), blob bytes in `Region` stable memory with a free-list allocator, and a domain-separated Merkle tree for certified serving (byte-compatible with the Egypt-L1 media canister's witness encoding). |

All six are **pure modules** (no actor, no internal state): the host actor owns the
state and passes it in. This keeps upgrades simple and the modules trivially testable.

`Media` bounds storage; it does not transform bytes: clients downscale/re-encode
(thebes-sdk `downscaleImage`) and the module enforces class byte caps
(avatar/logo ≤ 64 KiB, photo ≤ 512 KiB), magic-byte ↔ content-type agreement,
and real header-parsed dimension ceilings (256 px avatar/logo, 1600 px photo) at
finalize. The app republishes the media tree root via `CertifiedData.set(Media.root(store))`
after mutations — see the module header for the integration sketch.


## Identity, and the two strings you must not confuse

`MemphisAuth.verifyWithAudience(gate, token, audience)` is how a backend
authenticates a user. Two different strings are in play, and they are frequently
not equal:

| | What it is | Where it goes | Changing it |
| --- | --- | --- | --- |
| `origin` (on `State`) | Your **pseudonym namespace**. Any stable label — `"my-app"` is as valid as a URL. | `derive_principal_for_u(anchor, origin, version)` | **Rotates every user's principal.** Their data is keyed on it. Never change it on a live app. |
| `audience` (per call) | The **web origin** your app is served from, e.g. `"https://my-app.com"`. | `whoami_scoped_u(token, audience)` | Harmless — it only says where tokens are accepted from. |

```motoko
let gate = MemphisAuth.initFromCid(921, "my-app", 1);          // namespace
let AUDIENCE = "https://my-app.com";                            // web origin

switch (await* MemphisAuth.verifyWithAudience(gate, token, AUDIENCE)) {
  case (#ok(id)) { /* id.principal — key your state on this */ };
  case (#err(e)) { /* #Memphis(#Unauthorized) = minted for another origin */ };
};
```

`verify(gate, token)` exists and passes `gate.origin` as the audience. That is
correct **only** when your namespace is literally the URL. If it is a label, it
fails every time with `#Unauthorized`.

The comparison is **byte-exact**: a trailing slash, a differing port or a case
difference is a mismatch.

### Two rules that are not style preferences

**1. `await*`, never `await`.** `verify` and `verifyWithAudience` are `async*`.
A module-level `async` helper that awaits another contract loses the caller's
continuation: the engine replies with the *inner* awaited value instead of your
handler's own return, and state mutations after the await are dropped. The
symptom is a client-side Candid decode error naming a field your method never
declared — the client is decoding `Result<Identity, AuthError>`, not your type.

> Diagnostic that isolates it in one step: call an update that makes **no**
> inter-contract call, and one that does. If the first returns its declared type
> and the second returns the callee's, this is your bug. Anything else is a red
> herring.

**2. Bind the `_u` methods, never the `query` ones.** Memphis exports
`whoami` / `derive_principal_for` as queries for the browser, and
`whoami_scoped_u` / `derive_principal_for_u` as updates with identical bodies
for contracts. A contract-to-contract `await` on a query export gets no reply on
this substrate — the call fails as `method 'canister_update <name>' not found`.
Probing the query form over the boundary's `POST /api/query` **succeeds**, which
is what makes a wrong binding look correct; that path exercises the callee's
query entry point, not the path a contract takes.

The full integration guide — including the browser half (passkey ceremony,
discoverable credentials, confirm-before-mint) — is
[`docs/memphis.md`](https://github.com/Mercatura-Forum/thebes-sdk/blob/main/docs/memphis.md)
in the SDK.

### Why tokens are origin-scoped

A Memphis *master* session token is anchor-scoped — whoever holds it is that
user everywhere. Handing one to an app lets that app authenticate as its own
users at every other Thebes app: the confused deputy (Hardy, 1988). So the
client never receives one. It receives a credential minted for one origin and
refused at every other — an audience restriction, the same shape as OAuth's
`aud` (RFC 9068) and Internet Identity's per-frontend delegation.

The scoped token is strictly weaker than the session it came from: it cannot
outlive it, dies when it is revoked, and dies on sign-out-everywhere.

**Upgrading from 0.x:** a master session token no longer verifies. That is the
point, not a bug — clients must obtain a scoped token for your origin.

## Add it

`thebes-lib` is consumed as a [mops](https://mops.one) GitHub dependency — no registry
account required. Pin a tag for reproducible builds:

```toml
# mops.toml
[dependencies]
core = "2.5.0"
thebes-lib = "https://github.com/Mercatura-Forum/thebes-lib#v1.0.0"
```

> **Do not pin `v0.4.0` or earlier.** Those tags predate origin-scoped sessions:
> `MemphisAuth.verify` calls `whoami`, which resolves a token at *any* origin, so
> a token your app is handed authenticates as that user at every other Thebes
> app. `v1.0.0` is the first tag with the scoped call, the `_u` bindings and the
> `async*` signatures.

```sh
mops install
```

## Use it

```motoko
import Admin "mo:thebes-lib/Admin";

persistent actor MyApp {
  // The host actor owns the state; the module operates on it.
  var admin = Admin.init();

  // First caller claims ownership; thereafter the owner manages admins.
  public shared (msg) func claimOwner() : async Bool {
    Admin.claimOwner(admin, msg.caller)
  };

  // Gate a privileged, mutating entry point behind admin + not-paused.
  public shared (msg) func setListingActive(active : Bool) : async () {
    Admin.requireNotPaused(admin);
    Admin.requireAdmin(admin, msg.caller);
    // ... privileged operation
  };

  public query func isPaused() : async Bool { Admin.isPaused(admin) };
};
```

## Build

The library targets the Motoko compiler and the `core` package resolved by mops:

```sh
moc --check $(mops sources) src/Admin.mo
```

## Acknowledgements

This library is written in [Motoko](https://github.com/dfinity/motoko) and builds
on the **canister model** pioneered by the [Internet Computer](https://internetcomputer.org)
and the [DFINITY Foundation](https://dfinity.org) — smart contracts as
orthogonally-persistent actors. Their work is excellent and directly inspired this
stack. We are grateful to the DFINITY team and the wider IC community.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
