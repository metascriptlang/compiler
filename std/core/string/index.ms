@include("runtime/core/string.h");
@compile("runtime/core/string.c");

export * from "./operatorsKernel";
export { equals, indexOf, lastIndexOf, charAt, charCodeAt, slice, padStart, padEnd, parseFloat, parseInt, capacity, setLength, append, setSlice, stripInPlace, fromCodePoint, fromCharCode, asBytes, byteLength, byteAt, byteSlice, byteIndexOf, byteLastIndexOf } from "./kernel";
import { clampIndex } from "./shared";
export { startsWith, endsWith, contains, count, trim, trimStart, trimEnd, split, toLowerCase, toUpperCase, replace, replaceAll, repeat, reverse, equalsIgnoreCase, asciiLower, asciiUpper, isSpaceByte } from "./shared";

export function substring(this s: string, start: int32, end: int32 = 2147483647): string {
	const a = clampIndex(start, s.length);
	const b = clampIndex(end, s.length);
	return a <= b ? s.slice(a, b) : s.slice(b, a);
}

/** Converts any value to its string representation. Delegates to .toString(). */
@builtin("ToString")
export extern function String<T>(val: T): string;
