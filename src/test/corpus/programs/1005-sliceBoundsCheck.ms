// @exit: 1
// @stdout: Error: slice 1..9 out of bounds (length 4)
// @xfail(raiser): the Raiser VM reports the uncaught slice defect as its own 'raiser runtime error: slice ...' on stderr, not C's 'Error: slice ... out of bounds (length ...)'
// @xfail(danger): --danger drops bound checks, so the out-of-range slice is undefined behaviour there, not a slice error
function sum(xs: Span<int32>): int32 {
	let total = 0;
	for (let i = 0; i < xs.length; i++) total += xs[i];
	return total;
}

function run(): void {
	const dyn: int32[] = [1, 2, 3, 4];
	let fixed: int32[4] = [1, 2, 3, 4];
	let a = 1;
	let b = 3;
	console.log(`${sum(dyn[a..b])} ${sum(fixed[a...b])} ${sum(dyn[4..4])}`);
	let end = 9;
	console.log(`unreachable ${sum(dyn[a..end])}`);
}

run();
