export struct Point { x: float64; y: float64; }
export struct Label { at: Point; text: string; count: int32; shown: boolean; }

@wasm
export function moved(l: Label, dx: float64): Label {
	return { at: { x: l.at.x + dx, y: l.at.y }, text: l.text + "!", count: l.count + 1, shown: !l.shown };
}

@wasm
export function scaled(xs: Vec<float32>, k: float32): Vec<float32> {
	let out: Vec<float32> = [];
	for (const x of xs) out.push(x * k);
	return out;
}

@wasm
export function flags(n: int32): Vec<boolean> {
	let out: Vec<boolean> = [];
	for (let i = 0; i < n; i += 1) out.push(i % 2 == 0);
	return out;
}

@wasm
export function total(xs: Vec<uint16>): int32 {
	let s = 0;
	for (const x of xs) s += x as int32;
	return s;
}

@wasm
export function grown(xs: Vec<float64>, extra: float64): Vec<float64> {
	let ys = xs;
	for (let i = 0; i < 40; i += 1) ys.push(extra + i);
	return ys;
}

@wasm
export function countTrue(bs: Vec<boolean>): int32 {
	let n = 0;
	for (const b of bs) if (b) n += 1;
	return n;
}
