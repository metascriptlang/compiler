// Checker Callbacks — breaks circular dependency between checkExpr.ms and checkPass.ms
// Same pattern as parser/statements/callbacks.ms.

import { Node, Type, Symbol } from "../ast/node";
import { CheckerContext } from "./context";
import { SourceLocation } from "../ast/node";

type ExprCheckerFn = (ctx: CheckerContext, node: Node, expectedType: Type | null) => void;
type StmtCheckerFn = (ctx: CheckerContext, node: Node) => void;
type BodyCheckerFn = (ctx: CheckerContext, sym: Symbol, params: string[], body: Node, paramLocs: SourceLocation[] | null) => Symbol[];
type InstantiateGenericFn = (sym: Symbol, paramNames: string[], concreteTypes: Type[], ctx: CheckerContext, callLoc: SourceLocation, params: (Type | null)[]) => Symbol | null;
type EvalComptimeBlockFn = (node: Node, ctx: CheckerContext) => Node;
type ExpandMacroInvocationFn = (node: Node, ctx: CheckerContext, depth: int32) => Node;
type ApplyDecoratorsFn = (ctx: CheckerContext, program: Node) => void;
type ApplyModulePassesFn = (ctx: CheckerContext, program: Node) => void;
type DecoratorDefersFn = (ctx: CheckerContext, stmt: Node) => boolean;
type ApplyDecoratedStmtFn = (ctx: CheckerContext, stmt: Node, after: Node[]) => Node;
type DemandFn = (ctx: CheckerContext, sym: Symbol, read: Node) => void;
type SelfReadTypeFn = (callee: Node) => Type | null;
type UndefinedVariableMessageFn = (ctx: CheckerContext, name: string) => string;

let exprCheckerFn: ExprCheckerFn = (ctx: CheckerContext, node: Node, expectedType: Type | null): void => {
};

let stmtCheckerFn: StmtCheckerFn = (ctx: CheckerContext, node: Node): void => {
};

let bodyCheckerFn: BodyCheckerFn = (ctx: CheckerContext, sym: Symbol, params: string[], body: Node, paramLocs: SourceLocation[] | null): Symbol[] => {
	return [];
};

let instantiateGenericFn: InstantiateGenericFn = (sym: Symbol, paramNames: string[], concreteTypes: Type[], ctx: CheckerContext, callLoc: SourceLocation, params: (Type | null)[]): Symbol | null => {
	return null;
};

let evalComptimeBlockFn: EvalComptimeBlockFn = (node: Node, ctx: CheckerContext): Node => {
	return node;
};

let expandMacroInvocationFn: ExpandMacroInvocationFn = (node: Node, ctx: CheckerContext, depth: int32): Node => {
	return node;
};
let applyDecoratorsFn: ApplyDecoratorsFn = (ctx: CheckerContext, program: Node): void => {
};
let applyModulePassesFn: ApplyModulePassesFn = (ctx: CheckerContext, program: Node): void => {
};
let decoratorDefersFn: DecoratorDefersFn = (ctx: CheckerContext, stmt: Node): boolean => {
	return false;
};
let applyDecoratedStmtFn: ApplyDecoratedStmtFn = (ctx: CheckerContext, stmt: Node, after: Node[]): Node => {
	return stmt;
};
let demandReturnFn: DemandFn = (ctx: CheckerContext, sym: Symbol, read: Node): void => {
};
let demandBindingFn: DemandFn = (ctx: CheckerContext, sym: Symbol, read: Node): void => {
};
let selfReadTypeFn: SelfReadTypeFn = (callee: Node): Type | null => {
	return null;
};
let undefinedVariableMessageFn: UndefinedVariableMessageFn = (ctx: CheckerContext, name: string): string => {
	return `Undefined variable '${name}'`;
};


export function callCheckExpr(ctx: CheckerContext, node: Node, expectedType: Type | null): void {
	exprCheckerFn(ctx, node, expectedType);
}

export function checkInTypeSlot(ctx: CheckerContext, node: Node): void {
	const saved = ctx.typeExprSlot;
	ctx.typeExprSlot = node;
	exprCheckerFn(ctx, node, null);
	ctx.typeExprSlot = saved;
}

export function callCheckStmt(ctx: CheckerContext, node: Node): void {
	stmtCheckerFn(ctx, node);
}

export function callCheckFunctionBody(ctx: CheckerContext, sym: Symbol, params: string[], body: Node, paramLocs: SourceLocation[] | null): Symbol[] {
	return bodyCheckerFn(ctx, sym, params, body, paramLocs);
}

export function callInstantiateGeneric(sym: Symbol, paramNames: string[], concreteTypes: Type[], ctx: CheckerContext, callLoc: SourceLocation, params: (Type | null)[] = []): Symbol | null {
	return instantiateGenericFn(sym, paramNames, concreteTypes, ctx, callLoc, params);
}

export function callEvalComptimeBlock(node: Node, ctx: CheckerContext): Node {
	return evalComptimeBlockFn(node, ctx);
}

export function callExpandMacroInvocation(node: Node, ctx: CheckerContext, depth: int32): Node {
	return expandMacroInvocationFn(node, ctx, depth);
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

export function registerEvalComptimeBlock(fn: EvalComptimeBlockFn): void {
	evalComptimeBlockFn = fn;
}

export function registerExpandMacroInvocation(fn: ExpandMacroInvocationFn): void {
	expandMacroInvocationFn = fn;
}

export function callApplyDecorators(ctx: CheckerContext, program: Node): void {
	applyDecoratorsFn(ctx, program);
}

export function registerApplyDecorators(fn: ApplyDecoratorsFn): void {
	applyDecoratorsFn = fn;
}

export function callApplyModulePasses(ctx: CheckerContext, program: Node): void {
	applyModulePassesFn(ctx, program);
}

export function registerApplyModulePasses(fn: ApplyModulePassesFn): void {
	applyModulePassesFn = fn;
}

export function callDecoratorDefers(ctx: CheckerContext, stmt: Node): boolean {
	return decoratorDefersFn(ctx, stmt);
}

export function registerDecoratorDefers(fn: DecoratorDefersFn): void {
	decoratorDefersFn = fn;
}

export function callApplyDecoratedStmt(ctx: CheckerContext, stmt: Node, after: Node[]): Node {
	return applyDecoratedStmtFn(ctx, stmt, after);
}

export function registerApplyDecoratedStmt(fn: ApplyDecoratedStmtFn): void {
	applyDecoratedStmtFn = fn;
}

export function callDemandReturn(ctx: CheckerContext, sym: Symbol, read: Node): void {
	demandReturnFn(ctx, sym, read);
}

export function registerDemandReturn(fn: DemandFn): void {
	demandReturnFn = fn;
}

export function callDemandBinding(ctx: CheckerContext, sym: Symbol, read: Node): void {
	demandBindingFn(ctx, sym, read);
}

export function registerDemandBinding(fn: DemandFn): void {
	demandBindingFn = fn;
}

export function callSelfReadType(callee: Node): Type | null {
	return selfReadTypeFn(callee);
}

export function registerSelfReadType(fn: SelfReadTypeFn): void {
	selfReadTypeFn = fn;
}

export function callUndefinedVariableMessage(ctx: CheckerContext, name: string): string {
	return undefinedVariableMessageFn(ctx, name);
}

export function registerUndefinedVariableMessage(fn: UndefinedVariableMessageFn): void {
	undefinedVariableMessageFn = fn;
}
