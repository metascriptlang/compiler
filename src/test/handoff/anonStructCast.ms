// Anonymous struct cast to union type tests

import { compileToC, compileToJS } from "../helpers";

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

test "null as unknown as an interface compiles without a void* cast" {
	const src = "interface Point { x: number; y: number; }\nfunction makeNull(): Point {\n\treturn null as unknown as Point;\n}";
	const result = compileToC(src);
	assert result.ok;
	// Should NOT contain (void*)
	assert !result.value.contains("(void*)");
}

test "null cast to a value type that holds no null is refused" {
	const casts = ["null as string", "undefined as string", "null as int32", "null as boolean",
		"null as unknown as string", "null as unknown as int32", "undefined as unknown as float64", "null as (() => void)"];
	for (const cast of casts) {
		const result = compileToC("const a = " + cast + ";\nconsole.log(a);");
		assert !result.ok;
		assert result.error.contains("holds no null");
	}
}

test "null through unknown is refused where the slot is not a pointer and open where it is" {
	const prelude = "struct Pt { x: int32; }\nclass K { v: int32 = 1; }\n";
	const refused = ["Pt", "int32[4]", "Span<int32>", "string", "int32", "string[]", "int32[]", "K[]"];
	for (const t of refused) {
		const result = compileToC(prelude + "const a = null as unknown as " + t + ";\nconsole.log(a);");
		assert !result.ok;
		assert result.error.contains("holds no null");
	}
	const open = ["K", "(() => void)"];
	for (const t of open) {
		const result = compileToC(prelude + "const a = null as unknown as " + t + ";\nconsole.log(a == null);");
		assert result.ok;
	}
}

test "null through unknown is refused for a dynamic array on both backends" {
	const prelude = "class K { v: int32 = 1; }\n";
	for (const t of ["int32[]", "string[]", "K[]"]) {
		const src = prelude + "const a = null as unknown as " + t + ";\nconsole.log(a);";
		const c = compileToC(src);
		assert !c.ok;
		assert c.error.contains("holds no null");
		const js = compileToJS(src);
		assert !js.ok;
		assert js.error.contains("holds no null");
	}
}

test "a nullable dynamic array holds null and narrows on both backends" {
	const prelude = "class K { v: int32 = 1; }\n";
	for (const t of ["int32[]", "string[]", "K[]"]) {
		const src = prelude + "let a: " + t + " | null = null;\nconsole.log(a == null);\nif (a != null) { console.log(a.length); }";
		assert compileToC(src).ok;
		assert compileToJS(src).ok;
	}
}

test "null through unknown is refused for a std collection on both backends" {
	for (const t of ["Map<string, int32>", "HashMap<string, int32>", "Set<string>", "HashSet<string>"]) {
		const src = "const a = null as unknown as " + t + ";\nconsole.log(a);";
		const c = compileToC(src);
		assert !c.ok;
		assert c.error.contains("holds no null");
		assert c.error.contains(t + " | null");
		const js = compileToJS(src);
		assert !js.ok;
		assert js.error.contains("holds no null");
	}
}

test "a nullable std collection holds null and narrows on both backends" {
	for (const t of ["Map<string, int32>", "HashMap<string, int32>", "Set<string>", "HashSet<string>"]) {
		const src = "let a: " + t + " | null = null;\nconsole.log(a == null);\nif (a != null) { console.log(a.size); }";
		assert compileToC(src).ok;
		assert compileToJS(src).ok;
	}
}

test "a std collection is not held as unknown" {
	for (const t of ["Map<string, int32>", "HashMap<string, int32>", "Set<string>", "HashSet<string>"]) {
		const result = compileToC("const a = new " + t + "();\nconst u = a as unknown;\nconsole.log(u == null);");
		assert !result.ok;
		assert result.error.contains("as unknown");
	}
}

test "null through unknown stays open for a class, a Ref and a function on both backends" {
	const prelude = "class K { v: int32 = 1; }\n";
	for (const t of ["K", "Ref<int32>", "(() => void)"]) {
		const src = prelude + "const a = null as unknown as " + t + ";\nconsole.log(a == null);";
		assert compileToC(src).ok;
		assert compileToJS(src).ok;
	}
}

test "a direct null cast is refused for every type that holds no null" {
	const prelude = "struct Pt { x: int32; }\nclass K { v: int32 = 1; }\n";
	const targets = ["Pt", "K", "string[]", "int32[4]", "Span<int32>", "string", "(() => void)", "Map<string, int32>", "HashMap<string, int32>", "Set<string>", "HashSet<string>"];
	for (const t of targets) {
		for (const literal of ["null", "undefined"]) {
			const result = compileToC(prelude + "const a = " + literal + " as " + t + ";\nconsole.log(a);");
			assert !result.ok;
			assert result.error.contains("holds no null");
		}
	}
}

test "null into a type that holds no null is refused at every entry" {
	const prelude = "struct Pt { x: int32; }\nclass K { v: int32 = 1; }\n";
	const entries = [
		"const v: T = null;",
		"const v: T = undefined;",
		"function g(v: T): void { let w = v; w = null; }",
		"function g(): T { return null; }",
		"function h(v: T): void {}\nh(null);",
		"class Holder { f: T = null; }",
		"const e: T[] = [null];",
		"const o: { f: T } = { f: null };",
	];
	const types = ["Pt", "number[]", "string[]", "int32[4]", "Span<int32>", "K"];
	for (const t of types) {
		for (const entry of entries) {
			const borrowOnly = t == "Span<int32>" && (entry.contains("return") || entry.contains("class Holder"));
			if (borrowOnly) continue;
			const result = compileToC(prelude + entry.replaceAll("T", t));
			assert !result.ok;
			assert result.error.contains("not assignable") || result.error.contains("mismatch");
		}
	}
}

test "the ways to hold null still compile" {
	const sources = [
		"struct Pt { x: int32; }\nconst x: Pt | null = null;\nconsole.log(x == null);",
		"const y: string[] | null = null;\nconsole.log(y == null);",
		"const z: int32[4] | null = null;\nconsole.log(z == null);",
		"class K { v: int32 = 1; }\nconst k = null as unknown as K;\nconsole.log(k == null);",
		"const f = null as unknown as (() => void);\nconsole.log(f == null);",
		"function f(): Result<void, string> { return Result.ok(null); }\nconsole.log(f().ok);",
	];
	for (const src of sources) {
		const result = compileToC(src);
		assert result.ok;
	}
}

test "null cast to a type that holds null compiles" {
	const casts = ["null as string | null", "null as int32 | null", "null as unknown", "null as unknown as (() => void)", "null as Ptr<int32>"];
	for (const cast of casts) {
		const result = compileToC("const a = " + cast + ";\nconsole.log(a == null);");
		assert result.ok;
	}
}

// ===== struct-to-struct reinterpret via as unknown as =====

test "an interface reinterpreted through unknown is refused" {
	const src = "interface A { x: number; y: number; }\ninterface B { a: number; b: number; }\nfunction convert(a: A): B {\n\treturn a as unknown as B;\n}";
	const result = compileToC(src);
	assert !result.ok;
	assert result.error.contains("only a class has a runtime identity");
}
