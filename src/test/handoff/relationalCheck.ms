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

test "ordering a reference array is rejected, because backends would order it by address or by text" {
	assert hasError("const a: int32[] = [1];\nconst b: int32[] = [2];\nconst c = a < b;", "operator '<' cannot be applied to types");
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

test "ordering two references without valueOf is rejected" {
	const iface = "interface R { m: int32; }\nconst a: R = { m: 1 };\nconst b: R = { m: 2 };\nconst c = a < b;";
	assert hasError(iface, "operator '<' cannot be applied to types 'R' and 'R'");
	const cls = "class K { m: int32 = 0; }\nconst a = new K();\nconst b = new K();\nconst c = a <= b;";
	assert hasError(cls, "operator '<=' cannot be applied to types");
}

test "ordering two references reads them through valueOf" {
	const method = "class K { m: int32 = 0; valueOf(): int32 { return this.m; } }\nconst a = new K();\nconst b = new K();\nconst c = a < b;";
	assert strictErrorCount(method) == 0;
	const ext = "interface R { m: int32; }\nfunction valueOf(this r: R): int32 { return r.m; }\nconst a: R = { m: 1 };\nconst b: R = { m: 2 };\nconst c = a >= b;";
	assert strictErrorCount(ext) == 0;
}

const UNION_HEAD = "class K { m: int32 = 0; valueOf(): int32 { return this.m; } }\nclass M { m: int32 = 0; valueOf(): int32 { return this.m; } }\nclass N { s: string = \"\"; valueOf(): string { return this.s; } }\nstruct S { m: int32 }\ntype Pick = K | int32;\nfunction pick(): Pick { return 1; }\n";

test "a union whose every member orders against the other operand is accepted" {
	for (const fn of [
		"function f(a: K | int32, b: K): boolean { return a < b; }",
		"function f(a: K, b: K | int32): boolean { return a >= b; }",
		"function f(a: K | int32, b: K | int32): boolean { return a > b; }",
		"function f(a: K | M, b: K | M): boolean { return a <= b; }",
		"function f(a: N | string, b: string): boolean { return a < b; }",
		"function f(a: int32 | float64, b: int32): boolean { return a < b; }",
		"class H { u: K | int32 = 1; }\nfunction f(h: H, b: int32): boolean { return h.u < b; }",
	]) {
		assert strictErrorCount(UNION_HEAD + fn) == 0, fn;
	}
}

test "a union member that cannot order against the other operand is named" {
	assert hasError(UNION_HEAD + "function f(a: K | string, b: int32): boolean { return a < b; }", "cannot compare the member 'string' of 'K | string' with 'int32'");
	assert hasError(UNION_HEAD + "function f(a: int32, b: K | string): boolean { return a < b; }", "cannot compare the member 'string' of 'K | string' with 'int32'");
	assert hasError(UNION_HEAD + "function f(a: K | int32, b: K | string): boolean { return a < b; }", "cannot compare the member 'K' (read as 'int32') of 'K | int32' with 'string'");
	assert hasError(UNION_HEAD + "function f(a: N | string, b: int32): boolean { return a < b; }", "cannot compare the member 'N' (read as 'string') of 'N | string' with 'int32'");
	assert hasError(UNION_HEAD + "function f(a: int32 | boolean, b: int32): boolean { return a < b; }", "cannot compare the member 'boolean' of 'boolean | int32' with 'int32'");
}

test "a union member with no order is named, and a declared operator on it is not needed when valueOf reads it" {
	assert hasError(UNION_HEAD + "function f(a: S | int32, b: int32): boolean { return a < b; }", "cannot order the member 'S' of 'S | int32'");
	assert strictErrorCount(UNION_HEAD + "function valueOf(this s: S): int32 { return s.m; }\nfunction f(a: S | int32, b: int32): boolean { return a < b; }") == 0;
}

test "members that no tag or class test can tell apart are refused naming both, and one such member is accepted" {
	const reads = "struct T { m: int32 }\nfunction valueOf(this s: S): int32 { return s.m; }\nfunction valueOf(this t: T): int32 { return t.m; }\n";
	assert hasError(UNION_HEAD + reads + "function f(a: S | T, b: int32): boolean { return a < b; }", "cannot tell the members 'S' and 'T' of 'S | T' apart at run time");
	assert strictErrorCount(UNION_HEAD + reads + "function f(a: S | K, b: int32): boolean { return a < b; }") == 0;
	assert strictErrorCount(UNION_HEAD + reads + "function f(a: S | int32, b: S | int32): boolean { return a >= b; }") == 0;
}

const ENUM_HEAD = "enum E { A, B, C }\nenum F { X, Y }\n";

test "a union holding an enum and a number orders as the enum does on its own" {
	for (const fn of [
		"function f(a: E | int32, b: int32): boolean { return a < b; }",
		"function f(a: int32, b: E | int32): boolean { return a >= b; }",
		"function f(a: E | float64, b: E): boolean { return a <= b; }",
		"function f(a: E | uint8, b: F): boolean { return a > b; }",
		"function f(a: E | int32, b: E | int32): boolean { return a < b; }",
	]) {
		assert strictErrorCount(ENUM_HEAD + fn) == 0, fn;
	}
}

test "a union of two enums is refused because no run-time test tells them apart" {
	assert hasError(ENUM_HEAD + "function f(a: E | F, b: int32): boolean { return a < b; }", "cannot tell the members 'E' and 'F' of 'E | F' apart at run time");
}

test "an enum member of a union must still compare with the other operand" {
	assert hasError(ENUM_HEAD + "function f(a: E | int32, b: string): boolean { return a < b; }", "of 'E | int32' with 'string'");
	assert hasError(ENUM_HEAD + "function f(a: E | boolean, b: int32): boolean { return a < b; }", "cannot compare the member 'boolean' of 'E | boolean' with 'int32'");
}

test "a pointer orders only against a pointer" {
	for (const fn of [
		"function f(p: Ptr<uint64>, n: int64): boolean { return p < n; }",
		"function f(n: uint64, p: Ptr<uint64>): boolean { return n >= p; }",
		"function f(p: Ptr<uint64>, e: E): boolean { return p <= e; }",
		"function f(p: Ptr<uint64>): boolean { return p > 0; }",
	]) {
		assert hasError(ENUM_HEAD + fn, "cannot be applied to types"), fn;
	}
	for (const fn of [
		"function f(p: Ptr<uint64>, q: Ptr<uint64>): boolean { return p < q; }",
		"function f(p: Ptr<uint64>, q: Ptr<uint8>): boolean { return p >= q; }",
	]) {
		assert strictErrorCount(ENUM_HEAD + fn) == 0, fn;
	}
}

test "a Result member of a union operand is named" {
	assert hasError(UNION_HEAD + "function f(a: Result<int32, string> | int32, b: int32): boolean { return a < b; }", "cannot order the member 'Result<int32, string>'");
}

test "a union with null is refused like any nullable operand" {
	assert hasError(UNION_HEAD + "function f(a: K | null, b: int32): boolean { return a < b; }", "possibly null");
	assert hasError(UNION_HEAD + "function f(a: K | int32 | null, b: int32): boolean { return a < b; }", "possibly null");
	assert hasError(UNION_HEAD + "function f(a: int32, b: K | null): boolean { return a < b; }", "possibly null");
}

test "a union operand that is not a name or a field path is refused with its own case" {
	assert hasError(UNION_HEAD + "function f(b: int32): boolean { return pick() < b; }", "store it in a local first");
	assert hasError(UNION_HEAD + "class H { u: K | int32 = 1; }\nfunction mk(): H { return new H(); }\nfunction f(b: int32): boolean { return mk().u < b; }", "store it in a local first");
	assert strictErrorCount(UNION_HEAD + "function f(b: int32): boolean { const a = pick(); return a < b; }") == 0;
}

test "a union of primitives mixing string and number is refused naming the string" {
	assert hasError(UNION_HEAD + "function f(a: string | int32, b: int32): boolean { return a < b; }", "cannot compare the member 'string' of 'int32 | string' with 'int32'");
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

test "fixed array '==' fixed array of another length is rejected" {
	const src = "const a: uint8[4] = [1, 2, 3, 4];\n"
		+ "const b: uint8[3] = [1, 2, 3];\n"
		+ "const c = a == b;";
	assert hasError(src, "operator '==' cannot be applied to types");
}

test "fixed array '==' fixed array of another element type is rejected" {
	const src = "const a: uint8[4] = [1, 2, 3, 4];\n"
		+ "const b: uint16[4] = [1, 2, 3, 4];\n"
		+ "const c = a == b;";
	assert hasError(src, "operator '==' cannot be applied to types");
}

test "fixed array '==' array is rejected" {
	const src = "const a: uint8[4] = [1, 2, 3, 4];\n"
		+ "const b: uint8[] = [1, 2, 3, 4];\n"
		+ "const c = a == b;";
	assert hasError(src, "operator '==' cannot be applied to types");
}

test "fixed array '==' fixed array of one type is valid" {
	const src = "const a: uint8[4] = [1, 2, 3, 4];\n"
		+ "const b: uint8[4] = [1, 2, 3, 5];\n"
		+ "const c = a == b;";
	assert strictErrorCount(src) == 0;
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

test "comparing a signed and an unsigned integer neither of which holds the other is rejected" {
	const pre = "function count(): uint64 { return 3 as uint64; }\nconst li: int32 = -1;\nconst i32v: int32 = -5;\nconst u32: uint32 = 3000000000 as uint32;\nconst i8: int8 = -1;\nconst u8: uint8 = 200;\n";
	for (const cmp of ["count() < li", "count() > li", "count() === li", "li != count()", "i32v < u32", "u32 >= i32v", "i8 == u8"]) {
		assert hasError(pre + "const c = " + cmp + ";", "neither type holds every value of the other"), cmp;
	}
}

test "comparing a signed and an unsigned integer one of which holds the other is valid" {
	const pre = "function count(): uint64 { return 3 as uint64; }\nconst li: int32 = -1;\nconst wide: int64 = -1;\nconst u32: uint32 = 3000000000 as uint32;\nconst u8: uint8 = 200;\n";
	for (const cmp of ["u8 > li", "wide < u32", "u32 === wide", "count() > 0", "count() == (li as uint64)", "(count() as int32) < li"]) {
		assert strictErrorCount(pre + "const c = " + cmp + ";") == 0, cmp;
	}
}
