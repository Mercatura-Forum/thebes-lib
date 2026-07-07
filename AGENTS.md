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
test/                module tests (mops test)
```

All five are **pure modules**: no actor, no internal state — the host actor owns
the state and passes it in.

## How it is consumed

Two ways: as a **pinned mops GitHub dependency**
(`thebes-lib = "https://github.com/Mercatura-Forum/thebes-lib#v0.2.0"`) or — in
every `thebes-example-*` repository — as a **vendored snapshot** under
`motoko/thebes-lib` (a local mops path dep). This repo is the upstream source of
truth; never patch a vendored copy in an example.

## Conventions that bite

- Compiler is mops-pinned **moc 1.4.1** — not a system `moc`.
- Any helper that `await`s another contract must be **`async*`** — a plain
  `async` private helper drops post-`await` state mutations on this engine.
- Guarded methods get `*OrTrap` twins so frontends receive thrown reasons.
- A release = tag `vX.Y.Z` here → examples refresh their vendored snapshot.

## Related repositories

Hub: [Thebes-Protocol-](https://github.com/Mercatura-Forum/Thebes-Protocol-) ·
Frontend SDK: [thebes-sdk](https://github.com/Mercatura-Forum/thebes-sdk) ·
Examples: `thebes-example-<name>` (each carries its own AGENTS.md).
