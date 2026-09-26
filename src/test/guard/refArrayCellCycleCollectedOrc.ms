// nim-guard: under ORC a cycle that runs through a T[] field's heap cell is
// collected.
//
// Nim liftdestructors.nim fillSeqOp attachedTrace (`if canFormAcycle(elemType):
// forallElements`) gives seq[T] a =trace that follows its elements, and
// ccgtypes.nim genTypeInfoV2 hangs it on the seq's own TypeInfo (traceImpl, the
// acyclic flag from canFormAcycle), one TypeInfo per seq type. NIM-REF AN-20, CG-2.
// Proven red on main c36ed0ab and on wt/nim-hooks 8e3c3461, where every class
// element array shared one msRefArrayRefCell TypeInfo with no traceFn: TNode
// alloc=400 destroy=0, Peer alloc=400 destroy=0, Opt alloc=400 destroy=0, Grid
// alloc=400 destroy=0, Hub alloc=400 destroy=0, Named alloc=400 destroy=0 under orc.
//
// RED MEANS a ref-array cell TypeInfo lost its traceFn, or the lifter stopped
// lifting the cell trace for a cyclic element; run /trace-nim on the named type.
//
// GUARD-BALANCE Leaf
// GUARD-BALANCE-ORC TNode
// GUARD-BALANCE-ORC Peer
// GUARD-BALANCE-ORC Opt
// GUARD-BALANCE-ORC Grid
// GUARD-BALANCE-ORC Hub
// GUARD-BALANCE-ORC Named

class TNode {
	parent: TNode | null = null;
	children: TNode[] = [];
	id: int32 = 0;
}

class Peer {
	name: string;
	kids: Peer[];
	constructor(n: string) { this.name = n; this.kids = []; }
}

class Opt {
	name: string;
	slots: (Opt | null)[];
	constructor(n: string) { this.name = n; this.slots = []; }
}

class Grid {
	name: string;
	cells: Grid[][];
	constructor(n: string) { this.name = n; this.cells = []; }
}

interface Link { to: Hub; w: int32; }

class Hub {
	name: string;
	links: Link[];
	constructor(n: string) { this.name = n; this.links = []; }
}

class Named {
	name: string;
	fns: (() => string)[];
	constructor(n: string) { this.name = n; this.fns = []; }
}

class Leaf { v: int32 = 0; }

class Holder {
	leaves: Leaf[] = [];
	grid: Leaf[][] = [];
}

function tree(i: int32): int32 {
	const root = new TNode();
	root.id = i;
	const c = new TNode();
	c.id = i + 1;
	c.parent = root;
	root.children.push(c);
	return root.children.length as int32;
}

function peers(i: int32): int32 {
	const a = new Peer("a" + i.toString());
	const b = new Peer("b" + i.toString());
	a.kids.push(b);
	b.kids.push(a);
	return a.kids.length as int32;
}

function opts(i: int32): int32 {
	const a = new Opt("a" + i.toString());
	const b = new Opt("b" + i.toString());
	a.slots.push(b);
	b.slots.push(a);
	return b.slots.length as int32;
}

function grids(i: int32): int32 {
	const a = new Grid("a" + i.toString());
	const b = new Grid("b" + i.toString());
	a.cells.push([b]);
	b.cells.push([a]);
	return a.cells.length as int32;
}

function hubs(i: int32): int32 {
	const a = new Hub("a" + i.toString());
	const b = new Hub("b" + i.toString());
	a.links.push({ to: b, w: i });
	b.links.push({ to: a, w: i });
	return a.links.length as int32;
}

function nameOf(n: Named): () => string {
	return () => n.name;
}

function closures(i: int32): int32 {
	const a = new Named("a" + i.toString());
	const b = new Named("b" + i.toString());
	a.fns.push(nameOf(b));
	b.fns.push(nameOf(a));
	return a.fns.length as int32;
}

function leaves(i: int32): int32 {
	const h = new Holder();
	const l = new Leaf();
	l.v = i;
	h.leaves.push(l);
	h.grid.push([new Leaf()]);
	return h.leaves.length as int32;
}

function main(): void {
	let total: int32 = 0;
	for (let i: int32 = 0; i < 200; i++) {
		total = total + tree(i) + peers(i) + opts(i) + grids(i) + hubs(i) + closures(i) + leaves(i);
	}
	console.log(total);
	console.log("GUARD-OK");
}
main();
