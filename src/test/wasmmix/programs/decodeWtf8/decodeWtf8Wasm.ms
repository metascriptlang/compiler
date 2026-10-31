@wasm
export function echo(s: string): string {
	return s;
}

@wasm
export function probe(k: int32, callback: (s: string) => int32): int32 {
	if (k == 0) { return callback("\uD800aaaaaaaaaaaa"); }
	if (k == 1) { return callback("aaaaaa\uDC00aaaaaaa"); }
	if (k == 2) { return callback("aaaaaaa\uD800aaaaaaa"); }
	if (k == 3) { return callback("\uFFFDaaaaaaaaaaaaaa"); }
	return callback("\u{1F600}aaaaaaaaaaaaa");
}
