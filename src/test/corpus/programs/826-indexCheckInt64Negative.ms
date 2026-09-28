// @exit: 1
// @skip-js: JS arrays have no bounds check; a negative index reads undefined and exits 0
// @xfail(raiser): the Raiser VM has no int64 index check; it stops with its own 'array index out of bounds: -4294967295 (length 3)'
// @xfail(danger): --danger drops bound checks, so the out-of-range index is undefined behaviour there, not an index error
function run(): void {
	const a: int64[] = [10, 20, 30];
	const j: int64 = -4294967295 as int64;
	console.log(`unreachable ${a[j]}`);
}

run();
