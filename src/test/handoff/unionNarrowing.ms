// Route 14: Union variant narrowing via as-cast
//
// After `const d = data as VariantType`, member access on d must resolve
// a symbol (resolvedSym) so codegen can emit correct field access.
// Nim parity: lookupInRecordAndBuildCheck searches the record field list directly.

import { checkSource } from "./helpers";
import { hasErrors } from "../../checker/context";

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
