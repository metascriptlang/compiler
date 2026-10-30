// Checker: a defer body keeps the narrowing of its block only for a binding nothing reassigns after the defer

import { strictErrorCount, hasError } from "./helpers";

const HEAD = "function close(n: int32): void {}\n"
	+ "function f(s: int32 | null): void {\n";

test "a const narrowed before a defer block keeps it in the body" {
	assert strictErrorCount(HEAD + "\tconst x = s;\n\tif (x != null) { defer { close(x); } }\n}") == 0;
}

test "a const narrowed by an early return keeps it in an expression defer" {
	assert strictErrorCount(HEAD + "\tconst x = s;\n\tif (x == null) return;\n\tdefer close(x);\n}") == 0;
}

test "a let assigned only before the defer keeps the narrowing" {
	assert strictErrorCount(HEAD + "\tlet x = s;\n\tx = 3;\n\tif (x != null) { defer { close(x); } }\n}") == 0;
}

test "a let reassigned after the defer loses the narrowing in the body" {
	assert hasError(HEAD + "\tlet x = s;\n\tif (x != null) { defer { close(x); } x = null; }\n}", "got int32 | null, expected int32");
}

test "a let reassigned after an expression defer loses the narrowing" {
	assert hasError(HEAD + "\tlet x = s;\n\tif (x == null) return;\n\tdefer close(x);\n\tx = null;\n}", "got int32 | null, expected int32");
}

test "a defer inside a closure keeps a narrowing of the outer const" {
	assert strictErrorCount(HEAD + "\tconst x = s;\n\tif (x != null) { const g = (): void => { defer { close(x); } }; g(); }\n}") == 0;
}
