// @stdout: taken 128
// @serial
// note: two workers of one spawn group each return a ring in a value struct; the awaiting thread frees both. No thread may keep a root that points at a cell another thread freed.

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

struct Wrap { ring: Node; tag: int32; }

function churnThenWrap(n: int32): Wrap {
	const rings: Node[] = [];
	for (let r = 0; r < 64; r += 1) rings.push(makeRing(8));
	for (const ring of rings) ring.next = null;
	return { ring: makeRing(n), tag: 1 };
}

async function main(): Promise<void> {
	let taken = 0;
	for (let round = 0; round < 32; round += 1) {
		const rs = await Promise.all([spawn(() => churnThenWrap(64)), spawn(() => churnThenWrap(64))]);
		for (const w of rs) {
			taken += w.ring.payload.length * w.tag;
			w.ring.next = null;
		}
	}
	console.log(`taken ${taken}`);
}
await main();
