// @exit: 1
// @stdout: kept 0
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the char wraps in C instead of stopping
// @skip-raiser: the raiser stops with the same message but writes it to stderr, which the raiser lane does not read; src/codegen/raiser/eval.ms pins the raiser check
// note: `c--` read as a value on a char stops when the step leaves 0 .. 255 (below the range); a step onto the bound is kept.

function main(): void {
	let a = 1 as char;
	a--;
	console.log(`kept ${a as int32}`);
	let c = 0 as char;
	const before = c--;
	console.log(`after ${before as int32}`);
}

main();
