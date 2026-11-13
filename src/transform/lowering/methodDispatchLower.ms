import { Node, NodeKind, NodeFlag, SymbolKind, SymbolFlag, Symbol, Type, TypeKind, IdentifierData, ProgramData, SourceLocation } from "../../ast/node";
import { hasFlag } from "../../checker/symbol";
import { int32Type, derivesFromClass } from "../../checker/types";
import { GcMode, DispMethodEntry, dispatchEntryFor, dispatchOverridesFor, dispatchMethodOf } from "../../checker/context";
import { fitNode, projectTagUnionMember } from "../../checker/fit";
import { declaredDefaults, fillDefaults, takeDefaultArgTemps } from "../../checker/callResolve";
import { pickBodyCtx } from "../../checker/instantiate";
import { sameType } from "../../checker/compat";
import { TransformContext, mintSym, newLoweredSym } from "../context";
import { walkNode } from "../walker";
import { makeBinary, makeBlock, makeCall, makeExprStmt, makeFnDecl, makeIdentResolved, makeHiddenSubConv, makeIf, makeMember, makeNumber, makeReturn, makeTypedIdentResolved } from "../util";

// A call of an overridden instance method goes through one function per module that tries each
// override most-derived first and falls back to the method itself: the override is called with
// every argument converted to the type the override declares, so the ordinary call lowering
// handles a hidden result, an indirect parameter or a union widening.

// The C union stores the slot it holds; a Raiser union of classes is the object itself, so the
// object's class picks the member, a member deriving from another member tested first.
function holdsMember(ctx: TransformContext, p0: Symbol, member: Type, vi: int32, loc: SourceLocation): Node {
	if (ctx.raiserBackend) return makeBinary(makeTypedIdentResolved(p0, null, loc), "instanceof", makeIdentResolved(member.sym!, loc), loc);
	const tag = makeMember(makeTypedIdentResolved(p0, null, loc), "_tag", loc);
	tag.nodeType = int32Type();
	return makeBinary(tag, "==", makeNumber(vi, loc), loc);
}

function memberTestOrder(ut: Type): int32[] {
	const order: int32[] = [];
	const bases: int32[] = [];
	for (let vi = 0; vi < ut.typeChildren.length; vi += 1) {
		let n = 0;
		for (const other of ut.typeChildren) {
			if (other != ut.typeChildren[vi] && derivesFromClass(ut.typeChildren[vi], other.sym!)) n += 1;
		}
		bases.push(n);
		order.push(vi);
	}
	order.sort((a: int32, b: int32): number => bases[b] - bases[a]);
	return order;
}

function buildUnionDispatcher(ctx: TransformContext, shared: Symbol, ut: Type, ordinal: int32, decls: Node[], loc: SourceLocation): Symbol {
	const sharedType = shared.symbolType;
	const params: Symbol[] = [];
	const paramTypes: string[] = [];
	for (let i = 0; i < sharedType.typeChildren.length; i += 1) {
		params.push(newLoweredSym(ctx, SymbolKind.Parameter, "p" + i.toString(), sharedType.typeChildren[i]));
		paramTypes.push("");
	}
	const returns = sharedType.typeReturn != null && sharedType.typeReturn.kind != TypeKind.Void;
	const stmts: Node[] = [];
	const order = memberTestOrder(ut);
	const last = order.length - 1;
	for (let oi = 0; oi <= last; oi += 1) {
		const vi = order[oi];
		const member = ut.typeChildren[vi];
		const entry = dispatchMethodOf(ctx.checkerCtx.dispatchRegistry, member.sym!, shared.name);
		if (entry == null || entry.sym.symbolType == null) throw new Error(`internal: '${member.sym!.name}' has no method '${shared.name}' for the union call the checker accepted`);
		const meth = entry.sym;
		const methType = meth.symbolType;
		const args: Node[] = [];
		const value = projectTagUnionMember(makeTypedIdentResolved(params[0], null, loc), ut, member);
		value.nodeType = member;
		args.push(converted(ctx, value, member, methType.typeChildren[0]));
		for (let i = 1; i < params.length; i += 1) args.push(converted(ctx, makeTypedIdentResolved(params[i], null, loc), sharedType.typeChildren[i], methType.typeChildren[i]));
		const call = makeCall(makeTypedIdentResolved(meth, null, loc), args, loc);
		call.nodeType = methType.typeReturn;
		const arm: Node[] = [];
		if (returns) {
			arm.push(makeReturn(converted(ctx, call, methType.typeReturn, sharedType.typeReturn), loc));
		} else {
			arm.push(makeExprStmt(call, loc));
			arm.push(makeReturn(null, loc));
		}
		if (oi == last) {
			for (const st of arm) stmts.push(st);
		} else {
			stmts.push(makeIf(holdsMember(ctx, params[0], member, vi, loc), makeBlock(arm, loc), null, loc));
		}
	}
	const name = "msUnionDisp_" + shared.name + "_" + ordinal.toString();
	const decl = makeFnDecl(name, params, paramTypes, makeBlock(stmts, loc), "", "", loc);
	decl.nodeType = sharedType;
	const sym = mintSym(ctx, SymbolKind.Function, name, sharedType);
	sym.declNode = decl;
	sym.location = loc;
	decl.resolvedSym = sym;
	decls.push(decl);
	return sym;
}

