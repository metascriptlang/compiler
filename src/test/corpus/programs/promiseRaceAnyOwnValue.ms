// @stdout: race string fast-f
// @stdout: any string fast-f
// @stdout: race struct 2 3 p2
// @stdout: any struct 4 5 p4
// @stdout: race class box9
// @stdout: any tuple 8 t8
// @stdout: any after reject late-l
// @stdout: race read twice fast-f fast-f
// @stdout: race struct read twice p2 p2
// @stdout: dropped results settled
// @xfail(raiser): race picks slow-s, the first input made (an async call runs inline and settles before the next is made, inbox 2026-10-15-raiser-async-call-runs-inline)
// note: Promise.race and Promise.any complete their result with a value of their own: a winner whose future owns
//   a string, struct, class or tuple keeps it, and the result copies it, so the result outlives its inputs, reads
//   twice, and an unread result is released.

struct Pt { x: int32; y: int32; name: string; }
class Box { label: string = ""; }

async function slow(): Promise<string> { await Promise.resolve(0); await Promise.resolve(0); return "slow" + "-s"; }
async function fast(): Promise<string> { await Promise.resolve(0); return "fast" + "-f"; }
async function late(): Promise<string> { await Promise.resolve(0); await Promise.resolve(0); return "late" + "-l"; }
async function fails(): Promise<string> { await Promise.resolve(0); throw new Error("no"); }
async function point(n: int32, hops: int32): Promise<Pt> {
	for (let i = 0; i < hops; i++) await Promise.resolve(0);
	return { x: n, y: n + 1, name: "p" + n.toString() };
}
async function box(n: int32, hops: int32): Promise<Box> {
	for (let i = 0; i < hops; i++) await Promise.resolve(0);
	const b = new Box();
	b.label = "box" + n.toString();
	return b;
}
async function pair(n: int32, hops: int32): Promise<[int32, string]> {
	for (let i = 0; i < hops; i++) await Promise.resolve(0);
	return [n, "t" + n.toString()];
}

async function main(): Promise<void> {
	const r = await Promise.race([slow(), fast()]);
	console.log("race string " + r);
	const a = await Promise.any([slow(), fast()]);
	console.log("any string " + a);
	const p = await Promise.race([point(1, 2), point(2, 1)]);
	console.log(`race struct ${p.x} ${p.y} ${p.name}`);
	const q = await Promise.any([point(3, 2), point(4, 1)]);
	console.log(`any struct ${q.x} ${q.y} ${q.name}`);
	const b = await Promise.race([box(9, 1), box(10, 2)]);
	console.log("race class " + b.label);
	const t = await Promise.any([pair(7, 2), pair(8, 1)]);
	console.log(`any tuple ${t[0]} ${t[1]}`);
	const l = await Promise.any([fails(), late()]);
	console.log("any after reject " + l);
	const twice = Promise.race([slow(), fast()]);
	const first = await twice;
	const second = await twice;
	console.log(`race read twice ${first} ${second}`);
	const pts = Promise.race([point(1, 2), point(2, 1)]);
	const p1 = await pts;
	const p2 = await pts;
	console.log(`race struct read twice ${p1.name} ${p2.name}`);
	Promise.race([slow(), fast()]);
	Promise.any([point(5, 1), point(6, 2)]);
	for (let i = 0; i < 4; i++) await Promise.resolve(0);
	console.log("dropped results settled");
}

await main();
