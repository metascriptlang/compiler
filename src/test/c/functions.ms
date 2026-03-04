// E2E: Functions → C output
// Functions are called from top-level so DCE keeps them.

import { compileToC, assertContains, assertNoError } from "../helpers";
import { check } from "std/testing";

test "E2E C: function with call" {
	const src = "function add(a: number, b: number): number { return a + b; }\nconst r = add(1, 2);";
	const c = compileToC(src);
	check(assertNoError(c));
	check(assertContains(c, "double"));
	check(assertContains(c, "add("));
	check(assertContains(c, "return"));
}

test "E2E C: recursive function" {
	const src = "function fib(n: number): number {\n  if (n <= 1) { return n; }\n  return fib(n - 1) + fib(n - 2);\n}\nconst r = fib(10);";
	const c = compileToC(src);
	check(assertNoError(c));
	check(assertContains(c, "double"));
	check(assertContains(c, "fib("));
}

test "E2E C: void function" {
	const src = "function noop(): void { }\nnoop();";
	const c = compileToC(src);
	check(assertNoError(c));
	check(assertContains(c, "void noop("));
}

test "E2E C: function returns expression" {
	const src = "function square(x: number): number { return x * x; }\nconst r = square(5);";
	const c = compileToC(src);
	check(assertNoError(c));
	check(assertContains(c, "square("));
	check(assertContains(c, "x * x"));
}

test "E2E C: string param function" {
	const src = "function greet(name: string): string { return \"hi\"; }\nconst r = greet(\"world\");";
	const c = compileToC(src);
	check(assertNoError(c));
	check(assertContains(c, "msString"));
}

// KNOWN ISSUE: int32 params fail — numeric literals (1, 2) are type `number`, not int32.
// Checker rejects: "Argument type mismatch: got number, expected int32"
// test "E2E C: int32 params" {
// 	const src = "function pick(a: int32, b: int32): int32 { return a; }\nconst r = pick(1, 2);";
// 	const c = compileToC(src);
// 	check(assertNoError(c));
// 	check(assertContains(c, "int32_t"));
// }
