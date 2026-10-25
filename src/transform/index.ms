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
// 11. forLoopLower          — normalize for→while before forOf
// 12. forOfLower            — desugars for-of to while
// 13. resultDesugar         — 1:N expansion of try expressions
// 15. switchLower           — user switch → the match engine (ordinal discs pass through)
//     matchLower            — sees simplest AST
// 16. tailCallLower         — tail recursion → while + loop-carried shadow locals (both targets)
//     paramReassignLower    — assigned params → owned shadow locals (C only: DRC sink/destroy)
//     awaitSpill            — an await inside an expression → its own declaration, operands in order (C only)
// 17. asyncDesugar          — await → yield, async → generator (before generatorLower)
// 18. generatorLower        — function* → state machine returning iterator object
// 19. varHoist              — hoist var declarations to function scope top (JS semantics)
// 20. lambdaLifting         — closures with captures → lifted functions + env structs
// 21. rvalueLower           — f().method() → { const tmp = f(); tmp.method() } (evalOnce pattern)
// 22. extensionMethodLower  — obj.method(args) → method(obj, args) for UFCS extensions
// 23. conditionalExprLower  — ternary→if in statement position
// 24. updateExprLower       — x++/-- → assignment in statement position
// 25. dce                   — dead code elimination (2-tier: statement + symbol level)
// 26. destructorLifting     — generate per-type _destroy/_copy function bodies

import { Node, NodeKind, ProgramData, SymbolKind } from "../ast/node";
import { CheckerContext } from "../checker/context";
import { hasFlag, setFlag, SymbolFlag } from "../checker/symbol";
import { createTransformContextWithChecker, TransformContext } from "./context";
import { WriteSummaries } from "../analyzer/writeEffects";
import { bindCompilerFuncs } from "./util";
import { flowLap, flowMark } from "../compiler/flows";
import { lowerDefer } from "./lowering/deferLower";
import { lowerBitSet } from "./lowering/bitSetLower";
import { lowerConstFold } from "./coercion/constantFolding";
import { lowerVoidBind } from "./desugar/voidBindLower";
import { lowerStringLengthJS } from "./coercion/stringLengthJS";
import { lowerIntConvJS, injectRangeChecksJS } from "./coercion/intConvJS";
import { lowerNumberBitwiseOperands } from "./native/intCheckInject";
import { lowerIntArithJS } from "./coercion/intArithJS";
import { lowerAccessJS } from "./coercion/accessJS";
import { lowerFloat32JS } from "./coercion/float32JS";
import { lowerBigIntJS } from "./coercion/bigIntJS";
import { refuseUnfoldedSizeofJS } from "./coercion/sizeofJS";
import { lowerStringConcatFlatten } from "./coercion/stringConcatFlatten";
import { lowerOptionalChain } from "./coercion/optionalChain";
import { lowerNullishCoalesce } from "./coercion/nullishCoalesce";
import { materializeMaybeReads } from "./coercion/maybeReadMaterialize";
import { lowerStringTruthiness, instanceFieldInitializers, lowerMovedFieldInitTruthiness } from "./coercion/stringTruthiness";
import { eraseBrandTypes } from "./coercion/brandErase";
import { lowerImplicitConv } from "./coercion/implicitConvLower";
import { lowerDestructuring } from "./desugar/destructuringLower";
import { lowerObjectSpread } from "./desugar/objectSpreadLower";
import { lowerArraySpread } from "./desugar/arraySpreadLower";
import { lowerForLoop } from "./lowering/forLoopLower";
import { lowerForOf } from "./lowering/forOfLower";
import { lowerTryExpr, lowerResultConstructors } from "./desugar/resultDesugar";
import { lowerMatch } from "./lowering/matchLower";
import { lowerSwitch } from "./lowering/switchLower";
import { lowerTailCall } from "./lowering/tailCallLower";
import { retargetJumps } from "./lowering/jumpRetarget";
import { lowerParamReassign } from "./lowering/paramReassignLower";
import { lowerJsVarParam } from "./lowering/jsVarParamLower";
import { lowerJsPointers } from "./lowering/jsPointerLower";
import { lowerPointerAddresses } from "./lowering/pointerAddressLower";
import { lowerAwaitSpill } from "./lowering/awaitSpill";
import { lowerAsyncModuleBody } from "./lowering/asyncModuleBody";
import { lowerNamespaceValues } from "./lowering/namespaceValueLower";
import { lowerAsync } from "./lowering/asyncDesugar";
import { lowerGenerator } from "./lowering/generatorLower";
import { lowerAsyncBridge } from "./lowering/asyncBridge";
import { lowerSpawn } from "./lowering/spawnLower";
import { lowerSpawnGroup } from "./lowering/spawnGroupLower";
import { lowerAwait, lowerHeldSpawns } from "./lowering/awaitLower";
import { lowerVarHoist } from "./lowering/varHoist";
import { lowerLambda } from "./lowering/lambdaLifting";
import { lowerCallHoist } from "./lowering/callHoist";
import { lowerRvalueBridge } from "./lowering/rvalueLower";
import { lowerExtensionMethod } from "./lowering/extensionMethodLower";
import { lowerBorrow } from "./lowering/borrowLower";
import { lowerMethodToFunction } from "./lowering/methodToFunction";
import { lowerCtorInit } from "./lowering/ctorLower";
import { lowerStaticInit } from "./lowering/staticLower";
import { lowerNewExpr } from "./lowering/newExprLower";
import { lowerBuiltins } from "./native/builtinLower";
import { lowerCStringConv } from "./native/cstringConvLower";
import { lowerOperators, lowerClosureEqualities, bindCollectionKeyOps } from "./lowering/operatorLower";
import { lowerBigIntOps } from "./native/bigIntOpLower";
import { lowerStringOps } from "./native/stringOpLower";
import { lowerConditionalExpr } from "./lowering/conditionalExprLower";
import { planModuleTdz } from "./lowering/moduleTdz";
import { lowerUpdateExpr } from "./lowering/updateExprLower";
import { spanLower } from "./lowering/spanLower";
import { spanParamExpand } from "./native/spanParamExpand";
import { lowerNullable } from "./native/nullableLower";
import { projectNarrowedUnions, checkVariantReads } from "./native/unionProjectLower";
import { lowerUnionTags } from "./lowering/unionTagLower";
import { lowerTypeof } from "./lowering/typeofLower";
import { lowerUnionConversions } from "./lowering/unionConvLower";
import { unwrapMaybe } from "./native/maybeUnwrap";
import { lowerDCE } from "./analysis/dce";
import { liftDestructors } from "./lowering/destructorLifting";
import { lowerPowerAssert } from "./powerAssert";
import { lowerAssert } from "./native/assertLower";
import { lowerRestParams } from "./lowering/restParamLower";
import { lowerActorPre, lowerActor, lowerActorHandles } from "./lowering/actorLower";
import { lowerEnumToString } from "./native/enumToStringLower";

