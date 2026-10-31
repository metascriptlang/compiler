export struct Tag { text: string; count: int32; }

@wasm
export function label(n: int32): string {
	if (n < 0) { return "héllo wörld, ünïcode ✓ with a tail long enough for the decoder"; }
	return `é${n}`;
}

@wasm
export function made(n: int32): Tag {
	return { text: `t${n}`, count: n * 2 };
}

@wasm
export function each(n: int32, cb: (s: string) => int32): int32 {
	let total = 0;
	for (let i = 0; i < n; i += 1) { total += cb(`k${i}`); }
	return total;
}
