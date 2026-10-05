// @stdout: 13 79 76 64 25 40 -1 5 7 55
// note: a struct call assigned to a local, its field or its sized-array element writes that location when no argument reaches it and no handler can see a store the call leaves half done; a call whose arguments read the destination, directly, through a span over it or through a closure that captured it, still sees the old value, and a call result passed by address is read in place. Same output on every lane.
struct Quad { a: int64; b: int64; c: int64; d: int64; }
struct Box { q: Quad; arr: Quad[3]; n: int64; }
struct Named { name: string; n: int64; }

function quad(x: int64, y: int64): Quad { return { a: x, b: y, c: 0, d: 0 }; }
function swap(q: Quad): Quad { return { a: q.b, b: q.a, c: q.d, d: q.c }; }
function digits(q: Quad): int64 { return q.a * 10 + q.b; }
function checked(x: int64): Quad {
	if (x < 0) { throw new Error("negative"); }
	return { a: x, b: x, c: x, d: x };
}
function named(n: int64): Named { return { name: `n${n}`, n: n }; }

function selfSwap(): int64 {
	let q = quad(3, 1);
	q = swap(q);
	return digits(q);
}
function plain(x: int64): int64 {
	const src = quad(x, x + 2);
	let q = quad(0, 0);
	q = swap(src);
	q = swap(q);
	return digits(q);
}
function fieldTarget(x: int64): int64 {
	let b: Box = { q: quad(0, 0), arr: [quad(0, 0), quad(0, 0), quad(0, 0)], n: 7 };
	b.q = quad(x, x - 1);
	return digits(b.q);
}
function throughSpan(): int64 {
	let b: Box = { q: quad(0, 0), arr: [quad(1, 2), quad(4, 6), quad(0, 0)], n: 0 };
	const s: Span<Quad> = b.arr;
	b.arr[1] = swap(s[1]);
	return digits(b.arr[1]);
}
function captured(): int64 {
	let q = quad(5, 2);
	const read = (): Quad => q;
	q = swap(read());
	return digits(q);
}
function element(i: int32, x: int64): int64 {
	let b: Box = { q: quad(0, 0), arr: [quad(0, 0), quad(0, 0), quad(0, 0)], n: 4 };
	b.arr[i] = quad(x, 0);
	return digits(b.arr[i]);
}
function raises(n: int64): int64 {
	let q = quad(1, 1);
	q = checked(n);
	return q.a;
}
function guarded(n: int64): int64 {
	try {
		return raises(n);
	} catch (e) {
		return -1;
	}
}
function managed(): int64 {
	let s = named(1);
	s = named(s.n + 6);
	return s.n;
}
function receivers(): int64 {
	return digits(swap(quad(1, 2))) + digits(quad(3, 4)) + digits(checked(0)) + digits(swap(checked(0)));
}
console.log(`${selfSwap()} ${plain(7)} ${fieldTarget(7)} ${throughSpan()} ${captured()} ${element(2, 4)} ${guarded(-1)} ${guarded(5)} ${managed()} ${receivers()}`);
