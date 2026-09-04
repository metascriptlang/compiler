// GUARD-CHECK-FAIL narrowing drops the fractional part
// GUARD-JS
//
// nim-guard: the four implicit number → int32 conversion paths are
// CHECKER-REJECTED. They used to be runtime-checked in corpus
// 016-jsIntegerModel ("convViaDecl/Param/Return/Assign === 3"); when the
// fit.ms narrowing rule landed those shapes stopped compiling, so the
// coverage moved here as compile-error pins. docs/JS-NUMERIC.md §"four
// implicit paths" predates the rule and is stale on this point.
//
// Each arm is a separate conversion site in the pipeline, so each is probed
// separately: decl init, call argument, return value, plain assignment.
//
// WHAT IT CATCHES: the fit.ms rule being dropped or scoped down — any arm
// compiling clean means "implicit number → int32" came back silently.
//
// RED MEANS: run.sh reports "compiled clean — a checker rule was dropped".
// Proven on both ends: rule-bearing binary fails the build with the tag in
// the log; the pre-rule v0.2.53 compiles this file clean (verified by probe,
// 2026-09-04).
//
// No runtime body — the build must stop at check, so there is no main().

function opaque(v: float64): float64 { return v; }

function takesI32(n: int32): int32 { return n; }

function returnsI32(): int32 {
	const f: float64 = opaque(3.9);
	return f;
}

function main(): void {
	const viaDecl: int32 = opaque(3.9);
	// KNOWN RULE GAP (2026-09-04): the call-ARGUMENT path below still
	// compiles clean — fit.ms rejects decl/assign/return but not the arg
	// position, so this truncates silently today. Left live so the gap is
	// pinned in place; when fit.ms gains the arg arm this starts erroring
	// and the tag count goes 3 → 4.
	const viaParam: int32 = takesI32(opaque(3.9));
	const viaReturn: int32 = returnsI32();
	let viaAssign: int32 = 0;
	viaAssign = opaque(3.9);
	console.log("unreachable " + (viaDecl + viaParam + viaReturn + viaAssign).toString());
}

main();
