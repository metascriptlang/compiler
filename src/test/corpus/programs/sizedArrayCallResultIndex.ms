// @stdout: 40 4 300 305 14
// note: indexing a sized array that a call returns reads the caller's result slot; direct, small element, alias, extension and closure calls. Before, the index read a C temporary that died inside the access (SAN lane: stack-use-after-scope; SBF printed garbage).
type Row = uint64[4];

function pick(i: int32): uint64[4] {
	let t: uint64[4] = [10, 20, 30, 40];
	t[0] = t[0] + (i as uint64);
	return t;
}

function small(i: int32): uint8[4] {
	let t: uint8[4] = [1, 2, 3, 4];
	t[0] = t[0] + (i as uint8);
	return t;
}

function row(i: int32): Row {
	return [i as uint64, 100, 200, 300];
}

function shifted(this r: Row, by: uint64): Row {
	return [r[0] + by, r[1] + by, r[2] + by, r[3] + by];
}

function main(): void {
	const viaClosure = (i: int32): uint64[4] => pick(i + 1);
	for (let i: int32 = 0; i < 4; i++) {
		console.log(pick(i)[i].toString() + " " + small(i)[i].toString() + " " + row(i)[i].toString() +
			" " + row(i).shifted(5)[i].toString() + " " + viaClosure(i)[3 - i].toString());
	}
}
main();
