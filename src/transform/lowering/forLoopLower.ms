// For Loop Lowering — transforms for(init;cond;update) → block with while
// Follows reference implementation for_loop_lower.zig + reference transform pattern
//
// for (let i = 0; i < 10; i++) { body; }
// →
// { let i = 0; while (i < 10) { body; i++; } }

import { Node, NodeKind, ForStmtData, BlockStmtData, IfStmtData, TryCatchStmtData, WhileStmtData, DoWhileStmtData, MatchStmtData, MatchCaseData, BreakStmtData, ContinueStmtData } from "../../ast/node";
import { forEachChild } from "../../ast/visitor";
import { TransformContext } from "../context";
import { walkNode, mapChildren } from "../walker";
import { makeBool, makeBlock, makeWhile, makeExprStmt, makeBreak, makeSwitchWrapper, extractBodyStmts } from "../util";
import { isFnBoundary, LoopJumps, hasLoopContinue, retargetLoopJumps } from "./jumpRetarget";
import { firstStmtKindAfter, stmtCountAfter, parseInput, makeCtx, getStmts } from "../testUtil";

// ===== Main Entry Point =====

export function lowerForLoop(program: Node, ctx: TransformContext): Node {
	walkNode(program, (node: Node): Node => lowerForNode(node, ctx));
	return program;
}

function lowerForNode(node: Node, ctx: TransformContext): Node {
	if (node.kind != NodeKind.ForStmt) return node;
	const d = node.data as ForStmtData;
	const loc = node.location;
	const outerStmts: Node[] = [];

	// 1. Init statement (if present)
	if (d.forInit != null) {
		outerStmts.push(d.forInit);
	}

	// 2. Condition (default to true for infinite loop)
	let cond: Node | null = null;
	if (d.forCondition != null) {
		cond = d.forCondition;
	} else {
		cond = makeBool(true, loc);
	}

	let bodyStmts: Node[] = extractBodyStmts(d.forBody);
	let whileLabel = "";
	if (d.forUpdate != null) {
		const updateStmt = makeExprStmt(d.forUpdate, loc);
		if (hasLoopContinue(bodyStmts, "")) {
			if (loopSuspends(d, bodyStmts)) {
				rewriteContinues(bodyStmts, updateStmt);
			} else {
				ctx.tempCounter += 1;
				const jumps: LoopJumps = { bodyLabel: `__cont${ctx.tempCounter}`, loopLabel: `__lp${ctx.tempCounter}`, loopBroken: false };
				let i = 0;
				while (i < bodyStmts.length) {
					bodyStmts[i] = retargetLoopJumps(bodyStmts[i], jumps, false);
					i += 1;
				}
				bodyStmts = [makeSwitchWrapper(bodyStmts, jumps.bodyLabel, loc)];
				if (jumps.loopBroken) whileLabel = jumps.loopLabel;
			}
		}
		bodyStmts.push(updateStmt);
	}

	// 5. Build while loop
	const whileBody = makeBlock(bodyStmts, loc);
	const whileNode = makeWhile(cond, whileBody, loc);
	(whileNode.data as WhileStmtData).whileLabel = whileLabel;
	outerStmts.push(whileNode);

	return makeBlock(outerStmts, loc);
}

function loopSuspends(d: ForStmtData, bodyStmts: Node[]): boolean {
	if (d.forCondition != null && hasSuspendPoint(d.forCondition)) return true;
	if (hasSuspendPoint(d.forUpdate)) return true;
	for (const s of bodyStmts) {
		if (hasSuspendPoint(s)) return true;
	}
	return false;
}

function hasSuspendPoint(node: Node): boolean {
	if (node.kind == NodeKind.YieldExpr || node.kind == NodeKind.AwaitExpr) return true;
	if (isFnBoundary(node.kind)) return false;
	let found = false;
	forEachChild(node, (child: Node): void => {
		if (!found && hasSuspendPoint(child)) found = true;
	});
	return found;
}

// Rewrite continue → { update; continue; } at current loop level.
// Does NOT descend into nested loops (their continues target inner loops).
function rewriteContinues(stmts: Node[], updateStmt: Node): void {
	let i = 0;
	while (i < stmts.length) {
		stmts[i] = rewriteContinuesInNode(stmts[i], updateStmt);
		i += 1;
	}
}

