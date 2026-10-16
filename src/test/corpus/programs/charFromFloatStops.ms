// @exit: 1
// @stdout: value 300.7 not in range 0 .. 255
// @xfail(danger): --danger drops range checks, so the conversion wraps in C instead of stopping
// @skip-raiser: the raiser stops with the same range error but writes it to stderr, which the raiser lane does not read; src/codegen/raiser/eval.ms tests pin the raiser check
// note: a float converted to char truncates toward zero and stops when the result is outside 0 .. 255; -0.5 truncates to 0 and is kept.

function toChar(v: float64): char { return v as char; }

function main(): void {
	console.log(`kept=${toChar(-0.5) as int32},${toChar(255.9) as int32}`);
	console.log(toChar(300.7) as int32);
	console.log("unreachable");
}

main();
