// @exit: 1
// @stdout: before 7
// @xfail(danger): --danger drops the tag test, so the read of the other member is undefined behaviour
// @xfail(raiser): the Raiser VM does not test union conversions

class Row {
	value: int32;
	constructor(value: int32) { this.value = value; }
}

function carriedOf(k: int32): number | Row | null {
	if (k == 0) return new Row(7);
	if (k == 1) return null;
	return 9;
}

function carriedPlain(k: int32): Row { return carriedOf(k) as Row; }

console.log(`before ${carriedPlain(0).value}`);
console.log(`after ${carriedPlain(2).value}`);
