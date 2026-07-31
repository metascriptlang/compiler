// MetaScript String Prelude — Shared Byte-Loop Algorithms
// Single source for BOTH backends (Nim model: algorithms here, per-backend
// kernels asBytes/asString + extern fast paths stay in index.cms / index.jms).
// Strings are UTF-8 byte arrays on both backends; everything here uses ONLY
// asBytes/asString + uint8[] push/indexing/.length — the rest of the uint8[]
// method surface is blocked on the §2 15-methods row (neon BUGS.md).
// ⚠ Every COMPUTED push must cast `as uint8` (a number-typed arg silently
// binds the number[] overload on C — §2 push-dispatch facet).

export function startsWith(this s: string, prefix: string): boolean {
	const sb = s.asBytes();
	const pb = prefix.asBytes();
	if (pb.length === 0) return true;
	if (sb.length < pb.length) return false;
	let i = 0;
	while (i < pb.length) {
		if (sb[i] !== pb[i]) return false;
		i = i + 1;
	}
	return true;
}

export function endsWith(this s: string, suffix: string): boolean {
	const sb = s.asBytes();
	const xb = suffix.asBytes();
	if (xb.length === 0) return true;
	if (sb.length < xb.length) return false;
	const off = sb.length - xb.length;
	let i = 0;
	while (i < xb.length) {
		if (sb[off + i] !== xb[i]) return false;
		i = i + 1;
	}
	return true;
}

export function contains(this s: string, sub: string): boolean {
	return s.byteIndexOf(sub, 0) >= 0;
}

export function byteIndexOf(this s: string, sub: string, start: int64 = 0): int64 {
	const sb = s.asBytes();
	const xb = sub.asBytes();
	if (xb.length === 0) return start;
	if (start > sb.length) return -1;
	let i = start;
	if (i < 0) i = 0;
	while (i <= sb.length - xb.length) {
		let found = true;
		let j = 0;
		while (j < xb.length) {
			if (sb[i + j] !== xb[j]) { found = false; break; }
			j = j + 1;
		}
		if (found) return i;
		i = i + 1;
	}
	return -1;
}

export function byteLastIndexOf(this s: string, sub: string, startIdx: int64 = -1): int64 {
	const sb = s.asBytes();
	const xb = sub.asBytes();
	if (xb.length === 0) return sb.length as int64;
	if (xb.length > sb.length) return -1;
	let i = sb.length - xb.length;
	if (startIdx >= 0 && startIdx < i) i = startIdx;
	while (i >= 0) {
		let found = true;
		let j = 0;
		while (j < xb.length) {
			if (sb[i + j] !== xb[j]) { found = false; break; }
			j = j + 1;
		}
		if (found) return i as int64;
		i = i - 1;
	}
	return -1;
}

// Non-overlapping occurrences. An empty needle counts every gap: byteLength + 1.
export function count(this s: string, sub: string): int64 {
	const sb = s.asBytes();
	const xb = sub.asBytes();
	if (xb.length === 0) return (sb.length + 1) as int64;
	let n: int64 = 0;
	let pos = 0;
	while (pos <= sb.length - xb.length) {
		const found = s.byteIndexOf(sub, pos);
		if (found < 0) break;
		n = n + 1;
		pos = found + xb.length;
	}
	return n;
}

export function trim(this s: string): string {
	const sb = s.asBytes();
	if (sb.length === 0) return "";
	let a = 0;
	let b = sb.length - 1;
	while (a <= b && isSpaceByte(sb[a])) { a = a + 1; }
	while (b >= a && isSpaceByte(sb[b])) { b = b - 1; }
	return s.byteSlice(a, b + 1);
}

export function trimStart(this s: string): string {
	const sb = s.asBytes();
	if (sb.length === 0) return "";
	let a = 0;
	while (a < sb.length && isSpaceByte(sb[a])) { a = a + 1; }
	return s.byteSlice(a, sb.length);
}

export function trimEnd(this s: string): string {
	const sb = s.asBytes();
	if (sb.length === 0) return "";
	let b = sb.length;
	while (b > 0 && isSpaceByte(sb[b - 1])) { b = b - 1; }
	return s.byteSlice(0, b);
}

