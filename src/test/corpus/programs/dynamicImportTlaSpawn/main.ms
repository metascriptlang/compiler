// Parity program — import() of a module with a top-level await from a spawned task: the task
// waits until the body finished, the body runs once, and a later import on the main thread
// finds it evaluated.
//
// @serial
// @stdout: lazy start
// @stdout: lazy end
// @stdout: worker 21
// @stdout: main 30

async function run(): Promise<void> {
	const r = await spawn(() => { const m = await import("./lazy"); return m.triple(7); });
	console.log(`worker ${r}`);
	const m = await import("./lazy");
	console.log(`main ${m.triple(10)}`);
}

run();
