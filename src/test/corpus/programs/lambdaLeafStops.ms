// @exit: 1
// @stdout: start 2,4,6
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the product wraps instead of stopping
// @skip-raiser: the raiser stops with the same message but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms and src/codegen/raiser/eval.ms pin the raiser check
// note: a map callback that is a pure leaf arrow runs inline in the store loop and still stops at the element
// whose checked product overflows.

function doubled(xs: int32[]): int32[] {
	return xs.values().map((x) => x * 2).toArray();
}

console.log(`start ${doubled([1, 2, 3]).join(",")}`);
const big: int32[] = [];
for (let k: int32 = 0; k < 3000; k++) big.push(k);
big[1500] = 1073741824;
console.log(doubled(big).length);
console.log("unreachable");
