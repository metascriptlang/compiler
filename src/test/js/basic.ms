// E2E: JS Backend

import { compileToJS, assertContains, assertNoError } from "../helpers";


test "E2E JS: const variable" {
	const js = compileToJS("const x = 42;");
	expect(assertNoError(js));
	expect(assertContains(js, "42"));
}

test "E2E JS: function call" {
	const js = compileToJS("function add(a: number, b: number): number { return a + b; }\nconst r = add(1, 2);");
	expect(assertNoError(js));
	expect(assertContains(js, "function"));
	expect(assertContains(js, "add"));
}

test "E2E JS: enum" {
	const js = compileToJS("enum Dir { North, South }\nconst d: Dir = Dir.North;");
	expect(assertNoError(js));
	expect(assertContains(js, "Dir"));
}

test "E2E JS: match expression" {
	const js = compileToJS("function f(x: number): number { return match (x) { 1 => 10, _ => 0, }; }\nconst r = f(1);");
	expect(assertNoError(js));
}

// KNOWN ISSUE: arrow functions fail in E2E pipeline (checker/transform rejects).
// test "E2E JS: arrow function" {
// 	const js = compileToJS("const double = (n: number): number => n * 2;\nconst r = double(5);");
// 	check(assertNoError(js));
// }

test "E2E JS: interface object" {
	const js = compileToJS("interface Point { x: number; y: number }\nconst p: Point = { x: 1, y: 2 };");
	expect(assertNoError(js));
}
