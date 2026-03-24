// E2E: Functions → C output
// Functions are called from top-level so DCE keeps them.

import { compileToC } from "../helpers";


test "E2E C: function with call" {
	const src = "function add(a: number, b: number): number { return a + b; }\nconst r = add(1, 2);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("double");
	assert c.value.contains("add__");
	assert c.value.contains("return");
}

test "E2E C: recursive function" {
	const src = "function fib(n: number): number {\n  if (n <= 1) { return n; }\n  return fib(n - 1) + fib(n - 2);\n}\nconst r = fib(10);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("double");
	assert c.value.contains("fib__");
}

test "E2E C: void function" {
	const src = "function noop(): void { }\nnoop();";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("void noop__");
}

test "E2E C: function returns expression" {
	const src = "function square(x: number): number { return x * x; }\nconst r = square(5);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("square__");
	assert c.value.contains("x * x");
}

test "E2E C: string param function" {
	const src = "function greet(name: string): string { return \"hi\"; }\nconst r = greet(\"world\");";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("msString");
}

test "E2E C: array param passed by pointer" {
	const src = "function count(arr: string[]): number { return arr.length; }\nconst a: string[] = [];\ncount(a);";
	const c = compileToC(src);
	assert c.ok;
	// Array params must be pointers (msStringArray*) so callee mutations are visible to caller
	assert c.value.contains("msStringArray*");
}

test "E2E C: array return is by value not pointer" {
	const src = "function getItems(): string[] { return []; }\nconst a = getItems();";
	const c = compileToC(src);
	assert c.ok;
	// Return types must NOT be promoted to pointers — arrays returned by value
	assert c.value.contains("msStringArray getItems__");
}
