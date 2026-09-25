// @stdout: number 2.5 text hello 3 count 7 pair 7 batches 39 last batch 2 names 3
// @xfail(raiser): raiser runtime error: Unknown host function: msSleepAsync
// @xfail(js): the js Promise prelude declares only `then(fn: () => T)` (the spawn shape), so a `.then((v: T) => …)` callback fails the type check (inbox 2026-09-26-js-promise-then-takes-no-value)
// @xfail(esm): same js Promise prelude as the js lane
// @serial
// note: `.then` callbacks receive the promise's value in the callback's own C calling convention. Before the fix every `.then` fell through to the untyped runtime callback (the lowering only matched `p.then(cb)`, while the call arrives as `Promise_then(p, cb)`), which hands the callback a `void*`: a number, string or int32 callback crashed, an 8-byte struct arrived as garbage on Windows and every struct on Linux (SysV passes structs by value, Win64 passes those over 8 bytes by reference, which hid it). The combinators also did not keep their input future, output future or callback env alive until the callback ran, so a callback armed inside a loop (env freed at the end of the iteration) or on a discarded `.then` result read freed memory. `Batch` is 32 bytes with a string and a string[]: the callback takes it by pointer and the runtime destroys it after the call (ledger balance in the SAN lane).

struct Batch {
	paths: string[];
	label: string;
	count: int32;
}

struct Pair {
	a: int32;
	b: int32;
}

async function next(i: int32): Promise<Batch> {
	await sleepAsync(1);
	return { paths: [`a${i}.ms`, `b${i}.ms`], label: `batch ${i}`, count: i };
}

async function pair(): Promise<Pair> {
	await sleepAsync(1);
	return { a: 3, b: 4 };
}

async function text(): Promise<string> {
	await sleepAsync(1);
	return `hello ${3}`;
}

async function num(): Promise<number> {
	await sleepAsync(1);
	return 2.5;
}

async function count(): Promise<int32> {
	await sleepAsync(1);
	return 7;
}

async function names(): Promise<string[]> {
	await sleepAsync(1);
	return ["a", "b", "c"];
}

let total: int32 = 0;
let label = "";
let sum: int32 = 0;
let said = "";
let n = 0.0;
let c: int32 = 0;
let listed: int32 = 0;

async function main(): Promise<void> {
	for (let i: int32 = 0; i < 3; i += 1) {
		const bonus: int32 = i * 10;
		next(i).then((b: Batch): void => {
			total = total + b.paths.length + b.count + bonus;
			if (b.count == 2) label = b.label;
		});
	}
	pair().then((p: Pair): void => { sum = p.a + p.b; });
	text().then((s: string): void => { said = s; });
	num().then((v: number): void => { n = v; });
	count().then((v: int32): void => { c = v; });
	names().then((v: string[]): void => { listed = v.length; });
	await sleepAsync(40);
	console.log(`number ${n} text ${said} count ${c} pair ${sum} batches ${total} last ${label} names ${listed}`);
}

main();
