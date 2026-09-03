// A void call produces no machine value. TypeScript still lets the result be
// bound and stringified — its carrier there is `undefined`; MetaScript has no
// undefined, so the carrier is `null`, materialized only at bind sites by the
// voidBind lowering. Three uses are refused in both languages, measured
// against tsc --strict: flowing void into a typed slot (TS2322), testing it
// for truthiness (TS1345), and arithmetic or ordering on it (TS2365 / TS2367).
// The reference line is stricter still (every void use is an error); the
// carrier divergence is recorded in docs/NIM-REF.md.

import { compileToC } from "../helpers";

function refusedWith(source: string, needle: string): boolean {
	const r = compileToC(source);
	if (r.ok) return false;
	return r.error.contains(needle);
}

function accepted(source: string): boolean {
	const r = compileToC(source);
	return r.ok;
}

const V = "function f(): void {}\n";

// ===== R1 — void into a typed slot =====

test "void: refused in a typed initializer" {
	assert refusedWith(V + "const n: number = f();", "void");
}

test "void: refused in a typed assignment" {
	assert refusedWith(V + "let x: number = 1; x = f();", "void");
}

test "void: refused in a return of a value-typed function" {
	assert refusedWith(V + "function g(): number { return f(); }", "void");
}

test "void: refused in a typed object field" {
	assert refusedWith(V + "interface P { n: number; } const p: P = { n: f() };", "void");
}

test "void: refused in a typed array element" {
	assert refusedWith(V + "const a: number[] = [f()];", "void");
}

// ===== R2 — truthiness =====

test "void: refused as an if condition" {
	assert refusedWith(V + "const n = f(); if (n) {}", "truthiness");
}

test "void: refused as a while condition" {
	assert refusedWith(V + "const n = f(); while (n) {}", "truthiness");
}

test "void: refused under logical not" {
	assert refusedWith(V + "const n = f(); const b = !n;", "truthiness");
}

test "void: refused as a ternary condition" {
	assert refusedWith(V + "const n = f(); const x = n ? 1 : 2;", "truthiness");
}

// ===== R3 — arithmetic, ordering, mismatched equality =====

test "void: refused in addition with a number" {
	assert refusedWith(V + "const n = f(); const s = n + 1;", "void");
}

test "void: refused in ordering" {
	assert refusedWith(V + "const n = f(); const b = n < 1;", "void");
}

test "void: refused in equality with a number" {
	assert refusedWith(V + "const n = f(); const b = n === 1;", "void");
}

// ===== The forgiven half — carrier is null =====

test "void: a bare bind is accepted" {
	assert accepted(V + "const n = f();");
}

test "void: string concatenation is accepted" {
	assert accepted(V + "const n = f(); const s = \"x\" + n;");
}

test "void: console.log of a void bind is accepted" {
	assert accepted(V + "const n = f(); console.log(n);");
}

test "void: equality with null is accepted" {
	assert accepted(V + "const n = f(); const b = n === null;");
}

test "void: chained void bind is accepted" {
	assert accepted(V + "const n = f(); const m = n;");
}

test "void: return of a void call inside a void function is accepted" {
	assert accepted(V + "function g(): void { return f(); }");
}

test "void: void into a void slot is accepted" {
	assert accepted(V + "let x: void = f(); x = f();");
}
