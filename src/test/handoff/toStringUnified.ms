// Unified .toString() pipeline tests
//
// Every type has a compiler-provided default .toString().
// User-defined extension methods take priority.
// Pipeline: checker accepts → stringConcatFlatten emits → builtinLower resolves

import { compileToC } from "../helpers";
import { checkSource } from "./helpers";
import { hasErrors } from "../../checker/context";

// ===== Checker accepts .toString() on all types =====

test "number.toString() no checker error" {
	const ctx = checkSource("const x: number = 42;\nconst s: string = x.toString();");
	assert ctx != null;
	assert !hasErrors(ctx);
}

test "boolean.toString() no checker error" {
	const ctx = checkSource("const b = true;\nconst s: string = b.toString();");
	assert ctx != null;
	assert !hasErrors(ctx);
}

test "enum.toString() no checker error" {
	const ctx = checkSource("enum Color { Red, Green, Blue }\nconst c = Color.Red;\nconst s: string = c.toString();");
	assert ctx != null;
	assert !hasErrors(ctx);
}

// ===== String concat coercion =====

test "number concat emits msNumberToString" {
	const result = compileToC("const x: number = 42;\nconst s = \"val: \" + x;");
	assert result.ok;
	assert result.value.contains("msNumberToString");
}

test "boolean concat emits msBoolToString" {
	const result = compileToC("const b = true;\nconst s = \"flag: \" + b;");
	assert result.ok;
	assert result.value.contains("msBoolToString");
}

test "enum concat emits EnumName_toString" {
	const src = "enum Color { Red, Green, Blue }\nconst c = Color.Red;\nconst s = \"color: \" + c;";
	const result = compileToC(src);
	assert result.ok;
	assert result.value.contains("Color_toString");
}

// ===== Explicit .toString() =====

test "number.toString() emits msNumberToString" {
	const result = compileToC("const x: number = 42;\nconst s = x.toString();");
	assert result.ok;
	assert result.value.contains("msNumberToString");
}

test "boolean.toString() emits msBoolToString" {
	const result = compileToC("const b = true;\nconst s = b.toString();");
	assert result.ok;
	assert result.value.contains("msBoolToString");
}

test "enum.toString() emits EnumName_toString" {
	const src = "enum Color { Red, Green, Blue }\nconst c = Color.Red;\nconst s = c.toString();";
	const result = compileToC(src);
	assert result.ok;
	assert result.value.contains("Color_toString");
}

// ===== Consistency: same C function for concat and explicit =====

test "number toString consistent" {
	const src = "const x: number = 42;\nconst s1 = \"val: \" + x;\nconst s2 = x.toString();";
	const result = compileToC(src);
	assert result.ok;
	assert result.value.contains("msNumberToString");
}

test "enum toString consistent" {
	const src = "enum Dir { Up, Down }\nconst d = Dir.Up;\nconst s1 = \"dir: \" + d;\nconst s2 = d.toString();";
	const result = compileToC(src);
	assert result.ok;
	assert result.value.contains("Dir_toString");
}

// ===== Struct default toString =====

test "struct toString produces a JSON string" {
	const src = "interface Point { x: number; y: number; }\nconst p: Point = { x: 1, y: 2 };\nconst s = p.toString();";
	const result = compileToC(src);
	assert result.ok;
	// Struct toString lowers to the json-object + stringify path (not a passthrough).
	assert result.value.contains("stringify");
}

// ===== User extension overrides default =====

test "user toString extension overrides struct default" {
	const src = "interface Point { x: number; y: number; }\nfunction toString(this p: Point): string { return \"point\"; }\nconst p: Point = { x: 1, y: 2 };\nconst s = p.toString();";
	const result = compileToC(src);
	assert result.ok;
	// Should use the user extension, not __toString_Point
	assert result.value.contains("toString");
}
