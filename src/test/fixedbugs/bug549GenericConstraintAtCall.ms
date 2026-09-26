// bug549 — a generic constraint was not enforced at a call and a constrained class did not resolve
//
// Symptom:    `getF<Baz>(z)`, `getF(z)` and `num("str")` against `T extends Foo` / `T extends number`
//             compiled and ran; `class Box<T extends Foo>` failed with "Unresolved type 'T:Foo'" as
//             soon as it was instantiated.
//
// Root cause: the call binder bound T without consulting the parameter's constraint, and the
//             parser's `T:Foo` spelling of a constrained parameter reached every consumer that wanted
//             the bare name (explicit type-argument binding, the method receiver type, field
//             instantiation, the constructor instance, codegen's body substitution).
//
// Fix:        as Nim sigmatch.nim:2019 (a failed constraint is isNone), every binding is related to
//             its parameter's constraint at a generic call and at `new C<X>`; a member read on a
//             constrained parameter resolves against the constraint; consumers that bind by name
//             read the parameter names without their `:constraint` suffix.

import { errorCount, hasError } from "../handoff/helpers";

const DECL549 = "interface Foo549 { zzqw: int32; }\ninterface Baz549 { other: string; }\nfunction getF549<T extends Foo549>(v: T): int32 { return v.zzqw; }\nfunction num549<T extends number>(v: T): T { return v; }\n";
const UNMET549 = "does not satisfy constraint";

test "bug549: an explicit or inferred binding that misses its constraint is refused" {
	assert hasError(DECL549 + "const z: Baz549 = { other: \"x\" };\nconst a = getF549<Baz549>(z);\n", UNMET549 + " 'Foo549' for type parameter 'T' in 'getF549'");
	assert hasError(DECL549 + "const z: Baz549 = { other: \"x\" };\nconst a = getF549(z);\n", UNMET549 + " 'Foo549'");
	assert hasError(DECL549 + "const s = num549(\"str\");\n", UNMET549 + " 'number'");
}

test "bug549: a binding that meets its constraint stays accepted" {
	assert errorCount(DECL549 + "const f: Foo549 = { zzqw: 7 };\nconst a = getF549(f);\nconst b = num549(5 as int32);\n") == 0;
}

test "bug549: a constrained class instantiates, reads through its constraint and checks `new`" {
	const cls = "interface Foo549c { zzqw: int32; }\ninterface Bar549c { other: string; }\nclass Box549<T extends Foo549c> {\n\tv: T;\n\tconstructor(v: T) { this.v = v; }\n\tget(): int32 { return this.v.zzqw; }\n}\n";
	assert errorCount(cls + "const f: Foo549c = { zzqw: 7 };\nconst b = new Box549<Foo549c>(f);\nconst n = b.get();\n") == 0;
	assert hasError(cls + "const z: Bar549c = { other: \"x\" };\nconst b = new Box549<Bar549c>(z);\n", UNMET549 + " 'Foo549c' for type parameter 'T' in 'Box549'");
}
