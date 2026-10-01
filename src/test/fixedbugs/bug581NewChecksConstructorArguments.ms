// bug581 — `new` of a generic class into a typed slot never checked its arguments
//
// Symptom:    `const a: Box<string> = new Box(7)` compiled (clang error on C, JS printed 7);
//             `new Box(300)` into `Box<uint8>` printed 44 on C and 300 on JS; `new Box(true)`
//             into `Box<int32>` and `show(new Box(7))` for a `Box<string>` parameter passed too.
// Root cause: when the destination's name matched the class, `checkNewExpr` took the
//             destination and checked the arguments with no expected type; on the full path
//             the constructor's parameters were instantiated only from explicit type arguments.
// Fix:        a class with a constructor goes through the full path, and the constructor's
//             parameters are instantiated from the resolved instance (explicit or from the
//             destination), so every argument fits its parameter as in an ordinary call.

import { compileToC, compileToJS } from "../helpers";

const header = `
class Box<T> { v: T; constructor(v: T) { this.v = v; } }
class Pair<A, B> { a: A; b: B; constructor(a: A, b: B) { this.a = a; this.b = b; } }
function show(b: Box<string>): string { return b.v; }
`;

function errorOf(body: string): string {
	const c = compileToC(header + body);
	const js = compileToJS(header + body);
	if (c.ok || js.ok) return "";
	return c.error;
}

function compiles(body: string): boolean {
	return compileToC(header + body).ok && compileToJS(header + body).ok;
}

test "bug581: a literal argument fits the parameter the destination binds" {
	assert errorOf("const a: Box<string> = new Box(7);\n").contains("not assignable");
	assert errorOf("const a: Box<uint8> = new Box(300);\n").contains("cannot convert 300 to uint8");
	assert errorOf("const a: Box<int32> = new Box(true);\n").contains("not assignable");
}

test "bug581: a typed argument fits the parameter the destination binds" {
	assert errorOf("const n: int32 = 7;\nconst a: Box<string> = new Box(n);\n").contains("not assignable");
}

test "bug581: a parameter, a return and a nested new bind the destination too" {
	assert errorOf("console.log(show(new Box(7)));\n").contains("not assignable");
	assert errorOf("function mk(): Box<string> { return new Box(7); }\n").contains("not assignable");
	assert errorOf("const b: Box<Box<string>> = new Box(new Box(7));\n").contains("not assignable");
	assert errorOf("const p: Pair<string, string> = new Pair(\"x\", 1);\n").contains("not assignable");
}

test "bug581: arguments that fit still compile" {
	assert compiles("const a: Box<uint8> = new Box(7);\nconst p: Pair<string, int64> = new Pair(\"x\", 1);\nconst b: Box<Box<string>> = new Box(new Box(\"in\"));\nconsole.log(a.v, p.b, show(new Box(\"s\")), b.v.v);\n");
	assert compiles("const m: Map<string, int32> = new Map();\nm.set(\"a\", 1);\nconsole.log(m.get(\"a\"));\n");
}
