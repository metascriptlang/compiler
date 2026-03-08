// Route 14: Union variant narrowing via as-cast
//
// When a discriminated union has multiple variants with the same first field
// name but different types (e.g. { value: number } | { value: string }),
// the as-cast must pick the correct variant based on field types.

import { checkSource } from "./helpers";
import { lookupSymbol } from "../../checker/symbol";
import { TypeKind } from "../../checker/types";
import { hasErrors } from "../../checker/context";

test "as-cast picks string variant not number variant" {
	const src = "type Data = | { value: number } | { value: string };\ntype StrData = { value: string };\nconst d: Data = { value: \"hello\" };\nconst sd = d as StrData;\nconst v: string = sd.value;";
	const ctx = checkSource(src);
	assert ctx !== null;
	assert !hasErrors(ctx);
}

test "as-cast picks number variant correctly" {
	const src = "type Data = | { value: number } | { value: string };\ntype NumData = { value: number };\nconst d: Data = { value: 42 };\nconst nd = d as NumData;\nconst v: number = nd.value;";
	const ctx = checkSource(src);
	assert ctx !== null;
	assert !hasErrors(ctx);
}
