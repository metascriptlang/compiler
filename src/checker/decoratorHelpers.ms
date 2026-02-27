// Decorator accessor helpers — returns only primitives to avoid DRC cross-module Node lifecycle bugs.

import { Node, NodeKind, DecoratedDeclData, MacroInvocationData, StringLiteralData } from "../ast/node";

export interface DecoratorInfo {
	runtimeName: string;
	builtinKind: string;
}

// Extract all decorator metadata from a DecoratedDecl node as primitives.
export function extractDecoratorInfo(node: Node): DecoratorInfo {
	const dd = node.data as DecoratedDeclData;
	let rtName = "";
	let btKind = "";
	let i = 0;
	while (i < dd.decorators.length) {
		const dec = dd.decorators[i];
		if (dec.kind === NodeKind.MacroInvocation) {
			const md = dec.data as MacroInvocationData;
			if (md.macroName === "runtime" && md.macroArgs.length > 0) {
				const arg = md.macroArgs[0];
				if (arg.kind === NodeKind.StringLiteral) {
					rtName = (arg.data as StringLiteralData).value;
				}
			} else if (md.macroName === "builtin" && md.macroArgs.length > 0) {
				const arg = md.macroArgs[0];
				if (arg.kind === NodeKind.StringLiteral) {
					btKind = (arg.data as StringLiteralData).value;
				}
			}
		}
		i += 1;
	}
	return { runtimeName: rtName, builtinKind: btKind };
}