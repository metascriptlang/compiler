export class Grid {
	cells: int32[] = [0, 0, 0];
}

export function `[]`(this g: Grid, i: int32): int32 { return g.cells[i] + 100; }

export function `[]=`(this g: Grid, i: int32, v: int32): void { g.cells[i] = v * 2; }
