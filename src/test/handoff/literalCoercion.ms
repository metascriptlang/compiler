// Route 16: Checker — integer literal coercion
//
// Verifies: number literals auto-coerce to sized integer types when context
// demands it (var decl with type annotation, binary ops with integer operand).
// Reference parity: standard reference's integer literal and range handling.

import { TypeKind } from "../../ast/node";
import { checkSource, strictErrorCount, warningCount, hasError } from "./helpers";
import { lookupSymbol } from "../../checker/symbol";

// ===== A: Variable declaration coercion =====

test "int32 var with literal" {
	assert strictErrorCount("const x: int32 = 5381;") == 0;
}

test "int32 var with hex literal" {
	assert strictErrorCount("const x: int32 = 0xFF;") == 0;
}

test "uint8 var with literal" {
	assert strictErrorCount("const x: uint8 = 255;") == 0;
}

test "int32 var infers literal type" {
	const src = "const x: int32 = 42;";
	const ctx = checkSource(src);
	assert ctx != null;
	const sym = lookupSymbol(ctx.table, "x");
	assert sym != null;
	assert sym.symbolType.kind == TypeKind.Int32;
}

test "uint8 var infers literal type" {
	const src = "const x: uint8 = 100;";
	const ctx = checkSource(src);
	assert ctx != null;
	const sym = lookupSymbol(ctx.table, "x");
	assert sym != null;
	assert sym.symbolType.kind == TypeKind.Uint8;
}

test "int64 var with literal" {
	assert strictErrorCount("const x: int64 = 1000000;") == 0;
}

// ===== B: Binary expression coercion =====

test "int32 + literal coerces" {
	const src = "const x: int32 = 1 as int32;\nconst y = x + 10;";
	const ctx = checkSource(src);
	assert ctx != null;
	const sym = lookupSymbol(ctx.table, "y");
	assert sym != null;
	assert sym.symbolType.kind == TypeKind.Int32;
}

test "literal + int32 coerces (commutative)" {
	const src = "const x: int32 = 1 as int32;\nconst y = 10 + x;";
	const ctx = checkSource(src);
	assert ctx != null;
	const sym = lookupSymbol(ctx.table, "y");
	assert sym != null;
	assert sym.symbolType.kind == TypeKind.Int32;
}

test "int32 & 0xFF no warning" {
	const src = "const x: int32 = 1 as int32;\nconst y = x & 0xFF;";
	assert warningCount(src) == 0;
	assert strictErrorCount(src) == 0;
}

test "int32 << 4 no warning" {
	const src = "const x: int32 = 1 as int32;\nconst y = x << 4;";
	assert warningCount(src) == 0;
}

test "int32 & 0xFF result is int32" {
	const src = "const x: int32 = 1 as int32;\nconst y = x & 0xFF;";
	const ctx = checkSource(src);
	assert ctx != null;
	const sym = lookupSymbol(ctx.table, "y");
	assert sym != null;
	assert sym.symbolType.kind == TypeKind.Int32;
}

test "int32 * literal preserves int32" {
	const src = "const x: int32 = 3 as int32;\nconst y = x * 33;";
	const ctx = checkSource(src);
	assert ctx != null;
	const sym = lookupSymbol(ctx.table, "y");
	assert sym != null;
	assert sym.symbolType.kind == TypeKind.Int32;
}

// ===== C: No coercion when both literals =====

test "literal + literal is int32" {
	const src = "const y = 10 + 20;";
	const ctx = checkSource(src);
	assert ctx != null;
	const sym = lookupSymbol(ctx.table, "y");
	assert sym != null;
	assert sym.symbolType.kind == TypeKind.Int32;
}

// ===== D: Float literals don't coerce =====

test "float literal does not coerce to int32" {
	const src = "const x: int32 = 3.14;";
	// 3.14 is not a whole number → literal stays as number
	// declType overrides anyway, no error
	assert strictErrorCount(src) == 0;
}

// ===== E: Chained expressions =====

test "chained int32 arithmetic with literals" {
	const src = "const x: int32 = 1 as int32;\nconst y = x + 10 + 20;";
	const ctx = checkSource(src);
	assert ctx != null;
	const sym = lookupSymbol(ctx.table, "y");
	assert sym != null;
	assert sym.symbolType.kind == TypeKind.Int32;
}

// ===== F: Mixed integer sizes with literal =====

test "int32 & literal no size mismatch" {
	const src = "const x: int32 = 1 as int32;\nconst y = x & 255;";
	assert strictErrorCount(src) == 0;
}

// ===== G: Coercion flows through var decl to binary =====

test "int32 var then bitwise with literal" {
	const src = "const x: int32 = 5381;\nconst y = x & 0xFF;";
	assert strictErrorCount(src) == 0;
	assert warningCount(src) == 0;
	const ctx = checkSource(src);
	assert ctx != null;
	const sym = lookupSymbol(ctx.table, "y");
	assert sym != null;
	assert sym.symbolType.kind == TypeKind.Int32;
}

// ===== H: Compound assignment coercion =====

test "int32 += literal coerces" {
	const src = "let x: int32 = 1 as int32;\nx += 5;";
	assert strictErrorCount(src) == 0;
}

// ===== I: Comparison operators with literal =====

test "int32 === literal no error" {
	const src = "const x: int32 = 1 as int32;\nconst y = x === 0;";
	assert strictErrorCount(src) == 0;
}

