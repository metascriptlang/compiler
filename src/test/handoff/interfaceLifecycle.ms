// Route 5: Transform→Codegen — struct/interface lifecycle and parameter semantics
//
// Struct (value type): large structs auto-promoted to const T* in C.
// Interface (reference type): always Ref<Struct>, heap-allocated, T* in C.

import { compileToC } from "../helpers";

test "E2E C: large struct auto-promoted to const pointer param" {
	// 3 strings = 48 bytes > 24 → ccgIntroducedPtr=true → const pointer param
	const src = "struct Info { name: string; desc: string; tag: string; }\nfunction show(v: Info): void {}\nconst a: Info = { name: \"a\", desc: \"b\", tag: \"c\" };\nshow(a);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("(const Info__");
	assert c.value.contains("* v)");
	assert c.value.contains("((&(a__");
}

test "E2E C: small struct passed by value" {
	// 2 numbers = 16 bytes < 24 → no pointer introduction, plain value
	const src = "struct Pt { x: number; y: number; }\nfunction show(v: Pt): void {}\nconst a: Pt = { x: 1, y: 2 };\nshow(a);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains(" v)");
	assert !c.value.contains("* v)");
}

test "E2E C: ref param is mutable (no const)" {
	const src = "struct Vec2 { x: number; y: number; }\nfunction scale(ref v: Vec2): void {}\nlet a: Vec2 = { x: 1, y: 2 };\nscale(a);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("* v)");
	assert !c.value.contains("const Vec2__");
}

test "E2E C: interface built at run time is heap-allocated Ref" {
	const src = "interface Token { kind: number; value: string; }\nfunction mk(k: number): Token { return { kind: k, value: \"x\" }; }";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("*)msAllocTyped");
	assert c.value.contains("(sizeof(Token__");
}
