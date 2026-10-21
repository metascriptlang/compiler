// guard: an actor's cycle roots follow it across threads — cells built inside a visit
//
// INVARIANT (ULTRALOCK M1): an actor's root set is swapped in at the start of each visit
//   and out at its end, so a ring built in one visit on one thread is still the actor's
//   when an idle worker steals the actor for the next visit.
// RED MEANS: visit roots landed in the visiting thread's set (10/10 runs crash on
//   5b339faeb, 0/10 with the per-actor root set).

class Node {
	next: Node | null = null;
	tag: int32;
	constructor(tag: int32) { this.tag = tag; }
}

function makeRing(n: int32): Node {
	const head = new Node(0);
	let prev = head;
	for (let i: int32 = 1; i < n; i += 1) {
		const node = new Node(i);
		prev.next = node;
		prev = node;
	}
	prev.next = head;
	return head;
}

actor Spinner {
	head: Node;
	steps: int32;
	constructor() {
		this.head = new Node(0);
		this.steps = 0;
	}
	build(): void {
		this.head = makeRing(64);
	}
	step(): void {
		const n = this.head.next;
		if (n != null) this.head = n;
		const junk = makeRing(4);
		this.steps = this.steps + junk.tag + 1;
	}
	total(): int32 {
		return this.steps;
	}
}

function spin(n: int32): int32 {
	let s: int32 = 0;
	for (let i: int32 = 0; i < n; i += 1) s = (s + i) % 1000;
	return s;
}

async function main(): Promise<void> {
	const actors: Spinner[] = [];
	for (let i = 0; i < 8; i += 1) actors.push(new Spinner());
	for (const a of actors) a.build();
	let w = 0;
	for (let r = 0; r < 200; r += 1) {
		const f = spawn(() => spin(20000));
		for (let i = 0; i < 200; i += 1) {
			for (const a of actors) a.step();
		}
		w += await f;
	}
	let sum = 0;
	for (const a of actors) sum += await a.total();
	console.log(`steps ${sum + w * 0}`);
}
await main();
console.log("GUARD-OK");
