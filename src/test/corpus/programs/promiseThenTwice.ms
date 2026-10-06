// @xfail(raiser): raiser runtime error: Unknown host function: msFutureThen
// note: Two then callbacks on one promise both receive its value, as in TypeScript.

class Box { v: int32 = 0; }
struct Pair { n: int32; tag: string; }

async function makeBox(n: int32): Promise<Box> { const b = new Box(); b.v = n; return b; }
async function makePair(n: int32): Promise<Pair> { return { n: n, tag: "pair-" + n.toString() }; }
async function makeText(n: int32): Promise<string> { return "text-" + n.toString(); }

async function run(): Promise<void> {
	const pb = makeBox(3);
	await pb.then((b: Box): void => { console.log(`box a ${b.v}`); });
	await pb.then((b: Box): void => { console.log(`box b ${b.v}`); });
	const pp = makePair(4);
	await pp.then((p: Pair): void => { console.log(`pair a ${p.tag}`); });
	await pp.then((p: Pair): void => { console.log(`pair b ${p.tag}`); });
	const pt = makeText(5);
	await pt.then((t: string): void => { console.log(`text a ${t}`); });
	await pt.then((t: string): void => { console.log(`text b ${t}`); });
	console.log(`after ${(await pb).v} ${(await pp).n} ${await pt}`);
}

await run();
