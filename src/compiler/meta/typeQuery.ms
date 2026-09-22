import { Node, NodeKind, NodeFlag, Symbol, SymbolKind, Type, TypeKind, createNodeAt, makeLoc } from "../../ast/node";
import { CheckerContext, addError } from "../../checker/context";
import { lookupSymbol, hasFlag, SymbolFlag } from "../../checker/symbol";
import { ensureShaped, resolveAnnotation } from "../../checker/resolvePass";
import { RaiserValue, RaiserValueKind, raiserNil, raiserInt, raiserBool, heapObjectGetField, heapObjectSetField } from "../../raiser/value";
import { HostCapability, registerHostFn, activeHostObjectHeap, activeHostArrayHeap } from "../../raiser/hostRegistry";
import { mapTypeToAst, nodeToValue, boundSymAt, registerBoundType, boundTypeAt } from "./bridge";
import { sameType } from "../../checker/compat";
import { activeMetaCtx, activeMetaLine, activeMetaColumn } from "./callbacks";

export function stillDecoratedMessage(name: string): string {
	return `'${name}' is still being decorated - its type is not available until its decorators finish`;
}

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

function emitTypeNode(n: Node, src: Type): RaiserValue {
	const v = emitNode(n);
	const objHeap = activeHostObjectHeap();
	if (objHeap != null && v.kind == RaiserValueKind.Object) {
		heapObjectSetField(objHeap, v.intVal, "typeHandle", raiserInt(registerBoundType(src) as int64));
	}
	return v;
}

function peelAlias(t: Type): Type {
	let cur = t;
	let g = 0;
	while (cur != null && cur.kind == TypeKind.Alias && cur.typeReturn != null && g < 8) {
		cur = cur.typeReturn;
		g = g + 1;
	}
	return cur;
}

function typeArgOf(v: RaiserValue): Type | null {
	if (v.kind == RaiserValueKind.Object) {
		const heap = activeHostObjectHeap();
		if (heap != null) {
			const th = heapObjectGetField(heap, v.intVal, "typeHandle");
			if (th.kind == RaiserValueKind.Int) { const t = boundTypeAt(th.intVal as int32); if (t != null) return t; }
			if (th.kind == RaiserValueKind.Float) { const t = boundTypeAt(th.floatVal as int32); if (t != null) return t; }
		}
	}
	const sym = boundSymOf(v);
	if (sym != null && !hasFlag(sym, SymbolFlag.Forward)) {
		const ctx = activeMetaCtx();
		if (ctx != null && sym.symbolKind != SymbolKind.Macro) ensureShaped(sym, ctx);
		return sym.symbolType;
	}
	return null;
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
	ident.flags = ident.flags.incl(NodeFlag.BoundSym);
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
	if (hasFlag(sym, SymbolFlag.Forward)) return queryError(ctx, stillDecoratedMessage(sym.name));
	if (sym.symbolKind != SymbolKind.Macro) ensureShaped(sym, ctx);
	const t = sym.symbolType;
	if (t == null) return queryError(ctx, "node has no type");
	const loc = makeLoc(activeMetaLine(), activeMetaColumn());
	const src = impl ? peelToImpl(t) : t;
	return emitTypeNode(mapTypeToAst(src, loc), src);
}

function hostGetImpl(args: RaiserValue[]): RaiserValue {
	const ctx = activeMetaCtx();
	if (ctx == null || args.length < 1) return raiserNil();
	const sym = boundSymOf(args[0]);
	if (sym == null) return queryError(ctx, "node is not a symbol");
	if (hasFlag(sym, SymbolFlag.Forward)) return queryError(ctx, stillDecoratedMessage(sym.name));
	if (sym.declNode == null) return raiserNil();
	return emitNode(sym.declNode);
}

function hostResolveType(args: RaiserValue[]): RaiserValue {
	const ctx = activeMetaCtx();
	if (ctx == null || args.length < 1 || args[0].kind != RaiserValueKind.String) return raiserNil();
	const line = activeMetaLine();
	const column = activeMetaColumn();
	const t = resolveAnnotation(args[0].strVal, ctx, line, column);
	if (t == null) return raiserNil();
	return emitTypeNode(mapTypeToAst(t, makeLoc(line, column)), t);
}

function hostTypeKind(args: RaiserValue[]): RaiserValue {
	const ctx = activeMetaCtx();
	if (ctx == null || args.length < 1) return raiserNil();
	const sym = boundSymOf(args[0]);
	if (sym != null && hasFlag(sym, SymbolFlag.Forward)) return queryError(ctx, stillDecoratedMessage(sym.name));
	const t = typeArgOf(args[0]);
	if (t == null) return queryError(ctx, "node carries no type");
	return raiserInt(peelAlias(t).kind as int64);
}

function hostSameType(args: RaiserValue[]): RaiserValue {
	const ctx = activeMetaCtx();
	if (ctx == null || args.length < 2) return raiserBool(false);
	const a = typeArgOf(args[0]);
	const b = typeArgOf(args[1]);
	if (a == null || b == null) { queryError(ctx, "sameType needs two type nodes"); return raiserBool(false); }
	return raiserBool(sameType(a, b));
}

function hostSymKind(args: RaiserValue[]): RaiserValue {
	const ctx = activeMetaCtx();
	if (ctx == null || args.length < 1) return raiserNil();
	const sym = boundSymOf(args[0]);
	if (sym == null) return queryError(ctx, "node is not a symbol");
	return raiserInt(sym.symbolKind as int64);
}

export function registerTypeQueryHostFns(): void {
	registerHostFn("msMetaBindSym", hostBindSym, HostCapability.Pure);
	registerHostFn("msMetaGetType", hostGetType, HostCapability.Pure);
	registerHostFn("msMetaGetImpl", hostGetImpl, HostCapability.Pure);
	registerHostFn("msMetaResolveType", hostResolveType, HostCapability.Pure);
	registerHostFn("msMetaTypeKind", hostTypeKind, HostCapability.Pure);
	registerHostFn("msMetaSameType", hostSameType, HostCapability.Pure);
	registerHostFn("msMetaSymKind", hostSymKind, HostCapability.Pure);
}
