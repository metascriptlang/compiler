// Route 15f: Checker — `typeof x === "..."` narrows by every runtime tag the backends emit, not only the primitives

import { strictErrorCount, hasError } from "./helpers";

const APPLY = "function apply(v: int32 | ((prev: int32) => int32), cur: int32): int32 {\n"
	+ "\tif (typeof v === \"function\") { return v(cur); }\n"
	+ "\treturn v;\n}\n";

const APPLY_T = "function applyT<T>(v: T | ((prev: T) => T), cur: T): T {\n"
	+ "\tif (typeof v === \"function\") { return v(cur); }\n"
	+ "\treturn v;\n}\n";

// ===== "function" =====

test "typeof function narrows a value-or-updater union to its callable member" {
	assert strictErrorCount(APPLY) == 0;
}

test "a named closure fits the value-or-updater union" {
	assert strictErrorCount(APPLY + "const inc = (p: int32): int32 => p + 1;\nconst n: int32 = apply(inc, 1);") == 0;
}

test "typeof function narrows inside a generic body once instantiated" {
	assert strictErrorCount(APPLY_T + "const n: int32 = applyT<int32>(5, 1);") == 0;
}

test "typeof function excludes the callable member on the negated path" {
	assert strictErrorCount("function pick(v: int32 | (() => int32)): int32 {\n"
		+ "\tif (typeof v !== \"function\") { return v + 1; }\n"
		+ "\treturn v();\n}") == 0;
}

test "typeof function keeps a union of two callables whole" {
	const TWO = "function keep(v: (() => int32) | ((p: int32) => int32)): void {\n"
		+ "\tif (typeof v === \"function\") { const same: (() => int32) | ((p: int32) => int32) = v; }\n}";
	assert strictErrorCount(TWO) == 0;
}

// ===== "object" and the primitives =====

test "typeof object narrows to the array member and its complement" {
	assert strictErrorCount("function pick(v: int32[] | int32): int32 {\n"
		+ "\tif (typeof v === \"object\") { return v.length; }\n"
		+ "\treturn v;\n}") == 0;
}

test "typeof number and string still narrow the primitive members" {
	assert strictErrorCount("function pick(v: string | int32): int32 {\n"
		+ "\tif (typeof v === \"number\") { return v + 1; }\n"
		+ "\treturn v.length;\n}") == 0;
}

test "a chain of typeof guards narrows through the residual union" {
	assert strictErrorCount("function pick(v: string | int32 | boolean): int32 {\n"
		+ "\tif (typeof v === \"boolean\") { return v ? 1 : 0; }\n"
		+ "\tif (typeof v === \"number\") { return v * 2; }\n"
		+ "\treturn v.length;\n}") == 0;
}

// ===== no narrowing =====

test "typeof compared against a non-literal does not narrow" {
	assert strictErrorCount("function apply(v: int32 | ((prev: int32) => int32), cur: int32): int32 {\n"
		+ "\tlet k = \"function\";\n"
		+ "\tif (typeof v === k) { return v(cur); }\n"
		+ "\treturn v;\n}") == 1;
}

// ===== a string that is not a tag =====

const KINDS = "const a: uint8 = 3;\nconst u: int64 | uint64 = a as uint64;\n";
const TAGS = "\"bigint\" | \"boolean\" | \"function\" | \"number\" | \"object\" | \"string\" | \"symbol\" | \"undefined\"";
const NO_OVERLAP = "This comparison appears to be unintentional because the types '";
const EXACT_KIND_HINT = "to test an exact kind, compare 'typeof x' in place with a primitive name";
const STORED = "which only 'typeof x' written in the comparison can test";

test "typeof compared with a string that is neither a tag nor a primitive name is refused with the exact-kind hint" {
	const refused = [
		"if (typeof u === \"uint\") {}",
		"if (typeof u !== \"Int64\") {}",
		"if (typeof u == \"integer\") {}",
		"if (typeof u != \"null\") {}",
	];
	for (const line of refused) {
		assert hasError(KINDS + line, NO_OVERLAP + TAGS + "' and '\""), line;
		assert hasError(KINDS + line, EXACT_KIND_HINT), line;
	}
	assert hasError(KINDS + "if (\"uint\" === typeof u) {}", NO_OVERLAP + "\"uint\"' and '" + TAGS + "' have no overlap");
}

test "a switch case or match arm that is neither a tag nor a primitive name is refused" {
	assert hasError(KINDS + "switch (typeof u) { case \"uint\": break; default: break; }", "case of type '\"uint\"' is not comparable");
	assert hasError(KINDS + "switch (typeof u) { case \"uint\": break; default: break; }", EXACT_KIND_HINT);
	assert hasError(KINDS + "const r = match (typeof u) { \"double\" => 1, _ => 2 };", EXACT_KIND_HINT);
	assert strictErrorCount(KINDS + "const r = match (typeof u) { \"double\" => 1, _ => 2 };") == 1;
}

