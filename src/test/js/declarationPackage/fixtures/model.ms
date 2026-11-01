export class PackageItem {
	value: int32 = 0;
	private secret: int32 = 0;

	constructor(value: int32) { this.value = value; }

	add(amount: int32): int32 { return this.value + amount + this.secret; }
}

export type Label<T extends string = string> = [T];
export interface Envelope<T = string> { value: T; }

export function increment(value: int32): int32 { return value + 1; }