export function split(this s: string, delimiter: string): string[] {
	const sb = s.asBytes();
	const db = delimiter.asBytes();
	const parts: string[] = [];
	if (sb.length === 0) { parts.push(""); return parts; }
	if (db.length === 0) {
		let c = 0;
		while (c < sb.length) { parts.push(s.byteSlice(c, c + 1)); c = c + 1; }
		return parts;
	}
	let pos = 0;
	while (pos <= sb.length) {
		const found = s.byteIndexOf(delimiter, pos);
		if (found < 0) { parts.push(s.byteSlice(pos, sb.length)); break; }
		parts.push(s.byteSlice(pos, found));
		pos = found + db.length;
	}
	return parts;
}

export function toLowerCase(this s: string): string {
	const sb = s.asBytes();
	const result: uint8[] = [];
	let i = 0;
	while (i < sb.length) { result.push(asciiLower(sb[i]) as uint8); i = i + 1; }
	return result.asString();
}

export function toUpperCase(this s: string): string {
	const sb = s.asBytes();
	const result: uint8[] = [];
	let i = 0;
	while (i < sb.length) { result.push(asciiUpper(sb[i]) as uint8); i = i + 1; }
	return result.asString();
}

export function replace(this s: string, search: string, replacement: string): string {
	const sb = s.asBytes();
	const xb = search.asBytes();
	if (sb.length === 0 || xb.length === 0) return s.byteSlice(0, sb.length);
	const pos = s.byteIndexOf(search, 0);
	if (pos < 0) return s.byteSlice(0, sb.length);
	const rb = replacement.asBytes();
	const result: uint8[] = [];
	let i = 0;
	while (i < pos) { result.push(sb[i]); i = i + 1; }
	let j = 0;
	while (j < rb.length) { result.push(rb[j]); j = j + 1; }
	i = pos + xb.length;
	while (i < sb.length) { result.push(sb[i]); i = i + 1; }
	return result.asString();
}

export function replaceAll(this s: string, search: string, replacement: string): string {
	const sb = s.asBytes();
	const xb = search.asBytes();
	if (sb.length === 0 || xb.length === 0) return s.byteSlice(0, sb.length);
	const rb = replacement.asBytes();
	const result: uint8[] = [];
	let pos = 0;
	while (pos <= sb.length - xb.length) {
		const found = s.byteIndexOf(search, pos);
		if (found < 0) break;
		let k = pos;
		while (k < found) { result.push(sb[k]); k = k + 1; }
		let j = 0;
		while (j < rb.length) { result.push(rb[j]); j = j + 1; }
		pos = found + xb.length;
	}
	while (pos < sb.length) { result.push(sb[pos]); pos = pos + 1; }
	return result.asString();
}

export function repeat(this s: string, count: int32): string {
	const sb = s.asBytes();
	if (count <= 0 || sb.length === 0) return "";
	const result: uint8[] = [];
	let i = 0;
	while (i < count) {
		let j = 0;
		while (j < sb.length) { result.push(sb[j]); j = j + 1; }
		i = i + 1;
	}
	return result.asString();
}

// Byte reverse, matching msStringReverse — mangles multi-byte UTF-8 on both backends.
export function reverse(this s: string): string {
	const sb = s.asBytes();
	const result: uint8[] = [];
	let i = sb.length - 1;
	while (i >= 0) { result.push(sb[i]); i = i - 1; }
	return result.asString();
}

export function equalsIgnoreCase(this s: string, other: string): boolean {
	const ab = s.asBytes();
	const bb = other.asBytes();
	if (ab.length !== bb.length) return false;
	let i = 0;
	while (i < ab.length) {
		if (asciiLower(ab[i]) !== asciiLower(bb[i])) return false;
		i = i + 1;
	}
	return true;
}

function asciiLower(b: int32): int32 {
	if (b >= "A".code && b <= "Z".code) return b + 32;
	return b;
}

function asciiUpper(b: int32): int32 {
	if (b >= "a".code && b <= "z".code) return b - 32;
	return b;
}

export function isSpaceByte(b: int32): boolean {
	return b === " ".code || (b >= "\t".code && b <= "\r".code);
}
