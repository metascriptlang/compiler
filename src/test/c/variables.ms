// E2E: Variables, Types, Enums → C output
// All declarations are used (top-level const/let) so DCE doesn't strip them.

import { compileToC } from "../helpers";


test "E2E C: const number" {
	const c = compileToC("const x: number = 42;");
	assert c.ok;
	assert c.value.contains("double");
	assert c.value.contains("42");
}

test "E2E C: const int32" {
	const c = compileToC("const n: int32 = 10;");
	assert c.ok;
	assert c.value.contains("int32_t");
	assert c.value.contains("10");
}

test "E2E C: const boolean" {
	const c = compileToC("const f: boolean = true;");
	assert c.ok;
	assert c.value.contains("MS_BOOL");
}

test "E2E C: enum member access" {
	const c = compileToC("enum Color { Red, Green, Blue }\nconst x: Color = Color.Green;");
	assert c.ok;
	assert c.value.contains("typedef int32_t Color");
	assert c.value.contains("Color_Green");
}

test "E2E C: let variable" {
	const c = compileToC("let x: number = 0;\nx = 5;");
	assert c.ok;
	assert c.value.contains("double");
}

test "E2E C: type alias" {
	const c = compileToC("type ID = number;\nconst id: ID = 42;");
	assert c.ok;
	assert c.value.contains("double");
	assert c.value.contains("42");
}

test "E2E C: const false literal" {
	const c = compileToC("const b: boolean = false;");
	assert c.ok;
	assert c.value.contains("MS_FALSE");
}
