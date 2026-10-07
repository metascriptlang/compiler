// @xfail(raiser): raiser reports the index error in its own words ("array index out of bounds: -1 (length 0)")
// @exit: 1
// @stdout: index -1 out of bounds (length 0)
function run(): void {
	const a: int32[] = [1];
	const x = a.pop();
	console.log(`popped ${x} len=${a.length}`);
	const y = a.pop();
	console.log(`unreachable ${y} len=${a.length}`);
}

run();
