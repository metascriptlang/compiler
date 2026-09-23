// @xfail(raiser): raiser runtime error: cannot compile node kind BigIntLiteral at comptime: unsupported by the Raiser bytecode compiler
// Parity program — a generic body sees the real width of its bound type. A
// type argument inferred from an enum MEMBER, a named distinct, or a bigint
// each has to spell itself back into the substituted annotation; any of them
// degrading to `unknown` used to fold silently to zero.
//
// @stdout: 4|1|8|4|4|8|4
// @exit: 0

type MyId = distinct int32;
enum E { A, B, C }

function width<T>(v: T): int32 { return sizeof(T); }
function widthOfLocal<T>(v: T): int32 { const x: T = v; return sizeof(T); }

const e: E = E.A;
const parts: string[] = [
	width(1 as int32).toString(),
	width(1 as uint8).toString(),
	width(2.5 as float64).toString(),
	width(e).toString(),
	width(E.A).toString(),
	width(1n).toString(),
	widthOfLocal(E.A).toString(),
];
console.log(parts.join("|"));
