export type Cell = { kind: "a", x: number } | { kind: "b", y: string } | { kind: "c" };
export function describe(this c: Cell): string { return `cell:${c.kind}`; }
export function getDynamicField(this c: Cell, key: string): string { return `dyn:${key}`; }
