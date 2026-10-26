// @exit: 1
// @xfail(danger): --danger drops bound checks, so the out-of-range index is undefined behaviour there, not an index error
function run(): void {
	const a: int64[] = [10, 20, 30];
	const j: int64 = -4294967295 as int64;
	console.log(`unreachable ${a[j]}`);
}

run();
