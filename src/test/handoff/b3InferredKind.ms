// Phase 3 Batch 3 guard for TypeKind.Inferred — NIM-REF.md row 58 (kind split);
// canonical kind semantics: the sentinel-kind map at unknownType (checker/types.ms).
//
// Inferred answers "inference in progress / signature intentionally open"
// (Nim analog: tyInferred — constraint in base, candidate in last). Distinct
// from Pending ("legacy sentinel, dies in B4"), None ("nothing to say"), and
// user unknown (pointer-shaped top type).
//
// The load-bearing direction, same as None: Inferred must NEVER be
// pointer-shaped. The compat leniency gates exist FOR Inferred — B4 scopes
// them to it exclusively.

import { TypeKind } from "../../ast/node";
import { inferredType, noneType, isUnknownType, isPointerShapedForUnknown, typeDisplayName, numberType } from "../../checker/types";
import { isAssignable, typeRelation, TypeRelation } from "../../checker/compat";
import { isPointerType, getTypeDesc } from "../../codegen/c/types";
import { createCGen } from "../../codegen/c/context";
import { hasErrors } from "../../checker/context";
import { checkSource } from "./helpers";
import { resolveSimpleTypeStr } from "../../transform/util";
import { createTransformContext, freshTempSym } from "../../transform/context";

test "Inferred is its own kind, not Pending, not None, not user unknown" {
	assert inferredType().kind == TypeKind.Inferred;
	assert inferredType().kind != TypeKind.Pending;
	assert inferredType().kind != noneType().kind;
	assert !isUnknownType(inferredType());
}

test "checker and ABI readers agree Inferred is not a pointer" {
	assert !isPointerShapedForUnknown(inferredType());
	assert !isPointerType(inferredType());
}

test "Inferred stays lenient in assignability — open signatures must match" {
	assert isAssignable(inferredType(), numberType());
	assert isAssignable(numberType(), inferredType());
}

test "Inferred scores as generic in overload relation" {
	assert typeRelation(inferredType(), numberType()) == TypeRelation.Generic;
	assert typeRelation(numberType(), inferredType()) == TypeRelation.Generic;
}

test "Inferred displays as <inferring>" {
	assert typeDisplayName(inferredType()) == "<inferring>";
}

test "producer: empty annotation resolves to None, not Pending" {
	// Group A flip — transform/util.ms resolveSimpleTypeStr. Pre-B3 both
	// arms returned the Pending sentinel; the cell discriminates the flip.
	assert resolveSimpleTypeStr("").kind == TypeKind.None;
	assert resolveSimpleTypeStr("SomeNominalType").kind == TypeKind.None;
}

test "producer: an untyped transform temp carries None, not Pending" {
	// Group A flip — transform/context.ms freshTempSym null fallback.
	const ctx = createTransformContext();
	const sym = freshTempSym(ctx, "probe", null);
	assert sym.symbolType.kind == TypeKind.None;
}

test "Inferred at getTypeDesc raises the internal error (B4, Nim else-branch)" {
	// Inverted 2026-08-06 when B4 armed the seam: an unresolved Inferred
	// reaching emission is a compiler bug (tyInferred never arrives raw at cgen).
	const ctx = checkSource("function main(): void { }");
	assert ctx != null;
	const g = createCGen(ctx, "gate.ms");
	getTypeDesc(g, inferredType());
	assert hasErrors(ctx), "seam went silent again — gateFlaglessUnknown must addError (codegen/c/types.ms)";
}
