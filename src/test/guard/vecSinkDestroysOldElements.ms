// nim-guard: a value seq's =sink runs the seq's whole =destroy (elements, then
// payload) on the old destination when the payloads differ.
//
// Nim liftdestructors.nim fillSeqOp attachedSink: `move(x, y, destructorCall(
// t.destructor, x))`; the seq destructor is forallElements + destroy. NIM-REF AN-17
// (per-type sink ops SAME). Proven red on main c36ed0ab, whose arrayOp "sink" freed
// the old payload with a bare msArrayDestroy: Item alloc=11 destroy=4 on drc and orc.
//
// RED MEANS a lifted Vec<T> =sink (struct field or <T>ArraySink) drops the old
// elements; run /trace-nim on arrayOp "sink" in destructorLifting.ms.
//
// GUARD-BALANCE Item

class Item {
	name: string;
	constructor(n: string) { this.name = n; }
}

struct Holder {
	items: Vec<Item>;
}

struct Box {
	it: Item;
}

function mkVec(): Vec<Box> {
	return [{ it: new Item("n1") }];
}

function fieldSink(): string {
	const h1: Holder = { items: [new Item("a"), new Item("b")] };
	let h2: Holder = { items: [new Item("c"), new Item("d"), new Item("e")] };
	h2 = h1;
	return h2.items.length.toString() + h2.items[0].name;
}

function perTypeSink(): string {
	let v: Vec<Box> = [{ it: new Item("a") }, { it: new Item("b") }];
	v = mkVec();
	return v.length.toString() + v[0].it.name;
}

function perTypeCopyThenSink(): string {
	const w: Vec<Box> = [{ it: new Item("w") }];
	let v: Vec<Box> = [{ it: new Item("c") }, { it: new Item("d") }];
	v = w;
	return v.length.toString() + w.length.toString();
}

function main(): void {
	console.log(fieldSink());
	console.log(perTypeSink());
	console.log(perTypeCopyThenSink());
	console.log("GUARD-OK");
}
main();