// A method called on a union of classes goes through one function per module and (union, name)
// that tests the union's tag and calls the member's own method with the member's value; that call
// is an ordinary method call, so an override of the member's method is dispatched inside it.
export function lowerMethodDispatch(program: Node, ctx: TransformContext): Node {
	if (program.kind != NodeKind.Program || ctx.jsBackend || ctx.checkerCtx == null) return program;
	const overridesDispatch = !ctx.raiserBackend && ctx.checkerCtx.gcMode != GcMode.Manual;
	const dispatchers = new HashMap<Symbol, Symbol>();
	const unionDispatchers = new HashMap<string, Symbol>();
	const decls: Node[] = [];
	const unionDecls: Node[] = [];
	const visit = (node: Node): Node => {
		if (node.kind != NodeKind.Identifier || node.flags.has(NodeFlag.NoDispatch)) return node;
		const sym = node.resolvedSym;
		if (sym == null || sym.symbolKind != SymbolKind.Function || sym.nativeName != "") return node;
		if (hasFlag(sym, SymbolFlag.UnionMethod)) {
			const ut = sym.symbolType.typeChildren[0];
			let key = sym.name;
			for (const m of ut.typeChildren) key = key + "|" + m.sym!.modulePath + "#" + m.sym!.name;
			let shared = unionDispatchers.get(key) ?? null;
			if (shared == null) {
				shared = buildUnionDispatcher(ctx, sym, ut, unionDispatchers.size, unionDecls, node.location);
				unionDispatchers.set(key, shared);
			}
			(node.data as IdentifierData).name = shared.name;
			node.resolvedSym = shared;
			return node;
		}
		if (!overridesDispatch) return node;
		const entry = dispatchEntryFor(ctx.checkerCtx.dispatchRegistry, sym);
		if (entry == null || entry.overloaded) return node;
		let dispatcher = dispatchers.get(sym) ?? null;
		if (dispatcher == null) {
			const overrides = dispatchOverridesFor(ctx.checkerCtx.dispatchRegistry, entry.classSym, entry.methodName);
			if (overrides.length == 0 || sym.symbolType == null || sym.symbolType.typeChildren.length == 0) return node;
			dispatcher = buildDispatcher(ctx, sym, overrides, decls, node.location);
			dispatchers.set(sym, dispatcher);
		}
		(node.data as IdentifierData).name = dispatcher.name;
		node.resolvedSym = dispatcher;
		return node;
	};
	const result = walkNode(program, visit);
	const pd = result.data as ProgramData;
	for (const decl of unionDecls) pd.programStmts.push(walkNode(decl, visit));
	for (const decl of decls) pd.programStmts.push(decl);
	return result;
}

