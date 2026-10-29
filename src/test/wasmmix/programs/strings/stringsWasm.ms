@wasm();

export function twice(s: string): string {
	return s + s;
}

export function pick(k: int32): string {
	if (k == 0) { return "x\0y\u{1F600}"; }
	if (k == 1) { return "\uD800"; }
	return "";
}
