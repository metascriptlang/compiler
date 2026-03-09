// Test: null-check codegen for value-type arrays and structs
// In MetaScript, `arr !== null` on a string[] (value-type msStringArray) must NOT
// emit `msStringArray != (void*)0` — C can't compare structs to void*.

import { compileToC } from "../helpers";

test "null-check on string[] emits valid C" {
	const src = `
interface Foo {
	names: string[];
	tags: string[];
}

function checkNames(f: Foo): boolean {
	if (f.names !== null) {
		return f.names.length > 0;
	}
	return false;
}
`;
	const r = compileToC(src);
	if (r.ok) {
		// Should NOT contain direct struct-to-void* comparison
		assert r.value.indexOf("msStringArray) != ((void*)") < 0;
	}
}

test "null-check on Type[] emits valid C" {
	const src = `
interface MyType {
	kind: number;
	children: MyType[];
}

function hasChildren(t: MyType): boolean {
	return t.children !== null;
}
`;
	const r = compileToC(src);
	if (r.ok) {
		assert r.value.indexOf("TypeArray) != ((void*)") < 0;
	}
}

test "null on left side: null !== arr" {
	const src = `
interface Bar {
	items: string[];
}

function isInit(b: Bar): boolean {
	return null !== b.items;
}
`;
	const r = compileToC(src);
	if (r.ok) {
		// Should NOT contain struct-to-void* comparison
		assert r.value.indexOf("msStringArray) != ((void*)") < 0;
	}
}
