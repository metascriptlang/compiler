// Native-Backend Transform Pipeline — AST transforms for compiled backends (C, Raiser)
//
// These transforms lower constructs that JS handles natively but compiled backends need rewritten:
//  1. newExprLower        — new Foo(args) → Foo_new(args) constructor call
//  2. closureCallMarker   — mark calls through closure types for different calling convention
//  3. pointerParam        — flag parameters that are pointers in C (interfaces, classes)
//  4. rangeCheckInject    — insert runtime range checks for narrowing integer casts
//  5. optionalCoercion    — wrap T returns for T|null return types
//  6. builtinLower        — rewrite @runtime/@builtin calls to C-compatible AST
//
// NOTE: moveExprLower removed — MoveExpr survives to Phase 4 (analyzer) and Phase 5 (codegen).
// Analyzer handles RC semantics (wasMoved, errFailedMove). Codegen unwraps to inner expression.
//
// Called AFTER the general transform pipeline, ONLY for non-JS backends.

import { Node } from "../../ast/node";
import { TransformContext } from "../context";
import { lowerNewExpr } from "../lowering/newExprLower";
import { markClosureCalls } from "./closureCallMarker";
import { lowerClosureCalls } from "./closureCallLower";
import { markPointerParams } from "./pointerParam";
import { injectRangeChecks } from "./rangeCheckInject";
import { coerceOptionals } from "./optionalCoercion";
import { lowerBuiltins } from "./builtinLower";
import { lowerStringOps } from "./stringOpLower";
import { lowerEnumToString } from "./enumToStringLower";

export function transformForNative(program: Node, ctx: TransformContext): Node {
	let result = lowerNewExpr(program, ctx);
	result = markClosureCalls(result, ctx);
	result = lowerClosureCalls(result, ctx);
	result = markPointerParams(result, ctx);
	result = injectRangeChecks(result, ctx);
	result = coerceOptionals(result, ctx);
	result = lowerEnumToString(result, ctx);
	result = lowerBuiltins(result, ctx);
	result = lowerStringOps(result, ctx);
	return result;
}
