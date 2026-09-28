import { Node, NodeKind, NodeFlag } from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { GcMode } from "../../checker/context";

export function lowerDownConversions(program: Node, ctx: TransformContext): Node {
	const headersCarryType = ctx.checkerCtx == null || ctx.checkerCtx.gcMode != GcMode.Manual;
	const checks = ctx.objChecks && headersCarryType;
	return walkNode(program, (node: Node): Node => {
		if (node.kind == NodeKind.TypeAssertion) {
			if (!checks && node.flags.has(NodeFlag.ObjCheck)) node.flags = node.flags.excl(NodeFlag.ObjCheck);
		}
		return node;
	});
}
