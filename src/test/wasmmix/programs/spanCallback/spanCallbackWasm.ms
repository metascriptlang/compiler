@wasm
export function sumThrough(n: int32, cb: (xs: Readonly<Span<float32>>) => float32): float32 {
	let xs: Vec<float32> = [];
	for (let i = 0; i < n; i += 1) xs.push((i as float32) + 0.875);
	return cb(xs);
}

@wasm
export function editThrough(cb: (xs: Span<int32>, at: int32) => void): int32 {
	let ns: Vec<int32> = [1, 2, 3];
	cb(ns[1..3], 0);
	return ns[0] + ns[1] + ns[2] - 5;
}

@wasm
export function flipThrough(cb: (bs: Span<boolean>) => void): int32 {
	let bs: Vec<boolean> = [true, false, false];
	cb(bs);
	let on = 0;
	for (const b of bs) if (b) on += 1;
	return on;
}
