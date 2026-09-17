// Assert Lowering — every assert becomes its failure branch before the analyzer runs

import { Node, NodeKind, AssertStmtData } from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeIdent, makeCall, makeUnary, makeBlock, makeExprStmt, makeIf, makeString, makeNumber, runtimeRef } from "../util";

export function lowerAssert(program: Node, ctx: TransformContext): Node {
	return walkNode(program, (node: Node): Node => {
		if (node.kind != NodeKind.AssertStmt) return node;
		const d = node.data as AssertStmtData;
		const loc = node.location;
		const message = d.assertMessageExpr != null
			? d.assertMessageExpr
			: makeString(d.assertMessage.length > 0 ? d.assertMessage : d.assertSource, loc);
		const text = makeCall(runtimeRef("msStringToCString", loc), [message], loc);
		const fail = makeCall(runtimeRef("msAssertFail", loc), [text, makeIdent("__FILE__", loc), makeNumber(loc.line, loc)], loc);
		return makeIf(makeUnary("!", d.assertExpr, loc), makeBlock([makeExprStmt(fail, loc)], loc), null, loc);
	});
}
