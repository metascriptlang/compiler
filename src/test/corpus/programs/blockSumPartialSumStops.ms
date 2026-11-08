// A checked reduction whose running sum leaves int32 inside a block stops at that step, though the block's
// total fits.
//
// @exit: 1
// @stdout: start
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the sum wraps back into range instead of stopping
// @skip-raiser: the raiser stops with the same message but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms and src/codegen/raiser/eval.ms pin the raiser check

function keysSum(xs: int32[]): int32 {
	let total: int32 = 0;
	for (const k of xs.keys()) total += xs[k];
	return total;
}

const big: int32 = 1073741824;
const xs: int32[] = [1, big, big, big, -big, -big, -big];
console.log("start");
console.log(keysSum(xs));
