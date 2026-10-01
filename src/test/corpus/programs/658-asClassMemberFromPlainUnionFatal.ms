// @exit: 1
// @stdout: before row:7
// @skip-js: node exits 1 with the same "member 'Row' is not accessible" line but wraps it in its own uncaught-error report, and parity compares merged stdout+stderr (sibling of 647)
// @xfail(raiser): the Raiser VM does not test union conversions
// @xfail(danger): --danger drops the tag test, so the read of the other member is undefined behaviour

class Row {
	value: int32;
	constructor(value: int32) { this.value = value; }
}

function pick(k: int32): number | Row {
	if (k == 0) return new Row(7);
	return 9;
}

function rowOf(k: int32): Row | null {
	return pick(k) as Row | null;
}

function show(r: Row | null): string {
	return r == null ? "null" : `row:${r.value}`;
}

function main(): void {
	console.log(`before ${show(rowOf(0))}`);
	console.log(`after ${rowOf(1) == null ? "null" : "accepted"}`);
}
main();
