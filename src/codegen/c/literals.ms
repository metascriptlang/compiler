// C Codegen — Literal Emission
//
// String pool management, C string escaping,
// number formatting for C output.

import { Builder, addLine, createBuilder, extract, StringPool, createStringPool, internString } from "./context";
import { Type, TypeKind } from "../../ast/node";


// ===== C String Escaping =====
// Produces a C-compatible escaped string literal body (without quotes).

function isHexByte(b: number): boolean {
	return (b >= "0".code && b <= "9".code) || (b >= "a".code && b <= "f".code) || (b >= "A".code && b <= "F".code);
}

// Detect a literal \xHH sequence at byte offset i.
function isHexEscapeAt(s: string, i: number): boolean {
	return s.byteAt(i) === "\\".code && i + 3 < s.byteLength
		&& s.byteAt(i + 1) === "x".code
		&& isHexByte(s.byteAt(i + 2)) && isHexByte(s.byteAt(i + 3));
}

// BYTE-PURE walk (both functions): indexes here are UTF-8 byte offsets, so only
// the byte tier (byteAt/byteLength/byteSlice — host-uniform) may be used.
// charAt/slice are UTF-16-unit APIs: past the first non-ASCII character a byte
// offset reads the wrong position, and the emitted literal length drifts
// (the gen-2 string-corruption bug). All escape-relevant bytes are ASCII, so
// byte comparison is exact; plain bytes are copied in RUNS so multi-byte UTF-8
// sequences stay intact through byteSlice.
export function escapeCString(s: string): string {
	let result = "";
	let runStart = 0;
	let i = 0;
	while (i < s.byteLength) {
		const b = s.byteAt(i);
		if (isHexEscapeAt(s, i)) {
			// Hex escape \xHH — pass through as-is for C (stays in the plain run)
			i += 4;
		} else if (b === "\\".code || b === "\"".code || b === "\n".code
				|| b === "\r".code || b === "\t".code || b === 0 || b === "?".code) {
			if (runStart < i) result = result + s.byteSlice(runStart, i);
			result = result + match (b) {
				"\\".code => "\\\\",
				"\"".code => "\\\"",
				"\n".code => "\\n",
				"\r".code => "\\r",
				"\t".code => "\\t",
				0 => "\\0",
				_ => "\\?",
			};
			i += 1;
			runStart = i;
		} else {
			i += 1;
		}
	}
	if (runStart < s.byteLength) result = result + s.byteSlice(runStart, s.byteLength);
	return result;
}

// Compute actual C byte count for a string that may contain \xHH escape sequences.
// In our representation, \xHH is 4 bytes of source but compiles to 1 byte in C;
// every other byte (including each byte of a multi-byte UTF-8 sequence) is
// exactly one C byte.
export function cStringByteLen(s: string): number {
	let len = 0;
	let i = 0;
	while (i < s.byteLength) {
		if (isHexEscapeAt(s, i)) {
			len += 1;
			i += 4;
		} else {
			len += 1;
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

// Format a number for C output.
// When `type` is a float type (Number/Float32/Float64), integer-valued literals get a
// `.0` suffix so C picks the float overload of operators. Without this, `0.0 / 0.0` in
// MS would emit as `(0 / 0)` and trap as integer divide-by-zero instead of producing
// IEEE 754 NaN.
export function formatCNumber(value: number, type: Type | null = null): string {
	const isFloat = type !== null
		&& (type.kind === TypeKind.Number || type.kind === TypeKind.Float32 || type.kind === TypeKind.Float64);

	// Negative zero — must check before the regular zero branch (1.0 / -0.0 is -Infinity).
	if (value === 0.0 && (1.0 / value) < 0.0) return isFloat ? "-0.0" : "-0";
	if (value === 0.0) return isFloat ? "0.0" : "0";

	// Integer-valued? Truncation check stays bounded to int32 range; larger magnitudes
	// fall through to the precision-preserving double formatter.
	let isInt = false;
	if (value > -2147483648.0 && value < 2147483647.0) {
		const truncated = value - (value % 1.0);
		if (truncated === value) {
			isInt = true;
		}
	}

	if (isInt) {
		const intStr = value < 0.0 ? "-" + (0.0 - value) : "" + value;
		return isFloat ? intStr + ".0" : intStr;
	}

	const text = "" + value;
	if (isFloat && !text.contains(".") && !text.contains("e") && !text.contains("E")) {
		return text + ".0";
	}
	return text;
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

test "zero in float context emits 0.0" {
	const t: Type = { kind: TypeKind.Number, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null, typeFlags: 0 };
	assert formatCNumber(0.0, t) === "0.0";
}

test "positive integer in float context emits .0 suffix" {
	const t: Type = { kind: TypeKind.Float64, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null, typeFlags: 0 };
	assert formatCNumber(1.0, t) === "1.0";
	assert formatCNumber(42.0, t) === "42.0";
}

test "negative integer in float context emits .0 suffix" {
	const t: Type = { kind: TypeKind.Float64, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null, typeFlags: 0 };
	assert formatCNumber(-1.0, t) === "-1.0";
}

test "fractional value unchanged by float context" {
	const t: Type = { kind: TypeKind.Number, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null, typeFlags: 0 };
	assert formatCNumber(0.5, t) === "0.5";
}

test "negative zero in float context emits -0.0" {
	const t: Type = { kind: TypeKind.Number, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null, typeFlags: 0 };
	const negZero: number = -1.0 * 0.0;
	assert formatCNumber(negZero, t) === "-0.0";
}

test "negative zero with null type emits -0" {
	const negZero: number = -1.0 * 0.0;
	assert formatCNumber(negZero) === "-0";
}

test "integer type still emits plain integer" {
	const t: Type = { kind: TypeKind.Int32, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null, typeFlags: 0 };
	assert formatCNumber(42.0, t) === "42";
}

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
