// Parity program — a generic body whose sizeof sits in an argument slot. The
// uninstantiated template used to reach the JS emitter, which wrote a comment
// into that slot and made the whole bundle a syntax error while the correct
// instance sat right beside it.
//
// @stdout: 5|9
// @exit: 0

function pair(a: int32, b: int32): int32 { return a + b; }
function widthPair<T>(v: T): int32 { return pair(sizeof(T), 1); }

const parts: string[] = [
	widthPair(1 as int32).toString(),
	widthPair(2.5 as float64).toString(),
];
console.log(parts.join("|"));
