export struct V { x: int32; y: int32; }
export class K { n: int32 = 5; }
export class Box<T> {
	value: T;
	constructor(value: T) { this.value = value; }
}
export enum Color { Red, Green }
export function unbox(b: Box<int32>): int32 { return b.value; }
