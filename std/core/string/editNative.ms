@include("string.h");

import { stringByteIndexOf } from "./bytes";

extern function newBytes(length: int64): string from "msStringNewUninit";
extern function copyTo(dst: Ptr<uint8>, at: int64, src: Readonly<Span<uint8>>, from: int64, n: int64): void from "msMemCopyTo";
extern function sliceBytes(s: string, start: int64, end: int64): string from "msStringByteSlice";
extern function newParts(capacity: int64): string[] from "msStringArrayNew";
extern function asciiUnit(byte: uint8): string from "msCharTableAt";

@inline
function writable(value: string): Ptr<uint8> {
	return (value as cstring) as Ptr<uint8>;
}

function seqLenAt(sb: Readonly<Span<uint8>>, p: int64): int64 {
	const lead = sb[p];
	const left = sb.length - p;
	if (lead < 0x80) return 1;
	if (lead < 0xE0 && left > 1) return 2;
	if (lead < 0xF0 && left > 2) return 3;
	return left > 3 ? 4 : 1;
}

function codePointOfFour(sb: Readonly<Span<uint8>>, p: int64): int32 {
	return (((sb[p] as int32) & 7) << 18) | (((sb[p + 1] as int32) & 0x3F) << 12) | (((sb[p + 2] as int32) & 0x3F) << 6) | ((sb[p + 3] as int32) & 0x3F);
}

function isAstralAt(sb: Readonly<Span<uint8>>, p: int64, width: int64): boolean {
	return width == 4 && codePointOfFour(sb, p) >= 0x10000;
}

function writeSurrogate(dst: Ptr<uint8>, at: int64, unit: int32): void {
	dst[at] = (0xE0 | (unit >> 12)) as uint8;
	dst[at + 1] = (0x80 | ((unit >> 6) & 0x3F)) as uint8;
	dst[at + 2] = (0x80 | (unit & 0x3F)) as uint8;
}

function highHalf(sb: Readonly<Span<uint8>>, p: int64): int32 {
	return 0xD800 + ((codePointOfFour(sb, p) - 0x10000) >> 10);
}

function lowHalf(sb: Readonly<Span<uint8>>, p: int64): int32 {
	return 0xDC00 + ((codePointOfFour(sb, p) - 0x10000) & 0x3FF);
}

function surrogateString(unit: int32): string {
	const out = newBytes(3);
	writeSurrogate(writable(out), 0, unit);
	return out;
}

/**
 * Replaces the first occurrence of a search string with a replacement string.
 * @param search A string to search for.
 * @param replacement A string containing the text to replace.
 */
export function replace(this s: string, search: string, replacement: string): string {
	const sb = s.asBytes();
	const xb = search.asBytes();
	const rb = replacement.asBytes();
	if (xb.length == 0) return replacement + s;
	const at = stringByteIndexOf(s, search, 0);
	if (at < 0) return s;
	const out = newBytes(sb.length - xb.length + rb.length);
	const dst = writable(out);
	const after = at + xb.length;
	copyTo(dst, 0, sb, 0, at);
	copyTo(dst, at, rb, 0, rb.length);
	copyTo(dst, at + rb.length, sb, after, sb.length - after);
	return out;
}

/**
 * Replaces all occurrences of a search string with a replacement string.
 * @param search A string to search for.
 * @param replacement A string containing the text to replace.
 */
export function replaceAll(this s: string, search: string, replacement: string): string {
	const sb = s.asBytes();
	const xb = search.asBytes();
	const rb = replacement.asBytes();
	if (xb.length == 0) return interleaveUnits(sb, rb);
	let count: int64 = 0;
	let pos: int64 = 0;
	while (true) {
		const found = stringByteIndexOf(s, search, pos);
		if (found < 0) break;
		count += 1;
		pos = found + xb.length;
	}
	if (count == 0) return s;
	const out = newBytes(sb.length + count * (rb.length - xb.length));
	const dst = writable(out);
	let src: int64 = 0;
	let at: int64 = 0;
	while (true) {
		const found = stringByteIndexOf(s, search, src);
		if (found < 0) break;
		copyTo(dst, at, sb, src, found - src);
		at += found - src;
		copyTo(dst, at, rb, 0, rb.length);
		at += rb.length;
		src = found + xb.length;
	}
	copyTo(dst, at, sb, src, sb.length - src);
	return out;
}

function interleaveUnits(sb: Readonly<Span<uint8>>, rb: Readonly<Span<uint8>>): string {
	let units: int64 = 0;
	let unitBytes: int64 = 0;
	let p: int64 = 0;
	while (p < sb.length) {
		const w = seqLenAt(sb, p);
		if (isAstralAt(sb, p, w)) {
			units += 2;
			unitBytes += 6;
		} else {
			units += 1;
			unitBytes += w;
		}
		p += w;
	}
	const out = newBytes(unitBytes + (units + 1) * rb.length);
	const dst = writable(out);
	let at: int64 = 0;
	copyTo(dst, at, rb, 0, rb.length);
	at += rb.length;
	p = 0;
	while (p < sb.length) {
		const w = seqLenAt(sb, p);
		if (isAstralAt(sb, p, w)) {
			writeSurrogate(dst, at, highHalf(sb, p));
			copyTo(dst, at + 3, rb, 0, rb.length);
			writeSurrogate(dst, at + 3 + rb.length, lowHalf(sb, p));
			at += 6 + rb.length;
		} else {
			if (w == 1) {
				dst[at] = sb[p];
			} else {
				copyTo(dst, at, sb, p, w);
			}
			at += w;
		}
		copyTo(dst, at, rb, 0, rb.length);
		at += rb.length;
		p += w;
	}
	return out;
}

