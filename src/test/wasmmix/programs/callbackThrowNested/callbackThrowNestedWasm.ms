@wasm
export function relay(label: string, f: (s: string) => int64): int64 {
	return f(label) + 1;
}

@wasm
export function permit(label: string, f: (s: string, n: float64) => boolean): boolean {
	return f(label, 2.5);
}

@wasm
export function deepen(value: int32, f: (x: int32) => void): int32 {
	f(value);
	return value + 1;
}
