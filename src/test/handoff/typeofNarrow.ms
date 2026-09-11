// Route 15f: Checker — `typeof x === "..."` narrows by every runtime tag the backends emit, not only the primitives

import { strictErrorCount } from "./helpers";

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