// Returns the rewritten statement: a bare continue becomes { update; continue; }.
// Recurses into every position that can host a same-level continue — blocks,
// full if/else-if chains (alternate is an IfStmt, not a block), try/catch/finally,
// and match cases (matchLower runs after forLoopLower and keeps continue as-is).
function rewriteContinuesInNode(node: Node, updateStmt: Node): Node {
	if (node.kind == NodeKind.ContinueStmt) {
		return makeBlock([cloneStmt(updateStmt), node], node.location);
	}
	if (node.kind == NodeKind.BlockStmt) {
		const bd = node.data as BlockStmtData;
		rewriteContinues(bd.statements, updateStmt);
	} else if (node.kind == NodeKind.IfStmt) {
		const ifd = node.data as IfStmtData;
		if (ifd.consequent != null) ifd.consequent = rewriteContinuesInNode(ifd.consequent, updateStmt);
		if (ifd.alternate != null) ifd.alternate = rewriteContinuesInNode(ifd.alternate, updateStmt);
	} else if (node.kind == NodeKind.TryCatchStmt) {
		const td = node.data as TryCatchStmtData;
		if (td.tryBody != null) td.tryBody = rewriteContinuesInNode(td.tryBody, updateStmt);
		if (td.catchBody != null) td.catchBody = rewriteContinuesInNode(td.catchBody, updateStmt);
		if (td.finallyBody != null) td.finallyBody = rewriteContinuesInNode(td.finallyBody, updateStmt);
	} else if (node.kind == NodeKind.MatchStmt) {
		const md = node.data as MatchStmtData;
		let i = 0;
		while (i < md.matchStmtCases.length) {
			const c = md.matchStmtCases[i];
			if (c.kind == NodeKind.MatchCase) {
				const cd = c.data as MatchCaseData;
				if (cd.caseBody != null) cd.caseBody = rewriteContinuesInNode(cd.caseBody, updateStmt);
			}
			i += 1;
		}
	}
	// While/For/ForOf/DoWhile untouched — nested loops own their continues
	return node;
}

// Shallow clone of statement node (for duplicating updateStmt)
function cloneStmt(node: Node): Node {
	return {
		kind: node.kind,
		data: node.data,
		location: node.location,
		nodeType: node.nodeType,
		flags: node.flags,
		resolvedSym: node.resolvedSym,
	};
}

// ===== Test helpers =====

function loweredLoop(input: string): Node {
	const r = parseInput(input);
	if (!r.ok) return null as unknown as Node;
	const stmts = getStmts(lowerForLoop(r.value, makeCtx()));
	for (const s of stmts) {
		if (s.kind == NodeKind.BlockStmt) {
			for (const inner of (s.data as BlockStmtData).statements) {
				if (inner.kind == NodeKind.WhileStmt) return inner;
			}
		}
	}
	for (const s of stmts) {
		if (s.kind == NodeKind.FunctionDecl) {
			let found: Node | null = null;
			forEachChild(s, (child: Node): void => { if (found == null) found = findWhile(child); });
			if (found != null) return found;
		}
	}
	return null as unknown as Node;
}

function findWhile(node: Node): Node | null {
	if (node.kind == NodeKind.WhileStmt) return node;
	let found: Node | null = null;
	forEachChild(node, (child: Node): void => { if (found == null) found = findWhile(child); });
	return found;
}

function loopBodyStmts(loop: Node): Node[] {
	return ((loop.data as WhileStmtData).whileBody.data as BlockStmtData).statements;
}

function bodyBlockLabel(loop: Node): string {
	const first = loopBodyStmts(loop)[0];
	if (first.kind != NodeKind.DoWhileStmt) return "";
	return (first.data as DoWhileStmtData).dwLabel;
}

function jumpLabels(node: Node, kind: NodeKind, out: string[]): void {
	if (node.kind == kind) {
		out.push(kind == NodeKind.BreakStmt ? (node.data as BreakStmtData).breakLabel : (node.data as ContinueStmtData).continueLabel);
	}
	forEachChild(node, (child: Node): void => { jumpLabels(child, kind, out); });
}

function breaksIn(loop: Node): string[] {
	const out: string[] = [];
	jumpLabels(loop, NodeKind.BreakStmt, out);
	return out;
}

function continuesIn(loop: Node): string[] {
	const out: string[] = [];
	jumpLabels(loop, NodeKind.ContinueStmt, out);
	return out;
}

function updateFollowsBody(loop: Node): boolean {
	const stmts = loopBodyStmts(loop);
	return stmts.length == 2 && stmts[0].kind == NodeKind.DoWhileStmt && stmts[1].kind == NodeKind.ExprStmt;
}

