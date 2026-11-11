import MemphisAuth "../src/MemphisAuth";
import Map "mo:core/Map";
import Blob "mo:core/Blob";
import Principal "mo:core/Principal";

// A session bound to the caller that opened it answers only that caller.
let alice = Principal.fromText("aaaaa-aa");
let bob = Principal.fromText("bkyz2-fmaaa-aaaaa-qaaaq-cai");
let anon = Principal.fromText("2vxsx-fae");
let memphisId = Principal.fromText("bd3sg-teaaa-aaaaa-qaaba-cai");
let s = MemphisAuth.init(memphisId, "https://app.example", 1);
let h = MemphisAuth.initHolders();
let tok : Blob = "\01\02\03";
let other : Blob = "\09";
let id : MemphisAuth.Identity = { principal = alice; anchorId = "\aa"; expiresNs = 1_000 };
Map.add(s.cache, Blob.compare, tok, id);
Map.add(s.cache, Blob.compare, other, id);

// Verified but never bound: nobody reads it through cachedFor.
assert (MemphisAuth.cachedFor(s, h, tok, alice, 500) == null);
MemphisAuth.bindHolder(h, tok, alice);
// The holder, unexpired: answered.
assert (MemphisAuth.cachedFor(s, h, tok, alice, 500) == ?id);
// Another caller holding the same token (read from the chain): refused.
assert (MemphisAuth.cachedFor(s, h, tok, bob, 500) == null);
// The anonymous caller: refused, and never bindable.
assert (MemphisAuth.cachedFor(s, h, tok, anon, 500) == null);
MemphisAuth.bindHolder(h, other, anon);
assert (MemphisAuth.cachedFor(s, h, other, anon, 500) == null);
// Expired: refused even for the holder.
assert (MemphisAuth.cachedFor(s, h, tok, alice, 1_000) == null);
// Forgotten: refused.
MemphisAuth.forgetHolder(h, tok);
assert (MemphisAuth.cachedFor(s, h, tok, alice, 500) == null);
