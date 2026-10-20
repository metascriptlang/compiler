// @stdout: chain 8 text 3x7 pair 9 len 4 void 5 pair2 3 9 leaf x capture 4
// @xfail(raiser): raiser-solid owns Raiser Promise APIs
// note: a value-returning `.then` resolves the promise it makes with the callback's result:
// number, string, struct, array and class payloads in, number, string, int32 and struct out,
// a `Promise<void>` input, a chain of two, and a void callback capturing a local beside them.

struct Pair {
	a: int32;
	b: int32;
}

class Leaf {
	label: string;
	constructor(label: string) {
		this.label = label;
	}
}

class Counter {
	n: number = 0;
}

async function num(): Promise<number> {
	await sleepAsync(1);
	return 3;
}

async function text(): Promise<string> {
	await sleepAsync(1);
	return "3x";
}

async function pair(): Promise<Pair> {
	await sleepAsync(1);
	return { a: 4, b: 5 };
}

async function names(): Promise<string[]> {
	await sleepAsync(1);
	return ["a", "b", "c", "d"];
}

async function leaf(): Promise<Leaf> {
	await sleepAsync(1);
	return new Leaf("x");
}

async function unit(): Promise<void> {
	await sleepAsync(1);
}

async function main(): Promise<void> {
	const chain = await num().then((v: number): number => v + 1).then((v: number): number => v * 2);
	const t = await text().then((s: string): string => s + "7");
	const p = await pair().then((x: Pair): int32 => x.a + x.b);
	const len = await names().then((v: string[]): int32 => v.length);
	const fromVoid = await unit().then((): number => 5);
	const p2 = await num().then((v: number): Pair => ({ a: v as int32, b: (v * 2 + v) as int32 }));
	const lab = await leaf().then((l: Leaf): string => l.label);
	const c = new Counter();
	c.n = 1;
	await num().then((v: number): void => { c.n = c.n + v; });
	console.log(`chain ${chain} text ${t} pair ${p} len ${len} void ${fromVoid} pair2 ${p2.a} ${p2.b} leaf ${lab} capture ${c.n}`);
}

await main();
