// Type arguments of a call or `new`, closed by a shift token.
//
// Symptom:    `new Box<Box<Box<int32>>>(two)` formatted to
//             `new Box<Box < Box < int32 > >>(two)`; the lossless check refused it
//             because the source's `>>>` token came back as `>` and `>>`.
// Root cause: the printer rebuilt the list from Node.typeArg, the parser's
//             space-joined token text, which cannot say how the closers were written.
// Fix:        the printer copies the `<...>` list from the source after the callee's
//             name (rawGenericsAt), and falls back to Node.typeArg without a source.

import { assertFmtLossless, assertFmtPreservesAst } from "../roundtrip";

const BOX = "class Box<T> { v: T; constructor(v: T) { this.v = v; } }\n";

test "fmt: new with nested type arguments closed by one shift token" {
	assert assertFmtLossless(BOX + "const one = new Box<int32>(1);\nconst two = new Box<Box<int32>>(one);\nconst three = new Box<Box<Box<int32>>>(two);\n");
	assert assertFmtPreservesAst(BOX + "const one = new Box<int32>(1);\nconst three = new Box<Box<Box<int32>>>(new Box<Box<int32>>(new Box<int32>(1)));\n");
}

test "fmt: closers written apart stay apart" {
	assert assertFmtLossless(BOX + "const m = new Map<string, Box<int32> >();\n");
}

test "fmt: a generic call with nested type arguments" {
	assert assertFmtLossless(BOX + "function mk<T>(): T[] { return []; }\nconst made = mk<Box<Box<int32>>>();\n");
}

test "fmt: a generic method call with nested type arguments" {
	assert assertFmtLossless(BOX + "class F { make<T>(): T[] { return []; } }\nconst f = new F();\nconst made = f.make<Box<Box<int32>>>();\n");
}
