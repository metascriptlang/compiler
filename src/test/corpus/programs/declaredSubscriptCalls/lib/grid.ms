export struct Grid { w: int32; cells: int32[]; }
export function `[]`(this g: Grid, i: int32): int32 { return g.cells[i]; }
export function `[]=`(this g: Grid, i: int32, v: int32): void { g.cells[i] = v; }
