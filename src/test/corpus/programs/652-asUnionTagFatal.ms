// @exit: 1
// @stdout: before center
// @skip-js: node exits 1 with its own report of the failed conversion on stderr, and parity compares merged stdout+stderr (sibling of 647)
// @xfail(raiser): the Raiser VM does not test union conversions
// @xfail(danger): --danger drops the tag test, so the read of the other member is undefined behaviour

function textOf(u: number | string): string {
	return u as string;
}

function main(): void {
	console.log(`before ${textOf("center")}`);
	console.log(`after ${textOf(7)}`);
}
main();
