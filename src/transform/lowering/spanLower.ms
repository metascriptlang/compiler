// Span Lowering - Transforms HiddenStdConv (Array -> Span) into explicit struct initializers
//
// Pattern: Nim's lowerOpenArray in ccgexprs.nim (handled during emission, but we move to Transform)
//
// Array -> Span: ObjectLiteral(SpanType, { data: arr.p->data, len: arr.len })
// SizedArray -> Span: ObjectLiteral(SpanType, { data: arr.data, len: N })

import { Node, NodeKind, HiddenStdConvData, SourceLocation } from "../../ast/node";
import { TypeKind, numberType } from "../../checker/types";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeMember, makeObjectLiteral, makeNumber } from "../util";

export function spanLower(program: Node, ctx: TransformContext): Node {
	return walkNode(program, (node: Node): Node => {
		if (node.kind === NodeKind.HiddenStdConv || node.kind === NodeKind.HiddenSubConv) {
			const d = node.data as HiddenStdConvData;
			const targetType = d.convType;
			if (targetType === null) return node;

			if (targetType.kind === TypeKind.Span) {
				const srcType = d.convExpr.nodeType;
				if (srcType !== null) {
					const loc = node.location;
					if (srcType.kind === TypeKind.Array) {
						// Array -> Span: { data: arr.p->data, len: arr.len }
						// Note: C backend handles .p->data for Array member access
						const dataExpr = makeMember(d.convExpr, "data", loc);
						const lenExpr = makeMember(d.convExpr, "length", loc);
						const spanInit = makeObjectLiteral(["data", "len"], [dataExpr, lenExpr], loc);
						spanInit.nodeType = targetType;
						return spanInit;
					} else if (srcType.kind === TypeKind.SizedArray) {
						// SizedArray -> Span: { data: arr.data, len: N }
						const dataExpr = makeMember(d.convExpr, "data", loc);
						const lenExpr = makeNumber(srcType.typeFlags, loc);
						const spanInit = makeObjectLiteral(["data", "len"], [dataExpr, lenExpr], loc);
						spanInit.nodeType = targetType;
						return spanInit;
					}
				}
			}
		}
		return node;
	});
}
