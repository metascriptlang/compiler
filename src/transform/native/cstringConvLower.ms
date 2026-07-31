// Target-aware: C emits ms* helpers; JS emits nothing (cstring ≡ string).
// Runs before analyzer (DRC) so the conversion is a plain CallExpr by then.

import { Node, NodeKind, HiddenStdConvData, CallExprData, IdentifierData, TypeKind } from "../../ast/node";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeCall, makeIdent } from "../util";

function inverseOf(fn: string): string {
	return match (fn) {
		"msStringToCString" => "msStringFromCStr",
		"msStringFromCStr" => "msStringToCString",
		_ => "",
	};
}

function peelInverse(call: Node, fn: string): Node {
	if (call.kind !== NodeKind.CallExpr) return call;
	const cd = call.data as CallExprData;
	if (cd.callee.kind !== NodeKind.Identifier) return call;
	const innerName = (cd.callee.data as IdentifierData).name;
	if (innerName !== inverseOf(fn)) return call;
	if (cd.arguments.length !== 1) return call;
	return cd.arguments[0];
}

export function lowerCStringConv(program: Node, ctx: TransformContext): Node {
	return walkNode(program, (node: Node): Node => {
		if (node.kind !== NodeKind.HiddenStdConv && node.kind !== NodeKind.HiddenSubConv) return node;
		const d = node.data as HiddenStdConvData;
		if (d.convType === null) return node;
		const srcType = d.convExpr.nodeType;
		const loc = node.location;

		const matchForward = d.convType.kind === TypeKind.CString
			&& srcType !== null
			&& (srcType.kind === TypeKind.String || srcType.kind === TypeKind.StringLiteral);
		const matchReverse = d.convType.kind === TypeKind.String
			&& srcType !== null
			&& srcType.kind === TypeKind.CString;

		if (!matchForward && !matchReverse) return node;

		// cstring ≡ string on JS (STRING-CONTRACT §1) — no conversion exists.
		if (ctx.jsBackend) return d.convExpr;

		const fn = matchForward ? "msStringToCString" : "msStringFromCStr";

		// Round-trip optimization: `fn(inverse(x))` ≡ `x`. Walker is bottom-up,
		// so a nested inverse conversion has already been rewritten to its
		// CallExpr form by the time we get here.
		const inner = peelInverse(d.convExpr, fn);
		if (inner !== d.convExpr) return inner;

		const result = makeCall(makeIdent(fn, loc), [d.convExpr], loc);
		result.nodeType = d.convType;
		return result;
	});
}
