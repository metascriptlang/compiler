// @stdout: taken 4096
// @serial
// note: a worker builds a ring and returns it; the awaiting thread frees it. No thread may keep a root that points at a cell another thread freed.

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
	const rings: Node[] = [];
	for (let r = 0; r < rounds; r += 1) rings.push(makeRing(8));
	let made = 0;
	for (const ring of rings) {
		made += ring.payload.length;
		ring.next = null;
	}
	return made;
}

function churnThenRing(n: int32): Node {
	const made = churn(64);
	const ring = makeRing(n);
	ring.payload = `${made}`;
	return ring;
}

function spin(n: int32): int32 {
	let s: int32 = 0;
	for (let i: int32 = 0; i < n; i += 1) s = (s + i) % 1000;
	return s;
}

async function takeFromWorker(n: int32): Promise<int32> {
	const f = spawn(() => churnThenRing(n));
	const s = spin(200000);
	const ring = await f;
	const made = ring.payload.parseInt() as int32 + s * 0;
	ring.next = null;
	return made;
}

let taken = 0;
for (let round = 0; round < 32; round += 1) {
	taken += await takeFromWorker(64);
}
console.log(`taken ${taken}`);
