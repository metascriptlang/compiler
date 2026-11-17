@wasm
export function total(xs: Span<int32>): Promise<int32> {
	let s = 0;
	for (const x of xs) s += x;
	xs[0] = s;
	return Promise.resolve(s);
}

@wasm
export function bump(ref n: int32): Promise<void> {
	n += 1;
	return Promise.resolve();
}
