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
import { lowerTryExpr } from "./desugar/resultDesugar";
import { lowerResultFieldCheck } from "./desugar/resultFieldCheck";
import { lowerMatch } from "./lowering/matchLower";

export function transformForRaiser(program: Node, checkerCtx: CheckerContext): Node {
	const ctx = createTransformContextWithChecker(checkerCtx);
	let result = lowerDefer(program, ctx);
	result = lowerConstFold(result, ctx);
	result = lowerOptionalChain(result, ctx);
	result = lowerNullishCoalesce(result, ctx);
	result = lowerTypeCoercion(result, ctx);
	result = lowerDestructuring(result, ctx);
	result = lowerSpread(result, ctx);
	result = lowerTryExpr(result, ctx);
	result = lowerResultFieldCheck(result, ctx);
	result = lowerMatch(result, ctx);
	return result;
}
