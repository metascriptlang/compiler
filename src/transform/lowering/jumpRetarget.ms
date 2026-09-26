// Jump Retarget — gives every break/continue a target the backends can honor.
//
// After matchLower/switchLower, a bare `break` in a match arm sits inside a
// C/JS `switch` that would capture it, and a bare `continue` inside a
// switchLower wrapper (do-while(false)) would bind to the wrapper. Both must
// reach the enclosing REAL loop. This pass walks each function with a stack of
// jump targets and labels the jumps that cross a capturing construct; jumps
// already correct stay bare, so emitted code for the common cases is unchanged.
//
// Reference model: transf.nim transformLoopBody — loop-crossing jumps become
// labeled breaks resolved at lowering time; codegen only translates labels.

import { Node, NodeKind, BreakStmtData, ContinueStmtData, WhileStmtData, DoWhileStmtData, ForStmtData, ForOfStmtData, ForInStmtData } from "../../ast/node";
import { TransformContext } from "../context";
import { forEachChild } from "../../ast/visitor";
import { mapChildren } from "../walker";
import { makeBreak, makeBool, makeBlock, makeIf, makeUnary, makeSwitchWrapper, extractBodyStmts } from "../util";

const TK_LOOP = 1;
const TK_WRAPPER = 2;
const TK_SWITCH = 3;

interface JumpTarget {
	targetKind: int32;
	node: Node;
}

interface RetargetState {
	stack: JumpTarget[];
	ctx: TransformContext;
}

export function retargetJumps(program: Node, ctx: TransformContext): Node {
	const st: RetargetState = { stack: [], ctx };
	walk(program, st);
	return program;
}

export function isFnBoundary(kind: NodeKind): boolean {
	return kind == NodeKind.FunctionDecl
		|| kind == NodeKind.FunctionExpr
		|| kind == NodeKind.ArrowFunction
		|| kind == NodeKind.MethodDecl
		|| kind == NodeKind.ConstructorDecl
		|| kind == NodeKind.TestDecl;
}

export function isLoopKind(kind: NodeKind): boolean {
	return kind == NodeKind.WhileStmt
		|| kind == NodeKind.DoWhileStmt
		|| kind == NodeKind.ForStmt
		|| kind == NodeKind.ForOfStmt
		|| kind == NodeKind.ForInStmt;
}

export interface LoopJumps {
	bodyLabel: string;
	loopLabel: string;
	loopBroken: boolean;
}

function isSwitchWrapper(node: Node): boolean {
	return node.kind == NodeKind.DoWhileStmt && (node.data as DoWhileStmtData).dwSwitchWrapper;
}

function continuesLoop(node: Node, loopLabel: string): boolean {
	if (node.kind == NodeKind.ContinueStmt) {
		const label = (node.data as ContinueStmtData).continueLabel;
		return label == "" || label == loopLabel;
	}
	if (isFnBoundary(node.kind) || (isLoopKind(node.kind) && !isSwitchWrapper(node))) return false;
	let found = false;
	forEachChild(node, (child: Node): void => {
		if (!found && continuesLoop(child, loopLabel)) found = true;
	});
	return found;
}

export function hasLoopContinue(stmts: Node[], loopLabel: string): boolean {
	for (const s of stmts) {
		if (continuesLoop(s, loopLabel)) return true;
	}
	return false;
}

export function retargetLoopJumps(node: Node, jumps: LoopJumps, inSwitch: boolean): Node {
	if (node == null) return node;
	if (node.kind == NodeKind.ContinueStmt) {
		const label = (node.data as ContinueStmtData).continueLabel;
		if (label != "" && label != jumps.loopLabel) return node;
		const leave = makeBreak(node.location);
		(leave.data as BreakStmtData).breakLabel = jumps.bodyLabel;
		return leave;
	}
	if (node.kind == NodeKind.BreakStmt) {
		const bd = node.data as BreakStmtData;
		if (bd.breakLabel == "" && !inSwitch) {
			bd.breakLabel = jumps.loopLabel;
			jumps.loopBroken = true;
		}
		return node;
	}
	const wrapper = isSwitchWrapper(node);
	if (isFnBoundary(node.kind) || (isLoopKind(node.kind) && !wrapper)) return node;
	const childInSwitch = inSwitch || wrapper || node.kind == NodeKind.SwitchStmt;
	mapChildren(node, (child: Node): Node => retargetLoopJumps(child, jumps, childInSwitch));
	return node;
}

export function moveDoWhileTestIntoBody(stmt: Node, pre: Node[], cond: Node, ctx: TransformContext): void {
	const wd = stmt.data as DoWhileStmtData;
	const loc = stmt.location;
	let body: Node[] = extractBodyStmts(wd.doBody);
	if (hasLoopContinue(body, wd.dwLabel)) {
		ctx.tempCounter += 1;
		const jumps: LoopJumps = { bodyLabel: `__cont${ctx.tempCounter}`, loopLabel: wd.dwLabel != "" ? wd.dwLabel : `__lp${ctx.tempCounter}`, loopBroken: false };
		let i = 0;
		while (i < body.length) {
			body[i] = retargetLoopJumps(body[i], jumps, false);
			i += 1;
		}
		body = [makeSwitchWrapper(body, jumps.bodyLabel, loc)];
		if (jumps.loopBroken) wd.dwLabel = jumps.loopLabel;
	}
	for (const s of pre) body.push(s);
	body.push(makeIf(makeUnary("!", cond, loc), makeBlock([makeBreak(loc)], loc), null as unknown as Node, loc));
	wd.doCondition = makeBool(true, loc);
	wd.doBody = makeBlock(body, loc);
}

