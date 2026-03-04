// E2E: Expressions → C output
// Tests operator codegen: ternary, unary, logical, comparison.

import { compileToC, assertContains, assertNoError } from "../helpers";
import { check } from "std/testing";

test "E2E C: ternary expression" {
	const src = "function f(n: number): number { return (n > 0) ? 1 : -1; }\nconst r = f(5);";
	const c = compileToC(src);
	check(assertNoError(c));
	check(assertContains(c, "?"));
	check(assertContains(c, ":"));
}

test "E2E C: unary not" {
	const src = "function f(b: boolean): boolean { return !b; }\nconst r = f(true);";
	const c = compileToC(src);
	check(assertNoError(c));
	check(assertContains(c, "!"));
}

test "E2E C: unary negation" {
	const src = "function f(x: number): number { return -x; }\nconst r = f(5);";
	const c = compileToC(src);
	check(assertNoError(c));
	check(assertContains(c, "-"));
}

test "E2E C: logical AND" {
	const src = "function f(a: boolean, b: boolean): boolean { return a && b; }\nconst r = f(true, false);";
	const c = compileToC(src);
	check(assertNoError(c));
	check(assertContains(c, "&&"));
}

test "E2E C: logical OR" {
	const src = "function f(a: boolean, b: boolean): boolean { return a || b; }\nconst r = f(true, false);";
	const c = compileToC(src);
	check(assertNoError(c));
	check(assertContains(c, "||"));
}

test "E2E C: comparison operators" {
	const src = "function inRange(x: number): boolean { return x >= 0 && x <= 100; }\nconst r = inRange(50);";
	const c = compileToC(src);
	check(assertNoError(c));
	check(assertContains(c, ">="));
	check(assertContains(c, "<="));
}
