// @stdout: string text-5! text-5! text-5 | struct 5 pair-4? 5 pair-4? pair-4 | class 6 6 3 | dropped 400
// @xfail(raiser): raiser-solid owns Raiser Promise APIs
// note: the future a value-returning then makes is an async method's and owns its result
// (PARALOCK Amendment O): awaiting it twice copies, the input stays readable, and results
// nobody reads are released (the SAN lane reports a leak or a double free here).

class Box { v: int32 = 0; }
struct Pair { n: int32; tag: string; }

async function makeBox(n: int32): Promise<Box> { const b = new Box(); b.v = n; return b; }
async function makePair(n: int32): Promise<Pair> { return { n: n, tag: "pair-" + n.toString() }; }
async function makeText(n: int32): Promise<string> { return "text-" + n.toString(); }

async function run(): Promise<void> {
	const pt = makeText(5);
	const up = pt.then((t: string): string => t + "!");
	const s1 = await up;
	const s2 = await up;
	let out = `string ${s1} ${s2} ${await pt}`;

	const pp = makePair(4);
	const q = pp.then((p: Pair): Pair => ({ n: p.n + 1, tag: p.tag + "?" }));
	const a = await q;
	const b = await q;
	out += ` | struct ${a.n} ${a.tag} ${b.n} ${b.tag} ${(await pp).tag}`;

	const pb = makeBox(3);
	const r = pb.then((x: Box): Box => { const c = new Box(); c.v = x.v * 2; return c; });
	const r1 = await r;
	const r2 = await r;
	out += ` | class ${r1.v} ${r2.v} ${(await pb).v}`;

	let count = 0;
	for (let i = 0; i < 400; i += 1) {
		makeText(i).then((t: string): string => t + "-unread");
		count += 1;
	}
	await sleepAsync(5);
	console.log(`${out} | dropped ${count}`);
}

await run();
