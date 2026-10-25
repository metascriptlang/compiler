import { fill } from "./state";

export function refill(n: int32): void {
	fill(n);
}

export function measure(s: string): string {
	refill(2);
	const junk = [`junk-${3}`, `junk-${4}`, `junk-${5}`, `field-${6}`];
	return `[${s}]${junk.length}`;
}
