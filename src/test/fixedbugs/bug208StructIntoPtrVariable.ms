// bug208 — a struct value stored into a Ptr variable passed the checker and failed in C
//
// Symptom:    `const x: Ptr<P> | null = v` with `v: P`, the bare `Ptr<P>` form, the assignment
//             `x = v`, and a struct of another type all passed the checker; clang then stopped on
//             "assigning to 'P *' from incompatible type 'P'". The JS backend printed the value.
//
// Root cause: the fitNode layout gate (`isReinterpretUnsafe`) knew pointer vs scalar but not
//             pointer vs struct value, so the struct reached C unconverted.
//
// Fix:        a struct value into a Ptr slot is a layout mismatch, refused with both types named.
//             No address is taken implicitly: the reference's `ptr T` accepts only a `ptr` or `nil`.

import { hasError } from "../handoff/helpers";
import { compileToC } from "../helpers";

const P208 = "struct P208 { a: int32; }\nstruct Q208 { b: int32; }\nconst v: P208 = { a: 1 };\n";

test "bug208: a struct into a nullable Ptr declaration is refused" {
	assert hasError(P208 + "const x: Ptr<P208> | null = v;\n", "Type 'P208' is not assignable to type 'Ptr<P208> | null'");
}

test "bug208: a struct into a bare Ptr declaration is refused" {
	assert hasError(P208 + "const x: Ptr<P208> = v;\n", "Type 'P208' is not assignable to type 'Ptr<P208>'");
}

test "bug208: a struct assigned to a nullable Ptr variable is refused" {
	assert hasError(P208 + "let x: Ptr<P208> | null = null;\nx = v;\n", "Type 'P208' is not assignable to type 'Ptr<P208> | null'");
}

test "bug208: a struct of another type into a Ptr declaration is refused" {
	assert hasError(P208 + "const w: Q208 = { b: 2 };\nconst x: Ptr<P208> | null = w;\n", "Type 'Q208' is not assignable to type 'Ptr<P208> | null'");
}

test "bug208: a struct returned through a Ptr return type is refused" {
	assert hasError(P208 + "function f208(): Ptr<P208> | null { return v; }\n", "Type 'P208' is not assignable to type 'Ptr<P208> | null'");
}

test "bug208: a struct into a Ptr field is refused" {
	assert hasError(P208 + "struct H208 { p: Ptr<P208> | null; }\nconst h: H208 = { p: v };\n", "is not assignable to type 'Ptr<P208> | null'");
}

test "bug208: null and a Ptr value stay accepted" {
	const r = compileToC(P208 + "let x: Ptr<P208> | null = null;\nconst y: Ptr<P208> | null = x;\nx = y;\n");
	assert r.ok, r.error;
}
