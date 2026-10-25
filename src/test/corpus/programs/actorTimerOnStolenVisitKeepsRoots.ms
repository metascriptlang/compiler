// @xfail(raiser): the Raiser VM has no actors: stdout empty, exit 1
// @stdout: steps 800
// @serial
// note: four actors each run an interval that replaces their ring, while every round spawns a
// busy task so idle workers steal the actors between visits. The tick is an actor job, so the
// rings it builds land in the actor's cycle roots whichever thread runs it; under SAN a ring
// built in the arming thread's roots stops with "M1 owner violation".
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
	steps: int32 = 0;
	id: number = 0;
	constructor() { this.head = new Node(0); }
	arm(): int32 {
		this.id = setInterval(() => { this.head = makeRing(8); }, 1);
		return 1;
	}
	step(): void {
		this.head = makeRing(4);
		this.steps = this.steps + 1;
	}
	finish(): int32 {
		clearInterval(this.id);
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
	for (let i = 0; i < 4; i += 1) actors.push(new Spinner());
	for (const a of actors) await a.arm();
	let w = 0;
	for (let r = 0; r < 200; r += 1) {
		const f = spawn(() => spin(20000));
		for (const a of actors) a.step();
		w = w + await f;
	}
	let total = 0;
	for (const a of actors) total = total + await a.finish();
	for (const a of actors) stop(a.pid, ExitReason.Normal);
	console.log(`steps ${total + w * 0}`);
}
main();
