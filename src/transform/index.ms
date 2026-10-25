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
import { createTransformContextWithChecker, TransformContext, ModuleFact, mayContain } from "./context";
import { WriteSummaries } from "../analyzer/writeEffects";
import { bindCompilerFuncs } from "./util";
import { checkFactsAfter, factsCheckEnabled } from "./moduleFacts";
import { flowLap, flowMark, flowTally } from "../compiler/flows";
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
	let result = lowerMovedFieldInitTruthiness(lowerCtorInit(program, ctx), ctx, inits);
	if (runs(ctx, fact(ModuleFact.OptionalChain), "pass.lowerFieldInitializers.lowerOptionalChain")) result = lowerOptionalChain(result, ctx);
	if (runs(ctx, fact(ModuleFact.Nullish), "pass.lowerFieldInitializers.lowerNullishCoalesce")) result = lowerNullishCoalesce(result, ctx);
	return ctx.jsBackend ? result : lowerAwaitSpill(result, ctx);
}

function fact(f: ModuleFact): BitSet<ModuleFact> {
	return (0 as BitSet<ModuleFact>).incl(f);
}

function passDone(program: Node, ctx: TransformContext, pass: string): void {
	flowLap(pass);
	if (!factsCheckEnabled()) return;
	checkFactsAfter(program, ctx, pass);
	flowMark();
}

function runs(ctx: TransformContext, need: BitSet<ModuleFact>, pass: string): boolean {
	if (mayContain(ctx, need)) return true;
	flowTally(`skip.${pass}`, 1);
	return false;
}

