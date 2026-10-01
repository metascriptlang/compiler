// @xfail(raiser): != null yields 1 (NIM-REF CT-25, wt/nim-raiser 2adb86ea, not landed); struct == compares by reference on raiser (card 2026-09-29-raiser-struct-equality-by-reference)
// @stdout: arr=true,true,1,true,false,true,true box=true,true,4,true,false,true,true tup=true,true,a,true,false,true,true vec=true,true,1,7 field=true,false,true,late,true
// note: `T | null` whose payload is a fixed array, a tuple, a generic struct instance or a `Vec<T>` holds either a value or null: declared with a value or null, assigned null or a value, read after a null check, compared with `==` (payload by value, null only equals null), passed as an argument and returned; the same payloads as nullable struct fields. Same output on every backend.

struct Box<T> { v: T; }

struct H {
	k: uint8[4] | null;
	b: Box<string> | null;
	t: [int32, string] | null;
}

function arrEq(a: uint8[4] | null, b: uint8[4] | null): boolean { return a == b; }
function arrNull(a: uint8[4] | null): boolean { return a == null; }
function arrMake(present: boolean): uint8[4] | null { return present ? [1, 2, 3, 4] : null; }

function boxEq(a: Box<int32> | null, b: Box<int32> | null): boolean { return a == b; }
function boxNull(a: Box<int32> | null): boolean { return a == null; }
function boxMake(present: boolean): Box<int32> | null { return present ? { v: 4 } : null; }

function tupEq(a: [int32, string] | null, b: [int32, string] | null): boolean { return a == b; }
function tupNull(a: [int32, string] | null): boolean { return a == null; }
function tupMake(present: boolean): [int32, string] | null { return present ? [1, "a"] : null; }

function vecNull(a: Vec<int32> | null): boolean { return a == null; }
function vecMake(present: boolean): Vec<int32> | null {
	if (!present) return null;
	let v: Vec<int32> = [];
	v.push(7);
	return v;
}

function main(): void {
	let a: uint8[4] | null = null;
	const a0 = a == null;
	a = [1, 2, 3, 4];
	let aRead = 0 as uint8;
	if (a != null) { aRead = a[0]; }
	const arr = `${a0},${a != null},${aRead},${arrEq(a, [1, 2, 3, 4])},${arrEq(a, [1, 2, 3, 5])}`
		+ `,${arrNull(arrMake(false))},${arrEq(null, null)}`;

	let b: Box<int32> | null = null;
	const b0 = b == null;
	b = { v: 4 };
	let bRead: int32 = 0;
	if (b != null) { bRead = b.v; }
	const box = `${b0},${b != null},${bRead},${boxEq(b, { v: 4 })},${boxEq(b, { v: 5 })}`
		+ `,${boxNull(boxMake(false))},${boxEq(null, null)}`;

	let t: [int32, string] | null = null;
	const t0 = t == null;
	t = [1, "a"];
	let tRead = "";
	if (t != null) { tRead = t[1]; }
	const tup = `${t0},${t != null},${tRead},${tupEq(t, [1, "a"])},${tupEq(t, [1, "b"])}`
		+ `,${tupNull(tupMake(false))},${tupEq(null, null)}`;

	let v: Vec<int32> | null = null;
	const v0 = vecNull(v);
	v = vecMake(true);
	let vLen = 0;
	let vFirst: int32 = 0;
	if (v != null) {
		vLen = v.length;
		vFirst = v[0];
	}
	const vec = `${v0},${vecMake(false) == null},${vLen},${vFirst}`;

	const h1: H = { k: [1, 2, 3, 4], b: { v: "x" + "y" }, t: [1, "a" + "b"] };
	const h2: H = { k: [1, 2, 3, 4], b: { v: "xy" }, t: [1, "ab"] };
	let h3: H = { k: null, b: null, t: null };
	h3.b = { v: "la" + "te" };
	let late = "";
	if (h3.b != null) { late = h3.b.v; }
	h3.b = null;
	const field = `${h1 == h2},${h1 == h3},${h3.k == null},${late},${h3.b == null}`;

	console.log(`arr=${arr} box=${box} tup=${tup} vec=${vec} field=${field}`);
}

main();
