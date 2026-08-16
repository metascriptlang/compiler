// nim-guard: inline arrow args are lifted in EVERY expression position
//
// INVARIANT (Nim): lambda lifting walks the full tree uniformly — its default
//   arm recurses ALL sons (`detectCapturedVars`/`liftCapturedVars` else branch:
//   `for i in 0..<n.len: … n[i]`, lambdalifting.nim:511-515). No node kind is
//   skipped, so an arrow nested inside a call held by ANY wrapper (member
//   access, ternary, index, cast) is still discovered and lifted.
// NIM-REF: §1 "Lambda lifting: uniform child traversal" — verdict was
//   DIVERGE-UNINTENTIONAL -> SAME (walkLift's `_ => {}` default skipped
//   MemberExpr/ArrayAccess/ConditionalExpr/TypeAssertion; restored to a generic
//   mapChildren+walkOrLift walk, MS's analog of Nim's `for i in 0..<n.len`).
//
// WHAT IT CATCHES: `g(x => …)` whose RESULT is the receiver of a member access
//   (`g(x => …).toString()`), a ternary/index/as-cast operand, etc. The wrapper
//   fell to walkLift's no-op default, so the inner call was never walked, the
//   arrow never lifted -> codegen emitted `0 /* unlowered ArrowFunction */` ->
//   C `assigning to 'msClosure' from incompatible type 'int'`. A variable-bound
//   arrow (`const cb = …; g(cb)`) escaped because VariableDecl WAS handled.
//
// RED MEANS: a wrapper position stopped being walked -> an inline arrow arg it
//   holds is not closure-lowered. This probe fails to BUILD ("unlowered
//   ArrowFunction" / msClosure<-int) or throws on a wrong value. Run /trace-nim
//   on walkLift (transform/lowering/lambdaLifting.ms).
//   Proven RED on the pre-fix binary; GREEN post-fix (drc + orc).
//
// No RC balance directive — the signal is build-failure / wrong-value-throw.
// Run by src/test/guard/run.sh with -DMS_DRC_LEDGER (drc + orc).

function apply2(f: (a: number, b: number) => boolean): boolean {
	return f(1.0, 2.0);
}

function main(): void {
	// member-access receiver: g(arrow).toString()
	const memberChain = apply2((a, b) => a !== b).toString();
	// ternary operand
	const tern = (1.0 > 0.0) ? apply2((a, b) => a === b) : false;
	// as-cast operand
	const cast = apply2((a, b) => a !== b) as boolean;

	if (memberChain !== "true") { throw "GUARD RED: arrow in member-chain not lifted"; }
	if (tern !== false) { throw "GUARD RED: arrow in ternary not lifted/ran wrong"; }
	if (cast !== true) { throw "GUARD RED: arrow in as-cast not lifted"; }
	console.log("inlineArrowMemberLift ok");
}

main();
