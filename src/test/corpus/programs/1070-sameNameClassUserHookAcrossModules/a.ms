let destroyed: int32 = 0;

export class Cell {
	id: int32;
	constructor(id: int32) { this.id = id; }
	onDestroy(): void { destroyed += 1; }
}

export function runA(): void {
	const c = new Cell(1);
	console.log("a holds " + c.id.toString());
}

export function destroyedCount(): int32 { return destroyed; }
