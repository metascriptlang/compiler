// @stdout: moved 64
// @stdout: churn 1024
// @serial
// note: a worker returns an array of rings; the awaiting thread frees them. No thread may keep a root that points at a cell another thread freed.

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

function ringsOnWorker(n: int32): Node[] {
	const made = churn(64);
	const rings: Node[] = [makeRing(n), makeRing(n)];
	rings[0].payload = `${made}`;
	return rings;
}

async function dropOnWorker(n: int32): Promise<int32> {
	const f = spawn(() => ringsOnWorker(n));
	const s = spin(200000);
	const rings = await f;
	const made = rings[0].payload.parseInt() as int32 + s * 0;
	for (const r of rings) r.next = null;
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
