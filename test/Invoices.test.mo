import Invoices "../src/Invoices";
import Principal "mo:core/Principal";
import Result "mo:core/Result";

// Two distinct principals.
let alice = Principal.fromText("aaaaa-aa");
let bob = Principal.fromText("2vxsx-fae");

let s = Invoices.init();
let items = [
  { description = "Widget"; quantity = 3; unitPriceE8s = 100_000_000 },
  { description = "Bolt";   quantity = 2; unitPriceE8s = 50_000_000 },
];

// Totals: subtotal 3*1e8 + 2*0.5e8 = 4e8; 10% tax = 4e7; total 4.4e8.
let t = Invoices.computeTotals(items, 1000);
assert (t.subtotalE8s == 400_000_000);
assert (t.taxE8s == 40_000_000);
assert (t.totalE8s == 440_000_000);

// Create draft — totals recomputed, one audit entry.
let inv = Invoices.create(s, 0, alice, bob, items, 1000);
assert (inv.totalE8s == 440_000_000);
assert (Invoices.statusText(inv.status) == "draft");
assert (inv.history.size() == 1);

// Only the issuer can issue.
assert (Result.isErr(Invoices.issue(s, 1, bob, inv.id)));
assert (Result.isOk(Invoices.issue(s, 1, alice, inv.id)));

// Audit grew by one; status advanced.
switch (Invoices.get(s, inv.id)) {
  case (?i) { assert (i.history.size() == 2); assert (Invoices.statusText(i.status) == "issued") };
  case null { assert false };
};

// Cannot issue twice (monotonic).
assert (Result.isErr(Invoices.issue(s, 2, alice, inv.id)));

// Recipient pays; no double-pay; cannot void a paid invoice.
assert (Result.isOk(Invoices.markPaid(s, 3, bob, inv.id)));
assert (Result.isErr(Invoices.markPaid(s, 4, bob, inv.id)));
assert (Result.isErr(Invoices.void(s, 5, alice, inv.id)));

// Void path from draft; then cannot pay a void invoice.
let inv2 = Invoices.create(s, 6, alice, bob, items, 0);
assert (Result.isOk(Invoices.void(s, 7, alice, inv2.id)));
assert (Result.isErr(Invoices.markPaid(s, 8, bob, inv2.id)));

// createIssued is draft+issue in one (two audit entries, issued).
let inv3 = Invoices.createIssued(s, 9, alice, bob, items, 500);
assert (Invoices.statusText(inv3.status) == "issued");
assert (inv3.history.size() == 2);

// Reads.
assert (Invoices.count(s) == 3);
assert (Invoices.forPrincipal(s, alice).size() == 3);
assert (Invoices.forPrincipal(s, bob).size() == 3);
