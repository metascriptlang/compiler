// Printer Callbacks — breaks circular dependency between sub-printers
// Same pattern as parser/statements/callbacks.ms.

import { Node, NodeKind, NodeFlag, ExprStmtData, ConditionalExprData, BinaryExprData, CallExprData, VariableDeclData, DestructuringDeclData, ArrayLiteralData, MemberExprData, ArrayAccessData, ReturnStmtData, ThrowStmtData } from "../../../ast/node";
import { isAssignOp } from "../../../ast/operators";
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

function isPlainBinary(node: Node): boolean {
	if (node.kind != NodeKind.BinaryExpr) return false;
	const op = (node.data as BinaryExprData).operator;
	return !isAssignOp(op) && op != "|>";
}

function isPlainValueOf(parent: Node, node: Node): boolean {
	return match (parent.kind) {
		NodeKind.ReturnStmt => (parent.data as ReturnStmtData).argument == node,
		NodeKind.ThrowStmt => (parent.data as ThrowStmtData).throwArg == node,
		NodeKind.VariableDecl => (parent.data as VariableDeclData).initializer == node,
		NodeKind.DestructuringDecl => (parent.data as DestructuringDeclData).destrInit == node,
		NodeKind.CallExpr => (parent.data as CallExprData).arguments.includes(node),
		NodeKind.ArrayLiteral => (parent.data as ArrayLiteralData).elements.includes(node),
		_ => false,
	};
}

function isBranchOf(parent: Node, node: Node): boolean {
	if (parent.kind != NodeKind.ConditionalExpr) return false;
	const d = parent.data as ConditionalExprData;
	return d.ternaryConsequent == node || d.ternaryAlternate == node;
}

function bindsLooserThanChain(parent: Node, node: Node): boolean {
	return match (parent.kind) {
		NodeKind.MemberExpr => (parent.data as MemberExprData).object == node,
		NodeKind.CallExpr => (parent.data as CallExprData).callee == node,
		_ => false,
	};
}

function groupsOptionalChain(node: Node): boolean {
	let cur = node;
	while (true) {
		if (cur.flags.has(NodeFlag.OptionalLink)) return true;
		if (cur.kind == NodeKind.MemberExpr) {
			const m = cur.data as MemberExprData;
			if (m.isOptional) return true;
			cur = m.object;
		} else if (cur.kind == NodeKind.CallExpr) cur = (cur.data as CallExprData).callee;
		else if (cur.kind == NodeKind.ArrayAccess) cur = (cur.data as ArrayAccessData).array;
		else return false;
	}
}

export function keepsWrittenParensUnder(node: Node, parent: Node | null): boolean {
	if (!node.flags.has(NodeFlag.Parenthesized)) return false;
	if (parent == null) return true;
	if (isPlainBinary(node)) return !isPlainValueOf(parent, node);
	return match (node.kind) {
		NodeKind.Identifier | NodeKind.BooleanLiteral | NodeKind.NullLiteral => false,
		NodeKind.MemberExpr => !(bindsLooserThanChain(parent, node) && !groupsOptionalChain(node)),
		NodeKind.ConditionalExpr => !isBranchOf(parent, node),
		_ => true,
	};
}

export function keepsWrittenParens(node: Node): boolean {
	return keepsWrittenParensUnder(node, printedAncestor(1));
}
