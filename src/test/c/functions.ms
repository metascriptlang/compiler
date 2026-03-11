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
