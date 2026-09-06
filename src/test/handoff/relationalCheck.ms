// Route 15b: Checker — ordering operators need a declared operator

import { strictErrorCount, hasError } from "./helpers";

const STRUCT_LT = "struct S { m: int32; }\nfunction `<`(this a: S, b: S): boolean { return a.m < b.m; }\nconst x: S = { m: 1 };\nconst y: S = { m: 2 };\n";
const STRUCT_BARE = "struct S { m: int32; }\nconst x: S = { m: 1 };\nconst y: S = { m: 2 };\n";

// ===== Rejected: no candidate operator =====

test "struct '<=' without a declared operator is rejected" {
	assert hasError(STRUCT_LT + "const c = x <= y;", "operator '<=' is not defined for 'S' and 'S'");
}

test "struct '>=' reports against the base operator it derives from" {
	assert hasError(STRUCT_LT + "const c = x >= y;", "operator '<=' is not defined");
}

test "struct '<' without any declared operator is rejected" {
	assert hasError(STRUCT_BARE + "const c = x < y;", "operator '<' is not defined for 'S' and 'S'");
}

test "ordering a closure is rejected" {
	const src = "const f = (n: int32): int32 => n + 1;\nconst g = (n: int32): int32 => n + 2;\nconst c = f < g;";
	assert hasError(src, "operator '<' is not defined");
}

test "ordering a value array is rejected" {
	const src = "struct P { m: int32; }\nconst a: P[2] = [{ m: 1 }, { m: 2 }];\nconst b: P[2] = [{ m: 3 }, { m: 4 }];\nconst c = a < b;";
	assert hasError(src, "operator '<' is not defined");
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
