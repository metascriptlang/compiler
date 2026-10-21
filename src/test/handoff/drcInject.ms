// Route 8: DRC inject — HiddenAddr wrapping
//
// When DRC injects copy calls for large structs, the arguments
// must be wrapped with address-of (&) for pointer params.

import { compileToC } from "../helpers";

test "E2E C: DRC copy call has address-of for large struct" {
	const src = "struct Info { name: string; desc: string; tag: string }\nfunction take(x: Info): void { }\nfunction main(): void {\nconst a: Info = { name: \"a\", desc: \"b\", tag: \"c\" };\nconst b: Info = a;\ntake(a);\ntake(b);\n}";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("Copy((&(");
	assert c.value.contains(")), (&(a_");
}
