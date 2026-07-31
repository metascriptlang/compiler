// bug069 — `any` reached codegen as void*; `undefined` lost its null aliasing
//
// Symptom:    `x: any` type-checked and reached C codegen as void*; member
//             reads on it died in clang ("member reference base type is not
//             a structure or union") — 2 of the G1-gate files (deepNesting,
//             classMemberElseIf). `: undefined` resolved to the same void*
//             instead of behaving as `null`.
// Root cause: resolvePass mapped "any" to the internal pending-inference
//             singleton (unknownType()) — the checker's own "not inferred
//             yet, allow" sentinel — so user `any` inherited every leniency
//             gate and bypassed the UserUnknown diagnostics. "undefined"
//             had no mapping at all and fell through the exempted
//             unresolved-name path to that same singleton, so it silently
//             became an opaque pointer rather than the null alias the
//             language documents.
// Fix:        `any` is a checker error (no dynamic member lookup exists to
//             erase it to on a native target; `unknown` + an explicit cast
//             is the supported spelling). `undefined` resolves to nullType()
//             and warns, staying legal for TypeScript backward compatibility.
//             The internal singleton is untouched — pending inference and
//             metaprogramming (Node-typed, never `any`) are unaffected.

import { hasError, hasWarning, errorCount, strictErrorCount, warningCount } from "../handoff/helpers";

test "bug069: annotation 'any' is rejected with guidance" {
	assert hasError("function f(x: any): void {}", "'any' is not a MetaScript type");
}

test "bug069: compound 'any' positions are rejected too" {
	assert hasError("function f(): any[] { return []; }", "'any' is not a MetaScript type");
}

test "bug069: annotation 'undefined' warns but stays legal" {
	assert hasWarning("let x: undefined = null;", "'undefined' is an alias of 'null'");
	assert strictErrorCount("let x: undefined = null;") === 0;
}

// Measured as a DELTA against the same program spelled with `null`: the
// snippet is checked against the prelude, whose own warnings would otherwise
// swamp an absolute count.
test "bug069: the 'undefined' warning is emitted once per annotation" {
	const base = warningCount("let x: null = null;");
	const warned = warningCount("let x: undefined = null;");
	assert warned - base === 1;
}

test "bug069: 'undefined' aliases null in a union position" {
	assert strictErrorCount("function f(s: string | undefined): boolean { return s === null; }") === 0;
}

test "bug069: 'unknown' stays legal" {
	assert errorCount("function f(x: unknown): void {}") === 0;
}

test "bug069: the null cast idiom stays legal" {
	assert errorCount("interface T { v: int32; } function f(): T { return null as unknown as T; }") === 0;
}
