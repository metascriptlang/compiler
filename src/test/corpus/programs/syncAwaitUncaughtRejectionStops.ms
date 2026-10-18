// @exit: 1
// @stdout: Error: unhandled exception: boom
// @skip-js: node reports the uncaught error with its own stack trace on stderr, and parity compares merged stdout+stderr (sibling of 1020-moduleInitializerRaiseStops)
// @skip-raiser: the raiser writes its uncaught-error report to a stderr its lane does not read, so its output cannot match C's merged stdout+stderr (sibling of 1020-moduleInitializerRaiseStops)
// An uncaught rejected await at module top level stops the program at that await with the
// awaited error. Before the fix C ran the next statements with a null payload and reported the
// error only at exit; here the next statement would replace it with `unreachable`.

interface Reply { status: string; }

async function fail(): Promise<Reply> { throw new Error("boom"); }

async function main(): Promise<void> {
	const r = await fail();
	console.log(`continued ${r.status}`);
}

await main();
console.log("after main");
throw new Error("unreachable");
