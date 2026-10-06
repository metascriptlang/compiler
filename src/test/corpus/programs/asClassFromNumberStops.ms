// @exit: 1
// @stdout: before 7
// @xfail(danger): --danger drops the tag test, so the read of the other member is undefined behaviour
// @xfail(raiser): the Raiser VM does not test union conversions

class Row {
	value: int32;
	constructor(value: int32) { this.value = value; }
}

function plainOf(k: int32): number | Row {
	if (k == 0) return new Row(7);
	return 9;
}

function plainPlain(k: int32): Row { return plainOf(k) as Row; }

console.log(`before ${plainPlain(0).value}`);
console.log(`after ${plainPlain(1).value}`);
