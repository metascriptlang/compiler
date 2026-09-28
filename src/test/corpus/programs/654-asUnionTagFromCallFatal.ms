// @exit: 1
// @stdout: before text
// @skip-js: node exits 1 with the same "member 'string' is not accessible" line but wraps it in its own uncaught-error report, and parity compares merged stdout+stderr (sibling of 647)
// @xfail(raiser): the Raiser VM does not test union conversions
// @xfail(danger): --danger drops the tag test, so the read of the other member is undefined behaviour

function pick(n: number): number | string {
	if (n > 0) return n;
	return "text";
}

function main(): void {
	const a: string = pick(0) as string;
	console.log(`before ${a}`);
	const b: string = pick(1) as string;
	console.log(`after ${b}`);
}
main();
