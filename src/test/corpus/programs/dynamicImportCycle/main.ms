// Parity program — import() of a module in a static cycle evaluates the cycle once, the
// dependency before the module that closes the cycle, and a later import of the other
// member finds it already evaluated.
//
// @stdout: b body
// @stdout: a body
// @stdout: seen b sees a
// @stdout: other b sees a

async function run(): Promise<void> {
	const a = await import("./a");
	console.log(`seen ${a.seen}`);
	const b = await import("./b");
	console.log(`other ${b.fromB()}`);
}

run();
