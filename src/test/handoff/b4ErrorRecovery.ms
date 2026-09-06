// Phase 3 Batch 4 guard — Error-scrutiny for post-addError recovery sites.
// NIM-REF.md row 58 (kind split), final batch.
//
// A site that has ALREADY reported an error must recover with TypeKind.Error
// (Nim: errorType after localError), not Inferred — Inferred means "inference
// in progress" and feeds the return-inference machine and the compat leniency
// gates, which B4 scopes to genuine inference.
//
// The load-bearing asymmetry: the SILENT probe paths (line === 0, inference-
// time resolution with no source location) must KEEP returning Inferred. An
// Error type in a zero-diagnostic build is pointer-shaped at
// isPointerShapedForUnknown and would resurrect the §5 corruption family.

import { TypeKind } from "../../ast/node";
import { resolveAnnotation } from "../../checker/resolvePass";
import { hasErrors, errorCount } from "../../checker/context";
import { checkSource } from "./helpers";
import { lookupSymbol } from "../../checker/symbol";

test "reported 'any' resolves to Error, silent probe stays Inferred" {
	const ctx = checkSource("const _p: number = 0;");
	assert ctx != null;
	assert resolveAnnotation("any", ctx, 1, 1).kind == TypeKind.Error;
	assert hasErrors(ctx);
	const silent = checkSource("const _p: number = 0;");
	assert resolveAnnotation("any", silent, 0, 0).kind == TypeKind.Inferred;
	assert !hasErrors(silent);
}

test "reported unresolved type name resolves to Error, silent probe stays Inferred" {
	const ctx = checkSource("const _p: number = 0;");
	assert ctx != null;
	assert resolveAnnotation("NoSuchTypeZz", ctx, 1, 1).kind == TypeKind.Error;
	assert hasErrors(ctx);
	const silent = checkSource("const _p: number = 0;");
	assert resolveAnnotation("NoSuchTypeZz", silent, 0, 0).kind == TypeKind.Inferred;
	assert !hasErrors(silent);
}

test "cyclic interface extends errors once, no cascade" {
	const ctx = checkSource("interface A extends A { }");
	assert ctx != null;
	assert hasErrors(ctx);
	assert errorCount(ctx) == 1;
}

test "template arity mismatch types the call as Error" {
	const ctx = checkSource("template tw<T>(a: T): boolean { return a == a; }\nconst r = tw(1, 2);");
	assert ctx != null;
	assert hasErrors(ctx);
	const sym = lookupSymbol(ctx.table, "r");
	assert sym != null;
	assert sym.symbolType.kind == TypeKind.Error;
}
