// @stdout: local closure 45
// @stdout: borrowed place 37
// @stdout: nullable closure 13
// @stdout: checked projection 67
// @stdout: borrowed projection 89
// @stdout: distinct projection 67
// @stdout: distinct snapshot 23
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

console.log(`local closure ${fromClosure()}`);
console.log(`borrowed place ${fromLegacyPlace()}`);
console.log(`nullable closure ${fromNullableClosure()}`);
console.log(`checked projection ${fromCheckedProjection()}`);
console.log(`borrowed projection ${fromBorrowedProjection()}`);
console.log(`distinct projection ${fromDistinctProjection()}`);
console.log(`distinct snapshot ${fromDistinctSnapshot()}`);
