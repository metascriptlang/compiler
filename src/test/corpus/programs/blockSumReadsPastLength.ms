// @exit: 1
// @stdout: start 2
// @stdout: Error: index 3 out of bounds (length 3)
// @xfail(danger): --danger drops bound checks, so the read past the end is undefined behaviour there, not an index error
// @skip-raiser: the raiser stops with the same message but writes it to stderr, which the raiser lane does not read; src/raiser/vm.ms pins the raiser bound check
// note: a sticky block whose bound is not the array's length checks the array covers the block before it runs; a
// block the array does not cover runs only the checked loop, which stops at the first index past the end, so the
// SAN cell sees no read past the array.

function odd(xs: int32[], n: int32): int32 {
	let t: int32 = 0;
	for (let i = 0; i < n; i++) t += xs[i] & 1;
	return t;
}

console.log(`start ${odd([1, 2, 3], 3)}`);
console.log(odd([1, 2, 3], 2000));
console.log("unreachable");