// An instance field initializer is evaluated by the constructor, so its `?.`, `??` and
// truthiness tests bind their temps there, after lowerCtorInit has moved it; on C the moved
// expression also spills what a folded null comparison would drop.
function lowerFieldInitializers(program: Node, ctx: TransformContext): Node {
	const inits: Node[] = ctx.jsBackend ? [] : instanceFieldInitializers(program);
	const moved = lowerMovedFieldInitTruthiness(lowerCtorInit(program, ctx), ctx, inits);
	const result = lowerNullishCoalesce(lowerOptionalChain(moved, ctx), ctx);
	return ctx.jsBackend ? result : lowerAwaitSpill(result, ctx);
}

export function transformProgram(program: Node, checkerCtx: CheckerContext, jsBackend: boolean, reloadableModules: string[] = [], asyncModuleBody: boolean = false, liftTables: WriteSummaries | null = null): Node {
	const ctx = createTransformContextWithChecker(checkerCtx);
	ctx.jsBackend = jsBackend;
	ctx.liftTables = liftTables;
	ctx.reloadableModules = reloadableModules;
	bindCompilerFuncs(checkerCtx.compilerFuncs, checkerCtx.table.identCache);
	flowMark();
	let result = eraseBrandTypes(program);
	flowLap("pass.eraseBrandTypes");
	if (!jsBackend) { result = lowerActorHandles(result, ctx); flowLap("pass.lowerActorHandles"); }
	if (!jsBackend) { result = planModuleTdz(result, ctx); flowLap("pass.planModuleTdz"); }
	result = lowerBorrow(result, ctx);
	flowLap("pass.lowerBorrow");
	result = lowerImplicitConv(result, ctx);
	flowLap("pass.lowerImplicitConv");
	result = jsBackend ? lowerPowerAssert(result, ctx) : lowerAssert(result, ctx);
	flowLap(jsBackend ? "pass.lowerPowerAssert" : "pass.lowerAssert");
	result = lowerDefer(result, ctx);
	flowLap("pass.lowerDefer");
	result = lowerConstFold(result, ctx);
	flowLap("pass.lowerConstFold");
	if (!jsBackend) { result = lowerStaticInit(result, ctx); flowLap("pass.lowerStaticInit"); }
	result = lowerVoidBind(result, ctx);
	flowLap("pass.lowerVoidBind");
	result = lowerObjectSpread(result, ctx);
	flowLap("pass.lowerObjectSpread");
	if (!jsBackend) { result = lowerArraySpread(result, ctx); flowLap("pass.lowerArraySpread"); }
	if (!jsBackend) { result = lowerStringConcatFlatten(result, ctx); flowLap("pass.lowerStringConcatFlatten"); }
	result = lowerOptionalChain(result, ctx);
	flowLap("pass.lowerOptionalChain");
	result = lowerNullishCoalesce(result, ctx);
	flowLap("pass.lowerNullishCoalesce");
	result = materializeMaybeReads(result, ctx);
	flowLap("pass.materializeMaybeReads");
	result = lowerStringTruthiness(result, ctx);
	flowLap("pass.lowerStringTruthiness");
	result = lowerRestParams(result, ctx);
	flowLap("pass.lowerRestParams");
	result = lowerDestructuring(result, ctx);
	flowLap("pass.lowerDestructuring");
	if (!jsBackend) { result = lowerForLoop(result, ctx); flowLap("pass.lowerForLoop"); }
	result = lowerForOf(result, ctx);
	flowLap("pass.lowerForOf");
	result = lowerTryExpr(result, ctx);
	flowLap("pass.lowerTryExpr");
	result = lowerResultConstructors(result);
	flowLap("pass.lowerResultConstructors");
	result = lowerTypeof(result, ctx);
	flowLap("pass.lowerTypeof");
	result = lowerSwitch(result, ctx);
	flowLap("pass.lowerSwitch");
	result = lowerMatch(result, ctx);
	flowLap("pass.lowerMatch");
	// A `try` in a match expression arm became a statement only now.
	result = lowerTryExpr(result, ctx);
	flowLap("pass.lowerTryExpr#2");
	result = retargetJumps(result, ctx);
	flowLap("pass.retargetJumps");
	result = lowerTailCall(result, ctx);
	flowLap("pass.lowerTailCall");
	if (!jsBackend) { result = lowerParamReassign(result, ctx); flowLap("pass.lowerParamReassign"); }
	if (asyncModuleBody) { result = lowerAsyncModuleBody(result, ctx); flowLap("pass.lowerAsyncModuleBody"); }
	if (!jsBackend) { result = lowerAwaitSpill(result, ctx); flowLap("pass.lowerAwaitSpill"); }
	if (!jsBackend) { result = lowerNamespaceValues(result); flowLap("pass.lowerNamespaceValues"); }
	if (!jsBackend) { result = lowerActorPre(result, ctx); flowLap("pass.lowerActorPre"); }
	if (!jsBackend) { result = lowerSpawnGroup(result, ctx); flowLap("pass.lowerSpawnGroup"); }
	if (!jsBackend) { result = lowerHeldSpawns(result, ctx); flowLap("pass.lowerHeldSpawns"); }
	result = lowerPointerAddresses(result, ctx, !jsBackend);
	flowLap("pass.lowerPointerAddresses");
	if (!jsBackend) { result = lowerAsync(result, ctx); flowLap("pass.lowerAsync"); }
	if (!jsBackend) { result = lowerAsyncBridge(result, ctx); flowLap("pass.lowerAsyncBridge"); }
	if (!jsBackend) { result = lowerGenerator(result, ctx); flowLap("pass.lowerGenerator"); }
	if (!jsBackend) { result = lowerSpawn(result, ctx); flowLap("pass.lowerSpawn"); }
	// lowerSpawn boxes a thunk's return value around its await; spill that before lowerAwait.
	if (!jsBackend) { result = lowerAwaitSpill(result, ctx); flowLap("pass.lowerAwaitSpill#2"); }
	if (!jsBackend) { result = lowerAwait(result, ctx); flowLap("pass.lowerAwait"); }
	if (!jsBackend) { result = lowerFieldInitializers(result, ctx); flowLap("pass.lowerFieldInitializers"); }
	if (!jsBackend) { result = lowerActor(result, ctx); flowLap("pass.lowerActor"); }
	if (!jsBackend) { result = lowerVarHoist(result, ctx); flowLap("pass.lowerVarHoist"); }
	if (!jsBackend) { result = lowerRvalueBridge(result, ctx); flowLap("pass.lowerRvalueBridge"); }
	result = lowerExtensionMethod(result, ctx);
	flowLap("pass.lowerExtensionMethod");
	// Field initializers become assignments inside the constructor, so both
	// backends run them in one place and the parent chain reaches them.
	result = jsBackend ? lowerFieldInitializers(result, ctx) : lowerCtorInit(result, ctx);
	flowLap(jsBackend ? "pass.lowerFieldInitializers" : "pass.lowerCtorInit");
	result = lowerNewExpr(result, ctx);
	flowLap("pass.lowerNewExpr");
	// Lift class/actor methods → top-level FunctionDecl. C + Raiser want one
	// uniform shape for codegen; JS keeps `class Foo {}` native (its semantics
	// already match what we want at the source level).
	if (!jsBackend) { result = lowerMethodToFunction(result, ctx); flowLap("pass.lowerMethodToFunction"); }
	if (!jsBackend) { result = lowerLambda(result, ctx); flowLap("pass.lowerLambda"); }
	// Hoist fresh RC-returning calls out of non-RC bindings so the analyzer cleans
	// them (fixes `const has = provide(path).ok` leaking the Result). C/DRC only.
	result = lowerUnionConversions(result, ctx);
	flowLap("pass.lowerUnionConversions");
	if (!jsBackend) { result = lowerCallHoist(result, ctx); flowLap("pass.lowerCallHoist"); }
	result = lowerBuiltins(result, ctx);
	flowLap("pass.lowerBuiltins");
	if (jsBackend) { result = lowerStringLengthJS(result, ctx); flowLap("pass.lowerStringLengthJS"); }
	result = lowerCStringConv(result, ctx);
	flowLap("pass.lowerCStringConv");
	result = lowerClosureEqualities(result, ctx);
	flowLap("pass.lowerClosureEqualities");
	result = lowerOperators(result, ctx);
	flowLap("pass.lowerOperators");
	if (jsBackend) { result = bindCollectionKeyOps(result, ctx); flowLap("pass.bindCollectionKeyOps"); }
	if (!jsBackend) { result = lowerBigIntOps(result, ctx); flowLap("pass.lowerBigIntOps"); }
	if (!jsBackend) { result = lowerStringOps(result, ctx); flowLap("pass.lowerStringOps"); }
	if (jsBackend) { result = lowerJsPointers(result, ctx); flowLap("pass.lowerJsPointers"); }
	if (jsBackend) { result = lowerJsVarParam(result, ctx); flowLap("pass.lowerJsVarParam"); }
	result = spanLower(result, ctx, false);
	flowLap("pass.spanLower");
	result = lowerConditionalExpr(result, ctx);
	flowLap("pass.lowerConditionalExpr");
	// Conditionally-evaluated positions are statements now: the span sources the
	// first run had to leave there are evaluated once ahead of them and split.
	result = spanLower(result, ctx, true);
	flowLap("pass.spanLower#2");
	if (!jsBackend) { result = spanParamExpand(result, ctx); flowLap("pass.spanParamExpand"); }
	// Conditionally-evaluated positions (ternary arm, `&&`/`||` RHS, while-cond)
	// are statements now, so the positional-new hoist that skipped them above can
	// reach them. The pass empties `newArguments` when it lowers, so this second
	// run only sees what the first one refused.
	result = lowerNewExpr(result, ctx);
	flowLap("pass.lowerNewExpr#2");
	if (!jsBackend) { result = lowerUpdateExpr(result, ctx); flowLap("pass.lowerUpdateExpr"); }
	if (!jsBackend) { result = lowerNullable(result, ctx); flowLap("pass.lowerNullable"); }
	if (!jsBackend) { result = projectNarrowedUnions(result, ctx); flowLap("pass.projectNarrowedUnions"); }
	if (jsBackend) { result = lowerUnionTags(result, ctx); flowLap("pass.lowerUnionTags"); }
	if (jsBackend) { result = checkVariantReads(result, ctx, true); flowLap("pass.checkVariantReads"); }
	// C materializes the Maybe struct (above); JS de-materializes it — the two
	// backends are inverse directions of the same T|null lowering. Keeps JS on
	// native null (platform interop) and codegen dumb.
	if (jsBackend) { result = unwrapMaybe(result, ctx); flowLap("pass.unwrapMaybe"); }
	// Enum operands of a BitSet expression still carry their ordinal; turn each
	// into its bit before any backend sees the operator.
	result = lowerBitSet(result, ctx);
	flowLap("pass.lowerBitSet");
	result = lowerDCE(result, ctx);
	flowLap("pass.lowerDCE");
	// The 64-bit pass runs first so the width passes below never see the nodes
	// it consumed.
	if (jsBackend) { result = refuseUnfoldedSizeofJS(result, ctx); flowLap("pass.refuseUnfoldedSizeofJS"); }
	if (jsBackend) { result = lowerNumberBitwiseOperands(result, ctx); flowLap("pass.lowerNumberBitwiseOperands"); }
	if (jsBackend) { result = injectRangeChecksJS(result, ctx); flowLap("pass.injectRangeChecksJS"); }
	if (jsBackend) { result = lowerBigIntJS(result, ctx); flowLap("pass.lowerBigIntJS"); }
	if (jsBackend) { result = lowerFloat32JS(result, ctx); flowLap("pass.lowerFloat32JS"); }
	if (jsBackend) { result = lowerIntArithJS(result, ctx); flowLap("pass.lowerIntArithJS"); }
	if (jsBackend) { result = lowerIntConvJS(result, ctx); flowLap("pass.lowerIntConvJS"); }
	if (jsBackend) { result = lowerAccessJS(result, ctx); flowLap("pass.lowerAccessJS"); }
	// Definitions for the `EnumName_toString` calls the lowerings above emit
	// (enum reverse index + `.toString()`). C injects the same functions at the
	// tail of its native pipeline (transform/native/index.ms); JS has no native
	// pipeline, so its injection lands here — last for the same reason: every
	// pass that can request an enum has already run, and DCE cannot sweep a
	// definition whose only reference is a call the lowerings just created.
	if (jsBackend) { result = lowerEnumToString(result, ctx); flowLap("pass.lowerEnumToString"); }
	result = liftDestructors(result, ctx, !jsBackend);
	flowLap("pass.liftDestructors");
	if (jsBackend) { result = dropLocalTypeLift(result, checkerCtx); flowLap("pass.dropLocalTypeLift"); }
	if (jsBackend) { result = ownModuleScopeTemps(result, checkerCtx); flowLap("pass.ownModuleScopeTemps"); }
	return result;
}

