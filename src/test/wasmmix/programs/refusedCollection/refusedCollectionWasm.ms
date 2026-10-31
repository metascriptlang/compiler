@wasm
export function count(m: Map<string, int32>): number {
	return m.size;
}

@wasm
export function uniq(xs: Vec<int32>): Set<int32> {
	const s = new Set<int32>();
	for (const x of xs) s.add(x);
	return s;
}
