// For Loop Lowering — transforms for(init;cond;update) → block with while
// Follows reference implementation for_loop_lower.zig + reference transform pattern
//
// for (let i = 0; i < 10; i++) { body; }
// →
// { let i = 0; while (i < 10) { body; i++; } }
//
// Handles continue by inserting update before each continue statement.

import { Node, NodeKind, ForStmtData, BlockStmtData, IfStmtData, TryCatchStmtData, WhileStmtData, MatchStmtData, MatchCaseData } from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeBool, makeBlock, makeWhile, makeExprStmt, extractBodyStmts } from "../util";
import { firstStmtKindAfter, stmtCountAfter, parseInput, makeCtx, getStmts } from "../testUtil";

// ===== Main Entry Point =====

export function lowerForLoop(program: Node, ctx: TransformContext): Node {
	walkNode(program, lowerForNode);
	return program;
}

function lowerForNode(node: Node): Node {
	if (node.kind !== NodeKind.ForStmt) return node;
	const d = node.data as ForStmtData;
	const loc = node.location;
	const outerStmts: Node[] = [];

	// 1. Init statement (if present)
	if (d.forInit !== null) {
		outerStmts.push(d.forInit);
	}

	// 2. Condition (default to true for infinite loop)
	let cond: Node = null as unknown as Node;
	if (d.forCondition !== null) {
		cond = d.forCondition;
	} else {
		cond = makeBool(true, loc);
	}

	// 3. Extract body statements and rewrite continue to include update
	const bodyStmts: Node[] = extractBodyStmts(d.forBody);

	// 4. Append update as last statement, and insert before each continue
	if (d.forUpdate !== null) {
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
	if (node.kind === NodeKind.ContinueStmt) {
		return makeBlock([cloneStmt(updateStmt), node], node.location);
	}
	if (node.kind === NodeKind.BlockStmt) {
		const bd = node.data as BlockStmtData;
		rewriteContinues(bd.statements, updateStmt);
	} else if (node.kind === NodeKind.IfStmt) {
		const ifd = node.data as IfStmtData;
		if (ifd.consequent !== null) ifd.consequent = rewriteContinuesInNode(ifd.consequent, updateStmt);
		if (ifd.alternate !== null) ifd.alternate = rewriteContinuesInNode(ifd.alternate, updateStmt);
	} else if (node.kind === NodeKind.TryCatchStmt) {
		const td = node.data as TryCatchStmtData;
		if (td.tryBody !== null) td.tryBody = rewriteContinuesInNode(td.tryBody, updateStmt);
		if (td.catchBody !== null) td.catchBody = rewriteContinuesInNode(td.catchBody, updateStmt);
		if (td.finallyBody !== null) td.finallyBody = rewriteContinuesInNode(td.finallyBody, updateStmt);
	} else if (node.kind === NodeKind.MatchStmt) {
		const md = node.data as MatchStmtData;
		let i = 0;
		while (i < md.matchStmtCases.length) {
			const c = md.matchStmtCases[i];
			if (c.kind === NodeKind.MatchCase) {
				const cd = c.data as MatchCaseData;
				if (cd.caseBody !== null) cd.caseBody = rewriteContinuesInNode(cd.caseBody, updateStmt);
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

// True iff every ContinueStmt sits right after another statement in its block
// (i.e., was rewritten to { update; continue; }). A continue at block index 0
// means the update insertion was missed.
function continuesGuarded(node: Node): boolean {
	if (node.kind === NodeKind.BlockStmt) {
		const bd = node.data as BlockStmtData;
		let i = 0;
		while (i < bd.statements.length) {
			const s = bd.statements[i];
			if (s.kind === NodeKind.ContinueStmt) {
				if (i === 0 || bd.statements[i - 1].kind !== NodeKind.ExprStmt) return false;
			} else if (!continuesGuarded(s)) {
				return false;
			}
			i += 1;
		}
		return true;
	}
	if (node.kind === NodeKind.WhileStmt) {
		const wd = node.data as WhileStmtData;
		return continuesGuarded(wd.whileBody);
	}
	if (node.kind === NodeKind.IfStmt) {
		const ifd = node.data as IfStmtData;
		if (ifd.consequent !== null && !continuesGuarded(ifd.consequent)) return false;
		if (ifd.alternate !== null && !continuesGuarded(ifd.alternate)) return false;
		return true;
	}
	if (node.kind === NodeKind.MatchStmt) {
		const md = node.data as MatchStmtData;
		let i = 0;
		while (i < md.matchStmtCases.length) {
			const c = md.matchStmtCases[i];
			if (c.kind === NodeKind.MatchCase) {
				const cd = c.data as MatchCaseData;
				if (cd.caseBody !== null && !continuesGuarded(cd.caseBody)) return false;
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
test "basic for becomes block" { assert firstStmtKindAfter("for (let i = 0; i < 10; i++) {}", lowerForLoop) === NodeKind.BlockStmt; }

test "bare continue gets update" { assert loweredGuarded("for (let i = 0; i < 4; i += 1) { if (i === 1) continue; }"); }

test "continue in else gets update" { assert loweredGuarded("for (let i = 0; i < 4; i += 1) { if (i === 0) {} else { continue; } }"); }

test "continue in else-if chain gets update" { assert loweredGuarded("for (let i = 0; i < 4; i += 1) { if (i === 0) {} else if (i === 1) {} else { continue; } }"); }

test "continue in match case gets update" { assert loweredGuarded("for (let i = 0; i < 4; i += 1) { match (i) { 1 => { continue; } _ => {} } }"); }

test "while unchanged" { assert firstStmtKindAfter("while (true) {}", lowerForLoop) === NodeKind.WhileStmt; }

test "for-of unchanged" { assert firstStmtKindAfter("for (const x of arr) { x; }", lowerForLoop) === NodeKind.ForOfStmt; }
// Note: for(;;) not supported by parser — it always requires init/cond/update expressions
test "for with update only" { assert firstStmtKindAfter("for (let i = 0; i < 5; i++) { i; }", lowerForLoop) === NodeKind.BlockStmt; }

test "non-loop passthrough" { assert stmtCountAfter("const x = 1;", lowerForLoop) === 1; }

test "preserves surrounding stmts" { assert stmtCountAfter("let a = 1; for (let i = 0; i < 2; i++) {} let b = 2;", lowerForLoop) === 3; }

test "if stmt unchanged" { assert firstStmtKindAfter("if (x) {}", lowerForLoop) === NodeKind.IfStmt; }
