// Decorator accessor helpers — returns only primitives to avoid DRC cross-module Node lifecycle bugs.

import { Node, NodeKind, TypeFlag, DecoratedDeclData, MacroInvocationData, StringLiteralData, FunctionDeclData, ExternDeclData, MethodDeclData } from "../ast/node";

export interface DecoratorInfo {
	builtinKind: string;
	nativeName: string;
	nonisolated: boolean;
	// REPROMISE T2 Stage C: awaitable annotation.
	// 0 = not annotated. Non-zero = annotated, with these TypeFlag bits to set on
	// every GenericInstance of this type's name. Uses AwaitableAffine (64) +
	// AwaitableScopeBound (128). The two shipping decorators:
	//   @awaitable        → awaitableFlags = 0  + isAwaitableAnnotated = true
	//   @affineAwaitable  → awaitableFlags = AwaitableAffine | AwaitableScopeBound (192)
	awaitableFlags: int32;
	isAwaitableAnnotated: boolean;
}

// Extract all decorator metadata from a DecoratedDecl node as primitives.
export function extractDecoratorInfo(node: Node): DecoratorInfo {
	const dd = node.data as DecoratedDeclData;
	let btKind = "";
	let hasNonisolated = false;
	let awFlags: int32 = 0;
	let awAnnotated = false;
	for (let i = 0; i < dd.decorators.length; i += 1) {
		const dec = dd.decorators[i];
		if (dec.kind == NodeKind.MacroInvocation) {
			const md = dec.data as MacroInvocationData;
			if (md.macroName == "builtin" && md.macroArgs.length > 0) {
				const arg = md.macroArgs[0];
				if (arg.kind == NodeKind.StringLiteral) {
					btKind = (arg.data as StringLiteralData).value;
				}
			} else if (md.macroName == "pure") {
				btKind = "pure";
			} else if (md.macroName == "nonisolated") {
				hasNonisolated = true;
			} else if (md.macroName == "awaitable") {
				awAnnotated = true;
				// Plain @awaitable — non-affine, like Promise. No flag bits.
			} else if (md.macroName == "affineAwaitable") {
				awAnnotated = true;
				// Affine + scope-bound, like spawn-origin Promise. Both bits.
				awFlags = (TypeFlag.AwaitableAffine | TypeFlag.AwaitableScopeBound) as int32;
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
		awaitableFlags: awFlags,
		isAwaitableAnnotated: awAnnotated,
	};
}
