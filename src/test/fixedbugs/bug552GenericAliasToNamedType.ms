// bug552 — an instance of a generic alias whose body names another type was a type of its own
//
// Symptom:    `type Alias<T> = Plain; const a: Alias<string> = new Plain();` failed with "Type 'Plain' is not
//             assignable to type 'Alias'"; a parameter or return slot of that type failed on main already, and
//             C gave the instance a struct of its own, so an alias of a value struct did not compile.
//
// Root cause: resolveAnnotation built a GenericInstance named after the alias over the body, and every type
//             relation and the C backend treated it as a nominal type apart from that body.
//
// Fix:        an alias whose body names a declared class, interface, struct or enum, another generic's
//             instance or one of its parameters resolves to that body, as a non-generic alias does.

import { errorCount } from "../handoff/helpers";

const PLAIN = "class Plain552 { n: int32 = 7; }\ntype Alias552<T> = Plain552;\n";
const PT = "struct Pt552 { x: int32; y: int32; }\ntype P552<T> = Pt552;\nfunction mkPt(): Pt552 { return { x: 1, y: 2 }; }\n";
const HOLDER = "class Holder552<T> { v: T; constructor(v: T) { this.v = v; } }\ntype Box552<T> = Holder552<T>;\n";

test "bug552: an alias whose body names a class is that class at every slot" {
	assert errorCount(PLAIN + "const a: Alias552<string> = new Plain552();\nconst p: Plain552 = a;\n") == 0;
	assert errorCount(PLAIN + "function f(x: Alias552<boolean>): int32 { return x.n; }\nconst n = f(new Plain552());\n") == 0;
	assert errorCount(PLAIN + "function mk(): Alias552<int32> { return new Plain552(); }\nconst c: Alias552<string> = mk();\n") == 0;
}

test "bug552: an alias whose body names a struct is that struct" {
	assert errorCount(PT + "const p: P552<string> = mkPt();\nfunction back(): P552<int32> { return p; }\nconst q: Pt552 = back();\n") == 0;
}

test "bug552: an alias whose body instantiates another generic is that instance" {
	assert errorCount(HOLDER + "const b: Box552<string> = new Holder552<string>(\"x\");\nfunction g(h: Box552<string>): string { return h.v; }\nconst s: string = g(b);\n") == 0;
	assert errorCount(HOLDER + "const w: Box552<int32> = new Holder552<string>(\"x\");\n") == 1;
}
