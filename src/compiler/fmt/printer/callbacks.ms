// Printer Callbacks — breaks circular dependency between sub-printers
// Same pattern as parser/statements/callbacks.ms.

import { Node, NodeKind, ExprStmtData } from "../../../ast/node";
import { FormatOptions } from "../options";
import { Doc, docNil } from "../doc";

export type NodePrinterFn = (node: Node, options: FormatOptions) => Doc;

let nodePrinterFn: NodePrinterFn = (node: Node, options: FormatOptions): Doc => {
	return docNil();
};

export function registerNodePrinter(fn: NodePrinterFn): void {
	nodePrinterFn = fn;
}

let statementExpression: Node | null = null;

export function isStatementExpression(node: Node): boolean {
	return statementExpression == node;
}

export function callPrintNode(node: Node, options: FormatOptions): Doc {
	if (node != null && node.kind == NodeKind.ExprStmt) statementExpression = (node.data as ExprStmtData).expr;
	return nodePrinterFn(node, options);
}
