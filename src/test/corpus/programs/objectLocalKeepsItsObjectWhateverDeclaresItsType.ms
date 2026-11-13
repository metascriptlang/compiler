// @stdout: a b c d e f g
// note: a local keeps its object while a read through an Unowned edge that can reach it may still run in its scope, whatever declares the object's type: an instance of a generic class, of a generic class with two parameters, of a subclass of one, a record typed by a `type` alias, by a generic alias, by a generic interface, or by its literal alone. Each function hands the local to a holder that dies in an inner scope, then reads the edge. Before the fix only a class or an interface that is not generic kept its object: the others moved at their last read and the read stopped on C and the Raiser with "an Unowned<P> edge was read after its P was destroyed" while JS printed.
class P { name: string; constructor(name: string) { this.name = name; } }
class H { up: Unowned<P> | null = null; }
class Cell<T> { v: T; constructor(v: T) { this.v = v; } }
class CellBag { c: Cell<P> | null = null; }
class Pair<A, B> { a: A; b: B; constructor(a: A, b: B) { this.a = a; this.b = b; } }
class PairBag { p: Pair<P, string> | null = null; }
class PCell extends Cell<P> { constructor(v: P) { super(v); } }
class PCellBag { c: PCell | null = null; }
type Rec = { own: P; n: int32 };
class RecBag { r: Rec | null = null; }
type Slot<T> = { v: T; n: int32 };
class SlotBag { s: Slot<P> | null = null; }
interface Wrap<T> { v: T; }
class WrapBag { w: Wrap<P> | null = null; }
class AnyBag { r: { own: P; n: int32 } | null = null; }

function genericClassInstance(): string {
	const h = new H();
	const c = new Cell<P>(new P("a"));
	h.up = c.v;
	{ const b = new CellBag(); b.c = c; }
	return h.up!.name;
}

function genericClassWithTwoParameters(): string {
	const h = new H();
	const pair = new Pair<P, string>(new P("b"), "x");
	h.up = pair.a;
	{ const b = new PairBag(); b.p = pair; }
	return h.up!.name;
}

function subclassOfAGenericClass(): string {
	const h = new H();
	const c = new PCell(new P("c"));
	h.up = c.v;
	{ const b = new PCellBag(); b.c = c; }
	return h.up!.name;
}

function aliasRecord(): string {
	const h = new H();
	const r: Rec = { own: new P("d"), n: 1 };
	h.up = r.own;
	{ const b = new RecBag(); b.r = r; }
	return h.up!.name;
}

function genericAliasRecord(): string {
	const h = new H();
	const slot: Slot<P> = { v: new P("e"), n: 1 };
	h.up = slot.v;
	{ const b = new SlotBag(); b.s = slot; }
	return h.up!.name;
}

function genericInterfaceRecord(): string {
	const h = new H();
	const wrap: Wrap<P> = { v: new P("f") };
	h.up = wrap.v;
	{ const b = new WrapBag(); b.w = wrap; }
	return h.up!.name;
}

function recordTypedByItsLiteral(): string {
	const h = new H();
	const r = { own: new P("g"), n: 1 };
	h.up = r.own;
	{ const b = new AnyBag(); b.r = r; }
	return h.up!.name;
}

console.log([genericClassInstance(), genericClassWithTwoParameters(), subclassOfAGenericClass(), aliasRecord(), genericAliasRecord(), genericInterfaceRecord(), recordTypedByItsLiteral()].join(" "));
