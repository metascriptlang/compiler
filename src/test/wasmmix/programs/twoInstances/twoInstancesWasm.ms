export struct Pair { left: int32; name: string; }

@wasm
export function apply(value: int32, callback: (value: int32) => int32): int32 {
	return callback(value) + 1;
}

@wasm
export function measure(callback: (text: string) => int32): int32 {
	return callback("wasm") * 2;
}

@wasm
export function pair(n: int32, name: string): Pair {
	return { left: n + 1, name: name + "!" };
}

@wasm
export function ramp(n: int32): Vec<float32> {
	let out: Vec<float32> = [];
	for (let i = 0; i < n; i += 1) out.push((i as float32) * 0.5);
	return out;
}
