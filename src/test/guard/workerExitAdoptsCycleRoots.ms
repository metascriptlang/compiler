// guard: a cycle a pool worker dropped is collected after the worker exits
//
// INVARIANT (ULTRALOCK M1; RT-8): a cell whose last outside reference a pool worker dropped
//   sits in that worker's root set. When the worker exits, its root entries pass to the next
//   collection on a live thread instead of being freed with the thread, so the program's final
//   collection reclaims every such ring. Axes: a ring built and dropped inside the task, its
//   handles joined by Promise.all, and a ring moved into a held handle that the task drops
//   before its await returns (T4).
//
// RED MEANS: a worker's root set was discarded at thread exit, so each ring a worker dropped
//   leaks (a BuiltRing or MovedRing imbalance at exit).
//
// GUARD-BALANCE BuiltRing
// GUARD-BALANCE MovedRing

class BuiltRing {
	next: BuiltRing | null = null;
	tag: int32;
	constructor(tag: int32) { this.tag = tag; }
}

class MovedRing {
	next: MovedRing | null = null;
	tag: int32;
	constructor(tag: int32) { this.tag = tag; }
}

const TASKS: int32 = 32;

function pace(): int32 {
	const until = Date.now() + 5;
	let n: int32 = 0;
	while (Date.now() < until) n = (n + 1) % 1000;
	return n * 0;
}

function built(tag: int32): int32 {
	const a = new BuiltRing(tag);
	const b = new BuiltRing(tag);
	a.next = b;
	b.next = a;
	return a.tag + pace();
}

function movedRing(tag: int32): MovedRing {
	const a = new MovedRing(tag);
	const b = new MovedRing(tag);
	a.next = b;
	b.next = a;
	return a;
}

function read(r: MovedRing): int32 { return r.tag + pace(); }

async function joinBuilt(): Promise<int32> {
	const hs: Promise<int32>[] = [];
	for (let k: int32 = 0; k < TASKS; k += 1) {
		const tag = k;
		hs.push(spawn(() => built(tag)));
	}
	const rs = await Promise.all(hs);
	let t: int32 = 0;
	for (const r of rs) t = t + r;
	return t;
}

function joinMoved(): int32 {
	const hs: Promise<int32>[] = [];
	for (let k: int32 = 0; k < TASKS; k += 1) {
		const r = movedRing(k);
		hs.push(spawn(() => read(r), { move: [r] }));
	}
	let t: int32 = 0;
	for (const h of hs) t = t + await h;
	return t;
}

async function main(): Promise<void> {
	const want: int32 = TASKS * (TASKS - 1) / 2;
	const b = await joinBuilt();
	const m = joinMoved();
	if (b == want && m == want) console.log("GUARD-OK");
	else {
		console.log(`built=${b} moved=${m} want ${want}`);
		process.exit(1);
	}
}

main();
