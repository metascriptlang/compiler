// Checker Callbacks — breaks circular dependency between checkExpr.ms and checkPass.ms
// Same pattern as parser/statements/callbacks.ms.

import { Node, Type, Symbol } from "../ast/node";
import { CheckerContext } from "./context";
import { SourceLocation } from "../ast/node";

type ExprCheckerFn = (ctx: CheckerContext, node: Node, expectedType: Type | null) => void;
type StmtCheckerFn = (ctx: CheckerContext, node: Node) => void;
type BodyCheckerFn = (ctx: CheckerContext, sym: Symbol, params: string[], body: Node, paramLocs: SourceLocation[] | null) => Symbol[];
type LocalInstanceCheckerFn = (ctx: CheckerContext, node: Node, declared: (sym: Symbol) => void) => Symbol | null;
type InstantiateGenericFn = (sym: Symbol, params: Type[], concreteTypes: Type[], ctx: CheckerContext, callLoc: SourceLocation) => Symbol | null;
type EvalComptimeBlockFn = (node: Node, ctx: CheckerContext) => Node;
type ExpandMacroInvocationFn = (node: Node, ctx: CheckerContext, depth: int32) => Node;
type ApplyDecoratorsFn = (ctx: CheckerContext, program: Node) => void;
type ApplyModulePassesFn = (ctx: CheckerContext, program: Node) => void;
type DecoratorDefersFn = (ctx: CheckerContext, stmt: Node) => boolean;
type ApplyDecoratedStmtFn = (ctx: CheckerContext, stmt: Node, after: Node[]) => Node;
type DemandFieldFn = (ctx: CheckerContext, owner: Symbol, name: string, isStatic: boolean, read: Node) => void;
type DemandFn = (ctx: CheckerContext, sym: Symbol, read: Node) => void;
type SelfReadTypeFn = (callee: Node) => Type | null;
type UndefinedVariableMessageFn = (ctx: CheckerContext, name: string) => string;

let exprCheckerFn: ExprCheckerFn = (ctx: CheckerContext, node: Node, expectedType: Type | null): void => {
	throw new Error("internal: checker callback checkExpr was called before it was installed");
};

let stmtCheckerFn: StmtCheckerFn = (ctx: CheckerContext, node: Node): void => {
	throw new Error("internal: checker callback checkStmt was called before it was installed");
};

let bodyCheckerFn: BodyCheckerFn = (ctx: CheckerContext, sym: Symbol, params: string[], body: Node, paramLocs: SourceLocation[] | null): Symbol[] => {
	throw new Error("internal: checker callback checkFunctionBody was called before it was installed");
};

let localInstanceCheckerFn: LocalInstanceCheckerFn = (ctx: CheckerContext, node: Node, declared: (sym: Symbol) => void): Symbol | null => {
	throw new Error("internal: checker callback checkLocalInstance was called before it was installed");
};

let instantiateGenericFn: InstantiateGenericFn = (sym: Symbol, params: Type[], concreteTypes: Type[], ctx: CheckerContext, callLoc: SourceLocation): Symbol | null => {
	throw new Error("internal: checker callback instantiateGeneric was called before it was installed");
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
	throw new Error("internal: checker callback demandReturn was called before it was installed");
};
let demandBindingFn: DemandFn = (ctx: CheckerContext, sym: Symbol, read: Node): void => {
	throw new Error("internal: checker callback demandBinding was called before it was installed");
};
let demandFieldFn: DemandFieldFn = (ctx: CheckerContext, owner: Symbol, name: string, isStatic: boolean, read: Node): void => {
};
let selfReadTypeFn: SelfReadTypeFn = (callee: Node): Type | null => {
	throw new Error("internal: checker callback selfReadType was called before it was installed");
};
let undefinedVariableMessageFn: UndefinedVariableMessageFn = (ctx: CheckerContext, name: string): string => {
	throw new Error("internal: checker callback undefinedVariableMessage was called before it was installed");
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

export function callCheckLocalInstance(ctx: CheckerContext, node: Node, declared: (sym: Symbol) => void): Symbol | null {
	return localInstanceCheckerFn(ctx, node, declared);
}

export function callInstantiateGeneric(sym: Symbol, params: Type[], concreteTypes: Type[], ctx: CheckerContext, callLoc: SourceLocation): Symbol | null {
	return instantiateGenericFn(sym, params, concreteTypes, ctx, callLoc);
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

export function registerCheckLocalInstance(fn: LocalInstanceCheckerFn): void {
	localInstanceCheckerFn = fn;
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

export function callDemandField(ctx: CheckerContext, owner: Symbol, name: string, isStatic: boolean, read: Node): void {
	demandFieldFn(ctx, owner, name, isStatic, read);
}

export function registerDemandField(fn: DemandFieldFn): void {
	demandFieldFn = fn;
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

type TypeInstanceHooksFn = (instType: Type, ctx: CheckerContext, line: int32, col: int32) => void;

type GenericTypeHookFn = (ctx: CheckerContext, hookSym: Symbol, receiver: Type, hook: string, at: SourceLocation) => void;

let genericTypeHookFn: GenericTypeHookFn = (ctx: CheckerContext, hookSym: Symbol, receiver: Type, hook: string, at: SourceLocation): void => {
	throw new Error(`internal: no binder for the hook '${hook}' of a generic type is registered`);
};

export function registerGenericTypeHook(fn: GenericTypeHookFn): void {
	genericTypeHookFn = fn;
}

export function callGenericTypeHook(ctx: CheckerContext, hookSym: Symbol, receiver: Type, hook: string, at: SourceLocation): void {
	genericTypeHookFn(ctx, hookSym, receiver, hook, at);
}

let typeInstanceHooksFn: TypeInstanceHooksFn = (instType: Type, ctx: CheckerContext, line: int32, col: int32): void => {
};

export function registerTypeInstanceHooks(fn: TypeInstanceHooksFn): void {
	typeInstanceHooksFn = fn;
}

export function callTypeInstanceHooks(instType: Type, ctx: CheckerContext, line: int32, col: int32): void {
	typeInstanceHooksFn(instType, ctx, line, col);
}
