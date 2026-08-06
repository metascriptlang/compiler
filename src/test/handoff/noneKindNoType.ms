// Phase 3 Batch 2 guard for TypeKind.None — docs/UNKNOWN-BUG.md §8.
//
// None answers "this node kind has no type" (RegexLiteral / QuoteExpr / JSXText
// and the JSX element family), distinct from Pending ("inference not finished")
// and Error ("check failed"). Nim analog: tyNone.
//
// The load-bearing direction: None must NEVER become pointer-shaped. A
// pointer-shaped answer for a non-pointer value is the §5 corruption family.

import { TypeKind } from "../../ast/node";
import { noneType, pendingType, isUnknownType, isPointerShapedForUnknown, typeDisplayName, numberType } from "../../checker/types";
import { isAssignable, typeRelation, TypeRelation } from "../../checker/compat";
import { isPointerType, getTypeDesc } from "../../codegen/c/types";
import { createCGen } from "../../codegen/c/context";
import { hasErrors } from "../../checker/context";
import { checkSource } from "./helpers";
import { lookupSymbol } from "../../checker/symbol";

test "producer: a regex literal's binding carries TypeKind.None" {
	// Pre-Batch-2 this read TypeKind.Pending — the cell discriminates the flip.
	const ctx = checkSource("const r = /ab+/;");
	assert ctx !== null;
	assert !hasErrors(ctx);
	const sym = lookupSymbol(ctx.table, "r");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.None;
}

test "None is its own kind, not Pending, not user unknown" {
	assert noneType().kind === TypeKind.None;
	assert noneType().kind !== pendingType().kind;
	assert !isUnknownType(noneType());
}

test "checker and ABI readers agree None is not a pointer" {
	assert !isPointerShapedForUnknown(noneType());
	assert !isPointerType(noneType());
}

test "None stays lenient in assignability — JSX macro args must keep matching" {
	assert isAssignable(noneType(), numberType());
	assert isAssignable(numberType(), noneType());
}

test "None scores as generic in overload relation" {
	assert typeRelation(noneType(), numberType()) === TypeRelation.Generic;
	assert typeRelation(numberType(), noneType()) === TypeRelation.Generic;
}

test "None displays as <none>" {
	assert typeDisplayName(noneType()) === "<none>";
}

test "DEBT: None at getTypeDesc emits void* silently" {
	// Mirrors the Pending DEBT cell: when Phase 3's exit criterion lands
	// (pendingType() unconstructible), this must flip to assert an error —
	// a None type reaching emission is a compiler bug, Nim's else-branch.
	const ctx = checkSource("function main(): void { }");
	assert ctx !== null;
	const g = createCGen(ctx, "gate.ms");
	assert getTypeDesc(g, noneType()) === "void*";
	assert !hasErrors(ctx), "emission now errors on None — flip this cell, docs/UNKNOWN-BUG.md §8";
}
