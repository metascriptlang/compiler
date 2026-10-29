// Conditional expression layout: the test, then `?` consequent and `:` alternate indented under it,
// a chain of nested conditionals breaking together as one group.

import {
	Node, NodeKind, ConditionalExprData, CallExprData, MemberExprData, ArrayAccessData, TypeAssertionData,
	BinaryExprData, UnaryExprData, YieldExprData, ReturnStmtData, ThrowStmtData, VariableDeclData, DestructuringDeclData,
	NewExprData, PropertyDeclData,
} from "../../../ast/node";
import { isAssignOp } from "../../../ast/operators";
import { FormatOptions } from "../options";
import { Doc, docText, docGroup, docIndent, docLine, docSoftLine } from "../doc";
import { callPrintNode, printedAncestor, pushPrinted, popPrinted, keepsWrittenParensUnder } from "./callbacks";
import { hasCommentsOutside } from "./commentDocs";

enum Slot {
	Root,
	Test,
	Consequent,
	Alternate,
}

function slotOf(node: Node, parent: Node | null): Slot {
	if (parent == null || parent.kind != NodeKind.ConditionalExpr) return Slot.Root;
	const d = parent.data as ConditionalExprData;
	if (d.ternaryCondition == node) return Slot.Test;
	return d.ternaryAlternate == node ? Slot.Alternate : Slot.Consequent;
}

function printsInline(child: Node): boolean {
	return child.kind == NodeKind.ConditionalExpr && !keepsWrittenParensUnder(child, printedAncestor(0)) && !hasCommentsOutside(child);
}

function branchParts(child: Node, slot: Slot, options: FormatOptions): Doc[] {
	if (!printsInline(child)) return [callPrintNode(child, options)];
	pushPrinted(child);
	const parts = conditionalParts(child, slot, options);
	popPrinted();
	return parts;
}

function conditionalParts(node: Node, slot: Slot, options: FormatOptions): Doc[] {
	const d = node.data as ConditionalExprData;
	const test = callPrintNode(d.ternaryCondition, options);
	const tail: Doc[] = [
		docLine(),
		docText("? "),
		docIndent(branchParts(d.ternaryConsequent, Slot.Consequent, options)),
		docLine(),
		docText(": "),
		docIndent(branchParts(d.ternaryAlternate, Slot.Alternate, options)),
	];
	const head = slot == Slot.Alternate ? docIndent([test]) : test;
	return slot == Slot.Root || slot == Slot.Test ? [head, docIndent(tail)] : [head, ...tail];
}

function chainStep(anc: Node, expr: Node): boolean {
	return match (anc.kind) {
		NodeKind.CallExpr => (anc.data as CallExprData).callee == expr,
		NodeKind.MemberExpr => (anc.data as MemberExprData).object == expr,
		NodeKind.ArrayAccess => (anc.data as ArrayAccessData).array == expr,
		NodeKind.TypeAssertion => (anc.data as TypeAssertionData).asType == "!" && (anc.data as TypeAssertionData).asExpr == expr,
		_ => false,
	};
}

function isValueOf(parent: Node, expr: Node): boolean {
	return match (parent.kind) {
		NodeKind.VariableDecl => (parent.data as VariableDeclData).initializer == expr,
		NodeKind.DestructuringDecl => (parent.data as DestructuringDeclData).destrInit == expr,
		NodeKind.PropertyDecl => (parent.data as PropertyDeclData).propInitializer == expr,
		NodeKind.ReturnStmt => (parent.data as ReturnStmtData).argument == expr,
		NodeKind.ThrowStmt => (parent.data as ThrowStmtData).throwArg == expr,
		NodeKind.UnaryExpr => (parent.data as UnaryExprData).operand == expr,
		NodeKind.YieldExpr => (parent.data as YieldExprData).yieldArg == expr,
		NodeKind.BinaryExpr => isAssignOp((parent.data as BinaryExprData).operator) && (parent.data as BinaryExprData).right == expr,
		_ => false,
	};
}

function insideMemberChainValue(node: Node): boolean {
	let expr = node;
	let level = 1;
	let parent: Node | null = null;
	while (true) {
		const anc = printedAncestor(level);
		if (anc == null) return false;
		if (chainStep(anc, expr)) {
			expr = anc;
			level += 1;
			continue;
		}
		const wraps = (anc.kind == NodeKind.NewExpr && (anc.data as NewExprData).newCallee == expr)
			|| (anc.kind == NodeKind.TypeAssertion && (anc.data as TypeAssertionData).asExpr == expr);
		if (wraps) {
			expr = anc;
			parent = printedAncestor(level + 1);
		} else {
			parent = anc;
		}
		break;
	}
	if (expr == node || parent == null) return false;
	return isValueOf(parent, expr);
}

function isStaticMemberObject(parent: Node | null, node: Node): boolean {
	return parent != null && parent.kind == NodeKind.MemberExpr && (parent.data as MemberExprData).object == node;
}

export function printConditionalExpr(node: Node, options: FormatOptions): Doc {
	const parent = printedAncestor(1);
	const slot = slotOf(node, parent);
	const parts = conditionalParts(node, slot, options);
	if (slot == Slot.Test) return docGroup([docIndent([docSoftLine(), ...parts]), docSoftLine()]);
	if (slot != Slot.Root) return docGroup(parts);
	const extraIndent = insideMemberChainValue(node);
	if (isStaticMemberObject(parent, node) && !extraIndent) parts.push(docSoftLine());
	const grouped = docGroup(parts);
	return extraIndent ? docGroup([docIndent([docSoftLine(), grouped]), docSoftLine()]) : grouped;
}
