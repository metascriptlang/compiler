// DRC Analyzer Hub — entry point for Phase 4 (RC injection)
//
// Pipeline: parse → check → transform → **analyze** → codegen
//
// Re-exports the public API from all sub-modules.
// analyzeProgram is the main entry point called from src/index.ms.

import { Node, NodeKind, ProgramData } from "../ast/node";
import { CheckerContext, GcMode } from "../checker/context";
import { createTransformContextWithChecker } from "../transform/context";
import { createDrcContext, pushScope, popScope } from "./scope";
import { injectProgram } from "./inject";
import { optimizeDrc } from "./optimize";
import { classifyType, RcKind, noRcInfo } from "./classify";
import { isLastReadInBlock } from "./lastRead";
import { AliasKind, aliases, deepAliases, isAnalysableFieldAccess, skipConvDfa, getRootSym } from "./alias";

import { parseSource } from "../parser/statements/validation";
import { checkProgram } from "../checker/checkPass";
import { transformProgram } from "../transform/index";

// ===== Public Entry Point =====

export function analyzeProgram(program: Node, checkerCtx: CheckerContext): Node {
	if (checkerCtx == null) return program;  // test mode — skip analysis
	if (checkerCtx.gcMode == GcMode.None || checkerCtx.gcMode == GcMode.Manual) return program;
	const ctx = createTransformContextWithChecker(checkerCtx);
	const dctx = createDrcContext(ctx);
	const injected = injectProgram(program, dctx);
	return optimizeDrc(injected);
}

// ===== Re-exports =====

export { classifyType, RcKind, noRcInfo } from "./classify";
export { isLastReadInBlock } from "./lastRead";
export { AliasKind, aliases, deepAliases, isAnalysableFieldAccess, skipConvDfa, getRootSym } from "./alias";
export { injectProgram } from "./inject";
export { optimizeDrc } from "./optimize";
export {
	DrcContext, createDrcContext, pushScope, popScope, currentScope,
	registerVar, recordMove,
} from "./scope";

// ===== Integration Tests =====

function analyzePipeline(input: string): Node {
	const parseResult = parseSource(input);
	if (!parseResult.ok) return null as unknown as Node;
	const program = parseResult.value;
	const checkerCtx = checkProgram(program);
	const transformed = transformProgram(program, checkerCtx, false);
	return analyzeProgram(transformed, checkerCtx);
}

function getStmtCount(program: Node): number {
	if (program == null) return 0;
	if (program.kind != NodeKind.Program) return 0;
	const d = program.data as ProgramData;
	return d.programStmts.length;
}

test "primitives pass through unchanged" {
	const result = analyzePipeline("const x = 1; const y = 2;");
	assert result != null;
	// Primitive-only code: no RC calls inserted
	assert getStmtCount(result) == 2;
}

test "null checker skips analysis" {
	const parseResult = parseSource("const x = 1;");
	if (!parseResult.ok) {
		assert false;
		return;
	}
	const program = parseResult.value;
	const result = analyzeProgram(program, null as unknown as CheckerContext);
	assert result != null;
	// Should return program unchanged
	assert getStmtCount(result) == 1;
}

test "function with primitives" {
	const result = analyzePipeline("function add(a: number, b: number): number { return a + b; }");
	assert result != null;
}

test "empty program" {
	const result = analyzePipeline("");
	assert result != null;
	assert getStmtCount(result) == 0;
}

// Phase E field-level move patterns are covered by the full integration test suite (2186+ tests).
// The field-level CFG, alias-aware BFS, and injection paths are validated end-to-end
// through compile-and-run tests rather than isolated AST inspection.
