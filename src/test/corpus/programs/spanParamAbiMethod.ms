// A class method takes a Span parameter; the C ABI passes it as element pointer and length. Companion of `spanParamAbi`.
// @stdout: 7|7
// @exit: 0
function localSum(xs: Span<int64>): int64 {
	let s: int64 = 0;
	for (let i = 0; i < xs.length; i += 1) s += xs[i];
	return s;
}

class Acc {
	base: int64 = 1;
	total(xs: Span<int64>): int64 { return this.base + localSum(xs); }
}

const v: int64[] = [1, 2, 3];
const acc = new Acc();
console.log(acc.total(v).toString() + "|" + acc.total(v[0..3]).toString());
