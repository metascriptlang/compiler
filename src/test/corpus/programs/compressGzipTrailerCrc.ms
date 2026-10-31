// Parity program — the CRC32 and ISIZE words gzip writes after the deflate body, read back as hex.
// The standard CRC-32 check value of "123456789" is 0xCBF43926 and the empty input has CRC 0.
//
// @skip-js: std/compress has no JS surface
// @xfail(raiser): std/compress resolves only its zip submodule on Raiser
// @stdout: 2639f4cb09000000|0000000000000000|a1e61db100000100
// @exit: 0

import { Buffer } from "std/core/buffer";
import { gzip } from "std/compress/deflate";

function trailer(data: Buffer): string {
	const r = gzip(data);
	if (!r.ok) return "gzip failed";
	let s = "";
	for (let i = r.value.length - 8; i < r.value.length; i++) {
		const b = r.value[i];
		s += (b < 16 ? "0" : "") + b.toString(16);
	}
	return s;
}

const repeated = Buffer.alloc(256 * 256);
for (let i = 0; i < repeated.length; i++) repeated[i] = (i & 255) as uint8;
console.log([trailer(Buffer.fromString("123456789", "utf8")), trailer(Buffer.alloc(0)), trailer(repeated)].join("|"));
