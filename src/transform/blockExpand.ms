import {
	Node, NodeKind, ProgramData, BlockStmtData, IfStmtData, WhileStmtData, ForStmtData,
	ForOfStmtData, ForInStmtData, DoWhileStmtData, SwitchStmtData, SwitchCaseData,
	FunctionDeclData, ArrowFunctionData, FunctionExprData,
	ClassDeclData, ActorDeclData, MethodDeclData, ConstructorDeclData,
	ExportDeclData, DecoratedDeclData, TryCatchStmtData, TestDeclData,
} from "../ast/node";
import { Visitor, mapChildren } from "../ast/visitor";
import { TransformContext } from "./context";
import { makeBlock } from "./util";
import { parseInput, makeCtx, getStmts } from "./testUtil";

// Expanding visitor: takes a statement, returns array of replacement statements
type ExpandingVisitor = (node: Node) => Node[];

// ===== 1:N Block Expansion =====
// Walks a statement list, allowing each statement to expand into multiple statements.
// The expanding visitor returns Node[] for each input statement.

export function walkBlockExpanding(stmts: Node[], expander: ExpandingVisitor): Node[] {
	const result: Node[] = [];
	for (const stmt of stmts) {
		const expanded = expander(stmt);
		for (const node of expanded) {
			result.push(node);
		}
	}
	return result;
}

// ===== Block-Expanding Walk =====
// Shared walker for transforms that expand statement lists (1:N).
// Used by matchLower and resultDesugar — both walk the same node kinds,
// expanding Program/BlockStmt stmt lists and recursing into function bodies.

type StmtExpander = (stmt: Node, ctx: TransformContext) => Node[];

class ExpandWalk {
	expander: StmtExpander;
	ctx: TransformContext;
	onFnEntry: FnEntryHook;
	onFnExit: FnExitHook;
}

// Optional hook called on function-like node entry/exit.
// onEntry receives the function node, returns opaque state to restore on exit.
// Used by resultDesugar to track enclosing function return types.
export type FnEntryHook = (node: Node) => void;
export type FnExitHook = (node: Node) => void;

// Helpers to replace statement arrays in-place without value-copy aliasing.
// In C backend, `const d = node.data as X; d.field = y;` modifies a VALUE COPY,
// not the original node. These helpers take the node, extract old stmts, compute
// new stmts, and write back via node.data = {...} in a single scope where the
// return value is directly consumed (no local for DRC to destroy).
function replaceProgStmts(node: Node, w: ExpandWalk, visit: Visitor): void {
	const pd = node.data as ProgramData;
	const expanded = expandStmtList(pd.programStmts, w, visit);
	if (expanded != pd.programStmts) node.data = { programStmts: expanded };
}

function replaceBlockStmts(node: Node, w: ExpandWalk, visit: Visitor): void {
	const bd = node.data as BlockStmtData;
	const expanded = expandStmtList(bd.statements, w, visit);
	if (expanded != bd.statements) node.data = { statements: expanded };
}

function replaceCaseStmts(node: Node, w: ExpandWalk, visit: Visitor): void {
	const cd = node.data as SwitchCaseData;
	const expanded = expandStmtList(cd.caseStmts, w, visit);
	if (expanded != cd.caseStmts) node.data = { caseTests: cd.caseTests, caseStmts: expanded, isDefault: cd.isDefault };
}

let expandTryDepth = 0;

export function expandingInsideTry(): boolean {
	return expandTryDepth > 0;
}

function walkFnBodyHooked(body: Node, w: ExpandWalk, visit: Visitor): void {
	const outerTryDepth = expandTryDepth;
	expandTryDepth = 0;
	expandWalk(body, w, visit);
	expandTryDepth = outerTryDepth;
}

function expandStmtBodyHooked(node: Node, w: ExpandWalk, visit: Visitor): Node {
	if (node == null) return node;
	if (node.kind == NodeKind.BlockStmt) {
		expandWalk(node, w, visit);
		return node;
	}
	const expanded = w.expander(node, w.ctx);
	for (const stmt of expanded) {
		expandWalk(stmt, w, visit);
	}
	if (expanded.length == 1) return expanded[0];
	return makeBlock(expanded, node.location);
}

export function walkExpandBlocks(node: Node, expander: StmtExpander, ctx: TransformContext): void {
	walkExpandBlocksHooked(node, expander, ctx, null as unknown as FnEntryHook, null as unknown as FnExitHook);
}

// One visitor per walk: the default arm hands it to mapChildren for every node it does not
// special-case, so it is built once here and not once per node.
export function walkExpandBlocksHooked(node: Node, expander: StmtExpander, ctx: TransformContext, onFnEntry: FnEntryHook, onFnExit: FnExitHook): void {
	const w: ExpandWalk = { expander, ctx, onFnEntry, onFnExit };
	const visit = (child: Node): Node => {
		expandWalk(child, w, visit);
		return child;
	};
	expandWalk(node, w, visit);
}

