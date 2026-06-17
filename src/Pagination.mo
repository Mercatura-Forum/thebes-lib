/// Pagination.mo — bounded, offset-cursor paging over an ordered array.
///
/// The storage law says every unbounded collection must be paginated. This is
/// the shared helper: callers materialize an ordered slice (e.g.
/// `Iter.toArray(Map.entries(map))`, which `mo:core/Map` returns in key order)
/// and hand it here with an `offset` + `limit`. Returns the page plus the next
/// offset (`null` when exhausted) and the total count — everything a UI needs
/// to render "showing X–Y of N" and a "load more" cursor.
///
/// Offsets are stable for append-mostly logs read newest-last; for mutate-heavy
/// maps prefer keying the cursor on the last key returned (a future extension).

import Array "mo:core/Array";
import Nat "mo:core/Nat";

module {

  public type Page<T> = {
    items : [T];
    nextOffset : ?Nat; // null when there are no more items
    total : Nat;
  };

  /// Default page size when the caller passes `limit = 0`.
  let DEFAULT_LIMIT : Nat = 20;
  /// Hard ceiling so a single call can't return an unbounded slice.
  let MAX_LIMIT : Nat = 200;

  /// Slice `all[offset ..< offset+limit]` into a page. `limit = 0` uses the
  /// default; limits above MAX_LIMIT are clamped.
  public func page<T>(all : [T], offset : Nat, limit : Nat) : Page<T> {
    let total = all.size();
    let lim = if (limit == 0) DEFAULT_LIMIT else Nat.min(limit, MAX_LIMIT);
    if (offset >= total) {
      return { items = []; nextOffset = null; total };
    };
    let end = Nat.min(offset + lim, total);
    let items = Array.tabulate<T>(end - offset, func(i) { all[offset + i] });
    { items; nextOffset = (if (end < total) ?end else null); total };
  };

};
