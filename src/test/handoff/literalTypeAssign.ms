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

test "a value of a number literal type takes the conversions its base takes" {
	const decls = "function i64(v: int64): int64 { return v; }\nfunction u8(v: uint8): uint8 { return v; }\nconst a: 1 | 2 = 1;\nconst one: 1 = 1;\nconst k: int32 = 1;\n";
	assert strictErrorCount(decls + "i64(a);\ni64(one);\ni64(k);") == 0;
	assert hasError(decls + "u8(k);", "int32 → uint8");
	assert hasError(decls + "u8(a);", "int32 → uint8");
	assert hasError(decls + "u8(one);", "int32 → uint8");
	assert strictErrorCount(decls + "u8(1);") == 0;
}
