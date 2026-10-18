export class Cell {
	id: int32;
	constructor(id: int32) { this.id = id; }
}

export function runB(): void {
	const c = new Cell(2);
	console.log("b holds " + c.id.toString());
}
