// guard: a cycle among the implementers of an interface is collected when only the interface slot held it
//
// INVARIANT (reference types.nim canFormAcycleAux, the non-final rule: a cell reached through an open
//   type can form a cycle): a cell typed by an interface is a cell of one of the types the checker
//   accepted behind it, so the interface can form a cycle whenever one of them can, even when no path
//   returns to the interface. The slot drops its cell through the cyclic decref, which registers the
//   ring as a candidate root, and the collector frees it.
//   Axes: a plain interface (RingNode) and a generic interface instance (GenNode, GenHolder) whose
//   implementers close a cycle through it.
//
// CONTROL: none inline; the same ring held through a `RingNode` field balances on every compiler.
//
// RED MEANS: an interface was classified acyclic although an implementer can form a cycle (RingNode
//   leaks), or a generic interface stopped noting the types assigned to it (GenNode/GenHolder leak).
//   Run /trace-ref on canFormAcycle and noteHeldBeyond.
// GUARD-BALANCE RingNode
// GUARD-BALANCE GenNode
// GUARD-BALANCE GenHolder

interface Box { v: number }
class RingNode { v: number = 1; next: RingNode | null = null; }
class RingHolder { v: number = 2; b: Box | null = null; }

function makeRing(n: int32): RingNode {
	const head = new RingNode();
	let prev = head;
	for (let i: int32 = 1; i < n; i += 1) {
		const node = new RingNode();
		prev.next = node;
		prev = node;
	}
	prev.next = head;
	return head;
}

function churn(rounds: int32): number {
	let made: number = 0;
	for (let r: int32 = 0; r < rounds; r += 1) {
		const ring = makeRing(8);
		made += ring.v;
	}
	return made;
}

interface GBox<T> { v: T }
class GenNode { v: number = 1; back: GBox<number> | null = null; }
class GenHolder { v: number = 2; b: GBox<number> | null = null; }

function link(): number {
	const n = new GenNode();
	const h = new GenHolder();
	n.back = h;
	h.b = n;
	return n.v + h.v;
}

let t: number = 0;
for (let k: int32 = 0; k < 10; k += 1) {
	const h = new RingHolder();
	h.b = makeRing(16);
	t += churn(200);
	h.b = null;
	t += churn(200);
}
for (let i: int32 = 0; i < 1000; i += 1) t += link();
console.log("done", t);
