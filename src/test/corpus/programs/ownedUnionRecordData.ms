// note: a class whose data is an Owned union of records holding its children, written through an alias declared before or after the class, builds and walks a tree, reads a nullable owned union and an owned tuple as plain values; the whole tree is out of the collector (pinned in src/test/c/ownedEdge.ms).
// @stdout: before 15
// @stdout: after 27
// @stdout: pair 7 3
type D = { l: Owned<N>, r: Owned<N> } | { x: int32 };
class N {
	k: int32 = 0;
	isPair: boolean = false;
	data: Owned<D> = { x: 0 };
	constructor(k: int32) { this.k = k; }
}

class M {
	k: int32 = 0;
	data: Owned<E> | null = null;
	constructor(k: int32) { this.k = k; }
}
type E = { l: Owned<M>, r: Owned<M> } | { x: int32 };

function leaf(k: int32): Owned<N> {
	const n: Owned<N> = new N(k);
	n.data = { x: k };
	return move n;
}

function pair(k: int32, sink l: Owned<N>, sink r: Owned<N>): Owned<N> {
	const n: Owned<N> = new N(k);
	n.isPair = true;
	n.data = { l: move l, r: move r };
	return move n;
}

function sum(n: N): int32 {
	if (n.isPair) {
		const d: { l: Owned<N>, r: Owned<N> } = n.data as { l: Owned<N>, r: Owned<N> };
		return n.k + sum(d.l) + sum(d.r);
	}
	return n.k + (n.data as { x: int32 }).x;
}

function mleaf(k: int32): Owned<M> {
	const m: Owned<M> = new M(k);
	m.data = { x: k };
	return move m;
}

function msum(m: M): int32 {
	const d: E | null = m.data;
	if (d == null) return m.k;
	if ("l" in d) return m.k + msum(d.l) + msum(d.r);
	return m.k + d.x;
}

const t = pair(1, leaf(3), leaf(4));
console.log("before " + sum(t));
function mpair(k: int32, sink l: Owned<M>, sink r: Owned<M>): Owned<M> {
	const m: Owned<M> = new M(k);
	m.data = { l: move l, r: move r };
	return move m;
}

console.log("after " + msum(mpair(2, mpair(1, mleaf(3), mleaf(4)), mleaf(5))));

function firstOf(sink kid: Owned<N>, k: int32): int32 {
	const owned: [Owned<N> | null, int32] = [move kid, k];
	const plain: [N | null, int32] = owned;
	const n = plain[0];
	return n == null ? -1 : n.k;
}
console.log("pair " + firstOf(leaf(7), 3) + " " + 3);
