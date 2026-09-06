// Cancel Safe-Point Injection — PARALOCK Phase 3
//
// Injects `if (msSpawnCheckCancel(group)) { return; }` at loop backedges
// inside spawn closure bodies. This allows timed AwaitGroup waits to
// cancel running tasks that check at safe points.
//
// Only applicable to fused spawn paths — spawn(fn, { timeout: N }) — where
// the AwaitGroup pointer is known at transform time.

import { Node, NodeKind, SourceLocation, BlockStmtData, WhileStmtData, DoWhileStmtData, ForOfStmtData, ForStmtData, IfStmtData } from "../../ast/node";
import { makeCall, makeIdent, makeIf, makeBlock, makeReturn } from "../util";
import { booleanType } from "../../checker/types";

// Inject cancellation checks at loop backedges in the given function body.
// `groupIdent` is the AwaitGroup identifier node used for msSpawnCheckCancel.
export function injectCancelSafePoints(body: Node, groupIdent: Node, loc: SourceLocation): void {
	if (body == null) return;
	walkInjectCancel(body, groupIdent, loc);
}

function makeCancelCheck(groupIdent: Node, loc: SourceLocation): Node {
	const checkCall = makeCall(makeIdent("msSpawnCheckCancel", loc), [groupIdent], loc);
	checkCall.nodeType = booleanType();
	const retNode = makeReturn(null, loc);
	const ifBody = makeBlock([retNode], loc);
	return makeIf(checkCall, ifBody, null, loc);
}

// Walk statements, injecting cancel check at the start of loop bodies.
// Stops at nested function boundaries (FunctionExpr, ArrowFunction, FunctionDecl).
function walkInjectCancel(node: Node, groupIdent: Node, loc: SourceLocation): void {
	if (node == null) return;
	match (node.kind) {
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			for (const stmt of d.statements) {
				walkInjectCancel(stmt, groupIdent, loc);
			}
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			injectAtLoopBody(d.whileBody, groupIdent, loc);
			walkInjectCancel(d.whileBody, groupIdent, loc);
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			injectAtLoopBody(d.doBody, groupIdent, loc);
			walkInjectCancel(d.doBody, groupIdent, loc);
		},
		NodeKind.ForOfStmt => {
			const d = node.data as ForOfStmtData;
			injectAtLoopBody(d.forOfBody, groupIdent, loc);
			walkInjectCancel(d.forOfBody, groupIdent, loc);
		},
		NodeKind.ForStmt => {
			const d = node.data as ForStmtData;
			injectAtLoopBody(d.forBody, groupIdent, loc);
			walkInjectCancel(d.forBody, groupIdent, loc);
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			walkInjectCancel(d.consequent, groupIdent, loc);
			if (d.alternate != null) walkInjectCancel(d.alternate, groupIdent, loc);
		},
		// Stop at nested function boundaries — don't inject into nested closures
		NodeKind.FunctionExpr | NodeKind.ArrowFunction | NodeKind.FunctionDecl => {},
		_ => {},
	};
}

// Prepend a cancel check as the first statement of a loop body block.
function injectAtLoopBody(body: Node, groupIdent: Node, loc: SourceLocation): void {
	if (body == null) return;
	if (body.kind != NodeKind.BlockStmt) return;
	const bd = body.data as BlockStmtData;
	const check = makeCancelCheck(groupIdent, loc);
	const newStmts: Node[] = [check];
	for (const stmt of bd.statements) {
		newStmts.push(stmt);
	}
	bd.statements = newStmts;
}
