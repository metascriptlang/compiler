// @exit: 1
// @stdout: first
// @xfail(c): a throw out of a timer callback is swallowed, the later timer runs and the program exits 0 (inbox 2026-10-31-c-a-throw-out-of-a-timer-callback-is-swallowed)
// @xfail(danger): a throw out of a timer callback is swallowed, the later timer runs and the program exits 0 (inbox 2026-10-31-c-a-throw-out-of-a-timer-callback-is-swallowed)
// @xfail(san): a throw out of a timer callback is swallowed, the later timer runs and the program exits 0 (inbox 2026-10-31-c-a-throw-out-of-a-timer-callback-is-swallowed)
// @xfail(js): node reports the uncaught error with its own trace on stderr, which this lane compares with the output, where the Raiser writes its report to a stderr its lane does not read
// @xfail(esm): node reports the uncaught error with its own trace on stderr, which this lane compares with the output, where the Raiser writes its report to a stderr its lane does not read
// note: a throw out of a timeout's callback is uncaught: the program stops at it with exit 1, as in node, so a timer due later never runs.

setTimeout((): void => {
	console.log("first");
	throw new Error("boom");
}, 0);
setTimeout((): void => {
	console.log("later");
}, 20);