function buildDispatcher(ctx: TransformContext, base: Symbol, overrides: DispMethodEntry[], decls: Node[], loc: SourceLocation): Symbol {
	const baseType = base.symbolType!;
	const params: Symbol[] = [];
	const paramTypes: string[] = [];
	for (let i = 0; i < baseType.typeChildren.length; i += 1) {
		params.push(newLoweredSym(ctx, SymbolKind.Parameter, "p" + i.toString(), baseType.typeChildren[i]));
		paramTypes.push("");
	}
	const returns = baseType.typeReturn != null && baseType.typeReturn.kind != TypeKind.Void;
	const stmts: Node[] = [];
	for (const o of overrides) {
		const ovType = o.sym.symbolType;
		if (ovType == null || ovType.typeChildren.length == 0) throw new Error(`internal: the override '${o.sym.name}' of '${base.name}' has no signature to forward to`);
		const receiver = makeBinary(makeTypedIdentResolved(params[0], null, loc), "instanceof", makeIdentResolved(o.classSym, loc), loc);
		stmts.push(makeIf(receiver, makeBlock(forward(ctx, o.sym, ovType, baseType, params, returns, loc), loc), null, loc));
	}
	for (const s of forward(ctx, base, baseType, baseType, params, returns, loc)) stmts.push(s);
	const name = "msDisp_" + base.name;
	const decl = makeFnDecl(name, params, paramTypes, makeBlock(stmts, loc), "", "", loc);
	decl.nodeType = baseType;
	const sym = mintSym(ctx, SymbolKind.Function, name, baseType);
	sym.mutatedParams = base.mutatedParams;
	sym.declNode = decl;
	sym.location = loc;
	decl.resolvedSym = sym;
	decls.push(decl);
	return sym;
}

function forward(ctx: TransformContext, callee: Symbol, calleeType: Type, baseType: Type, params: Symbol[], returns: boolean, loc: SourceLocation): Node[] {
	const forwarded = calleeType.typeChildren.length < baseType.typeChildren.length ? calleeType.typeChildren.length : baseType.typeChildren.length;
	const args: Node[] = [];
	for (let i = 0; i < forwarded; i += 1) {
		const arg = makeTypedIdentResolved(params[i], null, loc);
		const formal = calleeType.typeChildren[i];
		if (i == 0) args.push(sameType(baseType.typeChildren[0], formal) ? arg : makeHiddenSubConv(arg, formal, loc));
		else args.push(converted(ctx, arg, baseType.typeChildren[i], formal));
	}
	const stmts: Node[] = [];
	if (calleeType.typeChildren.length > forwarded) {
		const defCtx = pickBodyCtx(callee.modulePath, ctx.checkerCtx);
		const hoistMark = defCtx.pendingHoisted.length;
		fillDefaults(ctx.checkerCtx, args, declaredDefaults(callee), calleeType.typeChildren.length, 0, calleeType.typeChildren, callee.modulePath, calleeType.typeNames);
		for (const t of takeDefaultArgTemps(defCtx, hoistMark)) stmts.push(t);
		if (args.length != calleeType.typeChildren.length) throw new Error(`internal: the override '${callee.name}' declares parameters beyond the base method without a default`);
	}
	const target = makeTypedIdentResolved(callee, null, loc);
	target.flags = target.flags.incl(NodeFlag.NoDispatch);
	const call = makeCall(target, args, loc);
	call.nodeType = calleeType.typeReturn;
	if (!returns) {
		stmts.push(makeExprStmt(call, loc));
		stmts.push(makeReturn(null, loc));
	} else {
		stmts.push(makeReturn(converted(ctx, call, calleeType.typeReturn, baseType.typeReturn), loc));
	}
	return stmts;
}

function converted(ctx: TransformContext, value: Node, from: Type | null, to: Type | null): Node {
	if (from == null || to == null || sameType(from, to)) return value;
	const errors = ctx.checkerCtx.errors.length;
	const fitted = fitNode(ctx.checkerCtx, value, to, from);
	if (ctx.checkerCtx.errors.length != errors) throw new Error(`internal: a dispatcher cannot convert '${from.typeName}' to the override's '${to.typeName}'`);
	return fitted;
}
