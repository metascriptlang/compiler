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

export function findChar(s: string, ch: string): int32 {
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

export function parseIntStr(s: string): int32 {
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

export function numericLiteralIsFloat(s: string): boolean {
	if (s.byteLength > 2 && s.charAt(0) === "0") {
		const prefix = s.charAt(1);
		if (prefix === "x" || prefix === "X" || prefix === "b" || prefix === "B" || prefix === "o" || prefix === "O") {
			return false;
		}
	}
	return s.indexOf(".") >= 0 || s.indexOf("e") >= 0 || s.indexOf("E") >= 0;
}

test "numericLiteralIsFloat hex with e" { assert !numericLiteralIsFloat("0xe0"); }

test "numericLiteralIsFloat hex capital" { assert !numericLiteralIsFloat("0xE0"); }

test "numericLiteralIsFloat hex plain" { assert !numericLiteralIsFloat("0xff"); }

test "numericLiteralIsFloat binary octal" { assert !numericLiteralIsFloat("0b1010"); assert !numericLiteralIsFloat("0o17"); }

test "numericLiteralIsFloat decimal" { assert numericLiteralIsFloat("1.5"); assert numericLiteralIsFloat("1e5"); assert numericLiteralIsFloat("1E5"); assert !numericLiteralIsFloat("42"); }

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

type ScannedInteger = { value: int64, fits: boolean, bitPattern: boolean };

// The magnitude is accumulated unsigned: the lexer leaves the sign out of the
// token, so INT64_MIN arrives as the magnitude 2^63, which is not an int64, and
// a signed running accumulator traps on the way there. The limit is built from
// an in-range expression so a compiler generation that still mis-parses the
// boundary can bootstrap the one that does not.
function scanInteger(s: string): ScannedInteger {
	let neg = false;
	let start = 0;
	if (s.byteLength > 0 && s.byteAt(0) === "-".code) { neg = true; start = 1; }

	let radix: uint64 = 10;
	if (s.byteLength > start + 2 && s.charAt(start) === "0") {
		const prefix = s.charAt(start + 1);
		if (prefix === "x" || prefix === "X") { radix = 16; start = start + 2; }
		else if (prefix === "b" || prefix === "B") { radix = 2; start = start + 2; }
		else if (prefix === "o" || prefix === "O") { radix = 8; start = start + 2; }
	}

	// One envelope for every radix: MetaScript has no literal suffix, so the
	// parser cannot know whether the target is int64 or uint64. Narrowing to a
	// signed range is the checker's job (literalFitsInType), which is the only
	// place the expected type is known.
	const limit: uint64 = 0 - 1;

	let acc: uint64 = 0;
	let fits = true;
	for (let i = start; i < s.byteLength; i = i + 1) {
		const ch = s.byteAt(i);
		if (ch === "_".code) { continue; }
		let digit: uint64 = radix;
		if (ch >= "0".code && ch <= "9".code) { digit = (ch - "0".code) as uint64; }
		else if (ch >= "a".code && ch <= "f".code) { digit = (ch - "a".code + 10) as uint64; }
		else if (ch >= "A".code && ch <= "F".code) { digit = (ch - "A".code + 10) as uint64; }
		if (digit >= radix) { continue; }
		if (acc > (limit - digit) / radix) { fits = false; break; }
		acc = acc * radix + digit;
	}
	return { value: (neg ? 0 - acc : acc) as int64, fits, bitPattern: radix !== 10 };
}

export function parseIntegerLiteral(s: string): int64 {
	return scanInteger(s).value;
}

// Whether the literal text denotes a value some 64-bit integer type can hold.
// Decided on the digits, not on a double: at the boundary 9223372036854775807
// and 9223372036854775808 are the same double, so `value` cannot separate them.
export function integerLiteralFits(s: string): boolean {
	return scanInteger(s).fits;
}

// Hex/binary/octal literals denote a BIT PATTERN, so they may fill the whole
// unsigned width of the target and still be legal (0x80 as int8 is -128).
// Decimal literals get the signed range instead. Nim draws the same line, and
// says so at lexer.nim:494-497.
export function integerLiteralIsBitPattern(s: string): boolean {
	return scanInteger(s).bitPattern;
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

export function uint64ToDecimal(v: uint64): string {
	if (v === 0) return "0";
	let n: uint64 = v;
	let out = "";
	while (n !== 0) {
		const digit: uint64 = n % 10;
		out = "0123456789".charAt(digit as int32) + out;
		n = n / 10;
	}
	return out;
}

test "int64ToDecimal past 2^53" {
	assert int64ToDecimal(parseIntegerLiteral("9007199254740993")) === "9007199254740993";
}
test "int64ToDecimal int64 max" {
	assert int64ToDecimal(parseIntegerLiteral("9223372036854775807")) === "9223372036854775807";
}
test "int64ToDecimal zero" { assert int64ToDecimal(0) === "0"; }
test "uint64ToDecimal above int64 max" {
	assert uint64ToDecimal(18446744073709551615) === "18446744073709551615";
}
test "uint64ToDecimal at the sign bit" {
	assert uint64ToDecimal(9223372036854775808) === "9223372036854775808";
}
test "uint64ToDecimal zero" { assert uint64ToDecimal(0) === "0"; }
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

// Compared through int64ToDecimal rather than against a literal: writing the
// boundary as source text here would ask the bootstrapping generation to parse
// the very value it may not yet handle.
test "parseIntegerLiteral reaches int64 min magnitude" {
	assert int64ToDecimal(parseIntegerLiteral("9223372036854775808")) === "-9223372036854775808";
}
test "parseIntegerLiteral bit-pattern radices span the unsigned width" {
	assert int64ToDecimal(parseIntegerLiteral("0x8000000000000000")) === "-9223372036854775808";
	assert parseIntegerLiteral("0xFFFFFFFFFFFFFFFF") === -1;
	assert parseIntegerLiteral("0b1000000000000000000000000000000000000000000000000000000000000000") < 0;
}
// The envelope is the widest 64-bit type, not int64: with no literal suffix the
// parser cannot know whether the target is int64 or uint64, so narrowing to a
// signed range belongs to literalFitsInType, where the expected type is known.
test "integerLiteralFits spans the whole 64-bit envelope" {
	assert integerLiteralFits("9223372036854775807");
	assert integerLiteralFits("9223372036854775808");
	assert integerLiteralFits("18446744073709551615");
	assert integerLiteralFits("9_223_372_036_854_775_807");
	assert !integerLiteralFits("18446744073709551616");
	assert !integerLiteralFits("99999999999999999999");
}
test "integerLiteralFits on the bit-pattern radices" {
	assert integerLiteralFits("0xFFFFFFFFFFFFFFFF");
	assert !integerLiteralFits("0x1FFFFFFFFFFFFFFFF");
	assert integerLiteralFits("0b1111111111111111111111111111111111111111111111111111111111111111");
	assert !integerLiteralFits("0b11111111111111111111111111111111111111111111111111111111111111111");
}

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

export function optionalizeTypeString(typeStr: string): string {
	const trimmed = typeStr.trim();
	if (trimmed === "" || trimmed === "null") return trimmed;
	if (hasTopLevelNullMember(trimmed)) return trimmed;
	return "(" + trimmed + ") | null";
}

function hasTopLevelNullMember(s: string): boolean {
	let depth = 0;
	let quote = "";
	let segStart = 0;
	for (let i = 0; i < s.length; i += 1) {
		const ch = s.charAt(i);
		if (quote !== "") {
			if (ch === quote) quote = "";
		} else if (ch === "\"" || ch === "'" || ch === "`") {
			quote = ch;
		} else if (ch === "(" || ch === "[" || ch === "{" || ch === "<") {
			depth += 1;
		} else if (ch === ")" || ch === "]" || ch === "}") {
			depth -= 1;
		} else if (ch === ">") {
			if (i > 0 && s.charAt(i - 1) === "=") {
				if (depth === 0) return false;
			} else {
				depth -= 1;
			}
		} else if (ch === "|" && depth === 0) {
			if (s.slice(segStart, i).trim() === "null") return true;
			segStart = i + 1;
		}
	}
	return s.slice(segStart, s.length).trim() === "null";
}

test "optionalize simple" { assert optionalizeTypeString("number") === "(number) | null"; }

test "optionalize keeps existing top-level null" { assert optionalizeTypeString("NeonView | null") === "NeonView | null"; }

test "optionalize fn type wraps whole" { assert optionalizeTypeString("(x: int32) => int32") === "((x: int32) => int32) | null"; }

test "optionalize fn returning null union still wraps" { assert optionalizeTypeString("(x: int32) => int32 | null") === "((x: int32) => int32 | null) | null"; }

test "optionalize literal union" { assert optionalizeTypeString("\"row\" | \"column\"") === "(\"row\" | \"column\") | null"; }

test "optionalize generic with nested null" { assert optionalizeTypeString("Map<string, T | null>") === "(Map<string, T | null>) | null"; }

test "optionalize parenthesized fn union unchanged" { assert optionalizeTypeString("((x: int32) => int32) | null") === "((x: int32) => int32) | null"; }

test "optionalize bare null" { assert optionalizeTypeString("null") === "null"; }

test "optionalize empty" { assert optionalizeTypeString("") === ""; }

test "startsWith match" { assert "std/testing".startsWith("std/"); }

test "startsWith no match" { assert !"./foo".startsWith("std/"); }

test "startsWith too short" { assert !"st".startsWith("std/"); }

test "startsWith exact" { assert "abc".startsWith("abc"); }

// ===== Hash (re-exported from std/hash) =====

import { djb2, hashStringSigned } from "std/hash";

export function djb2Hash(s: string): int64 { return djb2(s); }
export function djb2HashSigned(s: string): int32 { return hashStringSigned(s); }
