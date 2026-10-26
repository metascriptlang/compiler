// nim-guard: a for-of over a map's (key, value) pairs releases the pair it was handed
//
// INVARIANT (reference semtypinst.nim replaceTypeVarsTAux: a type built by substitution gets
//   propagateToOwner for each element, so tfHasAsgn follows the instance): a tuple whose
//   elements become managed once its type arguments are bound has destroy hooks, so the
//   `IteratorResult<[K, V]>` the loop keeps in its result slot is destroyed when it is
//   overwritten and when the loop ends.
//
// WHAT IT CATCHES: the substituted tuple losing HasAsgn. The result struct then has no hooks, the
//   pair copied out of the iterator keeps one count per step, and every value stored in the map
//   leaks (Item alloc=N destroy=0). Plain `values()` and `forEach` never showed it.
//
// RED MEANS: type substitution stopped propagating HasAsgn into a tuple or union. Run /trace-nim
//   on `IteratorResult<[K, V]>` with a managed V.
// GUARD-BALANCE Item
// GUARD-BALANCE Row
// GUARD-JS

class Item { s: string; constructor(s: string) { this.s = s; } }
class Row { cells: Item[] = []; }

function filled(): Map<string, Item> {
	const m = new Map<string, Item>();
	m.set("a", new Item("x"));
	m.set("bb", new Item("y"));
	return m;
}

function keyOnly(): number {
	const m = filled();
	let n: number = 0;
	for (const [k, v] of m) { n += k.length; }
	return n;
}

function valueOnly(): number {
	const m = filled();
	let n: number = 0;
	for (const [, v] of m) { n += v.s.length; }
	return n;
}

function both(): number {
	const m = filled();
	let n: number = 0;
	for (const [k, v] of m) { n += k.length + v.s.length; }
	return n;
}

function entriesCall(): number {
	const m = filled();
	let n: number = 0;
	for (const e of m.toPairs()) { n += e[1].s.length; }
	return n;
}

function nested(): number {
	const m = filled();
	let n: number = 0;
	for (const [k, v] of m) {
		for (const [k2, v2] of m) { n += k.length + v2.s.length; }
	}
	return n;
}

function arrayValues(): number {
	const m = new Map<string, Row>();
	const r = new Row();
	r.cells.push(new Item("p"));
	m.set("r", r);
	m.set("q", new Row());
	let n: number = 0;
	for (const [k, row] of m) { n += k.length + row.cells.length; }
	return n;
}

function intKeys(): number {
	const m = new Map<number, Item>();
	m.set(1, new Item("x"));
	m.set(2, new Item("yy"));
	let n: number = 0;
	for (const [k, v] of m) { n += k + v.s.length; }
	return n;
}

let i: int32 = 0;
let total: number = 0;
while (i < 50) {
	total += keyOnly() + valueOnly() + both() + entriesCall() + nested() + arrayValues() + intKeys();
	i += 1;
}
console.log(total);
console.log("GUARD-OK");
