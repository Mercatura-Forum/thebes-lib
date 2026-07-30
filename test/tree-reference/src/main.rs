//! Script-driven byte-for-byte reference check CLI over the reference asset_tree.
//!
//! Reads op lines from stdin, maintains a path→hash index exactly like the
//! media canister's `path_index` (BTreeMap), and prints canonical output
//! lines. The Motoko port runs the SAME script and must print byte-identical
//! lines. Output format (one line per query op, no trailing spaces):
//!
//!   root=<64hex>
//!   witness present path=<path> leaf=<64hex> steps=<n> root=<64hex> verified=<true|false>
//!   step <i> <64hex> <R|L>
//!   witness absent path=<path> leaf=<64hex-zeros> steps=0 root=<64hex>
//!
//! Script commands: `set <path> <64hex>` · `del <path>` · `root` ·
//! `witness <path>` · `#` comments and blank lines ignored.
//!
//! The absent shape mirrors lib.rs get_media_with_witness's 404 reply
//! (zero leaf hash, no steps, root still present) — lib.rs:1152-1166.

pub mod asset_tree;

use asset_tree::{compute_root, verify_witness, witness_for, Leaf};
use std::collections::BTreeMap;
use std::io::{self, BufRead};

fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8] = b"0123456789abcdef";
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push(HEX[(b >> 4) as usize] as char);
        s.push(HEX[(b & 0x0f) as usize] as char);
    }
    s
}

fn hex_decode_32(s: &str) -> Option<[u8; 32]> {
    if s.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    let b = s.as_bytes();
    let val = |c: u8| -> Option<u8> {
        match c {
            b'0'..=b'9' => Some(c - b'0'),
            b'a'..=b'f' => Some(c - b'a' + 10),
            b'A'..=b'F' => Some(c - b'A' + 10),
            _ => None,
        }
    };
    for i in 0..32 {
        out[i] = (val(b[2 * i])? << 4) | val(b[2 * i + 1])?;
    }
    Some(out)
}

fn leaves(index: &BTreeMap<String, [u8; 32]>) -> Vec<Leaf> {
    index
        .iter()
        .map(|(path, hash)| Leaf {
            path: path.clone(),
            body_sha256: *hash,
        })
        .collect()
}

fn main() {
    let mut index: BTreeMap<String, [u8; 32]> = BTreeMap::new();
    let stdin = io::stdin();
    for line in stdin.lock().lines() {
        let line = line.expect("stdin read");
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let mut parts = line.splitn(3, ' ');
        let cmd = parts.next().unwrap();
        match cmd {
            "set" => {
                let path = parts.next().expect("set needs path").to_string();
                let hex = parts.next().expect("set needs hash");
                let hash = hex_decode_32(hex).expect("set hash must be 64 hex chars");
                index.insert(path, hash);
            }
            "del" => {
                let path = parts.next().expect("del needs path");
                index.remove(path);
            }
            "root" => {
                let root = compute_root(&leaves(&index));
                println!("root={}", hex_encode(&root));
            }
            "witness" => {
                let path = parts.next().expect("witness needs path");
                let ls = leaves(&index);
                let root = compute_root(&ls);
                match witness_for(&ls, path) {
                    Some(w) => {
                        let ok = verify_witness(&w, &root);
                        println!(
                            "witness present path={} leaf={} steps={} root={} verified={}",
                            w.leaf_path,
                            hex_encode(&w.leaf_body_sha256),
                            w.steps.len(),
                            hex_encode(&root),
                            ok
                        );
                        for (i, s) in w.steps.iter().enumerate() {
                            println!(
                                "step {} {} {}",
                                i,
                                hex_encode(&s.sibling),
                                if s.sibling_is_right { "R" } else { "L" }
                            );
                        }
                    }
                    None => {
                        println!(
                            "witness absent path={} leaf={} steps=0 root={}",
                            path,
                            hex_encode(&[0u8; 32]),
                            hex_encode(&root)
                        );
                    }
                }
            }
            other => panic!("unknown script command {:?}", other),
        }
    }
}
