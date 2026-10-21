// Incomplete struct type tests
//
// When a closure captures a local struct variable by value,
// the closure env struct uses it as a field. Codegen must emit
// the full struct definition BEFORE the env struct — not just
// a forward declaration.

import { compileToC } from "../helpers";

// True when the struct's full definition precedes the closure env definition that holds it by value.
function definedBeforeEnv(code: string, structName: string): boolean {
	const def = code.indexOf("\nstruct " + structName + "__");
	const env = code.indexOf("\nstruct dollarEnv_");
	return def >= 0 && env >= 0 && def < env && code.contains("_Static_assert(sizeof(struct " + structName + "__");
}

// ===== Local struct captured in closure by value =====

test "local struct captured in closure emits full definition" {
	const src = "struct Point { x: number; y: number; }\nfunction makeAdder(p: Point): () => number {\n\treturn () => p.x + p.y;\n}";
	const result = compileToC(src);
	assert result.ok;
	assert definedBeforeEnv(result.value, "Point");
}

test "local struct in closure env is not just forward-declared" {
	const src = "struct Config { width: number; height: number; name: string; }\nfunction process(c: Config): () => string {\n\treturn () => c.name;\n}";
	const result = compileToC(src);
	assert result.ok;
	assert definedBeforeEnv(result.value, "Config");
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
	const src = "struct Inner { val: number; }\nstruct Outer { inner: Inner; name: string; }\nfunction wrap(o: Outer): () => number {\n\treturn () => o.inner.val;\n}";
	const result = compileToC(src);
	assert result.ok;
	assert definedBeforeEnv(result.value, "Inner");
	assert definedBeforeEnv(result.value, "Outer");
}
