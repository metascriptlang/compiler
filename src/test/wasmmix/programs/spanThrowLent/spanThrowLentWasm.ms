@wasm
export function editStop(xs: Span<int32>, stop: boolean): void {
	xs[0] = 7;
	if (stop) throw new Error("stop");
	xs[1] = 8;
}

@wasm
export function peek(xs: Vec<int32>, cb: (first: int32) => int32): int32 {
	return cb(xs[0]);
}

@wasm
export function sumOf(xs: Vec<int32>): int32 {
	let s = 0;
	for (const x of xs) s += x;
	return s;
}

@wasm
export function bump(xs: Span<int32>): void {
	for (let i = 0; i < xs.length; i += 1) xs[i] = xs[i] + 1;
}
