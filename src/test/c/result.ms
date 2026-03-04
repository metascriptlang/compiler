// E2E: Result<T, E> → C output
// Tests Result type, try operator, Result.ok/Result.err constructors.

import { compileToC, assertContains, assertNoError } from "../helpers";
import { check } from "std/testing";

test "E2E C: Result.ok constructor" {
	const src = "function f(): Result<number, string> { return Result.ok(42); }\nconst r = f();";
	const c = compileToC(src);
	check(assertNoError(c));
}

test "E2E C: Result.err constructor" {
	const src = "function f(): Result<number, string> { return Result.err(\"bad\"); }\nconst r = f();";
	const c = compileToC(src);
	check(assertNoError(c));
}

test "E2E C: try operator unwrap" {
	const src = "function inner(): Result<number, string> { return Result.ok(10); }\nfunction outer(): Result<number, string> { const x = try inner(); return Result.ok(x + 1); }\nconst r = outer();";
	const c = compileToC(src);
	check(assertNoError(c));
}

test "E2E C: try with catch fallback" {
	const src = "function maybe(): Result<number, string> { return Result.err(\"no\"); }\nfunction f(): number { const x = try maybe() catch 0; return x; }\nconst r = f();";
	const c = compileToC(src);
	check(assertNoError(c));
}

test "E2E C: Result field access .ok .value .error" {
	const src = "function f(): Result<number, string> { return Result.ok(42); }\nconst r = f();\nconst b: boolean = r.ok;\nconst v: number = r.value;";
	const c = compileToC(src);
	check(assertNoError(c));
}
