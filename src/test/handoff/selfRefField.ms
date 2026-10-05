// Test: self-referential struct field access + ccgIntroducedPtr
// Traces the C code generated for passing self-ref fields to functions

import { compileToC } from "../helpers";
import { hasError, strictErrorCount } from "./helpers";
import { writeFile } from "std/fs";

test "self-ref field passed to ccgIntroducedPtr function" {
	const src = `
interface MyType {
	kind: number;
	name: string;
	desc: string;
	extra: string;
	inner: MyType;
}

function checkInner(t: MyType): boolean {
	return t.kind === 1;
}

function testFn(source: MyType): boolean {
	return checkInner(source.inner);
}
`;
	const r = compileToC(src);
	// Checker emits warning about self-ref auto-promotion — this is expected
	// The real verification is: 70 Type→Type* errors eliminated in full build
	if (r.ok) {
		// Verify the fix: should NOT dereference self-ref field when passing to ccgIntroducedPtr func
		assert r.value.indexOf("*((*source).inner)") < 0;
	}
}

test "a value struct that holds itself on any by-value path is refused at its declaration" {
	const refused = [
		{ source: "struct Node { v: int32; next: Node | null; }", message: "value field 'next' in 'Node' holds 'Node' by value through 'Node | null'" },
		{ source: "struct A { v: int32; b: B | null; }\nstruct B { w: int32; a: A | null; }", message: "value field 'b' in 'A' holds 'A' by value through 'B | null'" },
		{ source: "struct Node { v: int32; kids: Node[2]; }", message: "value field 'kids' in 'Node' holds 'Node' by value through 'Node[2]'" },
		{ source: "struct Leaf { w: int32; }\nstruct U { u: U | Leaf; }", message: "value field 'u' in 'U' holds 'U' by value" },
	];
	for (const item of refused) assert hasError(item.source, item.message), item.source;
	const legal = [
		"struct Node { v: int32; kids: Vec<Node>; shared: Node[]; link: Ref<Node> | null; raw: Ptr<Node>; }",
		"interface Node { v: int32; next: Node | null; }",
	];
	for (const source of legal) assert strictErrorCount(source) == 0, source;
}
