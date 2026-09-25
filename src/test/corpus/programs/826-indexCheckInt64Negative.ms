// @exit: 1
// @skip-js: JS arrays have no bounds check; a negative index reads undefined and exits 0
function run(): void {
	const a: int64[] = [10, 20, 30];
	const j: int64 = -4294967295 as int64;
	console.log(`unreachable ${a[j]}`);
}

run();
