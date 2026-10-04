// @stdout: cell=9 twice=14 slot=7
// note: `at[]` in a generic body is the pointee of each instance: a generic function, a generic called from a generic, a generic class method, and a scalar instance that is only compiled.

struct Cell { a: uint64; b: uint64; }

function readThrough<T>(at: Ptr<T>): T {
	return at[];
}

function readTwice<T>(at: Ptr<T>, f: (value: T) => uint64): uint64 {
	const value: T = at[];
	return f(value) + f(readThrough<T>(at));
}

function wordAt(address: uint64): uint64 {
	return readThrough<uint64>(address as Ptr<uint64>);
}

class Slot<T> {
	at: Ptr<T>;
	constructor(at: Ptr<T>) { this.at = at; }
	read(): T { return this.at[]; }
}

let cells: Cell[1] = [{ a: 7, b: 9 }];
const cell = readThrough<Cell>(cells[0] as Ptr<Cell>);
const twice = readTwice<Cell>(cells[0] as Ptr<Cell>, (value: Cell): uint64 => value.a);
const slot = new Slot<Cell>(cells[0] as Ptr<Cell>);
console.log("cell=" + cell.b.toString() + " twice=" + twice.toString() + " slot=" + slot.read().a.toString());
