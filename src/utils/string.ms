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

test "endsWith match" { assert endsWith("hello.ms", ".ms"); }

test "endsWith no match" { assert !endsWith("hello.ms", ".js"); }

test "endsWith too short" { assert !endsWith("ab", "abc"); }

test "endsWith exact" { assert endsWith(".h", ".h"); }

// Parse number literals including hex (0x), binary (0b), octal (0o) prefixes.
// Falls back to parseFloat for plain decimal/float.
export function parseNumberLiteral(s: string): number {
	if (s.length > 2 && s[0] === "0") {
		const prefix = s[1];
		if (prefix === "x" || prefix === "X") {
			let result: number = 0;
			let i = 2;
			while (i < s.length) {
				const ch = s.charCodeAt(i);
				if (ch >= "0".code && ch <= "9".code) {
					result = result * 16 + (ch - "0".code);
				} else if (ch >= "a".code && ch <= "f".code) {
					result = result * 16 + (ch - "a".code + 10);
				} else if (ch >= "A".code && ch <= "F".code) {
					result = result * 16 + (ch - "A".code + 10);
				}
				i = i + 1;
			}
			return result;
		}
		if (prefix === "b" || prefix === "B") {
			let result: number = 0;
			let i = 2;
			while (i < s.length) {
				if (s[i] === "1") { result = result * 2 + 1; }
				else if (s[i] === "0") { result = result * 2; }
				i = i + 1;
			}
			return result;
		}
		if (prefix === "o" || prefix === "O") {
			let result: number = 0;
			let i = 2;
			while (i < s.length) {
				const ch = s.charCodeAt(i);
				if (ch >= "0".code && ch <= "7".code) {
					result = result * 8 + (ch - "0".code);
				}
				i = i + 1;
			}
			return result;
		}
	}
	return parseFloat(s);
}

test "parseNumberLiteral hex" { assert parseNumberLiteral("0xFF") === 255; }
test "parseNumberLiteral binary" { assert parseNumberLiteral("0b1111") === 15; }
test "parseNumberLiteral octal" { assert parseNumberLiteral("0o17") === 15; }
test "parseNumberLiteral decimal" { assert parseNumberLiteral("42") === 42; }
test "parseNumberLiteral float" { assert parseNumberLiteral("3.14") === 3.14; }

test "startsWith match" { assert startsWith("std/testing", "std/"); }

test "startsWith no match" { assert !startsWith("./foo", "std/"); }

test "startsWith too short" { assert !startsWith("st", "std/"); }

test "startsWith exact" { assert startsWith("abc", "abc"); }
