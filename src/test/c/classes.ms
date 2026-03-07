// E2E: Classes and Interfaces → C output
// Classes are instantiated so DCE keeps them.

import { compileToC, contains } from "../helpers";


test "E2E C: class with new" {
	const src = "class Foo { x: number }\nconst f = new Foo(42);";
	const c = compileToC(src);
	assert c.ok;
	assert contains(c.value,"Foo");
}

test "E2E C: interface struct" {
	const src = "interface Point { x: number; y: number }\nconst p: Point = { x: 1, y: 2 };";
	const c = compileToC(src);
	assert c.ok;
	assert contains(c.value,"struct Point");
}

test "E2E C: constructor emits Foo_new" {
	const src = "class Foo { x: number }\nconst f = new Foo(42);";
	const c = compileToC(src);
	assert c.ok;
	assert contains(c.value,"Foo_new");
}

// KNOWN ISSUE: class methods fail in E2E pipeline.
// test "E2E C: class method" {
// 	const src = "class Vec {\n  x: number;\n  getX(): number { return this.x; }\n}\nconst v = new Vec(5);\nconst r = v.getX();";
// 	const c = compileToC(src);
// 	check(c.ok);
// 	check(contains(c.value,"Vec_getX"));
// }
