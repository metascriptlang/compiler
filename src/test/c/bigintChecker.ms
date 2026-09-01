// bigint typing rules — TS parity: no implicit mixing with number/intN in
// arithmetic or bitwise ops, no unary '+', no '>>>'. Comparisons stay legal.
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
	assert ast.kind === NodeKind.Identifier;
	const d = ast.data as IdentifierData;
	assert d.name === "bigint";
}

test "JSON.stringify accepts bigint via explicit toString" {
	const result = compileToC("const v = 9007199254740993n;\nconsole.log(JSON.stringify({ id: v.toString() }));");
	assert result.ok;
}