function leavesBodyBlock(input: string): boolean {
	const loop = loweredLoop(input);
	if (loop == null || !updateFollowsBody(loop) || continuesIn(loop).length != 0) return false;
	const breaks = breaksIn(loop);
	return breaks.length == 1 && breaks[0] == bodyBlockLabel(loop);
}

// ===== Tests =====
test "basic for becomes block" { assert firstStmtKindAfter("for (let i = 0; i < 10; i++) {}", lowerForLoop) == NodeKind.BlockStmt; }

test "a body without continue keeps the update last and no body block" {
	const loop = loweredLoop("for (let i = 0; i < 4; i += 1) { if (i === 1) break; }");
	const stmts = loopBodyStmts(loop);
	assert stmts.length == 2 && stmts[0].kind == NodeKind.IfStmt && stmts[1].kind == NodeKind.ExprStmt;
	assert breaksIn(loop)[0] == "";
}

test "a continue in an if leaves the body block" { assert leavesBodyBlock("for (let i = 0; i < 4; i += 1) { if (i === 1) continue; }"); }

test "a continue in an else-if chain leaves the body block" { assert leavesBodyBlock("for (let i = 0; i < 4; i += 1) { if (i === 0) {} else if (i === 1) {} else { continue; } }"); }

test "a continue in a switch case leaves the body block" { assert leavesBodyBlock("for (let i = 0; i < 4; i += 1) { switch (i) { case 1: continue; default: i; } }"); }

test "a continue in a statement match arm leaves the body block" { assert leavesBodyBlock("for (let i = 0; i < 4; i += 1) { match (i) { 1 => { continue; } _ => {} } }"); }

test "a continue in a try body leaves the body block before the update runs" { assert leavesBodyBlock("for (let i = 0; i < 4; i += 1) { try { continue; } finally { i; } }"); }

test "a continue inside a match inside a switch leaves the body block" { assert leavesBodyBlock("for (let i = 0; i < 4; i += 1) { switch (i) { case 1: match (i) { 1 => { continue; } _ => {} } default: i; } }"); }

test "a break in a match arm names the loop" {
	const loop = loweredLoop("for (let i = 0; i < 4; i += 1) { if (i === 0) continue; match (i) { 2 => { break; } _ => {} } }");
	const label = (loop.data as WhileStmtData).whileLabel;
	assert label != "" && breaksIn(loop).indexOf(label) >= 0;
}

test "a break in a switch case stays with the switch" {
	const loop = loweredLoop("for (let i = 0; i < 4; i += 1) { if (i === 0) continue; switch (i) { case 2: break; default: i; } }");
	assert (loop.data as WhileStmtData).whileLabel == "" && breaksIn(loop).indexOf("") >= 0;
}

test "a continue of a nested loop stays with that loop" {
	const loop = loweredLoop("for (let i = 0; i < 4; i += 1) { if (i === 0) continue; while (i < 2) { continue; } }");
	assert continuesIn(loop).length == 1 && continuesIn(loop)[0] == "";
}

test "a body that yields keeps the update before each continue" {
	const loop = loweredLoop("function* g() { for (let i = 0; i < 4; i += 1) { if (i === 1) continue; yield i; } }");
	assert bodyBlockLabel(loop) == "" && continuesIn(loop).length == 1;
}

test "a body that awaits keeps the update before each continue" {
	const loop = loweredLoop("async function g() { for (let i = 0; i < 4; i += 1) { if (i === 1) continue; await h(i); } }");
	assert bodyBlockLabel(loop) == "" && continuesIn(loop).length == 1;
}

test "while unchanged" { assert firstStmtKindAfter("while (true) {}", lowerForLoop) == NodeKind.WhileStmt; }

test "for-of unchanged" { assert firstStmtKindAfter("for (const x of arr) { x; }", lowerForLoop) == NodeKind.ForOfStmt; }
// Note: for(;;) not supported by parser — it always requires init/cond/update expressions
test "for with update only" { assert firstStmtKindAfter("for (let i = 0; i < 5; i++) { i; }", lowerForLoop) == NodeKind.BlockStmt; }

test "non-loop passthrough" { assert stmtCountAfter("const x = 1;", lowerForLoop) == 1; }

test "preserves surrounding stmts" { assert stmtCountAfter("let a = 1; for (let i = 0; i < 2; i++) {} let b = 2;", lowerForLoop) == 3; }

test "if stmt unchanged" { assert firstStmtKindAfter("if (x) {}", lowerForLoop) == NodeKind.IfStmt; }
