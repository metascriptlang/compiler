// For Loop Lowering — transforms for(init;cond;update) → block with while
// Follows reference implementation for_loop_lower.zig + reference transform pattern
//
// for (let i = 0; i < 10; i++) { body; }
// →
// { let i = 0; while (i < 10) { body; i++; } }

import { Node, NodeKind, SourceLocation, ForStmtData, BlockStmtData, WhileStmtData, DoWhileStmtData, VariableDeclData, IdentifierData, BreakStmtData, ContinueStmtData, DeclKind, Symbol, createNode } from "../../ast/node";
import { forEachChild, anyChild, anyDescendant, Visit } from "../../ast/visitor";
import { TransformContext, freshOwnedSym } from "../context";
import { walkNode, isFuncBoundary } from "../walker";
import { makeBool, makeBlock, makeWhile, makeExprStmt, makeBreak, makeSwitchWrapper, extractBodyStmts, makeVarDecl, makeIdentResolved, makeAssign, makeIf, makeUnary, syntheticToken } from "../util";
import { LoopJumps, hasLoopContinue, retargetLoopJumps } from "./jumpRetarget";
import { booleanType } from "../../checker/types";
import { firstStmtKindAfter, stmtCountAfter, parseInput, makeCtx, getStmts } from "../testUtil";

// ===== Main Entry Point =====

export function lowerForLoop(program: Node, ctx: TransformContext): Node {
	walkNode(program, (node: Node): Node => lowerForStmt(node, ctx));
	return program;
}

export function lowerForStmt(node: Node, ctx: TransformContext): Node {
	if (node.kind != NodeKind.ForStmt) return node;
	const d = node.data as ForStmtData;
	const captured = capturedLetBinding(d);
	if (captured != null) return lowerPerIteration(d, captured, ctx, node.location);
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
		const tail = appendLoopTail(bodyStmts, updateStmt, ctx, loc);
		bodyStmts = tail.tailStmts;
		whileLabel = tail.tailLabel;
	}

	// 5. Build while loop
	const whileBody = makeBlock(bodyStmts, loc);
	const whileNode = makeWhile(cond, whileBody, loc);
	(whileNode.data as WhileStmtData).whileLabel = whileLabel;
	outerStmts.push(whileNode);

	return makeBlock(outerStmts, loc);
}

export interface LoopTail {
	tailStmts: Node[];
	tailLabel: string;
}

export function appendLoopTail(bodyStmts: Node[], tail: Node, ctx: TransformContext, loc: SourceLocation): LoopTail {
	let stmts = bodyStmts;
	let label = "";
	if (hasLoopContinue(stmts, "")) {
		ctx.tempCounter += 1;
		const jumps: LoopJumps = { bodyLabel: `__cont${ctx.tempCounter}`, loopLabel: `__lp${ctx.tempCounter}`, loopBroken: false };
		let i = 0;
		while (i < stmts.length) {
			stmts[i] = retargetLoopJumps(stmts[i], jumps, false);
			i += 1;
		}
		stmts = [makeSwitchWrapper(stmts, jumps.bodyLabel, loc)];
		if (jumps.loopBroken) label = jumps.loopLabel;
	}
	stmts.push(tail);
	return { tailStmts: stmts, tailLabel: label };
}

function capturedLetBinding(d: ForStmtData): Symbol | null {
	if (d.forInit == null || d.forInit.kind != NodeKind.VariableDecl) return null;
	if ((d.forInit.data as VariableDeclData).declKind != DeclKind.Let) return null;
	const sym = d.forInit.resolvedSym;
	if (sym == null) return null;
	if (capturedInClosure(d.forBody, sym, false) || headerCaptures(d, sym)) return sym;
	return null;
}

function headerCaptures(d: ForStmtData, sym: Symbol): boolean {
	return capturedInClosure((d.forInit.data as VariableDeclData).initializer, sym, false)
		|| capturedInClosure(d.forCondition, sym, false)
		|| capturedInClosure(d.forUpdate, sym, false);
}

function capturedInClosure(n: Node | null, sym: Symbol, nested: boolean): boolean {
	if (n == null) return false;
	if (nested && n.kind == NodeKind.Identifier && n.resolvedSym == sym) return true;
	const inner = nested || isFuncBoundary(n);
	return anyChild(n, (c: Node): boolean => capturedInClosure(c, sym, inner));
}

function renameBinding(n: Node | null, from: Symbol, to: Symbol): void {
	if (n == null) return;
	walkNode(n, (m: Node): Node => {
		if (m.kind == NodeKind.Identifier && m.resolvedSym == from) {
			(m.data as IdentifierData).name = to.name;
			m.resolvedSym = to;
		}
		return m;
	});
}

function isLoopNode(n: Node): boolean {
	return n.kind == NodeKind.WhileStmt || n.kind == NodeKind.DoWhileStmt || n.kind == NodeKind.ForStmt
		|| n.kind == NodeKind.ForOfStmt || n.kind == NodeKind.ForInStmt;
}

function continueVerdict(n: Node): Visit {
	if (n.kind == NodeKind.ContinueStmt && (n.data as ContinueStmtData).continueLabel == "") return Visit.Hit;
	return isFuncBoundary(n) || isLoopNode(n) ? Visit.Skip : Visit.Descend;
}

function hasOwnContinue(n: Node | null): boolean {
	if (n == null) return false;
	return anyDescendant(n, continueVerdict);
}

