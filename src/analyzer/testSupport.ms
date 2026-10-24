import { Node, NodeKind, Symbol, SymbolKind, IdentifierData, VariableDeclData, TryCatchStmtData } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { makeSymbol } from "../checker/symbol";
import { noneType } from "../checker/types";
import { parseInput } from "../transform/testUtil";

export function getBody(code: string): Node {
	const result = parseInput(code);
	if (!result.ok) return null as unknown as Node;
	return result.value;
}

export function makeTestSym(name: string): Symbol {
	return makeSymbol(name, SymbolKind.Variable, noneType(), false);
}

// Attaches `sym` to every Identifier named `name`, and to the VariableDecl or
// TryCatchStmt that declares it. Nested function bodies end the walk.
export function attachSymAll(node: Node, name: string, sym: Symbol): void {
	if (node == null) return;
	if (node.kind == NodeKind.Identifier) {
		if ((node.data as IdentifierData).name == name) node.resolvedSym = sym;
		return;
	}
	if (node.kind == NodeKind.VariableDecl) {
		if ((node.data as VariableDeclData).declName == name) node.resolvedSym = sym;
	}
	if (node.kind == NodeKind.TryCatchStmt) {
		if ((node.data as TryCatchStmtData).catchName == name) node.resolvedSym = sym;
	}
	if (node.kind == NodeKind.FunctionDecl
		|| node.kind == NodeKind.ArrowFunction
		|| node.kind == NodeKind.FunctionExpr) return;
	forEachChild(node, (c: Node): void => { attachSymAll(c, name, sym); });
}
