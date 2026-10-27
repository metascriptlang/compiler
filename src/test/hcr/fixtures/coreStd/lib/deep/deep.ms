export function clamp(x: number): number {
	return Number.isFinite(x) ? Math.sign(x) * Math.round(Math.abs(x)) : 0;
}
