// Route 15: Checker — bitwise operator type safety
//
// Verifies: bitwise ops (&, |, ^, <<, >>, >>>, ~) require integer operands.
// Reference parity: bitwise ops only have integer overloads.
// Enums allowed (integer-backed). Number warns + implicit int32 cast.
// Float/string/boolean types are rejected at the checker phase.

import { TypeKind } from "../../ast/node";
import { typeDisplayName } from "../../checker/types";
import { checkSource, errorCount, strictErrorCount, warningCount, hasError, hasWarning } from "./helpers";
import { lookupSymbol } from "../../checker/symbol";
import { Severity } from "../../checker/context";

// ===== Valid: integer bitwise ops =====

test "int32 & int32 is valid" {
	const src = "const a: int32 = 0xFF as int32;\nconst b: int32 = 0x0F as int32;\nconst c = a & b;";
	assert strictErrorCount(src) == 0;
}

test "uint8 | uint8 is valid" {
	const src = "const a: uint8 = 1 as uint8;\nconst b: uint8 = 2 as uint8;\nconst c = a | b;";
	assert strictErrorCount(src) == 0;
}

test "int64 ^ int64 is valid" {
	const src = "const a: int64 = 1 as int64;\nconst b: int64 = 2 as int64;\nconst c = a ^ b;";
	assert strictErrorCount(src) == 0;
}

test "int32 << int32 is valid" {
	const src = "const a: int32 = 1 as int32;\nconst b: int32 = 4 as int32;\nconst c = a << b;";
	assert strictErrorCount(src) == 0;
}

