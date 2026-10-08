import {
	Node, NodeKind, NodeFlag, Type, TypeKind, Symbol, SymbolKind, ArrayAccessData, createNodeAt, TypeAssertionData,
	MemberExprData, HiddenStdConvData, BinaryExprData, ConditionalExprData, ObjectLiteralData, ArrayLiteralData,
	CallExprData, VariableDeclData, ReturnStmtData, FunctionDeclData, MethodDeclData, ConstructorDeclData,
	ArrowFunctionData, FunctionExprData, ProgramData,
} from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { hasFlag, SymbolFlag } from "./symbol";
import { skipModifier, peelTransparentInstance, typeDisplayName, isReadonlyView, createReadonlyView, isValueStorage } from "./types";
import { sameType, nonNullMemberOfNullable } from "./compat";
import { CheckerContext, addError } from "./context";
import { writeRefusal, WriteSite } from "./assignable";

function pointee(target: Type | null): Type | null {
	let dest = skipModifier(target);
	if (dest == null) return null;
	const nonNull = nonNullMemberOfNullable(dest);
	if (nonNull != null) dest = nonNull;
	dest = peelTransparentInstance(dest);
	return dest.kind == TypeKind.Ptr ? dest.typeReturn : null;
}

function bareSource(source: Type | null): Type | null {
	const src = skipModifier(source);
	return src != null ? peelTransparentInstance(src) : null;
}

function storedInline(t: Type): boolean {
	return isValueStorage(t) || t.kind == TypeKind.SizedArray;
}

export function pointerAddressElement(source: Type | null, target: Type | null): Type | null {
	const src = bareSource(source);
	const elem = pointee(target);
	if (src == null || elem == null) return null;
	if (src.kind == TypeKind.Ref || src.kind == TypeKind.Ptr || src.kind == TypeKind.Null) return null;
	if (src.kind == TypeKind.Span) {
		const item = skipModifier(src.typeReturn);
		if (item != null && item.kind == TypeKind.Ref) return null;
		return src.typeReturn != null && sameType(src.typeReturn, elem) ? src.typeReturn : null;
	}
	return storedInline(src) && sameType(src, elem) ? src : null;
}

export function nativeAddressSource(source: Type | null, target: Type | null): Type | null {
	const src = bareSource(source);
	const elem = pointee(target);
	if (src == null || elem == null || pointerAddressElement(source, target) != null) return null;
	return storedInline(src) ? src : null;
}

