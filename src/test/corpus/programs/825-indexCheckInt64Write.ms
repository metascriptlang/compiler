// @exit: 1
// @xfail(raiser): the Raiser VM has no int64 index check; it stops with its own 'array index out of bounds: 4294967296 (length 3)'
// @xfail(danger): --danger drops bound checks, so the out-of-range index is undefined behaviour there, not an index error
// @xfail(js): node reports the uncaught index defect with its own trace on stderr, where C prints 'Error: index ... out of bounds (length ...)'; C also makes the defect fatal where JS lets it be caught
// @xfail(esm): node reports the uncaught index defect with its own trace on stderr, where C prints 'Error: index ... out of bounds (length ...)'; C also makes the defect fatal where JS lets it be caught
function run(): void {
	const a: int32[] = [10, 20, 30];
	let i: number = 4294967296;
	a[i] = 99;
	console.log(`unreachable ${a[0]}`);
}

run();
