// `x.kind === "circle"` and `switch (x.kind)` over a union told apart by a literal field compare its `_tag` on C.

import { Node, NodeKind, Type, TypeKind, BinaryExprData, MemberExprData, SwitchStmtData, SwitchCaseData, HiddenDerefData, HiddenStdConvData, StringLiteralData, BooleanLiteralData, NumberLiteralData, UnaryExprData } from "../../ast/node";
import { peelToStructOrUnion, skipModifier, unwrapRefNullUnion, literalTagDiscriminant, findFieldInVariant, findVariantByStringDiscriminant, findVariantByNumberDiscriminant, findVariantByBooleanDiscriminant, int32Type, booleanType } from "../../checker/types";
import { storesUnionTag } from "../../checker/fit";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeBinary, makeMember, makeNumber } from "../util";

const NOT_A_LITERAL: int32 = -2;

export function lowerDiscriminantTags(program: Node, ctx: TransformContext): Node {
	return walkNode(program, foldDispatch);
}

function foldDispatch(node: Node): Node {
	if (node.kind == NodeKind.SwitchStmt) {
		retagSwitch(node.data as SwitchStmtData);
		return node;
	}
	if (node.kind != NodeKind.BinaryExpr) return node;
	const d = node.data as BinaryExprData;
	const op = d.operator;
	if (op != "===" && op != "==" && op != "!==" && op != "!=") return node;
	const leftUnion = taggedUnionRead(d.left);
	const read = leftUnion != null ? d.left : d.right;
	const lit = leftUnion != null ? d.right : d.left;
	const union = leftUnion != null ? leftUnion : taggedUnionRead(d.right);
	if (union == null) return node;
	const arm = armNamedBy(union, (read.data as MemberExprData).property, lit);
	if (arm < 0) return node;
	const same = makeBinary(tagOf(read), op == "===" || op == "==" ? "==" : "!=", armNumber(arm, node), node.location);
	same.nodeType = booleanType();
	return same;
}

function retagSwitch(d: SwitchStmtData): void {
	const union = taggedUnionRead(d.switchDisc);
	if (union == null) return;
	const property = (d.switchDisc.data as MemberExprData).property;
	const arms: int32[][] = [];
	for (const c of d.switchCases) {
		const tests: int32[] = [];
		for (const test of (c.data as SwitchCaseData).caseTests) {
			const arm = armNamedBy(union, property, test);
			if (arm < 0) return;
			tests.push(arm);
		}
		arms.push(tests);
	}
	for (let ci = 0; ci < d.switchCases.length; ci += 1) {
		const cd = d.switchCases[ci].data as SwitchCaseData;
		for (let ti = 0; ti < cd.caseTests.length; ti += 1) cd.caseTests[ti] = armNumber(arms[ci][ti], cd.caseTests[ti]);
	}
	d.switchDisc = tagOf(d.switchDisc);
}

function tagOf(read: Node): Node {
	const tag = makeMember((read.data as MemberExprData).object, "_tag", read.location);
	tag.nodeType = int32Type();
	return tag;
}

function armNumber(arm: int32, at: Node): Node {
	const n = makeNumber(arm, at.location);
	n.nodeType = int32Type();
	return n;
}

function taggedUnionRead(n: Node): Type | null {
	if (n.kind != NodeKind.MemberExpr) return null;
	const md = n.data as MemberExprData;
	const held = peelToStructOrUnion(skipModifier(md.object.nodeType));
	if (held == null || held.kind != TypeKind.Union) return null;
	const u = declaredUnionOf(md.object);
	if (u == null || u.kind != TypeKind.Union || u.typeChildren.length < 2 || unwrapRefNullUnion(u) != null || storesUnionTag(u)) return null;
	if (literalTagDiscriminant(u) != md.property) return null;
	const field = findFieldInVariant(u.typeChildren[0], md.property);
	if (field == null || (field.kind != TypeKind.StringLiteral && field.kind != TypeKind.NumberLiteral && field.kind != TypeKind.BooleanLiteral)) return null;
	return u;
}

function declaredUnionOf(object: Node): Type | null {
	let ref = object;
	while (ref.kind == NodeKind.HiddenDeref) ref = (ref.data as HiddenDerefData).expr;
	const declared = (ref.kind == NodeKind.Identifier || ref.kind == NodeKind.MemberExpr) && ref.resolvedSym != null ? ref.resolvedSym.symbolType : object.nodeType;
	return peelToStructOrUnion(skipModifier(declared));
}

function armNamedBy(union: Type, disc: string, written: Node): int32 {
	let lit = written;
	while (lit.kind == NodeKind.HiddenSubConv || lit.kind == NodeKind.HiddenStdConv) lit = (lit.data as HiddenStdConvData).convExpr;
	if (lit.kind == NodeKind.StringLiteral) return findVariantByStringDiscriminant(union, disc, (lit.data as StringLiteralData).value);
	if (lit.kind == NodeKind.BooleanLiteral) return findVariantByBooleanDiscriminant(union, disc, (lit.data as BooleanLiteralData).boolValue);
	const negated = lit.kind == NodeKind.UnaryExpr && (lit.data as UnaryExprData).unaryOp == "-";
	const operand = negated ? (lit.data as UnaryExprData).operand : lit;
	if (operand.kind != NodeKind.NumberLiteral) return NOT_A_LITERAL;
	const nd = operand.data as NumberLiteralData;
	const value = nd.isFloat ? nd.value : nd.intVal as number;
	return findVariantByNumberDiscriminant(union, disc, negated ? 0 - value : value);
}
