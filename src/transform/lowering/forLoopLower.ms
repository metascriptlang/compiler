// For Loop Lowering — transforms for(init;cond;update) → block with while
// Follows reference implementation for_loop_lower.zig + reference transform pattern
//
// for (let i = 0; i < 10; i++) { body; }
// →
// { let i = 0; while (i < 10) { body; i++; } }
//
// Handles continue by inserting update before each continue statement.

import { Node, NodeKind, ForStmtData, BlockStmtData, IfStmtData, TryCatchStmtData } from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeBool, makeBlock, makeWhile, makeExprStmt, extractBodyStmts } from "../util";
import { firstStmtKindAfter, stmtCountAfter } from "../testUtil";

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
		const s = stmts[i];
		if (s.kind === NodeKind.ContinueStmt) {
			// Replace continue with block { update; continue; }
			stmts[i] = makeBlock([cloneStmt(updateStmt), s], s.location);
		} else if (s.kind === NodeKind.BlockStmt) {
			const bd = s.data as BlockStmtData;
			rewriteContinues(bd.statements, updateStmt);
		} else if (s.kind === NodeKind.IfStmt) {
			const ifd = s.data as IfStmtData;
			if (ifd.consequent !== null) rewriteContinuesInNode(ifd.consequent, updateStmt);
			if (ifd.alternate !== null) rewriteContinuesInNode(ifd.alternate, updateStmt);
		} else if (s.kind === NodeKind.TryCatchStmt) {
			const td = s.data as TryCatchStmtData;
			if (td.tryBody !== null) rewriteContinuesInNode(td.tryBody, updateStmt);
			if (td.catchBody !== null) rewriteContinuesInNode(td.catchBody, updateStmt);
			if (td.finallyBody !== null) rewriteContinuesInNode(td.finallyBody, updateStmt);
		}
		// Skip WhileStmt, ForStmt, ForOfStmt — nested loops own their continues
		i += 1;
	}
}

function rewriteContinuesInNode(node: Node, updateStmt: Node): void {
	if (node.kind === NodeKind.BlockStmt) {
		const bd = node.data as BlockStmtData;
		rewriteContinues(bd.statements, updateStmt);
	}
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

// ===== Tests =====
test "basic for becomes block" { assert firstStmtKindAfter("for (let i = 0; i < 10; i++) {}", lowerForLoop) === NodeKind.BlockStmt; }

test "while unchanged" { assert firstStmtKindAfter("while (true) {}", lowerForLoop) === NodeKind.WhileStmt; }

test "for-of unchanged" { assert firstStmtKindAfter("for (const x of arr) { x; }", lowerForLoop) === NodeKind.ForOfStmt; }
// Note: for(;;) not supported by parser — it always requires init/cond/update expressions
test "for with update only" { assert firstStmtKindAfter("for (let i = 0; i < 5; i++) { i; }", lowerForLoop) === NodeKind.BlockStmt; }

test "non-loop passthrough" { assert stmtCountAfter("const x = 1;", lowerForLoop) === 1; }

test "preserves surrounding stmts" { assert stmtCountAfter("let a = 1; for (let i = 0; i < 2; i++) {} let b = 2;", lowerForLoop) === 3; }

test "if stmt unchanged" { assert firstStmtKindAfter("if (x) {}", lowerForLoop) === NodeKind.IfStmt; }
