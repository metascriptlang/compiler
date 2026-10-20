// Implicit conversion lowering — the checker marks T → Maybe<T>, named
// function → closure and T → Borrow<T> as hidden conversions; this turns each into
// what every later pass reads: the `{ value, present }` carrier, the `{ fn, env }`
// pair and the address of the borrowed place.

import { Node, NodeKind, NodeFlag, TypeKind, TypeFlag, Type, Symbol, SymbolKind, SourceLocation, CallingConvention, HiddenStdConvData, ProgramData, CallExprData, createNode } from "../../ast/node";
import { isMaybeType, closureStorageType, createFunction, createPtr, createRef, voidType } from "../../checker/types";
import { TransformContext, mintSym, newLoweredSym, freshTemp } from "../context";
import { walkNode } from "../walker";
import { runtimeRef, makeNull, makeTypedObjectLiteral, makeHiddenAddr, makeHiddenDeref, makeTypedIdentResolved, makeMember, makeCall, makeReturn, makeExprStmt, makeBlock, makeFnDecl, makeInterfaceDeclFromTypes, syntheticToken } from "../util";
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
	if (node.paramSyms != null) {
		if (!ctx.jsBackend) return arityAdapter(d, node.paramSyms, ctx, adapterDecls, node.location);
		const call = d.convExpr.data as CallExprData;
		return call.arguments.length < node.paramSyms.length ? call.callee : jsArityAdapter(d, node.paramSyms, ctx, adapterDecls, node.location);
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

function arityAdapter(d: HiddenStdConvData, paramSyms: Symbol[], ctx: TransformContext, adapterDecls: Node[], loc: SourceLocation): Node {
	const call = d.convExpr.data as CallExprData;
	const sourceType = call.callee.nodeType!;
	const adapteeType = closureStorageType(sourceType);
	const adaptee = sourceType.callConv == CallingConvention.CcClosure ? call.callee : closurePair(call.callee, adapteeType, loc);
	const thunkName = freshTemp(ctx, "arity");
	const envDecl = makeInterfaceDeclFromTypes(thunkName + "Env", [ADAPTEE_FIELD], [""], [adapteeType], loc);
	const envType = envDecl.nodeType!;
	envType.typeFlags = envType.typeFlags.incl(TypeFlag.ArityAdapter);
	const envSym = mintSym(ctx, SymbolKind.Interface, envType.typeName, createRef(envType));
	envSym.declNode = envDecl;
	envSym.location = loc;
	envType.sym = envSym;
	adapterDecls.push(envDecl);

	const envParam = newLoweredSym(ctx, SymbolKind.Parameter, "_envP", createPtr(voidType()));
	const envCast = createNode(NodeKind.TypeAssertion, { asExpr: makeTypedIdentResolved(envParam, null, loc), asType: envType.typeName }, syntheticToken(loc));
	envCast.nodeType = createPtr(envType);
	const envRead = makeHiddenDeref(envCast, loc);
	envRead.nodeType = envType;
	const callee = makeMember(envRead, ADAPTEE_FIELD, loc);
	callee.nodeType = adapteeType;
	callee.resolvedSym = newLoweredSym(ctx, SymbolKind.Property, ADAPTEE_FIELD, adapteeType);
	const thunkParams: Symbol[] = [];
	for (const sym of paramSyms) thunkParams.push(sym);
	thunkParams.push(envParam);
	const thunkSym = adapterThunk(ctx, thunkName, thunkParams, callee, d, adapterDecls, loc);

	const env = makeTypedObjectLiteral([ADAPTEE_FIELD], [adaptee], createRef(envType), loc);
	const pair = makeTypedObjectLiteral(["fn", "env"], [makeTypedIdentResolved(thunkSym, d.convType, loc), env], d.convType, loc);
	pair.flags = pair.flags.incl(NodeFlag.Closure);
	return pair;
}

function jsArityAdapter(d: HiddenStdConvData, paramSyms: Symbol[], ctx: TransformContext, adapterDecls: Node[], loc: SourceLocation): Node {
	const source = (d.convExpr.data as CallExprData).callee;
	const sourceParam = newLoweredSym(ctx, SymbolKind.Parameter, "source", source.nodeType);
	const thunkParams: Symbol[] = [sourceParam];
	for (const sym of paramSyms) thunkParams.push(sym);
	const thunkSym = adapterThunk(ctx, freshTemp(ctx, "arity"), thunkParams, makeTypedIdentResolved(sourceParam, source.nodeType, loc), d, adapterDecls, loc);
	const adapted = makeCall(runtimeRef("msClosureAdapt", loc), [source, makeTypedIdentResolved(thunkSym, thunkSym.symbolType, loc)], loc);
	adapted.nodeType = d.convType;
	return adapted;
}

function adapterThunk(ctx: TransformContext, name: string, params: Symbol[], callee: Node, d: HiddenStdConvData, adapterDecls: Node[], loc: SourceLocation): Symbol {
	const adapted = makeCall(callee, (d.convExpr.data as CallExprData).arguments, loc);
	adapted.nodeType = d.convExpr.nodeType;
	const slotReturn = d.convType.typeReturn != null ? d.convType.typeReturn : voidType();
	const body = makeBlock([slotReturn.kind == TypeKind.Void ? makeExprStmt(adapted, loc) : makeReturn(adapted, loc)], loc);
	const paramTypes: string[] = [];
	const types: Type[] = [];
	const names: string[] = [];
	for (const p of params) {
		paramTypes.push(p.name == "_envP" ? "void*" : "");
		types.push(p.symbolType!);
		names.push(p.name);
	}
	const thunk = makeFnDecl(name, params, paramTypes, body, "", "", loc);
	thunk.nodeType = createFunction(types, names, slotReturn);
	const thunkSym = mintSym(ctx, SymbolKind.Function, name, thunk.nodeType);
	thunkSym.declNode = thunk;
	thunkSym.location = loc;
	thunk.resolvedSym = thunkSym;
	adapterDecls.push(thunk);
	return thunkSym;
}
