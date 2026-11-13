import {
	Node,
	NodeKind,
	ProgramData,
	DecoratedDeclData,
	FunctionDeclData,
	CallExprData,
	ExprStmtData,
	BlockStmtData,
	SymbolFlag,
	SymbolKind,
} from "../../ast/node";
import { exportedFunctionOf } from "../../checker/decoratorHelpers";
import { hasFlag, makeSymbol } from "../../checker/symbol";
import { makeTypedIdentResolved } from "../../transform/util";

export function wasmFunctionOf(stmt: Node): Node | null {
	let decl = stmt;
	if (decl.kind == NodeKind.DecoratedDecl) {
		decl = (decl.data as DecoratedDeclData).decoratedNode;
	}
	if (decl == null || decl.kind != NodeKind.ExportDecl) return null;
	const fn = exportedFunctionOf(decl);
	if (fn == null || fn.resolvedSym == null) return null;
	if (!hasFlag(fn.resolvedSym!, SymbolFlag.Wasm)) return null;
	return fn;
}

export function wasmFunctionNames(program: Node): string[] {
	const names: string[] = [];
	if (program == null || program.kind != NodeKind.Program) return names;
	for (const stmt of (program.data as ProgramData).programStmts) {
		const fn = wasmFunctionOf(stmt);
		if (fn != null) names.push((fn.data as FunctionDeclData).fnName);
	}
	return names;
}

export function withoutWasmFunctions(program: Node): Node {
	const pd = program.data as ProgramData;
	const kept: Node[] = [];
	for (const stmt of pd.programStmts) {
		if (wasmFunctionOf(stmt) == null) kept.push(stmt);
	}
	pd.programStmts = kept;
	return program;
}

export function withoutJsSideCode(program: Node): Node {
	const pd = program.data as ProgramData;
	pd.programStmts = pd.programStmts.filter((stmt) => !isJsSideCode(stmt));
	return program;
}

function isJsSideCode(stmt: Node): boolean {
	return match (stmt.kind) {
		NodeKind.ExprStmt => (stmt.data as ExprStmtData).expr.kind != NodeKind.MacroInvocation,
		NodeKind.BlockStmt => (stmt.data as BlockStmtData).statements.every(isBlockSideCode),
		NodeKind.IfStmt | NodeKind.WhileStmt | NodeKind.DoWhileStmt | NodeKind.ForStmt | NodeKind.ForOfStmt
			| NodeKind.ForInStmt | NodeKind.SwitchStmt | NodeKind.MatchStmt | NodeKind.TryCatchStmt
			| NodeKind.ThrowStmt | NodeKind.AssertStmt | NodeKind.DeferStmt => true,
		_ => false,
	};
}

function isBlockSideCode(stmt: Node): boolean {
	return stmt.kind == NodeKind.VariableDecl
		|| stmt.kind == NodeKind.DestructuringDecl
		|| isJsSideCode(stmt);
}

export function callsWasmWrapper(site: Node, pattern: string, args: Node[]): void {
	const sym = makeSymbol(pattern, SymbolKind.Function, null, false);
	sym.nativeName = pattern;
	const callee = makeTypedIdentResolved(sym, null, site.location);
	const made = site.nodeType;
	const call: CallExprData = {
		callee,
		arguments: args,
		isDirectCall: true,
		resolvedOverloadIdx: -1,
	};
	site.kind = NodeKind.CallExpr;
	site.data = call;
	site.resolvedSym = sym;
	site.nodeType = made;
}

import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";

test "the wasm half keeps a user module's declarations and directives, not its top-level code or blocks" {
	const parsed = parseSource([
		"console.log(\"once\");",
		"let n: int32 = 1;",
		"if (n > 0) { n = 2; }",
		"for (const x of [1]) n += x;",
		"{ n = 3; }",
		"{ let inner: int32 = 4; }",
		"@emit(\"int keptByC;\");",
		"export function f(): int32 { return n; }",
	].join("\n"));
	if (!parsed.ok) throw new Error(parsed.error);
	const kept = (withoutJsSideCode(parsed.value).data as ProgramData).programStmts.map((s) => s.kind);
	assert kept.length == 3;
	assert kept[0] == NodeKind.VariableDecl;
	assert kept[1] == NodeKind.ExprStmt;
	assert kept[2] == NodeKind.ExportDecl;
}
