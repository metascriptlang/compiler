@wasm
export function shout(s: string): string {
	return s + s;
}

@wasm
export function wrap(tag: string, inner: (s: string) => int32): string {
	const n = inner(tag + "!");
	if (n > 9) { return tag + tag + "#big"; }
	return tag + tag + "#small";
}

@wasm
export function hollow(inner: (s: string) => int32): string {
	inner("0123456789abcdefghij");
	return "";
}

@wasm
export function banner(): string {
	return "zero-parameter-banner";
}
