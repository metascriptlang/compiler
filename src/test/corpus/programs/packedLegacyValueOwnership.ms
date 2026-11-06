// @stdout: local closure 45
// @stdout: borrowed place 37
// @stdout: nullable closure 13
// @stdout: checked projection 67
// @stdout: borrowed projection 89
// @stdout: distinct projection 67
// @stdout: distinct snapshot 23
// @stdout: packed element copy 23 23 45 9 9
// @stdout: closure argument 23 23
// @stdout: raising closure argument caught 2
// @stdout: kept closure argument 23 23 9
// @stdout: method argument snapshot 23 0
// @stdout: sink argument 23 9
struct Pair { x: int64; y: int64; }
type OtherPair = distinct Pair;

@noinline function make(n: int64): Pair { return { x: n, y: n + 1 }; }

@noinline function fromClosure(): int64 {
	const f = make;
	const p = f(4);
	return p.x * 10 + p.y;
}

@noinline function fromLegacyPlace(): int64 {
	const xs: Pair[] = [{ x: 3, y: 7 }];
	const p = xs[0];
	return p.x * 10 + xs[0].y;
}

@noinline function flag(n: int64): boolean | null { return n == 0 ? null : false; }

@noinline function fromNullableClosure(): int64 {
	const f = flag;
	const absent = f(0);
	const present = f(1);
	return (absent == null ? 10 : 0) + (present != null ? 3 : 0) + ((present ?? true) ? 1 : 0);
}

@noinline function maybePair(n: int64): Pair | null { return n == 0 ? null : make(n); }

@noinline function fromCheckedProjection(): int64 {
	const p = maybePair(6) as Pair;
	return p.x * 10 + p.y;
}

@noinline function fromBorrowedProjection(): int64 {
	const xs: (Pair | null)[] = [make(8)];
	const p = xs[0] as Pair;
	const saved = xs[0] as Pair;
	return p.x * 10 + saved.y;
}

@noinline function scoreDistinct(p: OtherPair): int64 {
	const value = p as Pair;
	return value.x * 10 + value.y;
}

@noinline function fromDistinctProjection(): int64 {
	const p = maybePair(6) as OtherPair;
	return scoreDistinct(p);
}

@noinline function fromDistinctSnapshot(): int64 {
	let original: Pair = { x: 2, y: 3 };
	const snapshot = original as OtherPair;
	original.x = 9;
	return scoreDistinct(snapshot);
}

struct Holder { pair: Pair; }

@noinline function packedElementCopy(): string {
	let p: Pair = { x: 2, y: 3 };
	const xs: Pair[] = [{ x: 0, y: 0 }, { x: 6, y: 7 }];
	xs[0] = p;
	const snapshot = xs[0];
	p.x = 9;
	xs[1] = xs[0];
	xs[0].y = 8;
	let h: Holder = { pair: { x: 4, y: 5 } };
	xs[0] = h.pair;
	h.pair.x = 9;
	return `${snapshot.x * 10 + snapshot.y} ${xs[1].x * 10 + xs[1].y} ${xs[0].x * 10 + xs[0].y} ${p.x} ${h.pair.x}`;
}

class Keeper {
	pair: Pair = { x: 2, y: 3 };
	take(q: Pair): int64 { this.pair = { x: 0, y: 0 }; return q.x * 10 + q.y; }
}

@noinline function closureArgument(): string {
	const p: Pair = { x: 2, y: 3 };
	const f = (q: Pair): int64 => q.x * 10 + q.y;
	return `${f(p)} ${f({ x: 2, y: 3 })}`;
}

@noinline function raisingClosureArgument(): string {
	const p: Pair = { x: 2, y: 3 };
	const f = (q: Pair): int64 => { if (q.x > 0) throw new Error("raised"); return q.x; };
	let seen = "";
	try { f(p); } catch (e) { seen = "caught"; }
	return `${seen} ${p.x}`;
}

@noinline function keptClosureArgument(): string {
	const kept: Pair[] = [];
	let p: Pair = { x: 2, y: 3 };
	const f = (q: Pair): int64 => { kept.push(q); return q.x * 10 + q.y; };
	const n = f(p);
	p.x = 9;
	return `${n} ${kept[0].x * 10 + kept[0].y} ${p.x}`;
}

@noinline function methodArgumentSnapshot(): string {
	const k = new Keeper();
	return `${k.take(k.pair)} ${k.pair.x}`;
}

@noinline function sinkArgument(): string {
	const xs: Pair[] = [];
	let p: Pair = { x: 2, y: 3 };
	xs.push(p);
	p.x = 9;
	return `${xs[0].x * 10 + xs[0].y} ${p.x}`;
}

console.log(`local closure ${fromClosure()}`);
console.log(`borrowed place ${fromLegacyPlace()}`);
console.log(`nullable closure ${fromNullableClosure()}`);
console.log(`checked projection ${fromCheckedProjection()}`);
console.log(`borrowed projection ${fromBorrowedProjection()}`);
console.log(`distinct projection ${fromDistinctProjection()}`);
console.log(`distinct snapshot ${fromDistinctSnapshot()}`);
console.log(`packed element copy ${packedElementCopy()}`);
console.log(`closure argument ${closureArgument()}`);
console.log(`raising closure argument ${raisingClosureArgument()}`);
console.log(`kept closure argument ${keptClosureArgument()}`);
console.log(`method argument snapshot ${methodArgumentSnapshot()}`);
console.log(`sink argument ${sinkArgument()}`);
