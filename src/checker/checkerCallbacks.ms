// Checker Callbacks — breaks circular dependency between checkExpr.ms and checkPass.ms
// Same pattern as parser/statements/callbacks.ms.

import { Node, Type, Symbol } from "../ast/node";
import { CheckerContext } from "./context";
import { SourceLocation } from "../ast/node";

type ExprCheckerFn = (ctx: CheckerContext, node: Node, expectedType: Type | null) => void;
type StmtCheckerFn = (ctx: CheckerContext, node: Node) => void;
type BodyCheckerFn = (ctx: CheckerContext, sym: Symbol, params: string[], body: Node, paramLocs: SourceLocation[]) => void;
type InstantiateGenericFn = (sym: Symbol, paramNames: string[], concreteTypes: Type[], ctx: CheckerContext) => Symbol | null;

let exprCheckerFn: ExprCheckerFn = (ctx: CheckerContext, node: Node, expectedType: Type | null): void => {
};

let stmtCheckerFn: StmtCheckerFn = (ctx: CheckerContext, node: Node): void => {
};

let bodyCheckerFn: BodyCheckerFn = (ctx: CheckerContext, sym: Symbol, params: string[], body: Node, paramLocs: SourceLocation[]): void => {
};

let instantiateGenericFn: InstantiateGenericFn = (sym: Symbol, paramNames: string[], concreteTypes: Type[], ctx: CheckerContext): Symbol | null => {
	return null;
};


export function callCheckExpr(ctx: CheckerContext, node: Node, expectedType: Type | null): void {
	exprCheckerFn(ctx, node, expectedType);
}

export function callCheckStmt(ctx: CheckerContext, node: Node): void {
	stmtCheckerFn(ctx, node);
}

export function callCheckFunctionBody(ctx: CheckerContext, sym: Symbol, params: string[], body: Node, paramLocs: SourceLocation[]): void {
	bodyCheckerFn(ctx, sym, params, body, paramLocs);
}

export function callInstantiateGeneric(sym: Symbol, paramNames: string[], concreteTypes: Type[], ctx: CheckerContext): Symbol | null {
	return instantiateGenericFn(sym, paramNames, concreteTypes, ctx);
}

export function registerCheckExpr(fn: ExprCheckerFn): void {
	exprCheckerFn = fn;
}

export function registerCheckStmt(fn: StmtCheckerFn): void {
	stmtCheckerFn = fn;
}

export function registerCheckFunctionBody(fn: BodyCheckerFn): void {
	bodyCheckerFn = fn;
}

export function registerInstantiateGeneric(fn: InstantiateGenericFn): void {
	instantiateGenericFn = fn;
}

