// bug537 — a diagnostic named an object type '<kind:Ref>' or by its synthesized '__anon…' name
//
// Symptom:    `function f(o: { a: int32 }): void {}` then `f(3)` said "expected <kind:Ref>", and an
//             unannotated `{ a: 1, b: "s" }` into an int32 slot said "Type '__anon2__ai__bs'".
//
// Root cause: object types became references to a nameless struct (CK-92), and typeDisplayName had no
//             arm for a reference to a nameless struct; a literal's struct carries the internal
//             anonStructName.
//
// Fix:        a nameless or literal-named object type displays its fields, `{ a: int32; b: string; }`,
//             as TypeScript prints an anonymous object type.

import { hasError } from "../handoff/helpers";

test "bug537: an inline object parameter type displays its fields" {
	assert hasError("function f(o: { a: int32 }): void { console.log(o.a.toString()); }\nf(3);\n", "expected { a: int32; }");
}

test "bug537: an unannotated object literal displays its fields" {
	assert hasError("const o = { a: 1, b: \"s\" };\nconst n: int32 = o;\n", "Type '{ a: int32; b: string; }' is not assignable to type 'int32'");
}

test "bug537: a nullable value type displays as its payload or null" {
	assert hasError("function pick(): string | null { return 3; }\nconsole.log(pick() ?? \"none\");\n", "Type 'int32' is not assignable to type 'string | null'");
}

test "bug537: an object field of object type displays one level deeper" {
	assert hasError("function f(o: { p: { x: int32 } }): void { console.log(o.p.x.toString()); }\nf(3);\n", "expected { p: { x: int32; }; }");
}
