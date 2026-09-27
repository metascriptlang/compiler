// bug462 — a variable or field read left of an await was read after it on C
//
// Symptom:    on C, `x + await f()` where f sets x to 100 gave 105; JS (and
//             TypeScript) give 6. The same held for a field, an array element,
//             an argument before an awaited argument, the target of
//             `x += await f()`, and the object or index of `o.f = await f()`.
// Root cause: src/transform/lowering/asyncDesugar.ms bound only calls
//             evaluated before the await into temps, as the reference's
//             closure-iterator lowering does; a plain read stayed in the
//             expression and ran after resume.
// Fix:        a read of a scalar, string or reference that sits left of the
//             await is bound into a temp first; a compound assignment reads
//             its target into a temp before the await and stores
//             `t = $read OP value`; an assignment's object and index are
//             evaluated before the await. A value struct or array stays in
//             place (NIM-REF TR-24).
//
// Guarded end-to-end by corpus/programs/926-awaitReadsOperandsFirst.ms.

class B462Box {
	v: int32 = 1;
	s: string = "a";
}

let b462X: int32 = 1;
let b462S: string = "s";
let b462I: int32 = 0;
let b462Obj = new B462Box();
const b462Arr: int32[] = [10, 20, 30];

async function b462Clobber(): Promise<int32> {
	b462X = 100;
	b462S = "S";
	b462I = 2;
	b462Arr[0] = 99;
	b462Obj = new B462Box();
	b462Obj.v = 50;
	b462Obj.s = "z";
	return 5;
}

function b462Pair(a: int32, b: int32): int32 {
	return a * 1000 + b;
}

async function b462Reads(): Promise<string> {
	b462X = 1;
	const v = b462X + await b462Clobber();
	b462Obj = new B462Box();
	const f = b462Obj.v + await b462Clobber();
	b462Arr[0] = 10;
	const e = b462Arr[0] + await b462Clobber();
	b462X = 1;
	const a = b462Pair(b462X, await b462Clobber());
	b462S = "s";
	const s = b462S + (await b462Clobber()).toString();
	b462X = 1;
	const after = (await b462Clobber()) + b462X;
	return `${v} ${f} ${e} ${a} ${s} ${after}`;
}

async function b462Stores(): Promise<string> {
	b462X = 1;
	b462X += await b462Clobber();
	b462Obj = new B462Box();
	const first = b462Obj;
	b462Obj.v += await b462Clobber();
	b462Obj = new B462Box();
	const second = b462Obj;
	second.s = "a";
	b462Obj.s += (await b462Clobber()).toString();
	b462Obj = new B462Box();
	const third = b462Obj;
	b462Obj.v = await b462Clobber();
	b462I = 0;
	b462Arr[0] = 10;
	b462Arr[2] = 30;
	b462Arr[b462I] += await b462Clobber();
	return `${b462X} ${first.v} ${second.s} ${third.v} ${b462Arr[0]} ${b462Arr[2]}`;
}

struct B462Pt {
	x: int32;
	y: int32;
}

async function b462Values(): Promise<string> {
	let p: B462Pt = { x: 5, y: 6 };
	p.x = await b462Clobber();
	p.y += await b462Clobber();
	const names: string[] = ["a"];
	names.push((await b462Clobber()).toString());
	return `${p.x} ${p.y} ${names.join(",")}`;
}

test "bug462: a read left of an await is read before it" {
	assert await b462Reads() == "6 6 15 1005 s5 105";
}

test "bug462: a store whose value awaits reads and names its target before it" {
	assert await b462Stores() == "100 6 a5 5 15 30";
}

test "bug462: a value struct and an array stay in place" {
	assert await b462Values() == "5 11 a,5";
}
