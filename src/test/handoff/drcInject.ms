// Route 8: DRC inject — HiddenAddr wrapping
//
// When DRC injects copy calls for large structs, the arguments
// must be wrapped with address-of (&) for pointer params.

import { compileToC } from "../helpers";

test "E2E C: DRC copy call has address-of for large struct" {
	const src = "interface Info { name: string; desc: string; tag: string }\nfunction take(x: Info): void { }\nconst a: Info = { name: \"a\", desc: \"b\", tag: \"c\" };\ntake(a);";
	const c = compileToC(src);
	assert c.ok;
	if (c.value.contains("InfoCopy")) {
		assert c.value.contains("&(");
	}
}
