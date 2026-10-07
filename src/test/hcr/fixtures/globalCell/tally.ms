let counts: number[] = [];

export function tallyUp(n: number): number {
	counts.push(n);
	return counts.length;
}
