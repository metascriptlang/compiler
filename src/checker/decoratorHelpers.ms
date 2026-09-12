// Decorator accessor helpers — returns only primitives to avoid DRC cross-module Node lifecycle bugs.

import { Node, NodeKind, DecoratedDeclData, MacroInvocationData, StringLiteralData, FunctionDeclData, ExternDeclData, MethodDeclData } from "../ast/node";

export interface DecoratorInfo {
	builtinKind: string;
	nativeName: string;
	nonisolated: boolean;
}

const passThroughDirectives: string[] = [
	"emit", "include", "compile", "link", "passC", "passL", "import",
	"comptime", "builtin",
];
const intrinsicDecorators: string[] = ["nonisolated"];

export function isBuiltinDirective(name: string): boolean {
	for (const n of passThroughDirectives) {
		if (n == name) return true;
	}
	return false;
}

export function isIntrinsicDecorator(name: string): boolean {
	if (isBuiltinDirective(name)) return true;
	for (const n of intrinsicDecorators) {
		if (n == name) return true;
	}
	return false;
}

export function intrinsicOnly(decorators: Node[]): Node[] {
	const kept: Node[] = [];
	for (const d of decorators) {
		if (d.kind == NodeKind.MacroInvocation && !isIntrinsicDecorator((d.data as MacroInvocationData).macroName)) continue;
		kept.push(d);
	}
	return kept;
}

function allIntrinsic(decorators: Node[]): boolean {
	for (const d of decorators) {
		if (d.kind != NodeKind.MacroInvocation) return false;
		if (!isIntrinsicDecorator((d.data as MacroInvocationData).macroName)) return false;
	}
	return true;
}

export function stripIntrinsicMemberWrappers(body: Node[]): void {
	for (let i = 0; i < body.length; i += 1) {
		const member = body[i];
		if (member.kind != NodeKind.DecoratedDecl) continue;
		const dd = member.data as DecoratedDeclData;
		if (dd.decoratedNode == null || !allIntrinsic(dd.decorators)) continue;
		body[i] = dd.decoratedNode;
	}
}

// Extract all decorator metadata from a DecoratedDecl node as primitives.
export function hasDecoratorNamed(decorators: Node[], name: string): boolean {
	for (const dec of decorators) {
		if (dec.kind == NodeKind.MacroInvocation && (dec.data as MacroInvocationData).macroName == name) return true;
	}
	return false;
}

export function extractDecoratorInfo(node: Node): DecoratorInfo {
	const dd = node.data as DecoratedDeclData;
	let btKind = "";
	let hasNonisolated = false;
	for (let i = 0; i < dd.decorators.length; i += 1) {
		const dec = dd.decorators[i];
		if (dec.kind == NodeKind.MacroInvocation) {
			const md = dec.data as MacroInvocationData;
			if (md.macroName == "builtin" && md.macroArgs.length > 0) {
				const arg = md.macroArgs[0];
				if (arg.kind == NodeKind.StringLiteral) {
					btKind = (arg.data as StringLiteralData).value;
				}
			} else if (md.macroName == "nonisolated") {
				hasNonisolated = true;
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
		nonisolated: hasNonisolated,
	};
}
