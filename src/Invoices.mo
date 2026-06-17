/// Invoices.mo — a reusable invoicing surface for Thebes apps.
///
/// A PURE MODULE (no actor, no state of its own). The host actor holds one
/// `Invoices.State` in a top-level `let` (stable under `persistent actor`,
/// because `mo:core/Map` mutates in place) and passes it in.
///
/// What you get:
///   • create / createIssued — open an invoice from line items. Totals are
///                             ALWAYS recomputed on-chain from the line items and
///                             tax rate; a client can never supply a total.
///   • issue / markPaid / void — the status lifecycle, each guarded by the right
///                             party and a legal source status, each appending to
///                             an immutable audit trail.
///   • get / forPrincipal / all / count — reads (page large lists with
///                             `Pagination.page`).
///
/// Status lifecycle:  draft ──issue──▶ issued ──markPaid──▶ paid
///                      │                  │
///                      └──────void────────┴──▶ void
///
/// Money is in e8s (8 decimals), matching the Thebes token. Tax is in basis
/// points (1% = 100 bps).
///
/// Trust model: every mutation is keyed on the caller `Principal` the host actor
/// passes (`msg.caller` on Thebes) — never a value from untrusted arguments. The
/// mutating functions return `Result`; wrap them with an `*OrTrap` method at the
/// actor boundary so a failed guard rejects the call (never a swallowed `#err`).

import Map "mo:core/Map";
import Array "mo:core/Array";
import Iter "mo:core/Iter";
import Nat "mo:core/Nat";
import Principal "mo:core/Principal";
import Result "mo:core/Result";

