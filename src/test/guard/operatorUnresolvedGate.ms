// nim-guard: an operator that reaches codegen unresolved is an INTERNAL ERROR
//
// INVARIANT (Nim): a token that survives to code generation without having been
//   resolved is a compiler bug, never codegen leniency. `genMagicExpr`'s default
//   arm is `internalError(p.config, e.info, "genMagicExpr: " & $op)`
//   (ccgexprs.nim:3068) — Nim never writes an unrecognised operator through to
//   the C file. Upstream of that, a call with no matching candidate dies at
//   `notFoundError` -> "type mismatch" (semcall.nim:485/491) and never reaches
//   codegen at all.
// NIM-REF: no row sanctions a verbatim-token fallthrough. `mapBinaryOp`'s
//   catch-all (`_ => op`) emitted the source token straight into C, so `x ** y`
//   was handed to clang, which parses it as `x * (*y)` and reports the useless
//   "indirection requires pointer operand" — pointing at a pointer bug that does
//   not exist. DIVERGE-UNINTENTIONAL -> armed to match Nim.
//
// SAFE TO ARM: population measured EMPTY before arming (2026-08-10) — compiler
//   self-build 0 hits, battery `msc test src/index.ms` 3446/3446 with 0 hits,
//   Neon sweep 0 hits. Nothing in the tree relied on the verbatim fallthrough.
//
// WHAT IT CATCHES: restoring the `_ => op` passthrough. Without the gate this
//   file still fails to BUILD — but with a clang diagnostic about pointers
//   instead of a compiler diagnostic about the operator, which is why the check
//   pins the message text, not merely the failure.
//
// SPECIMEN: `>>>`, the remaining operator the checker types but the C backend
//   cannot emit (JS emits it natively — measured 2026-08-15). `**` was the
//   original specimen until it got its pow() emit; re-specimen when this one
//   does too.
// GUARD-CHECK-FAIL operator '>>>' reached codegen unresolved

export function main(): void {
	const x: int32 = 0 - 8;
	const y: int32 = 1;
	console.log("shr=" + (x >>> y).toString());
}
