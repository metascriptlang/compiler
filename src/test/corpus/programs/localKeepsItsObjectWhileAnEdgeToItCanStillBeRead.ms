// @stdout: a b c d e f g h i j k l m
// note: a local of a class keeps its object to the end of its scope while a read through an Unowned edge that can reach the object may still run there. Each function hands `p` over at its last read to something that gives it up before the scope ends (a holder in an inner scope, a binding or a field overwritten, a constructor's object that dies or that throws after its store, a `sink` parameter only read), then reads the edge: in the same function, in a callee, through a closure, in a catch, in a finally, or in the statement that handed it over. An object the local owns and a `sink` parameter of the callee are kept the same way. Before the fix the last read moved the object and the edge read stopped with "an Unowned<P> edge was read after its P was destroyed".
class P { name: string; constructor(name: string) { this.name = name; } }
class H { up: Unowned<P> | null = null; own: P | null = null; }
class Box { own: P | null = null; }
class K { own: P; constructor(p: P) { this.own = p; } }
class KT { own: P; constructor(p: P, on: boolean) { this.own = p; boom(on); } }
class Tree { root: P; constructor(root: P) { this.root = root; } }
class Shelf { own: Tree | null = null; }
function boom(on: boolean): void { if (on) throw new Error("x"); }
function drop(sink p: P): int32 { return p.name.length; }
function peek(h: H): string { return h.up!.name; }
function both(n: int32, s: string): string { return s; }

function holderInInnerScope(): string {
	const h = new H();
	const p = new P("a");
	h.up = p;
	{ const b = new Box(); b.own = p; }
	return h.up!.name;
}

function bindingOverwritten(): string {
	const h = new H();
	const p = new P("b");
	h.up = p;
	let q: P | null = p;
	q = null;
	return h.up!.name;
}

function fieldOverwritten(): string {
	const h = new H();
	const p = new P("c");
	h.up = p;
	h.own = p;
	h.own = null;
	return h.up!.name;
}

function constructorObjectDies(): string {
	const h = new H();
	const p = new P("d");
	h.up = p;
	{ const k = new K(p); }
	return h.up!.name;
}

function sinkParameterOnlyRead(): string {
	const h = new H();
	const p = new P("e");
	h.up = p;
	drop(p);
	return h.up!.name;
}

function readInACallee(): string {
	const h = new H();
	const p = new P("f");
	h.up = p;
	{ const b = new Box(); b.own = p; }
	const s = peek(h);
	return s;
}

function readThroughAClosure(): string {
	const h = new H();
	const p = new P("g");
	h.up = p;
	const g = (): string => h.up!.name;
	{ const b = new Box(); b.own = p; }
	const s = g();
	return s;
}

function readInACatch(): string {
	const h = new H();
	const p = new P("h");
	h.up = p;
	try {
		{ const b = new Box(); b.own = p; }
		boom(true);
	} catch (e) {
		return h.up!.name;
	}
	return "none";
}

function readInAFinally(): string {
	const h = new H();
	const p = new P("i");
	h.up = p;
	let s = "none";
	try {
		{ const b = new Box(); b.own = p; }
	} finally {
		s = h.up!.name;
	}
	return s;
}

function readInTheStatementThatHandsItOver(): string {
	const h = new H();
	const p = new P("j");
	h.up = p;
	return both(drop(p), h.up!.name);
}

function objectOwnedByTheLocal(): string {
	const h = new H();
	const t = new Tree(new P("k"));
	h.up = t.root;
	{ const b = new Shelf(); b.own = t; }
	return h.up!.name;
}

function sinkParameterOfTheCallee(sink p: P, h: H): string {
	{ const b = new Box(); b.own = p; }
	return h.up!.name;
}

function viaSinkParameterOfTheCallee(): string {
	const h = new H();
	const p = new P("l");
	h.up = p;
	return sinkParameterOfTheCallee(p, h);
}

function constructorStoresThenThrows(): string {
	const h = new H();
	const p = new P("m");
	h.up = p;
	try { const k = new KT(p, true); } catch (e) {}
	return h.up!.name;
}

console.log([holderInInnerScope(), bindingOverwritten(), fieldOverwritten(), constructorObjectDies(), sinkParameterOnlyRead(), readInACallee(), readThroughAClosure(), readInACatch(), readInAFinally(), readInTheStatementThatHandsItOver(), objectOwnedByTheLocal(), viaSinkParameterOfTheCallee(), constructorStoresThenThrows()].join(" "));
