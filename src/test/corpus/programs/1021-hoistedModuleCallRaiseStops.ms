// @exit: 1
// @stdout: Error: unhandled exception: stop
// @skip-js: node reports the uncaught error with its own stack trace on stderr, and parity compares merged stdout+stderr (sibling of 872)
// @skip-raiser: the raiser writes its uncaught-error report to a stderr its lane does not read, so its output cannot match C's merged stdout+stderr (sibling of 669)

function f(): int32 {
	throw new Error("stop");
}

console.log(`v=${f()}`);
throw new Error("unreachable");
