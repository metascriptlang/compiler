import { fmt } from "../roundtrip";

test "fmt: a returned or thrown binary expression is wrapped in parentheses when it breaks" {
	assert fmt("function f() {\n\treturn aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa && bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb;\n}\n") == "function f() {\n\treturn (\n\t\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa && bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n\t);\n}\n";
	assert fmt("function f() {\n\tthrow aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa || bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb;\n}\n") == "function f() {\n\tthrow (\n\t\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa || bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n\t);\n}\n";
}

test "fmt: a returned argument that is not binary or fits keeps its own layout" {
	assert fmt("function f() {\n\treturn a && b;\n}\n") == "function f() {\n\treturn a && b;\n}\n";
	assert fmt("function f() {\n\treturn aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa(bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb);\n}\n") == "function f() {\n\treturn aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa(\n\t\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,\n\t);\n}\n";
}

test "fmt: a statement header that does not fit breaks inside its parentheses" {
	assert fmt("if (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa(bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)) {\n\tx;\n}\n") == "if (\n\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa(\n\t\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,\n\t)\n) {\n\tx;\n}\n";
	assert fmt("while (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa(bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)) {\n\tx;\n}\n") == "while (\n\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa(\n\t\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,\n\t)\n) {\n\tx;\n}\n";
	assert fmt("do {\n\tx;\n} while (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa(bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb));\n") == "do {\n\tx;\n} while (\n\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa(\n\t\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,\n\t)\n);\n";
	assert fmt("switch (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa(bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)) {\n\tcase 1:\n\t\tx;\n}\n") == "switch (\n\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa(\n\t\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,\n\t)\n) {\n\tcase 1:\n\t\tx;\n}\n";
}
