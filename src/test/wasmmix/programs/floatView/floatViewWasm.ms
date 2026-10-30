let data: float32[] = [];

@wasm
export function fill(n: int32): void {
	data = [];
	for (let i = 0; i < n; i = i + 1) { data.push((i * 0.5) as float32); }
}

@wasm
export function push(v: float32): int32 {
	data.push(v);
	return data.length;
}

@wasm
export function sum(): float64 {
	let s: float64 = 0;
	for (let i = 0; i < data.length; i = i + 1) { s = s + data[i]; }
	return s;
}
