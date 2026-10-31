@wasm
export function tick(cb: () => int32): int32 {
	return cb() + 1;
}

@wasm
export function ping(cb: () => void): int32 {
	for (let i = 0; i < 3; i += 1) cb();
	return 3;
}

@wasm
export function both(f: (x: int32) => int32, g: (x: float64) => float64): float64 {
	const a = f(3);
	const b = f(4);
	return g(a as float64) + (b as float64);
}
