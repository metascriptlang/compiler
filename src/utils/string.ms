// String Utilities - DRC-safe string helpers (no indexOf/includes)

import { check } from "std/testing";

export function endsWith(s: string, suffix: string): boolean {
	if (s.length < suffix.length) return false;
	return sliceStr(s, s.length - suffix.length, s.length) === suffix;
}

export function startsWith(s: string, prefix: string): boolean {
	if (s.length < prefix.length) return false;
	return sliceStr(s, 0, prefix.length) === prefix;
}

export function trim(s: string): string {
	let start = 0;
	let end = s.length;
	while (start < end && charAt(s, start) === " ") { start += 1; }
	while (end > start && charAt(s, end - 1) === " ") { end -= 1; }
	return sliceStr(s, start, end);
}

export function charAt(s: string, i: number): string {
	return sliceStr(s, i, i + 1);
}

export function sliceStr(s: string, start: number, end: number): string {
	return s.slice(start, end);
}

export function findChar(s: string, ch: string): number {
	let depth = 0;
	for (let i = 0; i < s.length; i += 1) {
		const c = charAt(s, i);
		if (depth === 0 && c === ch) return i;
		if (c === "<") { depth += 1; }
		if (c === ">") { depth -= 1; }
	}
	return -1;
}

export function splitTopLevel(s: string, delim: string): string[] {
	const parts: string[] = [];
	let depth = 0;
	let start = 0;
	for (let i = 0; i < s.length; i += 1) {
		const c = charAt(s, i);
		if (c === "<" || c === "(" || c === "{" || c === "[") { depth += 1; }
		if (c === ">" || c === ")" || c === "}" || c === "]") { depth -= 1; }
		if (depth === 0 && c === delim) {
			parts.push(trim(sliceStr(s, start, i)));
			start = i + 1;
		}
	}
	if (start < s.length) {
		parts.push(trim(sliceStr(s, start, s.length)));
	}
	return parts;
}

test "endsWith match" { check(endsWith("hello.ms", ".ms")); }

test "endsWith no match" { check(!endsWith("hello.ms", ".js")); }

test "endsWith too short" { check(!endsWith("ab", "abc")); }

test "endsWith exact" { check(endsWith(".h", ".h")); }

test "startsWith match" { check(startsWith("std/testing", "std/")); }

test "startsWith no match" { check(!startsWith("./foo", "std/")); }

test "startsWith too short" { check(!startsWith("st", "std/")); }

test "startsWith exact" { check(startsWith("abc", "abc")); }
