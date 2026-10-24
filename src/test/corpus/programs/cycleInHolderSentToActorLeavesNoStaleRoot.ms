// @xfail(raiser): the Raiser VM has no actors and no per-thread cycle root sets, which this program pins
// @skip-js: a sync function awaits here, which the JS backend refuses (no blocking wait on JS, checker/syncAwait.ms); the program pins the native sync-context await
// @stdout: moved 512
// @stdout: churn 1024
// @serial
// @ledger-slack(Sink) 1
// ledger-slack reason: its actors are never stopped, so they and what they own are still live at exit
// note: an acyclic holder whose field is a ring is sent to an actor and its ring freed there; the main thread then keeps building and dropping rings. No thread may keep a root that points at a cell another thread freed.

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

actor Sink {
	seen: int32 = 0;
	take(holder: Holder): void {
		holder.ring.next = null;
		this.seen = this.seen + 64;
	}
	get(): int32 { return this.seen; }
}

function main(): void {
	const s = new Sink();
	let churned = 0;
	for (let round = 0; round < 8; round += 1) {
		const holder = new Holder(makeRing(64));
		s.take(move holder);
		const seen = await s.get();
		churned += churn(64) + seen * 0;
	}
	console.log(`moved ${await s.get()}`);
	console.log(`churn ${churned}`);
}
main();
