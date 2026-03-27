// Rest parameter lowering (Nim parity: varargs call-site array packing)
//
// 1. FunctionDecl: strip "..." prefix from rest param name ("...args" → "args")
// 2. CallExpr: pack excess args into ArrayLiteral for rest param
//
// Example:
//   function f(a: string, ...rest: string[]) {}
//   f("hello", "a", "b", "c");
// Lowered to:
//   function f(a: string, rest: string[]) {}
//   f("hello", ["a", "b", "c"]);

import {
	Node, NodeKind, NodeData, TypeKind,
	FunctionDeclData, MethodDeclData, CallExprData,
	createNode,
} from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { createToken, TokenKind } from "../../lexer/token";

export function lowerRestParams(program: Node, ctx: TransformContext): Node {
	walkNode(program, lowerRest);
	return program;
}

function isRestParam(name: string): boolean {
	return name.length > 3 && name.slice(0, 3) === "...";
}

function stripRestPrefix(name: string): string {
	if (isRestParam(name)) return name.slice(3, name.length);
	return name;
}

// Strip "..." from all rest params in a param list (shared by FunctionDecl + MethodDecl)
function stripRestFromParams(params: string[]): void {
	let i = 0;
	while (i < params.length) {
		if (isRestParam(params[i])) {
			params[i] = stripRestPrefix(params[i]);
		}
		i = i + 1;
	}
}

// Build an ArrayLiteral node from a list of element nodes
function makeArrayLit(elements: Node[], restType: import("../../ast/node").Type, line: number): Node {
	const arr = createNode(NodeKind.ArrayLiteral,
		{ elements } as unknown as NodeData,
		createToken(TokenKind.LBracket, "[", line));
	if (restType !== null) arr.nodeType = restType;
	return arr;
}

function lowerRest(node: Node): Node {
	// P9: DRY — shared helper for FunctionDecl and MethodDecl
	match (node.kind) {
		NodeKind.FunctionDecl => {
			const fd = node.data as FunctionDeclData;
			if (fd.params !== null) stripRestFromParams(fd.params);
		},
		NodeKind.MethodDecl => {
			const md = node.data as MethodDeclData;
			if (md.methodParams !== null) stripRestFromParams(md.methodParams);
		},
		_ => {},
	};

	if (node.kind !== NodeKind.CallExpr) return node;

	const d = node.data as CallExprData;
	const callee = d.callee;
	if (callee === null || callee.resolvedSym === null) return node;
	const sym = callee.resolvedSym;
	if (sym.symbolType === null || sym.symbolType.kind !== TypeKind.Function) return node;

	const typeNames = sym.symbolType.typeNames;
	if (typeNames.length === 0) return node;
	if (!isRestParam(typeNames[typeNames.length - 1])) return node;

	const restIdx = typeNames.length - 1;
	const restType = restIdx < sym.symbolType.typeChildren.length
		? sym.symbolType.typeChildren[restIdx]
		: null as unknown as import("../../ast/node").Type;

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
