// @xfail(raiser): raiser reports the index error in its own words ("array index out of bounds: 3 (length 3)")
// @exit: 1
// @stdout: index 3 out of bounds (length 3)
// @skip-js: node reports the uncaught index error with its own stack trace; exit code matches but the text differs (sibling of 721)
function run(): void {
	const a: number[] = [1.5, 2.5, 3.5, 4.5];
	a.pop();
	console.log(`last=${a.at(-1)} len=${a.length}`);
	console.log(`unreachable ${a.at(3)}`);
}

run();
