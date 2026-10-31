export struct Inner {
	flag: boolean;
	small: int8;
}

export struct Wide {
	inner: Inner;
	half: uint16;
	big: uint64;
}

@wasm
export function echoI8(x: int8): int8 {
	return x;
}

@wasm
export function echoI16(x: int16): int16 {
	return x;
}

@wasm
export function echoU8(x: uint8): uint8 {
	return x;
}

@wasm
export function echoU16(x: uint16): uint16 {
	return x;
}

@wasm
export function echoU32(x: uint32): uint32 {
	return x;
}

@wasm
export function echoI64(x: int64): int64 {
	return x;
}

@wasm
export function echoU64(x: uint64): uint64 {
	return x;
}

@wasm
export function echoF32(x: float32): float32 {
	return x;
}

@wasm
export function viaI8(x: int8, f: (v: int8) => int8): int8 {
	return f(x);
}

@wasm
export function viaU16(x: uint16, f: (v: uint16) => uint16): uint16 {
	return f(x);
}

@wasm
export function viaU32(x: uint32, f: (v: uint32) => uint32): uint32 {
	return f(x);
}

@wasm
export function viaU64(x: uint64, f: (v: uint64) => uint64): uint64 {
	return f(x);
}

@wasm
export function viaBool(x: boolean, f: (v: boolean) => boolean): boolean {
	return f(x);
}

@wasm
export function viaPair(a: int16, b: uint8, f: (a: int16, b: uint8) => void): void {
	f(a, b);
}

@wasm
export function echoWide(w: Wide): Wide {
	return w;
}

@wasm
export function echoVecU64(xs: Vec<uint64>): Vec<uint64> {
	return xs;
}

@wasm
export function echoVecI16(xs: Vec<int16>): Vec<int16> {
	return xs;
}

@wasm
export function swapEndsI8(xs: Span<int8>): void {
	const first = xs[0];
	xs[0] = xs[2];
	xs[2] = first;
}
