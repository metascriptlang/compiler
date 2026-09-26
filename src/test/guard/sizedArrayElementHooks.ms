// nim-guard: a value array T[N] whose element has hooks copies, sinks and destroys
// element by element.
//
// Nim liftdestructors.nim fillBody `of tyArray: if tfHasAsgn in t.flags:
// forallElements(c, t, body, x, y)`; tyArray carries tfHasAsgn from its element
// (propagateToOwner). NIM-REF: no entry for T[N]. Proven red on main c36ed0ab,
// which had no SizedArray arm in fillBody or classify: Item alloc=9 destroy=1 on
// drc and orc (locals, fields and copies all leaked, element writes freed shares).
//
// RED MEANS a T[N] local, field, copy or sink skipped its elements' hooks; run
// /trace-nim on the SizedArray arms of fillBody and classifyType.
//
// GUARD-BALANCE Item
// GUARD-JS

class Item {
	name: string;
	constructor(n: string) { this.name = n; }
}

struct Holder {
	names: string[3];
	items: Item[2];
}

function mk(s: string, i: int32): string {
	return s + i.toString() + "-long-enough-to-be-heap-allocated";
}

function local(): string {
	const items: Item[2] = [new Item("i1"), new Item("i2")];
	return items[1].name;
}

function copyThenWrite(): string {
	const a: string[2] = [mk("a", 1), mk("b", 2)];
	let b: string[2] = a;
	b[0] = mk("c", 3);
	const junk: string[] = [];
	for (let i: int32 = 0; i < 50; i += 1) { junk.push(mk("z", i)); }
	return a[0] + " " + b[0];
}

function fields(): string {
	let h: Holder = { names: [mk("a", 0), mk("b", 0), mk("c", 0)], items: [new Item("i3"), new Item("i4")] };
	let g: Holder = h;
	g.names[0] = mk("q", 0);
	g.items[0] = new Item("i5");
	h = g;
	return h.names[0] + " " + h.items[0].name + " " + h.items[1].name;
}

function reassign(): string {
	let items: Item[2] = [new Item("i6"), new Item("i7")];
	items = [new Item("i8"), new Item("i9")];
	return items[0].name;
}

function main(): void {
	console.log(local());
	console.log(copyThenWrite());
	console.log(fields());
	console.log(reassign());
	console.log("GUARD-OK");
}
main();
