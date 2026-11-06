// A checked mapped toArray fills its result through local spans and still stops at an overflowing element, as the
// loop through the heap cell does, instead of storing a wrapped value.
//
// @exit: 1
// @stdout: 2,4,6
// @stdout: over- or underflow
// @xfail(danger): --danger drops overflow checks, so the doubled element wraps there instead of raising
// @skip-js: JS numbers do not overflow at 2^31, so the doubled element is exact there

function doubled(a: int32[]): string {
	return a.values().map((x) => x * 2).toArray().join(",");
}

console.log(doubled([1, 2, 3]));
console.log(doubled([5, 1073741824, 7]));
