// Checker: a function value fills a closure slot of another arity when every slot argument has a parameter and every parameter left out is optional

import { strictErrorCount, hasError } from "./helpers";

const DEFAULTED = "function g(a: string, b: int32 = 5): string { return a + b; }\n";
const OPTIONAL = "function o(a: string, b?: string): string { return a + (b ?? \"-\"); }\n";
const REST = "function all(...parts: string[]): string { return parts.join(\"+\"); }\n";

test "a declared function whose extra parameter has a default fills a shorter slot" {
	assert strictErrorCount(DEFAULTED + "const f: (s: string) => string = g;") == 0;
}

test "a function whose extra parameter is optional fills a shorter slot" {
	assert strictErrorCount(OPTIONAL + "const f: (s: string) => string = o;\nconst k = o;\nconst h: (s: string) => string = k;") == 0;
}

test "a default read through a function value is refused, since the value does not carry it" {
	assert hasError(DEFAULTED + "const h = g;\nconst f: (s: string) => string = h;", "a default does not travel with a function value");
}

test "a required extra parameter is refused" {
	assert hasError("function r(a: string, b: int32): string { return a + b; }\nconst f: (s: string) => string = r;", "is not assignable to type 'function'");
}

test "a rest parameter takes every argument of a fixed slot" {
	assert strictErrorCount(REST + "const f: (a: string, b: string) => string = all;\nconst one: (a: string) => string = all;") == 0;
}

test "a rest parameter refuses a slot argument of another element type" {
	assert hasError(REST + "const f: (a: string, b: int32) => string = all;", "is not assignable to type 'function'");
}

test "a fixed parameter is refused in a slot that passes a rest parameter" {
	assert hasError("function fixed(a: string): string { return a; }\nconst f: (...xs: string[]) => string = fixed;", "as a rest parameter, which can hold none");
}

test "two overloads that both need an adapter take the first declared" {
	assert strictErrorCount("function one(s: string): string { return s; }\nfunction run(f: (s: string, i: int32, j: int32) => string): string { return f(\"a\", 1, 2); }\nfunction run(f: (s: string, i: int32) => string): string { return f(\"b\", 1); }\nconst r = run(one);") == 0;
}
