export struct Pair { left: string; n: int32; right: string; }

@wasm
export function echo(s: string): string {
	return s;
}

@wasm
export function lengthOf(s: string): int32 {
	return s.length;
}

@wasm
export function unitAt(s: string, k: int32): int32 {
	return s.charCodeAt(k);
}

@wasm
export function swap(p: Pair): Pair {
	return { left: p.right, n: p.n + 1, right: p.left };
}

@wasm
export function build(times: int32): string {
	const parts: string[] = [];
	for (let i = 0; i < times; i = i + 1) { parts.push("\u00e9\u{1F600}"); }
	return parts.join("");
}
