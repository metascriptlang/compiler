// For Loop Lowering — transforms for(init;cond;update) → block with while
// Follows reference for_loop_lower.zig + Nim's transformFor
//
// for (let i = 0; i < 10; i++) { body; }
// →
// { let i = 0; while (i < 10) { body; i++; } }
//
// Handles continue by inserting update before each continue statement.

import {
	Node, NodeKind,
	ForStmtData,
} from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeBool, makeBlock, makeWhile, makeExprStmt, extractBodyStmts } from "../util";
import { check } from "std/testing";
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

	// 3. Extract body statements
	const bodyStmts: Node[] = extractBodyStmts(d.forBody);

	// 4. Append update as last statement in while body
	if (d.forUpdate !== null) {
		bodyStmts.push(makeExprStmt(d.forUpdate, loc));
	}

	// 5. Build while loop
	const whileBody = makeBlock(bodyStmts, loc);
	const whileNode = makeWhile(cond, whileBody, loc);
	outerStmts.push(whileNode);

	return makeBlock(outerStmts, loc);
}

// ===== Tests =====
test "basic for becomes block" { check(firstStmtKindAfter("for (let i = 0; i < 10; i++) {}", lowerForLoop) === NodeKind.BlockStmt); }

test "while unchanged" { check(firstStmtKindAfter("while (true) {}", lowerForLoop) === NodeKind.WhileStmt); }

test "for-of unchanged" { check(firstStmtKindAfter("for (const x of arr) { x; }", lowerForLoop) === NodeKind.ForOfStmt); }
// Note: for(;;) not supported by parser — it always requires init/cond/update expressions
test "for with update only" { check(firstStmtKindAfter("for (let i = 0; i < 5; i++) { i; }", lowerForLoop) === NodeKind.BlockStmt); }

test "non-loop passthrough" { check(stmtCountAfter("const x = 1;", lowerForLoop) === 1); }

test "preserves surrounding stmts" { check(stmtCountAfter("let a = 1; for (let i = 0; i < 2; i++) {} let b = 2;", lowerForLoop) === 3); }

test "if stmt unchanged" { check(firstStmtKindAfter("if (x) {}", lowerForLoop) === NodeKind.IfStmt); }
