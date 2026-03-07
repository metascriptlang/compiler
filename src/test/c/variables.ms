// E2E: Variables, Types, Enums → C output
// All declarations are used (top-level const/let) so DCE doesn't strip them.

import { compileToC, assertContains, assertNoError } from "../helpers";


test "E2E C: const number" {
	const c = compileToC("const x: number = 42;");
	expect(assertNoError(c));
	expect(assertContains(c, "double"));
	expect(assertContains(c, "42"));
}

test "E2E C: const int32" {
	const c = compileToC("const n: int32 = 10;");
	expect(assertNoError(c));
	expect(assertContains(c, "int32_t"));
	expect(assertContains(c, "10"));
}

test "E2E C: const boolean" {
	const c = compileToC("const f: boolean = true;");
	expect(assertNoError(c));
	expect(assertContains(c, "MS_BOOL"));
}

test "E2E C: enum member access" {
	const c = compileToC("enum Color { Red, Green, Blue }\nconst x: Color = Color.Green;");
	expect(assertNoError(c));
	expect(assertContains(c, "typedef int32_t Color"));
	expect(assertContains(c, "Color_Green"));
}

test "E2E C: let variable" {
	const c = compileToC("let x: number = 0;\nx = 5;");
	expect(assertNoError(c));
	expect(assertContains(c, "double"));
}

test "E2E C: type alias" {
	const c = compileToC("type ID = number;\nconst id: ID = 42;");
	expect(assertNoError(c));
	expect(assertContains(c, "double"));
	expect(assertContains(c, "42"));
}

test "E2E C: const false literal" {
	const c = compileToC("const b: boolean = false;");
	expect(assertNoError(c));
	expect(assertContains(c, "MS_FALSE"));
}
