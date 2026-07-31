/// app.mo — the integration test actor: Media.mo wired next to Admin.mo and
/// Users.mo the way a real application uses the library — an admin-gated app
/// logo, an avatar per user, photos, and certified serve. It is also the
/// vehicle for the upgrade-survival and storage-independence suites, which
/// need a real canister (upgrades, and a heap measured across messages where
/// the collector runs).
///
/// Every piece of state lives in stable fields of this `persistent actor`;
/// the modules are pure. After each media mutation the actor republishes
/// the tree root via CertifiedData — the certification seam in action.

import Admin "../../src/Admin";
import Users "../../src/Users";
import Media "../../src/Media";
import CertifiedData "mo:core/CertifiedData";
import Time "mo:core/Time";
import Prim "mo:⛔";

persistent actor MediaApp {

  let admin = Admin.init();
  let users = Users.init();
  let media = Media.init();

  func republish() {
    CertifiedData.set(Media.root(media));
  };

  // ── Admin surface (Admin.mo pattern) ──
  public shared ({ caller }) func claimOwner() : async Bool {
    Admin.claimOwner(admin, caller);
  };

  // ── Users surface (Users.mo pattern) ──
  public shared ({ caller }) func register(name : Text) : async Users.Profile {
    Users.register(users, caller, name, Time.now());
  };

  // ── Media surface ──
  public shared ({ caller }) func startUpload(id : Text, mediaClass : Media.Class, contentType : Text, totalChunks : Nat) : async () {
    Media.startUploadOrTrap(media, admin, caller, id, mediaClass, contentType, totalChunks);
  };

  public shared ({ caller }) func putChunk(id : Text, index : Nat, bytes : Blob) : async () {
    Media.storeChunkOrTrap(media, admin, caller, id, index, bytes);
  };

  public shared ({ caller }) func finishUpload(id : Text) : async Media.FinishReply {
    let rep = Media.finishUploadOrTrap(media, admin, caller, id);
    // The avatar path lands on the caller's profile (the storage law: the
    // app keeps the pointer, Media keeps the bytes).
    switch (rep.path) {
      case (path) {
        if (Users.isRegistered(users, caller)) {
          ignore Users.setAvatar(users, caller, path);
        };
      };
    };
    republish();
    rep;
  };

  public shared ({ caller }) func clearAvatar() : async Bool {
    let r = Media.clearAvatar(media, caller);
    republish();
    r;
  };

  public shared ({ caller }) func deletePhoto(sha256Hex : Text) : async Bool {
    let r = Media.deletePhotoOrTrap(media, caller, sha256Hex);
    republish();
    r;
  };

  public shared ({ caller }) func deleteLogo(name : Text) : async Bool {
    let r = Media.deleteLogoOrTrap(media, admin, caller, name);
    republish();
    r;
  };

  // ── Queries ──
  public query func http_request(req : Media.HttpRequest) : async Media.HttpResponse {
    Media.httpRequest(media, req);
  };

  public query func mediaInfo(path : Text) : async ?Media.MediaInfo {
    Media.mediaInfo(media, path);
  };

  public query func listPaths() : async [Text] {
    Media.listPaths(media);
  };

  public query func storageStats() : async Media.StorageStats {
    Media.storageStats(media);
  };

  public query func chunkProgress(id : Text) : async ?Media.ChunkProgress {
    Media.chunkProgress(media, id);
  };

  public query func getAvatar(principalText : Text) : async ?{ path : Text; sha256Hex : Text } {
    Media.getAvatar(media, principalText);
  };

  public query func getLogo(name : Text) : async ?{ path : Text; sha256Hex : Text } {
    Media.getLogo(media, name);
  };

  public query func getMediaWithWitness(path : Text) : async Media.CertifiedMediaReply {
    Media.getMediaWithWitness(media, path);
  };

  public query func rootHex() : async Text {
    Media.hexEncode(Media.root(media));
  };

  public query func profileOf(p : Principal) : async ?Users.Profile {
    Users.get(users, p);
  };

  // ── Telemetry for the storage-independence suite (heap-independence, measured) ──
  public query func heapSize() : async Nat {
    Prim.rts_heap_size();
  };
}
