// A class keeps its `implements` clause through fmt.
//
// Symptom: `class Pet implements Named { … }` was refused ("fmt changes `implements` into `{`"):
//          the parser skipped the clause, so the printer had nothing to print.
// Fix:     ClassDeclData.classImplements keeps each entry as written; printClassDecl prints it
//          after `extends`.

import { assertFmtLossless, assertFmtIdempotent } from "../roundtrip";

const iface = "interface Named {\n\tname: string;\n}\ninterface Aged {\n\tage: int32;\n}\ninterface Box<T> {\n\tvalue: T;\n}\n";

test "fmt: implements one interface keeps the source tokens" {
	assert assertFmtLossless(iface + "class Pet implements Named {\n\tname: string = \"p\";\n}\n");
}

test "fmt: implements two interfaces keeps the source tokens" {
	assert assertFmtLossless(iface + "class Pet implements Named, Aged {\n\tname: string = \"p\";\n\tage: int32 = 1;\n}\n");
}

test "fmt: extends and implements keep the source tokens" {
	assert assertFmtLossless(iface + "class Animal {\n\tage: int32 = 1;\n}\nclass Pet extends Animal implements Named {\n\tname: string = \"p\";\n}\n");
}

test "fmt: a generic implements keeps the source tokens" {
	assert assertFmtLossless(iface + "class Cell<T> implements Box<T>, Box<Box<T>> {\n\tvalue: T;\n\tconstructor(v: T) {\n\t\tthis.value = v;\n\t}\n}\n");
}

test "fmt: a one-line class with implements formats twice to the same text" {
	assert assertFmtIdempotent(iface + "class Pet implements Named { name: string = \"p\"; }\n");
}
