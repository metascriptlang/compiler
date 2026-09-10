import { Node, NodeKind, NodeFlag, Symbol, SymbolKind, Type, TypeKind, createNodeAt, makeLoc } from "../../ast/node";
import { CheckerContext, addError } from "../../checker/context";
import { lookupSymbol } from "../../checker/symbol";
import { ensureShaped, resolveAnnotation } from "../../checker/resolvePass";
import { RaiserValue, RaiserValueKind, raiserNil, heapObjectGetField } from "../../raiser/value";
import { registerHostFn, activeHostObjectHeap, activeHostArrayHeap } from "../../raiser/hostRegistry";
import { mapTypeToAst, nodeToValue, boundSymAt } from "./bridge";
import { activeMetaCtx, activeMetaLine, activeMetaColumn } from "./callbacks";

function queryError(ctx: CheckerContext, msg: string): RaiserValue {
	addError(ctx, msg, activeMetaLine(), activeMetaColumn());
	return raiserNil();
}

function boundSymOf(v: RaiserValue): Symbol | null {
	if (v.kind != RaiserValueKind.Object) return null;
	const heap = activeHostObjectHeap();
	if (heap == null) return null;
	const hv = heapObjectGetField(heap, v.intVal, "symHandle");
	if (hv.kind == RaiserValueKind.Int) return boundSymAt(hv.intVal as int32);
	if (hv.kind == RaiserValueKind.Float) return boundSymAt(hv.floatVal as int32);
	return null;
}

function emitNode(n: Node): RaiserValue {
	const objHeap = activeHostObjectHeap();
	const arrHeap = activeHostArrayHeap();
	if (objHeap == null || arrHeap == null) return raiserNil();
	return nodeToValue(n, objHeap, arrHeap);
}

function peelToImpl(t: Type): Type {
	let cur = t;
	let guard = 0;
	while (cur != null && guard < 4
			&& (cur.kind == TypeKind.Ref || cur.kind == TypeKind.Alias)
			&& cur.typeReturn != null) {
		cur = cur.typeReturn;
		guard = guard + 1;
	}
	return cur;
}

function hostBindSym(args: RaiserValue[]): RaiserValue {
	const ctx = activeMetaCtx();
	if (ctx == null || args.length < 1 || args[0].kind != RaiserValueKind.String) return raiserNil();
	const sym = lookupSymbol(ctx.table, args[0].strVal);
	if (sym == null) return raiserNil();
	const ident = createNodeAt(NodeKind.Identifier, { name: sym.name }, makeLoc(activeMetaLine(), activeMetaColumn()));
	ident.resolvedSym = sym;
	ident.flags = ident.flags | (NodeFlag.BoundSym as int32);
	return emitNode(ident);
}

function hostGetType(args: RaiserValue[]): RaiserValue {
	const ctx = activeMetaCtx();
	if (ctx == null || args.length < 1) return raiserNil();
	const impl = args.length > 1 && args[1].kind == RaiserValueKind.Bool && args[1].intVal != 0;
	const sym = boundSymOf(args[0]);
	if (sym == null) {
		const heap = activeHostObjectHeap();
		if (heap != null && args[0].kind == RaiserValueKind.Object) {
			const nt = heapObjectGetField(heap, args[0].intVal, "nodeType");
			if (nt.kind == RaiserValueKind.Object) return nt;
		}
		return queryError(ctx, "node has no type");
	}
	if (sym.symbolKind != SymbolKind.Macro) ensureShaped(sym, ctx);
	const t = sym.symbolType;
	if (t == null) return queryError(ctx, "node has no type");
	const loc = makeLoc(activeMetaLine(), activeMetaColumn());
	return emitNode(mapTypeToAst(impl ? peelToImpl(t) : t, loc));
}

function hostGetImpl(args: RaiserValue[]): RaiserValue {
	const ctx = activeMetaCtx();
	if (ctx == null || args.length < 1) return raiserNil();
	const sym = boundSymOf(args[0]);
	if (sym == null) return queryError(ctx, "node is not a symbol");
	if (sym.declNode == null) return raiserNil();
	return emitNode(sym.declNode);
}

function hostResolveType(args: RaiserValue[]): RaiserValue {
	const ctx = activeMetaCtx();
	if (ctx == null || args.length < 1 || args[0].kind != RaiserValueKind.String) return raiserNil();
	const line = activeMetaLine();
	const column = activeMetaColumn();
	const t = resolveAnnotation(args[0].strVal, ctx, line, column);
	return emitNode(mapTypeToAst(t, makeLoc(line, column)));
}

export function registerTypeQueryHostFns(): void {
	registerHostFn("msMetaBindSym", hostBindSym);
	registerHostFn("msMetaGetType", hostGetType);
	registerHostFn("msMetaGetImpl", hostGetImpl);
	registerHostFn("msMetaResolveType", hostResolveType);
}
