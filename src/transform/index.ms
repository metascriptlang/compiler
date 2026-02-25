// Transform Pipeline Runner — applies all AST transforms in order
//
// Fixed order matches reference compiler dependency chain:
// 1. deferLower     — may create try/finally that later transforms see
// 2. optionalChain  — must run BEFORE nullishCoalesce
// 3. nullishCoalesce — sees already-lowered optional chains
// 4. typeCoercion   — simple 1:1 replacement
// 5. forOfLower     — desugars for-of to while
// 6. resultDesugar  — 1:N expansion of try expressions
// 7. matchLower     — sees simplest AST (last)

import { Node } from "../ast/node";
import { TransformContext, createTransformContext } from "./context";
import { lowerDefer } from "./lowering/deferLower";
import { lowerOptionalChain } from "./coercion/optionalChain";
import { lowerNullishCoalesce } from "./coercion/nullishCoalesce";
import { lowerTypeCoercion } from "./coercion/typeCoercion";
import { lowerForOf } from "./lowering/forOfLower";
import { lowerResult } from "./desugar/resultDesugar";
import { lowerMatch } from "./lowering/matchLower";

export function transformProgram(program: Node): Node {
	const ctx = createTransformContext();
	let result = lowerDefer(program, ctx);
	result = lowerOptionalChain(result, ctx);
	result = lowerNullishCoalesce(result, ctx);
	result = lowerTypeCoercion(result, ctx);
	result = lowerForOf(result, ctx);
	result = lowerResult(result, ctx);
	result = lowerMatch(result, ctx);
	return result;
}
