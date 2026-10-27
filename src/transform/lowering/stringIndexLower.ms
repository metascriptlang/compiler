// A string index read on the Raiser makes a new one-character string, like `charAt`. As an
// `ArrayAccess` the analyzer takes it for a borrowed element and never destroys it, so the read
// becomes the `charAt` call whose result it already owns. A written index (`s[i] = c`) stays for
// stringOpLower.

import { Node, NodeKind, ArrayAccessData, BinaryExprData, UpdateExprData, TypeKind } from "../../ast/node";
import { isStringLike, peelTransparentInstance } from "../../checker/types";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeCall, makeMember } from "../util";
import { isAssignOp } from "../../ast/operators";

function isStringTyped(node: Node): boolean {
	let t = node.nodeType;
	if (t == null) return false;
	if (t.kind == TypeKind.Var && t.typeReturn != null) t = t.typeReturn;
	return isStringLike(peelTransparentInstance(t));
}

function isRangeIndex(index: Node): boolean {
	if (index.kind != NodeKind.BinaryExpr) return false;
	const op = (index.data as BinaryExprData).operator;
	return op == ".." || op == "...";
}

export function lowerStringIndexReads(program: Node, ctx: TransformContext): Node {
	const written: Node[] = [];
	walkNode(program, (n: Node): Node => {
		if (n.kind == NodeKind.BinaryExpr && isAssignOp((n.data as BinaryExprData).operator)) written.push((n.data as BinaryExprData).left);
		if (n.kind == NodeKind.UpdateExpr) written.push((n.data as UpdateExprData).updateArg);
		return n;
	});
	return walkNode(program, (n: Node): Node => {
		if (n.kind != NodeKind.ArrayAccess) return n;
		const d = n.data as ArrayAccessData;
		if (!isStringTyped(d.array) || isRangeIndex(d.index) || written.includes(n)) return n;
		const call = makeCall(makeMember(d.array, "charAt", n.location), [d.index], n.location);
		call.nodeType = n.nodeType;
		return call;
	});
}
