// A loop that assigns the narrowed element drops the narrowing after it
//
// INVARIANT (flow narrowing): a narrowed `entry.items[0]` survives a loop that does not write it
//   (corpus narrowElementAcrossLoop); a loop that assigns `entry.items[0]` leaves it the declared union.
//
// RED MEANS: the narrowing now outlives a write to the element, so a read can name a field the
//   stored variant lacks.
//
// GUARD-CHECK-FAIL exists only on some variants

enum Kind { A, B }
struct Item = match (kind: Kind) {
	Kind.A => { name: string },
	Kind.B => { n: int32 },
};
struct Entry { items: Item[]; }

function assigns(entry: Entry): string {
	if (entry.items.length != 2 || entry.items[0].kind != Kind.A) { return "malformed"; }
	for (const item of entry.items) { entry.items[0] = item; }
	return entry.items[0].name; // GUARD-REFUSED
}
