@wasm
export function orMinus(a: int32 | null): int32 {
	return a ?? -1;
}

@wasm
export function sumBig(a: int64 | null, b?: int64): int64 {
	return (a ?? 0) + (b ?? 100);
}

@wasm
export function halve(x: float64): float64 | null {
	if (x < 0) { return null; }
	return x / 2;
}

@wasm
export function parity(n: int32): boolean | null {
	if (n < 0) { return null; }
	return n % 2 == 0;
}

@wasm
export function greet(name: string | null): string | null {
	if (name == null) { return null; }
	return "hi " + name;
}

@wasm
export function emptyOrNull(n: int32): string | null {
	if (n < 0) { return null; }
	if (n == 0) { return ""; }
	return "x";
}

@wasm
export function label(n: uint8 | null, s: string | null): string {
	return `${n ?? 255}/${s ?? "-"}`;
}

@wasm
export function echoU32(n: uint32 | null): uint32 | null {
	return n;
}

@wasm
export function echoSmall(n: int8 | null): int8 | null {
	return n;
}

@wasm
export function bigAt(base: int64, n: int32): int64 | null {
	if (n < 0) { return null; }
	return base + (n as int64);
}

@wasm
export function replay(callback: (n: int32 | null, s: string | null) => void): void {
	callback(7, "a");
	callback(null, "");
	callback(3, null);
}

@wasm
export function replayBig(callback: (f: boolean | null, s: int8 | null, b: int64 | null) => void): void {
	callback(true, -5, 9007199254740993);
	callback(null, null, null);
	callback(false, 127, 0);
}

@wasm
export function fold(callback: (x: float64 | null) => int32): int32 {
	return callback(1.5) + callback(null);
}
