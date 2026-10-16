// ECMAScript gives a module record one namespace object (GetModuleNamespace), so
// the type names the value: a read through it resolves like a qualified `ns.X`.

import { Node, NodeKind, MemberExprData, SymbolKind, Type, TypeKind } from "../../ast/node";
import { makeSymbol } from "../../checker/symbol";
import { getSysType } from "../../checker/types";
import { makeNumber } from "../../checker/literalNodes";
import { mapChildren } from "../walker";
import { makeIdentResolved } from "../util";

function isNamespaceIdent(n: Node): boolean {
	return n.kind == NodeKind.Identifier && n.resolvedSym != null && n.resolvedSym.symbolKind == SymbolKind.Module;
}

export function isNamespaceTyped(t: Type | null): boolean {
	return t != null && t.kind == TypeKind.Module;
}

function namespaceIdent(t: Type, at: Node): Node {
	const sym = makeSymbol("$ns", SymbolKind.Module, t, false);
	sym.modulePath = t.typeName;
	return makeIdentResolved(sym, at.location);
}

function lowerNode(n: Node): Node {
	if (n == null) return n;
	if (n.kind == NodeKind.MemberExpr) {
		const d = n.data as MemberExprData;
		if (isNamespaceIdent(d.object)) return n;
		if (isNamespaceTyped(d.object.nodeType) && d.object.kind == NodeKind.Identifier) {
			d.object = namespaceIdent(d.object.nodeType!, d.object);
			return n;
		}
	}
	if (isNamespaceIdent(n)) {
		const unit = makeNumber(1, n.location);
		unit.nodeType = getSysType(TypeKind.Uint8);
		return unit;
	}
	mapChildren(n, lowerNode);
	return n;
}

export function lowerNamespaceValues(program: Node): Node {
	return lowerNode(program);
}
