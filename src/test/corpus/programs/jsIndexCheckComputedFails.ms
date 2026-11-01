// @exit: 1
// @stdout: before 1
// @stdout: Error: index 5 out of bounds (length 4)
// @xfail(danger): --danger drops bound checks, so the out-of-range index is undefined behaviour there, not an index error
// note: a computed index past the end of a span fails with the same message and length as a plain one, after the index ran once.
let calls = 0;

function next(): int32 {
	calls++;
	return 4;
}

function main(): void {
	const base: int32[] = [10, 20, 30, 40, 50, 60];
	const s: Span<int32> = base[1..5];
	console.log(`before ${calls + 1}`);
	s[next() + 1] += 3;
	console.log(`unreachable ${calls}`);
}

main();
