export class Grid {
	width: int32 = 4;
}

export function `[]`(this g: Grid, i: int32): int32 { return g.width * 10 + i; }
