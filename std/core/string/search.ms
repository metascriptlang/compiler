// MetaScript String Prelude — search for the C and Raiser backends;
// the JS backend binds the native String methods instead (index.jms).
// indexOf and lastIndexOf answer UTF-16 unit positions over the UTF-8 bytes.

import { asBytes, byteIndexOf, byteEqAt, byteIsAscii } from "./bytes";

function unitWidth(lead: uint8): int32 {
	return lead < 0x80 ? 1 : lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : 4;
}

/**
 * Returns the position of the first occurrence of a substring.
 * @param sub The substring to search for in the string.
 * @param start The index at which to begin searching the String object. If omitted, search starts at the beginning of the string.
 */
export function indexOf(this s: string, sub: string, start: int32 = 0): int32 {
	const from = start < 0 ? 0 : start;
	const hb = s.asBytes();
	const nb = sub.asBytes();
	if (nb.length == 0) {
		const n = s.length;
		return from < n ? from : n;
	}
	if (nb.length > hb.length) return -1;
	if (byteIsAscii(s)) return s.byteIndexOf(sub, from);
	let p = 0;
	let unit = 0;
	while (p < hb.length && unit < from) {
		const w = unitWidth(hb[p]);
		p = p + w;
		unit = unit + (w == 4 ? 2 : 1);
	}
	while (p + nb.length <= hb.length) {
		if (byteEqAt(hb, p, nb)) return unit;
		const w = unitWidth(hb[p]);
		p = p + w;
		unit = unit + (w == 4 ? 2 : 1);
	}
	return -1;
}

/**
 * Returns the last occurrence of a substring in the string.
 * @param sub The substring to search for.
 */
export function lastIndexOf(this s: string, sub: string, startIdx: int32 = -1): int32 {
	const hb = s.asBytes();
	const nb = sub.asBytes();
	if (nb.length == 0) {
		const n = s.length;
		return startIdx >= 0 && startIdx < n ? startIdx : n;
	}
	if (nb.length > hb.length) return -1;
	const ascii = byteIsAscii(s);
	let i = hb.length - nb.length;
	if (startIdx >= 0) {
		if (ascii) {
			if (startIdx < i) i = startIdx;
		} else {
			let bytePos = 0;
			let unit = 0;
			while (bytePos < hb.length) {
				const w = unitWidth(hb[bytePos]);
				const next = unit + (w == 4 ? 2 : 1);
				if (next > startIdx) break;
				bytePos = bytePos + w;
				unit = next;
			}
			if (bytePos < i) i = bytePos;
		}
	}
	const first = nb[0];
	while (i >= 0 && !(hb[i] == first && (nb.length == 1 || byteEqAt(hb, i, nb)))) i = i - 1;
	if (i < 0 || ascii) return i;
	let p = 0;
	let unit = 0;
	while (p < i) {
		const w = unitWidth(hb[p]);
		p = p + w;
		unit = unit + (w == 4 ? 2 : 1);
	}
	return unit;
}

export function startsWith(this s: string, prefix: string): boolean {
	const sb = s.asBytes();
	const pb = prefix.asBytes();
	if (pb.length == 0) return true;
	if (sb.length < pb.length) return false;
	let i = 0;
	while (i < pb.length) {
		if (sb[i] != pb[i]) return false;
		i = i + 1;
	}
	return true;
}

export function endsWith(this s: string, suffix: string): boolean {
	const sb = s.asBytes();
	const xb = suffix.asBytes();
	if (xb.length == 0) return true;
	if (sb.length < xb.length) return false;
	const off = sb.length - xb.length;
	let i = 0;
	while (i < xb.length) {
		if (sb[off + i] != xb[i]) return false;
		i = i + 1;
	}
	return true;
}

export function includes(this s: string, sub: string): boolean {
	return s.contains(sub);
}

export function contains(this s: string, sub: string): boolean {
	return s.byteIndexOf(sub, 0) >= 0;
}

// Non-overlapping occurrences. An empty needle counts every gap: byteLength + 1.
export function count(this s: string, sub: string): int32 {
	const sb = s.asBytes();
	const xb = sub.asBytes();
	if (xb.length == 0) return sb.length + 1;
	let n: int32 = 0;
	let pos = 0;
	while (pos <= sb.length - xb.length) {
		const found = s.byteIndexOf(sub, pos);
		if (found < 0) break;
		n = n + 1;
		pos = found + xb.length;
	}
	return n;
}
