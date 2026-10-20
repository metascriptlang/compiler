// MetaScript String Prelude — byte-offset search for the C and Raiser backends;
// the JS backend binds the native String methods instead (index.jms).

import { asBytes, byteIndexOf } from "./bytes";

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
