// A closure moved into a spawn is refused when the thunk calls it
//
// INVARIANT (ULTRALOCK V0): a callee the checker cannot see counts as reaching module state, so a
//   call through a function value inside a crossing is a compile error naming the call. A closure
//   built by a factory and moved into the thunk is such a value.
//
// WHAT IT CATCHES: a factory-built closure whose env holds a holder of a ring, moved into a spawn and called there.
//
// RED MEANS: the thunk check in checkSpawnCaptures (sendable.ms) or callEffect (effects.ms) lets a
//   call through a moved function value cross.
//
// GUARD-CHECK-FAIL spawn runs this thunk on another thread, but it calls a function value at 61:27

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

function cutter(n: int32): () => int32 {
	const holder = new Holder(makeRing(n));
	return (): int32 => {
		holder.ring.next = null;
		return n;
	};
}

async function dropOnWorker(n: int32): Promise<int32> {
	const cut = cutter(n);
	const f = spawn(() => cut(), { move: [cut] });
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
