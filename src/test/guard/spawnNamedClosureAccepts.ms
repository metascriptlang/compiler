// The legal neighbour of spawnNamedClosureRejects.ms: a const-bound closure whose captures are only
// read, spawned by name or called from an inline thunk, with the parent changing nothing it captures
// until the await that joins the task. Reads through an alias, a loop binding, a Readonly callee or a
// copy, and a write under a Locked cell, are not writes to the captured graph. A const bound to such a
// closure, one hop or two, is the closure and is accepted the same way; so is a const bound to a read-only
// function declaration, spawned or handed to a Locked callback.
//
// GUARD-JS

class Child { v: int32; constructor(v: int32) { this.v = v; } }
class Holder {
	child: Child;
	constructor(c: Child) { this.child = c; }
	peek(): int32 { return this.child.v; }
}

function look(h: Readonly<Holder>): int32 { return h.child.v; }

async function byName(): Promise<int32> {
	const ring = new Holder(new Child(3));
	const cut = (): int32 => ring.child.v * 2;
	const f = spawn(cut);
	const seen = ring.child.v;
	const r = await f;
	ring.child = new Child(r + seen);
	return ring.child.v;
}

async function calledFromThunk(): Promise<int32> {
	const ring = new Holder(new Child(4));
	const cut = (): int32 => ring.child.v + 1;
	const r = await spawn((): int32 => cut());
	ring.child = new Child(r);
	return ring.child.v;
}

async function readOnlyAlias(): Promise<int32> {
	const ring = new Holder(new Child(5));
	const view = ring;
	const cut = (): int32 => { const again = view; return again.child.v + 1; };
	const r = await spawn(cut);
	ring.child = new Child(r);
	return ring.child.v;
}

async function readOnlyLoop(): Promise<int32> {
	const items: Holder[] = [new Holder(new Child(1)), new Holder(new Child(2))];
	const cut = (): int32 => {
		let sum: int32 = 0;
		for (const item of items) { sum += item.child.v; }
		return sum;
	};
	const r = await spawn(cut);
	items[0].child = new Child(r);
	return items[0].child.v + 1;
}

async function readOnlyCallees(apply: Sendable<(h: Readonly<Holder>) => int32>): Promise<int32> {
	const ring = new Holder(new Child(1));
	const cut = (): int32 => apply(ring) + look(ring) + ring.peek();
	const r = await spawn(cut);
	ring.child = new Child(r);
	return ring.child.v;
}

struct Hits { n: int32; }
async function lockedPayload(): Promise<int32> {
	const cell = new Locked<Hits>({ n: 0 });
	const cut = (): int32 => {
		lockedUpdate(cell, (h: Hits): Hits => { return { n: h.n + 1 }; });
		return 0;
	};
	const done = await spawn(cut);
	return lockedRead(cell, (h: Hits): int32 => h.n) + done;
}

struct Pt { x: int32; y: int32; }
interface Spot { pos: Pt; }
async function valueCopy(): Promise<int32> {
	const spot: Spot = { pos: { x: 1, y: 2 } };
	const cut = (): int32 => { let p = spot.pos; p.x = 5; return p.x; };
	return await spawn(cut);
}

async function readOnlyAlias2(): Promise<int32> {
	const ring = new Holder(new Child(6));
	const cut = (): int32 => ring.child.v + 1;
	const g = cut;
	const r = await spawn(g);
	ring.child = new Child(r);
	return ring.child.v;
}

async function twoHopAlias(): Promise<int32> {
	const ring = new Holder(new Child(7));
	const cut = (): int32 => ring.child.v + 1;
	const g = cut;
	const h = g;
	const r = await spawn(h);
	ring.child = new Child(r);
	return ring.child.v;
}

async function aliasCalledFromThunk(): Promise<int32> {
	const ring = new Holder(new Child(8));
	const cut = (): int32 => ring.child.v + 1;
	const g = cut;
	const r = await spawn((): int32 => g());
	ring.child = new Child(r);
	return ring.child.v;
}

const stamp = 5;
function stampPlus(): int32 { return stamp + 1; }
function lockedBump(v: int32): int32 { return v + stamp; }

async function declAlias(): Promise<int32> {
	const g = stampPlus;
	return await spawn(g);
}

async function lockedDeclAlias(): Promise<int32> {
	const cell = new Locked<int32>(1);
	const g = lockedBump;
	lockedUpdate(cell, g);
	return lockedRead(cell, (v: int32): int32 => v);
}

async function lockedClosureAlias(): Promise<int32> {
	const cell = new Locked<int32>(2);
	const bump = (v: int32): int32 => v + 3;
	const g = bump;
	const h = g;
	lockedUpdate(cell, h);
	return lockedRead(cell, (v: int32): int32 => v);
}

const r = await byName() + await calledFromThunk() + await readOnlyAlias() + await readOnlyLoop() + await lockedPayload() + await valueCopy() + await readOnlyCallees(look) + await readOnlyAlias2() + await twoHopAlias() + await aliasCalledFromThunk() + await declAlias() + await lockedDeclAlias() + await lockedClosureAlias();
if (r == 14 + 6 + 4 + 1 + 5 + 3 + 7 + 8 + 9 + 6 + 6 + 5) console.log("GUARD-OK");
else console.log(`unexpected r=${r}`);
