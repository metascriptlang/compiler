// @stdout: const=5999,5998,5997,5996,5995,5994,true,true,false,false,true,true run=5999,5998,5997,5996,5995,5994,true,true,false,false,true,true module=5999,5998,5997,5996,5995,5994,true,true,false,false,true,true init=5997,true box=12
// note: a declared operator on built-in operands is called for every overloadable binary operator — bitwise, shifts, comparisons — whether the operands are constants, run-time values, module constants or a module-level initializer; a declared bitwise operator on a struct is called too.

struct Box {
	v: int32;
}

function `&`(this a: int32, b: int32): int32 { return a * 1000 - 1; }
function `|`(this a: int32, b: int32): int32 { return a * 1000 - 2; }
function `^`(this a: int32, b: int32): int32 { return a * 1000 - 3; }
function `<<`(this a: int32, b: int32): int32 { return a * 1000 - 4; }
function `>>`(this a: int32, b: int32): int32 { return a * 1000 - 5; }
function `>>>`(this a: int32, b: int32): int32 { return a * 1000 - 6; }
function `<`(this a: int32, b: int32): boolean { return true; }
function `<=`(this a: int32, b: int32): boolean { return true; }
function `>`(this a: int32, b: int32): boolean { return false; }
function `>=`(this a: int32, b: int32): boolean { return false; }
function `==`(this a: int32, b: int32): boolean { return true; }
function `!=`(this a: int32, b: int32): boolean { return true; }
function `|`(this a: Box, b: Box): Box { return { v: a.v * 10 + b.v }; }

const A: int32 = 6;
const B: int32 = 3;
const MX = A ^ B;
const ML = A < B;

function row(and: int32, or: int32, xor: int32, shl: int32, shr: int32, ushr: int32, lt: boolean, le: boolean, gt: boolean, ge: boolean, eq: boolean, ne: boolean): string {
	return [and.toString(), or.toString(), xor.toString(), shl.toString(), shr.toString(), ushr.toString(), lt.toString(), le.toString(), gt.toString(), ge.toString(), eq.toString(), ne.toString()].join(",");
}

function run(c: int32, d: int32): void {
	const a: int32 = 6;
	const b: int32 = 3;
	const k = row(a & b, a | b, a ^ b, a << b, a >> b, a >>> b, a < b, a <= b, a > b, a >= b, a == b, a != b);
	const r = row(c & d, c | d, c ^ d, c << d, c >> d, c >>> d, c < d, c <= d, c > d, c >= d, c == d, c != d);
	const m = row(A & B, A | B, A ^ B, A << B, A >> B, A >>> B, A < B, A <= B, A > B, A >= B, A == B, A != B);
	const p: Box = { v: 1 };
	const q: Box = { v: 2 };
	const box = p | q;
	console.log(`const=${k} run=${r} module=${m} init=${MX},${ML} box=${box.v}`);
}
run(6, 3);
