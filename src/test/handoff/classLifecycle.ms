// Route 6: Class lifecycle hooks — critical handoff
//
// Class = Ref<Struct>. destructorLifting unwraps to Struct.
// Hooks must still work with pointer semantics.

import { compileToC } from "../helpers";

test "E2E C: class lifecycle hooks have pointer params" {
	// Class with string field needs lifecycle hooks for RC
	const src = "class Item { name: string; value: number }\nconst a = new Item(\"x\", 1);\nconst b = a;";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("Copy(Item__");
	assert c.value.contains("* dest, Item__");
}

test "E2E C: class lifecycle body does not use plain member access" {
	const src = "class Item { name: string; value: number }\nconst a = new Item(\"x\", 1);\nconst b = a;";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("Destroy(Item__");
	assert c.value.contains("msStringDecref((*self).name)");
	assert !c.value.contains("self.name");
}
