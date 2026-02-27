// Native-Backend Transform Pipeline — AST transforms for compiled backends (C, Raiser)
//
// These transforms lower constructs that JS handles natively but compiled backends need rewritten:
//  1. newExprLower        — new Foo(args) → Foo_new(args) constructor call
//  2. moveExprLower       — move x → x (DRC/runtime handles ownership transfer)
//  3. closureCallMarker   — mark calls through closure types for different calling convention
//  4. pointerParam        — flag parameters that are pointers in C (interfaces, classes)
//  5. rangeCheckInject    — insert runtime range checks for narrowing integer casts
//  6. optionalCoercion    — wrap T returns for T|null return types
//  7. builtinLower        — rewrite @runtime/@builtin calls to C-compatible AST
//
// Called AFTER the general transform pipeline, ONLY for non-JS backends.

import { Node } from "../../ast/node";
import { TransformContext } from "../context";
import { lowerNewExpr } from "../lowering/newExprLower";
import { lowerMoveExpr } from "../lowering/moveExprLower";
import { markClosureCalls } from "./closureCallMarker";
import { markPointerParams } from "./pointerParam";
import { injectRangeChecks } from "./rangeCheckInject";
import { coerceOptionals } from "./optionalCoercion";
import { lowerBuiltins } from "./builtinLower";

export function transformForNative(program: Node, ctx: TransformContext): Node {
	let result = lowerNewExpr(program, ctx);
	result = lowerMoveExpr(result, ctx);
	result = markClosureCalls(result, ctx);
	result = markPointerParams(result, ctx);
	result = injectRangeChecks(result, ctx);
	result = coerceOptionals(result, ctx);
	result = lowerBuiltins(result, ctx);
	return result;
}