module {

  public type InvoiceId = Nat;

  public type LineItem = {
    description : Text;
    quantity : Nat;
    unitPriceE8s : Nat;
  };

  public type Status = { #draft; #issued; #paid; #void };

  /// One entry in an invoice's immutable audit trail.
  public type Event = { at : Int; by : Principal; event : Text };

  public type Invoice = {
    id : InvoiceId;
    issuer : Principal;
    recipient : Principal;
    lineItems : [LineItem];
    taxBps : Nat;
    subtotalE8s : Nat;
    taxE8s : Nat;
    totalE8s : Nat;
    status : Status;
    createdAt : Int;
    history : [Event];
  };

  public type Totals = { subtotalE8s : Nat; taxE8s : Nat; totalE8s : Nat };

  /// The state the host actor holds: a B-tree of id → invoice, and the next id.
  public type State = {
    var nextId : InvoiceId;
    invoices : Map.Map<InvoiceId, Invoice>;
  };

  /// Fresh, empty state. Call once at actor init: `let invoices = Invoices.init();`
  public func init() : State {
    { var nextId = 0; invoices = Map.empty<InvoiceId, Invoice>() };
  };

  public func statusText(s : Status) : Text {
    switch s { case (#draft) "draft"; case (#issued) "issued"; case (#paid) "paid"; case (#void) "void" };
  };

  func statusEq(a : Status, b : Status) : Bool {
    switch (a, b) {
      case (#draft, #draft) true;
      case (#issued, #issued) true;
      case (#paid, #paid) true;
      case (#void, #void) true;
      case _ false;
    };
  };

  /// Recompute totals from the line items. The single source of truth for money —
  /// never accept a total from a caller.
  public func computeTotals(lineItems : [LineItem], taxBps : Nat) : Totals {
    let subtotal = Array.foldLeft<LineItem, Nat>(
      lineItems, 0, func(acc, li) { acc + li.quantity * li.unitPriceE8s },
    );
    let tax = subtotal * taxBps / 10_000;
    { subtotalE8s = subtotal; taxE8s = tax; totalE8s = subtotal + tax };
  };

  func appendEvent(inv : Invoice, now : Int, by : Principal, event : Text) : Invoice {
    { inv with history = Array.concat<Event>(inv.history, [{ at = now; by; event }]) };
  };

  /// Open a DRAFT invoice. `issuer` is the caller; totals are computed on-chain.
  public func create(
    s : State, now : Int, issuer : Principal, recipient : Principal,
    lineItems : [LineItem], taxBps : Nat,
  ) : Invoice {
    let id = s.nextId;
    s.nextId += 1;
    let t = computeTotals(lineItems, taxBps);
    let inv : Invoice = {
      id; issuer; recipient; lineItems; taxBps;
      subtotalE8s = t.subtotalE8s; taxE8s = t.taxE8s; totalE8s = t.totalE8s;
      status = #draft; createdAt = now;
      history = [{ at = now; by = issuer; event = "created" }];
    };
    Map.add(s.invoices, Nat.compare, id, inv);
    inv;
  };

  /// Open an invoice already ISSUED — the common order-to-invoice path.
  public func createIssued(
    s : State, now : Int, issuer : Principal, recipient : Principal,
    lineItems : [LineItem], taxBps : Nat,
  ) : Invoice {
    let draft = create(s, now, issuer, recipient, lineItems, taxBps);
    let issued = appendEvent({ draft with status = #issued }, now, issuer, "issued");
    Map.add(s.invoices, Nat.compare, issued.id, issued);
    issued;
  };

  /// draft → issued. Issuer only.
  public func issue(s : State, now : Int, caller : Principal, id : InvoiceId) : Result.Result<Invoice, Text> {
    switch (Map.get(s.invoices, Nat.compare, id)) {
      case null { #err("invoice not found") };
      case (?inv) {
        if (not Principal.equal(inv.issuer, caller)) { return #err("only the issuer can issue this invoice") };
        if (not statusEq(inv.status, #draft)) { return #err("can only issue a draft invoice (is " # statusText(inv.status) # ")") };
        let next = appendEvent({ inv with status = #issued }, now, caller, "issued");
        Map.add(s.invoices, Nat.compare, id, next);
        #ok(next);
      };
    };
  };

  /// issued → paid. Issuer or recipient.
  public func markPaid(s : State, now : Int, caller : Principal, id : InvoiceId) : Result.Result<Invoice, Text> {
    switch (Map.get(s.invoices, Nat.compare, id)) {
      case null { #err("invoice not found") };
      case (?inv) {
        if (not (Principal.equal(inv.issuer, caller) or Principal.equal(inv.recipient, caller))) {
          return #err("only the issuer or recipient can mark this invoice paid");
        };
        if (not statusEq(inv.status, #issued)) { return #err("can only pay an issued invoice (is " # statusText(inv.status) # ")") };
        let next = appendEvent({ inv with status = #paid }, now, caller, "paid");
        Map.add(s.invoices, Nat.compare, id, next);
        #ok(next);
      };
    };
  };

  /// draft|issued → void. Issuer only. A paid invoice cannot be voided.
  public func void(s : State, now : Int, caller : Principal, id : InvoiceId) : Result.Result<Invoice, Text> {
    switch (Map.get(s.invoices, Nat.compare, id)) {
      case null { #err("invoice not found") };
      case (?inv) {
        if (not Principal.equal(inv.issuer, caller)) { return #err("only the issuer can void this invoice") };
        if (statusEq(inv.status, #paid) or statusEq(inv.status, #void)) {
          return #err("cannot void a " # statusText(inv.status) # " invoice");
        };
        let next = appendEvent({ inv with status = #void }, now, caller, "voided");
        Map.add(s.invoices, Nat.compare, id, next);
        #ok(next);
      };
    };
  };

  // ── Reads ───────────────────────────────────────────────────────────────────

  public func get(s : State, id : InvoiceId) : ?Invoice {
    Map.get(s.invoices, Nat.compare, id);
  };

  public func count(s : State) : Nat { Map.size(s.invoices) };

  /// All invoices in id order. Page large lists with `Pagination.page`.
  public func all(s : State) : [Invoice] {
    Iter.toArray(Map.values(s.invoices));
  };

  /// Invoices where `who` is the issuer or the recipient, in id order.
  public func forPrincipal(s : State, who : Principal) : [Invoice] {
    Iter.toArray(
      Iter.filter<Invoice>(
        Map.values(s.invoices),
        func(inv) { Principal.equal(inv.issuer, who) or Principal.equal(inv.recipient, who) },
      )
    );
  };

};
