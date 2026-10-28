import { Node, NodeKind, NodeFlag, SymbolKind, Symbol, Type, TypeKind, IdentifierData, ProgramData, SourceLocation } from "../../ast/node";
import { GcMode, DispMethodEntry, dispatchEntryFor, dispatchOverridesFor } from "../../checker/context";
import { fitNode } from "../../checker/fit";
import { sameType } from "../../checker/compat";
import { TransformContext, mintSym, newLoweredSym } from "../context";
import { walkNode } from "../walker";
import { makeBinary, makeBlock, makeCall, makeExprStmt, makeFnDecl, makeIdentResolved, makeHiddenSubConv, makeIf, makeReturn, makeTypedIdentResolved } from "../util";

// A call of an overridden instance method goes through one function per module that tries each
// override most-derived first and falls back to the method itself: the override is called with
// every argument converted to the type the override declares, so the ordinary call lowering
// handles a hidden result, an indirect parameter or a union widening.

export function lowerMethodDispatch(program: Node, ctx: TransformContext): Node {
	if (program.kind != NodeKind.Program || ctx.jsBackend || ctx.raiserBackend) return program;
	if (ctx.checkerCtx == null || ctx.checkerCtx.gcMode == GcMode.Manual) return program;
	const dispatchers = new HashMap<Symbol, Symbol>();
	const decls: Node[] = [];
	const result = walkNode(program, (node: Node): Node => {
		if (node.kind != NodeKind.Identifier || node.flags.has(NodeFlag.NoDispatch)) return node;
		const sym = node.resolvedSym;
		if (sym == null || sym.symbolKind != SymbolKind.Function || sym.nativeName != "") return node;
		const entry = dispatchEntryFor(sym);
		if (entry == null || entry.overloaded) return node;
		let dispatcher = dispatchers.get(sym) ?? null;
		if (dispatcher == null) {
			const overrides = dispatchOverridesFor(entry.classSym, entry.methodName);
			if (overrides.length == 0 || sym.symbolType == null || sym.symbolType.typeChildren.length == 0) return node;
			dispatcher = buildDispatcher(ctx, sym, overrides, decls, node.location);
			dispatchers.set(sym, dispatcher);
		}
		(node.data as IdentifierData).name = dispatcher.name;
		node.resolvedSym = dispatcher;
		return node;
	});
	const pd = result.data as ProgramData;
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
		if (ovType == null || ovType.typeChildren.length == 0) continue;
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
	const target = makeTypedIdentResolved(callee, null, loc);
	target.flags = target.flags.incl(NodeFlag.NoDispatch);
	const call = makeCall(target, args, loc);
	call.nodeType = calleeType.typeReturn;
	if (!returns) return [makeExprStmt(call, loc), makeReturn(null, loc)];
	return [makeReturn(converted(ctx, call, calleeType.typeReturn, baseType.typeReturn), loc)];
}

function converted(ctx: TransformContext, value: Node, from: Type | null, to: Type | null): Node {
	if (from == null || to == null || sameType(from, to)) return value;
	const errors = ctx.checkerCtx.errors.length;
	const fitted = fitNode(ctx.checkerCtx, value, to, from);
	if (ctx.checkerCtx.errors.length != errors) throw new Error(`internal: a dispatcher cannot convert '${from.typeName}' to the override's '${to.typeName}'`);
	return fitted;
}
