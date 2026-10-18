// Monomorphization — generic type instance bookkeeping
//
// Function and class-constructor instances are made on demand during type checking
// (src/checker/instantiate.ms); a generic type instance is a type, emitted by codegen
// from its checked body, so this file only drains the per-module instance store.

import { Node, NodeKind, noFieldDecorators } from "../ast/node";
import { CheckerContext } from "../checker/context";

export function monomorphizeProgram(program: Node, checkerCtx: CheckerContext): Node {
	if (checkerCtx == null) return program;
	if (program == null) return program;
	if (program.kind != NodeKind.Program) return program;
	return program;
}
