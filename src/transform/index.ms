// Transform Pipeline Runner — applies all AST transforms in order
//
// Fixed order matches reference compiler dependency chain:
//  1. deferLower            — may create try/finally that later transforms see
//  2. constantFolding       — simplifies literal expressions for all later transforms
//  3. stringConcatFlatten   — flatten known-string + chains into concat call (after constFold)
//  4. optionalChain         — must run BEFORE nullishCoalesce
//  5. nullishCoalesce       — sees already-lowered optional chains
//  6. stringTruthiness      — normalize bare conditions after coercions
//  8. destructuringLower    — unpack array/object patterns before forOf/result
//  9. spreadExpand          — inline array literal spreads after destructuring
// 10. arrayMethodInline     — arr.map/filter/reduce → inline while loops (before forLoop/extensionMethod)
// 11. forLoopLower          — normalize for→while before forOf
// 12. forOfLower            — desugars for-of to while
// 13. resultDesugar         — 1:N expansion of try expressions
// 14. resultFieldCheck      — safety checks on $result_N.value/.error access
// 15. switchLower           — user switch → the match engine (ordinal discs pass through)
//     matchLower            — sees simplest AST
// 16. tailCallLower         — tail recursion → while + loop-carried shadow locals (both targets)
//     paramReassignLower    — assigned params → owned shadow locals (C only: DRC sink/destroy)
// 17. asyncDesugar          — await → yield, async → generator (before generatorLower)
// 18. generatorLower        — function* → state machine returning iterator object
// 19. varHoist              — hoist var declarations to function scope top (JS semantics)
// 20. lambdaLifting         — closures with captures → lifted functions + env structs
// 21. rvalueLower           — f().method() → { const tmp = f(); tmp.method() } (evalOnce pattern)
// 22. extensionMethodLower  — obj.method(args) → method(obj, args) for UFCS extensions
// 23. subscriptLower        — obj[idx] → `[]`(obj, idx) for custom subscript operators
// 24. conditionalExprLower  — ternary→if in statement position
// 25. updateExprLower       — x++/-- → assignment in statement position
// 26. dce                   — dead code elimination (2-tier: statement + symbol level)
// 27. destructorLifting     — generate per-type _destroy/_copy function bodies

import { Node } from "../ast/node";
import { CheckerContext } from "../checker/context";
import { createTransformContextWithChecker } from "./context";
import { lowerDefer } from "./lowering/deferLower";
import { lowerConstFold } from "./coercion/constantFolding";
import { lowerObjectLiteralComplete } from "./coercion/objectLiteralComplete";
import { lowerStringLengthJS } from "./coercion/stringLengthJS";
import { lowerIntConvJS } from "./coercion/intConvJS";
import { lowerIntArithJS } from "./coercion/intArithJS";
import { lowerStringConcatFlatten } from "./coercion/stringConcatFlatten";
import { lowerOptionalChain } from "./coercion/optionalChain";
import { lowerNullishCoalesce } from "./coercion/nullishCoalesce";
import { materializeMaybeReads } from "./coercion/maybeReadMaterialize";
import { lowerStringTruthiness } from "./coercion/stringTruthiness";
import { eraseBrandTypes } from "./coercion/brandErase";
import { lowerDestructuring } from "./desugar/destructuringLower";
import { lowerSpread } from "./desugar/spreadExpand";
import { lowerObjectSpread } from "./desugar/objectSpreadLower";
import { lowerArrayMethodInline } from "./desugar/arrayMethodInline";
import { lowerForLoop } from "./lowering/forLoopLower";
import { lowerForOf } from "./lowering/forOfLower";
import { lowerTryExpr, lowerResultConstructors } from "./desugar/resultDesugar";
import { lowerMatch } from "./lowering/matchLower";
import { lowerSwitch } from "./lowering/switchLower";
import { lowerTailCall } from "./lowering/tailCallLower";
import { lowerParamReassign } from "./lowering/paramReassignLower";
import { lowerAsync } from "./lowering/asyncDesugar";
import { lowerGenerator } from "./lowering/generatorLower";
import { lowerAsyncBridge } from "./lowering/asyncBridge";
import { lowerSpawn } from "./lowering/spawnLower";
import { lowerSpawnGroup } from "./lowering/spawnGroupLower";
import { lowerAwait } from "./lowering/awaitLower";
import { lowerVarHoist } from "./lowering/varHoist";
import { lowerLambda } from "./lowering/lambdaLifting";
import { lowerCallHoist } from "./lowering/callHoist";
import { lowerRvalueBridge } from "./lowering/rvalueLower";
import { lowerExtensionMethod } from "./lowering/extensionMethodLower";
import { lowerMethodToFunction } from "./lowering/methodToFunction";
import { lowerCtorInit } from "./lowering/ctorLower";
import { lowerNewExpr } from "./lowering/newExprLower";
import { lowerBuiltins } from "./native/builtinLower";
import { lowerCStringConv } from "./native/cstringConvLower";
import { lowerSubscript } from "./lowering/subscriptLower";
import { lowerOperators } from "./lowering/operatorLower";
import { lowerStringOps } from "./native/stringOpLower";
import { lowerConditionalExpr } from "./lowering/conditionalExprLower";
import { lowerUpdateExpr } from "./lowering/updateExprLower";
import { spanLower } from "./lowering/spanLower";
import { spanParamExpand } from "./native/spanParamExpand";
import { lowerNullable } from "./native/nullableLower";
import { unwrapMaybe } from "./native/maybeUnwrap";
import { lowerDCE } from "./analysis/dce";
import { liftDestructors } from "./lowering/destructorLifting";
import { lowerPowerAssert } from "./powerAssert";
import { lowerRestParams } from "./lowering/restParamLower";
import { lowerActorPre, lowerActor } from "./lowering/actorLower";
import { resolveRuntimeIdents } from "./lowering/runtimeIdentResolve";

