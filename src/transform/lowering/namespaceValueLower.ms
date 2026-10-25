// ECMAScript gives a module record one namespace object (GetModuleNamespace), so
// the type names the value: a read through it resolves like a qualified `ns.X`.

import { Node, NodeKind, MemberExprData, CallExprData, SymbolKind, Type, TypeKind } from "../../ast/node";
import { makeSymbol } from "../../checker/symbol";
import { getSysType } from "../../checker/types";
import { makeNumber, makeString } from "../../checker/literalNodes";
import { DYNAMIC_IMPORT } from "../../checker/importCall";
import { mangleModuleName, buildModuleNameRoots } from "../../codegen/c/names";
import { mapChildren } from "../walker";
import { makeCall, makeIdentResolved, runtimeRef } from "../util";

export function isNamespaceRef(n: Node): boolean {
	if (n.resolvedSym == null || n.resolvedSym.symbolKind != SymbolKind.Module) return false;
	return n.kind == NodeKind.Identifier || (n.kind == NodeKind.MemberExpr && isNamespaceRef((n.data as MemberExprData).object));
}

export function isNamespaceTyped(t: Type | null): boolean {
	return t != null && t.kind == TypeKind.Module;
}

function namespaceIdent(t: Type, at: Node): Node {
	const sym = makeSymbol("$ns", SymbolKind.Module, t, false);
	sym.modulePath = t.typeName;
	return makeIdentResolved(sym, at.location);
}

function dynamicImportTarget(n: Node): string {
	if (n.kind != NodeKind.CallExpr) return "";
	const sym = (n.data as CallExprData).callee.resolvedSym;
	return sym != null && sym.builtinKind == DYNAMIC_IMPORT ? sym.modulePath : "";
}

function lowerNode(n: Node): Node {
	if (n == null) return n;
	const target = dynamicImportTarget(n);
	if (target != "") {
		const call = makeCall(runtimeRef("msModuleImport", n.location), [makeString(mangleModuleName(buildModuleNameRoots(), target), n.location)], n.location);
		call.nodeType = n.nodeType;
		return call;
	}
	if (isNamespaceRef(n)) {
		const unit = makeNumber(1, n.location);
		unit.nodeType = getSysType(TypeKind.Uint8);
		return unit;
	}
	if (n.kind == NodeKind.MemberExpr) {
		const d = n.data as MemberExprData;
		if (isNamespaceRef(d.object)) return n;
		if (isNamespaceTyped(d.object.nodeType) && d.object.kind == NodeKind.Identifier) {
			d.object = namespaceIdent(d.object.nodeType!, d.object);
			return n;
		}
	}
	mapChildren(n, lowerNode);
	return n;
}

export function lowerNamespaceValues(program: Node): Node {
	return lowerNode(program);
}
