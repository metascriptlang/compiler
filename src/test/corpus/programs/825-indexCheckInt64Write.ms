// @exit: 1
// @xfail(raiser): the Raiser VM reports the uncaught index defect as its own 'raiser runtime error: array index out of bounds: 4294967296 (length 3)' on stderr, not C's 'Error: index ... out of bounds (length ...)'
// @xfail(danger): --danger drops bound checks, so the out-of-range index is undefined behaviour there, not an index error
function run(): void {
	const a: int32[] = [10, 20, 30];
	let i: number = 4294967296;
	a[i] = 99;
	console.log(`unreachable ${a[0]}`);
}

run();
