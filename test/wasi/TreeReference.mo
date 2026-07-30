/// TreeReference.test.mo — the Motoko half of the certified-tree byte-for-byte reference check
/// (the certified-tree reference check). Executes the SAME fixture scripts as the Rust
/// `test/tree-reference` binary and prints the SAME output lines; the
/// gate (test/run-tree-reference.sh) diffs the two outputs byte for byte.
///
/// Second, independent proof (bounded-verification: two proofs per item):
/// the pinned + empty roots below are HAND-DERIVED from the domain-tag
/// spec (asset_tree.rs:11-17) with plain sha256, independently of
/// Media.computeRoot's tree walk:
///   empty root       = sha256("thebes-asset-empty-v1")
///                    = 780506d46396392d17db4a5f059886a487eba1be03364073265a23fd2a671da4
///   pinned two-leaf  = sha256("thebes-asset-node-v1"
///                       || sha256("thebes-asset-leaf-v1" || le32(11) || "/index.html" || 0x11*32)
///                       || sha256("thebes-asset-leaf-v1" || le32( 8) || "/main.js"    || 0x22*32))
///                    = 02e55a8285b11008aa8caa0459c05322ef717771eb88101c0bdd9928d69a90f6
/// (also reproduced with Python hashlib during the port — see the progress
/// log; and asserted against asset_tree.rs:360's own pinned literal).

import Media "../../src/Media";
import Scripts "TreeReferenceScripts";
import Map "mo:core/Map";
import List "mo:core/List";
import Text "mo:core/Text";
import Blob "mo:core/Blob";
import Nat "mo:core/Nat";
import Debug "mo:core/Debug";
import Array "mo:core/Array";
import Nat8 "mo:core/Nat8";
import Runtime "mo:core/Runtime";

// ── Independent hand-derived anchors (proof #2) ──
do {
  let emptyHex = Media.hexEncode(Media.emptyRoot());
  assert (emptyHex == "780506d46396392d17db4a5f059886a487eba1be03364073265a23fd2a671da4");
  let l1 = Media.hashLeaf("/index.html", Blob.fromArray(Array.repeat<Nat8>(0x11, 32)));
  let l2 = Media.hashLeaf("/main.js", Blob.fromArray(Array.repeat<Nat8>(0x22, 32)));
  let pinned = Media.hexEncode(Media.hashInternal(l1, l2));
  assert (pinned == "02e55a8285b11008aa8caa0459c05322ef717771eb88101c0bdd9928d69a90f6");
  // And the tree API agrees with the hand-derivation:
  let viaTree = Media.computeRoot([
    { path = "/index.html"; bodySha256 = Blob.fromArray(Array.repeat<Nat8>(0x11, 32)) },
    { path = "/main.js"; bodySha256 = Blob.fromArray(Array.repeat<Nat8>(0x22, 32)) },
  ]);
  assert (Media.hexEncode(viaTree) == pinned);
};

// ── Script interpreter — mirrors tree-reference/src/main.rs ──

func runScript(name : Text, script : Text) {
  Debug.print("### " # name);
  let index = Map.empty<Text, Blob>();

  func leaves() : [Media.Leaf] {
    let out = List.empty<Media.Leaf>();
    for ((path, hash) in Map.entries(index)) {
      List.add(out, { path; bodySha256 = hash });
    };
    List.toArray(out);
  };

  for (rawLine in Text.split(script, #char '\n')) {
    let line = Text.trim(rawLine, #char ' ');
    if (line.size() == 0 or Text.startsWith(line, #text "#")) {
      // comment / blank
    } else {
      let parts = List.empty<Text>();
      for (t in Text.split(line, #char ' ')) {
        if (t.size() > 0) { List.add(parts, t) };
      };
      let cmd = List.at(parts, 0);
      if (cmd == "set") {
        let path = List.at(parts, 1);
        let hash = switch (Media.hexDecode32(List.at(parts, 2))) {
          case (?h) h;
          case null { Runtime.trap("set hash must be 64 hex chars") };
        };
        Map.add(index, Text.compare, path, hash);
      } else if (cmd == "del") {
        Map.remove(index, Text.compare, List.at(parts, 1));
      } else if (cmd == "root") {
        Debug.print("root=" # Media.hexEncode(Media.computeRoot(leaves())));
      } else if (cmd == "witness") {
        let path = List.at(parts, 1);
        let ls = leaves();
        let root = Media.computeRoot(ls);
        switch (Media.witnessFor(ls, path)) {
          case (?w) {
            let ok = Media.verifyWitness(w, root);
            Debug.print(
              "witness present path=" # w.leafPath
              # " leaf=" # Media.hexEncode(w.leafBodySha256)
              # " steps=" # Nat.toText(w.steps.size())
              # " root=" # Media.hexEncode(root)
              # " verified=" # (if ok "true" else "false")
            );
            var i = 0;
            for (st in w.steps.vals()) {
              Debug.print(
                "step " # Nat.toText(i) # " " # Media.hexEncode(st.sibling)
                # " " # (if (st.siblingIsRight) "R" else "L")
              );
              i += 1;
            };
          };
          case null {
            Debug.print(
              "witness absent path=" # path
              # " leaf=0000000000000000000000000000000000000000000000000000000000000000"
              # " steps=0 root=" # Media.hexEncode(root)
            );
          };
        };
      } else {
        Runtime.trap("unknown script command: " # cmd);
      };
    };
  };
};

for ((name, script) in Scripts.all.vals()) {
  runScript(name, script);
};
