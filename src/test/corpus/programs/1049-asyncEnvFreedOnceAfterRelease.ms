// @stdout: a=2|b=5|c=7
// note: the env cell of an async function is a cycle candidate; a release that frees it by its last count must leave the collector's roots, or the program-end collection frees it again.

async function inner(n: number): Promise<number> { return n; }

async function plain(): Promise<number> {
	return await inner(2);
}

async function nested(): Promise<number> {
	const x = await inner(2);
	const y = await plain();
	return x + y + 1;
}

class Holder { n: number; constructor(n: number) { this.n = n; } }

async function viaObject(): Promise<number> {
	const h = new Holder(await inner(3));
	return h.n + (await inner(4));
}

async function main(): Promise<void> {
	const a = await plain();
	const b = await nested();
	const c = await viaObject();
	console.log("a=" + a + "|b=" + b + "|c=" + c);
}
main();
