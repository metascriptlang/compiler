// String Utilities — specialized helpers not covered by std/core/string extension methods.
// Generic operations (charAt, slice, trim, contains) use extension methods directly.

// Extract the part after the last occurrence of a delimiter.
// "Kind.A" with "." → "A". "A" with "." → "A" (unchanged).
export function bareAfterDelim(s: string, delim: string): string {
	let result = s;
	let i = 0;
	while (i < s.length) {
		if (s.charAt(i) === delim) {
			result = s.slice(i + 1, s.length);
		}
		i = i + 1;
	}
	return result;
}

export function findChar(s: string, ch: string): number {
	let depth = 0;
	for (let i = 0; i < s.length; i += 1) {
		const c = s.charAt(i);
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
		const c = s.charAt(i);
		if (c === "<" || c === "(" || c === "{" || c === "[") { depth += 1; }
		if (c === ">" || c === ")" || c === "}" || c === "]") {
			// Don't count `>` that is the tail of an arrow-function `=>` — without
			// this, splitting a type-arg list like `string, (s: string) => Result<string, string>`
			// goes wrong: the arrow's `>` drops depth to -1, then the nested
			// `Result<...>`'s comma is mistakenly treated as a top-level separator.
			const prev = i > 0 ? s.charAt(i - 1) : "";
			if (!(c === ">" && prev === "=")) {
				depth -= 1;
			}
		}
		if (depth === 0 && c === delim) {
			parts.push(s.slice(start, i).trim());
			start = i + 1;
		}
	}
	if (start < s.length) {
		parts.push(s.slice(start, s.length).trim());
	}
	return parts;
}

