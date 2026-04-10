// Meta Callbacks — breaks circular dependency between expand.ms and eval.ms.
// Same pattern as checker/checkerCallbacks.ms.

import { Node } from "../../ast/node";
import { RaiserContext } from "../../raiser/context";

type MacroEvaluatorFn = (program: Node) => RaiserContext;

let macroEvaluatorFn: MacroEvaluatorFn = (program: Node): RaiserContext => {
	return null as unknown as RaiserContext;
};

export function callMacroEvaluator(program: Node): RaiserContext {
	return macroEvaluatorFn(program);
}

export function registerMacroEvaluator(fn: MacroEvaluatorFn): void {
	macroEvaluatorFn = fn;
}
