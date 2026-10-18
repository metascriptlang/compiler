// @stdout: nrvo-direct sum=48
// note: A direct call that returns a struct through an out-parameter must find the out-temp zeroed when the callee throws before writing it, or the scope-exit destroy of the temp reads stack residue (nrvoTempNeedsZero in codegen/c/expressions.ms, emitNrvoOrValueCall). warm() leaves freed heap strings in the frames attempt() reuses; the companion 1050 covers the closure-call path with a tuple payload.

struct Payload { label: string; n: int32; }

function made(tag: string): Payload {
	return { label: tag + "-made-" + tag + "-padding-padding-padding", n: tag.length as int32 };
}

function boom(tag: string): Payload {
	if (tag.length > 0) { throw new Error("boom " + tag); }
	return { label: tag, n: 0 };
}

function attempt(tag: string): int32 {
	let total: int32 = 0;
	try {
		const p = boom(tag);
		total = p.n;
	} catch (e) {
		total = -1;
	}
	return total;
}

function warm(tag: string): int32 {
	const a = made(tag);
	const b = made(tag + "x");
	return a.n + b.n;
}

let sum: int32 = 0;
for (let i = 0; i < 4; i += 1) {
	sum += warm("round" + i.toString());
	sum += attempt("t" + i.toString());
}
console.log("nrvo-direct sum=" + sum.toString());
