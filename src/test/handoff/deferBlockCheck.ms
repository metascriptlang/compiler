// Checker — a `defer { … }` block is checked like any other block, in a scope of its own

import { strictErrorCount, hasError } from "./helpers";

test "a name the defer block does not know is an error" {
	assert hasError("function f(): void {\n\t{\n\t\tdefer { nope(); }\n\t}\n}", "Undefined variable 'nope'");
}

test "a method call in a defer block checks its arguments" {
	const src = "function f(): void {\n\tconst s = new Set<int32>();\n\t{\n\t\tdefer { s.add(\"x\"); }\n\t}\n}";
	assert hasError(src, "Argument type mismatch in 'add'");
	assert strictErrorCount("function f(): void {\n\tconst s = new Set<int32>();\n\t{\n\t\tdefer { s.add(7); }\n\t}\n}") == 0;
}

test "a binding declared in a defer block stays in that block" {
	assert hasError("function f(): int32 {\n\t{\n\t\tdefer { const inner: int32 = 1; }\n\t}\n\treturn inner;\n}", "Undefined variable 'inner'");
	assert strictErrorCount("function f(): int32 {\n\tlet t: int32 = 0;\n\t{\n\t\tdefer { const ten: int32 = 10; t = t + ten; }\n\t}\n\treturn t;\n}") == 0;
}
