// @stdout: tar parity ok

// Pins the USTAR bytes produced by writeTar on the C backend: total layout,
// header field placement (magic/typeflag/name/size), data offset and the
// checksum arithmetic recomputed from raw bytes. The js backend must match
// once std/core/buffer/index.jms lands.

import { writeTar, TarEntry, DEFAULT_FILE_MODE } from "std/archive/tar";

function check(name: string, ok: boolean): boolean {
	if (!ok) { console.log("FAIL " + name); }
	return ok;
}

function parseOctalAt(s: string, offset: number, maxDigits: number): number {
	let v = 0;
	let i = 0;
	while (i < maxDigits) {
		const c = s.byteAt(offset + i);
		if (c < 48 || c > 55) { break; }
		v = v * 8 + (c - 48);
		i += 1;
	}
	return v;
}

function headerChecksum(s: string, base: number): number {
	let sum = 0;
	let i = 0;
	while (i < 148) { sum += s.byteAt(base + i); i += 1; }
	i = 0;
	while (i < 8) { sum += 32; i += 1; }
	i = 156;
	while (i < 512) { sum += s.byteAt(base + i); i += 1; }
	return sum;
}

function main(): void {
	const data2 = "BBBBBBBBBBBBBBBBBBBB";
	const entries: TarEntry[] = [
		{ name: "a.txt", data: "hello", mode: DEFAULT_FILE_MODE, mtime: 0 },
		{ name: "b.bin", data: data2, mode: DEFAULT_FILE_MODE, mtime: 0 },
	];
	const r = writeTar(entries);
	if (!r.ok) { console.log("FAIL writeTar " + r.error); return; }
	const s = r.value;

	let ok = true;

	// 2 headers + 2 data blocks (both padded to 512) + 2 zero end blocks.
	ok = check("totalSize", s.byteLength === 3072) && ok;

	// Header 1: name at 0, magic "ustar" at 257, typeflag '0' at 156.
	ok = check("name", s.byteAt(0) === 97 && s.byteAt(1) === 46) && ok;
	ok = check("magic", s.byteAt(257) === 117 && s.byteAt(258) === 115 && s.byteAt(259) === 116 &&
		s.byteAt(260) === 97 && s.byteAt(261) === 114) && ok;
	ok = check("typeflag", s.byteAt(156) === 48) && ok;

	// Size field is 12 octal digits at 124: entry 1 has 5 bytes.
	ok = check("size1", parseOctalAt(s, 124, 12) === 5) && ok;
	// mtime 0 at 136.
	ok = check("mtime", parseOctalAt(s, 136, 12) === 0) && ok;
	// mode 420 = 0o644 at 100.
	ok = check("mode", parseOctalAt(s, 100, 8) === 420) && ok;

	// Checksum field at 148 matches the recomputed sum.
	ok = check("cksum1", parseOctalAt(s, 148, 8) === headerChecksum(s, 0)) && ok;

	// Data 1 starts right after header 1.
	ok = check("data1", s.byteAt(512) === 104 && s.byteAt(516) === 111) && ok;

	// Header 2 at 1024: name b.bin, size 20, own checksum.
	ok = check("name2", s.byteAt(1024) === 98) && ok;
	ok = check("size2", parseOctalAt(s, 1024 + 124, 12) === 20) && ok;
	ok = check("cksum2", parseOctalAt(s, 1024 + 148, 8) === headerChecksum(s, 1024)) && ok;

	// Data 2 at 1536.
	ok = check("data2", s.byteAt(1536) === 66 && s.byteAt(1555) === 66) && ok;

	// End blocks at 2048 are zero.
	ok = check("endZero", s.byteAt(2048) === 0 && s.byteAt(3071) === 0) && ok;

	if (!ok) { console.log("tar parity FAILED"); return; }
	console.log("tar parity ok");
}

main();
