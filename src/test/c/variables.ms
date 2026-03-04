// E2E: Variables, Types, Enums → C output
// All declarations are used (top-level const/let) so DCE doesn't strip them.

import { compileToC, assertContains, assertNoError } from "../helpers";
import { check } from "std/testing";

test "E2E C: const number" {
	const c = compileToC("const x: number = 42;");
	check(assertNoError(c));
	check(assertContains(c, "double"));
	check(assertContains(c, "42"));
}

test "E2E C: const int32" {
	const c = compileToC("const n: int32 = 10;");
	check(assertNoError(c));
	check(assertContains(c, "int32_t"));
	check(assertContains(c, "10"));
}

test "E2E C: const boolean" {
	const c = compileToC("const f: boolean = true;");
	check(assertNoError(c));
	check(assertContains(c, "MS_BOOL"));
}

test "E2E C: enum member access" {
	const c = compileToC("enum Color { Red, Green, Blue }\nconst x: Color = Color.Green;");
	check(assertNoError(c));
	check(assertContains(c, "typedef int32_t Color"));
	check(assertContains(c, "Color_Green"));
}

test "E2E C: let variable" {
	const c = compileToC("let x: number = 0;\nx = 5;");
	check(assertNoError(c));
	check(assertContains(c, "double"));
}

test "E2E C: type alias" {
	const c = compileToC("type ID = number;\nconst id: ID = 42;");
	check(assertNoError(c));
	check(assertContains(c, "double"));
	check(assertContains(c, "42"));
}

test "E2E C: const false literal" {
	const c = compileToC("const b: boolean = false;");
	check(assertNoError(c));
	check(assertContains(c, "MS_FALSE"));
}
