/// Image.mo — the image-validation suite: the image-header corpus.
/// Every fixture is a REAL file (Pillow-generated or a deliberate byte
/// corruption — test/gen-image-fixtures.py); every reject path is shown
/// firing with its specific error, and every reject leaves the store
/// untouched (the Rust garbage_image_rejected_and_nothing_stored parity,
/// lib.rs:1639-1648).

import Media "../../src/Media";
import Admin "../../src/Admin";
import Fix "MediaFixtures";
import Blob "mo:core/Blob";
import Text "mo:core/Text";
import Array "mo:core/Array";
import Nat "mo:core/Nat";
import Nat8 "mo:core/Nat8";
import Principal "mo:core/Principal";
import Result "mo:core/Result";
import Debug "mo:core/Debug";
import Prim "mo:⛔";

func p(tag : Nat8) : Principal {
  Prim.principalOfBlob(Blob.fromArray(Array.repeat<Nat8>(tag, 10)));
};
let adminP = p(0xA0);
let alice = p(0x01);

func fresh() : (Media.Store, Admin.State) {
  let a = Admin.init();
  assert (Admin.claimOwner(a, adminP));
  (Media.init(), a);
};

func upload(
  s : Media.Store,
  a : Admin.State,
  class_ : Media.Class,
  ct : Text,
  body : Blob,
) : Result.Result<Media.FinishReply, Media.MediaError> {
  // Fixtures are all ≤ 32 KiB → single chunk. Logos are admin-gated, so
  // logo cases upload as the admin.
  let caller = switch (class_) { case (#logo _) adminP; case _ alice };
  assert (body.size() <= Media.MAX_CHUNK_BYTES);
  switch (Media.startUpload(s, a, caller, "img", class_, ct, 1)) {
    case (#err(e)) { return #err(e) };
    case (#ok) {};
  };
  switch (Media.storeChunk(s, a, caller, "img", 0, body)) {
    case (#err(e)) { return #err(e) };
    case (#ok) {};
  };
  Media.finishUpload(s, a, caller, "img");
};

var passCount = 0;
var rejectCount = 0;

/// A fixture that must be ACCEPTED for `class_`.
func mustPass(name : Text, class_ : Media.Class, ct : Text, body : Blob) {
  let (s, a) = fresh();
  switch (upload(s, a, class_, ct, body)) {
    case (#ok(rep)) {
      assert (rep.size == body.size());
      assert (rep.contentType == ct);
      // Served back byte-identical.
      let resp = Media.httpRequest(s, { method = "GET"; url = rep.path; headers = []; body = "" });
      assert (resp.statusCode == 200);
      assert (resp.body == body);
      passCount += 1;
      Debug.print("  PASS-accept " # name);
    };
    case (#err(e)) {
      Debug.print("  FAIL: expected accept for " # name # " got: " # Media.errorText(e));
      assert false;
    };
  };
};

/// A fixture that must be REJECTED for `class_` with `needle` in the error,
/// leaving the store byte-for-byte empty.
func mustReject(name : Text, class_ : Media.Class, ct : Text, body : Blob, needle : Text) {
  let (s, a) = fresh();
  switch (upload(s, a, class_, ct, body)) {
    case (#ok(rep)) {
      Debug.print("  FAIL: expected reject for " # name # " but stored " # rep.path);
      assert false;
    };
    case (#err(#Validation(v))) {
      // The VARIANT is asserted, not just the prose: every image refusal is a
      // #Validation, so a swapped variant fails here even if its rendered
      // text were preserved.
      if (not Text.contains(v.reason, #text needle)) {
        Debug.print("  FAIL: " # name # " reason \"" # v.reason # "\" missing \"" # needle # "\"");
        assert false;
      };
      // Nothing stored, nothing indexed, nothing owned (rollback parity).
      let st = Media.storageStats(s);
      assert (st.blobCount == 0);
      assert (st.totalBytes == 0);
      assert (st.pathCount == 0);
      assert (Media.listPaths(s).size() == 0);
      rejectCount += 1;
      Debug.print("  PASS-reject " # name # " (" # needle # ")");
    };
    case (#err(e)) {
      Debug.print("  FAIL: " # name # " expected #Validation, got " # Media.errorText(e));
      assert false;
    };
  };
};

Debug.print("— valid fixtures accepted for every fitting class —");
mustPass("jpeg_ok_64 avatar", #avatar, "image/jpeg", Fix.jpeg_ok_64);
mustPass("jpeg_ok_64 photo", #photo, "image/jpeg", Fix.jpeg_ok_64);
mustPass("jpeg_ok_64 logo", #logo("brand"), "image/jpeg", Fix.jpeg_ok_64);
mustPass("jpeg_progressive_96 (SOF2) avatar", #avatar, "image/jpeg", Fix.jpeg_progressive_96);
mustPass("png_ok_64 avatar", #avatar, "image/png", Fix.png_ok_64);
mustPass("gif_ok_64 avatar", #avatar, "image/gif", Fix.gif_ok_64);
mustPass("webp_lossy_64 (VP8) avatar", #avatar, "image/webp", Fix.webp_lossy_64);
mustPass("webp_lossless_64 (VP8L) avatar", #avatar, "image/webp", Fix.webp_lossless_64);
mustPass("webp_vp8x_64 (VP8X) avatar", #avatar, "image/webp", Fix.webp_vp8x_64);

Debug.print("— dimension boundaries: cap passes, cap+1 rejected —");
mustPass("jpeg_256 == avatar dim cap", #avatar, "image/jpeg", Fix.jpeg_256);
mustPass("jpeg_256 logo", #logo("big"), "image/jpeg", Fix.jpeg_256);
mustReject("jpeg_257w avatar", #avatar, "image/jpeg", Fix.jpeg_257w, "exceeds max dimension 256");
mustReject("jpeg_257w logo", #logo("wide"), "image/jpeg", Fix.jpeg_257w, "exceeds max dimension 256");
mustPass("jpeg_257w photo (fits 1600)", #photo, "image/jpeg", Fix.jpeg_257w);
mustReject("png_257h avatar", #avatar, "image/png", Fix.png_257h, "exceeds max dimension 256");
mustReject("gif_300w avatar", #avatar, "image/gif", Fix.gif_300w, "exceeds max dimension 256");
mustReject("webp_257w (VP8) avatar", #avatar, "image/webp", Fix.webp_257w, "exceeds max dimension 256");
mustReject("webp_l_257h (VP8L) avatar", #avatar, "image/webp", Fix.webp_l_257h, "exceeds max dimension 256");
mustPass("jpeg_1600w == photo dim cap", #photo, "image/jpeg", Fix.jpeg_1600w);
mustReject("jpeg_1601w photo", #photo, "image/jpeg", Fix.jpeg_1601w, "exceeds max dimension 1600");

Debug.print("— malformed fixtures: every parser reject path fires —");
mustReject("empty", #avatar, "image/jpeg", Fix.empty, "magic-byte check failed");
mustReject("garbage 4096B", #avatar, "image/png", Fix.garbage, "magic-byte check failed");
mustReject("trunc_jpeg_soi", #avatar, "image/jpeg", Fix.trunc_jpeg_soi, "magic-byte check failed"); // 2 bytes: FF D8 — too short even to sniff FF D8 FF
mustReject("jpeg_no_sof (SOI+EOI)", #avatar, "image/jpeg", Fix.jpeg_no_sof, "EOI without a frame header");
mustReject("trunc_png_20", #avatar, "image/png", Fix.trunc_png_20, "png: truncated header");
mustReject("png_bad_ihdr", #avatar, "image/png", Fix.png_bad_ihdr, "not IHDR");
mustReject("png_zero_width", #avatar, "image/png", Fix.png_zero_width, "zero dimension");
mustReject("gif_bad_version", #avatar, "image/gif", Fix.gif_bad_version, "bad version");
mustReject("webp_bad_fourcc (WEBQ)", #avatar, "image/webp", Fix.webp_bad_fourcc, "not WEBP");
mustReject("webp_bad_startcode", #avatar, "image/webp", Fix.webp_bad_startcode, "start code");

Debug.print("— magic-spoof: declared type must match sniffed magic —");
mustReject("png declared jpeg", #avatar, "image/jpeg", Fix.png_ok_64, "content_type mismatch");
mustReject("jpeg declared png", #avatar, "image/png", Fix.jpeg_ok_64, "content_type mismatch");
mustReject("gif declared webp", #avatar, "image/webp", Fix.gif_ok_64, "content_type mismatch");
mustReject("webp declared gif", #avatar, "image/gif", Fix.webp_lossy_64, "content_type mismatch");
mustReject("jpeg declared gif", #avatar, "image/gif", Fix.jpeg_ok_64, "content_type mismatch");

Debug.print("IMAGE SUITE: " # Nat.toText(passCount) # " accepts + " # Nat.toText(rejectCount) # " rejects, all as expected");
