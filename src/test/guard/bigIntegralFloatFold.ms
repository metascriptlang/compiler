// nim-guard: an integral-valued double past 2^53 stays a FLOAT literal
//
// INVARIANT: makeNumber (transform/util.ms) must classify a folded constant by
//   MAGNITUDE as well as fractional part. `val % 1 !== 0` asks "has a fractional
//   part", not "fits an integer" — 1e30 has no fractional part and does not fit
//   int64, so the integer branch ran `val as int64`, which is undefined. The
//   2^53 boundary is already stated one function below, on makeIntNumber.
//
// WHAT IT CATCHES: the compiler trapping while folding the +-1e30 sentinel pair
//   void uses for content bounds (void2d/types.ms:173) — RED is a compiler
//   crash during the build, not a wrong answer at runtime.

type Bounds = { xMin: number, yMin: number, xMax: number, yMax: number };

function main(): void {
	const b: Bounds = { xMin: 1e30, yMin: 1e30, xMax: -1e30, yMax: -1e30 };
	console.log(b.xMin);
	console.log(b.xMax);
	if (!(b.xMax < -1e29)) { throw "GUARD RED: -1e30 sentinel did not survive folding"; }
	if (!(b.xMin > 1e29)) { throw "GUARD RED: 1e30 sentinel did not survive folding"; }
	console.log("bigIntegralFloatFold ok");
}
main();
