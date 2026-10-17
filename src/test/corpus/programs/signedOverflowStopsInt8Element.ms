// @exit: 1
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the step wraps in C instead of stopping
// @skip-raiser: the raiser stops with the same message but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms and src/codegen/raiser/eval.ms pin the raiser check
// @ledger-slack(int8_tArrayRefCell) 1
// note: `++` on an int8 element stops when the step leaves int8, where it wrapped to -128 before; a postfix step still reads the value before it.

function main(): void {
	const xs: int8[] = [-128, 127];
	xs[1]++;
	console.log("unreachable");
}

function bounds(): void {
	const xs: int8[] = [126];
	const before = xs[0]++;
	console.log(`kept ${before} ${xs[0]}`);
}

bounds();
main();
