import { assertFmtLossless, assertFmtIdempotent, fmt } from "../roundtrip";

test "fmt: an empty static block stays on one line" {
	assert fmt("class A { static {} }\n") == "class A {\n\tstatic {}\n}\n";
	assert assertFmtIdempotent("class A { static {} }\n");
}

test "fmt: a static block with a statement breaks onto its own lines" {
	assert fmt("class B { static { f(); } }\n") == "class B {\n\tstatic {\n\t\tf();\n\t}\n}\n";
}

test "fmt: an empty else block is kept and breaks to two lines" {
	assert fmt("if (a) { b(); } else {}\n") == "if (a) {\n\tb();\n} else {\n}\n";
	assert fmt("if (a) {} else {}\n") == "if (a) {\n} else {\n}\n";
	assert assertFmtLossless("if (a) { b(); } else {}\n");
	assert assertFmtIdempotent("if (a) { b(); } else {}\n");
}
