// Decorator accessor helpers — returns only primitives to avoid DRC cross-module Node lifecycle bugs.

import { Node, NodeKind, DecoratedDeclData, MacroInvocationData, StringLiteralData } from "../ast/node";

export interface DecoratorInfo {
	builtinKind: string;
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
	return { builtinKind: btKind };
}
