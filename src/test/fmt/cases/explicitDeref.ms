// `x[]` dereferences a Ptr<T> or Ref<T>; the parser keeps it as a HiddenDeref flagged ExplicitDeref.
//
// Symptom:    printing the flagged node dropped the `[]`, so `acc[].n = 4` came back as `acc.n = 4`.
// Fix:        printDerefExpr prints the operand as an atom followed by `[]`.

import { assertFmtPreservesAst } from "../roundtrip";

test "fmt: x[] forms print back as written" {
	assert assertFmtPreservesAst("acc[].n = 4;");
	assert assertFmtPreservesAst("acc[].feed(3);");
	assert assertFmtPreservesAst("const snap = acc[];");
	assert assertFmtPreservesAst("acc[] = { n: 1 };");
	assert assertFmtPreservesAst("(get())[].n = 2;");
}
