// The legal neighbours of actorModuleStateReachRefused.ms: an immortal module const lent to an actor
// call and kept by an actor field, directly and through a local; a value built here, lent or stored;
// a scalar read of mutable module state stored or written into a fresh value; module state pushed into
// a lent value after its await, when no task reads it any more, directly and through a local bound
// before the lend; a value only read against module state by a callee that writes nothing; two
// values a reading method was called on, one written while the other is lent. The Arc neighbour is
// actorModuleStateArcAccepts.ms (C only: Arc<T> has no JS).
//
// INVARIANT (ULTRALOCK V0, V1): an immortal const is a SHARE, a scalar is a COPY and a fresh value
//   reaches no module state, so none of them is refused at the crossing.
//
// RED MEANS: the module-state reach check refuses a value that cannot race.
//
// GUARD-JS

class Node { next: Node | null = null; v: int32 = 1; }
const EMPTY: Readonly<Node> = new Node();
let COUNTER: int32 = 3;
const SHARED = new Node();

actor Reader {
	look(h: Readonly<Node>): int32 { return h.v; }
	take(h: Node): int32 { return h.v; }
}

actor Holder {
	head: Readonly<Node> = EMPTY;
	n: int32 = COUNTER;
	fresh: Node = new Node();
	other: Readonly<Node>;
	constructor() {
		const e = EMPTY;
		this.other = e;
		const f = new Node();
		f.v = COUNTER;
		this.fresh = f;
	}
	read(): int32 { return this.head.v + this.n + this.fresh.v + this.other.v; }
}

async function storeAfterJoin(): Promise<int32> {
	const kept: Node[] = [new Node()];
	const t = await spawn(() => kept[0].v);
	kept.push(SHARED);
	return t + kept.length;
}

async function storeLocalAfterJoin(): Promise<int32> {
	const n = SHARED;
	const kept: Node[] = [new Node()];
	const t = await spawn(() => kept[0].v);
	kept.push(n);
	return t + kept.length;
}

async function onlyCompared(): Promise<int32> {
	const seen: Node[] = [new Node()];
	if (seen.includes(SHARED)) return 0;
	return await spawn(() => seen.length);
}

class Pt { x: int32 = 0; dist(o: Readonly<Pt>): int32 { return this.x - o.x; } }
async function readerLeavesApart(): Promise<int32> {
	const a = new Pt();
	const b = new Pt();
	const d = b.dist(a);
	const t = spawn(() => a.x);
	b.x = 2;
	return d + b.x + await t;
}

async function main(): Promise<void> {
	const k = await storeLocalAfterJoin() + await onlyCompared() + await readerLeavesApart();
	const j = await storeAfterJoin();
	const r = new Reader();
	const a = await r.look(EMPTY);
	const e = EMPTY;
	const b = await r.look(e);
	const f = new Node();
	f.v = COUNTER;
	const c = await r.take(f);
	const h = await new Holder().read();
	console.log(`a=${a} b=${b} c=${c} h=${h} j=${j} k=${k}`);
	if (a == 1 && b == 1 && c == 3 && h == 8 && j == 3 && k == 6) console.log("GUARD-OK");
}

await main();
