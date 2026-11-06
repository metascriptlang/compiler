// @exit: 1
// @stdout: 4096 -6 2147483646 -2147483648 -6
// @stdout: over- or underflow
// @xfail(danger): --danger drops the overflow check on C, so the doubled element wraps instead of stopping
// @skip-js: JS numbers do not overflow at 2^31, so the doubled element is exact there
// @skip-raiser: the raiser stops with the same message but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms and src/codegen/raiser/eval.ms pin the raiser check
// note: a mapped toArray `x * 2` stores through range-guarded blocks of 1024, keeps the exact values at both ends of
// the range, then stops where one element passes MAX / 2 inside a block whose other elements all fit.

function doubled(xs: int32[]): int32[] {
	return xs.values().map((x) => x * 2).toArray();
}

const xs: int32[] = [];
for (let i: int32 = 0; i < 4096; i++) xs.push((i % 7) - 3);
xs[5] = 1073741823;
xs[1500] = -1073741824;
const a = doubled(xs);
console.log(a.length, a[0], a[5], a[1500], a[4095]);
xs[3000] = 1073741824;
const b = doubled(xs);
console.log("unreachable", b.length);