export function transformProgram(program: Node, checkerCtx: CheckerContext, jsBackend: boolean): Node {
	const ctx = createTransformContextWithChecker(checkerCtx);
	ctx.jsBackend = jsBackend;
	let result = eraseBrandTypes(program);
	result = jsBackend ? lowerPowerAssert(result, ctx) : result;
	result = lowerDefer(result, ctx);
	result = lowerConstFold(result, ctx);
	result = lowerObjectSpread(result, ctx);
	if (ctx.jsBackend) {
		result = lowerObjectLiteralComplete(result, ctx);
	}
	if (!jsBackend) { result = lowerStringConcatFlatten(result, ctx); }
	result = lowerOptionalChain(result, ctx);
	result = lowerNullishCoalesce(result, ctx);
	result = materializeMaybeReads(result, ctx);
	result = lowerStringTruthiness(result, ctx);
	result = lowerRestParams(result, ctx);
	result = lowerDestructuring(result, ctx);
	result = lowerSpread(result, ctx);
	if (!jsBackend) { result = lowerArrayMethodInline(result, ctx); }
	if (!jsBackend) { result = lowerForLoop(result, ctx); }
	if (!jsBackend) { result = lowerForOf(result, ctx); }
	result = lowerTryExpr(result, ctx);
	if (jsBackend) { result = lowerResultConstructors(result); }
	result = lowerSwitch(result, ctx);
	result = lowerMatch(result, ctx);
	result = lowerTailCall(result, ctx);
	if (!jsBackend) { result = lowerParamReassign(result, ctx); }
	if (!jsBackend) { result = lowerActorPre(result, ctx); }
	if (!jsBackend) { result = lowerSpawnGroup(result, ctx); }
	if (!jsBackend) { result = lowerAsync(result, ctx); }
	if (!jsBackend) { result = lowerAsyncBridge(result, ctx); }
	if (!jsBackend) { result = lowerGenerator(result, ctx); }
	if (!jsBackend) { result = lowerSpawn(result, ctx); }
	if (!jsBackend) { result = lowerAwait(result, ctx); }
	if (!jsBackend) { result = lowerActor(result, ctx); }
	if (!jsBackend) { result = lowerVarHoist(result, ctx); }
	if (!jsBackend) { result = lowerRvalueBridge(result, ctx); }
	result = lowerExtensionMethod(result, ctx);
	// Field initializers become assignments inside the constructor, so both
	// backends run them in one place and the parent chain reaches them.
	result = lowerCtorInit(result, ctx);
	result = lowerNewExpr(result, ctx);
	// Lift class/actor methods → top-level FunctionDecl. C + Raiser want one
	// uniform shape for codegen; JS keeps `class Foo {}` native (its semantics
	// already match what we want at the source level).
	if (!jsBackend) { result = lowerMethodToFunction(result, ctx); }
	if (!jsBackend) { result = lowerLambda(result, ctx); }
	// Hoist fresh RC-returning calls out of non-RC bindings so the analyzer cleans
	// them (fixes `const has = provide(path).ok` leaking the Result). C/DRC only.
	if (!jsBackend) { result = lowerCallHoist(result, ctx); }
	result = lowerBuiltins(result, ctx);
	if (jsBackend) { result = lowerStringLengthJS(result, ctx); }
	result = lowerCStringConv(result, ctx);
	result = lowerOperators(result, ctx);
	if (!jsBackend) { result = lowerStringOps(result, ctx); }
	result = lowerSubscript(result, ctx);
	if (!jsBackend) { result = spanLower(result, ctx); }
	if (!jsBackend) { result = spanParamExpand(result, ctx); }
	result = lowerConditionalExpr(result, ctx);
	// Conditionally-evaluated positions (ternary arm, `&&`/`||` RHS, while-cond)
	// are statements now, so the positional-new hoist that skipped them above can
	// reach them. The pass empties `newArguments` when it lowers, so this second
	// run only sees what the first one refused.
	result = lowerNewExpr(result, ctx);
	if (!jsBackend) { result = lowerUpdateExpr(result, ctx); }
	if (!jsBackend) { result = lowerNullable(result, ctx); }
	// C materializes the Maybe struct (above); JS de-materializes it — the two
	// backends are inverse directions of the same T|null lowering. Keeps JS on
	// native null (platform interop) and codegen dumb.
	if (jsBackend) { result = unwrapMaybe(result, ctx); }
	result = lowerDCE(result, ctx);
	if (jsBackend) { result = resolveRuntimeIdents(result, ctx); }
	// Must trail resolveRuntimeIdents: the synthesized `Math` receiver has to
	// stay unbound, or it resolves to the prelude's own `class Math` and gets
	// mangled as a module global.
	if (jsBackend) { result = lowerIntConvJS(result, ctx); }
	if (jsBackend) { result = lowerIntArithJS(result, ctx); }
	if (!jsBackend) { result = liftDestructors(result, ctx); }
	return result;
}
