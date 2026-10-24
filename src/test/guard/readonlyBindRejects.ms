// A generic std reader on a Readonly array hands out read-only elements
//
// INVARIANT (ULTRALOCK V5, error E24): the receiver's Readonly binds into the type parameter,
//   so find/at/filter/map/some/findIndex on Readonly<Item[]> see Readonly<Item>.
//
// WHAT IT CATCHES: T binding to the bare Item, which let a task write into the parent's lent graph
//   through find()/at()/map() while the parent reads it.
//
// RED MEANS: one of the seven marked lines below is accepted again.
//
// GUARD-CHECK-FAIL readonlyBindRejects.ms:22:
// GUARD-CHECK-FAIL readonlyBindRejects.ms:27:
// GUARD-CHECK-FAIL readonlyBindRejects.ms:31:
// GUARD-CHECK-FAIL readonlyBindRejects.ms:36:
// GUARD-CHECK-FAIL readonlyBindRejects.ms:41:
// GUARD-CHECK-FAIL readonlyBindRejects.ms:45:
// GUARD-CHECK-FAIL readonlyBindRejects.ms:49:
class Item { v: int32 = 0; }

function viaFind(ro: Readonly<Item[]>): void {
	const x = ro.find((y: Readonly<Item>): boolean => y.v == 2);
	if (x != null) x.v = 9;
}

function viaAt(ro: Readonly<Item[]>): void {
	const x = ro.at(1);
	x.v = 9;
}

function mapFormal(ro: Readonly<Item[]>): void {
	const m = ro.map((y: Item) => y);
}

function mapResult(ro: Readonly<Item[]>): void {
	const m = ro.map((y) => y);
	m[0].v = 1;
}

function filterResult(ro: Readonly<Item[]>): void {
	const f = ro.filter((y: Readonly<Item>) => y.v > 0);
	f[0].v = 1;
}

function someFormal(ro: Readonly<Item[]>): void {
	ro.some((y: Item) => y.v > 0);
}

function findIndexFormal(ro: Readonly<Item[]>): void {
	const i = ro.findIndex((y: Item) => y.v > 0);
}
