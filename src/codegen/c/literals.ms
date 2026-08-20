// C Codegen — Literal Emission
//
// String pool management, C string escaping,
// number formatting for C output.

import { Builder, addLine, createBuilder, extract, StringPool, createStringPool, internString } from "./context";
import { Type, TypeKind, NumberLiteralData } from "../../ast/node";
import { int64ToDecimal, uint64ToDecimal } from "../../utils/string";


// ===== C String Escaping =====
// Produces a C-compatible escaped string literal body (without quotes).

// Port of Nim's toCChar (compiler/msgs.nim): every byte outside printable ASCII
// is emitted as a 3-digit OCTAL escape. C hex escapes have no length bound, so
// "\\xC3" followed by a hex digit parses as one out-of-range escape; octal is
// self-terminating after 3 digits.
function octalEscape(b: number): string {
	return "\\" + ((b >> 6) & 7).toString() + ((b >> 3) & 7).toString() + (b & 7).toString();
}

// BYTE-PURE walk: indexes here are UTF-8 byte offsets, so only the byte tier
// (byteAt/byteLength/byteSlice — host-uniform) may be used. charAt/slice are
// UTF-16-unit APIs: past the first non-ASCII character a byte offset reads the
// wrong position (the gen-2 string-corruption bug). Plain bytes are copied in
// RUNS so multi-byte UTF-8 sequences stay intact through byteSlice.
export function escapeCString(s: string): string {
	let result = "";
	let runStart = 0;
	let i = 0;
	while (i < s.byteLength) {
		const b = s.byteAt(i);
		if (b < 32 || b >= 127 || b === "\\".code || b === "\"".code
				|| b === "'".code || b === "?".code) {
			if (runStart < i) result = result + s.byteSlice(runStart, i);
			result = result + match (b) {
				"\\".code => "\\\\",
				"\"".code => "\\\"",
				"'".code => "\\'",
				"?".code => "\\?",
				"\n".code => "\\n",
				"\r".code => "\\r",
				"\t".code => "\\t",
				_ => octalEscape(b),
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

// Escapes are decoded by the lexer, so a token value is already pure UTF-8 bytes
// and each byte is exactly one C byte.
export function cStringByteLen(s: string): number {
	return s.byteLength;
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

// Literal emission for a NumberLiteral node: integers take the exact int64,
// floats (and integer literals in float position) keep the double formatter.
export function formatCNumberLit(d: NumberLiteralData, ty: Type | null = null): string {
	const wantsFloat = ty !== null
		&& (ty.kind === TypeKind.Number || ty.kind === TypeKind.Float32 || ty.kind === TypeKind.Float64);
	const wantsUint64 = ty !== null && ty.kind === TypeKind.Uint64;
	const wantsInt64 = ty !== null && ty.kind === TypeKind.Int64;
	if (d.isFloat || wantsFloat) return formatCNumber(d.value, ty);
	if (wantsUint64) {
		return formatCUint64(d.intVal as uint64);
	}
	if (wantsInt64) {
		return formatCInt64(d.intVal);
	}
	return formatCIntLiteral(d.intVal);
}

export function formatCIntLiteral(v: int64): string {
	if (v > -2147483648 && v <= 2147483647) return int64ToDecimal(v);
	if (v === -2147483648) return "(-2147483647 -1)";
	return formatCInt64(v);
}

// Format as int32
export function formatCInt32(value: number): string {
	return "" + value;
}

// Format as int64
const int64MinValue: int64 = -9223372036854775808;

export function formatCInt64(v: int64): string {
	if (v > int64MinValue) return int64ToDecimal(v) + "LL";
	return "(-9223372036854775807LL - 1LL)";
}

// Format as uint32
export function formatCUint32(value: number): string {
	return `${value}U`;
}

// Format as uint64
export function formatCUint64(v: uint64): string {
	return uint64ToDecimal(v) + "ULL";
}

// Format as float32
export function formatCFloat32(value: number): string {
	return `${value}f`;
}

// ===== String Pool Emission =====
// Emits interned string payload structs for msString literal support.
// Each entry becomes a static const struct { int64_t cap; char data[N+1]; }
// (.rodata) with MS_STRLIT_FLAG plus baked ASCII-check flags in cap, so the
// runtime never writes into a literal payload. Usage: MS_STRING_LIT(&name, len)

export function emitStringPoolDecls(pool: StringPool, dest: Builder): void {
	for (const entry of pool.entries) {
		const escaped = escapeCString(entry.value);
		const len = cStringByteLen(entry.value);
		let ascii = true;
		for (let i = 0; i < entry.value.byteLength; i++) {
			if (entry.value.byteAt(i) >= 128) {
				ascii = false;
				break;
			}
		}
		const flags = ascii
			? "MS_STRLIT_FLAG | MS_ASCII_CHECKED | MS_ASCII_FLAG"
			: "MS_STRLIT_FLAG | MS_ASCII_CHECKED";
		addLine(dest, `static const struct { int64_t cap; char data[${len + 1}]; } ${entry.cName} = { ${flags} | ${len}, "${escaped}" };`);
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

test "number literal emission dispatches on uint64" {
	const tu: Type = { kind: TypeKind.Uint64, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null, typeFlags: 0 };
	const d: NumberLiteralData = { value: 0.0, isFloat: false, intVal: -1, outOfRangeText: "", isBitPattern: true };
	assert formatCNumberLit(d, tu) === "18446744073709551615ULL";
}

test "number literal emission dispatches on int64" {
	const ti: Type = { kind: TypeKind.Int64, typeName: "", typeNames: [], typeChildren: [], typeReturn: null as unknown as Type, typeExtra: null, typeFlags: 0 };
	const d: NumberLiteralData = { value: 42.0, isFloat: false, intVal: 42, outOfRangeText: "", isBitPattern: false };
	assert formatCNumberLit(d, ti) === "42LL";
}

test "int64 suffix" { assert formatCInt64(42) === "42LL"; }

test "int64 min decomposes" { assert formatCInt64(-9223372036854775808) === "(-9223372036854775807LL - 1LL)"; }

test "int64 max keeps the suffix" { assert formatCInt64(9223372036854775807) === "9223372036854775807LL"; }

test "int literal stays bare inside int32 range" { assert formatCIntLiteral(42) === "42"; }

test "int literal decomposes int32 min" { assert formatCIntLiteral(-2147483648) === "(-2147483647 -1)"; }

test "int literal takes the suffix past int32" { assert formatCIntLiteral(5000000000) === "5000000000LL"; }

test "uint64 max spells the digits" { assert formatCUint64(18446744073709551615) === "18446744073709551615ULL"; }

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

test "backslash-x sequence has its backslash escaped" {
	const backslash = "\\";
	const esc = backslash + "x1b[";
	assert escapeCString(esc) === backslash + backslash + "x1b[";
}

test "control and non-ascii bytes emit octal escapes" {
	assert escapeCString(fromCodePoint(27) + "[") === "\\033[";
	assert escapeCString("hi" + fromCodePoint(10) + "yo") === "hi\\nyo";
	assert escapeCString(fromCodePoint(233)) === "\\303\\251";
}

test "cStringByteLen plain" { assert cStringByteLen("hello") === 5; }

test "cStringByteLen counts raw bytes" {
	const backslash = "\\";
	assert cStringByteLen(backslash + "x1b[") === 5;
	assert cStringByteLen(fromCodePoint(27) + "[0m") === 4;
}
