// A checked mapped toArray whose term is not affine fills its result through local spans with every check kept, and
// still stops at an overflowing element, as the loop through the heap cell does, instead of storing a wrapped value.
//
// @exit: 1
// @stdout: 3 1 4 9
// @stdout: over- or underflow
// @xfail(danger): --danger drops overflow checks, so the squared element wraps there instead of raising
// @skip-js: JS numbers do not overflow at 2^31, so the squared element is exact there

function squared(a: int32[]): int32[] {
	return a.values().map((x) => x * x).toArray();
}

const small: int32[] = [1, 2, 3];
const large: int32[] = [5, 46341, 7];
const a = squared(small);
console.log(a.length, a[0], a[1], a[2]);
const b = squared(large);
console.log("unreachable", b.length);
