// nim-guard: a ref field's =sink releases the destination's share even when the
// source points at the same object.
//
// Nim liftdestructors.nim atomicRefOp attachedSink: acyclic `if nimDecRefIsLast(x):
// destroy; x = y`, cyclic `tmp = x; x = y; if nimDecRefIsLastCyclic(tmp): destroy` —
// no x != y test: dest and src each own a share of the pointee. NIM-REF AN-17 /
// AN-19 (ref ops SAME). Proven red on main c36ed0ab, whose sink wrapped the decref
// in `if (dest.f != src.f)`: Item alloc=2 destroy=0, Node alloc=1 destroy=0 on drc
// and orc.
//
// RED MEANS a value struct's lifted =sink skips or misorders the old ref field's
// release; run /trace-nim on refOp "sink" in destructorLifting.ms.
//
// GUARD-BALANCE Item
// GUARD-BALANCE Node

class Item {
	name: string;
	constructor(n: string) { this.name = n; }
}

class Node {
	next: Node | null = null;
	name: string = "";
}

struct S {
	it: Item;
	n: int32;
}

struct H {
	node: Node;
	n: int32;
}

function sameInLoop(): string {
	let a: S = { it: new Item("x"), n: 0 };
	for (let i: int32 = 1; i <= 64; i += 1) {
		a = { it: a.it, n: i };
	}
	return a.it.name + a.n.toString();
}

function sameTwice(): string {
	const item = new Item("y");
	let a: S = { it: item, n: 1 };
	a = { it: item, n: 2 };
	return a.it.name + a.n.toString();
}

function cyclicPointee(): string {
	const node = new Node();
	node.name = "z";
	let h: H = { node: node, n: 0 };
	for (let i: int32 = 1; i <= 64; i += 1) {
		h = { node: h.node, n: i };
	}
	return h.node.name + h.n.toString();
}

function main(): void {
	console.log(sameInLoop());
	console.log(sameTwice());
	console.log(cyclicPointee());
	console.log("GUARD-OK");
}
main();
