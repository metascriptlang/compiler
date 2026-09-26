// bug533 — a named function with another signature was wrapped into a closure slot and accepted
//
// Symptom:    `apply(named)` with `named(s: string, flag: boolean)` against `(s: string, i: number) => string`
//             compiled; C then read the number argument as a boolean (`a:T,b:T,c:T` where JS printed
//             `a:F,b:T,c:T`). The same held for a generic callee (`applyG("a", named)`, `xs.map(named)`) and
//             for a declaration `const f: (s: string, i: number) => string = named`.
//
// Root cause: synthClosureThunk wrapped any named function meeting a closure-typed slot and retyped the
//             argument to the slot, so the argument relation that follows compared the slot with itself.
//
// Fix:        the thunk is built only when the function relation (parameters and return) holds, as the
//             reference relates every parameter before granting the nimcall → closure conversion.

import { hasError } from "../handoff/helpers";
import { compileToC, compileToJS } from "../helpers";

const named = "function named(s: string, flag: boolean): string { return flag ? s + \":T\" : s + \":F\"; }\n";

test "bug533: a named function of another signature is refused for a closure parameter" {
	assert hasError(named + "function apply(f: (s: string, i: number) => string): string { return f(\"a\", 1); }\nconst r = apply(named);\n", "Argument type mismatch in 'apply' arg 0");
}

test "bug533: a generic callee refuses it too" {
	assert hasError(named + "function applyG<T>(x: T, f: (s: T, i: number) => string): string { return f(x, 1); }\nconst r = applyG(\"a\", named);\n", "Argument type mismatch in 'applyG' arg 1");
	assert hasError(named + "const xs: string[] = [\"a\", \"b\"];\nconst r = xs.map(named);\n", "Argument type mismatch in 'map' arg 0");
}

test "bug533: a closure-typed declaration refuses it" {
	assert hasError(named + "const f: (s: string, i: number) => string = named;\n", "is not assignable");
}

test "bug533: a named function of the same signature is still wrapped" {
	const src = "function named(s: string, i: number): string { return s + i.toString(); }\n"
		+ "function apply(f: (s: string, i: number) => string): string { return f(\"a\", 1); }\n"
		+ "function applyG<T>(x: T, f: (s: T, i: number) => string): string { return f(x, 1); }\n"
		+ "const f: (s: string, i: number) => string = named;\n"
		+ "const xs: string[] = [\"a\", \"b\"];\n"
		+ "console.log(apply(named) + applyG(\"b\", named) + xs.map(named).join(\",\") + f(\"c\", 3));\n";
	const c = compileToC(src);
	assert c.ok, c.error;
	const js = compileToJS(src);
	assert js.ok, js.error;
}
