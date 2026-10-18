// @exit: 1
// @stdout: before -100
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the int8 difference wraps instead of stopping
// @skip-raiser: the raiser stops with the same message but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms and src/codegen/raiser/eval.ms pin the raiser check
// note: an int8 `-=` reduction stops at the first element of the second block of 1024, where it passes MIN.

function drain(xs: int8[], n: int32): int8 {
	let s: int8 = 0;
	for (let i = 0; i < n; i++) s -= xs[i];
	return s;
}

function main(): void {
	const xs: int8[] = [];
	for (let i = 0; i < 1100; i++) xs.push(0 as int8);
	xs[1023] = 100;
	xs[1024] = 100;
	console.log(`before ${drain(xs, 1024)}`);
	console.log(drain(xs, xs.length));
	console.log("unreachable");
}

main();
