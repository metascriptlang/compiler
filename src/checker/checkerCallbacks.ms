// Checker Callbacks — breaks circular dependency between checkExpr.ms and checkPass.ms
// Same pattern as parser/statements/callbacks.ms.

import { Node } from "../ast/node";
import { Type, unknownType } from "./types";
import { CheckerContext } from "./context";

type ExprCheckerFn = (ctx: CheckerContext, node: Node, expectedType: Type) => Type;
type StmtCheckerFn = (ctx: CheckerContext, node: Node) => void;

let exprCheckerFn: ExprCheckerFn = (ctx: CheckerContext, node: Node, expectedType: Type): Type => {
	return unknownType();
};

let stmtCheckerFn: StmtCheckerFn = (ctx: CheckerContext, node: Node): void => {
};

export function callCheckExpr(ctx: CheckerContext, node: Node, expectedType: Type): Type {
	return exprCheckerFn(ctx, node, expectedType);
}

export function callCheckStmt(ctx: CheckerContext, node: Node): void {
	stmtCheckerFn(ctx, node);
}

export function registerCheckExpr(fn: ExprCheckerFn): void {
	exprCheckerFn = fn;
}

export function registerCheckStmt(fn: StmtCheckerFn): void {
	stmtCheckerFn = fn;
}
