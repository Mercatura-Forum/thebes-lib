//! Domain-separated binary Merkle tree over `(path, sha256(body))` pairs.
//!
//! The asset canister maintains one of these for its stored assets. The
//! 32-byte root is published via `ic0.certified_data_set` on every
//! mutating op, so the validator state machine includes it in state_root
//! (see `egypt-state::state_machine::compute_state_root`). State roots
//! are already MAYO-2 certified by ≥ 2f+1 validators (`StateCertificate`),
//! which gives every byte served via `http_request` a cryptographic
//! chain back to a finalized block.
//!
//! # Domain tags
//!
//! | Where | Tag | Hashed |
//! |---|---|---|
//! | leaf | `thebes-asset-leaf-v1` | `len_u32_le(path) \|\| path_bytes \|\| sha256(body)` |
//! | internal node | `thebes-asset-node-v1` | `left \|\| right` |
//! | empty tree | `thebes-asset-empty-v1` | (constant root) |
//!
//! Domain tags prevent second-preimage and type-confusion attacks between
//! leaves and internal nodes. The canonical tree is built over leaves
//! sorted by path — same asset set → same root regardless of insert order.
//!
//! # Odd-level handling
//!
//! When a level has an odd node count, the last node is **duplicated**
//! (Bitcoin-style). This is known to admit a duplicate-leaf malleability
//! attack when an attacker can choose the asset set, but the asset
//! canister's `store()` rejects duplicate paths, so the attack does not
//! apply here. An alternative (hashing last node with a fixed padding)
//! is available if that property is desired later.

use sha2::{Digest, Sha256};

const LEAF_TAG: &[u8] = b"thebes-asset-leaf-v1";
const NODE_TAG: &[u8] = b"thebes-asset-node-v1";
const EMPTY_TAG: &[u8] = b"thebes-asset-empty-v1";

/// One entry in the tree. Paths are expected to be unique across entries.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Leaf {
    pub path: String,
    pub body_sha256: [u8; 32],
}

/// Hash of a single leaf. Stable across runs for a given `(path, body_sha256)`.
pub fn hash_leaf(path: &str, body_sha256: &[u8; 32]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(LEAF_TAG);
    // u32 length prefix allows fast parsing in-browser without scanning
    // for a separator; 4 GiB per path is more than enough.
    let len = path.len() as u32;
    h.update(len.to_le_bytes());
    h.update(path.as_bytes());
    h.update(body_sha256);
    h.finalize().into()
}

/// Hash of an internal node from its two children.
pub fn hash_internal(left: &[u8; 32], right: &[u8; 32]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(NODE_TAG);
    h.update(left);
    h.update(right);
    h.finalize().into()
}

/// Root of an empty tree. Constant, domain-separated from any populated
/// root (a leaf with empty path + zero hash cannot collide because
/// `LEAF_TAG != EMPTY_TAG`).
pub fn empty_root() -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(EMPTY_TAG);
    h.finalize().into()
}

/// Build the root from a list of leaves. Leaves are sorted by path before
/// hashing, so the root is independent of insert order — any two clients
/// that agree on the asset set agree on the root.
pub fn compute_root(leaves: &[Leaf]) -> [u8; 32] {
    if leaves.is_empty() {
        return empty_root();
    }
    let mut sorted: Vec<&Leaf> = leaves.iter().collect();
    sorted.sort_by(|a, b| a.path.cmp(&b.path));
    let mut level: Vec<[u8; 32]> = sorted
        .iter()
        .map(|l| hash_leaf(&l.path, &l.body_sha256))
        .collect();
    while level.len() > 1 {
        level = next_level(&level);
    }
    level[0]
}

fn next_level(level: &[[u8; 32]]) -> Vec<[u8; 32]> {
    let mut out = Vec::with_capacity(level.len().div_ceil(2));
    let mut i = 0;
    while i < level.len() {
        let left = &level[i];
        let right = if i + 1 < level.len() {
            &level[i + 1]
        } else {
            // Duplicate the last leaf at odd levels. Safe here because
            // `store()` rejects duplicate paths in the asset canister.
            &level[i]
        };
        out.push(hash_internal(left, right));
        i += 2;
    }
    out
}

/// One sibling along a merkle path. `is_right` tells the verifier whether
/// to feed `(current, sibling)` or `(sibling, current)` into `hash_internal`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WitnessStep {
    pub sibling: [u8; 32],
    pub sibling_is_right: bool,
}

