// Route 15: Checker — bitwise operator type safety
//
// Verifies: bitwise ops (&, |, ^, <<, >>, >>>, ~) require integer operands.
// Reference parity: bitwise ops only have integer overloads.
// Enums allowed (integer-backed). Number warns + implicit int32 cast.
// Float/string/boolean types are rejected at the checker phase.

import { TypeKind } from "../../ast/node";
import { checkSource, errorCount, strictErrorCount, warningCount, hasError, hasWarning } from "./helpers";
import { lookupSymbol } from "../../checker/symbol";
import { Severity } from "../../checker/context";

// ===== Valid: integer bitwise ops =====

test "int32 & int32 is valid" {
	const src = "const a: int32 = 0xFF as int32;\nconst b: int32 = 0x0F as int32;\nconst c = a & b;";
	assert strictErrorCount(src) === 0;
}

test "uint8 | uint8 is valid" {
	const src = "const a: uint8 = 1 as uint8;\nconst b: uint8 = 2 as uint8;\nconst c = a | b;";
	assert strictErrorCount(src) === 0;
}

test "int64 ^ int64 is valid" {
	const src = "const a: int64 = 1 as int64;\nconst b: int64 = 2 as int64;\nconst c = a ^ b;";
	assert strictErrorCount(src) === 0;
}

test "int32 << int32 is valid" {
	const src = "const a: int32 = 1 as int32;\nconst b: int32 = 4 as int32;\nconst c = a << b;";
	assert strictErrorCount(src) === 0;
}

test "int32 >> int32 is valid" {
	const src = "const a: int32 = 16 as int32;\nconst b: int32 = 2 as int32;\nconst c = a >> b;";
	assert strictErrorCount(src) === 0;
}

// ===== number bitwise: warns, does not error =====

test "number & number warns" {
	assert hasWarning("const a: number = 1;\nconst b: number = 2;\nconst c = a & b;", "implicitly casts to int32");
}

test "number | number warns" {
	assert hasWarning("const a: number = 1;\nconst b: number = 2;\nconst c = a | b;", "implicitly casts to int32");
}

test "number << number warns" {
	assert hasWarning("const a: number = 1;\nconst b: number = 4;\nconst c = a << b;", "implicitly casts to int32");
}

test "number & number produces 0 errors, 2 warnings" {
	const src = "const a: number = 1;\nconst b: number = 2;\nconst c = a & b;";
	assert strictErrorCount(src) === 0;
	assert warningCount(src) === 2;
}

test "~number warns" {
	assert hasWarning("const a: number = 42;\nconst b = ~a;", "implicitly casts to int32");
	assert strictErrorCount("const a: number = 42;\nconst b = ~a;") === 0;
}

// ===== Invalid: mixed integer sizes =====

test "int32 & int64 errors (mixed size)" {
	assert hasError("const a: int32 = 1 as int32;\nconst b: int64 = 2 as int64;\nconst c = a & b;", "requires same integer size");
}

test "uint8 | uint32 errors (mixed size)" {
	assert hasError("const a: uint8 = 1 as uint8;\nconst b: uint32 = 2 as uint32;\nconst c = a | b;", "requires same integer size");
}

// ===== Invalid: string/boolean bitwise =====

test "string & string errors" {
	assert hasError("const a = \"hi\";\nconst b = \"lo\";\nconst c = a & b;", "bitwise operator '&' requires integer type");
}

test "boolean | boolean errors" {
	assert hasError("const a = true;\nconst b = false;\nconst c = a | b;", "bitwise operator '|' requires integer type");
}

// ===== Error count validation =====

test "string & string produces 2 errors" {
	const src = "const a = \"hi\";\nconst b = \"lo\";\nconst c = a & b;";
	assert strictErrorCount(src) === 2;
}

test "int32 & int64 produces 1 error (size mismatch)" {
	const src = "const a: int32 = 1 as int32;\nconst b: int64 = 2 as int64;\nconst c = a & b;";
	const ctx = checkSource(src);
	assert ctx !== null;
	let sizeErrors = 0;
	let i = 0;
	while (i < ctx.errors.length) {
		if (ctx.errors[i].message.indexOf("same integer size") >= 0) sizeErrors = sizeErrors + 1;
		i = i + 1;
	}
	assert sizeErrors === 1;
}

// ===== Non-bitwise ops still work on number =====

test "number + number is valid" {
	assert errorCount("const a: number = 1;\nconst b: number = 2;\nconst c = a + b;") === 0;
}

test "number * number is valid" {
	assert errorCount("const a: number = 3;\nconst b: number = 4;\nconst c = a * b;") === 0;
}

test "number === number is valid" {
	assert errorCount("const a: number = 1;\nconst b: number = 2;\nconst c = a === b;") === 0;
}

// ===== Integer type preservation (reference parity: magic procs) =====

test "int32 & int32 result is int32" {
	const src = "const a: int32 = 0xFF as int32;\nconst b: int32 = 0x0F as int32;\nconst c = a & b;";
	const ctx = checkSource(src);
	assert ctx !== null;
	const sym = lookupSymbol(ctx.table, "c");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Int32;
}

test "int32 + int32 result is int32" {
	const src = "const a: int32 = 1 as int32;\nconst b: int32 = 2 as int32;\nconst c = a + b;";
	const ctx = checkSource(src);
	assert ctx !== null;
	const sym = lookupSymbol(ctx.table, "c");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Int32;
}

test "int32 - int32 result is int32" {
	const src = "const a: int32 = 5 as int32;\nconst b: int32 = 3 as int32;\nconst c = a - b;";
	const ctx = checkSource(src);
	assert ctx !== null;
	const sym = lookupSymbol(ctx.table, "c");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Int32;
}

test "int32 * int32 result is int32" {
	const src = "const a: int32 = 3 as int32;\nconst b: int32 = 4 as int32;\nconst c = a * b;";
	const ctx = checkSource(src);
	assert ctx !== null;
	const sym = lookupSymbol(ctx.table, "c");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Int32;
}

test "uint8 | uint8 result is uint8" {
	const src = "const a: uint8 = 1 as uint8;\nconst b: uint8 = 2 as uint8;\nconst c = a | b;";
	const ctx = checkSource(src);
	assert ctx !== null;
	const sym = lookupSymbol(ctx.table, "c");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Uint8;
}

test "number + number result is number" {
	const src = "const a: number = 1;\nconst b: number = 2;\nconst c = a + b;";
	const ctx = checkSource(src);
	assert ctx !== null;
	const sym = lookupSymbol(ctx.table, "c");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Number;
}

test "unary -int32 result is int32" {
	const src = "const a: int32 = 5 as int32;\nconst b = -a;";
	const ctx = checkSource(src);
	assert ctx !== null;
	const sym = lookupSymbol(ctx.table, "b");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Int32;
}

test "~int32 result is int32" {
	const src = "const a: int32 = 0xFF as int32;\nconst b = ~a;";
	const ctx = checkSource(src);
	assert ctx !== null;
	const sym = lookupSymbol(ctx.table, "b");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Int32;
}
