// nim-guard: spawn { move } — a value built by a routine with no side effect
//   stays fresh and moves.
//
// INVARIANT (isolation check, callee purity): the callee check refuses only a
//   routine that touches mutable or ref-holding module state or calls an
//   external or unknown function. A pure factory, a recursive pure factory, a
//   constructor that only sets its fields, a subclass of such a class, a
//   factory that reads a const scalar, and a pure method on the owner keep
//   their moves.
//
// WHAT IT CATCHES: the callee check refusing a pure routine, which would make
//   `{ move }` unusable for values built by ordinary factories.
//
// RED MEANS: a pure shape below is refused (check error), or the moved value
//   carries the wrong contents.
//
// GUARD-JS

interface Counter { n: int32; }
interface Chain { n: int32; next: Chain | null; }

const START: int32 = 3;

function makeCounter(n: int32): Counter {
	return { n: n + START };
}

function makeChain(depth: int32): Chain {
	return { n: depth, next: depth > 0 ? makeChain(depth - 1) : null };
}

class Cell {
	n: int32 = 1;
	constructor(n: int32) { this.n = n; }
	bump(): void { this.n = this.n + 1; }
}

class TaggedCell extends Cell {
	tag: string = "t";
	constructor(n: int32) { super(n * 2); }
}

async function fromFactory(): Promise<int32> {
	const c = makeCounter(1);
	return await spawn(() => { c.n = c.n + 1; return c.n; }, { move: [c] });
}

async function fromRecursiveFactory(): Promise<int32> {
	const c = makeChain(3);
	return await spawn(() => { let s = 0; let p: Chain | null = c; while (p != null) { s += p.n; p = p.next; } return s; }, { move: [c] });
}

async function fromConstructor(): Promise<int32> {
	const c = new TaggedCell(5);
	c.bump();
	return await spawn(() => { c.n = c.n + 1; return c.n; }, { move: [c] });
}

async function main(): Promise<int32> {
	const a = await fromFactory();
	const b = await fromRecursiveFactory();
	const d = await fromConstructor();
	if (a != 5) { throw "GUARD RED: fromFactory"; }
	if (b != 6) { throw "GUARD RED: fromRecursiveFactory"; }
	if (d != 12) { throw "GUARD RED: fromConstructor"; }
	console.log("GUARD-OK");
	return 0;
}
await main();
