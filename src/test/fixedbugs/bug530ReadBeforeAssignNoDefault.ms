// bug530 — a local of a type with no default value could be read before any assignment
//
// Symptom:    `let o: Foo; if (flag) { o = new Foo(); } return o.x;` passed the checker and
//             dereferenced NULL on the path that skipped the assignment; the same with
//             `let cb: () => int32;` called a NULL closure. No diagnostic with or without
//             --strict-defs.
//
// Root cause: the init tracker's use-before-assignment branch ran only under --strict-defs and only
//             warned, whatever the variable's type.
//
// Fix:        the reference's useVar requiresInit branch: a local whose type has no valid zero
//             value (a class, interface or array handle, a function, a struct holding one) that the
//             tracker cannot prove assigned on every path is an error, independent of
//             --strict-defs.

import { hasError, errorCount } from "../handoff/helpers";

const NODEFAULT530 = "has no default value";

test "bug530: reading a class local assigned on one branch only is refused" {
	assert hasError("class Foo530 { x: int32 = 7; }\n"
		+ "function f(flag: boolean): int32 {\n"
		+ "\tlet o: Foo530;\n"
		+ "\tif (flag) { o = new Foo530(); }\n"
		+ "\treturn o.x;\n}\n", NODEFAULT530);
}

test "bug530: a function local, an array local and a struct holding a function are refused" {
	assert hasError("function f(flag: boolean): int32 {\n"
		+ "\tlet cb: () => int32;\n"
		+ "\tif (flag) { cb = (): int32 => 42; }\n"
		+ "\treturn cb();\n}\n", NODEFAULT530);
	assert hasError("function f(n: int32): int32 {\n"
		+ "\tlet xs: int32[];\n"
		+ "\tfor (let i = 0; i < n; i++) { xs = [i]; }\n"
		+ "\treturn xs.length;\n}\n", NODEFAULT530);
	assert hasError("struct S530 { cb: () => int32; }\n"
		+ "function f(flag: boolean): int32 {\n"
		+ "\tlet s: S530;\n"
		+ "\tif (flag) { s = { cb: (): int32 => 1 }; }\n"
		+ "\treturn s.cb();\n}\n", NODEFAULT530);
}

test "bug530: every branch assigning, a later closure read and a number stay accepted" {
	assert errorCount("class Foo530 { x: int32 = 7; }\n"
		+ "enum E530 { A, B }\n"
		+ "function f(flag: boolean, e: E530): int32 {\n"
		+ "\tlet o: Foo530;\n"
		+ "\tif (flag) { o = new Foo530(); } else { o = new Foo530(); }\n"
		+ "\tlet p: Foo530;\n"
		+ "\tmatch (e) { E530.A => { p = new Foo530(); }, E530.B => { p = new Foo530(); } };\n"
		+ "\tlet cb: () => int32;\n"
		+ "\tcb = (): int32 => 3;\n"
		+ "\tconst g = (): int32 => cb();\n"
		+ "\tlet n: int32;\n"
		+ "\tif (flag) { n = 1; }\n"
		+ "\treturn o.x + p.x + g() + n;\n}\n") == 0;
}
