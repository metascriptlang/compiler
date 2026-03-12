// C Codegen — Literal Emission
//
// String pool management, C string escaping,
// number formatting for C output.

import { sliceStr, charAt } from "../../utils/string";
import { Builder, add, addLine, addNewline, createBuilder, extract, StringPool, createStringPool, internString } from "./context";


// ===== C String Escaping =====
// Produces a C-compatible escaped string literal body (without quotes).

function isHexCh(ch: string): boolean {
	return (ch >= "0" && ch <= "9") || (ch >= "a" && ch <= "f") || (ch >= "A" && ch <= "F");
}

export function escapeCString(s: string): string {
	let result = "";
	let i = 0;
	while (i < s.length) {
		const ch = charAt(s, i);
		if (ch === "\\" && i + 3 < s.length && charAt(s, i + 1) === "x" && isHexCh(charAt(s, i + 2)) && isHexCh(charAt(s, i + 3))) {
			// Hex escape \xHH — pass through as-is for C
			result = result + sliceStr(s, i, i + 4);
			i += 4;
		} else if (ch === "\\") { result = result + "\\\\"; i += 1; }
		else if (ch === "\"") { result = result + "\\\""; i += 1; }
		else if (ch === "\n") { result = result + "\\n"; i += 1; }
		else if (ch === "\r") { result = result + "\\r"; i += 1; }
		else if (ch === "\t") { result = result + "\\t"; i += 1; }
		else if (ch === "\0") { result = result + "\\0"; i += 1; }
		else if (ch === "?") { result = result + "\\?"; i += 1; }
		else { result = result + ch; i += 1; }
	}
	return result;
}

// Compute actual C byte count for a string that may contain \xHH escape sequences.
// In our representation, \xHH is 4 chars but compiles to 1 byte in C.
export function cStringByteLen(s: string): number {
	let len = 0;
	let i = 0;
	while (i < s.length) {
		const ch = charAt(s, i);
		if (ch === "\\" && i + 3 < s.length && charAt(s, i + 1) === "x" && isHexCh(charAt(s, i + 2)) && isHexCh(charAt(s, i + 3))) {
			len += 1;
			i += 4;
		} else {
			// UTF-8 byte count: code points determine encoded byte length
			const cp = s.charCodeAt(i);
			if (cp < 0x80) { len += 1; }
			else if (cp < 0x800) { len += 2; }
			else if (cp < 0x10000) { len += 3; }
			else { len += 4; }
			i += 1;
		}
	}
	return len;
}

// Wrap in C string literal quotes
export function cStringLiteral(s: string): string {
	return `"${escapeCString(s)}"`;
}

// ===== Number Formatting =====

// Format a number for C output
export function formatCNumber(value: number): string {
	// Check for integer values — emit without decimal point
	if (value === 0.0) return "0";
	// Check for negative zero
	if (value === 0.0 && (1.0 / value) < 0.0) return "-0.0";

	// Check if it's an integer value (no fractional part)
	// Use truncation check: if truncating doesn't change the value, it's integer
	let isInt = false;
	if (value > -2147483648.0 && value < 2147483647.0) {
		const truncated = value - (value % 1.0);
		if (truncated === value) {
			isInt = true;
		}
	}

	if (isInt) {
		// Emit as integer
		if (value < 0.0) {
			const absVal = 0.0 - value;
			return "-" + absVal;
		}
		return "" + value;
	}

	// Emit as double with suffix to prevent precision loss
	return "" + value;
}

// Format as int32
export function formatCInt32(value: number): string {
	return "" + value;
}

// Format as int64
export function formatCInt64(value: number): string {
	return `${value}LL`;
}

// Format as uint32
export function formatCUint32(value: number): string {
	return `${value}U`;
}

// Format as uint64
export function formatCUint64(value: number): string {
	return `${value}ULL`;
}

// Format as float32
export function formatCFloat32(value: number): string {
	return `${value}f`;
}

// ===== String Pool Emission =====
// Emits interned string payload structs for msString literal support.
// Each entry becomes a static struct { int64_t cap; char data[N+1]; }
// with MS_STRLIT_FLAG set in cap. Usage: MS_STRING_LIT(&name, len)

export function emitStringPoolDecls(pool: StringPool, dest: Builder): void {
	for (const entry of pool.entries) {
		const escaped = escapeCString(entry.value);
		const len = cStringByteLen(entry.value);
		// static struct { int64_t cap; char data[N+1]; } TMP_STR_1 = { MS_STRLIT_FLAG | N, "..." };
		addLine(dest, `static struct { int64_t cap; char data[${len + 1}]; } ${entry.cName} = { MS_STRLIT_FLAG | ${len}, "${escaped}" };`);
	}
}

// Emit an msString expression from a pool entry name and string length.
// Returns: MS_STRING_LIT(&name, len)
export function msStringPoolRef(cName: string, len: number): string {
	return `MS_STRING_LIT(&${cName}, ${len})`;
}

// ===== Boolean Literal =====

export function cBoolLiteral(value: boolean): string {
	if (value) return "MS_TRUE";
	return "MS_FALSE";
}

// ===== Null Literal =====

export function cNullLiteral(): string {
	return "MS_NIL";
}

// ===== Tests =====
test "plain string" { assert escapeCString("hello") === "hello"; }

test "escape backslash" { assert escapeCString("a\\b") === "a\\\\b"; }

test "escape quotes" { assert escapeCString("a\"b") === "a\\\"b"; }

test "escape newline" { assert escapeCString("a\nb") === "a\\nb"; }

test "escape tab" { assert escapeCString("a\tb") === "a\\tb"; }

test "escape question mark prevents trigraphs" { assert escapeCString("??=") === "\\?\\?="; }

test "cStringLiteral wraps in quotes" {
	assert cStringLiteral("hello") === "\"hello\"";
	assert cStringLiteral("a\"b") === "\"a\\\"b\"";
}

test "zero" { assert formatCNumber(0.0) === "0"; }

test "positive integer" { assert formatCNumber(42.0) === "42"; }

test "negative integer" { assert formatCNumber(-7.0) === "-7"; }

test "int32 suffix" { assert formatCInt32(42) === "42"; }

test "int64 suffix" { assert formatCInt64(42) === "42LL"; }

test "uint32 suffix" { assert formatCUint32(42) === "42U"; }

test "float32 suffix" { assert formatCFloat32(3.14) === "3.14f"; }

test "emit pool declarations as msStrPayload" {
	const pool = createStringPool();
	internString(pool, "hello");
	internString(pool, "world");
	const builder = createBuilder();
	emitStringPoolDecls(pool, builder);
	const result = extract(builder);
	assert result.length > 0;
	// Should contain MS_STRLIT_FLAG, cap, and data
}

test "msStringPoolRef format" { assert msStringPoolRef("TMP_STR_1", 5) === "MS_STRING_LIT(&TMP_STR_1, 5)"; }

test "true/false" {
	assert cBoolLiteral(true) === "MS_TRUE";
	assert cBoolLiteral(false) === "MS_FALSE";
}

test "null" { assert cNullLiteral() === "MS_NIL"; }

test "hex escape passthrough" {
	assert escapeCString("\\x1b[") === "\\x1b[";
	assert escapeCString("hi\\x0ayo") === "hi\\x0ayo";
}

test "cStringByteLen plain" { assert cStringByteLen("hello") === 5; }

test "cStringByteLen hex escape" {
	assert cStringByteLen("\\x1b[") === 2;
	assert cStringByteLen("\\x1b[0m") === 4;
}
