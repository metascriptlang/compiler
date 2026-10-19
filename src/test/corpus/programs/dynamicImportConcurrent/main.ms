// Parity program — two import() calls in flight for one module share its single
// evaluation: the body runs once and both promises resolve to the same live namespace.
//
// @stdout: lazy body
// @stdout: a lazy 1
// @stdout: b lazy 1

async function first(): Promise<void> {
	const m = await import("./lazy");
	console.log(`a ${m.name()} ${m.loads}`);
}

async function second(): Promise<void> {
	const m = await import("./lazy");
	console.log(`b ${m.name()} ${m.loads}`);
}

first();
second();
