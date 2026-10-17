// Parity program — import() of a module in a static cycle whose other member has a top-level
// await: the awaiting member starts first, the module that closes the cycle runs only after
// it finished, and a later import of the awaiting member finds the cycle evaluated.
//
// @stdout: b start
// @stdout: b end
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
