// Implicit conversion lowering — the checker marks T → Maybe<T>, named
// function → closure and T → Borrow<T> as hidden conversions; this turns each into
// what every later pass reads: the `{ value, present }` carrier, the `{ fn, env }`
// pair and the address of the borrowed place.

import { Node, NodeKind, NodeFlag, TypeKind, TypeFlag, Type, Symbol, SymbolKind, SourceLocation, CallingConvention, HiddenStdConvData, ProgramData, createNode } from "../../ast/node";
import { isMaybeType, closureStorageType, createFunction, createPtr, createRef, voidType } from "../../checker/types";
import { TransformContext, mintSym, newLoweredSym, freshTemp } from "../context";
import { walkNode } from "../walker";
import { makeNull, makeTypedObjectLiteral, makeHiddenAddr, makeHiddenDeref, makeTypedIdentResolved, makeMember, makeCall, makeReturn, makeExprStmt, makeBlock, makeFnDecl, makeInterfaceDeclFromTypes, syntheticToken } from "../util";
import { wrapMaybeValue } from "../native/nullableLower";

export const ADAPTEE_FIELD: string = "$adaptee";

export function lowerImplicitConv(program: Node, ctx: TransformContext): Node {
	const adapterDecls: Node[] = [];
	const result = walkNode(program, (node: Node): Node => lowerImplicitConvNode(node, ctx, adapterDecls));
	if (adapterDecls.length == 0 || result.kind != NodeKind.Program) return result;
	const d = result.data as ProgramData;
	for (const s of d.programStmts) adapterDecls.push(s);
	result.data = { programStmts: adapterDecls };
	return result;
}

function lowerImplicitConvNode(node: Node, ctx: TransformContext, adapterDecls: Node[]): Node {
	if (node.kind != NodeKind.HiddenStdConv) return node;
	const d = node.data as HiddenStdConvData;
	if (isMaybeType(d.convType)) {
		if (d.convExpr.nodeType != null && isMaybeType(d.convExpr.nodeType)) return d.convExpr;
		return wrapMaybeValue(d.convExpr, d.convType, node.location);
	}
	if (d.convType.kind == TypeKind.Borrow) {
		const addr = makeHiddenAddr(d.convExpr, node.location);
		addr.nodeType = d.convType;
		return addr;
	}
	if (dropsTrailingParams(d)) {
		return ctx.jsBackend ? d.convExpr : arityAdapter(d, ctx, adapterDecls, node.location);
	}
	if (isClosureThunkConv(d)) return closurePair(d.convExpr, d.convType, node.location);
	return node;
}

function closurePair(fn: Node, t: Type, loc: SourceLocation): Node {
	const pair = makeTypedObjectLiteral(["fn", "env"], [fn, makeNull(loc)], t, loc);
	pair.flags = pair.flags.incl(NodeFlag.Closure);
	return pair;
}

function isClosureThunkConv(d: HiddenStdConvData): boolean {
	const inner = d.convExpr.nodeType;
	return d.convType.kind == TypeKind.Function && d.convType.callConv == CallingConvention.CcClosure
		&& inner != null && inner.kind == TypeKind.Function && inner.callConv != CallingConvention.CcClosure;
}

function runtimeParamCount(fn: Type): int32 {
	let n = 0;
	for (const param of fn.typeChildren) {
		if (param == null || param.kind != TypeKind.Void) n += 1;
	}
	return n;
}

function dropsTrailingParams(d: HiddenStdConvData): boolean {
	const inner = d.convExpr.nodeType;
	return d.convType.kind == TypeKind.Function && inner != null && inner.kind == TypeKind.Function
		&& runtimeParamCount(inner) < runtimeParamCount(d.convType);
}

function arityAdapter(d: HiddenStdConvData, ctx: TransformContext, adapterDecls: Node[], loc: SourceLocation): Node {
	const sourceType = d.convExpr.nodeType!;
	const adapteeType = closureStorageType(sourceType);
	const adaptee = sourceType.callConv == CallingConvention.CcClosure ? d.convExpr : closurePair(d.convExpr, adapteeType, loc);
	const thunkName = freshTemp(ctx, "arity");
	const envDecl = makeInterfaceDeclFromTypes(thunkName + "Env", [ADAPTEE_FIELD], [""], [adapteeType], loc);
	const envType = envDecl.nodeType!;
	envType.typeFlags = envType.typeFlags.incl(TypeFlag.ArityAdapter);
	const envSym = mintSym(ctx, SymbolKind.Interface, envType.typeName, createRef(envType));
	envSym.declNode = envDecl;
	envSym.location = loc;
	envType.sym = envSym;
	adapterDecls.push(envDecl);

	const slotType = d.convType;
	const paramSyms: Symbol[] = [];
	const paramTypes: string[] = [];
	const args: Node[] = [];
	let ri = 0;
	for (const param of slotType.typeChildren) {
		if (param != null && param.kind == TypeKind.Void) continue;
		const sym = newLoweredSym(ctx, SymbolKind.Parameter, "a" + String(ri), param);
		paramSyms.push(sym);
		paramTypes.push("");
		if (ri < runtimeParamCount(sourceType)) args.push(makeTypedIdentResolved(sym, param, loc));
		ri += 1;
	}
	const envParam = newLoweredSym(ctx, SymbolKind.Parameter, "_envP", createPtr(voidType()));
	paramSyms.push(envParam);
	paramTypes.push("void*");
	const envCast = createNode(NodeKind.TypeAssertion, { asExpr: makeTypedIdentResolved(envParam, null, loc), asType: envType.typeName }, syntheticToken(loc));
	envCast.nodeType = createPtr(envType);
	const envRead = makeHiddenDeref(envCast, loc);
	envRead.nodeType = envType;
	const callee = makeMember(envRead, ADAPTEE_FIELD, loc);
	callee.nodeType = adapteeType;
	const call = makeCall(callee, args, loc);
	call.nodeType = sourceType.typeReturn != null ? sourceType.typeReturn : voidType();
	const returnsVoid = slotType.typeReturn == null || slotType.typeReturn.kind == TypeKind.Void;
	const body = makeBlock([returnsVoid ? makeExprStmt(call, loc) : makeReturn(call, loc)], loc);
	const thunk = makeFnDecl(thunkName, paramSyms, paramTypes, body, "", "", loc);
	const thunkParams: Type[] = [];
	for (const ps of paramSyms) thunkParams.push(ps.symbolType!);
	const thunkNames: string[] = [];
	for (const ps of paramSyms) thunkNames.push(ps.name);
	thunk.nodeType = createFunction(thunkParams, thunkNames, slotType.typeReturn != null ? slotType.typeReturn : voidType());
	const thunkSym = mintSym(ctx, SymbolKind.Function, thunkName, thunk.nodeType);
	thunkSym.declNode = thunk;
	thunkSym.location = loc;
	thunk.resolvedSym = thunkSym;
	adapterDecls.push(thunk);

	const env = makeTypedObjectLiteral([ADAPTEE_FIELD], [adaptee], createRef(envType), loc);
	const fnRef = makeTypedIdentResolved(thunkSym, slotType, loc);
	const pair = makeTypedObjectLiteral(["fn", "env"], [fnRef, env], slotType, loc);
	pair.flags = pair.flags.incl(NodeFlag.Closure);
	return pair;
}