// A binding the lowerings declare at module scope belongs to the module, as one
// the author wrote does. C keeps such a slot apart with static linkage per
// translation unit; a JS bundle is one flat scope, so the slot takes the module
// qualifier every module-level variable carries.
function ownModuleScopeTemps(program: Node, checkerCtx: CheckerContext): Node {
	if (program.kind != NodeKind.Program) return program;
	const pd = program.data as ProgramData;
	for (const s of pd.programStmts) {
		if (s.kind != NodeKind.VariableDecl) continue;
		const sym = s.resolvedSym;
		if (sym == null || hasFlag(sym, SymbolFlag.Global)) continue;
		if (sym.symbolKind != SymbolKind.Variable && sym.symbolKind != SymbolKind.Temp) continue;
		if (sym.modulePath == "") sym.modulePath = checkerCtx.modulePath;
		setFlag(sym, SymbolFlag.Global);
	}
	return program;
}

function dropLocalTypeLift(program: Node, checkerCtx: CheckerContext): Node {
	if (checkerCtx == null || checkerCtx.liftedLocalTypeDecls.length == 0 || program.kind != NodeKind.Program) return program;
	const pd = program.data as ProgramData;
	const kept: Node[] = [];
	for (const s of pd.programStmts) {
		let lifted = false;
		for (const d of checkerCtx.liftedLocalTypeDecls) {
			if (d == s) lifted = true;
		}
		if (!lifted) kept.push(s);
	}
	pd.programStmts = kept;
	return program;
}
