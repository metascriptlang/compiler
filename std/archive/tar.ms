// std/archive/tar — POSIX USTAR tar writer.
//
// Writes a subset of the USTAR format (POSIX 1003.1-1988):
//   - Regular files only (no symlinks, no directories-as-entries, no hardlinks)
//   - No PAX extended headers (long names are split via `prefix` field)
//   - No sparse file support
//   - UID/GID always zero, uname/gname empty
//
// Determinism: mtime defaults to 0 so repeated calls with the same entries
// produce byte-identical output (and therefore identical integrity hashes).
//
// The output is uncompressed — the caller is expected to run `gzip(bytes, 6)`
// from std/compress/deflate to produce a `.tar.gz`.
//
// USTAR header layout (512 bytes, all fields ASCII):
//   0   100  name                    \
//   100 8    mode   (octal + NUL)    |
//   108 8    uid    (octal + NUL)    |
//   116 8    gid    (octal + NUL)    |
//   124 12   size   (octal + NUL)    |  checksum computed
//   136 12   mtime  (octal + NUL)    |  over ALL 512 bytes
//   148 8    chksum (6 octal + NUL + space)  with this field
//   156 1    typeflag ("0")          |  replaced by 8 spaces
//   157 100  linkname                |
//   257 6    magic "ustar\0"         |
//   263 2    version "00"            |
//   265 32   uname                   |
//   297 32   gname                   |
//   329 8    devmajor                |
//   337 8    devminor                |
//   345 155  prefix                  |
//   500 12   pad                     /

import { Buffer } from "std/core/buffer";

// Local extern bindings — std/core/buffer keeps these private but the tar
// writer needs direct byte-level access without relying on extension-method
// resolution through the `type Buffer = string` alias. The names match the
// C runtime symbols so no `from` clause is needed.
extern function msBufferAlloc(size: number): string;
extern function msBufferSet(buf: string, index: number, value: number): void;
extern function msBufferFill(buf: string, value: number, start: number, end: number): string;
extern function msBufferWriteString(buf: string, str: string, offset: number, length: number, encoding: string): number;
extern function msBufferCopy(src: string, dst: string, dstStart: number, srcStart: number, srcEnd: number): number;

const BLOCK_SIZE: int32 = 512;
const NAME_MAX: int32 = 100;
const PREFIX_MAX: int32 = 155;

// Default file mode (0o644 in octal).
export const DEFAULT_FILE_MODE: int32 = 420;

export interface TarEntry {
	name: string;       // POSIX-style path ("/" separator)
	data: string;       // file contents (byte-safe)
	mode: number;       // UNIX mode bits (e.g. 420 = 0o644)
	mtime: number;      // UNIX epoch seconds; use 0 for determinism
}

// Build a USTAR archive. Returns the raw tar bytes or an error string if any
// entry has a path that cannot fit in name+prefix (very long paths).
export function writeTar(entries: TarEntry[]): Result<string, string> {
	// Two-pass: first compute headers + total size, then allocate once and
	// copy everything in. O(n) memory traffic, not O(n²).
	const headers: string[] = [];

	let totalSize = 0;
	let i = 0;
	while (i < entries.length) {
		const entry = entries[i];
		i = i + 1;

		const headerResult = buildHeader(entry);
		if (!headerResult.ok) return Result.err(headerResult.error);
		headers.push(headerResult.value);

		totalSize = totalSize + BLOCK_SIZE;
		// Body is padded to next 512-byte boundary.
		const bodyLen: int32 = entry.data.byteLength as int32;
		const padded: int32 = bodyLen + ((BLOCK_SIZE - (bodyLen % BLOCK_SIZE)) % BLOCK_SIZE);
		totalSize = totalSize + padded;
	}
	// Two zero end blocks.
	totalSize = totalSize + BLOCK_SIZE + BLOCK_SIZE;

	// Single allocation; zero-filled by msBufferAlloc.
	const out = msBufferAlloc(totalSize);
	let off = 0;
	let j = 0;
	while (j < entries.length) {
		const entry = entries[j];
		const hdr = headers[j];
		msBufferCopy(hdr, out, off, 0, BLOCK_SIZE);
		off = off + BLOCK_SIZE;
		const bodyLen: int32 = entry.data.byteLength as int32;
		if (bodyLen > 0) {
			msBufferCopy(entry.data, out, off, 0, bodyLen);
		}
		const rem: int32 = bodyLen % BLOCK_SIZE;
		const padded: int32 = rem === 0 ? bodyLen : bodyLen + (BLOCK_SIZE - rem);
		off = off + padded;
		j = j + 1;
	}
	// End zero blocks are already zero from msBufferAlloc; just advance.
	// (No-op; out is fully built.)

	return Result.ok(out);
}

// --- Internal helpers ---

