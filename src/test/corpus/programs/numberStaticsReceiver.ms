// @xfail(raiser): error: Undefined variable 'Number'
// @stdout: 9007199254740991 true true false

function widen(x: float64): float64 {
	return x;
}

const top = Number.MAX_SAFE_INTEGER;
const same = widen(Number.MAX_SAFE_INTEGER) == top;
const eps = Number.EPSILON > 0.0 && Number.isFinite(Number.EPSILON);
const nan = Number.isFinite(Number.NaN);
console.log(`${top} ${same} ${eps} ${nan}`);
