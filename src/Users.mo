/// Users.mo — user registration + profiles + role tiers, built ON TOP of Admin.
///
/// A PURE MODULE (no actor, no state of its own). The host actor holds one
/// `Users.State` in a top-level `let` (stable under `persistent actor`,
/// because `mo:core/Map` is mutated in place) and passes it in.
///
/// What you get:
///   • register(name)       — create/update the caller's profile (idempotent).
///   • setAvatar(path)      — store the caller's media-contract avatar PATH
///                            (e.g. "/avatar/{principal}"); the image BYTES live
///                            in the media contract, never here — this app only
///                            holds the pointer (the storage law).
///   • role tiers           — owner | admin | user | guest. Authority is NOT
///                            duplicated: owner/admin come straight from Admin
///                            (single source of truth); a registered caller is a
///                            `user`; everyone else is a `guest`.
///   • requireRole(min)     — guard that Runtime.traps below the required tier.
///   • get / all / count    — read profiles (use Pagination for large lists).
///
/// Trust model: every write is keyed on the caller `Principal` the host actor
/// passes (`msg.caller` on Thebes) — never a value from untrusted arguments.
///
/// Storage: `mo:core/Map` (a B-tree of order 32 — ordered + memory-efficient),
/// keyed by `Principal` with `Principal.compare`.

import Map "mo:core/Map";
import Principal "mo:core/Principal";
import Iter "mo:core/Iter";
import Runtime "mo:core/Runtime";
import Admin "Admin";

module {

  /// Role tiers, lowest to highest privilege.
  public type Role = { #guest; #user; #admin; #owner };

  /// A user's public profile. `avatarPath` is a pointer into the media
  /// contract, not image bytes.
  public type Profile = {
    displayName : Text;
    avatarPath : ?Text;
    createdAt : Int;
  };

  /// The state the host actor holds (one B-tree of principal → profile).
  public type State = { profiles : Map.Map<Principal, Profile> };

  /// Fresh, empty state. Call once at actor init: `let users = Users.init();`
  public func init() : State { { profiles = Map.empty<Principal, Profile>() } };

  func rank(r : Role) : Nat {
    switch r { case (#guest) 0; case (#user) 1; case (#admin) 2; case (#owner) 3 };
  };

  /// True iff `p` has a profile.
  public func isRegistered(s : State, p : Principal) : Bool {
    switch (Map.get(s.profiles, Principal.compare, p)) { case (?_) true; case null false };
  };

  /// Effective role of `p` — owner/admin come from Admin (single authority),
  /// a registered principal is a `user`, otherwise `guest`.
  public func roleOf(admin : Admin.State, s : State, p : Principal) : Role {
    if (Admin.isOwner(admin, p)) #owner
    else if (Admin.isAdmin(admin, p)) #admin
    else if (isRegistered(s, p)) #user
    else #guest;
  };

  /// Guard: trap unless `caller`'s effective role is at least `min`. Call at the
  /// TOP of a privileged method — the trap reverts all state changes.
  public func requireRole(admin : Admin.State, s : State, caller : Principal, min : Role) {
    if (rank(roleOf(admin, s, caller)) < rank(min)) {
      Runtime.trap("Users: caller lacks the required role");
    };
  };

  /// Create or update the caller's profile. Re-registering updates the display
  /// name and preserves the avatar + createdAt. Returns the resulting profile.
  public func register(s : State, caller : Principal, displayName : Text, now : Int) : Profile {
    let name = if (displayName.size() == 0) "anon" else displayName;
    let prof : Profile = switch (Map.get(s.profiles, Principal.compare, caller)) {
      case (?p) { { p with displayName = name } };
      case null { { displayName = name; avatarPath = null; createdAt = now } };
    };
    Map.add(s.profiles, Principal.compare, caller, prof);
    prof;
  };

  /// Store the caller's media-contract avatar path. Returns false if the caller
  /// has not registered yet (register first).
  public func setAvatar(s : State, caller : Principal, avatarPath : Text) : Bool {
    switch (Map.get(s.profiles, Principal.compare, caller)) {
      case (?p) {
        Map.add(s.profiles, Principal.compare, caller, { p with avatarPath = ?avatarPath });
        true;
      };
      case null { false };
    };
  };

  /// Read one profile.
  public func get(s : State, p : Principal) : ?Profile {
    Map.get(s.profiles, Principal.compare, p);
  };

  /// Number of registered users.
  public func count(s : State) : Nat { Map.size(s.profiles) };

  /// All (principal, profile) pairs in principal order. For large directories,
  /// page this with `Pagination.page`.
  public func all(s : State) : [(Principal, Profile)] {
    Iter.toArray(Map.entries(s.profiles));
  };

};
