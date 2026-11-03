// Route 14: Union variant narrowing via as-cast
//
// After `const d = data as VariantType`, member access on d must resolve
// a symbol (resolvedSym) so codegen can emit correct field access.
// Standard reference parity: lookupInRecordAndBuildCheck searches the record field list directly.

import { checkSource, hasError, strictErrorCount } from "./helpers";
import { compileToC } from "../helpers";
import { hasErrors } from "../../checker/context";

test "as-cast on union: field access resolves without errors" {
	const src = "type Data = | { value: number } | { name: string };\ntype NameData = { name: string };\nconst d: Data = { name: \"hello\" };\nconst nd = d as NameData;\nconst v: string = nd.name;";
	const ctx = checkSource(src);
	assert ctx != null;
	assert !hasErrors(ctx);
}

test "as-cast: overlapping field names resolve correct type" {
	const src = "type Data = | { value: number } | { value: string };\ntype StrData = { value: string };\nconst d: Data = { value: \"hello\" };\nconst sd = d as StrData;\nconst v: string = sd.value;";
	const ctx = checkSource(src);
	assert ctx != null;
	// After as-cast, sd.value should be string, not number
	assert !hasErrors(ctx);
}

// ===== Subset cast resolves to full variant (C emission: unionNarrow.ms) =====

test "E2E C: subset as-cast compiles without type mismatch" {
	// Regression: subset `as { flat: number }` must not generate a separate anonymous struct
	const src = "type DocData = | { text: string } | { flat: number, broken: number };\nfunction test1(d: DocData): number {\nconst a = d as { flat: number, broken: number };\nreturn a.flat;\n}\nfunction test2(d: DocData): number {\nconst b = d as { flat: number };\nreturn b.flat;\n}";
	const result = compileToC(src);
	assert result.ok;
	// Both functions should compile — no msAnon type mismatch
}

const structArms = `struct Q { n: int32; }
struct A { v: int32[]; a: int32; }
struct B { v: Q; b: string; }
type AB = A | B;
`;

test "a union read narrowed to one member is refused into a sibling member's slot by assignment" {
	assert hasError(structArms + `function run(): void {
	const one: AB = { v: [1], a: 1 } as A;
	const two: AB = { v: { n: 5 }, b: "b" } as B;
	let c1 = one;
	c1 = two;
}`, "Type 'B' is not assignable to type 'A'");
}

test "a union read narrowed to one member is refused into a sibling member's slot by initialization" {
	assert hasError(structArms + `function run(x: AB): void {
	if ("b" in x) {
		const d: A = x;
	}
}`, "Type 'B' is not assignable to type 'A'");
}

test "a scalar union read narrowed to one member is refused into another member's type" {
	assert hasError(`function run(): void {
	let w: int32 | string = 3;
	let s: string = "s";
	s = w;
}`, "is not assignable to type 'string'");
}

test "a union read narrowed to one member still fits its own member's slot and the declared union" {
	assert strictErrorCount(structArms + `function run(x: AB): void {
	const two: AB = { v: { n: 5 }, b: "b" } as B;
	const d: B = two;
	let c: AB = two;
	if ("a" in x) {
		const e: A = x;
		c = x;
	}
}`) == 0;
}

test "a destructuring assignment target takes its declared union, not the arm it was narrowed to" {
	assert strictErrorCount(structArms + `struct Box { p: AB; q: AB; }
function run(): void {
	let p: AB = { v: [1], a: 1 } as A;
	let q: AB = { v: { n: 5 }, b: "b" } as B;
	[p, q] = [q, p];
	let box: Box = { p: p, q: q };
	[box.p, box.q] = [box.q, box.p];
}`) == 0;
}
