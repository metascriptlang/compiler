import { Node, NodeKind, SourceLocation, Type, TypeKind } from "../ast/node";
import { isMaybeType, isUnknownType, peelTransparentInstance, unionHasMemberOfKind, unwrapRefNullUnion, unionMemberDisplay } from "../checker/types";
import { makeBool, makeNull, makeTypedObjectLiteral } from "./util";
import { isNullExpr } from "../ast/shape";

// Wrap a value for assignment/return into a Maybe<T> slot. Canonical entry
// point for transform-layer Maybe construction — used by nullableLower
// (var-decl/assign) and optionalCoercion (return). Mirrors the checker-layer
// `synthMaybeWrap` in checkExprPass.ms; kept separate per checker/transform
// layering. Three cases:
//   - Already Maybe-typed:      passthrough (avoid Maybe<Maybe<T>>)
//   - Null in any form:         retype/canonicalize as Maybe wrapper, codegen
//                               emits `{0}` zero-init (present=false).
//   - Non-null value:           `{ value: init, present: true }` ObjectLiteral
//                               typed as wrapper. Direct struct construction.
export function wrapMaybeValue(init: Node, maybeType: Type, loc: SourceLocation): Node {
	if (init.nodeType != null && isMaybeType(init.nodeType)) return init;
	if (init.kind == NodeKind.NullLiteral) {
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

export function unwrapRefusesNull(target: Type): boolean {
	const t = peelTransparentInstance(target);
	if (isUnknownType(t) || isMaybeType(t) || t.kind == TypeKind.Null) return false;
	return !unionHasMemberOfKind(t, TypeKind.Null);
}

export function nullAccessHead(carrier: Type): string {
	const held = isMaybeType(carrier) ? carrier.typeReturn : unwrapRefNullUnion(carrier);
	const payload = held != null ? unionMemberDisplay(held) : "?";
	return `member '${payload}' is not accessible for type '${payload} | null' using '`;
}
