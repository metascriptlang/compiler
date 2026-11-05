// Native-Backend Transform Pipeline — AST transforms for compiled backends (C, Raiser)
//
// These transforms lower constructs that JS handles natively but compiled backends need rewritten:
//  1. (moved) newExprLower — positional-new lowering now runs in the shared pipeline
//  2. closureCallMarker   — mark calls through closure types for different calling convention
//  3. (removed) pointerParam — now handled at codegen time (Reference: indirect location parity)
//  4. rangeCheckInject    — insert runtime range checks for narrowing integer casts
//  5. optionalCoercion    — wrap T returns for T|null return types
//  6. presizedPush      — build an array a counted loop pushes onto once per step the way `map` does: presized, written by index (NIM-REF TR-41)
//  7. inductionPointer    — carry a Span index of a @computedGoto loop as a pointer under --danger (it reads the final shape of every access and call)
//  8. loopSpanCache      — hold the length and data of the arrays a call-free loop reads or fills in a local Span under --danger (last, so it leaves a computed-goto loop as inductionPointer shaped it)
//  9. constDataMark      — flag array literals of deep-constant elements so codegen copies one static initializer (last: the elements are in their final shape)
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
import { lowerEnumToString } from "./enumToStringLower";
import { insertVarParamDerefs } from "./varParamDeref";
import { lowerDownConversions } from "./downConvLower";
import { lowerPresizedPushes } from "./presizedPush";
import { lowerInductionPointers } from "./inductionPointer";
import { lowerLoopSpans } from "./loopSpanCache";
import { markConstData } from "./constDataMark";
import { reportShareIfRequested } from "../shareCount";

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
	// Last: injection must run after every pass that can request an Enum_toString
	// (the lowerBuiltins run in transformProgram).
	result = lowerEnumToString(result, ctx);
	flowLap("pass.native.lowerEnumToString");
	result = lowerDownConversions(result, ctx);
	flowLap("pass.lowerDownConversions");
	result = insertVarParamDerefs(result, ctx);
	flowLap("pass.insertVarParamDerefs");
	result = lowerPresizedPushes(result, ctx);
	flowLap("pass.lowerPresizedPushes");
	result = lowerInductionPointers(result, ctx);
	flowLap("pass.lowerInductionPointers");
	result = lowerLoopSpans(result, ctx);
	flowLap("pass.lowerLoopSpans");
	result = markConstData(result, ctx);
	flowLap("pass.native.markConstData");
	reportShareIfRequested(result, "native");
	return result;
}
