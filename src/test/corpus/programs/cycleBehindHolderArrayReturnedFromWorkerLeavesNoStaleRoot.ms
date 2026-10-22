// @stdout: moved 64
// @stdout: churn 1024
// @serial
// note: a worker builds holders of rings, none of which can form a cycle, and returns them in an array; the awaiter cuts the rings while the main thread keeps building and dropping rings. No thread may keep a root that points at a cell another thread freed.

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

function holdersOnWorker(n: int32): Holder[] {
	const made = churn(64);
	const holders: Holder[] = [new Holder(makeRing(n)), new Holder(makeRing(n))];
	holders[0].ring.payload = `${made}`;
	return holders;
}

async function dropOnWorker(n: int32): Promise<int32> {
	const f = spawn(() => holdersOnWorker(n));
	const s = spin(200000);
	const holders = await f;
	const made = holders[0].ring.payload.parseInt() as int32 + s * 0;
	for (const h of holders) h.ring.next = null;
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
