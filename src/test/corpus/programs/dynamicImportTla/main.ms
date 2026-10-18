// Parity program — a module reached only through import() with a top-level await runs its
// body after the importer's synchronous code, a 0 ms timer the body arms fires while the
// body awaits, and the importer resumes only once the whole body has finished.
//
// @stdout: start
// @stdout: after call
// @stdout: lazy start
// @stdout: timer in body
// @stdout: lazy end
// @stdout: got 7 8

async function run(): Promise<void> {
	const p = import("./lazy");
	console.log("after call");
	const m = await p;
	console.log(`got ${m.v} ${m.reads}`);
}

console.log("start");
run();
