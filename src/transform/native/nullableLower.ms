// Nullable Lower — Maybe<T> structural rewrites (Reference parity)
//
// After checker resolves `T | null` → Maybe_T and operatorLower/stringTruthiness
// handle null comparisons + truthiness, this late pass handles structural rewrites:
//
//   1. Narrowed identifiers: x (nodeType=T, symbolType=Maybe_T) → x.value
//   2. Member access on Maybe: x.field → x.value.field
//   3. Null expression unwrap: null as unknown as T → NullLiteral (codegen {0})
//   4. Value wrapping (decl): const x: T|null = tok → const x = { value: tok, present: true }
//   5. Value wrapping (assign): x = tok → x = { value: tok, present: true }

import { Node, NodeKind, SourceLocation, MemberExprData, VariableDeclData, BinaryExprData, Type } from "../../ast/node";
import { isStructType, isMaybeType, getProperty } from "../../checker/types";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeMember, makeBool, makeNull, makeTypedObjectLiteral } from "../util";
import { isNullExpr } from "../lowering/operatorLower";

// Wrap a value for assignment/return into a Maybe<T> slot. Canonical entry
// point for transform-layer Maybe construction — used by nullableLower
// (var-decl/assign) and optionalCoercion (return). Mirrors the checker-layer
// `synthMaybeWrap` in checkExprPass.ms; kept separate per checker/transform
// layering. Three cases:
//   - Already Maybe-typed:      passthrough (avoid Maybe<Maybe<T>>)
//   - Null in any form:         retype/canonicalize as Maybe wrapper, codegen
//                               emits `{0}` zero-init (present=false).
//   - Non-null value:           `{ value: init, present: true }` ObjectLiteral
//                               typed as wrapper. Direct struct construction
//                               (Nim parity).
export function wrapMaybeValue(init: Node, maybeType: Type, loc: SourceLocation): Node {
	if (init.nodeType !== null && isMaybeType(init.nodeType)) return init;
	if (init.kind === NodeKind.NullLiteral) {
		init.nodeType = maybeType;
		return init;
	}
	if (isNullExpr(init)) {
		// TypeAssertion-wrapped null (`null as unknown as T`): canonicalize to
		// a fresh NullLiteral so codegen's null-of-struct path fires uniformly.
		const nullNode = makeNull(loc);
		nullNode.nodeType = maybeType;
		return nullNode;
	}
	return makeTypedObjectLiteral(
		["value", "present"],
		[init, makeBool(true, loc)],
		maybeType, loc);
}

// ===== Main Entry Point =====

export function lowerNullable(program: Node, ctx: TransformContext): Node {
	walkNode(program, lowerNullableNode);
	return program;
}

function lowerNullableNode(node: Node): Node {
	if (node === null) return node;
	const loc = node.location;

	// 1. Narrowed identifier: symbolType=Maybe_T, nodeType=T (narrowed by checker)
	//    → replace x with x.value so codegen accesses the inner struct
	if (node.kind === NodeKind.Identifier && node.resolvedSym !== null
		&& isMaybeType(node.resolvedSym.symbolType)
		&& node.nodeType !== null && !isMaybeType(node.nodeType)) {
		const member = makeMember(node, "value", loc);
		member.nodeType = node.nodeType;
		return member;
	}

	// 1b. Narrowed member access: c.cursor where the field type in c's struct
	//     is Maybe<T> but the checker narrowed nodeType to inner T (e.g. inside
	//     `if (c.cursor !== null) { ... c.cursor ... }`). Rewrite to
	//     c.cursor.value so codegen reads the inner value, not the Maybe struct.
	//     Skip when property is "value"/"present" (already accessing the wrapper
	//     directly) or when accessing through an already-Maybe object (handled
	//     by rule 2 below).
	if (node.kind === NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
		if (d.object !== null && d.object.nodeType !== null
				&& d.property !== "value" && d.property !== "present"
				&& !isMaybeType(d.object.nodeType)
				&& node.nodeType !== null && !isMaybeType(node.nodeType)) {
			const fieldType = getProperty(d.object.nodeType, d.property);
			if (isMaybeType(fieldType)) {
				const member = makeMember(node, "value", loc);
				member.nodeType = node.nodeType;
				return member;
			}
		}
	}

	// 2. Member access on Maybe object: x.field → x.value.field
	//    Skip .present and .value (direct Maybe struct fields)
	if (node.kind === NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
		if (d.object !== null && d.property !== "present" && d.property !== "value"
			&& d.object.nodeType !== null && isMaybeType(d.object.nodeType)) {
			d.object = makeMember(d.object, "value", loc);
		}
	}

	// 3. Null expression unwrap: null as unknown as InterfaceType → NullLiteral
	//    Codegen's existing {0} handler works for NullLiteral + struct type
	if (isNullExpr(node) && node.kind !== NodeKind.NullLiteral
		&& node.nodeType !== null && isStructType(node.nodeType)) {
		const nullNode = makeNull(loc);
		nullNode.nodeType = node.nodeType;
		return nullNode;
	}

	// 4. Value wrapping: Maybe var initialized with non-Maybe value
	//    const x: Token | null = tok → const x = { value: tok, present: true }
	if (node.kind === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		if (d.initializer !== null && node.nodeType !== null && isMaybeType(node.nodeType)) {
			d.initializer = wrapMaybeValue(d.initializer, node.nodeType, loc);
		}
	}

	// 5. Assignment wrapping: Maybe var assigned non-Maybe value
	//    x = tok → x = { value: tok, present: true }
	if (node.kind === NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		if (d.operator === "=" && d.left.resolvedSym !== null
			&& isMaybeType(d.left.resolvedSym.symbolType)) {
			d.right = wrapMaybeValue(d.right, d.left.resolvedSym.symbolType, loc);
		}
	}

	return node;
}
