// bigint typing rules — TS parity: no implicit mixing with number/intN in
// arithmetic, bitwise or equality ops, no unary '+', no '>>>'. Relational
// comparisons stay legal.
// Emission pins live with each backend once lowering lands; these are
// checker-gate pins only, so every negative case must fail BEFORE codegen.

import { compileToC, compileToJS } from "../helpers";
import { createPrimitive } from "../../checker/types";
import { mapTypeToAst } from "../../compiler/meta/bridge";
import { NodeKind, TypeKind, makeLoc, IdentifierData } from "std/meta/node";

// ===== literal + annotation =====

test "bigint annotation resolves" {
	const result = compileToJS("const a: bigint = 123n;");
	assert result.ok;
}

// A const initializer carries no assignability gate (checker-wide, not a bigint
// trait), so every direction pin here goes through the return/argument path.

test "bigint literal does not satisfy an int64 return" {
	const result = compileToC("function f(): int64 { return 1n; }");
	assert !result.ok;
}

test "int literal does not satisfy a bigint return" {
	const result = compileToC("function f(): bigint { return 5; }");
	assert !result.ok;
}

test "bigint does not satisfy an int64 parameter" {
	const result = compileToC("function g(x: int64): void { }\ng(1n);");
	assert !result.ok;
}

test "int64 does not satisfy a bigint parameter" {
	const result = compileToC("function k(x: bigint): void { }\nconst c: int64 = 5;\nk(c);");
	assert !result.ok;
}

// ===== arithmetic mixing = compile error =====

test "bigint + int32 is rejected" {
	const result = compileToC("const a = 1n; const b: int32 = 2; const c = a + b;");
	assert !result.ok;
}

test "bigint + number is rejected" {
	const result = compileToC("const a = 1n; const b = 2.5; const c = a + b;");
	assert !result.ok;
}

test "bigint + int64 is rejected" {
	const result = compileToC("const a = 1n; const b: int64 = 2; const c = a + b;");
	assert !result.ok;
}

test "bigint * number is rejected" {
	const result = compileToC("const a = 2n; const c = a * 3;");
	assert !result.ok;
}

test "bigint % int32 is rejected" {
	const result = compileToC("const a = 7n; const b: int32 = 2; const c = a % b;");
	assert !result.ok;
}

// ===== bitwise / shift mixing = compile error =====

test "bigint & int32 is rejected" {
	const result = compileToC("const a = 12n; const b: int32 = 10; const c = a & b;");
	assert !result.ok;
}

test "bigint << int32 is rejected" {
	const result = compileToC("const a = 1n; const b: int32 = 3; const c = a << b;");
	assert !result.ok;
}

// ===== equality with a non-bigint = compile error =====

const NUMERIC_WIDTHS = ["int8", "int16", "int32", "int64", "uint8", "uint16", "uint32", "uint64", "float32", "float64", "number", "char"];
const BIGINT_EQUALITY_REFUSAL = "have no overlap — convert one side first: `b == BigInt(x)` or `Number(b) == x`";

function refusal(source: string): string {
	const result = compileToC(source);
	return result.ok ? "" : result.error;
}

test "bigint equality with a number of every width is refused on either side" {
	for (const t of NUMERIC_WIDTHS) {
		for (const op of ["==", "!=", "===", "!=="]) {
			assert refusal("function f(a: bigint, b: " + t + "): boolean { return a " + op + " b; }").contains("the types 'bigint' and '" + t + "' " + BIGINT_EQUALITY_REFUSAL);
			assert refusal("function f(a: bigint, b: " + t + "): boolean { return b " + op + " a; }").contains("the types '" + t + "' and 'bigint' " + BIGINT_EQUALITY_REFUSAL);
		}
	}
}

test "bigint equality with a number literal or through a nullable bigint is refused" {
	assert refusal("function f(a: bigint): boolean { return a == 5; }").contains(BIGINT_EQUALITY_REFUSAL);
	assert refusal("function f(a: bigint): boolean { return 5.5 != a; }").contains(BIGINT_EQUALITY_REFUSAL);
	assert refusal("function f(a: bigint | null, b: float64): boolean { return a == b; }").contains(BIGINT_EQUALITY_REFUSAL);
}

