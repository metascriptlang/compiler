@wasm
export function guarded(value: int32, f: (x: int32) => int32): int32 {
	return f(value) + 1;
}

@wasm
export function recover(label: string, f: (s: string) => int32): string {
	return `ok ${f(label)}`;
}
