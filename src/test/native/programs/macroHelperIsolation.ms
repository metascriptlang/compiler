// Native guard for macro-path injection isolation (src/compiler/meta/expand.ms).
// Helper FunctionDecls reachable from a macro body were injected into the wrapper
// Program BY REFERENCE, and evalASTFull's check+refineTypes+transformForRaiser
// rewrote the REAL decls in place — a closure-bearing helper was lambda-lifted
// against the synthetic program, so after one expansion the module itself failed
// its own check ("1 type error(s)" with an unrenderable synthetic location).
// Clone-at-push fixed it. Building this natively + the marker printing IS the
// test: pre-fix, this file does not compile.
//
// isoGd pins clone FIDELITY on top of isolation: cloneNodeImpl dropped
// MatchCase.caseGuard, so a guarded arm in a cloned helper matched
// unconditionally — the macro folded 100 instead of 5 (silent wrong value)
// while the runtime helper stayed correct.

import { Node, NodeKind } from "std/meta";

function isoClosureHelper(): number {
	const f = (x: number): number => x + 1;
	return f(41);
}

function isoGuardHelper(n: number, big: boolean): number {
	return match (n) {
		_ when (big === true) => 100,
		_ => 5,
	};
}

macro isoCt(a: Node): Node {
	return { kind: NodeKind.NumberLiteral, line: a.line, column: a.column, value: isoClosureHelper(), isFloat: false };
}

macro isoGd(a: Node): Node {
	return { kind: NodeKind.NumberLiteral, line: a.line, column: a.column, value: isoGuardHelper(1, false), isFloat: false };
}

function main(): void {
	const ct: number = isoCt(0);
	const rt: number = isoClosureHelper();
	const gd: number = isoGd(0);
	const gdRt: number = isoGuardHelper(1, false);
	if (ct === 42 && rt === 42 && gd === 5 && gdRt === 5) { console.log("macro-helper-isolation PASS"); }
	else { console.log("macro-helper-isolation FAIL ct=" + ct.toString() + " rt=" + rt.toString() + " gd=" + gd.toString() + " gdRt=" + gdRt.toString()); }
}
main();
