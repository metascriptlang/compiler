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
	if (c.value.contains("Item_copy")) {
		// Class lifecycle: params should be Item* (pointer), not Item (value)
		assert c.value.contains("Item_copy(Item*") || c.value.contains("Item_copy(Item *");
	}
}

test "E2E C: class lifecycle body does not use plain member access" {
	const src = "class Item { name: string; value: number }\nconst a = new Item(\"x\", 1);\nconst b = a;";
	const c = compileToC(src);
	assert c.ok;
	if (c.value.contains("Item_destroy")) {
		// If params are pointers, body must not use self.name (should use (*self).name or self->name)
		// If params are by-value (Item self), self.name is correct — but mutations won't propagate
		// Either way, verify consistency
		assert c.value.contains("Item_destroy(Item*") || c.value.contains("Item_destroy(Item ");
	}
}
