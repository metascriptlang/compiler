// E2E: Classes and Interfaces → C output
// Classes are instantiated so DCE keeps them.

import { compileToC } from "../helpers";


test "E2E C: class with new" {
	const src = "class Foo { x: number }\nconst f = new Foo(42);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("Foo");
}

test "E2E C: interface struct" {
	const src = "interface Point { x: number; y: number }\nconst p: Point = { x: 1, y: 2 };";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("struct Point");
}

test "E2E C: constructor allocates with msAllocTyped" {
	const src = "class Foo { x: number }\nconst f = new Foo(42);";
	const c = compileToC(src);
	assert c.ok;
	// Constructor uses heap allocation for class types
	assert c.value.contains("msAllocTyped");
	assert c.value.contains("Foo_typeInfo");
}
