// bug482 — a local or parameter named NaN / Infinity was emitted as the C macro
//
// Symptom:    `function scale(Infinity: int32) { return Infinity * 2; }` returned garbage on C
//             (debug trapped converting INFINITY to int); JS returned 42.
// Root cause: C codegen matched the identifier's name, not its symbol, and emitted NAN /
//             INFINITY for every identifier spelled NaN / Infinity.
// Fix:        the macro is emitted only for the builtin symbols (builtinKind NaN / Infinity);
//             any other symbol keeps its own name.

import { compileToC } from "../helpers";

function cOf(source: string): string {
	const c = compileToC(source);
	return c.ok ? c.value : c.error;
}

test "bug482: a parameter named Infinity is read as the parameter" {
	const c = cOf("export function scale(Infinity: int32): int32 { return Infinity * 2; }\n");
	assert c.contains("return (Infinity * 2);");
	assert !c.contains("INFINITY * 2");
}

test "bug482: a local named NaN is read as the local" {
	const c = cOf("export function f(): int32 { const NaN: int32 = 5; return NaN + 1; }\n");
	assert !c.contains("NAN + 1");
}

test "bug482: the builtin NaN and Infinity still emit the C macros" {
	const c = cOf("export function nan(): number { return NaN; }\nexport function inf(): number { return Infinity; }\n");
	assert c.contains("return NAN;");
	assert c.contains("return INFINITY;");
}
