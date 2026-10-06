// @exit: 1
// @stdout: before n
// @xfail(js): the JS stop names the held Row by typeof as 'object', where C names it 'Row'; the stop itself matches C
// @xfail(esm): same as js
// @xfail(danger): --danger drops the tag test, so the read of the other member is undefined behaviour
// @xfail(raiser): the Raiser VM does not test union conversions

class Row {
	v: int32;
	constructor(v: int32) { this.v = v; }
}

interface Named { name: string; }

function rowOrNamed(k: int32): Row | Named {
	if (k == 0) { const n: Named = { name: "n" }; return n; }
	return new Row(1);
}

function asNamed(k: int32): Named { return rowOrNamed(k) as Named; }

console.log(`before ${asNamed(0).name}`);
console.log(`after ${asNamed(1).name}`);
