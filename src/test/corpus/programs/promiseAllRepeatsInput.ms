// @xfail(raiser): raiser runtime error: Unknown host function: msPromiseAll
// note: Promise.all over a list that names the same promise twice yields its value in both slots, as in TypeScript, for every storage tier.

struct Pair { n: int32; tag: string; }
class Box { v: int32 = 0; }
type Count = () => int32;

async function makeText(n: int32): Promise<string> { return "text-" + n.toString(); }
async function makePair(n: int32): Promise<Pair> { return { n: n, tag: "pair-" + n.toString() }; }
async function makeBox(n: int32): Promise<Box> { const b = new Box(); b.v = n; return b; }
async function makeCounter(start: int32): Promise<Count> {
	let seen = start;
	return (): int32 => { seen = seen + 1; return seen; };
}

async function run(): Promise<void> {
	const pt = makeText(1);
	const ts = await Promise.all([pt, pt, makeText(2)]);
	console.log(`text ${ts[0]} ${ts[1]} ${ts[2]}`);

	const pp = makePair(3);
	const ps = await Promise.all([pp, pp]);
	console.log(`pair ${ps[0].tag} ${ps[1].tag}`);

	const pb = makeBox(4);
	const bs = await Promise.all([pb, pb]);
	console.log(`box ${bs[0].v} ${bs[1].v} ${bs[0] === bs[1]}`);

	const pc = makeCounter(10);
	const cs = await Promise.all([pc, pc, makeCounter(20)]);
	console.log(`counter ${cs[0]()} ${cs[1]()} ${cs[2]()}`);

	console.log(`after ${(await pt)} ${(await pp).n}`);
}

await run();
