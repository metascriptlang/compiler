// String Utilities - DRC-safe string helpers (no indexOf/includes)


export function endsWith(s: string, suffix: string): boolean {
	if (s.length < suffix.length) return false;
	return sliceStr(s, s.length - suffix.length, s.length) === suffix;
}

export function startsWith(s: string, prefix: string): boolean {
	if (s.length < prefix.length) return false;
	return sliceStr(s, 0, prefix.length) === prefix;
}

export function trimStr(s: string): string {
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
			parts.push(trimStr(sliceStr(s, start, i)));
			start = i + 1;
		}
	}
	if (start < s.length) {
		parts.push(trimStr(sliceStr(s, start, s.length)));
	}
	return parts;
}

export function parseIntStr(s: string): number {
	let result = 0;
	let i = 0;
	while (i < s.length) {
		const code = s.charCodeAt(i);
		if (code >= "0".code && code <= "9".code) {
			result = result * 10 + (code - "0".code);
		}
		i = i + 1;
	}
	return result;
}

test "endsWith match" { expect(endsWith("hello.ms", ".ms")); }

test "endsWith no match" { expect(!endsWith("hello.ms", ".js")); }

test "endsWith too short" { expect(!endsWith("ab", "abc")); }

test "endsWith exact" { expect(endsWith(".h", ".h")); }

test "startsWith match" { expect(startsWith("std/testing", "std/")); }

test "startsWith no match" { expect(!startsWith("./foo", "std/")); }

test "startsWith too short" { expect(!startsWith("st", "std/")); }

test "startsWith exact" { expect(startsWith("abc", "abc")); }
