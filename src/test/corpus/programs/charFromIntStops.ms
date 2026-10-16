// @exit: 1
// @stdout: value 300 not in range 0 .. 255
// @xfail(danger): --danger drops range checks, so the conversion wraps in C instead of stopping
// @skip-raiser: the raiser stops with the same range error but writes it to stderr, which the raiser lane does not read; src/codegen/raiser/eval.ms tests pin the raiser check
// note: an integer converted to char stops outside 0 .. 255 instead of wrapping, the same on every backend.

function toChar(v: int32): char { return v as char; }

function main(): void {
	console.log(`kept=${toChar(0) as int32},${toChar(255) as int32}`);
	console.log(toChar(300) as int32);
	console.log("unreachable");
}

main();
