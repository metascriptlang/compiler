// Rest parameter lowering (reference parity: varargs call-site array packing)
//
// Rest-ness is encoded type-level by createFunction (TypeKind.Varargs wraps the
// last param's array type). This pass packs excess call-site args into an
// ArrayLiteral when the callee's last param is Varargs.
//
// Example:
//   function f(a: string, ...rest: string[]) {}
//   f("hello", "a", "b", "c");
// Lowered to:
//   f("hello", ["a", "b", "c"]);

import {
	Node, NodeKind, NodeData, Type, TypeKind,
	CallExprData, IdentifierData,
	createNode,
} from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { createToken, TokenKind } from "../../lexer/token";
import { lookupSymbol } from "../../checker/symbol";

// Holds the active ctx for the current walk. Closure over `ctx` would be
// cleaner but walkNode's visitor signature is fixed to (node) => node.
let activeCtx: TransformContext | null = null;

export function lowerRestParams(program: Node, ctx: TransformContext): Node {
	activeCtx = ctx;
	walkNode(program, lowerRest);
	activeCtx = null;
	return program;
}

function makeArrayLit(elements: Node[], restType: Type, line: number): Node {
	const arr = createNode(NodeKind.ArrayLiteral,
		{ elements } as unknown as NodeData,
		createToken(TokenKind.LBracket, "[", line));
	if (restType !== null) arr.nodeType = restType;
	return arr;
}

function lowerRest(node: Node): Node {
	if (node.kind !== NodeKind.CallExpr) return node;

	const d = node.data as CallExprData;
	const callee = d.callee;
	if (callee === null) return node;
	let sym = callee.resolvedSym;
	// Synthetic calls inserted by earlier transforms (stringConcatFlatten,
	// nativeLower) emit bare Identifier callees with no resolvedSym. Look the
	// name up in the global symbol table so varargs packing still applies.
	if (sym === null && callee.kind === NodeKind.Identifier
		&& activeCtx !== null && activeCtx.checkerCtx !== null) {
		const id = callee.data as IdentifierData;
		const found = lookupSymbol(activeCtx.checkerCtx.table, id.name);
		if (found !== null) {
			sym = found;
			callee.resolvedSym = found;
		}
	}
	if (sym === null) return node;
	if (sym.symbolType === null || sym.symbolType.kind !== TypeKind.Function) return node;

	const typeChildren = sym.symbolType.typeChildren;
	if (typeChildren.length === 0) return node;
	const lastType = typeChildren[typeChildren.length - 1];
	if (lastType === null || lastType.kind !== TypeKind.Varargs) return node;

	// Method calls keep `this` as typeChildren[0] but the call-site arguments
	// don't include the receiver (it lives in callee.MemberExpr.object). Skip
	// that slot when computing rest position so d.arguments-relative indexing
	// stays aligned. Static extension calls (`Math.floor(x)`) and free function
	// calls keep their natural alignment.
	const typeNames = sym.symbolType.typeNames;
	const hasThisSlot = typeNames.length > 0 && typeNames[0] === "this"
		&& callee.kind === NodeKind.MemberExpr;
	const restIdx = (typeChildren.length - 1) - (hasThisSlot ? 1 : 0);

	// Peel Varargs → user's array type (e.g. string[]) for the ArrayLiteral.
	const restType = lastType.typeChildren.length > 0
		? lastType.typeChildren[0]
		: null as unknown as Type;

	// No excess args — insert empty array for the rest param
	if (d.arguments.length <= restIdx) {
		d.arguments.push(makeArrayLit([], restType, node.location.line));
		return node;
	}

	// Split args: regular (before restIdx) + rest (at/after restIdx)
	const regularArgs: Node[] = [];
	const restArgs: Node[] = [];
	let j = 0;
	while (j < d.arguments.length) {
		if (j < restIdx) {
			regularArgs.push(d.arguments[j]);
		} else {
			restArgs.push(d.arguments[j]);
		}
		j = j + 1;
	}

	regularArgs.push(makeArrayLit(restArgs, restType, node.location.line));
	d.arguments = regularArgs;

	return node;
}
