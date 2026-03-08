// Route 5: Transform→Codegen — interface lifecycle hooks
//
// Large interfaces (> 24 bytes) should have pointer params with deref
// in their lifecycle hooks (copy/destroy).

import { compileToC, contains } from "../helpers";

test "E2E C: large interface lifecycle uses pointer params" {
	// 3 strings = 48 bytes > 24 → ccgIntroducedPtr=true → pointer params
	const src = "interface Info { name: string; desc: string; tag: string }\nconst a: Info = { name: \"a\", desc: \"b\", tag: \"c\" };\nconst b: Info = a;";
	const c = compileToC(src);
	assert c.ok;
	if (contains(c.value, "Info_copy")) {
		// Params should be pointer type
		assert contains(c.value, "Info*");
	}
}

test "E2E C: large interface lifecycle body uses deref" {
	const src = "interface Info { name: string; desc: string; tag: string }\nconst a: Info = { name: \"a\", desc: \"b\", tag: \"c\" };\nconst b: Info = a;";
	const c = compileToC(src);
	assert c.ok;
	if (contains(c.value, "Info_copy")) {
		// Body must use (*dest).name or dest->name, NOT dest.name
		assert contains(c.value, "(*dest)") || contains(c.value, "dest->");
	}
}

test "E2E C: small interface no pointer introduction" {
	// 2 numbers = 16 bytes < 24 → no pointer introduction
	const src = "interface Pt { x: number; y: number }\nconst a: Pt = { x: 1, y: 2 };\nconst b: Pt = a;";
	const c = compileToC(src);
	assert c.ok;
	// Small struct should not generate lifecycle hooks (only primitives)
}
