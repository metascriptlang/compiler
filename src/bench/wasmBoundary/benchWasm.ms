import { Handle, VecBox } from "std/ffi";

export struct Point {
	x: float64;
	y: float64;
}

@wasm
export function add(a: int32, b: int32): int32 {
	return a + b;
}

@wasm
export function add64(a: int64, b: int64): int64 {
	return a + b;
}

@wasm
export function strLen(s: string): int32 {
	return s.asBytes().length as int32;
}

@wasm
export function echo(s: string): string {
	return s;
}

@wasm
export function mid(p: Point): Point {
	return { x: p.x / 2, y: p.y / 2 };
}

@wasm
export function sumVec(xs: Vec<float32>): float32 {
	let s: float32 = 0;
	for (const x of xs) s += x;
	return s;
}

@wasm
export function sumSpan(xs: Readonly<Span<float32>>): float32 {
	let s: float32 = 0;
	for (const x of xs) s += x;
	return s;
}

@wasm
export function makeVec(n: int32): Vec<float32> {
	let out: Vec<float32> = [];
	for (let i = 0; i < n; i += 1) out.push((i as float32) + 0.5);
	return out;
}

@wasm
export function scaleSpan(xs: Span<float32>, k: float32): void {
	for (let i = 0; i < xs.length; i += 1) xs[i] = xs[i] * k;
}

@wasm
export function makeBox(n: int32): Handle<VecBox<float32>> {
	const b = new VecBox<float32>();
	for (let i = 0; i < n; i += 1) b.items.push((i as float32) * 0.25);
	return Handle.retain(b);
}

@wasm
export function scaleBox(h: Handle<VecBox<float32>>, k: float32): void {
	const xs = h.value().items as Span<float32>;
	for (let i = 0; i < xs.length; i += 1) xs[i] = xs[i] * k;
}

@wasm
export function each(n: int32, cb: (i: int32) => int32): int32 {
	let s: int32 = 0;
	for (let i = 0; i < n; i += 1) s += cb(i);
	return s;
}

@wasm
export function primes(n: int32): int32 {
	let sieve: Vec<boolean> = [];
	for (let i = 0; i < n; i += 1) sieve.push(true);
	let count = 0;
	for (let i = 2; i < n; i += 1) {
		if (sieve[i]) {
			count += 1;
			if (i <= n / i)
				for (let j = i * i; j < n; j += i) sieve[j] = false;
		}
	}
	return count;
}
