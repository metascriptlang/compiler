// For Loop Lowering — transforms for(init;cond;update) → block with while
// Follows reference implementation for_loop_lower.zig + reference transform pattern
//
// for (let i = 0; i < 10; i++) { body; }
// →
// { let i = 0; while (i < 10) { body; i++; } }
//
// Handles continue by inserting update before each continue statement.

import { Node, NodeKind, SourceLocation, ForStmtData, BlockStmtData, IfStmtData, TryCatchStmtData, WhileStmtData, MatchStmtData, MatchCaseData, VariableDeclData, IdentifierData, BreakStmtData, ContinueStmtData, DeclKind, Symbol, createNode } from "../../ast/node";
import { forEachChild } from "../../ast/visitor";
import { TransformContext, freshOwnedSym } from "../context";
import { walkNode, isFuncBoundary } from "../walker";
import { makeBool, makeBlock, makeWhile, makeExprStmt, makeVarDecl, makeIdentResolved, makeAssign, makeIf, makeUnary, makeBreak, syntheticToken, extractBodyStmts } from "../util";
import { booleanType } from "../../checker/types";
import { firstStmtKindAfter, stmtCountAfter, parseInput, makeCtx, getStmts } from "../testUtil";

// ===== Main Entry Point =====

export function lowerForLoop(program: Node, ctx: TransformContext): Node {
	walkNode(program, (node: Node): Node => lowerForNode(node, ctx));
	return program;
}

function lowerForNode(node: Node, ctx: TransformContext): Node {
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

	// 3. Extract body statements and rewrite continue to include update
	const bodyStmts: Node[] = extractBodyStmts(d.forBody);

	// 4. Append update as last statement, and insert before each continue
	if (d.forUpdate != null) {
		const updateStmt = makeExprStmt(d.forUpdate, loc);
		rewriteContinues(bodyStmts, updateStmt);
		bodyStmts.push(updateStmt);
	}

	// 5. Build while loop
	const whileBody = makeBlock(bodyStmts, loc);
	const whileNode = makeWhile(cond, whileBody, loc);
	outerStmts.push(whileNode);

	return makeBlock(outerStmts, loc);
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
	let found = false;
	forEachChild(n, (c: Node): void => {
		if (!found && capturedInClosure(c, sym, inner)) found = true;
	});
	return found;
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

function hasOwnContinue(n: Node | null): boolean {
	if (n == null) return false;
	if (n.kind == NodeKind.ContinueStmt) return (n.data as ContinueStmtData).continueLabel == "";
	if (isFuncBoundary(n) || isLoopNode(n)) return false;
	let found = false;
	forEachChild(n, (c: Node): void => {
		if (!found && hasOwnContinue(c)) found = true;
	});
	return found;
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

// True iff every ContinueStmt sits right after another statement in its block
// (i.e., was rewritten to { update; continue; }). A continue at block index 0
// means the update insertion was missed.
function continuesGuarded(node: Node): boolean {
	if (node.kind == NodeKind.BlockStmt) {
		const bd = node.data as BlockStmtData;
		let i = 0;
		while (i < bd.statements.length) {
			const s = bd.statements[i];
			if (s.kind == NodeKind.ContinueStmt) {
				if (i == 0 || bd.statements[i - 1].kind != NodeKind.ExprStmt) return false;
			} else if (!continuesGuarded(s)) {
				return false;
			}
			i += 1;
		}
		return true;
	}
	if (node.kind == NodeKind.WhileStmt) {
		const wd = node.data as WhileStmtData;
		return continuesGuarded(wd.whileBody);
	}
	if (node.kind == NodeKind.IfStmt) {
		const ifd = node.data as IfStmtData;
		if (ifd.consequent != null && !continuesGuarded(ifd.consequent)) return false;
		if (ifd.alternate != null && !continuesGuarded(ifd.alternate)) return false;
		return true;
	}
	if (node.kind == NodeKind.MatchStmt) {
		const md = node.data as MatchStmtData;
		let i = 0;
		while (i < md.matchStmtCases.length) {
			const c = md.matchStmtCases[i];
			if (c.kind == NodeKind.MatchCase) {
				const cd = c.data as MatchCaseData;
				if (cd.caseBody != null && !continuesGuarded(cd.caseBody)) return false;
			}
			i += 1;
		}
		return true;
	}
	return true;
}

function loweredGuarded(input: string): boolean {
	const r = parseInput(input);
	if (!r.ok) return false;
	const lowered = lowerForLoop(r.value, makeCtx());
	const stmts = getStmts(lowered);
	let i = 0;
	while (i < stmts.length) {
		if (!continuesGuarded(stmts[i])) return false;
		i += 1;
	}
	return true;
}

// ===== Tests =====
test "basic for becomes block" { assert firstStmtKindAfter("for (let i = 0; i < 10; i++) {}", lowerForLoop) == NodeKind.BlockStmt; }

test "bare continue gets update" { assert loweredGuarded("for (let i = 0; i < 4; i += 1) { if (i === 1) continue; }"); }

test "continue in else gets update" { assert loweredGuarded("for (let i = 0; i < 4; i += 1) { if (i === 0) {} else { continue; } }"); }

test "continue in else-if chain gets update" { assert loweredGuarded("for (let i = 0; i < 4; i += 1) { if (i === 0) {} else if (i === 1) {} else { continue; } }"); }

test "continue in match case gets update" { assert loweredGuarded("for (let i = 0; i < 4; i += 1) { match (i) { 1 => { continue; } _ => {} } }"); }

test "while unchanged" { assert firstStmtKindAfter("while (true) {}", lowerForLoop) == NodeKind.WhileStmt; }

test "for-of unchanged" { assert firstStmtKindAfter("for (const x of arr) { x; }", lowerForLoop) == NodeKind.ForOfStmt; }
// Note: for(;;) not supported by parser — it always requires init/cond/update expressions
test "for with update only" { assert firstStmtKindAfter("for (let i = 0; i < 5; i++) { i; }", lowerForLoop) == NodeKind.BlockStmt; }

test "non-loop passthrough" { assert stmtCountAfter("const x = 1;", lowerForLoop) == 1; }

test "preserves surrounding stmts" { assert stmtCountAfter("let a = 1; for (let i = 0; i < 2; i++) {} let b = 2;", lowerForLoop) == 3; }

test "if stmt unchanged" { assert firstStmtKindAfter("if (x) {}", lowerForLoop) == NodeKind.IfStmt; }
