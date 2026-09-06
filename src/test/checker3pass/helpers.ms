// 3-pass Checker Isolation Test Helpers
//
// Goal: test Pass 3 (check) outputs DIRECTLY, without depending on transform,
// lambda lifting, monomorphize, codegen. Each helper stops after Pass 3 +
// optional validateTypedAST, returns the post-check AST + ctx so scenarios
// can navigate to specific nodes and assert their `nodeType`.
//
// Invariant under test:
//   After Pass 3, `node.nodeType` MUST NOT contain `TypeKind.GenericParam`
//   anywhere — EXCEPT inside template (uninstantiated generic) decls, where
//   GenericParam is the legitimate parametric placeholder.
//
// Vi phạm = silent corruption that downstream passes (lambda lifting, mono,
// codegen) silently propagate, surfacing as link errors much later.

import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { resetAllSideChannels } from "../../parser/context";
import { checkProgramWithRegistry } from "../../checker/checkPass";
import { checkModuleGraph, getPreludeContext } from "../../checker/orchestrator";
import { CheckerContext, Severity } from "../../checker/context";
import { validateTypedAST } from "../../checker/validate";
import { Node, NodeKind, ProgramData, FunctionDeclData, MethodDeclData, ClassDeclData, ArrowFunctionData, FunctionExprData, CallExprData, IdentifierData, BlockStmtData, VariableDeclData, ExprStmtData, ReturnStmtData, IfStmtData, WhileStmtData, BinaryExprData, MemberExprData, NewExprData } from "../../ast/node";
import { createMapProvider, loadModuleGraph, canonicalModulePath, MapEntry } from "../../module/loader";
import { findModule } from "../../module/graph";

export interface CheckResult {
	program: Node;
	ctx: CheckerContext;
	errors: string[];
}

// Stops after Pass 3. No monomorphize, no transform, no codegen — keeps
// the post-check AST intact so scenarios can inspect nodeType directly.
export function checkOnly(source: string): CheckResult {
	resetAllSideChannels();
	const modPath = canonicalModulePath("test/checker3pass.ms");
	const entries: MapEntry[] = [{ entryPath: modPath, entrySource: source }];
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph(modPath, provider);
	const registry = checkModuleGraph(graph, "");
	const preludeCtx = getPreludeContext();

	const mod = findModule(graph, modPath);
	if (mod == null) {
		return { program: null as unknown as Node, ctx: null as unknown as CheckerContext, errors: ["module not found"] };
	}

	const pr = parseSource(mod.source);
	if (!pr.ok) {
		return { program: null as unknown as Node, ctx: null as unknown as CheckerContext, errors: ["parse: " + pr.error] };
	}

	const ctx = checkProgramWithRegistry(pr.value, registry, graph, mod, preludeCtx);

	const errMsgs: string[] = [];
	for (const err of ctx.errors) {
		if (err.severity == Severity.Error) {
			errMsgs.push(err.message);
		}
	}

	return { program: pr.value, ctx, errors: errMsgs };
}

// ===== AST navigation helpers =====

export function findFirstArrow(program: Node): Node {
	return findFirstByKind(program, NodeKind.ArrowFunction);
}

export function findFirstFuncExpr(program: Node): Node {
	return findFirstByKind(program, NodeKind.FunctionExpr);
}

export function findFnDecl(program: Node, name: string): Node {
	if (program == null || program.kind != NodeKind.Program) return null as unknown as Node;
	const pd = program.data as ProgramData;
	for (const stmt of pd.programStmts) {
		if (stmt.kind == NodeKind.FunctionDecl) {
			const fd = stmt.data as FunctionDeclData;
			if (fd.fnName == name) return stmt;
		}
	}
	return null as unknown as Node;
}

// Locates `applyN<int32>(...)` style calls in nested contexts via substring match.
export function findCallByCalleeContains(program: Node, calleeFragment: string): Node {
	return findCallExprWalk(program, calleeFragment);
}