test "int32 >> int32 is valid" {
	const src = "const a: int32 = 16 as int32;\nconst b: int32 = 2 as int32;\nconst c = a >> b;";
	assert strictErrorCount(src) == 0;
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

test "number & number produces 0 errors, 1 warning" {
	const src = "const a: number = 1;\nconst b: number = 2;\nconst c = a & b;";
	assert strictErrorCount(src) == 0;
	assert warningCount(src) == 1;
}

test "~number warns" {
	assert hasWarning("const a: number = 42;\nconst b = ~a;", "implicitly casts to int32");
	assert strictErrorCount("const a: number = 42;\nconst b = ~a;") == 0;
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
	assert strictErrorCount(src) == 2;
}

test "int32 & int64 produces 1 error (size mismatch)" {
	const src = "const a: int32 = 1 as int32;\nconst b: int64 = 2 as int64;\nconst c = a & b;";
	const ctx = checkSource(src);
	assert ctx != null;
	let sizeErrors = 0;
	let i = 0;
	while (i < ctx.errors.length) {
		if (ctx.errors[i].message.indexOf("same integer size") >= 0) sizeErrors = sizeErrors + 1;
		i = i + 1;
	}
	assert sizeErrors == 1;
}

// ===== Non-bitwise ops still work on number =====

test "number + number is valid" {
	assert errorCount("const a: number = 1;\nconst b: number = 2;\nconst c = a + b;") == 0;
}

test "number * number is valid" {
	assert errorCount("const a: number = 3;\nconst b: number = 4;\nconst c = a * b;") == 0;
}

test "number === number is valid" {
	assert errorCount("const a: number = 1;\nconst b: number = 2;\nconst c = a === b;") == 0;
}

// ===== Integer type preservation (reference parity: magic procs) =====

test "int32 & int32 result is int32" {
	const src = "const a: int32 = 0xFF as int32;\nconst b: int32 = 0x0F as int32;\nconst c = a & b;";
	const ctx = checkSource(src);
	assert ctx != null;
	const sym = lookupSymbol(ctx.table, "c");
	assert sym != null;
	assert sym.symbolType.kind == TypeKind.Int32;
}

test "int32 + int32 result is int32" {
	const src = "const a: int32 = 1 as int32;\nconst b: int32 = 2 as int32;\nconst c = a + b;";
	const ctx = checkSource(src);
	assert ctx != null;
	const sym = lookupSymbol(ctx.table, "c");
	assert sym != null;
	assert sym.symbolType.kind == TypeKind.Int32;
}

test "int32 - int32 result is int32" {
	const src = "const a: int32 = 5 as int32;\nconst b: int32 = 3 as int32;\nconst c = a - b;";
	const ctx = checkSource(src);
	assert ctx != null;
	const sym = lookupSymbol(ctx.table, "c");
	assert sym != null;
	assert sym.symbolType.kind == TypeKind.Int32;
}

test "int32 * int32 result is int32" {
	const src = "const a: int32 = 3 as int32;\nconst b: int32 = 4 as int32;\nconst c = a * b;";
	const ctx = checkSource(src);
	assert ctx != null;
	const sym = lookupSymbol(ctx.table, "c");
	assert sym != null;
	assert sym.symbolType.kind == TypeKind.Int32;
}

test "uint8 | uint8 result is uint8" {
	const src = "const a: uint8 = 1 as uint8;\nconst b: uint8 = 2 as uint8;\nconst c = a | b;";
	const ctx = checkSource(src);
	assert ctx != null;
	const sym = lookupSymbol(ctx.table, "c");
	assert sym != null;
	assert sym.symbolType.kind == TypeKind.Uint8;
}

test "number + number result is number" {
	const src = "const a: number = 1;\nconst b: number = 2;\nconst c = a + b;";
	const ctx = checkSource(src);
	assert ctx != null;
	const sym = lookupSymbol(ctx.table, "c");
	assert sym != null;
	assert sym.symbolType.kind == TypeKind.Number;
}

test "unary -int32 result is int32" {
	const src = "const a: int32 = 5 as int32;\nconst b = -a;";
	const ctx = checkSource(src);
	assert ctx != null;
	const sym = lookupSymbol(ctx.table, "b");
	assert sym != null;
	assert sym.symbolType.kind == TypeKind.Int32;
}

test "~int32 result is int32" {
	const src = "const a: int32 = 0xFF as int32;\nconst b = ~a;";
	const ctx = checkSource(src);
	assert ctx != null;
	const sym = lookupSymbol(ctx.table, "b");
	assert sym != null;
	assert sym.symbolType.kind == TypeKind.Int32;
}

// ===== Compound bitwise assignment: the binary operator, stored into the target =====

test "every bitwise compound assignment is valid on a sized integer" {
	assert strictErrorCount("let a: uint8 = 1;\na |= 0x80;\na &= 0x0F;\na ^= 1;\na <<= 1;\na >>= 1;\na >>>= 1;") == 0;
	assert strictErrorCount("let b: int64 = 1;\nconst k: int64 = 3;\nb <<= k;\nb >>= k;\nb |= k;") == 0;
}

test "a BitSet takes |= &= ^= with a member or a set" {
	assert strictErrorCount("enum F { A, B }\nlet s = (0 as BitSet<F>).incl(F.A);\ns |= F.B;\ns &= F.A | F.B;\ns ^= F.A;") == 0;
}

test "a bitwise compound assignment keeps the binary same-size rule" {
	assert hasError("let a: int32 = 1;\nconst w: int64 = 2;\na |= w;", "bitwise operator '|=' requires same integer size");
	assert hasError("let u: uint64 = 1;\nconst c: int32 = 3;\nu <<= c;", "bitwise operator '<<=' requires same integer size");
}

test "a bitwise compound assignment takes the targets its binary operator takes" {
	assert strictErrorCount("let n: number = 5;\nn |= 1;\nn &= 3;\nn ^= 1;\nn <<= 2;\nn >>= 1;\nn >>>= 1;") == 0;
	assert hasWarning("let n: number = 5;\nn |= 1;", "bitwise operator '|=' on 'number' implicitly casts to int32");
	assert hasError("let f: float64 = 5;\nf <<= 1;", "bitwise operator '<<=' requires integer type, got 'float64'");
}

test "a bitwise compound assignment stores only what the target holds" {
	assert hasError("enum E { A, B }\nlet e: E = E.A;\ne |= E.B;", "'|=' cannot store the 'BitSet<E>' result of '|' in 'E'");
	assert hasError("let j: int32 = -1;\nj >>>= 1;", "'>>>=' cannot store the 'uint32' result of '>>>' in 'int32'");
	assert hasError("let j: int8 = -1;\nj >>>= 1;", "'>>>=' cannot store the 'uint8' result of '>>>' in 'int8'");
	assert hasError("let j: int64 = -1;\nj >>>= 1;", "'>>>=' cannot store the 'uint64' result of '>>>' in 'int64'");
}

test "an unsigned right shift of a signed integer is the unsigned type of its width" {
	const cases = [["let i: int8 = -1;\nconst r = i >>> 0;", "uint8"], ["let i: int16 = -1;\nconst r = i >>> 1;", "uint16"],
		["let i: int64 = -1;\nconst r = i >>> 0;", "uint64"], ["let i: uint8 = 255;\nconst r = i >>> 1;", "uint8"]];
	for (const c of cases) {
		const ctx = checkSource(c[0]);
		assert ctx != null, c[0];
		assert typeDisplayName(lookupSymbol(ctx.table, "r").symbolType) == c[1], c[0];
	}
	assert hasError("let i: int8 = -1;\nconst x: int8 = i >>> 1;", "implicit uint8 → int8 conversion may exceed the target's maximum");
}

test "an unsigned right shift of an int32 or a number is uint32" {
	for (const src of ["let i: int32 = -1;\nconst r = i >>> 1;", "let n: number = -1;\nconst r = n >>> 1;", "const r = -1 >>> 0;"]) {
		const ctx = checkSource(src);
		assert ctx != null, src;
		assert lookupSymbol(ctx.table, "r").symbolType.kind == TypeKind.Uint32, src;
	}
	assert strictErrorCount("let i: int32 = -1;\nconst u: uint32 = i >>> 0;") == 0;
	assert hasError("let i: int32 = -1;\nconst x: int32 = i >>> 1;", "implicit uint32 → int32 conversion may exceed the target's maximum");
}

test "a bitwise compound assignment is a statement" {
	assert hasError("let a: int32 = 1;\nconst b = (a |= 2);", "assignment is a statement");
}

test "a bitwise compound assignment refuses what the binary operator refuses on bigint" {
	assert hasError("let g: bigint = 5n;\ng >>>= 1n;", "operator '>>>=' is not allowed on bigint — use '>>='");
	assert hasError("let g: bigint = 5n;\ng |= 1;", "cannot mix bigint and 'int32' in '|='");
}

test "a bitwise compound assignment is a mutation of a readonly parameter" {
	assert hasError("function h(readonly x: uint8[]): void { x[0] |= 2; }", "cannot mutate readonly parameter 'x'");
}
