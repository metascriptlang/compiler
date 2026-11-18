// @stdout: vec 5 b
// @stdout: struct 6 1 7
// @stdout: int 5
// @stdout: nullable 3 c 2 0
// @stdout: field 2 2 z
// @stdout: closure 2
// @stdout: async 2 2
// note: `v!` and a cast to the operand's own type name the operand's storage, so a write through one (a `this ref` receiver, a `ref` or `out` argument, a built-in mutator, an assignment, `+=`, `++`) reaches the variable. Same output on every lane.
struct Inner { columns: Vec<string>; n: int32; }
class Keep { items: Vec<string> = []; m: Inner | null = null; }

function grow(this ref v: Vec<string>): void { v.push("x"); }
function bump(this ref i: Inner): void { i.n = i.n + 1; }
function growArg(ref v: Vec<string>): void { v.push("x"); }
function bumpArg(ref i: Inner): void { i.n = i.n + 1; }
function inc(ref x: int32): void { x = x + 1; }
function reset(out i: Inner): void { i = { columns: [], n: 7 }; }
function mkI(): Inner { return { columns: [], n: 0 }; }

function vecs(): void {
	let v: Vec<string> = [];
	v!.grow();
	(v as Vec<string>).grow();
	growArg(v!);
	growArg(v as Vec<string>);
	v!.push("y");
	const len = v.length;
	v! = ["a"];
	(v as Vec<string>) = ["b"];
	console.log(`vec ${len} ${v[0]}`);
}

function structs(): void {
	let s: Inner = mkI();
	s!.bump();
	(s as Inner).bump();
	bumpArg(s!);
	bumpArg(s as Inner);
	s!.n += 1;
	s!.n++;
	s.columns!.grow();
	const n = s.n;
	const cols = s.columns.length;
	reset(out s!);
	console.log(`struct ${n} ${cols} ${s.n}`);
}

function ints(): void {
	let c: int32 = 0;
	inc(c!);
	inc(c as int32);
	c! += 2;
	c!++;
	console.log(`int ${c}`);
}

function nullables(): void {
	let n: Vec<string> | null = [];
	n!.grow();
	growArg(n!);
	n!.push("y");
	const len = n!.length;
	n! = ["c"];
	let ns: Inner | null = mkI();
	ns!.bump();
	bumpArg(ns!);
	const bumped = ns!.n;
	ns! = mkI();
	console.log(`nullable ${len} ${n![0]} ${bumped} ${ns!.n}`);
}

function fields(): void {
	const k = new Keep();
	k.items!.grow();
	growArg(k.items!);
	k.items![0] = "z";
	k.m = mkI();
	k.m!.bump();
	bumpArg(k.m!);
	console.log(`field ${k.items.length} ${k.m!.n} ${k.items[0]}`);
}

function closures(): void {
	let v: Vec<string> = [];
	const f = (): void => { v!.grow(); (v as Vec<string>).grow(); };
	f();
	console.log(`closure ${v.length}`);
}

async function later(): Promise<void> {
	let v: Vec<string> = [];
	let s: Inner = mkI();
	await Promise.resolve();
	v!.grow();
	(v as Vec<string>).grow();
	s!.bump();
	bumpArg(s as Inner);
	console.log(`async ${v.length} ${s.n}`);
}

vecs();
structs();
ints();
nullables();
fields();
closures();
later();