function ensureLoopLabel(target: JumpTarget, ctx: TransformContext): string {
	if (target.node.kind == NodeKind.WhileStmt) {
		const wd = target.node.data as WhileStmtData;
		if (wd.whileLabel == "") {
			ctx.tempCounter += 1;
			wd.whileLabel = `__lp${ctx.tempCounter}`;
		}
		return wd.whileLabel;
	}
	if (target.node.kind == NodeKind.DoWhileStmt) {
		const dd = target.node.data as DoWhileStmtData;
		if (dd.dwLabel == "") {
			ctx.tempCounter += 1;
			dd.dwLabel = `__lp${ctx.tempCounter}`;
		}
		return dd.dwLabel;
	}
	if (target.node.kind == NodeKind.ForStmt) {
		const fd = target.node.data as ForStmtData;
		if (fd.forLabel == "") {
			ctx.tempCounter += 1;
			fd.forLabel = `__lp${ctx.tempCounter}`;
		}
		return fd.forLabel;
	}
	if (target.node.kind == NodeKind.ForOfStmt) {
		const fd = target.node.data as ForOfStmtData;
		if (fd.forOfLabel == "") {
			ctx.tempCounter += 1;
			fd.forOfLabel = `__lp${ctx.tempCounter}`;
		}
		return fd.forOfLabel;
	}
	if (target.node.kind == NodeKind.ForInStmt) {
		const fd = target.node.data as ForInStmtData;
		if (fd.forInLabel == "") {
			ctx.tempCounter += 1;
			fd.forInLabel = `__lp${ctx.tempCounter}`;
		}
		return fd.forInLabel;
	}
	return "";
}

function retargetBreak(node: Node, st: RetargetState): void {
	const bd = node.data as BreakStmtData;
	if (bd.breakLabel != "") return;
	let crossedSwitch = false;
	let i = st.stack.length - 1;
	while (i >= 0) {
		const t = st.stack[i];
		if (t.targetKind == TK_SWITCH) {
			crossedSwitch = true;
			i -= 1;
			continue;
		}
		if (crossedSwitch) {
			const lbl = ensureLoopLabel(t, st.ctx);
			if (lbl != "") bd.breakLabel = lbl;
		}
		return;
	}
}

function retargetContinue(node: Node, st: RetargetState): void {
	const cd = node.data as ContinueStmtData;
	if (cd.continueLabel != "") return;
	let crossedWrapper = false;
	let i = st.stack.length - 1;
	while (i >= 0) {
		const t = st.stack[i];
		if (t.targetKind == TK_SWITCH || t.targetKind == TK_WRAPPER) {
			if (t.targetKind == TK_WRAPPER) crossedWrapper = true;
			i -= 1;
			continue;
		}
		if (crossedWrapper) {
			const lbl = ensureLoopLabel(t, st.ctx);
			if (lbl != "") cd.continueLabel = lbl;
		}
		return;
	}
}

function walk(node: Node, st: RetargetState): void {
	const kind = node.kind;
	if (kind == NodeKind.BreakStmt) {
		retargetBreak(node, st);
		return;
	}
	if (kind == NodeKind.ContinueStmt) {
		retargetContinue(node, st);
		return;
	}
	if (isFnBoundary(kind)) {
		const savedStack = st.stack;
		st.stack = [];
		forEachChild(node, (child: Node) => { walk(child, st); });
		st.stack = savedStack;
		return;
	}
	if (kind == NodeKind.WhileStmt) {
		st.stack.push({ targetKind: TK_LOOP, node });
		forEachChild(node, (child: Node) => { walk(child, st); });
		st.stack.pop();
		return;
	}
	if (kind == NodeKind.DoWhileStmt) {
		const dd = node.data as DoWhileStmtData;
		st.stack.push({ targetKind: dd.dwSwitchWrapper ? TK_WRAPPER : TK_LOOP, node });
		forEachChild(node, (child: Node) => { walk(child, st); });
		st.stack.pop();
		return;
	}
	if (kind == NodeKind.ForStmt || kind == NodeKind.ForOfStmt || kind == NodeKind.ForInStmt) {
		st.stack.push({ targetKind: TK_LOOP, node });
		forEachChild(node, (child: Node) => { walk(child, st); });
		st.stack.pop();
		return;
	}
	if (kind == NodeKind.SwitchStmt) {
		st.stack.push({ targetKind: TK_SWITCH, node });
		forEachChild(node, (child: Node) => { walk(child, st); });
		st.stack.pop();
		return;
	}
	forEachChild(node, (child: Node) => { walk(child, st); });
}
