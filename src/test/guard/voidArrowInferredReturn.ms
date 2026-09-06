// nim-guard: an arrow with no return statement resolves to void, never a sentinel
//
// INVARIANT: no pending-inference sentinel may survive sem. Nim enforces this
//   for procs (`semProcBody`, semexprs.nim:2108 — a still-meta return type
//   becomes void when the body yields nothing, else errCannotInferReturnType);
//   MS enforces it structurally since the kind-split arc, where `Inferred` is
//   the sole pending sentinel and `getTypeDesc` answers any sentinel kind with
//   Nim's else-branch internal error (`gateFlaglessUnknown`).
// NIM-REF: §1 row 58 (kind split — sentinel kinds must never reach emission)
//   and row 596 (lambda return type). Row 596 records that Nim does NOT infer a
//   lambda's return type from its body — no annotation means void — so the
//   body-inference site in `checkAnonymousFunction` is MS-native; its authority
//   is TS plus MS's own declaration path. TS infers void for a block body with
//   no return, which is what the fallthrough now returns.
//
// WHAT IT CATCHES: `checkAnonymousFunction` used to return
//   `createClosureType(..., inferredType())` when the body produced no return
//   value, so an unannotated block-bodied arrow carried `Inferred` out of the
//   checker. lambdaLifting's `preserveResolvedTypes` correctly refuses to copy
//   an unresolved type, so the lifted function kept the `None` its empty string
//   annotation produced, and codegen's gate fired. Only NON-capturing arrows
//   reach it — a capturing arrow takes the `$lifted_` path.
//
// RED MEANS: a sentinel return type is escaping sem again. This probe fails to
//   BUILD ("internal: unresolved type (kind=46/47) reached codegen") or exits
//   nonzero on a wrong value. Run /trace-nim on `checkAnonymousFunction`
//   (checker/checkExprPass.ms).
//   Proven RED on the pre-fix binary; GREEN post-fix.
//
// No RC balance directive — the signal is build-failure / wrong-value exit.
// Run by src/test/guard/run.sh with -DMS_DRC_LEDGER (drc + orc).

import { exit } from "std/process";

let counter: number = 0;

// Non-capturing (counter is module-level), block body, no return, no annotation
// — the exact shape that minted the sentinel.
const bump = () => { counter = counter + 1; };

// Same shape nested inside another arrow.
const runTwice = () => {
	const noop = () => { };
	noop();
	bump();
	bump();
	return counter;
};

// Control: an explicit `: void` annotation must keep working.
let flag: number = 0;
const explicitVoid = (): void => { flag = 7.0; };

// Control: a value-returning arrow must keep its inferred type, not collapse.
const answer = () => { return 42; };

function main(): void {
	bump();
	if (counter != 1.0) {
		console.log("FAIL: bump did not run, counter=" + counter.toString());
		exit(1);
	}
	const after = runTwice();
	if (after != 3.0) {
		console.log("FAIL: nested void arrow path, counter=" + after.toString());
		exit(1);
	}
	explicitVoid();
	if (flag != 7.0) {
		console.log("FAIL: explicit void arrow, flag=" + flag.toString());
		exit(1);
	}
	if (answer() != 42) {
		console.log("FAIL: value-returning arrow collapsed");
		exit(1);
	}
	console.log("voidArrowInferredReturn ok");
}

main();
