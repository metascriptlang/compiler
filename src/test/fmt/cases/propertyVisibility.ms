// Visibility modifiers (`private`, `public`, `protected`) on class
// properties survive fmt roundtrip.
//
// Symptom:    `class Foo { private x: number = 1; }` formats to
//             `class Foo { x: number = 1; }` — visibility silently
//             dropped at parse time, never recoverable at print time.
// Root cause: parser at declaration.ms:993-998 consumed the keyword
//             token and discarded it.
// Fix:        Capture into a propVisibility string field on
//             PropertyDeclData; printPropertyDecl emits it as a
//             leading modifier.

import { assertFmtContains, assertFmtPreservesAst } from "../roundtrip";

test "fmt: private class property preserved" {
	const src = "class Foo { private x: number = 1; }";
	assertFmtPreservesAst(src);
	assertFmtContains(src, "private x");
}

test "fmt: protected class property preserved" {
	const src = "class Foo { protected y: string = \"a\"; }";
	assertFmtPreservesAst(src);
	assertFmtContains(src, "protected y");
}

test "fmt: public class property preserved" {
	const src = "class Foo { public z: boolean = true; }";
	assertFmtPreservesAst(src);
	assertFmtContains(src, "public z");
}
