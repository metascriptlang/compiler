// Checker — a literal type holds only its own value

import { strictErrorCount, hasError } from "./helpers";

test "a string literal type takes only its own value" {
	assert strictErrorCount("const a: \"a\" = \"a\";\nconst b: \"a\" = a;\nconst s: string = a;") == 0;
	assert hasError("const a: \"a\" = \"a\";\nconst b: \"b\" = a;", "Type '\"a\"' is not assignable to type '\"b\"'");
	assert hasError("function f(x: \"a\" | \"b\"): void {}\nconst c: \"c\" = \"c\";\nf(c);", "got \"c\", expected \"a\" | \"b\"");
}

test "a boolean literal type takes only its own value" {
	assert strictErrorCount("const t: true = true;\nconst u: true = t;\nconst b: boolean = t;") == 0;
	assert hasError("const t: true = true;\nconst f: false = t;", "Type 'true' is not assignable to type 'false'");
}
