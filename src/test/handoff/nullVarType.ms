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

test "null asserted to a non-nullable type narrows to that type" {
	const decls = "class Foo { kind: number = 0; }\nclass Holder { f: Foo | null = null; }\n";
	const field = "function reset(h: Holder): Foo {\n\th.f = null as unknown as Foo;\n\treturn h.f;\n}";
	const local = "function fresh(): Foo {\n\tlet x: Foo | null = new Foo();\n\tx = null as unknown as Foo;\n\treturn x;\n}";
	const init = "function declared(): Foo {\n\tlet y: Foo | null = null as unknown as Foo;\n\treturn y;\n}";
	for (const body of [field, local, init]) {
		const result = compileToC(decls + body);
		assert result.ok, body + "\n" + (result.ok ? "" : result.error);
	}
}

test "null asserted to a nullable type narrows to that type, not to null" {
	const decls = "class Foo { kind: number = 0; }\nfunction each(f: () => void): void { f(); }\n";
	const init = "function declared(): number {\n\tlet x = null as Foo | null;\n\teach(() => { x = new Foo(); });\n\tif (x !== null) return x.kind;\n\treturn 0;\n}";
	const later = "function assigned(): number {\n\tlet x: Foo | null = new Foo();\n\tx = null as Foo | null;\n\teach(() => { x = new Foo(); });\n\tif (x !== null) return x.kind;\n\treturn 0;\n}";
	for (const body of [init, later]) {
		const result = compileToC(decls + body);
		assert result.ok, body + "\n" + (result.ok ? "" : result.error);
	}
}

test "a bare null assigned to a nullable local narrows to null" {
	const src = "class Foo { kind: number = 0; }\nfunction plain(): Foo {\n\tlet x: Foo | null = new Foo();\n\tx = null;\n\treturn x;\n}";
	const result = compileToC(src);
	assert !result.ok;
	assert result.error.contains("Type 'null' is not assignable to type 'Foo'"), result.error;
}
