import { fill } from "./state";

export function refill(n: int32): void {
	fill(n);
}

export function measure(s: string): string {
	return `[${s}]`;
}
