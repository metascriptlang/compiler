// Parity program — an import() whose evaluation throws rejects; the error is recorded on
// every module of the evaluation, so later imports of the thrower and of the module that
// imported it reject with the same error object, and neither body runs again.
//
// @stdout: failing body
// @stdout: first boom
// @stdout: second boom same
// @stdout: direct boom same

async function run(): Promise<void> {
	let first: Error | null = null;
	try {
		const m = await import("./dependent");
		console.log(`unexpected ${m.doubled}`);
	} catch (e) {
		first = e;
		console.log(`first ${e.message}`);
	}
	try {
		await import("./dependent");
		console.log("unexpected second");
	} catch (e) {
		console.log(`second ${e.message} ${e === first ? "same" : "other"}`);
	}
	try {
		await import("./failing");
		console.log("unexpected direct");
	} catch (e) {
		console.log(`direct ${e.message} ${e === first ? "same" : "other"}`);
	}
}

run();
