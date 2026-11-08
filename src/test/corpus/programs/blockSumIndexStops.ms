// A checked reduction whose term reads past the array stops at that read with the index and the length.
//
// @exit: 1
// @stdout: start
// @stdout: index 5 out of bounds (length 5)
// @xfail(danger): --danger drops the bound check on C, so the read past the array is not caught

function shifted(xs: int32[]): int32 {
	let total: int32 = 0;
	const n: int32 = xs.length;
	for (let i: int32 = 0; i < n; i++) total += xs[i + 1];
	return total;
}

console.log("start");
console.log(shifted([1, 2, 3, 4, 5]));
