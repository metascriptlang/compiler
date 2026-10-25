// @stdout: moved 512
// @stdout: churn 1024
// @serial
// note: a holder whose value struct field holds a second holder of a ring, none of which can form a cycle, is moved into a spawn and cuts the ring there; the main thread then keeps building and dropping rings. No thread may keep a root that points at a cell another thread freed.

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

struct Slot { holder: Holder; tag: int32; }

class Outer {
	slot: Slot;
	constructor(slot: Slot) { this.slot = slot; }
}

async function dropOnWorker(n: int32): Promise<int32> {
	const outer = new Outer({ holder: new Holder(makeRing(n)), tag: 1 });
	const f = spawn(() => {
		outer.slot.holder.ring.next = null;
		return n;
	}, { move: [outer] });
	const s = spin(1000000);
	return await f + s * 0;
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
