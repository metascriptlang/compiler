// @xfail(raiser): the ArrayBuffer passed to a constructor whose later super(...) argument throws stays live at exit on the Raiser VM (ledger: 1 object item); card 2026-11-06-raiser-super-argument-raise-leaks-earlier-argument
// @stdout: misaligned start offset of Int32Array should be a multiple of 4
// @stdout: ragged threw
// note: a typed array over a buffer refuses a byteOffset that is not a multiple of BYTES_PER_ELEMENT, and a buffer whose byte length is not one when the length is omitted, with RangeError; the message is the TS one where the native backends write it. Same output on every lane as on Node.

try {
	new Int32Array(new ArrayBuffer(16), 2);
} catch (e) {
	console.log(`misaligned ${(e as Error).message}`);
}
try {
	new Float64Array(new ArrayBuffer(12));
	console.log("ragged accepted");
} catch (e) {
	console.log("ragged threw");
}
