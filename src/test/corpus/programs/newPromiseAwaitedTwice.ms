// @stdout: text hi hi | pair seven seven | list 2 2 y | late later later
// note: a new Promise owns the value it was resolved with, so every await of it reads that
// value: a string, a struct holding a string and an array, settled at once or after a sleep.

struct Pair { n: int32; tag: string; }

async function after(ms: number, run: () => void): Promise<void> {
	await sleepAsync(ms);
	run();
}

async function run(): Promise<void> {
	const text = new Promise<string>((resolve) => { resolve(`h${"i"}`); });
	const t1 = await text;
	const t2 = await text;

	const pair = new Promise<Pair>((resolve) => { resolve({ n: 7, tag: `se${"ven"}` }); });
	const p1 = await pair;
	const p2 = await pair;

	const list = new Promise<string[]>((resolve) => { resolve([`x${""}`, `y${""}`]); });
	const l1 = await list;
	const l2 = await list;

	const late = new Promise<string>((resolve) => { after(1, (): void => { resolve(`la${"ter"}`); }); });
	const d1 = await late;
	const d2 = await late;

	console.log(`text ${t1} ${t2} | pair ${p1.tag} ${p2.tag} | list ${l1.length} ${l2.length} ${l2[1]} | late ${d1} ${d2}`);
}

await run();
