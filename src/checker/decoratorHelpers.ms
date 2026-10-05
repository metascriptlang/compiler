// Decorator accessor helpers — returns only primitives to avoid DRC cross-module Node lifecycle bugs.

import { Node, NodeKind, Symbol, SymbolKind, DecoratedDeclData, MacroInvocationData, StringLiteralData, FunctionDeclData, ExternDeclData, MethodDeclData, ExportDeclData, PropertyDeclData } from "../ast/node";
import { markUsedIn, CheckerContext, sgRecordSym, addError, findExportedSymbol } from "./context";
import { lookupSymbol } from "./symbol";
import { findChar } from "../utils/string";

export interface DecoratorInfo {
	builtinKind: string;
	nativeName: string;
	exportName: string;
	compilerFunc: boolean;
	throws: boolean;
	borrow: boolean;
	compileTime: boolean;
}

const passThroughDirectives: string[] = [
	"emit", "include", "compile", "link", "passC", "passL", "import",
	"comptime", "builtin", "exportName", "beforeReload", "afterReload", "inline",
];
const intrinsicBuiltins: string[] = ["nonisolated", "compilerFunc", "throws", "delegate"];

export function isBuiltinDirective(name: string): boolean {
	for (const n of passThroughDirectives) {
		if (n == name) return true;
	}
	return false;
}

export function intrinsicBuiltinOf(ctx: CheckerContext, name: string, at: Node | null = null): string {
	const sym = lookupSymbol(ctx.table, name);
	if (sym == null || sym.builtinKind == "") return "";
	for (const n of intrinsicBuiltins) {
		if (n != sym.builtinKind) continue;
		markUsedIn(ctx, sym);
		if (at != null) {
			at.resolvedSym = sym;
			const col = at.location.column + 1;
			sgRecordSym(ctx, at.location.line, col, col + name.length, sym, sym.symbolType, sym.symbolKind, name, "", false);
		}
		return sym.builtinKind;
	}
	return "";
}

export function isIntrinsicDecorator(ctx: CheckerContext, name: string, at: Node | null = null): boolean {
	if (isBuiltinDirective(name)) return true;
	return intrinsicBuiltinOf(ctx, name, at) != "";
}

export function intrinsicOnly(ctx: CheckerContext, decorators: Node[]): Node[] {
	const kept: Node[] = [];
	for (const d of decorators) {
		if (d.kind == NodeKind.MacroInvocation && !isIntrinsicDecorator(ctx, (d.data as MacroInvocationData).macroName)) continue;
		kept.push(d);
	}
	return kept;
}

function allIntrinsic(ctx: CheckerContext, decorators: Node[]): boolean {
	for (const d of decorators) {
		if (d.kind != NodeKind.MacroInvocation) return false;
		if (!isIntrinsicDecorator(ctx, (d.data as MacroInvocationData).macroName)) return false;
	}
	return true;
}

export function resolveDecoratorSymbol(ctx: CheckerContext, name: string): Symbol {
	const dot = findChar(name, ".");
	if (dot < 0) return lookupSymbol(ctx.table, name);
	const head = name.slice(0, dot);
	const rest = name.slice(dot + 1, name.length);
	const ns = lookupSymbol(ctx.table, head);
	if (ns == null || ns.symbolKind != SymbolKind.Module) return null as unknown as Symbol;
	markUsedIn(ctx, ns);
	const info = findExportedSymbol(ctx.exportRegistry, ns.modulePath, rest);
	if (info == null) return null as unknown as Symbol;
	return info.sym;
}

export function checkFieldDecoratorNames(ctx: CheckerContext, rows: Node[][]): void {
	for (const row of rows) {
		for (const dec of row) {
			const name = (dec.data as MacroInvocationData).macroName;
			const sym = resolveDecoratorSymbol(ctx, name);
			if (sym == null) {
				addError(ctx, `Cannot find name '${name}'`, dec.location.line, dec.location.column);
				continue;
			}
			if (sym.symbolKind != SymbolKind.Function && sym.symbolKind != SymbolKind.Macro) {
				addError(ctx, `'${name}' is not callable as a decorator`, dec.location.line, dec.location.column);
				continue;
			}
			markUsedIn(ctx, sym);
		}
	}
}

export function recordFieldDecorators(sym: Symbol, dd: DecoratedDeclData): void {
	const inner = dd.decoratedNode;
	if (sym == null || inner == null || inner.kind != NodeKind.PropertyDecl) return;
	const pd = inner.data as PropertyDeclData;
	if (pd.propIsStatic) return;
	for (const recorded of sym.fieldDecoratorNames) {
		if (recorded == pd.propName) return;
	}
	sym.fieldDecoratorNames.push(pd.propName);
	sym.fieldDecorators.push(dd.decorators);
}

