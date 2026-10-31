@wasm
export function dec(n: int32): int32 | null {
	if (n <= 0) { return null; }
	return n - 1;
}

@wasm
export function viaCallback(n: int32, f: (x: int32) => int32): int32 | null {
	const y = f(n);
	if (y < 0) { return null; }
	return y + 100;
}

@wasm
export function name(n: int32): string | null {
	if (n < 0) { return null; }
	return `n${n}`;
}

@wasm
export function wrap(n: int32, f: (x: int32) => int32): string | null {
	const k = f(n);
	if (k < 0) { return null; }
	return `w${k}`;
}
