import { Node, NodeKind, Symbol, SymbolKind, FunctionDeclData, ExportDeclData, ImportDeclData, DecoratedDeclData, ProgramData } from "../ast/node";
import { CheckerContext, addError, findModuleExports, isExtensionRoutine, isGenericFn } from "./context";
import { lookupSymbol, lookupLocal, hasFlag, SymbolFlag } from "./symbol";
import { hasGenericParams } from "./types";
import { getDeclName, resolveImportSourcePath } from "./collectPass";

export interface BundleReexport {
	name: string;
	sym: Symbol;
}

function fnFlagsOf(sym: Symbol): string {
	return sym.declNode != null && sym.declNode.kind == NodeKind.FunctionDecl ? (sym.declNode.data as FunctionDeclData).fnFlags : "";
}

function isExtensionSym(sym: Symbol): boolean {
	return isExtensionRoutine(fnFlagsOf(sym));
}

function hostFunctions(sym: Symbol): Symbol[] {
	const members: Symbol[] = [];
	const all: Symbol[] = [sym];
	for (const o of sym.overloads) all.push(o);
	for (const m of all) {
		if (m != null && !hasFlag(m, SymbolFlag.OverloadSig) && !isExtensionSym(m)) members.push(m);
	}
	return members;
}

function isGenericSym(sym: Symbol): boolean {
	return isGenericFn(fnFlagsOf(sym)) || hasGenericParams(sym.symbolType);
}

function noSingleValueReason(sym: Symbol): string {
	if (sym.symbolKind == SymbolKind.Enum) return "it is an enum, which is a type, not a value — export consts or functions that carry its members, or drop 'export'";
	if (sym.symbolKind == SymbolKind.Class && hasGenericParams(sym.symbolType)) return "it is a generic class, which compiles to one class per instance, not one value — export a non-generic class for each type a host needs, or drop 'export'";
	if (sym.symbolKind != SymbolKind.Function) return "";
	const fns = hostFunctions(sym);
	for (const f of fns) {
		if (isGenericSym(f)) return "it is a generic function, which compiles to one function per instance, not one value — export a non-generic wrapper for each type a host needs, or drop 'export'";
	}
	if (fns.length > 1) return `it is an overload set of ${fns.length} functions, and an ES export holds one value — give each function its own name, or drop 'export'`;
	return "";
}

function refuse(ctx: CheckerContext, node: Node, name: string, origin: string, reason: string): void {
	const from = origin == "" ? "" : ` (re-exported from '${origin}')`;
	addError(ctx, `the JS bundle cannot export '${name}'${from}: ${reason}`, node.location.line, node.location.column);
}

function runtimeValueOf(sym: Symbol): Symbol | null {
	if (sym.nativeName != "" || hasFlag(sym, SymbolFlag.CompileTime) || hasFlag(sym, SymbolFlag.ImportC)) return null;
	if (sym.declNode != null && sym.declNode.kind == NodeKind.ExternDecl) return null;
	if (sym.symbolKind == SymbolKind.Function) {
		const fns = hostFunctions(sym);
		return fns.length == 1 ? fns[0] : null;
	}
	return sym.symbolKind == SymbolKind.Variable || sym.symbolKind == SymbolKind.Class ? sym : null;
}

function exportDeclOf(stmt: Node): Node | null {
	const node = stmt.kind == NodeKind.DecoratedDecl ? (stmt.data as DecoratedDeclData).decoratedNode : stmt;
	return node.kind == NodeKind.ExportDecl ? node : null;
}

export function checkJsBundleExports(ctx: CheckerContext, program: Node): BundleReexport[] {
	const reexports: BundleReexport[] = [];
	const handled = new Set<string>();
	for (const stmt of (program.data as ProgramData).programStmts) {
		const exp = exportDeclOf(stmt);
		if (exp == null) continue;
		const inner = (exp.data as ExportDeclData).exportedDecl;
		if (inner.kind != NodeKind.ImportDecl) {
			const name = getDeclName(inner);
			const sym = name == "" ? null : lookupSymbol(ctx.table, name);
			if (sym == null || handled.has(name)) continue;
			handled.add(name);
			const reason = noSingleValueReason(sym);
			if (reason != "") refuse(ctx, exp, name, "", reason);
			continue;
		}
		const imp = inner.data as ImportDeclData;
		const names: string[] = [];
		if (imp.importNames.length == 1 && imp.importNames[0] == "*") {
			const origin = findModuleExports(ctx.exportRegistry, resolveImportSourcePath(ctx, imp.importSource));
			if (origin != null) { for (const info of origin.symbols) names.push(info.name); }
		} else {
			for (const alias of imp.importAliases) names.push(alias);
		}
		for (const name of names) {
			const sym = lookupLocal(ctx.table, name);
			if (sym == null || sym.modulePath == ctx.modulePath || handled.has(name)) continue;
			handled.add(name);
			const reason = noSingleValueReason(sym);
			if (reason != "") refuse(ctx, exp, name, imp.importSource, reason);
			else {
				const value = runtimeValueOf(sym);
				if (value != null) reexports.push({ name, sym: value });
			}
		}
	}
	return reexports;
}