export function stripIntrinsicMemberWrappers(ctx: CheckerContext, sym: Symbol, body: Node[]): void {
	for (let i = 0; i < body.length; i += 1) {
		const member = body[i];
		if (member.kind != NodeKind.DecoratedDecl) continue;
		const dd = member.data as DecoratedDeclData;
		if (dd.decoratedNode == null || !allIntrinsic(ctx, dd.decorators)) continue;
		recordFieldDecorators(sym, dd);
		body[i] = dd.decoratedNode;
	}
}

export function hasIntrinsicDecorator(ctx: CheckerContext, decorators: Node[], kind: string): boolean {
	for (const dec of decorators) {
		if (dec.kind != NodeKind.MacroInvocation) continue;
		if (intrinsicBuiltinOf(ctx, (dec.data as MacroInvocationData).macroName) == kind) return true;
	}
	return false;
}

export function exportNameDecorator(decorators: Node[]): Node | null {
	for (const dec of decorators) {
		if (dec.kind != NodeKind.MacroInvocation) continue;
		if ((dec.data as MacroInvocationData).macroName == "exportName") return dec;
	}
	return null;
}

export function inlineDecorator(decorators: Node[]): Node | null {
	for (const dec of decorators) {
		if (dec.kind != NodeKind.MacroInvocation) continue;
		if ((dec.data as MacroInvocationData).macroName == "inline") return dec;
	}
	return null;
}

export function reloadHandlerDecorator(decorators: Node[]): Node | null {
	for (const dec of decorators) {
		if (dec.kind != NodeKind.MacroInvocation) continue;
		const name = (dec.data as MacroInvocationData).macroName;
		if (name == "beforeReload" || name == "afterReload") return dec;
	}
	return null;
}

export function exportedFunctionOf(decorated: Node): Node | null {
	let decl = decorated;
	if (decl != null && decl.kind == NodeKind.ExportDecl) decl = (decl.data as ExportDeclData).exportedDecl;
	if (decl == null || decl.kind != NodeKind.FunctionDecl) return null;
	return decl;
}

function exportNameOf(dec: Node, decorated: Node): string {
	const md = dec.data as MacroInvocationData;
	if (md.macroArgs.length == 1 && md.macroArgs[0].kind == NodeKind.StringLiteral) {
		return (md.macroArgs[0].data as StringLiteralData).value;
	}
	if (md.macroArgs.length > 0) return "";
	const fn = exportedFunctionOf(decorated);
	if (fn == null) return "";
	return (fn.data as FunctionDeclData).fnName;
}

// Extract all decorator metadata from a DecoratedDecl node as primitives.
export function extractDecoratorInfo(node: Node): DecoratorInfo {
	const dd = node.data as DecoratedDeclData;
	let btKind = "";
	for (let i = 0; i < dd.decorators.length; i += 1) {
		const dec = dd.decorators[i];
		if (dec.kind == NodeKind.MacroInvocation) {
			const md = dec.data as MacroInvocationData;
			if (md.macroName == "builtin" && md.macroArgs.length > 0) {
				const arg = md.macroArgs[0];
				if (arg.kind == NodeKind.StringLiteral) {
					btKind = (arg.data as StringLiteralData).value;
				}
			}
		}
	}
	let isCompilerFunc = false;
	let canThrow = false;
	let borrows = false;
	let atCompileTime = false;
	for (let i = 0; i < dd.decorators.length; i += 1) {
		const dec = dd.decorators[i];
		if (dec.kind != NodeKind.MacroInvocation) continue;
		const name = (dec.data as MacroInvocationData).macroName;
		if (name == "compilerFunc") isCompilerFunc = true;
		if (name == "throws") canThrow = true;
		if (name == "delegate") borrows = true;
		if (name == "comptime") atCompileTime = true;
	}
	const exportDec = exportNameDecorator(dd.decorators);
	const exportName = exportDec != null ? exportNameOf(exportDec, dd.decoratedNode) : "";
	// Extract nativeName from inner decorated node (from "c_name" clause)
	const inner = dd.decoratedNode;
	let natName = match (inner.kind) {
		NodeKind.FunctionDecl => (inner.data as FunctionDeclData).nativeName,
		NodeKind.ExternDecl => (inner.data as ExternDeclData).nativeName,
		NodeKind.MethodDecl => (inner.data as MethodDeclData).nativeName,
		_ => "",
	};
	if (natName == null) natName = "";
	return {
		builtinKind: btKind,
		nativeName: natName,
		exportName: exportName,
		compilerFunc: isCompilerFunc,
		throws: canThrow,
		borrow: borrows,
		compileTime: atCompileTime,
	};
}
