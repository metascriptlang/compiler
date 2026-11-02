export const LIMIT: int32 = 4;

export enum Level { Low = 1, High = 5 }

export struct Pair {
	a: int32;
	b: int32;
}

export class Counter {
	n: int32 = 0;
	bump(): int32 { this.n += 1; return this.n; }
}

export function scale(x: int32, k: int32 = 2): int32 {
	return x * k;
}

export function word(): string {
	return "apples";
}

export function seed(): int32 {
	return 3;
}
