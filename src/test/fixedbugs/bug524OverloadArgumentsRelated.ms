// bug524 — an overloaded free-function call never related its arguments to the chosen overload
//
// Symptom:    with `f(x: int32)` / `f(x: string)`, `f(n)` for a `number` 3.7 printed `i:3`; `f(null)`
//             reached a `Box` parameter and crashed on the member access; a `Readonly<int32[]>` reached
//             a mutating `int32[]` overload; a `(d: Dog) => string` callback reached an
//             `(a: Animal) => string` parameter and read a Dog field off an Animal; `ov(-1)` reached a
//             `uint32` overload as 4294967295. The same calls to a non-overloaded function are errors.
//
// Root cause: resolveOverloadCall scored the candidates with typeRelation and then only wrapped
//             conversions — relateCallArgs, which refuses what isAssignable refuses, never ran for the
//             winner. typeRelation also scored a float argument into an integer formal as FromLiteral.
//
// Fix:        the winner's arguments go through relateCallArgs, as the reference's paramTypesMatchAux
//             relates and converts in one pass; a float argument no longer matches an integer formal,
//             and an integer literal matches an integer formal of another kind only when in range.

import { hasError } from "../handoff/helpers";
import { compileToC } from "../helpers";

test "bug524: a number argument does not pick an int32 overload" {
	assert hasError("function f(x: int32): string { return \"i\"; }\nfunction f(x: string): string { return x; }\nconst n: number = 3.7;\nconst r = f(n);\n", "No matching overload for 'f'");
}

test "bug524: null is refused by the class overload it picked" {
	assert hasError("class Box524 { v: int32; constructor(v: int32) { this.v = v; } }\nfunction f(b: Box524): string { return \"b\"; }\nfunction f(s: string): string { return s; }\nconst r = f(null);\n", "Argument type mismatch in 'f' arg 0: got null, expected Box524");
}

test "bug524: a read-only view is refused by a mutable overload" {
	assert hasError("function clear(xs: int32[]): string { xs.push(9); return \"a\"; }\nfunction clear(s: string): string { return s; }\nfunction show(v: Readonly<int32[]>): string { return clear(v); }\n", "Argument type mismatch in 'clear' arg 0: got Readonly<int32[]>, expected int32[]");
}

test "bug524: a callback taking a subclass is refused for a base-class parameter" {
	const pre = "class A524 { n: string; constructor(n: string) { this.n = n; } }\nclass D524 extends A524 { t: string; constructor(n: string) { super(n); this.t = \"t\"; } }\n";
	assert hasError(pre + "function each(xs: A524[], f: (a: A524) => string): string { return \"\"; }\nfunction each(xs: string, f: (a: string) => string): string { return xs; }\nfunction onlyD(d: D524): string { return d.t; }\nconst xs: A524[] = [];\nconst r = each(xs, onlyD);\n", "Argument type mismatch in 'each' arg 1");
}

test "bug524: a negative literal does not match an unsigned overload" {
	assert hasError("function ov(x: uint32): string { return \"u\"; }\nfunction ov(x: string): string { return x; }\nconst r = ov(-1);\n", "No matching overload for 'ov'");
}

test "bug524: matching arguments still resolve and convert" {
	const r = compileToC("function f(x: int32): string { return \"i\"; }\nfunction f(x: string): string { return x; }\nconst a = f(3);\nconst b = f(\"s\");\nfunction g(x: int64): string { return \"l\"; }\nfunction g(x: string): string { return x; }\nconst i: int32 = 4;\nconst c = g(i);\n");
	assert r.ok, r.error;
}
