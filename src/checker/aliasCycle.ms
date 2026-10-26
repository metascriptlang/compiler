import { Symbol, SymbolKind, TypeAliasDeclData, Type, TypeKind } from "../ast/node";
import { CheckerContext, addError } from "./context";
import { assignType, errorType } from "./types";

function isIndirection(k: TypeKind): boolean {
	return match (k) {
		TypeKind.Ref | TypeKind.Ptr | TypeKind.Borrow | TypeKind.Sink | TypeKind.Lent
		| TypeKind.Var | TypeKind.Array | TypeKind.Span | TypeKind.Cursor => true,
		_ => false,
	};
}

function isStructural(k: TypeKind): boolean {
	return match (k) {
		TypeKind.Tuple | TypeKind.Function | TypeKind.SizedArray
		| TypeKind.Distinct | TypeKind.Alias | TypeKind.Varargs => true,
		_ => isIndirection(k),
	};
}

function isContainer(k: TypeKind): boolean {
	return match (k) {
		TypeKind.Tuple | TypeKind.Union | TypeKind.Struct | TypeKind.SizedArray
		| TypeKind.Distinct | TypeKind.Alias | TypeKind.Varargs => true,
		_ => false,
	};
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

function cycleMessage(name: string, root: Type, resolved: Type | null): string | null {
	const advice = "declare the recursive type as an interface or class";
	const onlyItself = resolved != null && resolved.kind == TypeKind.Inferred &&
		resolved.sym != null && resolved.sym.symbolKind == SymbolKind.TypeAlias;
	if (onlyItself) {
		return "illegal recursion in type '" + name + "': it is defined only in terms of itself — " + advice;
	}
	if (cyclic(root, false)) {
		return "illegal recursion in type '" + name + "': it refers to itself without passing an " +
			"interface, class, struct or union — " + advice;
	}
	if (cyclic(root, true)) {
		return "type '" + name + "' contains itself by value (infinite size) — " + advice +
			", or hold the link in an array";
	}
	return null;
}

export function refuseAliasCycle(
	ctx: CheckerContext,
	d: TypeAliasDeclData,
	sym: Symbol,
	resolved: Type | null,
): boolean {
	const root = sym.symbolType;
	if (root == null) return false;
	const message = cycleMessage(d.aliasName, root, resolved);
	if (message == null) return false;
	addError(ctx, message, d.nameLocation.line, d.nameLocation.column);
	assignType(root, errorType());
	return true;
}
