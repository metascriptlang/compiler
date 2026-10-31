// @exit: 1
// @stdout: tick 1
// @xfail(c): a throw out of a timer callback is swallowed, the interval keeps ticking and the program exits 0 (inbox 2026-10-31-c-a-throw-out-of-a-timer-callback-is-swallowed)
// @xfail(danger): a throw out of a timer callback is swallowed, the interval keeps ticking and the program exits 0 (inbox 2026-10-31-c-a-throw-out-of-a-timer-callback-is-swallowed)
// @xfail(san): a throw out of a timer callback is swallowed, the interval keeps ticking and the program exits 0 (inbox 2026-10-31-c-a-throw-out-of-a-timer-callback-is-swallowed)
// @xfail(js): node reports the uncaught error with its own trace on stderr, which this lane compares with the output, where the Raiser writes its report to a stderr its lane does not read
// @xfail(esm): node reports the uncaught error with its own trace on stderr, which this lane compares with the output, where the Raiser writes its report to a stderr its lane does not read
// note: a throw out of an interval's callback is uncaught: the program stops at it with exit 1, as in node, so the interval never ticks again and the timeout that would clear it never runs.

let n = 0;
const id = setInterval((): void => {
	n = n + 1;
	console.log(`tick ${n}`);
	throw new Error("boom");
}, 10);
setTimeout((): void => {
	clearInterval(id);
	console.log(`cleared after ${n}`);
}, 55);
