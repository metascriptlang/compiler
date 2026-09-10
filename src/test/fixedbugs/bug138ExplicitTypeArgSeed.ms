// bug138 — explicit type args lost to argument-driven binding at instantiation
//
// Symptom:    `pair<Animal>(dog, dog2)` generated the `Dog` instance; the
//             explicit `<Animal>` only reached the return type. In
//             `f3<string>("s", 1, "x")` the checker stayed silent on the `B`
//             conflict and clang reported the string-into-int mismatch.
// Root cause: tryInstantiateGenericCallee unified the arguments first and
//             merged the explicit type args afterwards under first-wins, so
//             an explicit binding could only fill gaps, never settle a param
//             the arguments had already bound; the conflict gate was then
//             skipped for the whole call whenever any type arg was explicit.
// Fix:        seed the bindings from the explicit type args before the
//             argument pass; the conflict gate runs on every call and leaves
//             explicit bindings to the formal-level check.

import { hasError } from "../handoff/helpers";
import { compileToC } from "../helpers";

const B138 = "class Animal138 { name: string = \"\"; }\nclass Dog138 extends Animal138 { breed: string = \"\"; }\nfunction pair138<T>(a: T, b: T): T { return a; }\n";

test "bug138: an explicit type arg keys the instance when every argument binds a subclass" {
	const r = compileToC(B138 + "const d1 = new Dog138();\nconst d2 = new Dog138();\nconst c = pair138<Animal138>(d1, d2);\n");
	assert r.ok;
	assert r.value.contains("pair138__ref_Animal138");
	assert !r.value.contains("pair138__ref_Dog138");
}

test "bug138: a conflict on a param not given explicitly is still reported" {
	const src = "function f138<A, B>(a: A, b: B, c: B): B { return b; }\nconst r = f138<string>(\"s\", 1, \"x\");\n";
	assert hasError(src, "Argument type mismatch in 'f138' arg 2: got string, expected int32");
}
