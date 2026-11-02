@wasm
export function editThenStop(xs: Span<int32>, at: int32): void {
	xs[0] = 100;
	xs[1] = 200;
	if (at >= 0) throw new Error("stop");
	xs[2] = 300;
}

@wasm
export function stampThenTick(bs: Span<boolean>, fail: boolean): int32 {
	bs[0] = true;
	if (fail) throw new Error("tick");
	bs[1] = true;
	return 1;
}

@wasm
export function halveThenStop(xs: Span<float32>): void {
	for (let i = 0; i < xs.length; i += 1) xs[i] = xs[i] / 2;
	throw new Error("half");
}

@wasm
export function sumThenStop(xs: Readonly<Span<int32>>, fail: boolean): int32 {
	let s = 0;
	for (const x of xs) s += x;
	if (fail) throw new Error("read");
	return s;
}
