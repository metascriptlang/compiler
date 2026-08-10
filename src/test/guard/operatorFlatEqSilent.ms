// nim-guard: a flat `==` overload BEATS the compiler's builtin struct equality,
// and the derived `!=` follows THAT overload — not the builtin.
//
// Kept separate from operatorFlatDecl.ms on purpose: that guard dies at BUILD
// time on a pre-fix binary, which would mask this case. This one compiles clean
// pre-fix and fails on the VALUE — a silent miscompile has to be caught by a
// wrong answer, not by a build error that happens to fire first.
//
// INVARIANT (Nim): a user overload takes part in the same overload resolution as
//   the builtin, so an exact user match wins; `{.magic.}` only changes the
//   EMISSION of an already-resolved symbol (ccgexprs.nim:3551), it does not skip
//   resolution. And a derived operator is derived from the RESOLVED base: Nim's
//   `!=` is `template `!=`(x, y) = not (x == y)`, which re-resolves `==` through
//   normal overload resolution and therefore lands on the user's proc.
// NIM-REF: §0 — "track Nim most strictly where getting it wrong is a silent
//   miscompile". Pre-fix, `collectPass.ms` registered operators ONLY for
//   receiver-form (`this`) declarations, so the flat `==` below was invisible in
//   BOTH places that look for it: the direct resolution AND `resolveOpCall`, the
//   helper the `!=`->`==` derivation calls. The builtin struct-eq answered both.
//
// WHAT IT CATCHES (two independent regressions):
//   1. reverting the candidate set to registry-only  -> `eq` goes true
//   2. reverting ONLY `resolveOpCall`/`hasBase`      -> `eq` false but `ne` false
//      too, i.e. `a == b` and `a != b` both false — a logical contradiction that
//      the first version of this fix actually shipped until this guard caught it.

struct Vec { x: int32; }

// Always false — structural equality says `true` for the operands below, so a
// `true` here can ONLY mean this function was discarded.
export function `==`(a: Vec, b: Vec): boolean { return false; }

export function main(): void {
	const p: Vec = { x: 3 } as Vec;
	const q: Vec = { x: 3 } as Vec;

	const eq = p == q;
	const ne = p != q;
	console.log("eq=" + eq.toString() + " ne=" + ne.toString());

	// The line above prints the observed pair FIRST, so this guard reports a red
	// by VALUE (`eq=true` and/or `ne=false`, and no trailing ok) even where an
	// uncaught throw does not surface a useful exit status.
	if (eq) { throw "GUARD RED: builtin struct-eq silently overrode the user's flat `==`"; }
	if (!ne) { throw "GUARD RED: derived `!=` ignored the user's flat `==` (contradicts `==`)"; }

	console.log("operatorFlatEqSilent ok");
}
main();
