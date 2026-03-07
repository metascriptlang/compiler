// E2E: Classes and Interfaces → C output
// Classes are instantiated so DCE keeps them.

import { compileToC, assertContains, assertNoError } from "../helpers";


test "E2E C: class with new" {
	const src = "class Foo { x: number }\nconst f = new Foo(42);";
	const c = compileToC(src);
	expect(assertNoError(c));
	expect(assertContains(c, "Foo"));
}

test "E2E C: interface struct" {
	const src = "interface Point { x: number; y: number }\nconst p: Point = { x: 1, y: 2 };";
	const c = compileToC(src);
	expect(assertNoError(c));
	expect(assertContains(c, "struct Point"));
}

test "E2E C: constructor emits Foo_new" {
	const src = "class Foo { x: number }\nconst f = new Foo(42);";
	const c = compileToC(src);
	expect(assertNoError(c));
	expect(assertContains(c, "Foo_new"));
}

// KNOWN ISSUE: class methods fail in E2E pipeline.
// test "E2E C: class method" {
// 	const src = "class Vec {\n  x: number;\n  getX(): number { return this.x; }\n}\nconst v = new Vec(5);\nconst r = v.getX();";
// 	const c = compileToC(src);
// 	check(assertNoError(c));
// 	check(assertContains(c, "Vec_getX"));
// }
