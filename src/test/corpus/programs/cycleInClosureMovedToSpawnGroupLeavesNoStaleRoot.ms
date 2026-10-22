// @stdout: moved 512
// @stdout: churn 1024
// @serial
// note: two closures whose envs hold rings are moved into the slots of one spawn group, each slot returns an int32 and cuts its ring there; the main thread then keeps building and dropping rings. No thread may keep a root that points at a cell another thread freed.

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

function cutter(n: int32): () => int32 {
	const head = makeRing(n);
	return (): int32 => {
		head.next = null;
		return n;
	};
}

async function dropOnWorker(n: int32): Promise<int32> {
	const cutA = cutter(n);
	const cutB = cutter(n);
	const rs = await Promise.all([spawn(() => cutA(), { move: [cutA] }), spawn(() => cutB(), { move: [cutB] })]);
	const s = spin(1000000);
	return rs[0] + rs[1] - n + s * 0;
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
