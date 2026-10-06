// @stdout: runtime=555 const=555 module=555 tilde=66 tildeConst=66 float=0.5 narrow=-4 literal=-7 negFloat=-2.5
// note: a user unary operator on a built-in type runs like the binary ones: on a run-time value, on constants in a function and at module level, for `~` on int64 and `-` on float64; `int8` keeps the built-in beside a `-`(int32) that needs a conversion, and a negative literal stays a literal.
function `-`(this a: int32): int32 { return 555; }
function `~`(this a: int64): int64 { return 66; }
function `-`(this a: float64): float64 { return 0.5; }
const A: int32 = 10;
const N = -A;
function run(r: int32, w: int64, f: float64, s: int8): void {
	const a: int32 = 10;
	const k: int64 = 3;
	console.log(`runtime=${-r} const=${-a} module=${N} tilde=${~w} tildeConst=${~k} float=${-f} narrow=${-s} literal=${-7} negFloat=${-2.5}`);
}
run(10, 3, 2.0, 4);
