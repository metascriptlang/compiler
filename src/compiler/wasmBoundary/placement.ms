import {
	Node,
	NodeKind,
	ProgramData,
	DecoratedDeclData,
	FunctionDeclData,
	CallExprData,
	SymbolFlag,
	SymbolKind,
} from "../../ast/node";
import { exportedFunctionOf } from "../../checker/decoratorHelpers";
import { hasFlag, makeSymbol } from "../../checker/symbol";
import { makeTypedIdentResolved } from "../../transform/util";

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
