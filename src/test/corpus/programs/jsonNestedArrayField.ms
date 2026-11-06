// Parity program — a struct field whose type is an array of arrays, or a Vec, round-trips through
// JSON.stringify and JSON.parse<T> as node prints it, and a strict error names the element's
// full path.
// Axes: Vec<Vec<int64>> and int32[][] with an empty inner array, string[][], an array of arrays
// of structs, three levels deep, a Vec of structs and of strings; a wrong inner element, a
// non-array element, a wrong element of a struct inside the nesting and inside a Vec.
//
// @stdout: {"rows":[[1,2],[3]]}
// @stdout: {"rows":[[1,2],[3]]}
// @stdout: {"cells":[[],[7,-8]],"names":[["a"],["b","c"]]}
// @stdout: {"cells":[[],[7,-8]],"names":[["a"],["b","c"]]}
// @stdout: {"grid":[[{"id":1}],[{"id":2},{"id":3}]],"cube":[[[1],[2,3]],[[4]]]}
// @stdout: {"grid":[[{"id":1}],[{"id":2},{"id":3}]],"cube":[[[1],[2,3]],[[4]]]}
// @stdout: {"items":[{"id":1},{"id":2}],"tags":["a"]}
// @stdout: {"items":[{"id":1},{"id":2}],"tags":["a"]}
// @stdout: err=field 'rows[1][0]': expected int, got string
// @stdout: err=field 'rows[1]': expected array, got int
// @stdout: err=field 'grid[0][1].id': expected int, got boolean
// @stdout: err=field 'items[1].id': expected int, got string
// @exit: 0
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

const sample: Sample = { rows: [[1, 2], [3]] };
const sampleText = JSON.stringify(sample);
console.log(sampleText);
const sampleBack = JSON.parse<Sample>(sampleText);
console.log(sampleBack.ok ? JSON.stringify(sampleBack.value) : "err=" + sampleBack.error);

const mixed: Mixed = { cells: [[], [7, -8]], names: [["a"], ["b", "c"]] };
const mixedText = JSON.stringify(mixed);
console.log(mixedText);
const mixedBack = JSON.parse<Mixed>(mixedText);
console.log(mixedBack.ok ? JSON.stringify(mixedBack.value) : "err=" + mixedBack.error);

const deep: Deep = { grid: [[{ id: 1 }], [{ id: 2 }, { id: 3 }]], cube: [[[1], [2, 3]], [[4]]] };
const deepText = JSON.stringify(deep);
console.log(deepText);
const deepBack = JSON.parse<Deep>(deepText);
console.log(deepBack.ok ? JSON.stringify(deepBack.value) : "err=" + deepBack.error);

const bag: Bag = { items: [{ id: 1 }, { id: 2 }], tags: ["a"] };
const bagText = JSON.stringify(bag);
console.log(bagText);
const bagBack = JSON.parse<Bag>(bagText);
console.log(bagBack.ok ? JSON.stringify(bagBack.value) : "err=" + bagBack.error);

const wrongInner = JSON.parse<Sample>("{\"rows\":[[1],[\"x\"]]}");
console.log(wrongInner.ok ? "wrongInner ok — WRONG" : "err=" + wrongInner.error);
const notArray = JSON.parse<Sample>("{\"rows\":[[1],5]}");
console.log(notArray.ok ? "notArray ok — WRONG" : "err=" + notArray.error);
const wrongItem = JSON.parse<Deep>("{\"grid\":[[{\"id\":1},{\"id\":true}]],\"cube\":[]}");
console.log(wrongItem.ok ? "wrongItem ok — WRONG" : "err=" + wrongItem.error);
const wrongBagItem = JSON.parse<Bag>("{\"items\":[{\"id\":1},{\"id\":\"x\"}],\"tags\":[]}");
console.log(wrongBagItem.ok ? "wrongBagItem ok — WRONG" : "err=" + wrongBagItem.error);
