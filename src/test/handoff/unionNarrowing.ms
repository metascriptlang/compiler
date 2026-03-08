// Route 14: Union variant narrowing via as-cast
//
// After `const d = data as VariantType`, member access on d must resolve
// a symbol (resolvedSym) so codegen can emit correct field access.
// Standard reference parity: lookupInRecordAndBuildCheck searches the record field list directly.

import { checkSource } from "./helpers";
import { compileToC } from "../helpers";
import { hasErrors } from "../../checker/context";
import { lookupSymbol } from "../../checker/symbol";
import { TypeKind } from "../../checker/types";

test "as-cast on union: field access resolves without errors" {
	const src = "type Data = | { value: number } | { name: string };\ntype NameData = { name: string };\nconst d: Data = { name: \"hello\" };\nconst nd = d as NameData;\nconst v: string = nd.name;";
	const ctx = checkSource(src);
	assert ctx !== null;
	assert !hasErrors(ctx);
}

test "as-cast: overlapping field names resolve correct type" {
	const src = "type Data = | { value: number } | { value: string };\ntype StrData = { value: string };\nconst d: Data = { value: \"hello\" };\nconst sd = d as StrData;\nconst v: string = sd.value;";
	const ctx = checkSource(src);
	assert ctx !== null;
	// After as-cast, sd.value should be string, not number
	assert !hasErrors(ctx);
}

// ===== Subset cast resolves to full variant =====

test "as-cast: subset fields resolve to full variant type" {
	// `as { flat: Doc }` (1 field) must resolve to full variant `{ flat: Doc, broken: Doc }` (2 fields)
	const src = "type DocData = | { text: string } | { children: number[] } | { flat: number, broken: number };\nconst d: DocData = { flat: 1, broken: 2 };\nconst nd = d as { flat: number };";
	const ctx = checkSource(src);
	assert ctx !== null;
	const sym = lookupSymbol(ctx.table, "nd");
	assert sym !== null;
	// nodeType should be full variant (2 fields), not subset (1 field)
	assert sym.symbolType.kind === TypeKind.Struct;
	assert sym.symbolType.typeNames.length === 2;
}

test "E2E C: subset as-cast compiles without type mismatch" {
	// Regression: subset `as { flat: number }` must not generate a separate anonymous struct
	const src = "type DocData = | { text: string } | { flat: number, broken: number };\nfunction test1(d: DocData): number {\nconst a = d as { flat: number, broken: number };\nreturn a.flat;\n}\nfunction test2(d: DocData): number {\nconst b = d as { flat: number };\nreturn b.flat;\n}";
	const result = compileToC(src);
	assert result.ok;
	// Both functions should compile — no msAnon type mismatch
}