/// Merkle proof that a given leaf is committed by a root.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Witness {
    pub leaf_path: String,
    pub leaf_body_sha256: [u8; 32],
    pub steps: Vec<WitnessStep>,
}

/// Build a witness for `target_path` against the given leaf set. Returns
/// `None` if `target_path` is not among the leaves. The produced witness
/// always verifies against `compute_root(leaves)` by construction — this
/// is asserted in the oracle tests.
pub fn witness_for(leaves: &[Leaf], target_path: &str) -> Option<Witness> {
    if leaves.is_empty() {
        return None;
    }
    let mut sorted: Vec<&Leaf> = leaves.iter().collect();
    sorted.sort_by(|a, b| a.path.cmp(&b.path));
    let target_pos = sorted.iter().position(|l| l.path == target_path)?;
    let target_leaf = sorted[target_pos];

    // Compute level 0 hashes.
    let mut level: Vec<[u8; 32]> = sorted
        .iter()
        .map(|l| hash_leaf(&l.path, &l.body_sha256))
        .collect();

    let mut idx = target_pos;
    let mut steps = Vec::new();
    while level.len() > 1 {
        let pair_start = idx & !1usize; // even index at this pair
        let is_left = idx == pair_start;
        let sibling_idx = if is_left {
            // If we're at the right-most pair and it's odd-length, the
            // sibling is ourselves (duplicated). Still record it honestly.
            if pair_start + 1 < level.len() {
                pair_start + 1
            } else {
                pair_start
            }
        } else {
            pair_start
        };
        let sibling = level[sibling_idx];
        steps.push(WitnessStep {
            sibling,
            sibling_is_right: is_left,
        });
        level = next_level(&level);
        idx /= 2;
    }

    Some(Witness {
        leaf_path: target_leaf.path.clone(),
        leaf_body_sha256: target_leaf.body_sha256,
        steps,
    })
}

