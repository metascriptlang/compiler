// @exit: 1
// @stdout: sum 1498002000
// @stdout: drain -1498002000
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the int32 term wraps instead of stopping
// @skip-raiser: the raiser stops with the same message but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms and src/codegen/raiser/eval.ms pin the raiser check
// note: an entries() reduction `s += x + (k & 1)` sums through range-guarded blocks of 1024, then stops where one
// term passes MAX inside a block whose other terms all fit.

function sum(xs: int32[]): int32 {
	let s: int32 = 0;
	for (const [k, x] of xs.entries()) s += x + ((k as int32) & 1);
	return s;
}

function drain(xs: int32[]): int32 {
	let s: int32 = 0;
	for (const [k, x] of xs.entries()) s -= x + ((k as int32) & 1);
	return s;
}

function main(): void {
	const xs: int32[] = [];
	for (let i: int32 = 0; i < 3000; i++) xs.push(i * 333 % 1000000);
	console.log(`sum ${sum(xs)}`);
	console.log(`drain ${drain(xs)}`);
	xs[2049] = 2147483647;
	console.log(sum(xs));
	console.log("unreachable");
}

main();
