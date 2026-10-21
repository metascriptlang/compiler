// @stdout: fn struct=7/true string=set/true int=42/true iface=4/true | module struct=7/true string=set/true int=42/true iface=4/true | field=8/true/set elem=9/true forward=7/true out=11 inPlace=2/1
// note: a `ref` or `out` parameter typed `T | null` writes the caller's variable, field or element, whether the old or the new value is null, for a struct, a string, an int and an interface. The Raiser VM passed the held value instead of the caller's location, so a write that set or cleared the optional stayed in the callee.

struct Inner { n: int32; }
interface P { x: int32; }
struct Holder { opt: Inner | null; s: string | null; }

function setI(ref x: Inner | null, n: int32): void { x = { n: n }; }
function clearI(ref x: Inner | null): void { x = null; }
function setS(ref v: string | null): void { v = "set"; }
function clearS(ref v: string | null): void { v = null; }
function setN(ref v: int32 | null): void { v = 42; }
function clearN(ref v: int32 | null): void { v = null; }
function setP(ref p: P | null): void { p = { x: 4 }; }
function clearP(ref p: P | null): void { p = null; }
function forwardI(ref x: Inner | null): void { setI(x, 7); }
function forwardClear(ref x: Inner | null): void { clearI(x); }
function fill(out x: Inner | null): void { x = { n: 11 }; }

function showI(v: Inner | null): string { return v == null ? "null" : v.n.toString(); }
function showS(v: string | null): string { return v == null ? "null" : v; }
function showN(v: int32 | null): string { return v == null ? "null" : v.toString(); }
function showP(v: P | null): string { return v == null ? "null" : v.x.toString(); }

function inFunction(): string {
	let b: Inner | null = null;
	setI(b, 7);
	const struct1 = showI(b);
	clearI(b);
	let s: string | null = null;
	setS(s);
	const string1 = showS(s);
	clearS(s);
	let n: int32 | null = null;
	setN(n);
	const int1 = showN(n);
	clearN(n);
	let p: P | null = null;
	setP(p);
	const iface1 = showP(p);
	clearP(p);
	return "fn struct=" + struct1 + "/" + String(b == null) + " string=" + string1 + "/" + String(s == null)
		+ " int=" + int1 + "/" + String(n == null) + " iface=" + iface1 + "/" + String(p == null);
}

let mb: Inner | null = null;
setI(mb, 7);
const mStruct = showI(mb);
clearI(mb);
let ms: string | null = null;
setS(ms);
const mString = showS(ms);
clearS(ms);
let mn: int32 | null = null;
setN(mn);
const mInt = showN(mn);
clearN(mn);
let mp: P | null = null;
setP(mp);
const mIface = showP(mp);
clearP(mp);
const atModule = "module struct=" + mStruct + "/" + String(mb == null) + " string=" + mString + "/" + String(ms == null)
	+ " int=" + mInt + "/" + String(mn == null) + " iface=" + mIface + "/" + String(mp == null);

function paths(): string {
	let h: Holder = { opt: null, s: null };
	setI(h.opt, 8);
	const field1 = showI(h.opt);
	setS(h.s);
	let k: Holder = { opt: { n: 1 }, s: null };
	clearI(k.opt);
	const arr: (Inner | null)[] = [null, { n: 2 }];
	setI(arr[0], 9);
	clearI(arr[1]);
	let f: Inner | null = null;
	forwardI(f);
	const forward1 = showI(f);
	forwardClear(f);
	let o: Inner | null = null;
	fill(o);
	let held: Inner | null = { n: 1 };
	const copy = held;
	setI(held, 2);
	return "field=" + field1 + "/" + String(k.opt == null) + "/" + showS(h.s)
		+ " elem=" + showI(arr[0]) + "/" + String(arr[1] == null)
		+ " forward=" + forward1 + "/" + String(f == null) + " out=" + showI(o)
		+ " inPlace=" + showI(held) + "/" + showI(copy);
}

console.log(inFunction() + " | " + atModule + " | " + paths());
