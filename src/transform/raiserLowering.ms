// Raiser-specific lowering subset — only semantic transforms, no C-backend transforms.
// Skips lambdaLifting, destructorLifting, DCE, generators, string ops, etc.
// The Raiser VM handles ForStmt/ForOfStmt, closures, ternary, update natively.
//
// Ordering matches the proven transformProgram pipeline (1000+ tests):
//   lowerConstFold before lowerMatch (patterns resolved)
//   lowerTryExpr before lowerResultFieldCheck (desugar first, then validate)

import { Node } from "../ast/node";
import { CheckerContext } from "../checker/context";
import { createTransformContextWithChecker } from "./context";
import { lowerDefer } from "./lowering/deferLower";
import { lowerConstFold } from "./coercion/constantFolding";
import { lowerOptionalChain } from "./coercion/optionalChain";
import { lowerNullishCoalesce } from "./coercion/nullishCoalesce";
import { lowerTypeCoercion } from "./coercion/typeCoercion";
import { lowerDestructuring } from "./desugar/destructuringLower";
import { lowerSpread } from "./desugar/spreadExpand";
import { lowerTryExpr, lowerResultConstructors } from "./desugar/resultDesugar";
import { lowerResultFieldCheck } from "./desugar/resultFieldCheck";
import { lowerMatch } from "./lowering/matchLower";
import { lowerSwitch } from "./lowering/switchLower";
import { lowerLambda } from "./lowering/lambdaLifting";
import { lowerCtorInit } from "./lowering/ctorLower";
import { lowerNewExpr } from "./lowering/newExprLower";
import { lowerExtensionMethod } from "./lowering/extensionMethodLower";

export function transformForRaiser(program: Node, checkerCtx: CheckerContext): Node {
	const ctx = createTransformContextWithChecker(checkerCtx);
	ctx.keepBuiltinMemberCalls = true;  // Raiser has special-case opcodes for arr.push/console.*/etc.
	let result = lowerDefer(program, ctx);
	result = lowerConstFold(result, ctx);
	result = lowerOptionalChain(result, ctx);
	result = lowerNullishCoalesce(result, ctx);
	result = lowerTypeCoercion(result, ctx);
	result = lowerDestructuring(result, ctx);
	result = lowerSpread(result, ctx);
	result = lowerTryExpr(result, ctx);
	// Result.ok/err are `static extern` (no body, no nativeName) — Raiser
	// cannot dispatch via either funcMap or CallHost. Desugar to ObjectLiteral
	// here, matching the JS-backend pattern (transform/index.ms:91). Without
	// this, calls to Result.ok/err fall through to compileClosureCall →
	// LoadField on Nil → "object handle out of bounds: 0".
	result = lowerResultConstructors(result);
	result = lowerResultFieldCheck(result, ctx);
	result = lowerSwitch(result, ctx);
	result = lowerMatch(result, ctx);
	result = lowerCtorInit(result, ctx);
	result = lowerNewExpr(result, ctx);
	result = lowerLambda(result, ctx);
	result = lowerExtensionMethod(result, ctx);
	return result;
}
