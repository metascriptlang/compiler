// @xfail(raiser): raiser reports the index error in its own words ("array index out of bounds: -1 (length 0)")
// @exit: 1
// @stdout: index -1 out of bounds (length 0)
function run(): void {
	const a: string[] = [];
	console.log(`len=${a.length}`);
	const s = a.pop();
	console.log(`unreachable '${s}'`);
}

run();
