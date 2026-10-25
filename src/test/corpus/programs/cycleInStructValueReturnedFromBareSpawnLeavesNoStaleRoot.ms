// @xfail(raiser): the Raiser VM refuses spawn of a bare function (inbox 2026-09-19-raiser-spawn-named-function) and has no per-thread cycle root sets, which this program pins
// @stdout: moved 64
// @stdout: churn 1024
// @serial
// note: a function spawned by bare reference builds a ring and returns it in a value struct; the awaiter cuts the ring while the main thread keeps building and dropping rings. No thread may keep a root that points at a cell another thread freed.

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
struct Wrap { ring: Node; tag: int32; }

function wrapOnWorker(): Wrap {
	const made = churn(64);
	return { ring: makeRing(64), tag: made / 16 };
}

async function dropOnWorker(n: int32): Promise<int32> {
	const f = spawn(wrapOnWorker);
	const s = spin(200000);
	const w = await f;
	w.ring.next = null;
	return w.tag + s * 0 + n - 64;
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
