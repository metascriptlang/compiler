import { Node, NodeKind, SizeofExprData } from "../../ast/node";
import { TransformContext } from "../context";
import { addError } from "../../checker/context";
import { walkNode } from "../walker";

export function refuseUnfoldedSizeofJS(program: Node, ctx: TransformContext): Node {
	walkNode(program, (node: Node): Node => refuseSizeof(node, ctx));
	return program;
}

function refuseSizeof(node: Node, ctx: TransformContext): Node {
	if (node.kind != NodeKind.SizeofExpr) return node;
	const d = node.data as SizeofExprData;
	if (d.sizeofResolved == null) return node;
	if (ctx.checkerCtx != null) {
		addError(ctx.checkerCtx, `'sizeof' has no compile-time layout for '${d.sizeofType}' on the js target`,
			node.location.line, node.location.column);
	}
	return node;
}