function buildHeader(entry: TarEntry): Result<Buffer, string> {
	const hdr = msBufferAlloc(BLOCK_SIZE);

	// Split name into prefix + name if it's too long for the 100-byte field.
	const split = splitPath(entry.name);
	if (!split.ok) return Result.err(split.error);
	const nameField = split.value.name;
	const prefixField = split.value.prefix;

	// Name (offset 0, 100 bytes)
	msBufferWriteString(hdr, nameField, 0, nameField.byteLength, "binary");

	// Mode (offset 100, 8 bytes): 7 octal digits + NUL.
	writeOctal(hdr, 100, 8, entry.mode);

	// UID (offset 108, 8 bytes): always "0000000\0"
	writeOctal(hdr, 108, 8, 0);

	// GID (offset 116, 8 bytes): always "0000000\0"
	writeOctal(hdr, 116, 8, 0);

	// Size (offset 124, 12 bytes): 11 octal digits + NUL
	writeOctal(hdr, 124, 12, entry.data.byteLength);

	// Mtime (offset 136, 12 bytes): 11 octal digits + NUL
	writeOctal(hdr, 136, 12, entry.mtime);

	// Checksum field (offset 148, 8 bytes): fill with 8 spaces FOR the
	// checksum computation — we'll overwrite it with the real value below.
	msBufferFill(hdr, 32, 148, 156); // 32 = ' '

	// Typeflag (offset 156, 1 byte): "0" for regular file
	msBufferSet(hdr, 156, 48); // '0'

	// Linkname (offset 157, 100 bytes): already zero

	// Magic "ustar\0" (offset 257, 6 bytes)
	msBufferSet(hdr, 257, 117); // 'u'
	msBufferSet(hdr, 258, 115); // 's'
	msBufferSet(hdr, 259, 116); // 't'
	msBufferSet(hdr, 260, 97);  // 'a'
	msBufferSet(hdr, 261, 114); // 'r'
	msBufferSet(hdr, 262, 0);   // NUL

	// Version "00" (offset 263, 2 bytes)
	msBufferSet(hdr, 263, 48); // '0'
	msBufferSet(hdr, 264, 48); // '0'

	// uname (offset 265, 32 bytes): empty
	// gname (offset 297, 32 bytes): empty
	// devmajor (329, 8): empty
	// devminor (337, 8): empty

	// Prefix (offset 345, 155 bytes)
	if (prefixField.byteLength > 0) {
		msBufferWriteString(hdr, prefixField, 345, prefixField.byteLength, "binary");
	}

	// Compute checksum: sum of all 512 bytes (interpreted as unsigned) with
	// the 8 checksum bytes replaced by spaces during computation.
	let sum = 0;
	let k = 0;
	while (k < BLOCK_SIZE) {
		sum = sum + hdr.byteAt(k);
		k = k + 1;
	}

	// Write checksum: 6 octal digits + NUL + space (the canonical GNU format).
	const cksumStr = padOctal(sum, 6) + "\0 ";
	msBufferWriteString(hdr, cksumStr, 148, 8, "binary");

	return Result.ok(hdr);
}

interface PathSplit {
	name: string;
	prefix: string;
}

// Split a path so it fits in the 100-byte name + 155-byte prefix fields.
// If the path is ≤100 bytes, name = path, prefix = "".
// If the path is longer, we split at the nearest "/" such that the suffix
// (name) is ≤100 bytes and the prefix is ≤155 bytes. If no such split
// exists, return an error.
function splitPath(path: string): Result<PathSplit, string> {
	const blen: int32 = path.byteLength as int32;
	if (blen <= NAME_MAX) {
		return Result.ok({ name: path, prefix: "" });
	}
	if (blen > NAME_MAX + 1 + PREFIX_MAX) {
		return Result.err("path too long for USTAR format: " + path);
	}
	// Find the latest "/" such that (byte position + 1) ≤ blen - NAME_MAX and
	// the prefix length ≤ PREFIX_MAX.
	let bestSplit: int32 = -1;
	let i: int32 = 0;
	while (i < blen) {
		if (path.byteAt(i) === 47) {
			// i is a "/" position. prefix = path[0..i], suffix = path[i+1..blen]
			const prefixLen: int32 = i;
			const suffixLen: int32 = blen - i - 1;
			if (prefixLen <= PREFIX_MAX && suffixLen <= NAME_MAX) {
				bestSplit = i; // keep scanning — latest valid split gives shortest prefix
			}
		}
		i = i + 1;
	}
	if (bestSplit < 0) {
		return Result.err("path cannot be split to fit USTAR name/prefix: " + path);
	}
	const prefix = path.byteSlice(0, bestSplit);
	const name = path.byteSlice(bestSplit + 1, blen);
	return Result.ok({ name, prefix });
}

// Write a value as octal into `buf` at `offset`, filling `fieldLen` bytes.
// Format: (fieldLen-1) octal digits zero-padded + trailing NUL.
function writeOctal(buf: Buffer, offset: number, fieldLen: number, value: number): void {
	const s = padOctal(value, fieldLen - 1) + "\0";
	msBufferWriteString(buf, s, offset, fieldLen, "binary");
}

// Convert a non-negative integer to an octal string of exactly `width` digits,
// zero-padded on the left.
function padOctal(value: number, width: number): string {
	let v = value;
	if (v < 0) v = 0;
	// Build octal digits right-to-left.
	const digits: string[] = [];
	if (v === 0) {
		digits.push("0");
	} else {
		while (v > 0) {
			const d = v % 8;
			digits.push(octalDigit(d));
			v = (v - d) / 8;
		}
	}
	// Pad to width.
	while (digits.length < width) digits.push("0");
	// Truncate from the left if the value overflows the width (shouldn't
	// happen for tar fields but keeps the function total).
	if (digits.length > width) {
		const trimmed = digits.slice(0, width);
		return joinReverse(trimmed);
	}
	return joinReverse(digits);
}

function octalDigit(d: number): string {
	if (d === 0) return "0";
	if (d === 1) return "1";
	if (d === 2) return "2";
	if (d === 3) return "3";
	if (d === 4) return "4";
	if (d === 5) return "5";
	if (d === 6) return "6";
	return "7";
}

function joinReverse(parts: string[]): string {
	let out = "";
	let i = parts.length - 1;
	while (i >= 0) {
		out = out + parts[i];
		i = i - 1;
	}
	return out;
}
