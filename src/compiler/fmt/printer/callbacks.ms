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

const printing: Node[] = [];

export function printedAncestor(levels: int32): Node | null {
	const at = printing.length - 1 - levels;
	return at >= 0 ? printing[at] : null;
}

export function pushPrinted(node: Node): void {
	printing.push(node);
}

export function popPrinted(): void {
	printing.pop();
}

export function callPrintNode(node: Node, options: FormatOptions): Doc {
	if (node == null) return nodePrinterFn(node, options);
	if (node.kind == NodeKind.ExprStmt) statementExpression = (node.data as ExprStmtData).expr;
	printing.push(node);
	const doc = nodePrinterFn(node, options);
	printing.pop();
	return doc;
}
