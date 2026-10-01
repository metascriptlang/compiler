export type Box<U> = { v: U };
export interface Cell<T> { v: T; }
export class Pair<A> { v: A; constructor(v: A) { this.v = v; } }

export function libBox(): Box<string> { return { v: "lib-box" }; }
export function libCell(): Cell<string> { return { v: "lib-cell" }; }
export function libPair(): Pair<string> { return new Pair<string>("lib-pair"); }
export function readBox(b: Box<string>): string { return b.v; }
