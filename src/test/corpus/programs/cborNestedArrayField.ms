// @stdout: nested-array-cbor all-ok
// note: a struct field whose type is an array of arrays, or a Vec, round-trips through cborEncode
// and cborValueToStruct: Vec<Vec<int64>>, int32[][] with an empty inner array, string[][], an array
// of arrays of structs, three levels deep, a Vec of structs and of strings.
import { cborEncode, decode, cborValueToStruct, cborInt } from "std/serialize/cbor";

struct Sample {
	rows: Vec<Vec<int64>>;
}

struct Mixed {
	cells: int32[][];
	names: string[][];
}

struct Item {
	id: int64;
}

struct Bag {
	items: Vec<Item>;
	tags: Vec<string>;
}

struct Deep {
	grid: Item[][];
	cube: int64[][][];
}

let failures = 0;
function check(name: string, ok: boolean): void {
	if (!ok) {
		console.log("FAIL " + name);
		failures = failures + 1;
	}
}

const sample: Sample = { rows: [[1, 2], [3]] };
const rs = decode(cborEncode(sample));
const qs: Sample = cborValueToStruct(rs.ok ? rs.value : cborInt(0), null as Sample | null);
check("vec of vec", rs.ok && qs.rows.length == 2 && qs.rows[0].length == 2 && qs.rows[0][1] == 2 && qs.rows[1][0] == 3);

const mixed: Mixed = { cells: [[], [7, -8]], names: [["a"], ["b", "c"]] };
const rm = decode(cborEncode(mixed));
const qm: Mixed = cborValueToStruct(rm.ok ? rm.value : cborInt(0), null as Mixed | null);
check("int32 and string", rm.ok && qm.cells[0].length == 0 && qm.cells[1][1] == -8 && qm.names[1][1] == "c");

const deep: Deep = { grid: [[{ id: 1 }], [{ id: 2 }, { id: 3 }]], cube: [[[1], [2, 3]], [[4]]] };
const rd = decode(cborEncode(deep));
const qd: Deep = cborValueToStruct(rd.ok ? rd.value : cborInt(0), null as Deep | null);
check("structs and three levels", rd.ok && qd.grid[1][1].id == 3 && qd.cube[0][1][1] == 3 && qd.cube[1][0][0] == 4);

const bag: Bag = { items: [{ id: 1 }, { id: 2 }], tags: ["a"] };
const rb = decode(cborEncode(bag));
const qb: Bag = cborValueToStruct(rb.ok ? rb.value : cborInt(0), null as Bag | null);
check("vec of structs and strings", rb.ok && qb.items.length == 2 && qb.items[1].id == 2 && qb.tags[0] == "a");

if (failures == 0) {
	console.log("nested-array-cbor all-ok");
}
