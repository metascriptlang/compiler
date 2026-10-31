export struct Pt { x: float64; y: float64; }
export struct Seg { start: Pt; stop: Pt; tag: string; lit: boolean; }

@wasm
export function addI32(a: int32, b: int32): int32 {
	return a + b;
}

@wasm
export function lowByte(a: uint8): uint8 {
	return a;
}

@wasm
export function echo64(a: int64): int64 {
	return a;
}

@wasm
export function echoU64(a: uint64): uint64 {
	return a;
}

@wasm
export function not(b: boolean): boolean {
	return !b;
}

@wasm
export function half(a: float64): float64 {
	return a / 2;
}

@wasm
export function join2(a: string, b: string): string {
	return a + b;
}

@wasm
export function sumVec(xs: Vec<int32>): int32 {
	let s = 0;
	for (const x of xs) s += x;
	return s;
}

@wasm
export function countTrue(bs: Vec<boolean>): int32 {
	let n = 0;
	for (const b of bs) {
		if (b) n += 1;
	}
	return n;
}

@wasm
export function bigSum(xs: Vec<int64>): int64 {
	let s: int64 = 0;
	for (const x of xs) s += x;
	return s;
}

@wasm
export function reach(s: Seg): float64 {
	return (s.stop.x - s.start.x) + (s.stop.y - s.start.y);
}

@wasm
export function sumSpan(xs: Readonly<Span<float32>>): float32 {
	let s: float32 = 0;
	for (const x of xs) s += x;
	return s;
}

@wasm
export function evalCb(value: int32, cb: (x: int32) => int32): int32 {
	return cb(value) + 1;
}

@wasm
export function testCb(value: int32, cb: (x: int32) => boolean): boolean {
	return cb(value);
}
