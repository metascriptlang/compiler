// @exit: 1
// @skip-js: JS arrays have no bounds check; a[2^32] = v stores a property and exits 0
function run(): void {
	const a: int32[] = [10, 20, 30];
	let i: number = 4294967296;
	a[i] = 99;
	console.log(`unreachable ${a[0]}`);
}

run();
