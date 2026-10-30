// Checker: a closure's write to a namesake of a captured variable is a write to another symbol, so it does not cancel the outer narrowing

import { strictErrorCount, hasError } from "./helpers";

const NARROWED = "function f(s: string | null): int32 {\n"
	+ "\tlet x = s;\n"
	+ "\tif (x == null) return 0;\n"
	+ "\tconst g = (): int32 => x.length;\n";

test "a later closure declaring its own x keeps the outer narrowing" {
	assert strictErrorCount(NARROWED + "\tconst h = (): void => { let x = 1; x = 2; };\n\treturn g();\n}") == 0;
}

test "a later closure declaring x in an inner block keeps the outer narrowing" {
	assert strictErrorCount(NARROWED + "\tconst h = (): void => { if (true) { let x = 1; x = 2; } };\n\treturn g();\n}") == 0;
}

test "a later closure destructuring into x keeps the outer narrowing" {
	assert strictErrorCount(NARROWED + "\tconst h = (): void => { let [x] = [1]; x = 2; };\n\treturn g();\n}") == 0;
}

test "a nested function parameter named x keeps the outer narrowing" {
	assert strictErrorCount(NARROWED + "\tfunction h(x: string | null): void { x = null; }\n\treturn g();\n}") == 0;
}

test "an arrow parameter named x keeps the outer narrowing" {
	assert strictErrorCount(NARROWED + "\tconst h = (x: int32): void => { x = 2; };\n\treturn g();\n}") == 0;
}

test "a later closure writing the outer x cancels the narrowing" {
	assert hasError(NARROWED + "\tconst h = (): void => { x = null; };\n\treturn g();\n}", "is possibly 'null'");
}

test "a write to the outer x beside a shadowing declaration still cancels the narrowing" {
	assert hasError(NARROWED + "\tconst h = (): void => { x = null; if (true) { let x = 1; x = 2; } };\n\treturn g();\n}", "is possibly 'null'");
}

test "a write to the outer x after a block's shadowing declaration closed still cancels it" {
	assert hasError(NARROWED + "\tconst h = (): void => { { let x = 1; x = 2; } x = null; };\n\treturn g();\n}", "is possibly 'null'");
}
