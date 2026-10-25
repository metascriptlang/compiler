// nim-guard: a view a task passes to a constructor that stores it is a store of the view.
//
// INVARIANT (ULTRALOCK V5): in task-reached code, storing a view into an owning slot is refused.
//   A constructor parameter the body stores into a field takes a count on the argument exactly
//   as the direct field store would, so a borrowed argument to it is refused: a part of a deep
//   Readonly module const and a part of the parent's BORROW alike, through an own, an inherited
//   and a `super` constructor, a generic class, a constructor that builds the storing object
//   from its parameter, a nested `new`, and a setter method.
//
// WHAT IT CATCHES: the count taken in the constructor on a cell the parent and the other tasks
//   share. Before the fix every `new` shape compiled, and TSan reported a plain msIncRef /
//   msDecRefIsLast race and an msSlabFree of the shared cell on the const and BORROW probes.
//
// RED MEANS: one of the shapes compiled.
//
// GUARD-CHECK-FAIL is a view the task does not own

class Child { n: int32 = 1; }
class Cell { child: Child = new Child(); }
class Holder { c: Readonly<Child>; constructor(c: Readonly<Child>) { this.c = c; } }
class Inherited extends Holder {}
class ViaSuper extends Holder { m: int32; constructor(c: Readonly<Child>) { super(c); this.m = 2; } }
class Outer { h: Holder; constructor(h: Holder) { this.h = h; } }
class Builds { h: Holder; constructor(c: Readonly<Child>) { this.h = new Holder(c); } }
class Box<T> { v: T; constructor(v: T) { this.v = v; } }
class Slot { c: Readonly<Child> | null = null; set(c: Readonly<Child>): void { this.c = c; } }

const K: Readonly<Cell> = new Cell();

function fromConst(): int32 { return new Holder(K.child).c.n; }
function fromBorrow(k: Readonly<Cell>): int32 { return new Holder(k.child).c.n; }
function inherited(k: Readonly<Cell>): int32 { return new Inherited(k.child).c.n; }
function viaSuper(k: Readonly<Cell>): int32 { return new ViaSuper(k.child).c.n; }
function nested(k: Readonly<Cell>): int32 { return new Outer(new Holder(k.child)).h.c.n; }
function builds(): int32 { return new Builds(K.child).h.c.n; }
function generic(k: Readonly<Cell>): int32 { return new Box<Readonly<Child>>(k.child).v.n; }
function setter(k: Readonly<Cell>): int32 {
	const s = new Slot();
	s.set(k.child);
	return s.c != null ? s.c.n : 0;
}

async function main(): Promise<void> {
	const k = new Cell();
	const a = spawn(() => fromConst()); // GUARD-REFUSED
	const b = spawn(() => fromBorrow(k)); // GUARD-REFUSED
	const c = spawn(() => inherited(k)); // GUARD-REFUSED
	const d = spawn(() => viaSuper(k)); // GUARD-REFUSED
	const e = spawn(() => nested(k)); // GUARD-REFUSED
	const f = spawn(() => builds()); // GUARD-REFUSED
	const g = spawn(() => generic(k)); // GUARD-REFUSED
	const h = spawn(() => setter(k)); // GUARD-REFUSED
	console.log(await a, await b, await c, await d, await e, await f, await g, await h);
}

await main();
