// @stdout: box 14 14 true
// @stdout: list 9 true
// @stdout: counter 11 12 13
// @stdout: then true 21
// @stdout: all true 31
// @stdout: pair 3 1
// note: a promise settled with an object, an array or a closure hands every reader that same value, as TS does: two awaits, a .then callback and a Promise.all element all see one instance, while a struct read twice is two copies.

class Box { v: int32 = 0; }
struct Pair { n: int32; tag: string; }
type Count = () => int32;

async function makeBox(n: int32): Promise<Box> { const b = new Box(); b.v = n; return b; }
async function makeList(n: int32): Promise<int32[]> { return [n, n + 1]; }
async function makeCounter(start: int32): Promise<Count> {
	let seen = start;
	return (): int32 => { seen = seen + 1; return seen; };
}
async function makePair(n: int32): Promise<Pair> { return { n: n, tag: "p" + n.toString() }; }

async function main(): Promise<void> {
	const pb = makeBox(4);
	const b1 = await pb;
	const b2 = await pb;
	b1.v = b1.v + 10;
	console.log(`box ${b1.v} ${b2.v} ${b1 === b2}`);

	const pl = makeList(5);
	const l1 = await pl;
	l1[0] = 9;
	const l2 = await pl;
	console.log(`list ${l2[0]} ${l1 === l2}`);

	const pc = makeCounter(10);
	const c1 = await pc;
	const c2 = await pc;
	console.log(`counter ${c1()} ${c2()} ${c1()}`);

	const pt = makeBox(1);
	const t1 = await pt;
	let seen: Box | null = null;
	await pt.then((b: Box): void => { b.v = b.v + 20; seen = b; });
	console.log(`then ${seen === t1} ${t1.v}`);

	const pa = makeBox(1);
	const all = await Promise.all([pa]);
	const a1 = await pa;
	a1.v = a1.v + 30;
	console.log(`all ${all[0] === a1} ${all[0].v}`);

	const pp = makePair(3);
	let p1 = await pp;
	const p2 = await pp;
	p1.n = 1;
	console.log(`pair ${p2.n} ${p1.n}`);
}

await main();
