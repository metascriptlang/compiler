// Meta Callbacks — breaks circular dependency between expand.ms and eval.ms.
// Same pattern as checker/checkerCallbacks.ms.

import { Node } from "../../ast/node";
import { RaiserContext } from "../../raiser/context";

type MacroEvaluatorFn = (program: Node) => RaiserContext | null;

let macroEvaluatorFn: MacroEvaluatorFn = (program: Node): RaiserContext | null => {
	return null;
};

export function callMacroEvaluator(program: Node): RaiserContext | null {
	return macroEvaluatorFn(program);
}

export function registerMacroEvaluator(fn: MacroEvaluatorFn): void {
	macroEvaluatorFn = fn;
}
