// Parity program — JSON.stringify of an array whose element is a brand over an array is the array of
// arrays, as a brand at the top level or in a field already is.
// Axes: a uint8 and an int16 element base, a struct field holding the array, an array of structs
// holding the brand.
//
// @stdout: [[1,2],[3]]
// @stdout: [[-5,300]]
// @stdout: {"rows":[[9,8]],"n":1}
// @stdout: [{"data":[1]},{"data":[2,3]}]
// @exit: 0
type Bytes = uint8[] & { __brand: "Bytes" };
type Words = int16[] & { __brand: "Words" };

struct Row {
	data: Bytes;
}

struct Table {
	rows: Bytes[];
	n: int32;
}

const a: uint8[] = [1, 2];
const b: uint8[] = [3];
const xs: Bytes[] = [a as Bytes, b as Bytes];
console.log(JSON.stringify(xs));

const w: int16[] = [-5, 300];
const ws: Words[] = [w as Words];
console.log(JSON.stringify(ws));

const c: uint8[] = [9, 8];
const table: Table = { rows: [c as Bytes], n: 1 };
console.log(JSON.stringify(table));

const d: uint8[] = [1];
const e: uint8[] = [2, 3];
const rows: Row[] = [{ data: d as Bytes }, { data: e as Bytes }];
console.log(JSON.stringify(rows));
