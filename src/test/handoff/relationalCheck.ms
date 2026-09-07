// Route 15b: Checker — binary operators need a declared operator

import { strictErrorCount, hasError } from "./helpers";

const STRUCT_LT = "struct S { m: int32; }\nfunction `<`(this a: S, b: S): boolean { return a.m < b.m; }\nconst x: S = { m: 1 };\nconst y: S = { m: 2 };\n";
const STRUCT_BARE = "struct S { m: int32; }\nconst x: S = { m: 1 };\nconst y: S = { m: 2 };\n";

// ===== Rejected: no candidate operator =====

test "struct '<=' without a declared operator is rejected" {
	assert hasError(STRUCT_LT + "const c = x <= y;", "operator '<=' cannot be applied to types 'S' and 'S'");
}

test "struct '>=' reports against the base operator it derives from" {
	assert hasError(STRUCT_LT + "const c = x >= y;", "operator '<=' cannot be applied to types");
}

test "struct '<' without any declared operator is rejected" {
	assert hasError(STRUCT_BARE + "const c = x < y;", "operator '<' cannot be applied to types 'S' and 'S'");
}

test "ordering a closure is rejected" {
	const src = "const f = (n: int32): int32 => n + 1;\nconst g = (n: int32): int32 => n + 2;\nconst c = f < g;";
	assert hasError(src, "operator '<' cannot be applied to types");
}

test "ordering a value array is rejected" {
	const src = "struct P { m: int32; }\nconst a: P[2] = [{ m: 1 }, { m: 2 }];\nconst b: P[2] = [{ m: 3 }, { m: 4 }];\nconst c = a < b;";
	assert hasError(src, "operator '<' cannot be applied to types");
}

test "reference array ordering compares references" {
	assert strictErrorCount("const a: int32[] = [1];\nconst b: int32[] = [2];\nconst c = a < b;") == 0;
}

// ===== Accepted: a candidate exists =====

test "struct '<' with a declared operator is valid" {
	assert strictErrorCount(STRUCT_LT + "const c = x < y;") == 0;
}

test "struct '>' derives from a declared '<'" {
	assert strictErrorCount(STRUCT_LT + "const c = x > y;") == 0;
}

test "struct '<=' with both operators declared is valid" {
	const src = "struct S { m: int32; }\nfunction `<`(this a: S, b: S): boolean { return a.m < b.m; }\nfunction `<=`(this a: S, b: S): boolean { return a.m <= b.m; }\nconst x: S = { m: 1 };\nconst y: S = { m: 2 };\nconst c = x <= y;";
	assert strictErrorCount(src) == 0;
}

test "struct equality stays available without a declared operator" {
	assert strictErrorCount(STRUCT_BARE + "const c = x == y;") == 0;
}

// ===== No false positives on the builtin-ordered kinds =====

test "numeric ordering is unaffected" {
	assert strictErrorCount("const a: int32 = 1;\nconst b: int32 = 2;\nconst c = a <= b;") == 0;
}

test "string ordering is unaffected" {
	assert strictErrorCount("const a = \"x\";\nconst b = \"y\";\nconst c = a <= b;") == 0;
}

test "enum ordering is unaffected" {
	assert strictErrorCount("enum E { A, B }\nconst a = E.A;\nconst b = E.B;\nconst c = a < b;") == 0;
}

test "reference ordering is unaffected" {
	const src = "interface R { m: int32; }\nconst a: R = { m: 1 };\nconst b: R = { m: 2 };\nconst c = a < b;";
	assert strictErrorCount(src) == 0;
}

// ===== Arithmetic and equality operands =====

test "struct '+' with an int is rejected" {
	assert hasError(STRUCT_BARE + "const c = x + 1;", "operator '+' cannot be applied to types 'S' and 'int32'");
}

test "struct '*' is rejected instead of silently typing float64" {
	assert hasError(STRUCT_BARE + "const c = x * y;", "operator '*' cannot be applied to types");
}

test "string '==' int is rejected" {
	assert hasError("const a = \"s\";\nconst b: int32 = 3;\nconst c = a == b;", "operator '==' cannot be applied to types");
}

test "string '*' int is rejected" {
	assert hasError("const a = \"s\";\nconst c = a * 2;", "operator '*' cannot be applied to types");
}

test "boolean '==' int is rejected" {
	assert hasError("const a = true;\nconst b: int32 = 1;\nconst c = a == b;", "operator '==' cannot be applied to types");
}

test "instantiated generic body reports the bad operand at check time" {
	const src = "struct S { m: int32; }\nfunction inc<T>(a: T): T { return a + 1; }\nconst s: S = { m: 1 };\nconst r = inc(s);";
	assert hasError(src, "operator '+' cannot be applied to types");
}

test "expanded template body reports the bad operand at check time" {
	const src = "struct S { m: int32; }\ntemplate tinc<T>(a: T): T { return a + 1; }\nconst s: S = { m: 1 };\nconst r = tinc(s);";
	assert hasError(src, "operator '+' cannot be applied to types");
}

test "struct '+' with a declared operator is valid" {
	const src = "struct S { m: int32; }\nfunction `+`(this a: S, b: S): S { return { m: a.m + b.m }; }\nconst x: S = { m: 1 };\nconst y: S = { m: 2 };\nconst c = x + y;";
	assert strictErrorCount(src) == 0;
}

test "numeric arithmetic is unaffected" {
	assert strictErrorCount("const a: int32 = 1;\nconst b: float64 = 2.5;\nconst c = a * b;") == 0;
}

test "string concatenation is unaffected" {
	assert strictErrorCount("const a = \"x\";\nconst b: int32 = 1;\nconst c = a + b;") == 0;
}

test "enum arithmetic is unaffected" {
	assert strictErrorCount("enum E { A, B }\nconst a = E.A;\nconst c = a + 1;") == 0;
}

test "null comparison is unaffected" {
	assert strictErrorCount("interface R { m: int32; }\nconst a: R | null = null;\nconst c = a == null;") == 0;
}
