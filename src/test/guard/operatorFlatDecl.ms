// nim-guard: a flat `function `op`(a, b)` declaration is an operator candidate
//
// INVARIANT (Nim): an infix operator resolves exactly like a normal call, over
//   EVERY symbol bearing that name. `semExpr` routes nkCall/nkInfix/nkPrefix
//   through ONE branch (semexprs.nim:3431) into `semDirectOp` (:983), which calls
//   `semOverloadedCallAnalyseEffects` -> `semOverloadedCall` (:1185) over
//   {skProc, skFunc, skMethod, skConverter, skMacro, skTemplate}. Nim has no
//   second "operators live in a separate registry" dispatch: `^` is a plain
//   `func` in math.nim:1212, and `{.magic.}` only changes EMISSION after the
//   symbol has already been resolved (ccgexprs.nim:3551).
// NIM-REF: no row on operator dispatch -> undocumented -> DIVERGE-UNINTENTIONAL.
//   `operatorLower.ms`'s own header claimed the Nim model ("resolves `a == b`
//   into ``==``(a, b) as a normal call") while the code asked ONLY the extension
//   registry, which `collectPass.ms` populates solely for receiver-form (`this`)
//   declarations. Restored by widening the candidate set to plain function
//   symbols + their overloads, scored by the SAME existing relation
//   (scoreCandidatePriority / cmpCandidates) — `typeRelation` untouched.
//
// WHAT IT CATCHES: reverting the candidate set to registry-only. Case 2 is the
//   dangerous one — it was a SILENT MISCOMPILE: the builtin struct-eq won and
//   printed `true` while the user's `==` returns `false`, with no diagnostic at
//   all. Cases 3-4 are the receiver-form neighbours that already worked and must
//   not regress.

struct Vec { x: int32; }

// (1) flat operator on a builtin operand type — pre-fix no candidate was found and
//     the token reached codegen verbatim, where C parsed `x ** y` as `x * (*y)`.
export function `**`(a: int32, b: int32): int32 {
	let r: int32 = 1;
	let i: int32 = 0;
	while (i < b) { r = r * a; i = i + 1; }
	return r;
}

// (2) flat operator that DISAGREES with the builtin it overrides — returns false
//     for structurally equal operands, so a `true` result proves the user function
//     was silently discarded.
export function `==`(a: Vec, b: Vec): boolean { return false; }

// (3) flat operator on a struct, arithmetic.
export function `*`(a: Vec, b: Vec): Vec { return { x: a.x * b.x } as Vec; }

// (4) receiver-form control — must keep working unchanged.
export function `<`(this a: Vec, b: Vec): boolean { return a.x < b.x; }

export function main(): void {
	const two: int32 = 2;
	const three: int32 = 3;
	if ((two ** three) !== 8) { throw "GUARD RED: flat operator on builtin operands not resolved"; }

	const p: Vec = { x: 3 } as Vec;
	const q: Vec = { x: 3 } as Vec;
	if (p == q) { throw "GUARD RED: builtin struct-eq silently beat the user's flat `==`"; }

	const m = p * q;
	if (m.x !== 9) { throw "GUARD RED: flat operator on struct operands not resolved"; }

	if (!(p < q) === false) { /* keep the receiver-form call live */ }
	const r: Vec = { x: 9 } as Vec;
	if (!(p < r)) { throw "GUARD RED: receiver-form operator regressed"; }

	console.log("operatorFlatDecl ok");
}