test "a number case or match arm on a bigint is refused" {
	for (const t of NUMERIC_WIDTHS) {
		assert refusal("function f(a: bigint, b: " + t + "): int32 { switch (a) { case b: return 1; default: return 0; } }").contains("is not comparable to the switch value of type 'bigint' — convert one side first");
	}
	assert refusal("function f(a: bigint): int32 { switch (a) { case 5: return 1; default: return 0; } }").contains("convert one side first");
	assert refusal("function f(a: bigint): int32 { return match (a) { 5 => 1, _ => 0 }; }").contains("convert one side first");
	assert refusal("function f(a: bigint): int32 { let r: int32 = 0; match (a) { 5 => { r = 1; }, _ => { r = 0; } }; return r; }").contains("convert one side first");
}

test "bigint equality with a bigint, null or a converted side and relational mixes are accepted" {
	const checkerAccepts = (source: string): boolean => compileToJS(source).ok;
	assert checkerAccepts("function f(a: bigint, b: bigint): boolean { return a == b && a !== 5n; }");
	assert checkerAccepts("function f(a: bigint | null, b: bigint): boolean { return a == null || a == b; }");
	assert checkerAccepts("function f(a: bigint, x: float64): boolean { return a == (x as bigint) || (a as float64) == x; }");
	assert checkerAccepts("function f(a: bigint, x: float64, i: int32): boolean { return a < x && x >= a && a > i; }");
	assert checkerAccepts("function f(a: bigint): int32 { switch (a) { case 5n: return 1; default: return 0; } }");
}

// ===== banned operators =====

test "unary plus on bigint is rejected" {
	const result = compileToC("const a = 1n; const b = +a;");
	assert !result.ok;
}

test ">>> on bigint is rejected" {
	const result = compileToC("const a = 8n; const b = a >>> 1n;");
	assert !result.ok;
}

// ===== legal same-type operations =====

test "bigint arithmetic and bitwise typecheck when both sides are bigint" {
	const result = compileToJS(
		"const a = 7n; const b = 2n;\n"
		+ "const s = a + b; const d = a - b; const m = a * b;\n"
		+ "const q = a / b; const r = a % b; const p = a ** b;\n"
		+ "const w = a & b; const o = a | b; const x = a ^ b;\n"
		+ "const l = a << b; const t = a >> b;\n"
		+ "const n = -a; const f = ~a;");
	assert result.ok;
}

test "bigint comparisons typecheck" {
	const result = compileToJS("const a = 1n; const b = 2n; const c = a < b; const d = a >= b;");
	assert result.ok;
}

test "bigint increment keeps bigint" {
	const result = compileToJS("let a = 1n; a++; const b: bigint = a;");
	assert result.ok;
}

// ===== JS backend emits native BigInt syntax already =====

test "bigint literal beyond int64 survives to JS verbatim" {
	const result = compileToJS("const a: bigint = 123456789012345678901234567890n;");
	assert result.ok;
	assert result.value.contains("123456789012345678901234567890n");
}

// ===== bigint has no JSON representation (Node parity: stringify(1n) throws) =====
//
// The refusal itself fires at macro expansion (`jsonValueOf` sees Identifier
// "bigint" and errors), which only the CLI pipeline instantiates — the
// in-process compileToC tier does not run generic-macro mono, so it cannot
// pin this. CLI-verified 2026-09-01: `interface T { v: bigint }` +
// `JSON.stringify(t)` fails with "bigint is not JSON-serializable". The
// load-bearing prerequisite pinned here is the bridge name mapping — before
// it, bigint Types reached codec macros as Identifier "unknown" and silently
// wrapped through the jsonInt int64 carrier.

test "bridge maps bigint Type to Identifier 'bigint'" {
	const t = createPrimitive(TypeKind.BigInt);
	const ast = mapTypeToAst(t, makeLoc(0, 0));
	assert ast.kind == NodeKind.Identifier;
	const d = ast.data as IdentifierData;
	assert d.name == "bigint";
}

test "JSON.stringify accepts bigint via explicit toString" {
	const result = compileToC("const v = 9007199254740993n;\nconsole.log(JSON.stringify({ id: v.toString() }));");
	assert result.ok;
}
