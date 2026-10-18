// Parity program — a top-level await that rejects: the error is recorded on the module and on
// the module waiting for it, so the import rejects, a second import of either rejects with the
// same error object, and the waiting module's body never runs.
//
// @stdout: bad start
// @stdout: first late boom
// @stdout: second late boom same
// @stdout: direct late boom same

async function run(): Promise<void> {
	let first: Error | null = null;
	try {
		const m = await import("./lazy");
		console.log(`unexpected ${m.doubled}`);
	} catch (e) {
		first = e;
		console.log(`first ${e.message}`);
	}
	try {
		await import("./lazy");
		console.log("unexpected second");
	} catch (e) {
		console.log(`second ${e.message} ${e === first ? "same" : "other"}`);
	}
	try {
		await import("./bad");
		console.log("unexpected direct");
	} catch (e) {
		console.log(`direct ${e.message} ${e === first ? "same" : "other"}`);
	}
}

run();
