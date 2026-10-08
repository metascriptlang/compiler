// note: A promise from an async function is a plain value: every await reads the same result, as in TypeScript. Covers each storage tier (int, string built at run time, struct with a heap field, class, array, closure), an alias of the promise, and a promise awaited inside another async function.

struct Pair { n: int32; tag: string; }
class Box { v: int32 = 0; }
type Count = () => int32;

async function makeInt(n: int32): Promise<int32> { return n + 1; }
async function makeText(n: int32): Promise<string> { return "a text long enough to own a heap payload " + n.toString(); }
async function makePair(n: int32): Promise<Pair> { return { n: n, tag: "pair-" + n.toString() }; }
async function makeBox(n: int32): Promise<Box> { const b = new Box(); b.v = n; return b; }
async function makeList(n: int32): Promise<int32[]> { return [n, n + 1, n + 2]; }
async function makeCounter(start: int32): Promise<Count> {
	let seen = start;
	return (): int32 => { seen = seen + 1; return seen; };
}

async function twice(): Promise<void> {
	const pi = makeInt(1);
	console.log(`int ${await pi} ${await pi}`);

	const pt = makeText(2);
	const t1 = await pt;
	const t2 = await pt;
	console.log(`text ${t1.length} ${t2.length} ${t1 == t2}`);

	const pp = makePair(3);
	const p1 = await pp;
	const p2 = await pp;
	console.log(`pair ${p1.n}${p1.tag} ${p2.n}${p2.tag}`);

	const pb = makeBox(4);
	const b1 = await pb;
	const b2 = await pb;
	b1.v = b1.v + 10;
	console.log(`box ${b1.v} ${b2.v} ${b1 === b2}`);

	const pl = makeList(5);
	const l1 = await pl;
	const l2 = await pl;
	console.log(`list ${l1.length} ${l2.length} ${l1[2]} ${l2[0]}`);

	const pc = makeCounter(10);
	const c1 = await pc;
	const c2 = await pc;
	console.log(`counter ${c1()} ${c2()} ${c1()}`);

	const alias = pt;
	const t3 = await alias;
	console.log(`alias ${t3 == t1}`);
}

async function readsInside(p: Promise<Pair>): Promise<string> {
	const a = await p;
	const b = await p;
	return a.tag + "|" + b.tag;
}

await twice();
const shared = makePair(6);
console.log(`inside ${await readsInside(shared)} ${(await shared).tag}`);
