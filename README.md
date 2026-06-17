# thebes-lib

The Motoko backend library for [Thebes Protocol](https://github.com/Mercatura-Forum/Thebes-Protocol-)
applications. It provides the four building blocks a production dapp backend needs —
controller-gated administration, passkey identity, user management, and bounded
pagination — as pure, composable modules that hold no state of their own.

Every Thebes example dapp depends on this library; it is the single source for the
backend toolkit.

## Modules

| Module | Responsibility |
| --- | --- |
| `Admin` | Controller-gated operations. A pure module the host actor holds one record of; gates privileged entry points behind the canister's controller set. |
| `MemphisAuth` | Memphis passkey identity. Verifies a passkey session and resolves it to a stable principal the backend can trust. |
| `Users` | User registration, profiles, avatars, and role tiers — built on top of `Admin`. |
| `Pagination` | Bounded, offset-cursor paging over an ordered array, so every list read stays within a fixed instruction budget. |

All four are **pure modules** (no actor, no internal state): the host actor owns the
state and passes it in. This keeps upgrades simple and the modules trivially testable.

## Add it

`thebes-lib` is consumed as a [mops](https://mops.one) GitHub dependency — no registry
account required. Pin a tag for reproducible builds:

```toml
# mops.toml
[dependencies]
core = "2.5.0"
thebes-lib = "https://github.com/Mercatura-Forum/thebes-lib#v0.1.0"
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

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
