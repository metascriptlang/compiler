// C Codegen — Literal Emission
//
// String pool management (Nim's cfsStrData), C string escaping,
// number formatting for C output.

import { sliceStr, charAt } from "../../utils/string";
import { Builder, add, addLine, addNewline, createBuilder, extract, StringPool, createStringPool, internString } from "./context";


// ===== C String Escaping =====
// Produces a C-compatible escaped string literal body (without quotes).

export function escapeCString(s: string): string {
	let result = "";
	for (let i = 0; i < s.length; i += 1) {
		const ch = charAt(s, i);
		if (ch === "\\") { result = result + "\\\\"; }
		else if (ch === "\"") { result = result + "\\\""; }
		else if (ch === "\n") { result = result + "\\n"; }
		else if (ch === "\r") { result = result + "\\r"; }
		else if (ch === "\t") { result = result + "\\t"; }
		else if (ch === "\0") { result = result + "\\0"; }
		else { result = result + ch; }
	}
	return result;
}

// Wrap in C string literal quotes
export function cStringLiteral(s: string): string {
	return "\"" + escapeCString(s) + "\"";
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
	return "" + value + "LL";
}

// Format as uint32
export function formatCUint32(value: number): string {
	return "" + value + "U";
}

// Format as uint64
export function formatCUint64(value: number): string {
	return "" + value + "ULL";
}

// Format as float32
export function formatCFloat32(value: number): string {
	return "" + value + "f";
}

// ===== String Pool Emission =====
// Emits interned string payload structs for msString literal support.
// Each entry becomes a static struct { int64_t cap; char data[N+1]; }
// with MS_STRLIT_FLAG set in cap. Usage: MS_STRING_LIT(&name, len)

export function emitStringPoolDecls(pool: StringPool, dest: Builder): void {
	for (let i = 0; i < pool.entries.length; i += 1) {
		const entry = pool.entries[i];
		const escaped = escapeCString(entry.value);
		const len = entry.value.length;
		// static struct { int64_t cap; char data[N+1]; } TMP_STR_1 = { MS_STRLIT_FLAG | N, "..." };
		addLine(dest, "static struct { int64_t cap; char data[" + (len + 1) + "]; } " + entry.cName + " = { MS_STRLIT_FLAG | " + len + ", \"" + escaped + "\" };");
	}
}

// Emit an msString expression from a pool entry name and string length.
// Returns: MS_STRING_LIT(&name, len)
export function msStringPoolRef(cName: string, len: number): string {
	return "MS_STRING_LIT(&" + cName + ", " + len + ")";
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
test "plain string" { expect(escapeCString("hello") === "hello"); }

test "escape backslash" { expect(escapeCString("a\\b") === "a\\\\b"); }

test "escape quotes" { expect(escapeCString("a\"b") === "a\\\"b"); }

test "escape newline" { expect(escapeCString("a\nb") === "a\\nb"); }

test "escape tab" { expect(escapeCString("a\tb") === "a\\tb"); }

test "cStringLiteral wraps in quotes" {
	expect(cStringLiteral("hello") === "\"hello\"");
	expect(cStringLiteral("a\"b") === "\"a\\\"b\"");
}

test "zero" { expect(formatCNumber(0.0) === "0"); }

test "positive integer" { expect(formatCNumber(42.0) === "42"); }

test "negative integer" { expect(formatCNumber(-7.0) === "-7"); }

test "int32 suffix" { expect(formatCInt32(42) === "42"); }

test "int64 suffix" { expect(formatCInt64(42) === "42LL"); }

test "uint32 suffix" { expect(formatCUint32(42) === "42U"); }

test "float32 suffix" { expect(formatCFloat32(3.14) === "3.14f"); }

test "emit pool declarations as msStrPayload" {
	const pool = createStringPool();
	internString(pool, "hello");
	internString(pool, "world");
	const builder = createBuilder();
	emitStringPoolDecls(pool, builder);
	const result = extract(builder);
	expect(result.length > 0);
	// Should contain MS_STRLIT_FLAG, cap, and data
}

test "msStringPoolRef format" { expect(msStringPoolRef("TMP_STR_1", 5) === "MS_STRING_LIT(&TMP_STR_1, 5)"); }

test "true/false" {
	expect(cBoolLiteral(true) === "MS_TRUE");
	expect(cBoolLiteral(false) === "MS_FALSE");
}

test "null" { expect(cNullLiteral() === "MS_NIL"); }
