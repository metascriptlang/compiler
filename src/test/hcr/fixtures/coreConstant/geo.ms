import { SCALE } from "./scale";
export function area(r: number): number {
	return Math.PI * r * r * SCALE;
}
export function wide(): boolean {
	return Number.MAX_SAFE_INTEGER > 1000;
}
