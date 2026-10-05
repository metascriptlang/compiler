export function tag(): string { return "T"; }
export function twice(n: int32): int32 { return n * 2; }
export function apply(f: (n: int32) => int32, n: int32): int32 { return f(n); }
export class Box {
	v: int32;
	constructor(v: int32) { this.v = v; }
	get(): int32 { return this.v; }
}
export const K: int32 = 7;
export enum Color { Red, Green }
