// A generic std reader on a Readonly array hands out read-only elements
//
// INVARIANT (ULTRALOCK V5, error E24): the receiver's Readonly binds into the type parameter,
//   so find/at/filter/map/some/findIndex on Readonly<Item[]> see Readonly<Item>.
//
// WHAT IT CATCHES: T binding to the bare Item, which let a task write into the parent's lent graph
//   through find()/at()/map() while the parent reads it.
//
// RED MEANS: one of the seven marked lines below is accepted again.
// GUARD-CHECK-FAIL readonlyBindRejects.ms:
class Item { v: int32 = 0; }

function viaFind(ro: Readonly<Item[]>): void {
	const x = ro.find((y: Readonly<Item>): boolean => y.v == 2);
	if (x != null) x.v = 9; // GUARD-REFUSED
}

function viaAt(ro: Readonly<Item[]>): void {
	const x = ro.at(1);
	x.v = 9; // GUARD-REFUSED
}

function mapFormal(ro: Readonly<Item[]>): void {
	const m = ro.map((y: Item) => y); // GUARD-REFUSED
}

function mapResult(ro: Readonly<Item[]>): void {
	const m = ro.map((y) => y);
	m[0].v = 1; // GUARD-REFUSED
}

function filterResult(ro: Readonly<Item[]>): void {
	const f = ro.filter((y: Readonly<Item>) => y.v > 0);
	f[0].v = 1; // GUARD-REFUSED
}

function someFormal(ro: Readonly<Item[]>): void {
	ro.some((y: Item) => y.v > 0); // GUARD-REFUSED
}

function findIndexFormal(ro: Readonly<Item[]>): void {
	const i = ro.findIndex((y: Item) => y.v > 0); // GUARD-REFUSED
}
