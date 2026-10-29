import { fmt } from "../roundtrip";

test "fmt: a binary expression returned or thrown keeps its operands at one level" {
	assert fmt("function h() { return aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa && bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb && ccccccccccccccccccccc; }\n") == "function h() {\n\treturn (\n\t\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa &&\n\t\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb &&\n\t\tccccccccccccccccccccc\n\t);\n}\n";
	assert fmt("function h() { throw aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa && bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb && ccccccccccccccccccccc; }\n") == "function h() {\n\tthrow (\n\t\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa &&\n\t\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb &&\n\t\tccccccccccccccccccccc\n\t);\n}\n";
}

test "fmt: a binary expression in a statement header keeps its operands at one level" {
	assert fmt("while (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa && bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb && ccccccccccccccccccccc) { x(); }\n") == "while (\n\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa &&\n\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb &&\n\tccccccccccccccccccccc\n) {\n\tx();\n}\n";
	assert fmt("do { x(); } while (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa && bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb && ccccccccccccccccccccc);\n") == "do {\n\tx();\n} while (\n\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa &&\n\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb &&\n\tccccccccccccccccccccc\n);\n";
	assert fmt("if (someVeryLongFunctionNameThatGoesOnnnnnnnnnnnnnn(argumentNumberOne, argumentNumberTwo) || someOtherLongFunctionName(argumentNumberOne, argumentNumberTwo, three)) { x(); }\n") == "if (\n\tsomeVeryLongFunctionNameThatGoesOnnnnnnnnnnnnnn(\n\t\targumentNumberOne,\n\t\targumentNumberTwo,\n\t) ||\n\tsomeOtherLongFunctionName(argumentNumberOne, argumentNumberTwo, three)\n) {\n\tx();\n}\n";
}
