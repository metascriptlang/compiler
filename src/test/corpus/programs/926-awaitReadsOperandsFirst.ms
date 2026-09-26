// @stdout: stores 100 6 a5 5 15 30
// @ledger-slack(Box): 1
// @ledger-slack(int32_tArrayRefCell): 1
// note: an operand left of an await is read before the await runs, as in TypeScript: a variable, a field, an array element, an argument before an awaited argument, the target of `x += await f()`, and the object and index of `o.f = await f()` or `a[i] = await f()`. Before the fix C read them after resume, so `x + await f()` saw what f wrote (105 instead of 6). A value struct or array stays in place: the store and the push land in it.

class Box {
	v: int32 = 1;
	s: string = "a";
}

struct Pt {
	x: int32;
	y: int32;
}

let x: int32 = 1;
let s: string = "s";
let i: int32 = 0;
let obj = new Box();
const arr: int32[] = [10, 20, 30];

async function clobber(): Promise<int32> {
	x = 100;
	s = "S";
	i = 2;
	arr[0] = 99;
	obj = new Box();
	obj.v = 50;
	obj.s = "z";
	return 5;
}

function pair(a: int32, b: int32): int32 {
	return a * 1000 + b;
}

async function reads(): Promise<void> {
	x = 1;
	const v = x + await clobber();
	obj = new Box();
	const f = obj.v + await clobber();
	arr[0] = 10;
	const e = arr[0] + await clobber();
	x = 1;
	const a = pair(x, await clobber());
	x = 1;
	const nested = pair(x, pair(x, await clobber()));
	s = "s";
	const t = s + (await clobber()).toString() + s;
	x = 1;
	const after = (await clobber()) + x;
	x = 1;
	const lit = [x, await clobber(), x];
	console.log(`reads ${v} ${f} ${e} ${a} ${nested} ${t} ${after} ${lit[0]} ${lit[2]}`);
}

async function stores(): Promise<void> {
	x = 1;
	x += await clobber();
	const afterCompound = x;
	obj = new Box();
	const first = obj;
	obj.v += await clobber();
	obj = new Box();
	const second = obj;
	obj.s += (await clobber()).toString();
	obj = new Box();
	const third = obj;
	obj.v = await clobber();
	i = 0;
	arr[0] = 10;
	arr[2] = 30;
	arr[i] += await clobber();
	const compoundAt = `${arr[0]} ${arr[2]}`;
	i = 0;
	arr[0] = 10;
	arr[2] = 30;
	arr[i] = await clobber();
	console.log(`stores ${x} ${first.v} ${second.s} ${third.v} ${compoundAt}`);
	console.log(`compound ${afterCompound} set ${arr[0]} ${arr[2]}`);
}

async function values(): Promise<void> {
	let p: Pt = { x: 5, y: 6 };
	p.x = await clobber();
	p.y += await clobber();
	const names: string[] = ["a"];
	names.push((await clobber()).toString());
	console.log(`values ${p.x} ${p.y} ${names.join(",")}`);
}

async function main(): Promise<void> {
	await reads();
	await stores();
	await values();
}

await main();
