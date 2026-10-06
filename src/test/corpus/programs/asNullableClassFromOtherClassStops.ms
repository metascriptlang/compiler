// @exit: 1
// @stdout: before 5
// @xfail(danger): --danger drops the tag test, so the read of the other member is undefined behaviour
// @xfail(raiser): the Raiser VM does not test union conversions

class Row {
	value: int32;
	constructor(value: int32) { this.value = value; }
}

class Other { tag: int32 = 5; }

function twoOf(k: int32): Row | Other {
	if (k == 0) return new Row(7);
	return new Other();
}

function twoNullable(k: int32): Other | null { return twoOf(k) as Other | null; }

function show(o: Other | null): string { return o == null ? "null" : `${o.tag}`; }

console.log(`before ${show(twoNullable(1))}`);
console.log(`after ${show(twoNullable(0))}`);