function expandWalk(node: Node, w: ExpandWalk, visit: Visitor): void {
	if (node == null) return;
	match (node.kind) {
		NodeKind.Program => {
			replaceProgStmts(node, w, visit);
		},
		NodeKind.BlockStmt => {
			replaceBlockStmts(node, w, visit);
		},
		NodeKind.FunctionDecl => {
			const d = node.data as FunctionDeclData;
			if (w.onFnEntry != null) w.onFnEntry(node);
			walkFnBodyHooked(d.fnBody, w, visit);
			if (w.onFnExit != null) w.onFnExit(node);
		},
		NodeKind.ArrowFunction => {
			const d = node.data as ArrowFunctionData;
			if (w.onFnEntry != null) w.onFnEntry(node);
			walkFnBodyHooked(d.arrowBody, w, visit);
			if (w.onFnExit != null) w.onFnExit(node);
		},
		NodeKind.FunctionExpr => {
			const d = node.data as FunctionExprData;
			if (w.onFnEntry != null) w.onFnEntry(node);
			walkFnBodyHooked(d.funcExprBody, w, visit);
			if (w.onFnExit != null) w.onFnExit(node);
		},
		NodeKind.MethodDecl => {
			const d = node.data as MethodDeclData;
			if (w.onFnEntry != null) w.onFnEntry(node);
			walkFnBodyHooked(d.methodBody, w, visit);
			if (w.onFnExit != null) w.onFnExit(node);
		},
		NodeKind.ConstructorDecl => {
			const d = node.data as ConstructorDeclData;
			walkFnBodyHooked(d.ctorBody, w, visit);
		},
		NodeKind.ExportDecl => {
			const d = node.data as ExportDeclData;
			expandWalk(d.exportedDecl, w, visit);
		},
		NodeKind.TestDecl => {
			const d = node.data as TestDeclData;
			walkFnBodyHooked(d.testBody, w, visit);
		},
		NodeKind.AssertStmt => {},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			d.consequent = expandStmtBodyHooked(d.consequent, w, visit);
			d.alternate = expandStmtBodyHooked(d.alternate, w, visit);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			d.whileBody = expandStmtBodyHooked(d.whileBody, w, visit);
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			d.doBody = expandStmtBodyHooked(d.doBody, w, visit);
		},
		NodeKind.ForStmt => {
			const d = node.data as ForStmtData;
			d.forBody = expandStmtBodyHooked(d.forBody, w, visit);
		},
		NodeKind.ForOfStmt => {
			const d = node.data as ForOfStmtData;
			d.forOfBody = expandStmtBodyHooked(d.forOfBody, w, visit);
		},
		NodeKind.ForInStmt => {
			const d = node.data as ForInStmtData;
			d.forInBody = expandStmtBodyHooked(d.forInBody, w, visit);
		},
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			expandTryDepth += 1;
			expandWalk(d.tryBody, w, visit);
			expandWalk(d.catchBody, w, visit);
			expandWalk(d.finallyBody, w, visit);
			expandTryDepth -= 1;
		},
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			let i = 0;
			while (i < d.switchCases.length) {
				expandWalk(d.switchCases[i], w, visit);
				i = i + 1;
			}
		},
		NodeKind.SwitchCase => {
			replaceCaseStmts(node, w, visit);
		},
		NodeKind.DecoratedDecl => {
			const d = node.data as DecoratedDeclData;
			expandWalk(d.decoratedNode, w, visit);
		},
		NodeKind.ClassDecl => {
			const d = node.data as ClassDeclData;
			let i = 0;
			while (i < d.classBody.length) {
				expandWalk(d.classBody[i], w, visit);
				i = i + 1;
			}
		},
		NodeKind.ActorDecl => {
			const d = node.data as ActorDeclData;
			let i = 0;
			while (i < d.actorBody.length) {
				expandWalk(d.actorBody[i], w, visit);
				i = i + 1;
			}
		},
		_ => {
			mapChildren(node, visit);
		},
	};
}

// Returns `stmts` itself when every statement expands to itself, so a block no lowering touches
// is neither copied nor rebuilt.
function expandStmtList(stmts: Node[], w: ExpandWalk, visit: Visitor): Node[] {
	let result: Node[] = stmts;
	let changed = false;
	for (let i = 0; i < stmts.length; i += 1) {
		const stmt = stmts[i];
		const expanded = w.expander(stmt, w.ctx);
		if (!changed && expanded.length == 1 && expanded[0] == stmt) continue;
		if (!changed) {
			changed = true;
			result = [];
			for (let j = 0; j < i; j += 1) result.push(stmts[j]);
		}
		for (const node of expanded) {
			result.push(node);
		}
	}
	for (const node of result) {
		expandWalk(node, w, visit);
	}
	return result;
}

// ===== Tests =====

function keepStmt(stmt: Node, ctx: TransformContext): Node[] {
	return [stmt];
}

function splitStmt(stmt: Node, ctx: TransformContext): Node[] {
	return stmt.kind == NodeKind.VariableDecl ? [stmt, stmt] : [stmt];
}

test "a statement list no expander touched keeps its array" {
	const parsed = parseInput("const a = 1; const b = 2;");
	assert parsed.ok;
	const before = getStmts(parsed.value);
	walkExpandBlocks(parsed.value, keepStmt, makeCtx());
	assert getStmts(parsed.value) == before;
}

test "a statement list an expander grew is rebuilt in order" {
	const parsed = parseInput("const a = 1; f();");
	assert parsed.ok;
	const before = getStmts(parsed.value);
	walkExpandBlocks(parsed.value, splitStmt, makeCtx());
	const after = getStmts(parsed.value);
	assert after != before;
	assert after.length == 3;
	assert after[0].kind == NodeKind.VariableDecl;
	assert after[1].kind == NodeKind.VariableDecl;
	assert after[2].kind == NodeKind.ExprStmt;
}
