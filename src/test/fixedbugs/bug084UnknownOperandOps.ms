// bug084 — arithmetic/comparison on an `unknown` operand type-checked clean
// and crashed at runtime
//
// Symptom:    `const u = null as unknown; const x = u + 1;` compiled on BOTH
//             backends and died at runtime (C emits void* arithmetic, then a
//             number-formatted read of a pointer). `u < 2`, `u * 2`, `u += 1`,
//             `"a" + u` — same. TS and Nim both reject the shape at check time.
// Root cause: the BinaryExpr arm gates bitwise operands and string '+' but had
//             NO operand gate for user `unknown`. Pre-existing before the
//             docs/UNKNOWN-BUG.md Phase 2 kind split — found by its landing
//             probe matrix (identical crash under the pre-split binary).
// Fix:        allowlist gate ahead of the operator branches — equality,
//             logical/coalescing, and plain '=' stay legal on unknown; every
//             other binary operator errors with the narrowing hint.

import { hasError, errorCount } from "../handoff/helpers";

test "bug084: u + 1 is a checker error" {
	assert hasError("function f(u: unknown): void { const x = u + 1; }", "cannot be applied to 'unknown'");
}

test "bug084: comparison on unknown is a checker error" {
	assert hasError("function f(u: unknown): void { const b = u < 2; }", "cannot be applied to 'unknown'");
}

test "bug084: compound assignment on unknown is a checker error" {
	assert hasError("function f(): void { let u: unknown = null; u += 1; }", "cannot be applied to 'unknown'");
}

test "bug084: string concat with unknown is a checker error" {
	assert hasError("function f(u: unknown): void { const s = \"a\" + u; }", "cannot be applied to 'unknown'");
}

test "bug084 control: equality on unknown stays legal" {
	assert errorCount("function f(u: unknown): boolean { return u === null; }") === 0;
}

test "bug084 control: a narrowed operand stays legal" {
	// unknown narrows to POINTER-SHAPED targets only (void*-repr rule, bug069/
	// unknownKindReaders pin the value-type rejection) — narrow to the Ref, then
	// do arithmetic on its field.
	assert errorCount("class Box { n: number; }\nfunction f(u: unknown): number { return (u as Box).n + 1; }") === 0;
}

test "bug084 control: assignment into an unknown local stays legal" {
	assert errorCount("class Box { n: number; }\nfunction f(): void { let u: unknown = null; const b = new Box(); u = b as unknown; }") === 0;
}
