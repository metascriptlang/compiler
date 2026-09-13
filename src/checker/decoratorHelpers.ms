// Decorator accessor helpers — returns only primitives to avoid DRC cross-module Node lifecycle bugs.

import { Node, NodeKind, DecoratedDeclData, MacroInvocationData, StringLiteralData, FunctionDeclData, ExternDeclData, MethodDeclData } from "../ast/node";
import { CheckerContext } from "./context";
import { lookupSymbol, markUsed } from "./symbol";

export interface DecoratorInfo {
	builtinKind: string;
	nativeName: string;
}

const passThroughDirectives: string[] = [
	"emit", "include", "compile", "link", "passC", "passL", "import",
	"comptime", "builtin",
];
const intrinsicBuiltins: string[] = ["nonisolated"];

export function isBuiltinDirective(name: string): boolean {
	for (const n of passThroughDirectives) {
		if (n == name) return true;
	}
	return false;
}

export function intrinsicBuiltinOf(ctx: CheckerContext, name: string): string {
	const sym = lookupSymbol(ctx.table, name);
	if (sym == null || sym.builtinKind == "") return "";
	for (const n of intrinsicBuiltins) {
		if (n != sym.builtinKind) continue;
		markUsed(sym);
		return sym.builtinKind;
	}
	return "";
}

export function isIntrinsicDecorator(ctx: CheckerContext, name: string): boolean {
	if (isBuiltinDirective(name)) return true;
	return intrinsicBuiltinOf(ctx, name) != "";
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

export function stripIntrinsicMemberWrappers(ctx: CheckerContext, body: Node[]): void {
	for (let i = 0; i < body.length; i += 1) {
		const member = body[i];
		if (member.kind != NodeKind.DecoratedDecl) continue;
		const dd = member.data as DecoratedDeclData;
		if (dd.decoratedNode == null || !allIntrinsic(ctx, dd.decorators)) continue;
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
	};
}
