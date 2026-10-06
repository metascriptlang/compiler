// @exit: 1
// @stdout: before
// @xfail(danger): --danger drops bound checks, so the out-of-range index is undefined behaviour there, not an index error
// @xfail(raiser): the raiser writes its uncaught-error report to a stderr its lane does not read, so its output cannot match C's merged stdout+stderr (sibling of 1021)
// note: an index out of bounds stops the program on every backend, inside a `try` and inside a `catch` without a binding too: no `catch` sees it and `after` never prints.
function read(xs: number[], i: int32): number {
	try {
		return xs[i];
	} catch {
		return -1;
	}
}

function main(): void {
	const xs: number[] = [1, 2, 3];
	console.log("before");
	try {
		console.log(`${read(xs, 5)}`);
	} catch (e) {
		console.log("caught");
	}
	console.log("after");
}

main();
