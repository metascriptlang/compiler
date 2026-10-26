class Cell {
	v: int32;
	constructor(v: int32) { this.v = v; }
}

class Row {
	tag: Cell;
	cells: Cell[];
	constructor(tag: Cell) {
		this.tag = tag;
		this.cells = [];
	}
}

function total(rows: Row[]): int32 {
	let sum: int32 = 0;
	for (const r of rows) {
		for (const c of r.cells) sum += c.v + r.tag.v;
	}
	return sum;
}

function run(): void {
	const rows: Row[] = [];
	for (let i: int32 = 0; i < 4; i += 1) {
		const r = new Row(new Cell(i));
		r.cells.push(new Cell(i * 2));
		r.cells.push(new Cell(i * 3));
		rows.push(r);
	}
	console.log(total(rows));
	const first = rows[0];
	first.cells = [new Cell(100)];
	console.log(total(rows));
}

run();
