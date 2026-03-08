// String Utilities - DRC-safe string helpers (no indexOf/includes)


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

// Extract the part after the last occurrence of a delimiter.
// "Kind.A" with "." → "A". "A" with "." → "A" (unchanged).
export function bareAfterDelim(s: string, delim: string): string {
	let result = s;
	let i = 0;
	while (i < s.length) {
		if (charAt(s, i) === delim) {
			result = sliceStr(s, i + 1, s.length);
		}
		i = i + 1;
	}
	return result;
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

test "endsWith match" { assert "hello.ms".endsWith(".ms"); }

test "endsWith no match" { assert !"hello.ms".endsWith(".js"); }

test "endsWith too short" { assert !"ab".endsWith("abc"); }

test "endsWith exact" { assert ".h".endsWith(".h"); }

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

test "startsWith match" { assert "std/testing".startsWith("std/"); }

test "startsWith no match" { assert !"./foo".startsWith("std/"); }

test "startsWith too short" { assert !"st".startsWith("std/"); }

test "startsWith exact" { assert "abc".startsWith("abc"); }
