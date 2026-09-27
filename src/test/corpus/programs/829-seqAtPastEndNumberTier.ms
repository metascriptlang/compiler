// @xfail(raiser): raiser pop sets the length from a Float and stops with "ArraySetLen expected an integer length, got kind Float" before the index check
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
