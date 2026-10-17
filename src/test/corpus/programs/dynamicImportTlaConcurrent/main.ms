// Parity program — two import() calls of a module with a top-level await, the second issued
// while the first evaluation is suspended, share that one evaluation: the body runs once and
// both promises resolve after it finished, in the order they were made.
//
// @stdout: lazy start
// @stdout: lazy end
// @stdout: first 1
// @stdout: second 1
// @stdout: third 1

async function first(): Promise<void> {
	const m = await import("./lazy");
	console.log(`first ${m.loads}`);
}

async function second(): Promise<void> {
	await sleepAsync(1);
	const m = await import("./lazy");
	console.log(`second ${m.loads}`);
}

async function run(): Promise<void> {
	const a = first();
	const b = second();
	await a;
	await b;
	const m = await import("./lazy");
	console.log(`third ${m.loads}`);
}

run();
