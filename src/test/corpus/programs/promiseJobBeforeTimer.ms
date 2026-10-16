// @stdout: 1 sync
// @stdout: 2 promise
// @stdout: 3 timer
// @xfail(raiser): raiser runtime error: Unknown host function: msSetTimeout
// note: a `.then` queued after a 0 ms timer runs before the timer, as in TypeScript: pending callbacks drain before expired timers.

setTimeout((): void => { console.log("3 timer"); }, 0);
Promise.resolve(1).then((v: int32): void => { console.log("2 promise"); });
console.log("1 sync");
