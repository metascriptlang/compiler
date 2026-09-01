// @maxrss: 30
// @stdout: macro-node-fields PASS
// note: Locks addKindFields (expand.ms) ↔ bridge.ms nodeToValue parity: a macro reading an ARRAY field of a NodeKind addKindFields didn't serialize used to abort at expansion with 'array handle out of bounds: 0' (e.g. MatchExpr.matchCases). Brought addKindFields to full parity (54 missing kinds added: MatchExpr/MatchCase, all For/Switch/Try/Do stmts, New/Await/Yield/Spread/TryExpr, Class/Interface/Enum/Method/Property/Ctor/Struct/Actor/Import/Export/Macro decls, patterns, etc.). The macros here read matchCases.length, matchCases[0].caseBody.kind, and casePatterns.length — building this program natively re-runs them at compile time, so a regression re-breaks the BUILD (macro abort), not just this assert. Invisible to compileToC tests (isolated module graph can't resolve std/meta).

// Native guard for addKindFields ↔ bridge.ms nodeToValue parity (src/compiler/meta/expand.ms).
// A macro reading an ARRAY field of a NodeKind that addKindFields didn't serialize used to
// abort at expansion with "array handle out of bounds: 0" (e.g. MatchExpr.matchCases). After
// the parity fix every NodeKind's fields serialize, so these macros expand at compile time and
// the marker prints. Building this program natively IS the test — a regression re-breaks the
// build (macro abort), not just this assert. Invisible to compileToC tests (their isolated
// module graph can't resolve std/meta).

import { Node, NodeKind } from "std/meta";

macro matchCaseCount(node: Node): Node {
	return { kind: NodeKind.NumberLiteral, line: node.line, column: node.column, value: node.matchCases.length };
}

macro firstCaseBodyKind(node: Node): Node {
	return { kind: NodeKind.NumberLiteral, line: node.line, column: node.column, value: node.matchCases[0].caseBody.kind };
}

macro firstCasePatternCount(node: Node): Node {
	return { kind: NodeKind.NumberLiteral, line: node.line, column: node.column, value: node.matchCases[0].casePatterns.length };
}

function main(): void {
	let ok = true;
	if (matchCaseCount(match (1) { 1 => 10, 2 => 20, _ => 30 }) !== 3) { ok = false; }
	if (firstCaseBodyKind(match (1) { 1 => 99, _ => 0 }) !== (NodeKind.NumberLiteral as number)) { ok = false; }
	if (firstCasePatternCount(match (1) { 1 => 10, _ => 20 }) !== 1) { ok = false; }
	if (ok) { console.log("macro-node-fields PASS"); }
	else { console.log("macro-node-fields FAIL"); }
}
main();
