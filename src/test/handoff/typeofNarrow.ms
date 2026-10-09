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
const NAMED_VARIANTS = "use a union with named variants";

test "typeof compared with a string that is no tag is refused with the named-variant hint" {
	const refused = [
		"if (typeof u === \"uint64\") {}",
		"if (typeof u !== \"uint64\") {}",
		"if (typeof u == \"int32\") {}",
		"if (typeof u != \"int32\") {}",
		"const t = typeof u;\nif (t === \"uint8\") {}",
	];
	for (const line of refused) {
		assert hasError(KINDS + line, NO_OVERLAP + TAGS + "' and '\""), line;
		assert hasError(KINDS + line, NAMED_VARIANTS), line;
	}
	assert hasError(KINDS + "if (\"uint8\" === typeof u) {}", NO_OVERLAP + "\"uint8\"' and '" + TAGS + "' have no overlap");
}

test "a switch case or match arm that is no tag is refused" {
	assert hasError(KINDS + "switch (typeof u) { case \"uint8\": break; default: break; }", "case of type '\"uint8\"' is not comparable");
	assert hasError(KINDS + "switch (typeof u) { case \"uint8\": break; default: break; }", NAMED_VARIANTS);
	assert hasError(KINDS + "const r = match (typeof u) { \"float64\" => 1, _ => 2 };", NAMED_VARIANTS);
	assert strictErrorCount(KINDS + "const r = match (typeof u) { \"float64\" => 1, _ => 2 };") == 1;
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
	assert !hasError(PICK + "if (s === \"c\") {}", NAMED_VARIANTS);
	assert strictErrorCount(PICK + "if (s === \"a\" || s !== \"b\") {}") == 0;
}
