// @exit: 1
// @stdout: small 6
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the sum wraps back into range instead of stopping
// @skip-raiser: the raiser stops with the same message but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms and src/codegen/raiser/eval.ms pin the raiser check
// note: a reduction whose running sum leaves int32 and comes back stops at the step that leaves, though the total would fit.

function sum(xs: int32[]): int32 {
	let s: int32 = 0;
	for (const x of xs) s += x;
	return s;
}

function main(): void {
	console.log(`small ${sum([1, 2, 3])}`);
	console.log(sum([2147483647, 1, -5, -5]));
	console.log("unreachable");
}

main();
