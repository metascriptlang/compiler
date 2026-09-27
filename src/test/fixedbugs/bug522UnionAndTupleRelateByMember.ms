// bug522 — any union was assignable to any union, and any tuple to any tuple
//
// Symptom:    `string | int32` passed into a `boolean | string` parameter (C read the int32 payload
//             as a string and panicked), `string | null` passed into `number | boolean`, and
//             `[int32, string]` passed into `[string, int32]` (clang: incompatible tuple structs).
//
// Root cause: the same-kind arm of isAssignable had no Union or Tuple case and fell to `true`; the
//             `string | null` carrier then passed as a struct that "needs a conversion" to a union.
//
// Fix:        a union relates member by member and only onto the same slot layout (tag = member
//             index); a tuple relates element-wise, as the reference's recordRel; a struct reaches a
//             union only through a member it is assignable to.

import { hasError } from "../handoff/helpers";
import { compileToC } from "../helpers";

test "bug522: a union member that fits no target member is refused" {
	assert hasError("function keep(x: boolean | string): void {}\nfunction f(v: string | int32): void { keep(v); }\n", "Argument type mismatch in 'keep' arg 0");
}

test "bug522: a union into a wider union of another layout is refused" {
	assert hasError("function show(x: string | int32 | boolean): void {}\nfunction f(v: string | int32): void { show(v); }\n", "Argument type mismatch in 'show' arg 0");
}

test "bug522: a nullable carrier does not pass as an unrelated union" {
	assert hasError("function mk(): string | null { return \"x\"; }\nconst u = mk();\nconst w: int32 | boolean = u;\n", "is not assignable to type 'int32 | boolean'");
}

test "bug522: tuples relate element by element at argument and declaration" {
	const pre = "const a: [int32, string] = [5, \"five\"];\n";
	assert hasError(pre + "function show(t: [string, int32]): void {}\nshow(a);\n", "Argument type mismatch in 'show' arg 0");
	assert hasError(pre + "const b: [string, int32] = a;\n", "Type 'Tuple' is not assignable to type 'Tuple'");
}

test "bug522: the same union, a nullable reference in either order and the same tuple stay assignable" {
	const r = compileToC("class N522 { v: int32; constructor() { this.v = 1; } }\n"
		+ "function g(x: string | int32): void {}\nfunction f(v: string | int32): void { g(v); }\n"
		+ "function h(n: null | N522): N522 | null { return n; }\n"
		+ "const a: [int32, string] = [5, \"five\"];\nconst b: [int32, string] = a;\n");
	assert r.ok, r.error;
}