function labelOwnBreaks(n: Node | null, label: string): boolean {
	if (n == null) return false;
	if (n.kind == NodeKind.BreakStmt) {
		const bd = n.data as BreakStmtData;
		if (bd.breakLabel != "") return false;
		bd.breakLabel = label;
		return true;
	}
	if (isFuncBoundary(n) || isLoopNode(n) || n.kind == NodeKind.SwitchStmt) return false;
	let labelled = false;
	forEachChild(n, (c: Node): void => {
		if (labelOwnBreaks(c, label)) labelled = true;
	});
	return labelled;
}

function letOf(sym: Symbol, init: Node, loc: SourceLocation): Node {
	const decl = makeVarDecl(sym.name, init, DeclKind.Let, loc);
	decl.resolvedSym = sym;
	decl.nodeType = sym.symbolType;
	return decl;
}

function assignOf(sym: Symbol, value: Node, loc: SourceLocation): Node {
	return makeExprStmt(makeAssign(makeIdentResolved(sym, loc), value, loc), loc);
}

function iterationBody(body: Node, ctx: TransformContext, loc: SourceLocation): { stmts: Node[], label: string } {
	const stmts = extractBodyStmts(body);
	if (!hasOwnContinue(body)) return { stmts, label: "" };
	ctx.tempCounter += 1;
	const label = `__lp${ctx.tempCounter}`;
	let labelled = false;
	for (const s of stmts) {
		if (labelOwnBreaks(s, label)) labelled = true;
	}
	const wrapper = createNode(NodeKind.DoWhileStmt, { doBody: makeBlock(stmts, loc), doCondition: makeBool(false, loc), dwLabel: "", dwSwitchWrapper: false }, syntheticToken(loc));
	return { stmts: [wrapper], label: labelled ? label : "" };
}

function lowerPerIteration(d: ForStmtData, sym: Symbol, ctx: TransformContext, loc: SourceLocation): Node {
	const iter = freshOwnedSym(ctx, "fi", sym.symbolType);
	renameBinding(d.forBody, sym, iter);
	const inHeader = headerCaptures(d, sym);
	const outer: Node[] = [d.forInit];
	const loopStmts: Node[] = [];
	let carrier = sym;
	let cond = d.forCondition != null ? d.forCondition : makeBool(true, loc);
	if (inHeader) {
		carrier = freshOwnedSym(ctx, "fc", sym.symbolType);
		outer.push(letOf(carrier, makeIdentResolved(sym, loc), loc));
		renameBinding(d.forCondition, sym, iter);
		renameBinding(d.forUpdate, sym, iter);
	}
	loopStmts.push(letOf(iter, makeIdentResolved(carrier, loc), loc));
	if (inHeader) {
		if (d.forUpdate != null) {
			const first = freshOwnedSym(ctx, "ff", booleanType());
			outer.push(letOf(first, makeBool(true, loc), loc));
			loopStmts.push(makeIf(
				makeIdentResolved(first, loc),
				makeBlock([assignOf(first, makeBool(false, loc), loc)], loc),
				makeBlock([makeExprStmt(d.forUpdate, loc)], loc),
				loc,
			));
		}
		if (d.forCondition != null) {
			loopStmts.push(makeIf(makeUnary("!", d.forCondition, loc), makeBlock([makeBreak(loc)], loc), null, loc));
		}
		cond = makeBool(true, loc);
	}
	const body = iterationBody(d.forBody, ctx, loc);
	for (const s of body.stmts) loopStmts.push(s);
	loopStmts.push(assignOf(carrier, makeIdentResolved(iter, loc), loc));
	if (!inHeader && d.forUpdate != null) loopStmts.push(makeExprStmt(d.forUpdate, loc));
	const loop = makeWhile(cond, makeBlock(loopStmts, loc), loc);
	(loop.data as WhileStmtData).whileLabel = body.label;
	outer.push(loop);
	return makeBlock(outer, loc);
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

test "a continue in a body that yields leaves the body block" { assert leavesBodyBlock("function* g() { for (let i = 0; i < 4; i += 1) { switch (i) { case 1: continue; default: i; } yield i; } }"); }

test "a continue in a body that awaits leaves the body block" { assert leavesBodyBlock("async function g() { for (let i = 0; i < 4; i += 1) { try { if (i === 1) continue; await h(i); } finally { i; } } }"); }

test "while unchanged" { assert firstStmtKindAfter("while (true) {}", lowerForLoop) == NodeKind.WhileStmt; }

test "for-of unchanged" { assert firstStmtKindAfter("for (const x of arr) { x; }", lowerForLoop) == NodeKind.ForOfStmt; }
// Note: for(;;) not supported by parser — it always requires init/cond/update expressions
test "for with update only" { assert firstStmtKindAfter("for (let i = 0; i < 5; i++) { i; }", lowerForLoop) == NodeKind.BlockStmt; }

test "non-loop passthrough" { assert stmtCountAfter("const x = 1;", lowerForLoop) == 1; }

test "preserves surrounding stmts" { assert stmtCountAfter("let a = 1; for (let i = 0; i < 2; i++) {} let b = 2;", lowerForLoop) == 3; }

test "if stmt unchanged" { assert firstStmtKindAfter("if (x) {}", lowerForLoop) == NodeKind.IfStmt; }
