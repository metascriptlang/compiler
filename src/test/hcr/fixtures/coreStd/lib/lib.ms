export function parse(s: string): number {
	const n = parseFloat(s);
	return Number.isNaN(n) ? -1 : n;
}