export function transformProgram(program: Node, checkerCtx: CheckerContext, jsBackend: boolean, reloadableModules: string[] = [], asyncModuleBody: boolean = false, liftTables: WriteSummaries | null = null): Node {
	const ctx = createTransformContextWithChecker(checkerCtx);
	ctx.jsBackend = jsBackend;
	ctx.liftTables = liftTables;
	ctx.reloadableModules = reloadableModules;
	bindCompilerFuncs(checkerCtx.compilerFuncs, checkerCtx.table.identCache);
	flowMark();
	let result = eraseBrandTypes(program, ctx);
	passDone(result, ctx, "pass.eraseBrandTypes");
	if (!jsBackend) { result = lowerActorHandles(result, ctx); passDone(result, ctx, "pass.lowerActorHandles"); }
	if (!jsBackend) { result = planModuleTdz(result, ctx); passDone(result, ctx, "pass.planModuleTdz"); }
	result = lowerBorrow(result, ctx);
	passDone(result, ctx, "pass.lowerBorrow");
	result = lowerImplicitConv(result, ctx);
	passDone(result, ctx, "pass.lowerImplicitConv");
	result = jsBackend ? lowerPowerAssert(result, ctx) : lowerAssert(result, ctx);
	passDone(result, ctx, jsBackend ? "pass.lowerPowerAssert" : "pass.lowerAssert");
	if (runs(ctx, fact(ModuleFact.Defer), "pass.lowerDefer")) result = lowerDefer(result, ctx);
	passDone(result, ctx, "pass.lowerDefer");
	result = lowerConstFold(result, ctx);
	passDone(result, ctx, "pass.lowerConstFold");
	if (!jsBackend) { result = lowerStaticInit(result, ctx); passDone(result, ctx, "pass.lowerStaticInit"); }
	result = lowerVoidBind(result, ctx);
	passDone(result, ctx, "pass.lowerVoidBind");
	if (runs(ctx, fact(ModuleFact.Spread), "pass.lowerObjectSpread")) result = lowerObjectSpread(result, ctx);
	passDone(result, ctx, "pass.lowerObjectSpread");
	if (!jsBackend) {
		if (runs(ctx, fact(ModuleFact.Spread), "pass.lowerArraySpread")) result = lowerArraySpread(result, ctx);
		passDone(result, ctx, "pass.lowerArraySpread");
	}
	if (!jsBackend) { result = lowerStringConcatFlatten(result, ctx); passDone(result, ctx, "pass.lowerStringConcatFlatten"); }
	if (runs(ctx, fact(ModuleFact.OptionalChain), "pass.lowerOptionalChain")) result = lowerOptionalChain(result, ctx);
	passDone(result, ctx, "pass.lowerOptionalChain");
	if (runs(ctx, fact(ModuleFact.Nullish), "pass.lowerNullishCoalesce")) result = lowerNullishCoalesce(result, ctx);
	passDone(result, ctx, "pass.lowerNullishCoalesce");
	result = materializeMaybeReads(result, ctx);
	passDone(result, ctx, "pass.materializeMaybeReads");
	result = lowerStringTruthiness(result, ctx);
	passDone(result, ctx, "pass.lowerStringTruthiness");
	result = lowerRestParams(result, ctx);
	passDone(result, ctx, "pass.lowerRestParams");
	result = lowerDestructuring(result, ctx);
	passDone(result, ctx, "pass.lowerDestructuring");
	if (!jsBackend) { result = lowerForLoop(result, ctx); passDone(result, ctx, "pass.lowerForLoop"); }
	result = lowerForOf(result, ctx);
	passDone(result, ctx, "pass.lowerForOf");
	result = lowerTryExpr(result, ctx);
	passDone(result, ctx, "pass.lowerTryExpr");
	result = lowerResultConstructors(result);
	passDone(result, ctx, "pass.lowerResultConstructors");
	result = lowerTypeof(result, ctx);
	passDone(result, ctx, "pass.lowerTypeof");
	if (runs(ctx, fact(ModuleFact.Switch), "pass.lowerSwitch")) result = lowerSwitch(result, ctx);
	passDone(result, ctx, "pass.lowerSwitch");
	result = lowerMatch(result, ctx);
	passDone(result, ctx, "pass.lowerMatch");
	// A `try` in a match expression arm became a statement only now.
	result = lowerTryExpr(result, ctx);
	passDone(result, ctx, "pass.lowerTryExpr#2");
	result = retargetJumps(result, ctx);
	passDone(result, ctx, "pass.retargetJumps");
	result = lowerTailCall(result, ctx);
	passDone(result, ctx, "pass.lowerTailCall");
	if (!jsBackend) { result = lowerParamReassign(result, ctx); passDone(result, ctx, "pass.lowerParamReassign"); }
	if (asyncModuleBody) { result = lowerAsyncModuleBody(result, ctx); passDone(result, ctx, "pass.lowerAsyncModuleBody"); }
	if (!jsBackend) { result = lowerAwaitSpill(result, ctx); passDone(result, ctx, "pass.lowerAwaitSpill"); }
	if (!jsBackend) { result = lowerNamespaceValues(result); passDone(result, ctx, "pass.lowerNamespaceValues"); }
	if (!jsBackend) { result = lowerActorPre(result, ctx); passDone(result, ctx, "pass.lowerActorPre"); }
	if (!jsBackend) {
		if (runs(ctx, fact(ModuleFact.Await), "pass.lowerSpawnGroup")) result = lowerSpawnGroup(result, ctx);
		passDone(result, ctx, "pass.lowerSpawnGroup");
	}
	if (!jsBackend) { result = lowerHeldSpawns(result, ctx); passDone(result, ctx, "pass.lowerHeldSpawns"); }
	result = lowerPointerAddresses(result, ctx, !jsBackend);
	passDone(result, ctx, "pass.lowerPointerAddresses");
	if (!jsBackend) {
		if (runs(ctx, fact(ModuleFact.Async), "pass.lowerAsync")) result = lowerAsync(result, ctx);
		passDone(result, ctx, "pass.lowerAsync");
	}
	if (!jsBackend) {
		if (runs(ctx, fact(ModuleFact.Async), "pass.lowerAsyncBridge")) result = lowerAsyncBridge(result, ctx);
		passDone(result, ctx, "pass.lowerAsyncBridge");
	}
	// lowerAsyncBridge leaves its split diagnostics and loop locals for lowerGenerator to report.
	if (!jsBackend) {
		if (runs(ctx, fact(ModuleFact.Generator).incl(ModuleFact.Async), "pass.lowerGenerator")) result = lowerGenerator(result, ctx);
		passDone(result, ctx, "pass.lowerGenerator");
	}
	if (!jsBackend) {
		if (runs(ctx, fact(ModuleFact.Spawn), "pass.lowerSpawn")) result = lowerSpawn(result, ctx);
		passDone(result, ctx, "pass.lowerSpawn");
	}
	// lowerSpawn boxes a thunk's return value around its await; spill that before lowerAwait.
	if (!jsBackend) { result = lowerAwaitSpill(result, ctx); passDone(result, ctx, "pass.lowerAwaitSpill#2"); }
	if (!jsBackend) {
		if (runs(ctx, fact(ModuleFact.Await).incl(ModuleFact.Spawn), "pass.lowerAwait")) result = lowerAwait(result, ctx);
		passDone(result, ctx, "pass.lowerAwait");
	}
	if (!jsBackend) { result = lowerFieldInitializers(result, ctx); passDone(result, ctx, "pass.lowerFieldInitializers"); }
	if (!jsBackend) { result = lowerActor(result, ctx); passDone(result, ctx, "pass.lowerActor"); }
	if (!jsBackend) { result = lowerVarHoist(result, ctx); passDone(result, ctx, "pass.lowerVarHoist"); }
	if (!jsBackend) { result = lowerRvalueBridge(result, ctx); passDone(result, ctx, "pass.lowerRvalueBridge"); }
	result = lowerExtensionMethod(result, ctx);
	passDone(result, ctx, "pass.lowerExtensionMethod");
	// Field initializers become assignments inside the constructor, so both
	// backends run them in one place and the parent chain reaches them.
	result = jsBackend ? lowerFieldInitializers(result, ctx) : lowerCtorInit(result, ctx);
	passDone(result, ctx, jsBackend ? "pass.lowerFieldInitializers" : "pass.lowerCtorInit");
	result = lowerNewExpr(result, ctx);
	passDone(result, ctx, "pass.lowerNewExpr");
	// Lift class/actor methods → top-level FunctionDecl. C + Raiser want one
	// uniform shape for codegen; JS keeps `class Foo {}` native (its semantics
	// already match what we want at the source level).
	if (!jsBackend) { result = lowerMethodToFunction(result, ctx); passDone(result, ctx, "pass.lowerMethodToFunction"); }
	if (!jsBackend) { result = lowerLambda(result, ctx); passDone(result, ctx, "pass.lowerLambda"); }
	// Hoist fresh RC-returning calls out of non-RC bindings so the analyzer cleans
	// them (fixes `const has = provide(path).ok` leaking the Result). C/DRC only.
	result = lowerUnionConversions(result, ctx);
	passDone(result, ctx, "pass.lowerUnionConversions");
	if (!jsBackend) { result = lowerCallHoist(result, ctx); passDone(result, ctx, "pass.lowerCallHoist"); }
	result = lowerBuiltins(result, ctx);
	passDone(result, ctx, "pass.lowerBuiltins");
	if (jsBackend) { result = lowerStringLengthJS(result, ctx); passDone(result, ctx, "pass.lowerStringLengthJS"); }
	result = lowerCStringConv(result, ctx);
	passDone(result, ctx, "pass.lowerCStringConv");
	result = lowerClosureEqualities(result, ctx);
	passDone(result, ctx, "pass.lowerClosureEqualities");
	result = lowerOperators(result, ctx);
	passDone(result, ctx, "pass.lowerOperators");
	if (jsBackend) { result = bindCollectionKeyOps(result, ctx); passDone(result, ctx, "pass.bindCollectionKeyOps"); }
	if (!jsBackend) { result = lowerBigIntOps(result, ctx); passDone(result, ctx, "pass.lowerBigIntOps"); }
	if (!jsBackend) { result = lowerStringOps(result, ctx); passDone(result, ctx, "pass.lowerStringOps"); }
	if (jsBackend) { result = lowerJsPointers(result, ctx); passDone(result, ctx, "pass.lowerJsPointers"); }
	if (jsBackend) { result = lowerJsVarParam(result, ctx); passDone(result, ctx, "pass.lowerJsVarParam"); }
	result = spanLower(result, ctx, false);
	passDone(result, ctx, "pass.spanLower");
	result = lowerConditionalExpr(result, ctx);
	passDone(result, ctx, "pass.lowerConditionalExpr");
	// Conditionally-evaluated positions are statements now: the span sources the
	// first run had to leave there are evaluated once ahead of them and split.
	result = spanLower(result, ctx, true);
	passDone(result, ctx, "pass.spanLower#2");
	if (!jsBackend) { result = spanParamExpand(result, ctx); passDone(result, ctx, "pass.spanParamExpand"); }
	// Conditionally-evaluated positions (ternary arm, `&&`/`||` RHS, while-cond)
	// are statements now, so the positional-new hoist that skipped them above can
	// reach them. The pass empties `newArguments` when it lowers, so this second
	// run only sees what the first one refused.
	result = lowerNewExpr(result, ctx);
	passDone(result, ctx, "pass.lowerNewExpr#2");
	if (!jsBackend) { result = lowerUpdateExpr(result, ctx); passDone(result, ctx, "pass.lowerUpdateExpr"); }
	if (!jsBackend) { result = lowerNullable(result, ctx); passDone(result, ctx, "pass.lowerNullable"); }
	if (!jsBackend) { result = projectNarrowedUnions(result, ctx); passDone(result, ctx, "pass.projectNarrowedUnions"); }
	if (jsBackend) { result = lowerUnionTags(result, ctx); passDone(result, ctx, "pass.lowerUnionTags"); }
	if (jsBackend) { result = checkVariantReads(result, ctx, true); passDone(result, ctx, "pass.checkVariantReads"); }
	// C materializes the Maybe struct (above); JS de-materializes it — the two
	// backends are inverse directions of the same T|null lowering. Keeps JS on
	// native null (platform interop) and codegen dumb.
	if (jsBackend) { result = unwrapMaybe(result, ctx); passDone(result, ctx, "pass.unwrapMaybe"); }
	// Enum operands of a BitSet expression still carry their ordinal; turn each
	// into its bit before any backend sees the operator.
	result = lowerBitSet(result, ctx);
	passDone(result, ctx, "pass.lowerBitSet");
	result = lowerDCE(result, ctx);
	passDone(result, ctx, "pass.lowerDCE");
	// The 64-bit pass runs first so the width passes below never see the nodes
	// it consumed.
	if (jsBackend) { result = refuseUnfoldedSizeofJS(result, ctx); passDone(result, ctx, "pass.refuseUnfoldedSizeofJS"); }
	if (jsBackend) { result = lowerNumberBitwiseOperands(result, ctx); passDone(result, ctx, "pass.lowerNumberBitwiseOperands"); }
	if (jsBackend) { result = injectRangeChecksJS(result, ctx); passDone(result, ctx, "pass.injectRangeChecksJS"); }
	if (jsBackend) { result = lowerBigIntJS(result, ctx); passDone(result, ctx, "pass.lowerBigIntJS"); }
	if (jsBackend) { result = lowerFloat32JS(result, ctx); passDone(result, ctx, "pass.lowerFloat32JS"); }
	if (jsBackend) { result = lowerIntArithJS(result, ctx); passDone(result, ctx, "pass.lowerIntArithJS"); }
	if (jsBackend) { result = lowerIntConvJS(result, ctx); passDone(result, ctx, "pass.lowerIntConvJS"); }
	if (jsBackend) { result = lowerAccessJS(result, ctx); passDone(result, ctx, "pass.lowerAccessJS"); }
	// Definitions for the `EnumName_toString` calls the lowerings above emit
	// (enum reverse index + `.toString()`). C injects the same functions at the
	// tail of its native pipeline (transform/native/index.ms); JS has no native
	// pipeline, so its injection lands here — last for the same reason: every
	// pass that can request an enum has already run, and DCE cannot sweep a
	// definition whose only reference is a call the lowerings just created.
	if (jsBackend) { result = lowerEnumToString(result, ctx); passDone(result, ctx, "pass.lowerEnumToString"); }
	result = liftDestructors(result, ctx, !jsBackend);
	passDone(result, ctx, "pass.liftDestructors");
	if (jsBackend) { result = dropLocalTypeLift(result, checkerCtx); passDone(result, ctx, "pass.dropLocalTypeLift"); }
	if (jsBackend) { result = ownModuleScopeTemps(result, checkerCtx); passDone(result, ctx, "pass.ownModuleScopeTemps"); }
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
