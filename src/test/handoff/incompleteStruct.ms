// Incomplete struct type tests
//
// When a closure captures a local struct variable by value,
// the closure env struct uses it as a field. Codegen must emit
// the full struct definition BEFORE the env struct — not just
// a forward declaration.

import { compileToC } from "../helpers";

// ===== Local struct captured in closure by value =====

test "local struct captured in closure emits full definition" {
	const src = "interface Point { x: number; y: number; }\nfunction makeAdder(p: Point): () => number {\n\treturn () => p.x + p.y;\n}";
	const result = compileToC(src);
	assert result.ok;
	// The generated C must have the full Point struct before the env struct
	assert result.value.contains("struct Point {");
}

test "local struct in closure env is not just forward-declared" {
	const src = "interface Config { width: number; height: number; name: string; }\nfunction process(c: Config): () => string {\n\treturn () => c.name;\n}";
	const result = compileToC(src);
	assert result.ok;
	assert result.value.contains("struct Config {");
}

test "non-exported struct used by closure compiles" {
	const src = "interface ScopeEntry { name: string; depth: number; }\nfunction scan(entries: ScopeEntry[]): () => number {\n\treturn () => entries.length;\n}";
	const result = compileToC(src);
	assert result.ok;
}

// ===== Array of local struct (needs complete type for MS_ARRAY) =====

test "array of local struct in closure compiles" {
	const src = "interface Item { label: string; value: number; }\nfunction collect(items: Item[]): () => number {\n\treturn () => items.length;\n}";
	const result = compileToC(src);
	assert result.ok;
}

// ===== Struct with nested struct field captured in closure =====

test "nested struct captured in closure compiles" {
	const src = "interface Inner { val: number; }\ninterface Outer { inner: Inner; name: string; }\nfunction wrap(o: Outer): () => number {\n\treturn () => o.inner.val;\n}";
	const result = compileToC(src);
	assert result.ok;
	assert result.value.contains("struct Inner {");
	assert result.value.contains("struct Outer {");
}
