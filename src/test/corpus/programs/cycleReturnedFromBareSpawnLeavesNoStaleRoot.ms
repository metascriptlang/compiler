// @xfail(raiser): the Raiser VM refuses spawn of a bare function (inbox 2026-09-19-raiser-spawn-named-function) and has no per-thread cycle root sets, which this program pins
// @stdout: moved 64
// @stdout: churn 1024
// @serial
// note: `spawn(f)` with a bare function reference returns a ring; the awaiting thread frees it. No thread may keep a root that points at a cell another thread freed.

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

function ringOnWorker(): Node {
	const made = churn(64);
	const ring = makeRing(64);
	ring.payload = `${made}`;
	return ring;
}

async function dropOnWorker(n: int32): Promise<int32> {
	const f = spawn(ringOnWorker);
	const s = spin(200000);
	const ring = await f;
	const made = ring.payload.parseInt() as int32 + s * 0;
	ring.next = null;
	return made / 16 + n - n;
}

console.log(`armed ${await spawn(() => spin(10))}`);
let moved = 0;
let churned = 0;
for (let round = 0; round < 8; round += 1) {
	moved += await dropOnWorker(64);
	churned += churn(64);
}
console.log(`moved ${moved}`);
console.log(`churn ${churned}`);
