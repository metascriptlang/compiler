// @stdout: nrvo-closure sum=48
// note: A closure call that returns a tuple through an out-parameter must find the out-temp zeroed when the closure throws before writing it, or the scope-exit destroy of the temp reads stack residue (nrvoTempNeedsZero in codegen/c/expressions.ms, genClosureCall). warm() leaves freed heap strings in the frames attempt() reuses; the companion 1049 covers the direct-call path with a struct payload.

function madeGrid(tag: string): [string, int32] {
	return [tag + "-grid-" + tag + "-padding-padding-padding", tag.length as int32];
}

function attempt(tag: string): int32 {
	let total: int32 = 0;
	const boom = (t: string): [string, int32] => {
		if (t.length > 0) { throw new Error("boom " + t); }
		return [t, 0];
	};
	try {
		const p = boom(tag);
		total = p[1];
	} catch (e) {
		total = -1;
	}
	return total;
}

function warm(tag: string): int32 {
	const a = madeGrid(tag);
	const b = madeGrid(tag + "x");
	return a[1] + b[1];
}

let sum: int32 = 0;
for (let i = 0; i < 4; i += 1) {
	sum += warm("round" + i.toString());
	sum += attempt("t" + i.toString());
}
console.log("nrvo-closure sum=" + sum.toString());
