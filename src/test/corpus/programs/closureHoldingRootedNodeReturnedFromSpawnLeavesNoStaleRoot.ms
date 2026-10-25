// @stdout: read 4096
// @stdout: swept 558080
// @serial
// note: a worker builds a chain, makes its head a cycle root candidate, and returns a read-only closure holding it; the awaiter calls the closure and frees the chain. No thread may keep a root that points at a cell another thread freed.

class Node {
	next: Node | null = null;
	payload: string;
	constructor(payload: string) { this.payload = payload; }
}

function makeChain(n: int32): Node {
	const head = new Node("n0");
	let prev = head;
	for (let i = 1; i < n; i += 1) {
		const node = new Node(`n${i}`);
		prev.next = node;
		prev = node;
	}
	return head;
}

function lengthOf(node: Node): int32 {
	return node.payload.length;
}

function reader(n: int32): Sendable<() => int32> {
	const head = makeChain(n);
	const second = head;
	lengthOf(second);
	return (): int32 => n + head.payload.length * 0;
}

function sweep(n: int32): int32 {
	const keep: Node[] = [];
	for (let i = 0; i < n; i += 1) keep.push(new Node(`k${i}`));
	let s = 0;
	for (let r = 0; r < 4; r += 1) {
		for (let i = 0; i < n; i += 1) {
			const c = keep[i];
			s += lengthOf(c);
		}
	}
	return s;
}

async function readMany(n: int32): Promise<int32> {
	const pending: Promise<Sendable<() => int32>>[] = [];
	for (let k = 0; k < 8; k += 1) pending.push(spawn(() => reader(n)));
	let sum = 0;
	for (const p of pending) {
		const read = await p;
		sum += read();
	}
	return sum;
}

let total = 0;
let swept = 0;
for (let round = 0; round < 8; round += 1) {
	total += await readMany(64);
	const sweeps: Promise<int32>[] = [];
	for (let w = 0; w < 16; w += 1) sweeps.push(spawn(() => sweep(300)));
	for (const p of sweeps) swept += await p;
}
console.log(`read ${total}`);
console.log(`swept ${swept}`);