export function checkPointerAddress(ctx: CheckerContext, node: Node, expr: Node, target: Type): void {
	const source = bareSource(expr.nodeType);
	const dest = bareSource(target);
	if (source != null && dest != null && dest.kind == TypeKind.Span && dest.typeReturn != null) {
		let view = source;
		if (view.kind == TypeKind.Ref && view.typeReturn != null) view = peelTransparentInstance(view.typeReturn);
		if ((view.kind == TypeKind.Span || view.kind == TypeKind.Array || view.kind == TypeKind.SizedArray)
			&& view.typeReturn != null && !sameType(view.typeReturn, dest.typeReturn)) {
			addError(ctx, "cannot convert " + typeDisplayName(source) + " to " + typeDisplayName(target)
				+ ": a view keeps its element type; read bytes through `as Ptr<void> as Ptr<uint8>` on a native target", expr.location.line, expr.location.column);
		}
		return;
	}
	const elem = pointee(target);
	if (source == null || elem == null) return;
	if (source.kind == TypeKind.Span && source.typeReturn != null && sameType(source.typeReturn, elem)) {
		const item = skipModifier(source.typeReturn);
		if (item != null && item.kind == TypeKind.Ref) {
			addError(ctx, "cannot convert " + typeDisplayName(source) + " to " + typeDisplayName(target)
				+ ": the view stores reference slots, but this pointer type addresses their pointees", expr.location.line, expr.location.column);
			return;
		}
	}
	let handle = source;
	if (handle.kind == TypeKind.Ref && handle.typeReturn != null) handle = peelTransparentInstance(handle.typeReturn);
	if ((handle.kind == TypeKind.Array || handle.kind == TypeKind.String) && !sameType(source, elem) && elem.kind != TypeKind.Void) {
		addError(ctx, "cannot convert " + typeDisplayName(source) + " to " + typeDisplayName(target)
			+ ": a " + typeDisplayName(source) + " is a handle to heap storage, so its address holds no "
			+ typeDisplayName(elem) + "; reach its elements through `as Span<…>` first", expr.location.line, expr.location.column);
		return;
	}
	const element = pointerAddressElement(expr.nodeType, target);
	if (element == null && nativeAddressSource(expr.nodeType, target) == null) return;
	let place = expr;
	if (element != null && source.kind == TypeKind.Span) {
		const index = createNodeAt(NodeKind.NumberLiteral, { value: 0, isFloat: false, intVal: 0 as int64, outOfRangeText: "", isBitPattern: false }, expr.location);
		place = createNodeAt(NodeKind.ArrayAccess, { array: expr, index } as ArrayAccessData, expr.location);
	} else if (expr.kind != NodeKind.Identifier && expr.kind != NodeKind.MemberExpr
		&& expr.kind != NodeKind.ArrayAccess && expr.kind != NodeKind.HiddenDeref) {
		addError(ctx, "cannot take a typed pointer: expression has no address", expr.location.line, expr.location.column);
		return;
	}
	const refusal = writeRefusal(place, WriteSite.RefArg);
	if (refusal == "" || node.nodeType == null || isReadonlyView(node.nodeType)) return;
	const view = createReadonlyView(node.nodeType);
	if (isReadonlyView(view)) {
		node.nodeType = view;
		return;
	}
	addError(ctx, refusal, expr.location.line, expr.location.column);
}

interface EscapeUnit {
	ctx: CheckerContext;
	tainted: Symbol[];
	origin: Node[];
	changed: boolean;
	report: boolean;
}

export function isAddressTaking(node: Node): boolean {
	if (node.kind != NodeKind.TypeAssertion || node.nodeType == null) return false;
	const expr = (node.data as TypeAssertionData).asExpr;
	if (expr == null) return false;
	return pointerAddressElement(expr.nodeType, node.nodeType) != null || nativeAddressSource(expr.nodeType, node.nodeType) != null;
}

function throughHeap(t: Type | null): boolean {
	const held = skipModifier(t);
	if (held == null) return true;
	return held.kind == TypeKind.Ref || held.kind == TypeKind.Ptr || held.kind == TypeKind.Span || held.kind == TypeKind.Unknown;
}

function frameRoot(node: Node | null): Symbol | null {
	let n = node;
	while (n != null) {
		match (n.kind) {
			NodeKind.Identifier => {
				const sym = n.resolvedSym;
				if (sym == null || hasFlag(sym, SymbolFlag.Global) || throughHeap(sym.symbolType)) return null;
				if (sym.symbolKind == SymbolKind.Parameter && sym.symbolType != null && sym.symbolType.kind == TypeKind.Var) return null;
				if (sym.symbolKind != SymbolKind.Variable && sym.symbolKind != SymbolKind.Parameter) return null;
				return sym;
			},
			NodeKind.MemberExpr => {
				const object = (n.data as MemberExprData).object;
				if (throughHeap(object.nodeType)) return null;
				n = object;
			},
			NodeKind.ArrayAccess => {
				const array = (n.data as ArrayAccessData).array;
				if (throughHeap(array.nodeType)) return null;
				n = array;
			},
			NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => { n = (n.data as HiddenStdConvData).convExpr; },
			_ => { return null; },
		};
	}
	return null;
}

function isTainted(u: EscapeUnit, sym: Symbol | null): boolean {
	if (sym == null) return false;
	for (const s of u.tainted) { if (s == sym) return true; }
	return false;
}

