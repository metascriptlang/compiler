// Route 4: Checker→Codegen — class constructor (positional, TypeScript-style)
//
// Verifies: new ClassName(args) inlines allocation + positional field assignment
// Standard reference parity: inline object construction — no separate _new function

import { compileToC, contains } from "../helpers";

test "E2E C: new Item(42) inlines msAllocTyped" {
	const src = "class Item { value: number }\nconst x = new Item(42);";
	const c = compileToC(src);
	assert c.ok;
	assert contains(c.value, "msAllocTyped");
	assert !contains(c.value, "Item_new");
}

test "E2E C: new Item(42) assigns field by position" {
	const src = "class Item { value: number }\nconst x = new Item(42);";
	const c = compileToC(src);
	assert c.ok;
	assert contains(c.value, ".value = 42");
}

test "E2E C: multi-field positional assignment" {
	const src = "class Item { value: number; name: string }\nconst x = new Item(42, \"hi\");";
	const c = compileToC(src);
	assert c.ok;
	assert contains(c.value, ".value = 42");
	assert contains(c.value, ".name = ");
}

test "E2E C: no-arg new inlines" {
	const src = "class Item { value: number }\nconst x = new Item;";
	const c = compileToC(src);
	assert c.ok;
	assert contains(c.value, "msAllocTyped");
}

test "E2E C: class single pointer not double" {
	const src = "class Doc { kind: number; name: string }\nfunction getKind(d: Doc): number { return d.kind; }\nconst doc = new Doc(1, \"hi\");\nconst k = getKind(doc);";
	const c = compileToC(src);
	assert c.ok;
	assert contains(c.value, "Doc*");
	assert !contains(c.value, "Doc**");
}
