const pad = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz";

@wasm
export function same(s: string): string {
	return s;
}

@wasm
export function size(s: string): int32 {
	return s.length;
}

@wasm
export function made(bytes: int32, ch: string, width: int32, at: int32): string {
	const rest = bytes - width;
	const left = at == 0 ? 0 : at == 1 ? rest >> 1 : rest;
	return pad.slice(0, left) + ch + pad.slice(0, rest - left);
}