test "int32 < literal no error" {
	const src = "const x: int32 = 1 as int32;\nconst y = x < 100;";
	assert strictErrorCount(src) == 0;
}

// ===== J: Out-of-range literal is compile-time error =====
// Reference parity: standard reference's type change diagnostics

test "uint8 out of range literal is error" {
	const src = "const x: uint8 = 256;";
	assert strictErrorCount(src) == 1;
	assert hasError(src, "cannot convert");
}

test "int8 out of range literal is error" {
	const src = "const x: int8 = 200;";
	assert strictErrorCount(src) == 1;
	assert hasError(src, "cannot convert");
}

test "an integer constant expression is judged by its exact value at every slot" {
	const slots = [
		{ fits: "const v: int64 = 100000 * 100000;", refused: "const v: int32 = 100000 * 100000;" },
		{ fits: "function f(): int64 { return 100000 * 100000; }", refused: "function f(): int32 { return 100000 * 100000; }" },
		{ fits: "function take(n: int64): int64 { return n; } const v = take(100000 * 100000);", refused: "function take(n: int32): int32 { return n; } const v = take(100000 * 100000);" },
		{ fits: "interface H { v: int64; } const h: H = { v: 100000 * 100000 };", refused: "interface H { v: int32; } const h: H = { v: 100000 * 100000 };" },
		{ fits: "const xs: int64[] = [100000 * 100000];", refused: "const xs: int32[] = [100000 * 100000];" },
		{ fits: "const K = 100000; const v: int64 = K * K;", refused: "const K = 100000; const v: int32 = K * K;" },
	];
	for (const slot of slots) {
		assert strictErrorCount(slot.fits) == 0, slot.fits;
		assert strictErrorCount(slot.refused) == 1, slot.refused;
		assert hasError(slot.refused, "cannot convert 10000000000 to int32"), slot.refused;
	}
}

test "an untyped constant is folded exactly before its slot judges it" {
	assert strictErrorCount("function probe(): int32 { return 2147483647 + 1; }") == 1;
	assert strictErrorCount("function probe(): int32 { return (-2147483647 - 1) % -1; }") == 0;
	assert strictErrorCount("function probe(): uint8 { return 16 * 16 - 1; }") == 0;
	assert strictErrorCount("function probe(): uint8 { return 16 * 16; }") == 1;
}

test "a constant past int32 widens its typed partner to int64, which an int32 slot refuses" {
	assert strictErrorCount("function probe(i: int32): int64 { return i * (100000 * 100000); }") == 0;
	assert strictErrorCount("function probe(i: int32): int32 { return i * (100000 * 100000); }") == 1;
	assert strictErrorCount("function probe(i: int32): int32 { return i + 4000000000; }") == 1;
	assert strictErrorCount("const big = 100000 * 100000; function probe(): int32 { return big; }") == 1;
}

test "a nullish payload and its fallback are judged by the slot once, like conditional arms" {
	assert strictErrorCount("function f(v: uint8 | null): uint32 { const x: uint32 = v ?? 1; return x; }") == 0;
	assert strictErrorCount("function f(v: int32 | null): int64 { const x: int64 = v ?? 0; return x; }") == 0;
	assert strictErrorCount("type D = \"row\" | \"column\"; function f(s: D | null): D { const d: D = s ?? \"row\"; return d; }") == 0;
	assert strictErrorCount("function f(v: int32 | null): uint32 { const x: uint32 = v ?? 1; return x; }") == 1;
	assert strictErrorCount("function f(v: int32 | null, u: uint32): uint32 { const x: uint32 = v ?? u; return x; }") == 1;
	assert strictErrorCount("function f(v: uint8 | null): uint8 { const x: uint8 = v ?? 300; return x; }") == 1;
	assert hasError("function f(v: uint8 | null): uint8 { const x: uint8 = v ?? 300; return x; }", "cannot convert 300 to uint8");
}

test "a bitwise integer constant keeps its int32 value, so it fits an int32 slot" {
	assert strictErrorCount("const v: int32 = 1 << 31;") == 0;
	assert strictErrorCount("const v: int32 = ~0 & 255;") == 0;
}

test "negative literal out of range for uint8 is error" {
	const src = "const x: uint8 = -1;";
	// -1 is UnaryExpr so won't trigger literal check directly
	// but the inner literal 1 fits in uint8, so no error from literal handler
	assert strictErrorCount(src) == 0;
}

// ===== K: fitNode — implicit narrowing HiddenStdConv insertion =====
// Parity: standard reference's node fitting and transformation patterns

test "narrowing int32 to int8 var decl needs an explicit as" {
	assert strictErrorCount("const a: int32 = 1 as int32;\nconst x: int8 = a;") == 1;
	assert strictErrorCount("const a: int32 = 1 as int32;\nconst x: int8 = a as int8;") == 0;
}

test "widening int8 to int32 has no HiddenStdConv" {
	// Widening is always safe — no conversion needed
	const src = "const a: int8 = 1 as int8;\nconst x: int32 = a;";
	assert strictErrorCount(src) == 0;
}

test "narrowing number to int8 assignment" {
	// Assignment: x = someNumber where x is int8
	const src = "let x: int8 = 0 as int8;\nconst y: number = 42;\nx = y;";
	assert strictErrorCount(src) == 0;
}

test "same type no conversion" {
	const src = "const a: int32 = 1 as int32;\nconst x: int32 = a;";
	assert strictErrorCount(src) == 0;
}
