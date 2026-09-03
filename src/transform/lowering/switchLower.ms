// Switch Desugar — user SwitchStmt → MatchStmt, lowered straight through the
// match engine so ONE dispatcher owns value dispatch (if-else chain, string
// hash switch, real C switch for ordinal discriminants). Case tests are
// checker-resolved expressions, never binding patterns. The default case
// moves to the tail as the wildcard arm — with no fall-through the orders are
// equivalent. Lowering inline (not returning a raw MatchStmt) keeps the
// walker recursing into the produced blocks, so nested switches lower too.

import { Node, NodeKind, SourceLocation, SwitchStmtData, SwitchCaseData, BreakStmtData, IfStmtData, BlockStmtData, TryCatchStmtData, MatchStmtData, MatchCaseData } from "../../ast/node";
import { TransformContext } from "../context";
import { makeIdent, makeBlock, makeExprStmt, makeMatchStmt, makeMatchCase, makeSwitchWrapper, isCSwitchableType } from "../util";
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
	if (d.switchLowered) return [stmt];
	d.switchLowered = true;
	const loc = stmt.location;
	let ownedBreaks: Node[] = [];
	for (const caseNode of d.switchCases) {
		const cd = caseNode.data as SwitchCaseData;
		dropTerminalBreak(cd.caseStmts);
		collectOwnedBreaks(cd.caseStmts, ownedBreaks);
	}

	let lowered: Node[];
	if (isCSwitchableType(d.switchDisc.nodeType)) {
		lowered = [stmt];
	} else {
		lowered = eraseToMatch(d, loc, ctx);
	}
	if (ownedBreaks.length === 0) return lowered;
	ctx.tempCounter += 1;
	const swLabel = `__sw${ctx.tempCounter}`;
	for (const b of ownedBreaks) {
		(b.data as BreakStmtData).breakLabel = swLabel;
	}
	return [makeSwitchWrapper(lowered, swLabel, loc)];
}

// A trailing bare `break` in a no-fall-through case body is a no-op: delete it
// so the common `case 1: foo(); break;` idiom emits no wrapper and no labels.
function dropTerminalBreak(stmts: Node[]): void {
	while (stmts.length > 0) {
		const last = stmts[stmts.length - 1];
		if (last.kind !== NodeKind.BreakStmt) return;
		if ((last.data as BreakStmtData).breakLabel !== "") return;
		stmts.pop();
	}
}

// Breaks owned by this switch (TS semantics: break inside a switch case exits
// the switch). Descends transparent statements; stops at loops, nested
// switches, and function boundaries (statements only — never into expressions).
function collectOwnedBreaks(stmts: Node[], out: Node[]): void {
	for (const s of stmts) {
		collectOwnedInStmt(s, out);
	}
}

function collectOwnedInStmt(s: Node, out: Node[]): void {
	if (s.kind === NodeKind.BreakStmt) {
		const bd = s.data as BreakStmtData;
		if (bd.breakLabel === "") {
			out.push(s);
		}
		return;
	}
	if (s.kind === NodeKind.IfStmt) {
		const id = s.data as IfStmtData;
		collectOwnedInStmt(id.consequent, out);
		if (id.alternate !== null) { collectOwnedInStmt(id.alternate, out); }
		return;
	}
	if (s.kind === NodeKind.BlockStmt) {
		collectOwnedBreaks((s.data as BlockStmtData).statements, out);
		return;
	}
	if (s.kind === NodeKind.TryCatchStmt) {
		const td = s.data as TryCatchStmtData;
		collectOwnedInStmt(td.tryBody, out);
		if (td.catchBody !== null) { collectOwnedInStmt(td.catchBody, out); }
		if (td.finallyBody !== null) { collectOwnedInStmt(td.finallyBody, out); }
		return;
	}
	if (s.kind === NodeKind.MatchStmt) {
		const md = s.data as MatchStmtData;
		for (const c of md.matchStmtCases) {
			const cd = c.data as MatchCaseData;
			collectOwnedInStmt(cd.caseBody, out);
		}
		return;
	}
}

function eraseToMatch(d: SwitchStmtData, loc: SourceLocation, ctx: TransformContext): Node[] {
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