function holdsPointer(t: Type | null, depth: int32 = 0): boolean {
	if (t == null || depth > 8) return true;
	return match (t.kind) {
		TypeKind.Ptr | TypeKind.Unknown | TypeKind.GenericParam => true,
		TypeKind.Struct | TypeKind.Tuple | TypeKind.Union | TypeKind.Result => {
			for (const c of t.typeChildren) {
				if (holdsPointer(c, depth + 1)) return true;
			}
			return false;
		},
		TypeKind.SizedArray | TypeKind.Array | TypeKind.Alias | TypeKind.Distinct => holdsPointer(t.typeReturn, depth + 1),
		TypeKind.GenericInstance => t.typeReturn != null ? holdsPointer(t.typeReturn, depth + 1) : false,
		_ => false,
	};
}

function frameAddress(u: EscapeUnit, node: Node | null): Node | null {
	if (node == null || !holdsPointer(node.nodeType)) return null;
	return match (node.kind) {
		NodeKind.Identifier => {
			for (let i = 0; i < u.tainted.length; i += 1) {
				if (u.tainted[i] == node.resolvedSym) return u.origin[i];
			}
			return null;
		},
		NodeKind.TypeAssertion => {
			if (isAddressTaking(node) && frameRoot((node.data as TypeAssertionData).asExpr) != null) return node;
			return frameAddress(u, (node.data as TypeAssertionData).asExpr);
		},
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => frameAddress(u, (node.data as HiddenStdConvData).convExpr),
		NodeKind.MemberExpr => frameAddress(u, (node.data as MemberExprData).object),
		NodeKind.ArrayAccess => frameAddress(u, (node.data as ArrayAccessData).array),
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			if (d.operator != "+" && d.operator != "-") return null;
			const left = frameAddress(u, d.left);
			return left != null ? left : frameAddress(u, d.right);
		},
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			const yes = frameAddress(u, d.ternaryConsequent);
			return yes != null ? yes : frameAddress(u, d.ternaryAlternate);
		},
		NodeKind.ObjectLiteral => {
			for (const p of (node.data as ObjectLiteralData).properties) {
				const hit = frameAddress(u, p);
				if (hit != null) return hit;
			}
			return null;
		},
		NodeKind.ArrayLiteral => {
			for (const e of (node.data as ArrayLiteralData).elements) {
				const hit = frameAddress(u, e);
				if (hit != null) return hit;
			}
			return null;
		},
		_ => null,
	};
}

function taint(u: EscapeUnit, sym: Symbol | null, origin: Node): void {
	if (sym == null || isTainted(u, sym)) return;
	u.tainted.push(sym);
	u.origin.push(origin);
	u.changed = true;
}

function escapeError(u: EscapeUnit, origin: Node, into: string, at: Node): void {
	if (!u.report) return;
	const expr = (origin.data as TypeAssertionData).asExpr;
	const root = frameRoot(expr);
	const name = root != null ? root.name : "a local";
	addError(u.ctx, `'${name}' escapes its stack frame: the address taken at ${origin.location.line}:${origin.location.column} reaches ${into}, which outlives the call`, at.location.line, at.location.column);
}

function storeTarget(u: EscapeUnit, target: Node, origin: Node, at: Node): void {
	if (target.kind == NodeKind.Identifier) {
		const sym = target.resolvedSym;
		if (sym == null) return;
		if (hasFlag(sym, SymbolFlag.Global)) { escapeError(u, origin, `module-level '${sym.name}'`, at); return; }
		if (sym.symbolKind == SymbolKind.Parameter && sym.symbolType != null && sym.symbolType.kind == TypeKind.Var) {
			escapeError(u, origin, `the caller's '${sym.name}'`, at);
			return;
		}
		taint(u, sym, origin);
		return;
	}
	const root = frameRoot(target);
	if (root != null) { taint(u, root, origin); return; }
	escapeError(u, origin, "heap storage", at);
}

