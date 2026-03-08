// Phase Handoff Test Helpers
//
// Shared utilities for running the compiler pipeline up to specific phases.

import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { checkProgram } from "../../checker/checkPass";
import { CheckerContext } from "../../checker/context";
import { monomorphizeProgram } from "../../monomorphize/collect";
import { validateTypedAST } from "../../checker/validate";
import { transformProgram } from "../../transform/index";
import { transformForNative } from "../../transform/native/index";
import { createTransformContextWithChecker } from "../../transform/context";
import { Node, NodeKind, ProgramData, FunctionDeclData } from "../../ast/node";

export function checkSource(source: string): CheckerContext {
	const pr = parseSource(source);
	if (!pr.ok) return null as unknown as CheckerContext;
	return checkProgram(pr.value);
}

export function fullPipeline(source: string): Node {
	const pr = parseSource(source);
	if (!pr.ok) return null as unknown as Node;
	const ctx = checkProgram(pr.value);
	const monoed = monomorphizeProgram(pr.value, ctx);
	validateTypedAST(ctx, monoed);
	const transformed = transformProgram(monoed, ctx, false);
	const nativeCtx = createTransformContextWithChecker(ctx);
	return transformForNative(transformed, nativeCtx);
}

// Find a FunctionDecl by name in the program's top-level statements
export function findFnDecl(program: Node, name: string): Node {
	if (program === null || program.kind !== NodeKind.Program) return null as unknown as Node;
	const pd = program.data as ProgramData;
	let i = 0;
	while (i < pd.programStmts.length) {
		const stmt = pd.programStmts[i];
		if (stmt.kind === NodeKind.FunctionDecl) {
			const fd = stmt.data as FunctionDeclData;
			if (fd.fnName === name) return stmt;
		}
		i = i + 1;
	}
	return null as unknown as Node;
}
