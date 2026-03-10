// Anonymous struct cast to union type tests
//
// Pattern: `node.data = { value: 42 } as unknown as NodeData;`
// In JS this is structural typing. In C, the codegen must generate
// proper union variant construction, not `(NodeData)((void*)struct)`.

import { compileToC } from "../helpers";

// ===== The as-unknown-as-union pattern =====

test "object literal as unknown as union compiles" {
	const src = "type MyData = | { value: number } | { name: string };\nfunction setVal(out d: MyData): void {\n\td = { value: 42 } as unknown as MyData;\n}";
	const result = compileToC(src);
	assert result.ok;
	// Should NOT contain (void*) cast of a struct value
	assert !result.value.contains("(void*)_lit");
}

test "object literal assigned to NodeData-like union" {
	const src = "type Data = | { value: number } | { text: string };\ninterface Box { kind: number; data: Data; }\nfunction makeNum(b: Box): void {\n\tb.data = { value: 1 } as unknown as Data;\n}";
	const result = compileToC(src);
	assert result.ok;
}

// ===== null as unknown as T (general unwrap covers null collapse) =====

test "null as unknown as struct compiles to zero-init" {
	const src = "interface Point { x: number; y: number; }\nfunction makeNull(): Point {\n\treturn null as unknown as Point;\n}";
	const result = compileToC(src);
	assert result.ok;
	// Should NOT contain (void*)
	assert !result.value.contains("(void*)");
}

// ===== struct-to-struct reinterpret via as unknown as =====

test "struct as unknown as other struct compiles" {
	const src = "interface A { x: number; y: number; }\ninterface B { a: number; b: number; }\nfunction convert(a: A): B {\n\treturn a as unknown as B;\n}";
	const result = compileToC(src);
	assert result.ok;
	// Should use pointer reinterpret, not (void*) cast
	assert !result.value.contains("(void*)");
}
