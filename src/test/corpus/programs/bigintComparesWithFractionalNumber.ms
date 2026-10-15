// @stdout: nan false false false false false true | false false false false false true
// @stdout: inf true false false true | true true
// @stdout: frac true true true true false false | true true true true false
// @stdout: neg true true true true true | huge true true true | f32 true true
// @stdout: eq false true false true | false true false true
// @xfail(raiser): bigint is not supported on the Raiser VM
// note: a bigint compared with a fractional or non-finite number orders mathematically on C and JS (NaN unordered, Infinity beyond every bigint); C used to abort with exit 134.

function big(v: bigint): bigint { return v; }
function f64(v: float64): float64 { return v; }
function f32(v: float32): float32 { return v; }

function main(): void {
	const nan = f64(0.0) / f64(0.0);
	const inf = f64(1.0) / f64(0.0);
	const b = big(5n);
	console.log(`nan ${b < nan} ${b <= nan} ${b > nan} ${b >= nan} ${b == nan} ${b != nan} | ${nan < b} ${nan <= b} ${nan > b} ${nan >= b} ${nan == b} ${nan != b}`);
	console.log(`inf ${b < inf} ${b > inf} ${b < -inf} ${b > -inf} | ${inf > b} ${-inf < b}`);
	console.log(`frac ${b < f64(5.5)} ${b <= f64(5.5)} ${b > f64(4.5)} ${b >= f64(4.5)} ${b > f64(5.5)} ${b < f64(4.5)} | ${f64(5.5) > b} ${f64(5.5) >= b} ${f64(4.5) < b} ${f64(4.5) <= b} ${f64(5.5) < b}`);
	console.log(`neg ${big(-1n) < f64(-0.5)} ${big(-1n) > f64(-1.5)} ${big(0n) > f64(-0.5)} ${big(-2n) < f64(-1.5)} ${f64(-0.5) > big(-1n)} | huge ${big(10n) ** big(300n) < f64(1e301)} ${big(10n) ** big(300n) > f64(1e299)} ${-(big(10n) ** big(300n)) > -inf} | f32 ${b < f32(5.5)} ${b > f32(4.5)}`);
	console.log(`eq ${b == f64(5.5)} ${b != f64(5.5)} ${b == inf} ${b != -inf} | ${f64(5.5) == b} ${f64(5.5) != b} ${inf == b} ${-inf != b}`);
}

main();
