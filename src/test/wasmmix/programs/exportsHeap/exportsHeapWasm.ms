@wasm
export function ramp(n: int32): Vec<int32> {
	let out: Vec<int32> = [];
	for (let i = 0; i < n; i += 1) out.push(i * i);
	return out;
}

@wasm
export function bytes(n: int32): Vec<uint8> {
	let out: Vec<uint8> = [];
	for (let i = 0; i < n; i += 1) out.push((250 - i) as uint8);
	return out;
}

@wasm
export function visit(cb: (xs: Readonly<Span<float64>>) => float64): float64 {
	let xs: Vec<float64> = [0.5, 1.5, 2.5];
	return cb(xs) + 0.25;
}

@wasm
export function bump(cb: (xs: Span<uint16>) => void): int32 {
	let xs: Vec<uint16> = [1, 2, 3];
	cb(xs);
	let s = 0;
	for (const x of xs) s += x as int32;
	return s;
}
