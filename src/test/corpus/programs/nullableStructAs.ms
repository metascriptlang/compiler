// Parity program — `as` takes a nullable value struct to its payload: a map
// read, a nullable parameter and a map read inside a generic class.
//
// @stdout: 3 3 4 7
// @exit: 0

struct Cell {
	index: int32;
	length: number;
}

class Store<K> {
	cells: Map<K, Cell> = new Map<K, Cell>();
	at(key: K): Cell { return this.cells.get(key) as Cell; }
}

function payload(c: Cell | null): Cell { return c as Cell; }

const m = new Map<string, Cell>();
m.set("a", { index: 3, length: 1 });
const got = m.get("a") as Cell;
const s = new Store<string>();
s.cells.set("b", { index: 4, length: 7 });
console.log(`${got.index} ${payload(got).index} ${s.at("b").index} ${s.at("b").length}`);
