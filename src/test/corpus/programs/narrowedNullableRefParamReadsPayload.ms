// @stdout: ternary=5 if=5 absent=-1 write=7/7 compound=8/8 string=5 int=5 borrow=5 field=9
// note: a `ref` or `Borrow` parameter typed `T | null` for a value `T` reads and writes its payload once narrowed, through a ternary or an `if`, for a struct, a string and an int. C read the field off the nullable carrier and clang refused the program.

struct Inner { n: int32; }
struct Holder { opt: Inner | null; }

function readTernary(ref x: Inner | null): int32 { return x == null ? -1 : x.n; }
function readIf(ref x: Inner | null): int32 { if (x != null) return x.n; return -1; }
function setField(ref x: Inner | null): int32 { if (x != null) { x.n = 7; return x.n; } return -1; }
function bumpField(ref x: Inner | null): int32 { if (x != null) { x.n += 1; return x.n; } return -1; }
function strLen(ref s: string | null): number { return s == null ? -1 : s.length; }
function incInt(ref v: int32 | null): int32 { return v == null ? -1 : v + 1; }
function readBorrow(x: Borrow<Inner | null>): int32 { return x == null ? -1 : x.n; }
function readHolder(ref h: Holder): int32 { return h.opt == null ? -1 : h.opt.n; }

function show(v: Inner | null): string { return v == null ? "null" : v.n.toString(); }

function run(): void {
	let b: Inner | null = { n: 5 };
	let none: Inner | null = null;
	const ternary = readTernary(b);
	const viaIf = readIf(b);
	const absent = readTernary(none);
	const written = setField(b);
	const writeLine = `write=${written}/${show(b)}`;
	const bumped = bumpField(b);
	const compoundLine = `compound=${bumped}/${show(b)}`;
	let s: string | null = "hello";
	let i: int32 | null = 4;
	let c: Inner | null = { n: 5 };
	let h: Holder = { opt: { n: 9 } };
	console.log(`ternary=${ternary} if=${viaIf} absent=${absent} ${writeLine} ${compoundLine} string=${strLen(s)} int=${incInt(i)} borrow=${readBorrow(c)} field=${readHolder(h)}`);
}

run();
