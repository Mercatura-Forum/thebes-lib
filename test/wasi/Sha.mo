/// Sha.mo — NIST/known-vector suite for Media.mo's embedded SHA-256.
/// Pass bound: every vector equal to its published/precomputed digest.
/// Vectors: NIST FIPS 180-4 examples + boundary lengths around the 64-byte
/// block and the 56-byte padding threshold + a 100000-byte multi-block
/// vector precomputed with Python hashlib.

import Media "../../src/Media";
import Text "mo:core/Text";
import Blob "mo:core/Blob";
import Nat8 "mo:core/Nat8";
import Array "mo:core/Array";
import Debug "mo:core/Debug";

func hexOf(msg : [Nat8]) : Text { Media.hexEncode(Media.sha256(msg)) };
func bytesOf(t : Text) : [Nat8] { Blob.toArray(Text.encodeUtf8(t)) };

// NIST FIPS 180-4
assert (hexOf([]) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
assert (hexOf(bytesOf("abc")) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
assert (hexOf(bytesOf("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");

// Padding/block boundaries (python hashlib ground truth).
func rep(n : Nat) : [Nat8] { Array.repeat<Nat8>(0x61, n) }; // 'a' × n
assert (hexOf(rep(55)) == "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318");
assert (hexOf(rep(56)) == "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a");
assert (hexOf(rep(63)) == "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34");
assert (hexOf(rep(64)) == "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb");
assert (hexOf(rep(65)) == "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0");

// 100000-byte multi-block vector: bytes[i] = (i*89 + 7) & 0xff.
let long = Array.tabulate<Nat8>(100000, func(i : Nat) : Nat8 { Nat8.fromNat((i * 89 + 7) % 256) });
assert (hexOf(long) == "b3e87b18f6e2c333455ec507ca88cd05dbad28364ddebe56bf6d957be31726df");

Debug.print("SHA-256 vectors: 9/9 PASS");
