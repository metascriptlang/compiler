import { Symbol, SymbolKind, TypeAliasDeclData, Type, TypeKind } from "../ast/node";
import { CheckerContext, addError } from "./context";
import { assignType, errorType } from "./types";

function isIndirection(k: TypeKind): boolean {
	return k == TypeKind.Ref || k == TypeKind.Ptr || k == TypeKind.Borrow || k == TypeKind.Sink || k == TypeKind.Lent
		|| k == TypeKind.Var || k == TypeKind.Array || k == TypeKind.Span || k == TypeKind.Cursor;
}

function isStructural(k: TypeKind): boolean {
	return isIndirection(k) || k == TypeKind.Tuple || k == TypeKind.Function || k == TypeKind.SizedArray
		|| k == TypeKind.Distinct || k == TypeKind.Alias || k == TypeKind.Varargs;
}

function isContainer(k: TypeKind): boolean {
	return k == TypeKind.Tuple || k == TypeKind.Union || k == TypeKind.Struct || k == TypeKind.SizedArray
		|| k == TypeKind.Distinct || k == TypeKind.Alias || k == TypeKind.Varargs;
}

function walkable(t: Type, byValue: boolean): boolean {
	if (t.kind == TypeKind.GenericInstance) return true;
	return byValue ? isContainer(t.kind) : isStructural(t.kind);
}

function reaches(t: Type | null, root: Type, byValue: boolean, seen: Type[]): boolean {
	if (t == null) return false;
	if (t == root) return true;
	if (seen.includes(t) || !walkable(t, byValue)) return false;
	seen.push(t);
	return reachesBelow(t, root, byValue, seen);
}

function reachesBelow(t: Type, root: Type, byValue: boolean, seen: Type[]): boolean {
	if (t.kind == TypeKind.GenericInstance) return reaches(t.typeExtra, root, byValue, seen);
	for (const c of t.typeChildren) {
		if (reaches(c, root, byValue, seen)) return true;
	}
	return reaches(t.typeReturn, root, byValue, seen);
}

function cyclic(root: Type, byValue: boolean): boolean {
	return walkable(root, byValue) && reachesBelow(root, root, byValue, []);
}

export function refuseAliasCycle(ctx: CheckerContext, d: TypeAliasDeclData, sym: Symbol, resolved: Type | null): boolean {
	const root = sym.symbolType;
	if (root == null) return false;
	const line = d.nameLocation.line;
	const col = d.nameLocation.column;
	const advice = "declare the recursive type as an interface or class";
	let message = "";
	if (resolved != null && resolved.kind == TypeKind.Inferred && resolved.sym != null && resolved.sym.symbolKind == SymbolKind.TypeAlias) {
		message = "illegal recursion in type '" + d.aliasName + "': it is defined only in terms of itself — " + advice;
	} else if (cyclic(root, false)) {
		message = "illegal recursion in type '" + d.aliasName + "': it refers to itself without passing an interface, class, struct or union — " + advice;
	} else if (cyclic(root, true)) {
		message = "type '" + d.aliasName + "' contains itself by value (infinite size) — " + advice + ", or hold the link in an array";
	}
	if (message == "") return false;
	addError(ctx, message, line, col);
	assignType(root, errorType());
	return true;
}
