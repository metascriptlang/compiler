// MetaScript String Prelude — byte-offset search algorithms for the C and Raiser
// backends; the JS backend binds the native String methods instead (index.jms).

import { asBytes, byteLength, byteSlice, byteIndexOf } from "./bytes";

extern function codeUnitAt(s: string, unit: int32): string from "msStringCharAt";

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

export function split(this s: string, delimiter: string): string[] {
	const parts: string[] = [];
	if (delimiter.byteLength() == 0) {
		const units = s.length;
		for (let unit = 0; unit < units; unit++) parts.push(codeUnitAt(s, unit));
		return parts;
	}
	const delimiterLength = delimiter.byteLength();
	let pos = 0;
	let found = s.byteIndexOf(delimiter, 0);
	while (found >= 0) {
		parts.push(s.byteSlice(pos, found));
		pos = found + delimiterLength;
		found = s.byteIndexOf(delimiter, pos);
	}
	parts.push(s.byteSlice(pos, s.byteLength()));
	return parts;
}

export function replace(this s: string, search: string, replacement: string): string {
	const found = s.byteIndexOf(search, 0);
	if (found < 0) return s;
	return s.byteSlice(0, found) + replacement + s.byteSlice(found + search.byteLength(), s.byteLength());
}

export function replaceAll(this s: string, search: string, replacement: string): string {
	const searchLength = search.byteLength();
	if (searchLength == 0) {
		let spread = replacement;
		const units = s.length;
		for (let unit = 0; unit < units; unit++) { spread += codeUnitAt(s, unit); spread += replacement; }
		return spread;
	}
	let found = s.byteIndexOf(search, 0);
	if (found < 0) return s;
	let result = s.byteSlice(0, found);
	let pos = 0;
	while (found >= 0) {
		result += replacement;
		pos = found + searchLength;
		found = s.byteIndexOf(search, pos);
		if (found >= 0) result += s.byteSlice(pos, found);
	}
	result += s.byteSlice(pos, s.byteLength());
	return result;
}
