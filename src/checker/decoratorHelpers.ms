// Decorator accessor helpers — returns only primitives to avoid DRC cross-module Node lifecycle bugs.

import { Node, NodeKind, DecoratedDeclData, MacroInvocationData, StringLiteralData, FunctionDeclData, ExternDeclData, MethodDeclData } from "../ast/node";

export interface DecoratorInfo {
	builtinKind: string;
	nativeName: string;
}

// Extract all decorator metadata from a DecoratedDecl node as primitives.
export function extractDecoratorInfo(node: Node): DecoratorInfo {
	const dd = node.data as DecoratedDeclData;
	let btKind = "";
	for (let i = 0; i < dd.decorators.length; i += 1) {
		const dec = dd.decorators[i];
		if (dec.kind === NodeKind.MacroInvocation) {
			const md = dec.data as MacroInvocationData;
			if (md.macroName === "builtin" && md.macroArgs.length > 0) {
				const arg = md.macroArgs[0];
				if (arg.kind === NodeKind.StringLiteral) {
					btKind = (arg.data as StringLiteralData).value;
				}
			} else if (md.macroName === "pure") {
				btKind = "pure";
			}
		}
	}
	// Extract nativeName from inner decorated node (from "c_name" clause)
	let natName = "";
	const inner = dd.decoratedNode;
	if (inner.kind === NodeKind.FunctionDecl) {
		natName = (inner.data as FunctionDeclData).nativeName;
	} else if (inner.kind === NodeKind.ExternDecl) {
		natName = (inner.data as ExternDeclData).nativeName;
	} else if (inner.kind === NodeKind.MethodDecl) {
		natName = (inner.data as MethodDeclData).nativeName;
	}
	if (natName === null) natName = "";
	return { builtinKind: btKind, nativeName: natName };
}
