// bug544 — a match over a boolean, an integer or a literal union with no `_` arm was accepted
//
// Symptom:    `return match (b) { false => 20 };` called with true returned 20 (the last arm ran as
//             the fallback), `match (n) { 1 => 100 }` with 7 returned 0 on C and undefined on JS,
//             and a statement `match (b) { true => { r = 10; } }` set r with b false.
//
// Root cause: exhaustiveness was computed only for enum and field-narrowed string unions; every
//             other selector passed with no arm for some of its values.
//
// Fix:        as Nim semCase (semstmts.nim:1391) for its ordinal selectors, a match over an
//             integer, char, boolean or a literal type/union must cover every value or carry `_`,
//             as a statement and as a value; a boolean or literal selector whose values all have
//             an arm is exhaustive. A string or float selector keeps its statement form open.

import { errorCount, hasError } from "../handoff/helpers";

const NONEX544 = "Non-exhaustive match: not every";

test "bug544: a boolean and an integer match expression without `_` are refused" {
	assert hasError("function f(b: boolean): int32 {\n\treturn match (b) {\n\t\tfalse => 20,\n\t};\n}\n", NONEX544 + " 'boolean' value");
	assert hasError("function g(n: int32): int32 {\n\treturn match (n) {\n\t\t1 => 100,\n\t\t2 => 200,\n\t};\n}\n", NONEX544 + " 'int32' value");
}

test "bug544: a boolean statement and an integer statement over constants without `_` are refused" {
	assert hasError("function f(b: boolean): int32 {\n\tlet r: int32 = -1;\n\tmatch (b) {\n\t\ttrue => { r = 10; },\n\t}\n\treturn r;\n}\n", NONEX544 + " 'boolean' value");
	assert hasError("const P544: int32 = 80;\nfunction g(port: int32): string {\n\tlet name = \"unknown\";\n\tmatch (port) {\n\t\tP544 => { name = \"http\"; },\n\t}\n\treturn name;\n}\n", NONEX544 + " 'int32' value");
}

test "bug544: a literal union selector must name every member" {
	assert hasError("type Dir544 = \"row\" | \"column\";\nfunction f(d: Dir544): int32 {\n\treturn match (d) {\n\t\t\"row\" => 1,\n\t};\n}\n", NONEX544);
	assert errorCount("type Dir544b = \"row\" | \"column\";\nfunction f(d: Dir544b): int32 {\n\treturn match (d) {\n\t\t\"row\" => 1,\n\t\t\"column\" => 2,\n\t};\n}\n") == 0;
}

test "bug544: a covered boolean, a `_` arm and a string statement stay accepted" {
	assert errorCount("function f(b: boolean): int32 {\n\treturn match (b) {\n\t\ttrue => 10,\n\t\tfalse => 20,\n\t};\n}\n") == 0;
	assert errorCount("function g(n: int32): int32 {\n\treturn match (n) {\n\t\t1 => 100,\n\t\t_ => 0,\n\t};\n}\n") == 0;
	assert errorCount("function h(cmd: string): int32 {\n\tlet hits: int32 = 0;\n\tmatch (cmd) {\n\t\t\"list\" => { hits = hits + 1; },\n\t\t\"show\" => { hits = hits + 100; },\n\t}\n\treturn hits;\n}\n") == 0;
}

test "bug544: a string or float match whose value is used must carry `_`" {
	assert hasError("function f(s: string): int32 {\n\treturn match (s) {\n\t\t\"a\" => 1,\n\t\t\"b\" => 2,\n\t};\n}\n", NONEX544 + " 'string' value");
	assert hasError("function g(x: float64): string {\n\tconst r = match (x) {\n\t\t0.5 => \"half\",\n\t\t1.0 => \"one\",\n\t};\n\treturn r;\n}\n", NONEX544 + " 'float64' value");
	assert hasError("function show(n: int32): void {}\nfunction h(s: string): void {\n\tshow(match (s) { \"a\" => 1, \"b\" => 2 });\n}\n", NONEX544 + " 'string' value");
	assert errorCount("function note(s: string): void {}\nfunction k(cmd: string): void {\n\tmatch (cmd) {\n\t\t\"list\" => note(\"l\"),\n\t\t\"show\" => note(\"s\"),\n\t};\n}\n") == 0;
}
