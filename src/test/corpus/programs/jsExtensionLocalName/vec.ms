export interface Vec { x: number; y: number; }
export function lengthSquared(this v: Vec): number {
	return v.x * v.x + v.y * v.y;
}
export function normalizedLength(this a: Vec): number {
	const lengthSquared = a.lengthSquared();
	return lengthSquared;
}
export function plusEach(this a: Vec, extra: number[]): number[] {
	return extra.map((lengthSquared: number): number => a.lengthSquared() + lengthSquared);
}
export class Scaler {
	factor: number;
	constructor(factor: number) { this.factor = factor; }
	scaled(lengthSquared: Vec): number {
		return lengthSquared.lengthSquared() * this.factor;
	}
}