export function findFirstByKind(root: Node, kind: NodeKind): Node {
	if (root == null) return null as unknown as Node;
	if (root.kind == kind) return root;
	let found: Node = null as unknown as Node;
	walkChildren(root, (child: Node): boolean => {
		const inner = findFirstByKind(child, kind);
		if (inner != null) { found = inner; return true; }
		return false;
	});
	return found;
}

// ===== Private helpers =====

function findCallExprWalk(root: Node, calleeFragment: string): Node {
	if (root == null) return null as unknown as Node;
	if (root.kind == NodeKind.CallExpr) {
		const cd = root.data as CallExprData;
		if (cd.callee != null && cd.callee.kind == NodeKind.Identifier) {
			const id = cd.callee.data as IdentifierData;
			if (id.name.indexOf(calleeFragment) >= 0) return root;
		}
	}
	let found: Node = null as unknown as Node;
	walkChildren(root, (child: Node): boolean => {
		const inner = findCallExprWalk(child, calleeFragment);
		if (inner != null) { found = inner; return true; }
		return false;
	});
	return found;
}

// Per-NodeKind child walker. Visits only the structural slots needed for
// invariant checking and navigation. Callback returns `true` to
// short-circuit (used by `findFirstByKind` / `findCallExprWalk`).
function walkChildren(node: Node, cb: (child: Node) => boolean): void {
	if (node == null) return;
	match (node.kind) {
		NodeKind.Program => {
			const d = node.data as ProgramData;
			for (const s of d.programStmts) { if (cb(s)) return; }
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			for (const s of d.statements) { if (cb(s)) return; }
		},
		NodeKind.FunctionDecl => {
			const d = node.data as FunctionDeclData;
			if (d.fnBody != null && cb(d.fnBody)) return;
		},
		NodeKind.MethodDecl => {
			const d = node.data as MethodDeclData;
			if (d.methodBody != null && cb(d.methodBody)) return;
		},
		NodeKind.ClassDecl => {
			const d = node.data as ClassDeclData;
			for (const m of d.classBody) { if (cb(m)) return; }
		},
		NodeKind.ArrowFunction => {
			const d = node.data as ArrowFunctionData;
			if (d.arrowBody != null && cb(d.arrowBody)) return;
		},
		NodeKind.FunctionExpr => {
			const d = node.data as FunctionExprData;
			if (d.funcExprBody != null && cb(d.funcExprBody)) return;
		},
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			if (d.initializer != null && cb(d.initializer)) return;
		},
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			if (d.callee != null && cb(d.callee)) return;
			for (const a of d.arguments) { if (cb(a)) return; }
		},
		NodeKind.NewExpr => {
			const d = node.data as NewExprData;
			if (d.newCallee != null && cb(d.newCallee)) return;
			for (const a of d.newArguments) { if (cb(a)) return; }
		},
		NodeKind.MemberExpr => {
			const d = node.data as MemberExprData;
			if (d.object != null && cb(d.object)) return;
		},
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			if (d.left != null && cb(d.left)) return;
			if (d.right != null && cb(d.right)) return;
		},
		NodeKind.ExprStmt => {
			const d = node.data as ExprStmtData;
			if (d.expr != null && cb(d.expr)) return;
		},
		NodeKind.ReturnStmt => {
			const d = node.data as ReturnStmtData;
			if (d.argument != null && cb(d.argument)) return;
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			if (d.condition != null && cb(d.condition)) return;
			if (d.consequent != null && cb(d.consequent)) return;
			if (d.alternate != null && cb(d.alternate)) return;
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			if (d.whileCondition != null && cb(d.whileCondition)) return;
			if (d.whileBody != null && cb(d.whileBody)) return;
		},
		_ => {},
	};
}

export function walkChildrenForCheck(node: Node, cb: (child: Node) => boolean): void {
	walkChildren(node, cb);
}
