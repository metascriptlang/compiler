// @xfail(raiser): output differs from c: raiser runs no user lifecycle hooks (destroyed 0)
// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
// note: a tree held through Vec<Owned<N>> is acyclic, so dropping its root runs onDestroy once per node without the cycle collector; the same tree through N[] is cyclic and drops the same way.
let destroyed = 0;

class N {
	id: int32 = 0;
	kids: Vec<Owned<N>> = [];
	constructor(id: int32) { this.id = id; }
	onDestroy() { destroyed += 1; }
}

class M {
	id: int32 = 0;
	kids: M[] = [];
	constructor(id: int32) { this.id = id; }
	onDestroy() { destroyed += 1; }
}

function buildOwned(depth: int32, next: int32[]): Owned<N> {
	const n: Owned<N> = new N(next[0]);
	next[0] += 1;
	if (depth > 0) {
		for (let i = 0; i < 3; i += 1) n.kids.push(buildOwned(depth - 1, next));
	}
	return n;
}

function buildShared(depth: int32, next: int32[]): M {
	const m = new M(next[0]);
	next[0] += 1;
	if (depth > 0) {
		for (let i = 0; i < 3; i += 1) m.kids.push(buildShared(depth - 1, next));
	}
	return m;
}

function sumOwned(n: N): int32 {
	let total = n.id;
	for (let i = 0; i < n.kids.length; i += 1) total += sumOwned(n.kids[i]);
	return total;
}

function sumShared(m: M): int32 {
	let total = m.id;
	for (let i = 0; i < m.kids.length; i += 1) total += sumShared(m.kids[i]);
	return total;
}

function ownedRound(): int32 {
	const root = buildOwned(3, [0]);
	return sumOwned(root);
}

function sharedRound(): int32 {
	const root = buildShared(3, [0]);
	return sumShared(root);
}

console.log("owned sum", ownedRound(), "destroyed", destroyed);
destroyed = 0;
console.log("shared sum", sharedRound(), "destroyed", destroyed);
