@wasm
export function sum(xs: int32[]): int32 {
	let t: int32 = 0;
	for (const x of xs) t += x;
	return t;
}

@wasm
export function halves(n: int32): float64[] {
	const out: float64[] = [];
	for (let i = 0; i < n; i += 1) out.push(i / 2);
	return out;
}
