import {
	Node,
	NodeKind,
	ProgramData,
	DecoratedDeclData,
	FunctionDeclData,
	CallExprData,
	ExprStmtData,
	BlockStmtData,
	ExportDeclData,
	VariableDeclData,
	Symbol,
	SymbolFlag,
	SymbolKind,
} from "../../ast/node";
import { exportedFunctionOf } from "../../checker/decoratorHelpers";
import { hasFlag, makeSymbol } from "../../checker/symbol";
import { makeTypedIdentResolved } from "../../transform/util";
import { forEachChild } from "../../ast/visitor";

function wasmFunctionOf(stmt: Node): Node | null {
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
		NodeKind.BlockStmt => (stmt.data as BlockStmtData).statements.every(isJsSideCode),
		NodeKind.IfStmt | NodeKind.WhileStmt | NodeKind.DoWhileStmt | NodeKind.ForStmt | NodeKind.ForOfStmt
			| NodeKind.ForInStmt | NodeKind.SwitchStmt | NodeKind.MatchStmt | NodeKind.TryCatchStmt
			| NodeKind.ThrowStmt | NodeKind.AssertStmt | NodeKind.DeferStmt => true,
		_ => false,
	};
}

function moduleVarOf(stmt: Node): Node | null {
	const decl = stmt.kind == NodeKind.ExportDecl ? (stmt.data as ExportDeclData).exportedDecl : stmt;
	return decl != null && decl.kind == NodeKind.VariableDecl && decl.resolvedSym != null ? decl : null;
}

// Returns the variables whose initializer it dropped, for the check that nothing reaches them.
export function withoutUnreadInitializers(owners: Node[], readers: Node[]): Symbol[] {
	const decls = new HashMap<Symbol, Node>();
	for (const program of owners) {
		for (const stmt of (program.data as ProgramData).programStmts) {
			const decl = moduleVarOf(stmt);
			if (decl != null && (decl.data as VariableDeclData).initializer != null) decls.set(decl.resolvedSym!, decl);
		}
	}
	const read = new HashSet<Symbol>();
	const pending: Node[] = [];
	const visit = (node: Node): void => {
		const sym = node.resolvedSym;
		if (node.kind == NodeKind.Identifier && sym != null && decls.has(sym) && !read.has(sym)) {
			read.add(sym);
			pending.push(decls.get(sym)!);
		}
		forEachChild(node, visit);
	};
	for (const program of readers) {
		for (const stmt of (program.data as ProgramData).programStmts) {
			const decl = moduleVarOf(stmt);
			if (decl == null || !decls.has(decl.resolvedSym!)) visit(stmt);
		}
	}
	while (pending.length > 0) visit((pending.pop().data as VariableDeclData).initializer!);
	const dropped: Symbol[] = [];
	for (const program of owners) {
		for (const stmt of (program.data as ProgramData).programStmts) {
			const decl = moduleVarOf(stmt);
			if (decl == null || !decls.has(decl.resolvedSym!) || read.has(decl.resolvedSym!)) continue;
			(decl.data as VariableDeclData).initializer = null as unknown as Node;
			dropped.push(decl.resolvedSym!);
		}
	}
	return dropped;
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

test "the wasm half keeps a user module's declarations and directives, not its top-level code" {
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
	assert kept.length == 4;
	assert kept[0] == NodeKind.VariableDecl;
	assert kept[1] == NodeKind.BlockStmt;
	assert kept[2] == NodeKind.ExprStmt;
	assert kept[3] == NodeKind.ExportDecl;
}

test "the wasm half initializes a module variable only when the code it keeps reads it" {
	const parsed = parseSource([
		"let a: int32 = 1;",
		"let b: int32 = a;",
		"let c: int32 = 3;",
		"let d: int32 = c;",
		"export function f(): int32 { return b; }",
	].join("\n"));
	if (!parsed.ok) throw new Error(parsed.error);
	const program = parsed.value;
	const stmts = (program.data as ProgramData).programStmts;
	const syms: Symbol[] = [];
	for (const name of ["a", "b", "c", "d"]) syms.push(makeSymbol(name, SymbolKind.Variable, null, false));
	for (let i = 0; i < 4; i += 1) stmts[i].resolvedSym = syms[i];
	const reads = (stmt: Node, sym: Symbol): void => {
		const visit = (n: Node): void => {
			if (n.kind == NodeKind.Identifier) n.resolvedSym = sym;
			forEachChild(n, visit);
		};
		visit(stmt);
	};
	reads((stmts[1].data as VariableDeclData).initializer!, syms[0]);
	reads((stmts[3].data as VariableDeclData).initializer!, syms[2]);
	reads(stmts[4], syms[1]);
	const dropped = withoutUnreadInitializers([program], [program]).map((s) => s.name);
	assert dropped.length == 2;
	assert dropped.includes("c");
	assert dropped.includes("d");
	assert (stmts[0].data as VariableDeclData).initializer != null;
	assert (stmts[3].data as VariableDeclData).initializer == null;
}
