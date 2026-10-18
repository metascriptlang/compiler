export struct Cell { count: int32; }
export interface Box<T> { tag: string; item: T; extra: float64; }
export function makeCell(): [Cell, int32] { return [{ count: 7 }, 2]; }
export function makeBox(): [Box<int32>, int32] { return [{ tag: "rb", item: 9, extra: 1.5 }, 4]; }
export function makeAnon(): [{ c: int32; d: int32 }, int32] { return [{ c: 8, d: 9 }, 5]; }
