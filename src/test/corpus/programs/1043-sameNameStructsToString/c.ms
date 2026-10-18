export class Cell {
	n: int32 = 3;
}

export function toString(this c: Cell): string { return "C" + String(c.n); }
