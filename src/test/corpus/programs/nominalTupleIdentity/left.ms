export struct Cell { text: string; }
export interface Box<T> { item: T; tag: string; }
export function makeCell(): [Cell, int32] { return [{ text: "left" }, 1]; }
export function makeBox(): [Box<int32>, int32] { return [{ item: 5, tag: "lb" }, 2]; }
export function makeAnon(): [{ a: string; b: string }, int32] { return [{ a: "x", b: "y" }, 3]; }
