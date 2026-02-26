// Transform Pipeline Runner — applies all AST transforms in order
//
// Fixed order matches reference compiler dependency chain:
//  1. deferLower            — may create try/finally that later transforms see
//  2. constantFolding       — simplifies literal expressions for all later transforms
//  3. stringConcatFlatten   — flatten known-string + chains into concat call (after constFold)
//  4. optionalChain         — must run BEFORE nullishCoalesce
//  5. nullishCoalesce       — sees already-lowered optional chains
//  6. typeCoercion          — simple 1:1 replacement
//  7. stringTruthiness      — normalize bare conditions after coercions
//  8. destructuringLower    — unpack array/object patterns before forOf/result
//  9. spreadExpand          — inline array literal spreads after destructuring
// 10. forLoopLower          — normalize for→while before forOf
// 11. forOfLower            — desugars for-of to while
// 12. resultDesugar         — 1:N expansion of try expressions
// 13. resultFieldCheck      — safety checks on $result_N.value/.error access
// 14. matchLower            — sees simplest AST
// 15. tailCallLower         — tail recursion → while (sees fully normalized AST)
// 16. asyncDesugar          — await → yield, async → generator (before generatorLower)
// 17. generatorLower        — function* → state machine returning iterator object
// 18. lambdaLifting         — closures with captures → lifted functions + env structs
// 19. extensionMethodLower  — obj.method(args) → method(obj, args) for UFCS extensions
// 20. subscriptLower        — obj[idx] → `[]`(obj, idx) for custom subscript operators
// 21. dce                   — dead code elimination (2-tier: statement + symbol level)
// 22. destructorLifting     — generate per-type _destroy/_copy function bodies

import { Node } from "../ast/node";
import { CheckerContext } from "../checker/context";
import { TransformContext, createTransformContextWithChecker } from "./context";
import { lowerDefer } from "./lowering/deferLower";
import { lowerConstFold } from "./coercion/constantFolding";
import { lowerStringConcatFlatten } from "./coercion/stringConcatFlatten";
import { lowerOptionalChain } from "./coercion/optionalChain";
import { lowerNullishCoalesce } from "./coercion/nullishCoalesce";
import { lowerTypeCoercion } from "./coercion/typeCoercion";
import { lowerStringTruthiness } from "./coercion/stringTruthiness";
import { lowerDestructuring } from "./desugar/destructuringLower";
import { lowerSpread } from "./desugar/spreadExpand";
import { lowerForLoop } from "./lowering/forLoopLower";
import { lowerForOf } from "./lowering/forOfLower";
import { lowerResult } from "./desugar/resultDesugar";
import { lowerResultFieldCheck } from "./desugar/resultFieldCheck";
import { lowerMatch } from "./lowering/matchLower";
import { lowerTailCall } from "./lowering/tailCallLower";
import { lowerAsync } from "./lowering/asyncDesugar";
import { lowerGenerator } from "./lowering/generatorLower";
import { lowerLambda } from "./lowering/lambdaLifting";
import { lowerExtensionMethod } from "./lowering/extensionMethodLower";
import { lowerSubscript } from "./lowering/subscriptLower";
import { lowerDCE } from "./analysis/dce";
import { liftDestructors } from "./lowering/destructorLifting";

export function transformProgram(program: Node, checkerCtx: CheckerContext): Node {
	const ctx = createTransformContextWithChecker(checkerCtx);
	let result = lowerDefer(program, ctx);
	result = lowerConstFold(result, ctx);
	result = lowerStringConcatFlatten(result, ctx);
	result = lowerOptionalChain(result, ctx);
	result = lowerNullishCoalesce(result, ctx);
	result = lowerTypeCoercion(result, ctx);
	result = lowerStringTruthiness(result, ctx);
	result = lowerDestructuring(result, ctx);
	result = lowerSpread(result, ctx);
	result = lowerForLoop(result, ctx);
	result = lowerForOf(result, ctx);
	result = lowerResult(result, ctx);
	result = lowerResultFieldCheck(result, ctx);
	result = lowerMatch(result, ctx);
	result = lowerTailCall(result, ctx);
	result = lowerAsync(result, ctx);
	result = lowerGenerator(result, ctx);
	result = lowerLambda(result, ctx);
	result = lowerExtensionMethod(result, ctx);
	result = lowerSubscript(result, ctx);
	result = lowerDCE(result, ctx);
	result = liftDestructors(result, ctx);
	return result;
}
