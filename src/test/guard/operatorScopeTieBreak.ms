// nim-guard: a tied operator candidate is broken by scope depth, not by push order
//
// INVARIANT (Nim): `cmpCandidates` (sigmatch.nim:414) ends with
//   `result = a.calleeScope - b.calleeScope` — "only as a last resort, consider
//   scoping". `calleeScope` is filled at candidate construction from
//   `cmpScopes` (lookups.nim:263), which scores a symbol of the current module
//   above one reaching in from another module. So a local declaration wins a tie
//   against an imported/prelude one of the same signature.
// NIM-REF: the mechanism is absent from docs/NIM-REF.md (verified: zero hits for
//   `calleeScope`, `cmpScopes`, `cmpCandidates`, `resolveOperatorCall`), so no
//   intentional divergence covers it.
//   `cmpCandidates` (compat.ms) already carried step 9 on `calleeScope`, and
//   both non-operator resolvers fill it (checkExprPass.ms, compat.ms
//   `resolveOverloadIdx`). `pickBestOperatorCandidate` (context.ms) left it 0 on
//   every candidate, so every operator tie fell through to `> 0` against the
//   first-pushed candidate — and `resolveOperatorCall` pushes the extension
//   registry (prelude, scopeDepth 0) before the symbol table.
//   -> DIVERGE-UNINTENTIONAL.
//
// WHAT WENT WRONG: `function `==`(a: string, b: string)` declared in a program
//   scored exactly as prelude's string `==` (exact=2 both) and lost the tie. The
//   declaration type-checked, emitted, and was never called — silently dead.
//
// WHAT IT CATCHES: dropping the scope-depth plumbing at the operator site, or
//   flipping the sign of step 9.

let userEqCalls: int32 = 0;

export function `==`(a: string, b: string): boolean {
	userEqCalls = userEqCalls + 1;
	return true;
}

function main(): int32 {
	const x = "abc";
	const y = "zzz";
	const eq = x == y;
	console.log("observed eq=" + (eq ? "true" : "false") + " userEqCalls=" + userEqCalls.toString());
	if (userEqCalls === 0) { console.log("GUARD-FAIL local `==` never called — prelude won the tie"); return 1; }
	if (!eq) { console.log("GUARD-FAIL prelude `==` decided the comparison"); return 1; }
	console.log("GUARD-OK operatorScopeTieBreak");
	return 0;
}
