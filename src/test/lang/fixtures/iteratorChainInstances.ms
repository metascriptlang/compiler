export function joinAll(xs: string[]): string {
	return xs.values().reduce((acc: string, x: string, i: number): string => acc + x, "");
}

export function doubledSum(xs: int32[]): int32 {
	return xs.values().map((x: int32, i: number): int32 => x * 2).reduce((acc: int32, x: int32, i: number): int32 => acc + x, 0);
}
