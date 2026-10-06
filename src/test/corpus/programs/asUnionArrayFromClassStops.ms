// @exit: 1
// @stdout: before 2
// @xfail(js): the JS stop names the held Row by typeof as 'object', where C names it 'Row'; the stop itself matches C
// @xfail(esm): same as js
// @xfail(danger): --danger drops the tag test, so the read of the other member is undefined behaviour
// @xfail(raiser): the Raiser VM does not test union conversions

class Row {
	v: int32;
	constructor(v: int32) { this.v = v; }
}

function rowOrList(k: int32): Row | int32[] {
	if (k == 0) return [4, 5];
	return new Row(1);
}

function asList(k: int32): int32[] { return rowOrList(k) as int32[]; }

console.log(`before ${asList(0).length}`);
console.log(`after ${asList(1).length}`);
