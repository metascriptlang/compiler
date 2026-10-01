// Anonymous struct cast to union type tests

import { compileToC } from "../helpers";

test "object literal into a union slot compiles" {
	const src = "type MyData = | { value: number } | { name: string };\nfunction setVal(out d: MyData): void {\n\td = { value: 42 };\n}";
	const result = compileToC(src);
	assert result.ok;
	assert !result.value.contains("(void*)_lit");
}

test "object literal assigned to NodeData-like union" {
	const src = "type Data = | { value: number } | { text: string };\ninterface Box { kind: number; data: Data; }\nfunction makeNum(b: Box): void {\n\tb.data = { value: 1 };\n}";
	const result = compileToC(src);
	assert result.ok;
}

test "a value union reached through unknown is refused" {
	const src = "type Data = | { value: number } | { text: string };\ninterface Box { kind: number; data: Data; }\nfunction makeNum(b: Box): void {\n\tb.data = { value: 1 } as unknown as Data;\n}";
	const result = compileToC(src);
	assert !result.ok;
	assert result.error.contains("unknown holds objects");
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

test "an interface reinterpreted through unknown is refused" {
	const src = "interface A { x: number; y: number; }\ninterface B { a: number; b: number; }\nfunction convert(a: A): B {\n\treturn a as unknown as B;\n}";
	const result = compileToC(src);
	assert !result.ok;
	assert result.error.contains("only a non-generic class has a runtime identity");
}
