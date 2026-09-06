// nim-guard (checker diagnostic): casting a nilable-pointer union that collapses
// to `unknown` (`unknown | null`) to a FAT VALUE type must be DIAGNOSED at the
// checker — same as a bare `unknown` cast — not slip through to a cryptic clang
// "address of rvalue" (or a silent reinterpret).
//
// INVARIANT: §57 "value-shaped x unknown flows DIAGNOSED at casts (no void* repr
//   for string/struct/closure)". The cast-site check inspected bare `unknown`
//   (srcType.kind === Unknown) but not the nilable-union form `{unknown, null}`
//   (srcType.kind === Union, collapses to void*). Fix: peel unwrapRefNullUnion
//   before the check — mirrors the already-present peel at the call-arg sites.
// NIM-REF: §1 "unknown top type" — DIVERGE-INCOMPLETE -> SAME (diagnostic applied
//   to call-args but not the cast site).

import { checkSource } from "./helpers";
import { hasErrors } from "../../checker/context";

test "unknown|null cast to fat value type is diagnosed (not slipped to codegen)" {
	// f(): unknown | null  ->  cast to a fat value struct: no void* repr, must error.
	const src = "function f(): unknown | null { return null; }\ntype P = { x: number, y: number };\nfunction main(): void { const bad = f() as P; }";
	const ctx = checkSource(src);
	assert ctx != null;
	assert hasErrors(ctx);
}

test "bare unknown cast to fat value type still diagnosed (no regression)" {
	const src = "function g(): unknown { return null as unknown; }\ntype P = { x: number, y: number };\nfunction main(): void { const bad = g() as P; }";
	const ctx = checkSource(src);
	assert ctx != null;
	assert hasErrors(ctx);
}

test "unknown|null cast to a Ref type is allowed (pointer, no over-fire)" {
	const src = "class Box { n: number; }\nfunction f(): unknown | null { return null; }\nfunction main(): void { const ok = f() as Box; }";
	const ctx = checkSource(src);
	assert ctx != null;
	assert !hasErrors(ctx);
}
