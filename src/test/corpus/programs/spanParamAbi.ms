// Parity program: a Span parameter crosses the C ABI as its element pointer and a length. Every function shape
// that takes one: module-local, exported, closure, function-typed value, generic, one that reassigns
// the span, one that passes it on, element types int64 and struct, empty and sliced sources.
// @stdout: 6|6|52|6|7|7|6|3|0|4|12|17
// @exit: 0
struct Pt { x: int32; y: int32; }

function localSum(xs: Span<int64>): int64 {
	let s: int64 = 0;
	for (let i = 0; i < xs.length; i += 1) s += xs[i];
	return s;
}

export function pubSum(xs: Span<int64>): int64 {
	let s: int64 = 0;
	for (let i = 0; i < xs.length; i += 1) s += xs[i];
	return s;
}

function sumX(ps: Span<Pt>): int32 {
	let s: int32 = 0;
	for (let i = 0; i < ps.length; i += 1) s += ps[i].x;
	return s;
}


function genericLen<T>(xs: Span<T>): int32 { return xs.length; }

function skipFirst(xs: Span<int64>): int64 {
	xs = xs[1..xs.length];
	return localSum(xs) * 10 + xs.length;
}

function captured(src: int64[]): int64 {
	let k: int64 = 0;
	k += 1;
	const h = (xs: Span<int64>): int64 => localSum(xs) + k;
	k += 0;
	return h(src);
}

function passOn(xs: Span<int64>, k: int64): int64 { return localSum(xs) + k; }

function twoSpans(a: Span<int64>, n: int32, b: Span<int64>): int64 { return localSum(a) * n + localSum(b); }

const v: int64[] = [1, 2, 3];
const none: int64[] = [];
const pts: Pt[] = [{ x: 3, y: 0 }, { x: 4, y: 1 }, { x: 5, y: 2 }];
const out: string[] = [];

out.push(localSum(v).toString());
out.push(pubSum(v).toString());
out.push(skipFirst(v).toString());
const f: (xs: Span<int64>) => int64 = localSum;
out.push(f(v).toString());
out.push(captured(v).toString());
out.push(passOn(v, 1).toString());
out.push((genericLen(v) + genericLen(pts)).toString());
out.push(sumX(pts[0..1]).toString());
out.push(localSum(none).toString());
out.push(sumX(pts[1..2]).toString());
out.push(sumX(pts).toString());
out.push(twoSpans(v, 2, v[1..3]).toString());
console.log(out.join("|"));
