// nim-guard: `try/finally` (no catch clause) must PROPAGATE the exception;
// an empty `catch {}` must still SWALLOW it.
//
// INVARIANT: handler presence is STRUCTURAL. Reference `genTryGoto`
//   (ccgstmts.nim:1447) decides with `hasExcept = t[1].kind == nkExceptBranch`
//   — a node-kind test, never "is the body pointer non-nil" or "is the body
//   empty". A try with no except branch runs its finally and lets the error
//   keep propagating; only a real handler clears the error flag.
// NIM-REF: §1 "Try/finally handler presence is structural" — DIVERGE-UNINTENTIONAL -> SAME.
//   `hasCatch = d.catchBody !== null` treated the NullLiteral "no catch clause"
//   placeholder (parser try/finally + the DRC scope-cleanup try/finally from
//   analyzer/inject.ms) as a bare catch, so EVERY cleanup scope swallowed a
//   propagating exception. Restored via isAbsentCatchClause + the trailing
//   raiseExit (ccgstmts.nim genTryGoto's final `raiseExit(p)`) and the
//   `oldNimErrFin` save/restore around the finally body.
//
// COVERS (each shape independently regressed at least once):
//   1 try/finally propagates            5 nested finallys both run, inner-then-outer
//   2 empty `catch {}` still swallows   6 DRC-cleanup scope (owned local) propagates
//   3 throw inside a catch body still   7 tail-recursive throw propagates instead of
//     runs THAT try's finally             re-entering the `while (1)` tail-call loop
//   4 finally runs on the normal path
//
// WHAT IT CATCHES: a swallowed exception silently turning a raise into normal
//   control flow. In a tail-recursive function (body wrapped in `while (1)`)
//   the swallow additionally loops back to the function entry and re-throws
//   forever — an infinite hang, not just a wrong result.
//   RED pre-fix: "propagates" throws GUARD RED (threw stayed false).
//
// No RC balance directive — the signal is a wrong-value throw.

function viaFinally(): void {
	try { throw "boom"; } finally { }
}

function viaEmptyCatch(): void {
	try { throw "boom2"; } catch { }
}

let trace = "";

function throwInCatch(): void {
	try { throw "c1"; } catch (e) { throw "c2"; } finally { trace = trace + "F"; }
}

function nestedInner(): void {
	try { throw "n"; } finally { trace = trace + "i"; }
}

function nestedOuter(): void {
	try { nestedInner(); } finally { trace = trace + "o"; }
}

function ownedLocalThrows(n: number): string {
	const s = "x" + n.toString();
	if (s.length > 0) { throw "owned"; }
	return s;
}

function tailRec(n: number): string {
	if (n === 0) { throw "tail"; }
	return tailRec(n - 1);
}

function normalPath(): number {
	try { return 7; } finally { trace = trace + "N"; }
}

function main(): void {
	let threw = false;
	try { viaFinally(); } catch (e) { threw = true; }
	console.log(threw ? "propagate:ok" : "propagate:RED");

	let swallowed = true;
	try { viaEmptyCatch(); } catch (e) { swallowed = false; }
	console.log(swallowed ? "swallow:ok" : "swallow:RED");

	trace = "";
	let reached = false;
	try { throwInCatch(); } catch (e) { reached = true; }
	const catchFin = reached && trace.indexOf("F") >= 0;
	console.log(catchFin ? "catchthrow-finally:ok" : "catchthrow-finally:RED");

	trace = "";
	let nested = false;
	try { nestedOuter(); } catch (e) { nested = true; }
	const nestedOk = nested && trace === "io";
	console.log(nestedOk ? "nested:ok" : "nested:RED");

	let owned = false;
	try { const r = ownedLocalThrows(3); } catch (e) { owned = true; }
	console.log(owned ? "drcscope:ok" : "drcscope:RED");

	let tail = false;
	try { const r = tailRec(4); } catch (e) { tail = true; }
	console.log(tail ? "tailrec:ok" : "tailrec:RED");

	trace = "";
	const v = normalPath();
	const normOk = v === 7 && trace === "N";
	console.log(normOk ? "normal:ok" : "normal:RED");

	if (!threw) { throw "GUARD RED: try/finally swallowed a propagating exception"; }
	if (!swallowed) { throw "GUARD RED: empty catch{} failed to swallow"; }
	if (!catchFin) { throw "GUARD RED: throw inside catch skipped its own finally"; }
	if (!nestedOk) { throw "GUARD RED: nested finallys wrong"; }
	if (!owned) { throw "GUARD RED: DRC-cleanup scope swallowed"; }
	if (!tail) { throw "GUARD RED: tail-recursive throw did not propagate"; }
	if (!normOk) { throw "GUARD RED: finally broke the normal path"; }
	console.log("tryFinallyPropagates ok");
}

main();
