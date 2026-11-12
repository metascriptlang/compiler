// A value that reaches module state is refused where it crosses to an actor or a task, whatever local,
// field or call carried it there.
//
// INVARIANT (ULTRALOCK V0, V4, V6): a partition reachable from module state is not lendable, and an
//   actor keeps its fields on whichever thread takes its message; a value keeps its provenance through
//   a local alias, a field store and a call result (the region of a value loaded from a global carries
//   that global's isolation through assign and merge).
//
// WHAT IT CATCHES: module state lent to an actor call through a local, through a call whose callee
//   reaches it, and through a field of a fresh object; stored by an actor's field initializer and its
//   constructor, directly and through a local; lent to a spawn through a local, through a value pushed
//   or stored into a fresh local, and through what a callee returns after pushing or assigning into it;
//   a module-level array handed to an async routine whose body lends it to a spawn.
//
// RED MEANS: main writes the module object while an actor or a task on another thread reads it
//   (TSan data race on `rprobe`-style probes: raceTid.ms, 2026-11-08).
//
// The legal neighbours are pinned by actorModuleStateReachAccepts.ms, which must build and run.
//
// GUARD-JS
// GUARD-CHECK-FAIL the actor call of 'take' lends a value that
// GUARD-CHECK-FAIL uses module-level 'SHARED'
// GUARD-CHECK-FAIL calls 'getShared'
// GUARD-CHECK-FAIL calls a function value, whose result may be module state
// GUARD-CHECK-FAIL as overridden in 'SharedSource'
// GUARD-CHECK-FAIL actor 'Holder' keeps 'head' on whichever thread takes its message
// GUARD-CHECK-FAIL actor 'Keeper' keeps 'head' on whichever thread takes its message
// GUARD-CHECK-FAIL actor 'Collector' keeps 'items' on whichever thread takes its message
// GUARD-CHECK-FAIL is lent to the spawn
// GUARD-CHECK-FAIL module state crosses threads only as a const value

class Node { next: Node | null = null; v: int32 = 1; }
const SHARED = new Node();
function getShared(): Node { return SHARED; }

class Bag { items: Node[] = []; head: Node | null = null; }
class Registry { items: Node[] = [new Node()]; exportInto(out: Node[]): void { out.push(this.items[0]); } }
const REGISTRY = new Registry();
let PICK: int32 = 1;
function bagOf(): Bag { const b = new Bag(); b.items.push(getShared()); return b; }
function reassigned(): Node { let n = new Node(); n = SHARED; return n; }
const ROW: Node[] = [new Node()];
async function sumOf(ns: Node[]): Promise<int32> {
	const jobs: Promise<int32>[] = [];
	for (const n of ns) jobs.push(spawn(() => n.v));
	let total: int32 = 0;
	for (const j of jobs) total += await j;
	return total;
}

actor Reader {
	take(h: Node): int32 { return h.v; }
}

actor Holder {
	head: Node = SHARED; // GUARD-REFUSED
	read(): int32 { return this.head.v; }
}

actor Keeper {
	head: Node;
	tail: Node;
	constructor() {
		const n = SHARED;
		this.head = n; // GUARD-REFUSED
		this.tail = getShared(); // GUARD-REFUSED
	}
	read(): int32 { return this.head.v + this.tail.v; }
}

actor Collector {
	items: Node[] = [];
	constructor() {
		this.items.push(SHARED); // GUARD-REFUSED
	}
	read(): int32 { return this.items[0].v; }
}

async function lendAlias(r: Reader): Promise<int32> {
	const n = SHARED;
	return await r.take(n); // GUARD-REFUSED
}

async function lendCall(r: Reader): Promise<int32> {
	return await r.take(getShared()); // GUARD-REFUSED
}

async function lendField(r: Reader): Promise<int32> {
	const m = new Node();
	m.next = SHARED;
	return await r.take(m); // GUARD-REFUSED
}

async function spawnAlias(): Promise<int32> {
	const n = SHARED;
	return await spawn(() => n.v); // GUARD-REFUSED
}

async function spawnPushed(): Promise<int32> {
	const b = new Bag();
	b.items.push(SHARED);
	return await spawn(() => b.items[0].v); // GUARD-REFUSED
}

async function spawnFieldStored(): Promise<int32> {
	const b = new Bag();
	b.head = SHARED;
	return await spawn(() => b.items.length); // GUARD-REFUSED
}

async function spawnCalleePushed(): Promise<int32> {
	const b = bagOf();
	return await spawn(() => b.items[0].v); // GUARD-REFUSED
}

async function lendMatch(r: Reader): Promise<int32> {
	return await r.take(match (PICK) { 1 => SHARED, _ => new Node() }); // GUARD-REFUSED
}

async function spawnMatch(): Promise<int32> {
	const n = match (PICK) { 1 => new Node(), _ => SHARED };
	return await spawn(() => n.v); // GUARD-REFUSED
}

async function spawnCalleeStoredItsReceiver(): Promise<int32> {
	const out: Node[] = [];
	REGISTRY.exportInto(out);
	return await spawn(() => out[0].v); // GUARD-REFUSED
}

async function spawnMapSet(): Promise<int32> {
	const m = new Map<string, Node>();
	m.set("a", SHARED);
	return await spawn(() => m.size); // GUARD-REFUSED
}

async function spawnSetAdd(): Promise<int32> {
	const s = new Set<Node>();
	s.add(SHARED);
	return await spawn(() => s.size); // GUARD-REFUSED
}

class Source { get(): Node { return new Node(); } }
class SharedSource extends Source { get(): Node { return SHARED; } }
async function spawnFunctionValueResult(f: () => Node): Promise<int32> {
	const n = f();
	return await spawn(() => n.v); // GUARD-REFUSED
}

async function spawnOverrideResult(s: Source): Promise<int32> {
	const n = s.get();
	return await spawn(() => n.v); // GUARD-REFUSED
}

async function spawnCalleeReassigned(): Promise<int32> {
	const n = reassigned();
	return await spawn(() => n.v); // GUARD-REFUSED
}

async function main(): Promise<void> {
	const r = new Reader();
	console.log(await spawnPushed() + await spawnFieldStored() + await spawnCalleePushed() + await spawnCalleeReassigned());
	const row = await sumOf(ROW); // GUARD-REFUSED
	console.log(row);
	console.log(await lendAlias(r) + await lendCall(r) + await lendField(r) + await spawnAlias());
	console.log(await lendMatch(r) + await spawnMatch() + await spawnCalleeStoredItsReceiver() + await spawnMapSet() + await spawnSetAdd() + await spawnFunctionValueResult(getShared) + await spawnOverrideResult(new SharedSource()));
	console.log(await new Holder().read() + await new Keeper().read() + await new Collector().read());
}

await main();
