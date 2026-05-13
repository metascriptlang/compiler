// bug023 — Result<T[], E> codegen double-wrap when user T collides with Result's T.
//
// Symptom:    A generic function `function fetch<T>(): Result<T[], string>`
//             instantiated at `fetch<int32>()` produced C struct
//             `Result__...v0 { ok; int32_tArrayArray value; }` — element type
//             was double-wrapped (Array<Array<int32>> instead of Array<int32>).
// Root cause: types.ms `createResult` baked the user's `okType` (which contained
//             user's `GenericParam("T")`) into the Result variant's typeChildren.
//             At Result instantiation time, `instantiateGenericBody` substitutes
//             Result's own "T" → typeChildren[0] over the variant body. Because
//             user's T and Result's T are both named "T", the substitution fired
//             on the BAKED `Array<GenericParam("T")>` and replaced its inner T
//             with `Array<T>` again — producing `Array<Array<T>>`.
// Fix:        Variants now hold Result's own fresh `GenericParam("T")/("E")`
//             placeholders instead of the user's okType/errType. User-supplied
//             types live ONLY in `typeChildren`. `instantiateGenericBody` then
//             substitutes the variant's placeholder T once → `Array<T_user>`
//             (no recursion target collision). Pair fix at MemberExpr in
//             `checkExprPass.ms` calls `instantiateGenericBody` before
//             `peelToStructOrUnion` so field types resolve against the
//             substituted body (Bug 16 family).

import { compileToC } from "../helpers";

test "bug023: Result<T[], E> instantiates as single-wrap Array, not Array<Array<T>>" {
	const src = `
		function fetch<T>(): Result<T[], string> {
			return Result.ok([] as T[]);
		}
		function main(): void {
			const r = fetch<int32>();
			if (r.ok) {
				const arr: int32[] = r.value;
			}
		}
		main();
	`;
	const c = compileToC(src);
	assert c.ok;
	if (c.ok) {
		const out = c.value;
		// The pre-fix bug printed `int32_tArrayArray value` (double wrap).
		// Single-wrap target shape is `int32_tArray value`.
		assert !out.contains("int32_tArrayArray");
		assert out.contains("int32_tArray value");
		// The whole `Result<int32[], string>` mono type name must NOT carry a
		// nested array marker either (e.g. `_arr_arr_`).
		assert !out.contains("Result__arr_arr_int32");
		assert out.contains("Result__arr_int32_string");
	}
}

test "bug023: Result<T[][], E> intentionally double-wraps (user-written nested array)" {
	// Sanity check the fix does not over-correct: when the USER writes T[][],
	// the result really should be Array<Array<T>>, mangled as `arr_arr_`.
	const src = `
		function nested<T>(): Result<T[][], string> {
			return Result.ok([] as T[][]);
		}
		function main(): void {
			const r = nested<int32>();
			if (r.ok) {
				const arr: int32[][] = r.value;
			}
		}
		main();
	`;
	const c = compileToC(src);
	assert c.ok;
	if (c.ok) {
		const out = c.value;
		// User asked for T[][], so int32_tArrayArray IS the correct output here.
		assert out.contains("int32_tArrayArray value");
		assert out.contains("Result__arr_arr_int32_string");
	}
}