// Pad units are UTF-16 code units; a cut landing inside an astral pair keeps its high half.
export function padStart(this s: string, targetLen: int32, pad: string): string {
	return padded(s, targetLen, pad, true);
}

export function padEnd(this s: string, targetLen: int32, pad: string): string {
	return padded(s, targetLen, pad, false);
}

function padded(s: string, targetLen: int32, pad: string, atStart: boolean): string {
	const have = s.length;
	const pb = pad.asBytes();
	if (have >= targetLen || pb.length == 0) return s;
	const sb = s.asBytes();
	const padUnits = (targetLen - have) as int64;
	let cycleUnits: int64 = 0;
	let p: int64 = 0;
	while (p < pb.length) {
		const w = seqLenAt(pb, p);
		cycleUnits += isAstralAt(pb, p, w) ? 2 : 1;
		p += w;
	}
	const cycles = padUnits / cycleUnits;
	let restUnits = padUnits - cycles * cycleUnits;
	let restBytes: int64 = 0;
	p = 0;
	while (restUnits > 0) {
		const w = seqLenAt(pb, p);
		if (isAstralAt(pb, p, w)) {
			restBytes += restUnits >= 2 ? 4 : 3;
			restUnits -= 2;
		} else {
			restBytes += w;
			restUnits -= 1;
		}
		p += w;
	}
	const padBytes = cycles * pb.length + restBytes;
	const out = newBytes(padBytes + sb.length);
	const dst = writable(out);
	let at: int64 = atStart ? 0 : sb.length;
	if (!atStart) copyTo(dst, 0, sb, 0, sb.length);
	if (pb.length == 1) {
		const fill = pb[0];
		let i: int64 = 0;
		while (i < cycles) {
			dst[at + i] = fill;
			i += 1;
		}
		at += cycles;
	} else {
		let i: int64 = 0;
		while (i < cycles) {
			copyTo(dst, at, pb, 0, pb.length);
			at += pb.length;
			i += 1;
		}
	}
	let left = padUnits - cycles * cycleUnits;
	p = 0;
	while (left > 0) {
		const w = seqLenAt(pb, p);
		if (isAstralAt(pb, p, w)) {
			if (left >= 2) {
				copyTo(dst, at, pb, p, w);
				at += w;
			} else {
				writeSurrogate(dst, at, highHalf(pb, p));
				at += 3;
			}
			left -= 2;
		} else {
			copyTo(dst, at, pb, p, w);
			at += w;
			left -= 1;
		}
		p += w;
	}
	if (atStart) copyTo(dst, at, sb, 0, sb.length);
	return out;
}

/**
 * Split a string into substrings using the specified separator and return them as an array.
 * @param delimiter A string that identifies character or characters to use in separating the string.
 */
export function split(this s: string, delimiter: string): string[] {
	const parts = newParts(8);
	const sb = s.asBytes();
	const db = delimiter.asBytes();
	if (db.length == 0) {
		let p: int64 = 0;
		while (p < sb.length) {
			const lead = sb[p];
			if (lead < 0x80) {
				parts.push(asciiUnit(lead));
				p += 1;
				continue;
			}
			const w = seqLenAt(sb, p);
			if (isAstralAt(sb, p, w)) {
				parts.push(surrogateString(highHalf(sb, p)));
				parts.push(surrogateString(lowHalf(sb, p)));
			} else {
				parts.push(sliceBytes(s, p, p + w));
			}
			p += w;
		}
		return parts;
	}
	if (sb.length == 0) {
		parts.push("");
		return parts;
	}
	let pos: int64 = 0;
	while (true) {
		const found = stringByteIndexOf(s, delimiter, pos);
		if (found < 0) {
			parts.push(sliceBytes(s, pos, sb.length));
			return parts;
		}
		parts.push(sliceBytes(s, pos, found));
		pos = found + db.length;
	}
}

@exportName("msStringJoin")
export function stringJoin(arr: Vec<string>, sep: string): string {
	const n = arr.length;
	if (n == 0) return "";
	const sb = sep.asBytes();
	let total: int64 = (n - 1) * sb.length;
	let i: int64 = 0;
	while (i < n) {
		total += arr[i].asBytes().length;
		i += 1;
	}
	const out = newBytes(total);
	const dst = writable(out);
	let at: int64 = 0;
	i = 0;
	while (i < n) {
		if (i > 0) {
			copyTo(dst, at, sb, 0, sb.length);
			at += sb.length;
		}
		const eb = arr[i].asBytes();
		copyTo(dst, at, eb, 0, eb.length);
		at += eb.length;
		i += 1;
	}
	return out;
}
