// Native-Backend Transform Pipeline — AST transforms for compiled backends (C, Raiser)
//
// These transforms lower constructs that JS handles natively but compiled backends need rewritten:
//  1. newExprLower        — new Foo(args) → Foo_new(args) constructor call
//  2. closureCallMarker   — mark calls through closure types for different calling convention
//  3. (removed) pointerParam — now handled at codegen time (Reference: indirect location parity)
//  4. rangeCheckInject    — insert runtime range checks for narrowing integer casts
//  5. optionalCoercion    — wrap T returns for T|null return types
//  6. builtinLower        — rewrite @builtin calls + extern extensions to C-compatible AST
//
// NOTE: moveExprLower removed — MoveExpr survives to Phase 4 (analyzer) and Phase 5 (codegen).
// Analyzer handles RC semantics (wasMoved, errFailedMove). Codegen unwraps to inner expression.
//
// Called AFTER the general transform pipeline, ONLY for non-JS backends.

import { Node } from "../../ast/node";
import { TransformContext } from "../context";
import { lowerNewExpr } from "../lowering/newExprLower";
import { markClosureCalls } from "./closureCallMarker";
// closureCallLower removed — Reference parity: dispatch generated at codegen time
import { injectRangeChecks } from "./rangeCheckInject";
import { coerceOptionals } from "./optionalCoercion";
import { lowerBuiltins } from "./builtinLower";
import { lowerStringOps } from "./stringOpLower";
import { lowerEnumToString } from "./enumToStringLower";

export function transformForNative(program: Node, ctx: TransformContext): Node {
	let result = lowerNewExpr(program, ctx);
	result = markClosureCalls(result, ctx);
	result = injectRangeChecks(result, ctx);
	result = coerceOptionals(result, ctx);
	result = lowerBuiltins(result, ctx);
	result = lowerStringOps(result, ctx);
	// Last: injection must run after every pass that can request an Enum_toString
	// (builtinLower/debugLower here + the stage-1 lowerBuiltins run in transformProgram).
	result = lowerEnumToString(result, ctx);
	return result;
}
