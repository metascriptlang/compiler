// Null-initialized variable type inference tests
//
// Pattern: `let x = null; x = someTypedValue;`
// The checker assigns Null type to the variable since there's no annotation.
// In C, Null → void* → accessing .field on void* is invalid.
// Fix: source must use `null as unknown as T` or explicit type annotation.

import { compileToC } from "../helpers";

test "null-init variable with later assignment needs type annotation" {
	// Nullable annotation compiles (strict-null: bare Foo rejects null, Foo | null accepts it).
	const src = "class Foo { kind: number; }\nfunction test(): number {\n\tlet found: Foo | null = null;\n\tfound = new Foo(42);\n\treturn found.kind;\n}";
	const result = compileToC(src);
	assert result.ok;
	// Should NOT have void* for found
	assert !result.value.contains("void* found");
}

test "null as unknown as Type pattern compiles" {
	const src = "class Foo { kind: number; }\nfunction test(): number {\n\tlet found = null as unknown as Foo;\n\tfound = new Foo(42);\n\treturn found.kind;\n}";
	const result = compileToC(src);
	assert result.ok;
	assert !result.value.contains("void* found");
}
