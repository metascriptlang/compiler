// Maybe Unwrap — JS backend ONLY. Normalizes the Maybe<T> representation back to
// native JS null.
//
// `T | null` (for value types) is represented in C as a Maybe struct
// { value, present } because C has no native null for value types. The checker
// (synthMaybeWrap) and operatorLower / stringTruthiness materialize + read that
// struct for BOTH backends. JS has native null and must NOT carry the struct — it
// also breaks platform interop (e.g. `document.querySelector()` returns real null,
// not `{present:false}`).
//
// This pass runs ONLY for the JS backend and strips every Maybe artifact to native
// null, regardless of which upstream pass produced it (checker wrap, operatorLower
// read, stringTruthiness read). It is a normalizer, not a targeted patch — that is
// what makes "JS never sees Maybe" enforceable in one place:
//
//   { value: x, present: true }   (Maybe wrapper literal)   →  x
//   x.present   (x is Maybe-typed)                          →  x !== null
//   x.value     (x is Maybe-typed)                          →  x
//
// The absent case (null-typed-as-Maybe) already lowers to native `null` via JS
// codegen's emitNullLiteral, so construction needs no rewrite — only the reads above.

import { Node, NodeKind, MemberExprData, ObjectLiteralData } from "../../ast/node";
import { isMaybeType } from "../../checker/types";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeBinary, makeNull } from "../util";

export function unwrapMaybe(program: Node, ctx: TransformContext): Node {
	walkNode(program, unwrapMaybeNode);
	return program;
}

function unwrapMaybeNode(node: Node): Node {
	if (node == null) return node;
	const loc = node.location;

	// 1. Maybe wrapper object literal `{ value: x, present: true }` → inner value x
	if (node.kind == NodeKind.ObjectLiteral && node.nodeType != null && isMaybeType(node.nodeType)) {
		const d = node.data as ObjectLiteralData;
		if (d.keys.length == 2 && d.keys[0] == "value" && d.keys[1] == "present") {
			return d.properties[0];
		}
	}

	// 2/3. Reads on a Maybe-typed object collapse to native null semantics.
	if (node.kind == NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
		if (d.object != null && d.object.nodeType != null && isMaybeType(d.object.nodeType)) {
			// x.present → x !== null
			if (d.property == "present") {
				const cmp = makeBinary(d.object, "!==", makeNull(loc), loc);
				cmp.nodeType = node.nodeType;
				return cmp;
			}
			// x.value → x  (native value IS the payload once null-collapsed)
			if (d.property == "value") {
				return d.object;
			}
		}
	}

	return node;
}
