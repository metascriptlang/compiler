// An @iteratorHelper generator on JS closes its source when closed before its first next, as the C entry state does.

import { Node, NodeKind, SourceLocation, Symbol, SymbolKind, FunctionDeclData, BlockStmtData, DeclKind, createNode } from "../../ast/node";
import { TransformContext, newLoweredSym } from "../context";
import { walkNode } from "../walker";
import { hasFlag, SymbolFlag } from "../../checker/symbol";
import { booleanType } from "../../checker/types";
import { isGenericFn } from "../../checker/context";
import { makeIdentResolved, makeVarDecl, makeExprStmt, makeIf, makeBlock, makeReturn, makeUnary, makeCall, makeMember, makeAssign, syntheticToken } from "../util";
import { closeIterator } from "./forOfLower";

export function lowerIteratorHelpersJs(program: Node, ctx: TransformContext): Node {
	return walkNode(program, (node: Node): Node => {
		if (node.kind != NodeKind.FunctionDecl || node.resolvedSym == null || !hasFlag(node.resolvedSym, SymbolFlag.IteratorHelper)) return node;
		const d = node.data as FunctionDeclData;
		if (isGenericFn(d.fnFlags)) return node;
		const params = node.paramSyms;
		if (params == null || params.length == 0) throw new Error(`internal: iterator helper '${node.resolvedSym.name}' has no source parameter`);
		d.fnBody = startTrackedBody(d.fnBody, params[0], ctx, node.location);
		d.fnFlags = "";
		return node;
	});
}

function makeBool(value: boolean, loc: SourceLocation): Node {
	const n = createNode(NodeKind.BooleanLiteral, { boolValue: value }, syntheticToken(loc));
	n.nodeType = booleanType();
	return n;
}

function local(sym: Symbol, init: Node, kind: DeclKind, loc: SourceLocation): Node {
	const decl = makeVarDecl(sym.name, init, kind, loc);
	decl.resolvedSym = sym;
	return decl;
}

function startTrackedBody(body: Node, source: Symbol, ctx: TransformContext, loc: SourceLocation): Node {
	const started = newLoweredSym(ctx, SymbolKind.Temp, "__helper_started", booleanType(), true);
	const gen = newLoweredSym(ctx, SymbolKind.Temp, "__helper_gen", null);
	const close = newLoweredSym(ctx, SymbolKind.Temp, "__helper_close", null);
	const value = newLoweredSym(ctx, SymbolKind.Variable, "__helper_value", null);
	const markStarted = (): Node => makeExprStmt(makeAssign(makeIdentResolved(started, loc), makeBool(true, loc), loc), loc);

	const stmts = (body.data as BlockStmtData).statements;
	const genFn = createNode(NodeKind.FunctionExpr, {
		funcExprParams: [], funcExprParamTypes: [], funcExprBody: makeBlock([markStarted(), ...stmts], loc), funcExprFlags: "generator", funcExprReturnType: "",
	}, syntheticToken(loc));
	genFn.paramSyms = [];

	const closeBeforeStart = makeIf(makeUnary("!", makeIdentResolved(started, loc), loc), makeBlock([markStarted(), closeIterator(source, loc)], loc), null as unknown as Node, loc);
	const forward = makeCall(makeMember(makeIdentResolved(close, loc), "call", loc), [makeIdentResolved(gen, loc), makeIdentResolved(value, loc)], loc);
	const returnFn = createNode(NodeKind.FunctionExpr, {
		funcExprParams: [value.name], funcExprParamTypes: [""], funcExprBody: makeBlock([closeBeforeStart, makeReturn(forward, loc)], loc), funcExprFlags: "", funcExprReturnType: "",
	}, syntheticToken(loc));
	returnFn.paramSyms = [value];

	return makeBlock([
		local(started, makeBool(false, loc), DeclKind.Let, loc),
		local(gen, makeCall(genFn, [], loc), DeclKind.Const, loc),
		local(close, makeMember(makeIdentResolved(gen, loc), "return", loc), DeclKind.Const, loc),
		makeExprStmt(makeAssign(makeMember(makeIdentResolved(gen, loc), "return", loc), returnFn, loc), loc),
		makeReturn(makeIdentResolved(gen, loc), loc),
	], loc);
}
