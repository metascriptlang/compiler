// Parity program — import() called inside a spawned task evaluates the module once, and
// the task reads the module through the namespace it awaited.
//
// @serial
// @stdout: lazy body
// @stdout: worker 21
// @stdout: main 30

async function run(): Promise<void> {
	const r = await spawn(() => { const m = await import("./lazy"); return m.triple(7); });
	console.log(`worker ${r}`);
	const m = await import("./lazy");
	console.log(`main ${m.triple(10)}`);
}

run();
