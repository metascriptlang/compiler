// A reduction whose term's outermost checked add is tested on the block's min and max sums terms of both signs,
// and stops with that add's error when one element overflows it.
//
// @exit: 1
// @stdout: 2994
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the add wraps instead of stopping
// @skip-raiser: the raiser stops with the same message but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms and src/codegen/raiser/eval.ms pin the raiser check

function bumped(xs: int32[]): int32 {
	let total: int32 = 0;
	for (let i: int32 = 0; i < xs.length; i++) total += xs[i] + 1;
	return total;
}

const xs: int32[] = [];
for (let k: int32 = 0; k < 3000; k++) xs.push((k % 7) - 3);
console.log(bumped(xs));
xs[2500] = 2147483647;
console.log(bumped(xs));
