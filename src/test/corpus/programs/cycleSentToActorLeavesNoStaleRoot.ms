// @skip-js: a sync function awaits here, which the JS backend refuses (no blocking wait on JS, checker/syncAwait.ms); the program pins the native sync-context await
// @xfail(raiser): raiser runtime error: cannot compile 'new' here: no matching constructor in the Raiser function table
// @stdout: sent 512
// @stdout: churn 1024
// @serial
// note: a ring built on the main thread is sent to an actor and freed there; the main thread then keeps building and dropping rings. No thread may keep a root that points at a cell another thread freed.

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

function churn(rounds: int32): int32 {
	let made = 0;
	for (let r = 0; r < rounds; r += 1) {
		const ring = makeRing(8);
		made += ring.payload.length;
	}
	return made;
}

actor Sink {
	seen: int32 = 0;
	take(ring: Node): void {
		ring.next = null;
		this.seen = this.seen + 64;
	}
	get(): int32 { return this.seen; }
}

function main(): void {
	const s = new Sink();
	let churned = 0;
	for (let round = 0; round < 8; round += 1) {
		const ring = makeRing(64);
		s.take(move ring);
		const seen = await s.get();
		churned += churn(64) + seen * 0;
	}
	console.log(`sent ${await s.get()}`);
	console.log(`churn ${churned}`);
}
main();
