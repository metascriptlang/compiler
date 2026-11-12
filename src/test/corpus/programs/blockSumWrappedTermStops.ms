// @exit: 1
// @stdout: start 1500
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the difference wraps instead of stopping
// @skip-raiser: the raiser stops with the same message but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms and src/codegen/raiser/eval.ms pin the raiser check
// note: a reduction whose term is a checked int32 difference runs it wrapped in the sticky block; 2147483647 - -2147483647
// wraps to -2, a small term the magnitude bound would take, so only the block's overflow bits send it to the checked
// rerun, which stops at that element.

function spread(xs: int32[], ys: int32[]): int32 {
	let t: int32 = 0;
	for (const k of xs.keys()) t += xs[k] - ys[k];
	return t;
}

const xs: int32[] = [];
const ys: int32[] = [];
for (let k: int32 = 0; k < 3000; k++) {
	xs.push(1 + k % 2);
	ys.push(1);
}
console.log(`start ${spread(xs, ys)}`);
xs[1500] = 2147483647;
ys[1500] = -2147483647;
console.log(spread(xs, ys));
console.log("unreachable");
