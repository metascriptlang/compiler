export function first<T>(pair: [T, int32]): T { return pair[0]; }
export function count<T>(pair: [T, int32]): int32 { return pair[1]; }
export function apply<T>(compute: () => [T, int32], sink: (v: T) => void): int32 {
	const pair = compute();
	sink(pair[0]);
	return pair[1];
}
