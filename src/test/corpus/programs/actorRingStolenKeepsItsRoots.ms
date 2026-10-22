// @xfail(raiser): the Raiser VM has no actors: stdout empty, exit 1
// @stdout: steps 320000
// @serial
// note: eight actors each hold a 64-node ring and build garbage rings in every visit, while each
// round spawns a busy task so idle workers steal the actors between visits. An actor's ring stays
// in the actor's cycle roots whichever thread runs the visit; under SAN a root touched from the
// wrong root set stops with "M1 owner violation".
import { stop, ExitReason } from "std/actor";

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
		this.head = makeRing(64);
		this.steps = 0;
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
	for (const a of actors) stop(a.pid, ExitReason.Normal);
	console.log(`steps ${sum + w * 0}`);
}
main();