export function parseIntStr(s: string): number {
	let result = 0;
	let i = 0;
	while (i < s.byteLength) {
		const code = s.byteAt(i);
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
	if (s.byteLength > 2 && s.charAt(0) === "0") {
		const prefix = s.charAt(1);
		if (prefix === "x" || prefix === "X") {
			let result: number = 0;
			let i = 2;
			while (i < s.byteLength) {
				const ch = s.byteAt(i);
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
			while (i < s.byteLength) {
				if (s.charAt(i) === "1") { result = result * 2 + 1; }
				else if (s.charAt(i) === "0") { result = result * 2; }
				i = i + 1;
			}
			return result;
		}
		if (prefix === "o" || prefix === "O") {
			let result: number = 0;
			let i = 2;
			while (i < s.byteLength) {
				const ch = s.byteAt(i);
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

// Exact integer view of the same literal text parseNumberLiteral accepts.
// Accumulating in int64 instead of a double is the whole point: `parseFloat`
// and the `result * 16 + d` loops above both round off past 2^53.
// Callers must only use this when the literal has no fraction/exponent.
export function parseIntegerLiteral(s: string): int64 {
	let neg = false;
	let start = 0;
	if (s.byteLength > 0 && s.byteAt(0) === "-".code) { neg = true; start = 1; }

	let radix: int64 = 10;
	if (s.byteLength > start + 2 && s.charAt(start) === "0") {
		const prefix = s.charAt(start + 1);
		if (prefix === "x" || prefix === "X") { radix = 16; start = start + 2; }
		else if (prefix === "b" || prefix === "B") { radix = 2; start = start + 2; }
		else if (prefix === "o" || prefix === "O") { radix = 8; start = start + 2; }
	}

	let result: int64 = 0;
	for (let i = start; i < s.byteLength; i = i + 1) {
		const ch = s.byteAt(i);
		if (ch === "_".code) { continue; }
		let digit: int64 = -1;
		if (ch >= "0".code && ch <= "9".code) { digit = (ch - "0".code) as int64; }
		else if (ch >= "a".code && ch <= "f".code) { digit = (ch - "a".code + 10) as int64; }
		else if (ch >= "A".code && ch <= "F".code) { digit = (ch - "A".code + 10) as int64; }
		if (digit < 0 || digit >= radix) { continue; }
		result = result * radix + digit;
	}
	return neg ? -result : result;
}

// Does this decimal digit string fit int64? Compared as text because the value
// is by definition one a double (and possibly an int64) cannot hold, so there is
// no numeric type available to range-check it in.
export function fitsInt64Decimal(s: string, negative: boolean): boolean {
	let start = 0;
	if (s.byteLength > 0 && (s.byteAt(0) === "-".code || s.byteAt(0) === "+".code)) { start = 1; }
	while (start < s.byteLength - 1 && s.byteAt(start) === "0".code) { start = start + 1; }
	const digits = s.slice(start, s.byteLength);
	const limit = negative ? "9223372036854775808" : "9223372036854775807";
	if (digits.byteLength < limit.byteLength) return true;
	if (digits.byteLength > limit.byteLength) return false;
	for (let i = 0; i < digits.byteLength; i = i + 1) {
		const a = digits.byteAt(i);
		const b = limit.byteAt(i);
		if (a < b) return true;
		if (a > b) return false;
	}
	return true;
}

test "fitsInt64Decimal at the boundary" {
	assert fitsInt64Decimal("9223372036854775807", false);
	assert !fitsInt64Decimal("9223372036854775808", false);
	assert fitsInt64Decimal("9223372036854775808", true);
	assert !fitsInt64Decimal("123456789012345678901234567890", false);
	assert fitsInt64Decimal("0000009007199254740993", false);
}

// Decimal digits straight from an int64. Deliberately hand-rolled instead of
// `.toString()`: this runs inside the compiler, so a build made by a generation
// whose toString still routed through a double would emit truncated digits and
// the defect would survive its own fix.
export function int64ToDecimal(v: int64): string {
	if (v === 0) return "0";
	// Accumulate on the negative side — INT64_MIN has no positive counterpart.
	let n: int64 = v > 0 ? 0 - v : v;
	let out = "";
	while (n !== 0) {
		const digit: int64 = 0 - (n % 10);
		out = "0123456789".charAt(digit as int32) + out;
		n = n / 10;
	}
	return v < 0 ? "-" + out : out;
}

test "int64ToDecimal past 2^53" {
	assert int64ToDecimal(parseIntegerLiteral("9007199254740993")) === "9007199254740993";
}
test "int64ToDecimal int64 max" {
	assert int64ToDecimal(parseIntegerLiteral("9223372036854775807")) === "9223372036854775807";
}
test "int64ToDecimal zero" { assert int64ToDecimal(0) === "0"; }
test "int64ToDecimal negative" { assert int64ToDecimal(-42) === "-42"; }

test "parseIntegerLiteral keeps digits past 2^53" {
	assert parseIntegerLiteral("9007199254740993") === 9007199254740993;
}
test "parseIntegerLiteral int64 max" {
	assert parseIntegerLiteral("9223372036854775807") === 9223372036854775807;
}
test "parseIntegerLiteral hex" { assert parseIntegerLiteral("0xFF") === 255; }
test "parseIntegerLiteral binary" { assert parseIntegerLiteral("0b1111") === 15; }
test "parseIntegerLiteral octal" { assert parseIntegerLiteral("0o17") === 15; }
test "parseIntegerLiteral negative" { assert parseIntegerLiteral("-42") === -42; }

test "parseNumberLiteral hex" { assert parseNumberLiteral("0xFF") === 255; }
test "parseNumberLiteral binary" { assert parseNumberLiteral("0b1111") === 15; }
test "parseNumberLiteral octal" { assert parseNumberLiteral("0o17") === 15; }
test "parseNumberLiteral decimal" { assert parseNumberLiteral("42") === 42; }
test "parseNumberLiteral float" { assert parseNumberLiteral("3.14") === 3.14; }

// Extract directory from a file path (everything before last '/').
export function getModuleDir(path: string): string {
	let lastSlash = -1;
	let i = 0;
	while (i < path.length) {
		if (path.charAt(i) === "/") lastSlash = i;
		i = i + 1;
	}
	if (lastSlash <= 0) return "";
	return path.slice(0, lastSlash);
}

// Check if a space-separated flag string contains an exact flag (word-boundary match).
// Avoids substring false positives: "-I/usr" must not match "-I/usr/local".
function hasExactFlag(flags: string, flag: string): boolean {
	if (flags === flag) return true;
	// Pad with spaces so every flag is bounded by spaces
	const padded = " " + flags + " ";
	const needle = " " + flag + " ";
	return padded.contains(needle);
}

// Append a space-separated flag, deduplicating via exact word-boundary match.
export function appendFlag(flags: string, flag: string): string {
	if (flags !== "" && hasExactFlag(flags, flag)) return flags;
	if (flags !== "") return flags + " " + flag;
	return flag;
}

// Prepend a space-separated flag (no dedup — matches reference linker behavior).
export function prependFlag(flags: string, flag: string): string {
	if (flag === "") return flags;
	if (flags !== "") return flag + " " + flags;
	return flag;
}

// Concat a space-separated flag without dedup (matches reference @passL behavior).
export function concatFlag(flags: string, flag: string): string {
	if (flag === "") return flags;
	if (flags !== "") return flags + " " + flag;
	return flag;
}

test "startsWith match" { assert "std/testing".startsWith("std/"); }

test "startsWith no match" { assert !"./foo".startsWith("std/"); }

test "startsWith too short" { assert !"st".startsWith("std/"); }

test "startsWith exact" { assert "abc".startsWith("abc"); }

// ===== Hash (re-exported from std/hash) =====

import { djb2, hashStringSigned } from "std/hash";

export function djb2Hash(s: string): int64 { return djb2(s); }
export function djb2HashSigned(s: string): int32 { return hashStringSigned(s); }