function sinkFormal(t: Type | null): boolean {
	return t != null && t.kind == TypeKind.Sink;
}

function escapeCall(u: EscapeUnit, node: Node): void {
	const d = node.data as CallExprData;
	const sym = node.resolvedSym;
	const fnType = sym != null && sym.symbolType != null && sym.symbolType.kind == TypeKind.Function ? sym.symbolType : null;
	if (fnType == null) return;
	const offset: int32 = node.flags.has(NodeFlag.ExtCall) && !node.flags.has(NodeFlag.ExtStatic) ? 1 : 0;
	for (let i = 0; i < d.arguments.length; i += 1) {
		const fi = i + offset;
		if (fi >= fnType.typeChildren.length || !sinkFormal(fnType.typeChildren[fi])) continue;
		const origin = frameAddress(u, d.arguments[i]);
		if (origin != null) escapeError(u, origin, "a sink argument", d.arguments[i]);
	}
}

function escapeWalk(u: EscapeUnit, node: Node | null): void {
	if (node == null) return;
	match (node.kind) {
		NodeKind.FunctionDecl | NodeKind.ArrowFunction | NodeKind.FunctionExpr | NodeKind.ClassDecl
			| NodeKind.MethodDecl | NodeKind.ConstructorDecl | NodeKind.TestDecl => { return; },
		NodeKind.VariableDecl => {
			const origin = frameAddress(u, (node.data as VariableDeclData).initializer);
			if (origin != null) {
				if (node.resolvedSym != null && hasFlag(node.resolvedSym, SymbolFlag.Global)) {
					escapeError(u, origin, `module-level '${node.resolvedSym.name}'`, node);
				} else {
					taint(u, node.resolvedSym, origin);
				}
			}
		},
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			if (d.operator == "=") {
				const origin = frameAddress(u, d.right);
				if (origin != null) storeTarget(u, d.left, origin, node);
			}
		},
		NodeKind.ReturnStmt => {
			const origin = frameAddress(u, (node.data as ReturnStmtData).argument);
			if (origin != null) escapeError(u, origin, "the return value", node);
		},
		NodeKind.CallExpr => escapeCall(u, node),
		_ => {},
	};
	forEachChild(node, (child: Node): void => { escapeWalk(u, child); });
}

function escapeUnit(ctx: CheckerContext, body: Node | null): void {
	if (body == null) return;
	const u: EscapeUnit = { ctx, tainted: [], origin: [], changed: true, report: false };
	let rounds = 0;
	while (u.changed && rounds < 8) {
		u.changed = false;
		escapeWalk(u, body);
		rounds += 1;
	}
	u.report = true;
	escapeWalk(u, body);
}

function escapeScan(ctx: CheckerContext, node: Node | null): void {
	if (node == null) return;
	match (node.kind) {
		NodeKind.FunctionDecl => escapeUnit(ctx, (node.data as FunctionDeclData).fnBody),
		NodeKind.MethodDecl => escapeUnit(ctx, (node.data as MethodDeclData).methodBody),
		NodeKind.ConstructorDecl => escapeUnit(ctx, (node.data as ConstructorDeclData).ctorBody),
		NodeKind.ArrowFunction => escapeUnit(ctx, (node.data as ArrowFunctionData).arrowBody),
		NodeKind.FunctionExpr => escapeUnit(ctx, (node.data as FunctionExprData).funcExprBody),
		_ => {},
	};
	forEachChild(node, (child: Node): void => { escapeScan(ctx, child); });
}

export function checkPointerEscapesIn(ctx: CheckerContext, routine: Node): void {
	escapeScan(ctx, routine);
}

export function checkPointerEscapes(ctx: CheckerContext, program: Node): void {
	if (program == null || program.kind != NodeKind.Program) return;
	for (const stmt of (program.data as ProgramData).programStmts) { escapeScan(ctx, stmt); }
}
