export class K {
	static twice(x: int32): int32 { return x * 2; }
	n: int32 = 4;
	plus(x: int32): int32 { return this.n + x; }
}
export enum Color { Red, Green = 5 }
export function label(c: Color): string { return c == Color.Green ? "green" : "red"; }
export function pair<T>(x: T): T[] { return [x, x]; }
export let counter: int32 = 3;
console.log("lib body");
