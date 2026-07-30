#!/usr/bin/env python3
"""Generate the deterministic tree-reference fixture scripts (the certified-tree reference check).

Writes test/tree-fixtures/*.txt. Hashes are sha256(path-string) so the
scripts are reproducible from this generator alone. Run once; commit the
outputs. run-tree-reference.sh replays each script through both the Rust
reference binary and the Motoko implementation and diffs the two outputs.
"""
import hashlib
import os

OUT = os.path.join(os.path.dirname(__file__), "tree-fixtures")
os.makedirs(OUT, exist_ok=True)


def h(path: str) -> str:
    return hashlib.sha256(path.encode()).hexdigest()


def write(name: str, lines):
    with open(os.path.join(OUT, name), "w") as f:
        f.write("\n".join(lines) + "\n")


# 00 — the pinned vector from asset_tree.rs:344-362. Expected root
# 02e55a8285b11008aa8caa0459c05322ef717771eb88101c0bdd9928d69a90f6 is
# asserted literally by run-tree-reference.sh (independent anchor).
write("00-pinned.txt", [
    "# pinned vector, asset_tree.rs:344-362",
    "set /index.html " + "11" * 32,
    "set /main.js " + "22" * 32,
    "root",
])

# 01 — empty tree: constant root + absent witness on empty.
write("01-empty.txt", [
    "root",
    "witness /any",
])

# 02 — single asset: present witness has 0 steps; absent query alongside.
write("02-one.txt", [
    "set /avatar/aaaaa-aa " + h("/avatar/aaaaa-aa"),
    "root",
    "witness /avatar/aaaaa-aa",
    "witness /missing",
])

# 03 — 100 assets, roots at growth points, witnesses across positions.
lines = []
paths = []
for i in range(100):
    p = f"/photo/{h(f'photo-{i}')}" if i % 3 else f"/avatar/principal-{i:03d}"
    paths.append(p)
    lines.append(f"set {p} {h(p)}")
    if i + 1 in (1, 2, 3, 5, 10, 33, 64, 100):
        lines.append("root")
sorted_paths = sorted(paths)
for p in (sorted_paths[0], sorted_paths[1], sorted_paths[49],
          sorted_paths[63], sorted_paths[64], sorted_paths[-2],
          sorted_paths[-1]):
    lines.append(f"witness {p}")
write("03-hundred.txt", lines)

# 04 — deep/long paths and odd counts (3,5,7,9): every leaf witnessed at 5,
# boundary leaves witnessed at 3/7/9 (odd-duplication edge each level).
deep = [f"/a/{'x' * n}/{'deep/' * n}leaf-{n}" for n in (1, 2, 3, 4, 5, 6, 7, 8, 9)]
lines = []
for n, p in enumerate(deep, start=1):
    lines.append(f"set {p} {h(p)}")
    if n in (3, 5, 7, 9):
        lines.append("root")
        if n == 5:
            for q in sorted(deep[:5]):
                lines.append(f"witness {q}")
        else:
            s = sorted(deep[:n])
            lines.append(f"witness {s[0]}")
            lines.append(f"witness {s[-1]}")
write("04-deep.txt", lines)

# 05 — deletes: middle/first/last, re-set after delete, down to empty.
ten = [f"/photo/{h(f'del-{i}')}" for i in range(10)]
lines = [f"set {p} {h(p)}" for p in ten] + ["root"]
srt = sorted(ten)
lines += [f"del {srt[5]}", "root", f"witness {srt[4]}", f"witness {srt[5]}"]
lines += [f"del {srt[0]}", "root", f"witness {srt[1]}"]
lines += [f"del {srt[9]}", "root", f"witness {srt[8]}"]
lines += [f"set {srt[5]} {h(srt[5])}", "root", f"witness {srt[5]}"]
for p in srt:
    lines.append(f"del {p}")
lines += ["root", f"witness {srt[3]}"]
write("05-delete.txt", lines)

# 06 — absent-key witnesses against a populated tree: before-first,
# between, after-last, near-miss (prefix of a present key).
five = sorted(f"/k/{h(f'abs-{i}')[:8]}" for i in range(5))
lines = [f"set {p} {h(p)}" for p in five]
lines += ["root",
          "witness /0-before-everything",
          f"witness {five[2]}zz",
          "witness /zzzz-after-everything",
          f"witness {five[0][:-1]}"]
write("06-absent.txt", lines)

print("wrote", sorted(os.listdir(OUT)))