// ===== a primitive name tests the exact kind =====

test "typeof written in the comparison accepts every primitive name with each operator and side" {
	for (const name of ["int8", "int16", "int32", "int64", "uint8", "uint16", "uint32", "uint64", "float32", "float64", "char", "cstring"]) {
		const src = KINDS + "if (typeof u === \"" + name + "\" || typeof u !== \"" + name + "\" || typeof a == \"" + name + "\" || \"" + name + "\" != typeof a) {}\n"
			+ "switch (typeof u) { case \"" + name + "\": break; default: break; }\n"
			+ "const r = match (typeof u) { \"" + name + "\" => 1, _ => 2 };";
		assert strictErrorCount(src) == 0, name;
	}
}

test "an exact-kind test narrows a union to the member and removes it on the other path" {
	assert strictErrorCount(KINDS + "if (typeof u === \"uint64\") { const x: uint64 = u; } else { const y: int64 = u; }") == 0;
	assert strictErrorCount(KINDS + "if (\"int64\" !== typeof u) { const x: uint64 = u; } else { const y: int64 = u; }") == 0;
	assert strictErrorCount("function f(v: int64 | string): string {\n"
		+ "\tif (typeof v === \"int64\") { const n: int64 = v; return \"n\"; }\n"
		+ "\treturn v;\n}") == 0;
	assert hasError("function f(v: int64 | string): int32 { if (typeof v === \"int64\") { return v.length; } return 0; }", "Property 'length' does not exist on type 'int64'");
}

test "a switch on typeof narrows each case and the default by the other cases" {
	const SW = "function f(v: int64 | uint64 | string): string {\n"
		+ "\tswitch (typeof v) {\n"
		+ "\t\tcase \"int64\": { const a: int64 = v; return \"i\"; }\n"
		+ "\t\tcase \"uint64\": { const b: uint64 = v; return \"u\"; }\n"
		+ "\t\tdefault: { const c: string = v; return c; }\n"
		+ "\t}\n}";
	assert strictErrorCount(SW) == 0;
	const TS = "function g(v: int32 | string): string {\n"
		+ "\tswitch (typeof v) {\n"
		+ "\t\tcase \"number\": { const n: int32 = v; return \"n\"; }\n"
		+ "\t\tdefault: { const s: string = v; return s; }\n"
		+ "\t}\n}";
	assert strictErrorCount(TS) == 0;
}

test "a match arm on typeof narrows to the named kind" {
	assert strictErrorCount("function f(v: int64 | uint64): uint64 { return match (typeof v) { \"uint64\" => v + (1 as uint64), _ => 0 as uint64 }; }") == 0;
	assert hasError("function f(v: int64 | string): int32 { return match (typeof v) { \"int64\" => v.length, _ => 0 }; }", "Property 'length' does not exist on type 'int64'");
}

test "a stored typeof result compared with a primitive name is refused, never false" {
	const stored = [
		"const t = typeof u;\nif (t === \"uint8\") {}",
		"const t = typeof u;\nif (\"int64\" != t) {}",
		"const t = typeof u;\nswitch (t) { case \"uint64\": break; default: break; }",
		"const t = typeof u;\nconst r = match (t) { \"int64\" => 1, _ => 2 };",
	];
	for (const line of stored) {
		assert hasError(KINDS + line, STORED), line;
		assert strictErrorCount(KINDS + line) == 1, line;
	}
}

test "typeof of an unknown value cannot test an exact kind" {
	assert hasError("class Pet { n: int32 = 1; }\nfunction f(v: unknown): boolean { return typeof v === \"int64\"; }", "carries no exact kind");
}

test "the eight tags compare and switch without an error" {
	for (const tag of ["bigint", "boolean", "function", "number", "object", "string", "symbol", "undefined"]) {
		const src = KINDS + "const t = typeof u;\nif (typeof u === \"" + tag + "\" || t !== \"" + tag + "\") {}\n"
			+ "switch (typeof u) { case \"" + tag + "\": break; default: break; }";
		assert strictErrorCount(src) == 0, tag;
	}
}

test "a string literal union compared with a string outside it is refused" {
	const PICK = "function pick(n: int32): \"a\" | \"b\" { return n > 0 ? \"a\" : \"b\"; }\nconst s = pick(1);\n";
	assert hasError(PICK + "if (s === \"c\") {}", NO_OVERLAP + "\"a\" | \"b\"' and '\"c\"' have no overlap");
	assert !hasError(PICK + "if (s === \"c\") {}", EXACT_KIND_HINT);
	assert strictErrorCount(PICK + "if (s === \"a\" || s !== \"b\") {}") == 0;
}
