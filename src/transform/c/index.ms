// C-Backend Transform Pipeline — applies C-specific AST transforms
//
// These transforms prepare the AST for C code generation:
//  1. closureCallMarker   — mark calls through closure types for different calling convention
//  2. pointerParam        — flag parameters that are pointers in C (interfaces, classes)
//  3. rangeCheckInject    — insert runtime range checks for narrowing integer casts
//  4. optionalCoercion    — wrap T returns for T|null return types
//  5. builtinLower        — rewrite @runtime/@builtin calls to C-compatible AST
//
// Called AFTER the general transform pipeline, ONLY when targeting C backend.

import { Node } from "../../ast/node";
import { TransformContext } from "../context";
import { markClosureCalls } from "./closureCallMarker";
import { markPointerParams } from "./pointerParam";
import { injectRangeChecks } from "./rangeCheckInject";
import { coerceOptionals } from "./optionalCoercion";
import { lowerBuiltins } from "./builtinLower";

export function transformForC(program: Node, ctx: TransformContext): Node {
	let result = markClosureCalls(program, ctx);
	result = markPointerParams(result, ctx);
	result = injectRangeChecks(result, ctx);
	result = coerceOptionals(result, ctx);
	result = lowerBuiltins(result, ctx);
	return result;
}
