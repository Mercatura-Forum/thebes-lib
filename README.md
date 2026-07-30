# thebes-lib

The Motoko backend library for [Thebes Protocol](https://github.com/Mercatura-Forum/Thebes-Protocol-)
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
| `MemphisAuth` | Memphis passkey identity. Verifies a passkey session and resolves it to a stable principal the backend can trust. |
| `Users` | User registration, profiles, avatars, and role tiers — built on top of `Admin`. |
| `Pagination` | Bounded, offset-cursor paging over an ordered array, so every list read stays within a fixed instruction budget. |
| `Invoices` | Invoicing — line items, on-chain-recomputed totals and tax, a `draft → issued → paid` / `void` lifecycle with per-party guards, and an immutable audit trail. Shared by the commerce and billing examples. |
| `Media` | On-chain, certified user media (logos, avatars, photos) inside the app's own canister — chunked uploads (≤ 32 KiB), content-addressed dedup + refcount, per-principal quotas, image-header validation (JPEG/PNG/WebP/GIF magic + dimensions), blob bytes in `Region` stable memory with a free-list allocator, and a domain-separated Merkle tree for certified serving (byte-compatible with the Egypt-L1 media canister's witness encoding). |

All six are **pure modules** (no actor, no internal state): the host actor owns the
state and passes it in. This keeps upgrades simple and the modules trivially testable.

`Media` bounds storage; it does not transform bytes: clients downscale/re-encode
(thebes-sdk `downscaleImage`) and the module enforces class byte caps
(avatar/logo ≤ 64 KiB, photo ≤ 512 KiB), magic-byte ↔ content-type agreement,
and real header-parsed dimension ceilings (256 px avatar/logo, 1600 px photo) at
finalize. The app republishes the media tree root via `CertifiedData.set(Media.root(store))`
after mutations — see the module header for the integration sketch.

## Add it

`thebes-lib` is consumed as a [mops](https://mops.one) GitHub dependency — no registry
account required. Pin a tag for reproducible builds:

```toml
# mops.toml
[dependencies]
core = "2.5.0"
thebes-lib = "https://github.com/Mercatura-Forum/thebes-lib#v0.3.0"
```

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
