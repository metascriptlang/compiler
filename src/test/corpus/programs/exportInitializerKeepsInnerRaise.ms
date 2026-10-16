// @exit: 1
// @stdout: Error: unhandled exception: inner
// @skip-js: node reports the uncaught error with its own stack trace on stderr, and parity compares merged stdout+stderr (sibling of 1021)
// @skip-raiser: the raiser writes its uncaught-error report to a stderr its lane does not read, so its output cannot match C's merged stdout+stderr (sibling of 1021)

function thrower(n: int32): int32 {
	if (n > 0) throw new Error("inner");
	return n;
}
function outer(v: int32): int32 {
	throw new Error("outer ran");
}
export const x = outer(thrower(1));
console.log(`x=${x}`);