/// Verify a witness against a root. Returns `true` iff the witness proves
/// `(leaf_path, leaf_body_sha256)` is committed by `root`.
///
/// This function is a pure reference implementation — the browser-side
/// TypeScript verifier reimplements the same algorithm against the same
/// domain tags, so both sides converge on identical roots from the same
/// witness bytes.
pub fn verify_witness(witness: &Witness, root: &[u8; 32]) -> bool {
    let mut current = hash_leaf(&witness.leaf_path, &witness.leaf_body_sha256);
    for step in &witness.steps {
        current = if step.sibling_is_right {
            hash_internal(&current, &step.sibling)
        } else {
            hash_internal(&step.sibling, &current)
        };
    }
    current == *root
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::{Digest, Sha256};

    fn leaf(path: &str, body: &[u8]) -> Leaf {
        Leaf {
            path: path.to_string(),
            body_sha256: Sha256::digest(body).into(),
        }
    }

    #[test]
    fn empty_tree_is_domain_separated() {
        // Empty root must differ from any single-leaf root, especially the
        // edge case of an empty path + zero-body leaf which is the closest
        // value-collision candidate.
        let root_empty = compute_root(&[]);
        let root_one = compute_root(&[leaf("", b"")]);
        assert_ne!(root_empty, root_one);
    }

    #[test]
    fn root_is_insert_order_independent() {
        let a = leaf("/a", b"a");
        let b = leaf("/b", b"b");
        let c = leaf("/c", b"c");
        let r1 = compute_root(&[a.clone(), b.clone(), c.clone()]);
        let r2 = compute_root(&[c, b, a]);
        assert_eq!(r1, r2);
    }

    #[test]
    fn root_changes_when_body_changes() {
        let a1 = leaf("/index.html", b"<h1>one</h1>");
        let a2 = leaf("/index.html", b"<h1>two</h1>");
        assert_ne!(compute_root(&[a1]), compute_root(&[a2]));
    }

    #[test]
    fn root_changes_when_path_changes() {
        let a1 = leaf("/x", b"same");
        let a2 = leaf("/y", b"same");
        assert_ne!(compute_root(&[a1]), compute_root(&[a2]));
    }

    #[test]
    fn witness_roundtrip_single_leaf() {
        let leaves = vec![leaf("/only.html", b"hi")];
        let root = compute_root(&leaves);
        let w = witness_for(&leaves, "/only.html").expect("witness exists");
        assert!(verify_witness(&w, &root));
    }

    #[test]
    fn witness_roundtrip_multi_leaf_even() {
        let leaves = vec![
            leaf("/a.html", b"A"),
            leaf("/b.html", b"B"),
            leaf("/c.js", b"C"),
            leaf("/d.css", b"D"),
        ];
        let root = compute_root(&leaves);
        for target in ["/a.html", "/b.html", "/c.js", "/d.css"] {
            let w = witness_for(&leaves, target).expect("witness exists");
            assert!(verify_witness(&w, &root), "witness for {} failed", target);
        }
    }

    #[test]
    fn witness_roundtrip_multi_leaf_odd() {
        // Odd count exercises the duplicate-last-sibling branch at every
        // level that rounds up.
        let leaves = vec![
            leaf("/a", b"1"),
            leaf("/b", b"2"),
            leaf("/c", b"3"),
            leaf("/d", b"4"),
            leaf("/e", b"5"),
        ];
        let root = compute_root(&leaves);
        for target in ["/a", "/b", "/c", "/d", "/e"] {
            let w = witness_for(&leaves, target).expect("witness exists");
            assert!(verify_witness(&w, &root), "witness for {} failed", target);
        }
    }

    #[test]
    fn witness_rejects_wrong_body() {
        let leaves = vec![leaf("/x", b"real")];
        let root = compute_root(&leaves);
        let mut w = witness_for(&leaves, "/x").unwrap();
        w.leaf_body_sha256 = [0xffu8; 32];
        assert!(!verify_witness(&w, &root));
    }

    #[test]
    fn witness_rejects_wrong_path() {
        let leaves = vec![leaf("/x", b"real"), leaf("/y", b"real")];
        let root = compute_root(&leaves);
        let mut w = witness_for(&leaves, "/x").unwrap();
        w.leaf_path = "/evil".into();
        assert!(!verify_witness(&w, &root));
    }

    #[test]
    fn witness_rejects_tampered_sibling() {
        let leaves = vec![
            leaf("/a", b"A"),
            leaf("/b", b"B"),
            leaf("/c", b"C"),
            leaf("/d", b"D"),
        ];
        let root = compute_root(&leaves);
        let mut w = witness_for(&leaves, "/a").unwrap();
        assert!(!w.steps.is_empty());
        w.steps[0].sibling = [0u8; 32];
        assert!(!verify_witness(&w, &root));
    }

    #[test]
    fn witness_rejects_wrong_side_flag() {
        let leaves = vec![leaf("/a", b"A"), leaf("/b", b"B")];
        let root = compute_root(&leaves);
        let mut w = witness_for(&leaves, "/a").unwrap();
        w.steps[0].sibling_is_right = !w.steps[0].sibling_is_right;
        assert!(!verify_witness(&w, &root));
    }

    #[test]
    fn missing_path_returns_none() {
        let leaves = vec![leaf("/a", b"A")];
        assert!(witness_for(&leaves, "/missing").is_none());
    }

    #[test]
    fn empty_tree_has_no_witness() {
        assert!(witness_for(&[], "/any").is_none());
    }

    #[test]
    fn deterministic_roots_match_across_runs() {
        // Pinned vector — if a refactor accidentally changes the domain
        // tag or the leaf encoding, this test fires before it can leak
        // into the browser verifier or the signed state_root.
        let leaves = vec![
            Leaf {
                path: "/index.html".into(),
                body_sha256: [0x11u8; 32],
            },
            Leaf {
                path: "/main.js".into(),
                body_sha256: [0x22u8; 32],
            },
        ];
        let root = compute_root(&leaves);
        // The exact hex isn't meaningful on its own, but pinning it
        // catches accidental encoding drift. Recompute once if the
        // domain tags or leaf encoding ever change intentionally.
        // Pinned on 2026-04-22; recompute if the domain tags or the
        // leaf encoding change intentionally and document in the commit.
        let expected =
            "02e55a8285b11008aa8caa0459c05322ef717771eb88101c0bdd9928d69a90f6";
        let got = hex_encode(&root);
        if got != expected {
            // Print so the regenerating engineer can copy/paste.
            panic!(
                "asset tree root vector drift\n  expected: {}\n  got:      {}",
                expected, got
            );
        }
    }

    fn hex_encode(bytes: &[u8]) -> String {
        const HEX: &[u8] = b"0123456789abcdef";
        let mut s = String::with_capacity(bytes.len() * 2);
        for b in bytes {
            s.push(HEX[(b >> 4) as usize] as char);
            s.push(HEX[(b & 0x0f) as usize] as char);
        }
        s
    }
}
