// MetaScript String Prelude — Shared Byte-Loop Algorithms
// Single source for BOTH backends (Nim model: algorithms here, per-backend
// byte kernels live in bytes.<ext>, extern fast paths in index.<ext>).
// Strings are UTF-8 byte arrays on both backends; everything here uses ONLY
// asBytes/asString + uint8[] push/indexing/.length — the rest of the uint8[]
// method surface is blocked on the §2 15-methods row (neon BUGS.md).
// ⚠ Every COMPUTED push must cast `as uint8` (a number-typed arg silently
// binds the number[] overload on C — §2 push-dispatch facet).

import { asBytes, byteSlice } from "./bytes";

export function clampIndex(i: int32, len: int32): int32 {
	return i < 0 ? 0 : i > len ? len : i;
}

export function trim(this s: string): string {
	const sb = s.asBytes();
	if (sb.length == 0) return "";
	let a = 0;
	let b = sb.length - 1;
	while (a <= b && isSpaceByte(sb[a] as int32)) { a = a + 1; }
	while (b >= a && isSpaceByte(sb[b] as int32)) { b = b - 1; }
	return s.byteSlice(a, b + 1);
}

export function trimStart(this s: string): string {
	const sb = s.asBytes();
	if (sb.length == 0) return "";
	let a = 0;
	while (a < sb.length && isSpaceByte(sb[a] as int32)) { a = a + 1; }
	return s.byteSlice(a, sb.length);
}

export function trimEnd(this s: string): string {
	const sb = s.asBytes();
	if (sb.length == 0) return "";
	let b = sb.length;
	while (b > 0 && isSpaceByte(sb[b - 1] as int32)) { b = b - 1; }
	return s.byteSlice(0, b);
}

export function toLowerCase(this s: string): string {
	const sb = s.asBytes();
	const result: uint8[] = [];
	let i = 0;
	while (i < sb.length) { result.push(asciiLower(sb[i] as int32) as uint8); i = i + 1; }
	return result.asString();
}

export function toUpperCase(this s: string): string {
	const sb = s.asBytes();
	const result: uint8[] = [];
	let i = 0;
	while (i < sb.length) { result.push(asciiUpper(sb[i] as int32) as uint8); i = i + 1; }
	return result.asString();
}

export function repeat(this s: string, count: int32): string {
	const sb = s.asBytes();
	if (count <= 0 || sb.length == 0) return "";
	const result: uint8[] = [];
	let i = 0;
	while (i < count) {
		let j = 0;
		while (j < sb.length) { result.push(sb[j]); j = j + 1; }
		i = i + 1;
	}
	return result.asString();
}

// Byte reverse — mangles multi-byte UTF-8 on both backends.
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
	if (ab.length != bb.length) return false;
	let i = 0;
	while (i < ab.length) {
		if (asciiLower(ab[i] as int32) != asciiLower(bb[i] as int32)) return false;
		i = i + 1;
	}
	return true;
}

// Module-private in spirit, but exported: the Raiser macro checker pulls a
// macro's helper closure by export boundary, so non-exported helpers leave
// these exported algorithms unresolvable inside macro bodies.
export function asciiLower(b: int32): int32 {
	if (b >= "A".code && b <= "Z".code) return b + 32;
	return b;
}

export function asciiUpper(b: int32): int32 {
	if (b >= "a".code && b <= "z".code) return b - 32;
	return b;
}

export function isSpaceByte(b: int32): boolean {
	return b == " ".code || (b >= "\t".code && b <= "\r".code);
}
