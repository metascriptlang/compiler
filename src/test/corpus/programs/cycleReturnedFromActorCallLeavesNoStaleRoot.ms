// @stdout: moved 64
// @stdout: churn 1024
// @xfail(raiser): the Raiser VM has no actors: stdout empty, exit 1
// @serial
// note: an actor method builds a ring on the actor and returns it bare through the CALL reply; the caller cuts the ring. No thread may keep a root that points at a cell another thread freed.

import { stop, ExitReason } from "std/actor";

class Node {
	next: Node | null = null;
	payload: string;
	constructor(payload: string) { this.payload = payload; }
}

function makeRing(n: int32): Node {
	const head = new Node("n0");
	let prev = head;
	for (let i = 1; i < n; i += 1) {
		const node = new Node(`n${i}`);
		prev.next = node;
		prev = node;
	}
	prev.next = head;
	return head;
}

function spin(n: int32): int32 {
	let s: int32 = 0;
	for (let i: int32 = 0; i < n; i += 1) s = (s + i) % 1000;
	return s;
}

function churn(rounds: int32): int32 {
	let made = 0;
	for (let r = 0; r < rounds; r += 1) {
		const ring = makeRing(8);
		made += ring.payload.length;
	}
	return made;
}
class Holder {
	ring: Node;
	constructor(ring: Node) { this.ring = ring; }
}

actor Maker {
	made: int32 = 0;
	make(n: int32): Node {
		this.made += churn(64);
		return makeRing(n);
	}
}

async function dropFromActor(k: Maker): Promise<int32> {
	const r = await k.make(64);
	r.next = null;
	return 8;
}

async function main(): Promise<void> {
	const k = new Maker();
	let moved = 0;
	let churned = 0;
	for (let round = 0; round < 8; round += 1) {
		moved += await dropFromActor(k);
		churned += churn(64);
	}
	console.log(`moved ${moved}`);
	stop(k.pid, ExitReason.Normal);
	console.log(`churn ${churned}`);
}

await main();
