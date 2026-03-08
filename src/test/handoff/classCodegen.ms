// Route 4: Checker→Codegen — class type in C
//
// Verifies that class types compile to single pointer (Doc*) not double
// pointer (Doc**), and member access uses pointer dereference.

import { compileToC, contains } from "../helpers";

test "E2E C: class type single pointer not double" {
	const src = "class Doc { kind: number; name: string }\nfunction getKind(d: Doc): number { return d.kind; }\nconst doc = new Doc(1, \"hi\");\nconst k = getKind(doc);";
	const c = compileToC(src);
	assert c.ok;
	assert contains(c.value, "Doc*");
	assert !contains(c.value, "Doc**");
}

test "E2E C: class function param uses (*d).field" {
	// Class param d is Ref<Struct> → codegen gets Doc* → member access must use (*d).field
	const src = "class Doc { kind: number; name: string }\nfunction getKind(d: Doc): number { return d.kind; }\nconst doc = new Doc(1, \"hi\");\nconst k = getKind(doc);";
	const c = compileToC(src);
	assert c.ok;
	// Should use (*d).kind or d->kind, NOT d.kind (d is a pointer)
	assert contains(c.value, "(*d).kind") || contains(c.value, "d->kind");
}

test "E2E C: nullable class no double pointer" {
	const src = "class Nd { value: number }\nfunction process(n: Nd): number {\n  if (n === null) { return 0; }\n  return n.value;\n}\nconst nd = new Nd(42);\nconst r = process(nd);";
	const c = compileToC(src);
	assert c.ok;
	assert !contains(c.value, "Nd**");
}
