// Parked by ~/metascript/.inbox/compiler/2026-10-30-js-buffer-literal-writefilebytes.md.
// Register this literal-input test after the JS byte boundary is fixed.

import { exists, ensureDir, writeFileBytes, remove } from "std/fs";

test "writeFileBytes accepts a Buffer-typed byte array literal" {
	const path = "out/fsByteLiteralParked.bin";
	assert ensureDir("out").ok;
	assert !exists(path);
	const binary: Buffer = [0, 255, 195, 40, 0, 128, 10, 13, 127];
	const written = writeFileBytes(path, binary);
	assert written.ok;
	if (written.ok) { assert remove(path).ok; }
}
