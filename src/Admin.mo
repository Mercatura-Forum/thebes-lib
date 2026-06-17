/// Admin.mo — the STANDARD admin surface every Thebes app embeds.
///
/// This is a PURE MODULE, not an actor. It owns no state itself; instead the
/// host actor holds a single `Admin.State` value in a top-level `var` (which is
/// stable by default under `persistent actor`), and passes it into these
/// functions. This is the "externalize-state" pattern: state survives upgrades
/// because it lives in the actor, and all logic lives here where it can be
/// reused and unit-checked.
///
/// What you get:
///   • Owner claim/transfer  — first-caller-claims, then owner-only transfer.
///   • Admins set            — owner adds/removes admins; admins are a privilege
///                             tier below the owner.
///   • isOwner / isAdmin     — boolean checks (admin tier INCLUDES the owner).
///   • requireOwner / requireAdmin — guards that Runtime.trap on failure; call
///                             them at the TOP of a privileged method.
///   • paused flag + requireNotPaused — an emergency stop. Owner/admin can flip
///                             `paused`; guarded methods refuse while paused.
///
/// Trust model: authority is keyed on the caller `Principal`. The host actor
/// must pass `msg.caller` (the ingress sender on Thebes) as the `caller`
/// argument — never a value derived from untrusted call arguments.
///
/// mo:core conventions used here: `Set` with an explicit comparator
/// (`Principal.compare`), `Set.add` (overwrites, returns void), `.values()`.

import Set "mo:core/Set";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Iter "mo:core/Iter";

module {

  /// The admin state the host actor holds in a stable var.
  /// `owner = null` means "unclaimed" — the first caller of claim() takes it.
  public type State = {
    var owner : ?Principal;
    var admins : Set.Set<Principal>;
    var paused : Bool;
  };

  /// Build a fresh, unclaimed admin state. Call once at actor init:
  ///   var admin = Admin.init();
  public func init() : State {
    {
      var owner = null;
      var admins = Set.empty<Principal>();
      var paused = false;
    };
  };

  // ── Ownership ─────────────────────────────────────────────────────────────

  /// First-caller-claims. Returns true if `caller` just became owner; false if
  /// the owner was already set (claim is a no-op once claimed — transfer is the
  /// only way to change owner after that).
  public func claimOwner(s : State, caller : Principal) : Bool {
    switch (s.owner) {
      case null { s.owner := ?caller; true };
      case (?_) { false };
    };
  };

  /// Owner-only handover. Returns true on success; false if there is no owner
  /// yet or `caller` is not the current owner. The new owner replaces the old;
  /// the old owner is NOT auto-added to the admins set.
  public func transferOwner(s : State, caller : Principal, newOwner : Principal) : Bool {
    switch (s.owner) {
      case null { false };
      case (?cur) {
        if (Principal.equal(cur, caller)) { s.owner := ?newOwner; true }
        else { false };
      };
    };
  };

  public func getOwner(s : State) : ?Principal { s.owner };

  /// True iff `caller` is the current owner.
  public func isOwner(s : State, caller : Principal) : Bool {
    switch (s.owner) {
      case null { false };
      case (?cur) { Principal.equal(cur, caller) };
    };
  };

  // ── Admins ──────────────────────────────────────────────────────────────--

  /// True iff `caller` is the owner OR a member of the admins set. The owner is
  /// always an admin by definition — you never have to add the owner explicitly.
  public func isAdmin(s : State, caller : Principal) : Bool {
    if (isOwner(s, caller)) { true }
    else { Set.contains(s.admins, Principal.compare, caller) };
  };

  /// Owner-only: grant admin to `who`. Returns true on success; false if
  /// `caller` is not the owner. Adding an existing admin is a harmless no-op
  /// (Set.add overwrites).
  public func addAdmin(s : State, caller : Principal, who : Principal) : Bool {
    if (not isOwner(s, caller)) { false }
    else { Set.add(s.admins, Principal.compare, who); true };
  };

  /// Owner-only: revoke admin from `who`. Returns true if `caller` is the owner
  /// (whether or not `who` was actually an admin — removal is idempotent);
  /// false if `caller` is not the owner. The owner cannot be removed this way
  /// because the owner is not stored in the admins set.
  public func removeAdmin(s : State, caller : Principal, who : Principal) : Bool {
    if (not isOwner(s, caller)) { false }
    else { ignore Set.delete(s.admins, Principal.compare, who); true };
  };

  /// Snapshot of the admins set as an array (owner NOT included — query the
  /// owner separately via getOwner). Use in a `getAdmins` query method.
  public func getAdmins(s : State) : [Principal] {
    Iter.toArray(Set.values(s.admins));
  };

  // ── Pause (emergency stop) ─────────────────────────────────────────────────

  /// Admin-or-owner: set the emergency-stop flag. Returns true on success;
  /// false if `caller` is not admin/owner. Guarded methods (see
  /// requireNotPaused) refuse to run while paused — read-only queries are
  /// unaffected unless you choose to guard them too.
  public func setPaused(s : State, caller : Principal, value : Bool) : Bool {
    if (not isAdmin(s, caller)) { false }
    else { s.paused := value; true };
  };

  public func isPaused(s : State) : Bool { s.paused };

  // ── Guards (trap on failure) ───────────────────────────────────────────────
  // Call these at the TOP of a privileged update method. They Runtime.trap with
  // a clear message, which rejects the call and reverts all state changes made
  // in that call — there is no partial mutation.

  /// Trap unless `caller` is the owner.
  public func requireOwner(s : State, caller : Principal) {
    if (not isOwner(s, caller)) { Runtime.trap("Admin: caller is not the owner") };
  };

  /// Trap unless `caller` is the owner or an admin.
  public func requireAdmin(s : State, caller : Principal) {
    if (not isAdmin(s, caller)) { Runtime.trap("Admin: caller is not an admin") };
  };

  /// Trap if the contract is paused. Put this FIRST in any user-facing method
  /// you want the emergency stop to disable.
  public func requireNotPaused(s : State) {
    if (s.paused) { Runtime.trap("Admin: contract is paused") };
  };

};
