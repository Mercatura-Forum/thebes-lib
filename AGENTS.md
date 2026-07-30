# AGENTS.md — working on thebes-lib

Orientation for an automated agent landing in `thebes-lib`, the shared Motoko
backend library for Thebes applications. Human detail in [README.md](README.md).

## Layout

```
src/Admin.mo         controller-gated administration (ownership, roles, pause)
src/MemphisAuth.mo   passkey identity — verifies a session, resolves a principal
src/Users.mo         registration, profiles, avatars, role tiers
src/Pagination.mo    bounded offset-cursor paging (fixed instruction budget)
src/Invoices.mo      invoicing — recomputed totals, draft→issued→paid/void
src/Media.mo         certified on-chain media — chunked uploads, dedup+refcount,
                     quotas, image-header validation, Region blob store, Merkle
                     certified serve (ported from the Rust media canister)
test/                module tests (mops test) — interpreter-safe tests only
test/wasi/           Media suites needing Region/Prim (test/run-wasi.sh)
test/replica/        upgrade + heap suite (test/run-replica.sh, dfx local only)
test/run-all.sh      the full Media gate: regression + tree reference + wasi + replica
```

All six are **pure modules**: no actor, no internal state — the host actor owns
the state and passes it in.

Media.mo discipline: the certified tree is checked byte for byte against the
Rust reference implementation (an md5-pinned copy of its `asset_tree.rs` lives
in `test/tree-reference`) by `test/run-tree-reference.sh` — run it (and
`--teeth`) after ANY change to the tree, SHA-256, hex, or path-sort code. `mops test`
(interpreter) cannot execute Region code; the full suite is
`test/run-all.sh`.

## How it is consumed

Two ways: as a **pinned mops GitHub dependency**
(`thebes-lib = "https://github.com/Mercatura-Forum/thebes-lib#v0.3.0"`) or — in
every `thebes-example-*` repository — as a **vendored snapshot** under
`motoko/thebes-lib` (a local mops path dep). This repo is the upstream source of
truth; never patch a vendored copy in an example.

### Refreshing a vendored snapshot

A snapshot is **`src/*.mo` only** — never `test/`, never the reference crate.
From a consumer repository, with `TAG` the release being adopted:

```sh
git -C /tmp clone --depth 1 --branch "$TAG" \
  https://github.com/Mercatura-Forum/thebes-lib.git thebes-lib-$TAG
rm -f motoko/thebes-lib/*.mo
cp /tmp/thebes-lib-$TAG/src/*.mo motoko/thebes-lib/
```

Then record the adopted tag in the consumer's own notes, and rebuild. A module
only compiles where its imports resolve: `Users.mo` and `Media.mo` both import
`Admin`, so a partial snapshot (some files, not others) is not supported —
copy all of `src/*.mo` or none. `Media.mo` additionally needs a `Region`-capable
target, so it is exercised by the suites here rather than by `mops test`.

## Conventions that bite

- Compiler is mops-pinned **moc 1.4.1** — not a system `moc` (`/usr/bin/moc`
  may be Qt's). dfx's bundled moc (1.1.0) REJECTS the registry core@2.5.0
  artifact — build replica-test wasms with the pinned moc and install `--wasm`.
- Any helper that `await`s another contract must be **`async*`** — a plain
  `async` private helper drops post-`await` state mutations on this engine.
- Guarded methods get `*OrTrap` twins so frontends receive thrown reasons.
- A release = tag `vX.Y.Z` here → examples refresh their vendored snapshot.

## Related repositories

Hub: [Thebes-Protocol-](https://github.com/Mercatura-Forum/Thebes-Protocol-) ·
Frontend SDK: [thebes-sdk](https://github.com/Mercatura-Forum/thebes-sdk) ·
Examples: `thebes-example-<name>` (each carries its own AGENTS.md).
