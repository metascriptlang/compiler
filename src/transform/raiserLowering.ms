// Raiser-specific lowering subset — only semantic transforms, no C-backend transforms.
//
// Ordering matches the proven transformProgram pipeline (1000+ tests):
//   lowerConstFold before lowerMatch (patterns resolved)

import { Node } from "../ast/node";
import { CheckerContext } from "../checker/context";
import { createTransformContextWithChecker, TransformContext } from "./context";
import { lowerDefer } from "./lowering/deferLower";
import { lowerConstFold } from "./coercion/constantFolding";
import { lowerImplicitConv } from "./coercion/implicitConvLower";
import { unwrapMaybe } from "./native/maybeUnwrap";
import { lowerOptionalChain } from "./coercion/optionalChain";
import { lowerNullishCoalesce } from "./coercion/nullishCoalesce";
import { lowerTypeCoercion } from "./coercion/typeCoercion";
import { lowerRestParams } from "./lowering/restParamLower";
import { lowerDestructuring } from "./desugar/destructuringLower";
import { lowerSpread } from "./desugar/spreadExpand";
import { lowerForLoop } from "./lowering/forLoopLower";
import { lowerForOf } from "./lowering/forOfLower";
import { retargetJumps } from "./lowering/jumpRetarget";
import { lowerObjectSpreadEager } from "./desugar/objectSpreadLower";
import { lowerArraySpreadEager } from "./desugar/arraySpreadLower";
import { lowerTryExpr, lowerResultConstructors } from "./desugar/resultDesugar";
import { lowerMatch } from "./lowering/matchLower";
import { lowerSwitch } from "./lowering/switchLower";
import { lowerLambda } from "./lowering/lambdaLifting";
import { lowerGenerator } from "./lowering/generatorLower";
import { lowerCtorInit } from "./lowering/ctorLower";
import { lowerNewExpr } from "./lowering/newExprLower";
import { lowerExtensionMethod } from "./lowering/extensionMethodLower";
import { lowerBorrow } from "./lowering/borrowLower";
import { lowerPointerAddresses } from "./lowering/pointerAddressLower";
import { insertVarParamDerefs } from "./native/varParamDeref";
import { lowerBitSet } from "./lowering/bitSetLower";
import { lowerAggregateEquality, lowerUserOperators } from "./lowering/operatorLower";
import { projectTaggedMaybeReads } from "./coercion/maybeReadMaterialize";
import { lowerUnionTags } from "./lowering/unionTagLower";
import { liftDestructors } from "./lowering/destructorLifting";
import { injectEnumRangeChecks } from "./native/rangeCheckInject";
import { enterCompilerFuncs, leaveCompilerFuncs } from "./util";

export function transformForRaiser(program: Node, checkerCtx: CheckerContext): Node {
	const ctx = createTransformContextWithChecker(checkerCtx);
	ctx.raiserBackend = true;
	ctx.keepBuiltinMemberCalls = true;  // Raiser has special-case opcodes for arr.push/console.*/etc.
	const outer = enterCompilerFuncs(checkerCtx.compilerFuncs, checkerCtx.table.identCache);
	try {
		return lowerForRaiser(program, ctx);
	} finally {
		leaveCompilerFuncs(outer);
	}
}

function lowerForRaiser(program: Node, ctx: TransformContext): Node {
	let result = lowerPointerAddresses(program, ctx, false);
	result = lowerBorrow(result, ctx);
	result = lowerImplicitConv(result, ctx);
	result = lowerDefer(result, ctx);
	result = lowerConstFold(result, ctx);
	result = lowerRestParams(result, ctx);
	result = lowerObjectSpreadEager(result, ctx);
	result = lowerArraySpreadEager(result, ctx);
	result = lowerOptionalChain(result, ctx);
	result = lowerNullishCoalesce(result, ctx);
	result = lowerTypeCoercion(result, ctx);
	result = lowerDestructuring(result, ctx);
	result = lowerSpread(result, ctx);
	result = lowerForLoop(result, ctx);
	result = lowerForOf(result, ctx);
	result = lowerTryExpr(result, ctx);
	// Result.ok/err are `static extern` (no body, no nativeName) — Raiser
	// cannot dispatch via either funcMap or CallHost. Desugar to ObjectLiteral
	// here, matching the JS-backend pattern (transform/index.ms:91). Without
	// this, calls to Result.ok/err fall through to compileClosureCall →
	// LoadField on Nil → "object handle out of bounds: 0".
	result = lowerResultConstructors(result);
	result = lowerSwitch(result, ctx);
	result = lowerMatch(result, ctx);
	result = retargetJumps(result, ctx);
	result = lowerGenerator(result, ctx);
	result = lowerCtorInit(result, ctx);
	result = lowerNewExpr(result, ctx);
	result = lowerLambda(result, ctx);
	result = lowerExtensionMethod(result, ctx);
	result = lowerBitSet(result, ctx);
	result = lowerAggregateEquality(result, ctx);
	result = lowerUserOperators(result, ctx);
	result = injectEnumRangeChecks(result, ctx);
	result = projectTaggedMaybeReads(result);
	result = lowerUnionTags(result, ctx);
	result = unwrapMaybe(result, ctx);
	result = liftDestructors(result, ctx, false);
	result = insertVarParamDerefs(result, ctx);
	return result;
}

// ===== Tests =====

import { parseInput } from "./testUtil";
import { checkProgram } from "../checker/checkPass";
import { walkNode } from "./walker";
import { NodeKind, Symbol, SymbolKind } from "../ast/node";
import { makeSymbol } from "../checker/symbol";
import { compilerFuncSym } from "./util";

test "the raiser lowering names runtime procs from its own std, not from the last backend transformed" {
	const parsed = parseInput("enum Color { Red, Green, Blue }\nfunction raw(): int32 { return 9; }\nconst c = raw() as Color;");
	assert parsed.ok;
	const checkerCtx = checkProgram(parsed.value);
	const foreign = new HashMap<string, Symbol>();
	const jsHelper = makeSymbol("msCheckRangeI32", SymbolKind.Function, null, false);
	foreign.set("msCheckRangeI32", jsHelper);
	const saved = enterCompilerFuncs(foreign, checkerCtx.table.identCache);
	const lowered = transformForRaiser(parsed.value, checkerCtx);
	const restored = compilerFuncSym("msCheckRangeI32");
	leaveCompilerFuncs(saved);
	let check: Symbol | null = null;
	walkNode(lowered, (n: Node): Node => {
		if (n.kind == NodeKind.CallExpr && n.resolvedSym != null && n.resolvedSym.name == "msCheckRangeI32") check = n.resolvedSym;
		return n;
	});
	assert check != null;
	assert check != jsHelper;
	assert restored == jsHelper;
}
