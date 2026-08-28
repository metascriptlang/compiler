// Switch Desugar — user SwitchStmt → MatchStmt, lowered straight through the
// match engine so ONE dispatcher owns value dispatch (if-else chain, string
// hash switch, real C switch for ordinal discriminants). Case tests are
// checker-resolved expressions, never binding patterns. The default case
// moves to the tail as the wildcard arm — with no fall-through the orders are
// equivalent. Lowering inline (not returning a raw MatchStmt) keeps the
// walker recursing into the produced blocks, so nested switches lower too.

import { Node, NodeKind, SwitchStmtData, SwitchCaseData } from "../../ast/node";
import { TransformContext } from "../context";
import { makeIdent, makeBlock, makeExprStmt, makeMatchStmt, makeMatchCase, isCSwitchableType } from "../util";
import { walkExpandBlocks } from "../walker";
import { lowerMatchStmt } from "./matchLower";
import { stmtCountAfter, firstStmtKindAfter } from "../testUtil";

export function lowerSwitch(program: Node, ctx: TransformContext): Node {
	walkExpandBlocks(program, expandSwitchStmt, ctx);
	return program;
}

// The ordinal gate is also the cycle breaker: the match engine EMITS int-disc
// SwitchStmt nodes (C-switch optimization), which the walker re-feeds here —
// passing ordinals through ends the recursion.
function expandSwitchStmt(stmt: Node, ctx: TransformContext): Node[] {
	if (stmt.kind !== NodeKind.SwitchStmt) return [stmt];
	const d = stmt.data as SwitchStmtData;
	if (isCSwitchableType(d.switchDisc.nodeType)) return [stmt];
	const loc = stmt.location;
	const nullGuard = null as unknown as Node;

	const cases: Node[] = [];
	let defaultCase: Node | null = null;
	for (const caseNode of d.switchCases) {
		const cd = caseNode.data as SwitchCaseData;
		const body = makeBlock(cd.caseStmts, loc);
		if (cd.isDefault) {
			if (defaultCase === null) {
				defaultCase = makeMatchCase([makeIdent("_", loc)], nullGuard, body, loc);
			}
			continue;
		}
		if (cd.caseTests.length === 0) continue;
		cases.push(makeMatchCase(cd.caseTests, nullGuard, body, loc));
	}
	if (defaultCase !== null) cases.push(defaultCase);
	if (cases.length === 0) return [makeExprStmt(d.switchDisc, loc)];

	return lowerMatchStmt(makeMatchStmt(d.switchDisc, cases, loc), ctx);
}

test "non-integer switch becomes temp + if chain" {
	assert stmtCountAfter("switch (s) { case \"a\": foo(); default: bar(); }", lowerSwitch) === 2;
	assert firstStmtKindAfter("switch (s) { case \"a\": foo(); default: bar(); }", lowerSwitch) === NodeKind.VariableDecl;
}

test "switch without default still lowers" {
	assert stmtCountAfter("switch (n) { case 1: a(); case 2: b(); }", lowerSwitch) === 2;
}

test "empty switch keeps only the discriminant eval" {
	assert stmtCountAfter("switch (n) { }", lowerSwitch) === 1;
}

test "nested switch in a case body lowers too" {
	const src = "switch (a) { case 1: switch (b) { case 2: f(); } default: g(); }";
	assert stmtCountAfter(src, lowerSwitch) === 2;
}

test "non-switch passthrough" {
	assert stmtCountAfter("const x = 1;", lowerSwitch) === 1;
}
