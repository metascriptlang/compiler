@wasm
export function bomShort(): string {
	return "\uFEFFab";
}

@wasm
export function bomLong(): string {
	return "\uFEFFabcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN";
}

@wasm
export function bomNonAscii(): string {
	return "\uFEFFh\u00e9llo w\u00f6rld caf\u00e9 cr\u00e8me";
}

@wasm
export function twoBoms(): string {
	return "\uFEFF\uFEFFabcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN";
}

@wasm
export function midBom(): string {
	return "ab\uFEFFabcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN";
}

@wasm
export function echo(s: string): string {
	return s;
}

@wasm
export function probe(callback: (s: string) => int32): int32 {
	return callback("\uFEFFabcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN") + callback("\uFEFFab");
}
