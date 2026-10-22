// @stdout: p1 p2
// note: each slot of one spawn group runs a closure moved into it and returns a string, which crosses back boxed.

function label(n: int32): () => string {
	const parts: string[] = [`p${n}`];
	return (): string => parts[0];
}

async function both(): Promise<string> {
	const a = label(1);
	const b = label(2);
	const rs = await Promise.all([spawn(() => a(), { move: [a] }), spawn(() => b(), { move: [b] })]);
	return `${rs[0]} ${rs[1]}`;
}

console.log(await both());
