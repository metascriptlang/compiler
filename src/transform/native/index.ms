// Native-Backend Transform Pipeline — AST transforms for compiled backends (C, Raiser)
//
// These transforms lower constructs that JS handles natively but compiled backends need rewritten:
//  1. (moved) newExprLower — positional-new lowering now runs in the shared pipeline
//  2. closureCallMarker   — mark calls through closure types for different calling convention
//  3. (removed) pointerParam — now handled at codegen time (Reference: indirect location parity)
//  4. rangeCheckInject    — insert runtime range checks for narrowing integer casts
//  5. optionalCoercion    — wrap T returns for T|null return types
//  6. builtinLower        — rewrite @builtin calls + extern extensions to C-compatible AST
//  7. inductionPointer    — carry a Span index of a @computedGoto loop as a pointer under --danger (last: it reads the final shape of every access and call)
//
// NOTE: moveExprLower removed — MoveExpr survives to Phase 4 (analyzer) and Phase 5 (codegen).
// Analyzer handles RC semantics (wasMoved, errFailedMove). Codegen unwraps to inner expression.
//
// Called AFTER the general transform pipeline, ONLY for non-JS backends.

import { Node } from "../../ast/node";
import { flowLap, flowMark } from "../../compiler/flows";
import { TransformContext } from "../context";
import { markClosureCalls } from "./closureCallMarker";
// closureCallLower removed — Reference parity: dispatch generated at codegen time
import { injectRangeChecks } from "./rangeCheckInject";
import { injectIntChecks, lowerNumberBitwiseOperands } from "./intCheckInject";
import { coerceOptionals } from "./optionalCoercion";
import { lowerBuiltins } from "./builtinLower";
import { lowerStringOps } from "./stringOpLower";
import { lowerEnumToString } from "./enumToStringLower";
import { insertVarParamDerefs } from "./varParamDeref";
import { lowerDownConversions } from "./downConvLower";
import { lowerInductionPointers } from "./inductionPointer";

export function transformForNative(program: Node, ctx: TransformContext): Node {
	flowMark();
	let result = markClosureCalls(program, ctx);
	flowLap("pass.markClosureCalls");
	result = lowerNumberBitwiseOperands(result, ctx);
	flowLap("pass.native.lowerNumberBitwiseOperands");
	result = injectRangeChecks(result, ctx);
	flowLap("pass.injectRangeChecks");
	result = injectIntChecks(result, ctx);
	flowLap("pass.injectIntChecks");
	result = coerceOptionals(result, ctx);
	flowLap("pass.coerceOptionals");
	result = lowerBuiltins(result, ctx);
	flowLap("pass.native.lowerBuiltins");
	result = lowerStringOps(result, ctx);
	flowLap("pass.native.lowerStringOps");
	// Last: injection must run after every pass that can request an Enum_toString
	// (builtinLower/debugLower here + the stage-1 lowerBuiltins run in transformProgram).
	result = lowerEnumToString(result, ctx);
	flowLap("pass.native.lowerEnumToString");
	result = lowerDownConversions(result, ctx);
	flowLap("pass.lowerDownConversions");
	result = insertVarParamDerefs(result, ctx);
	flowLap("pass.insertVarParamDerefs");
	result = lowerInductionPointers(result, ctx);
	flowLap("pass.lowerInductionPointers");
	return result;
}
