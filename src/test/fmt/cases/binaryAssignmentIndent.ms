import { fmt } from "../roundtrip";

test "fmt: a binary expression on the right of an assignment-like parent adds no indent" {
	assert fmt("const p = someVeryLongFunctionNameThatGoesOnnnnnnnnnnnnnn(argumentNumberOne) || someOtherLongFunctionName(arg);\n") == "const p =\n\tsomeVeryLongFunctionNameThatGoesOnnnnnnnnnnnnnn(argumentNumberOne) ||\n\tsomeOtherLongFunctionName(arg);\n";
	assert fmt("class A { prop = someVeryLongFunctionNameThatGoesOnnnnnnnnnnnnnn(argumentNumberOne) || someOtherLongFunctionName(arg); }\n") == "class A {\n\tprop =\n\t\tsomeVeryLongFunctionNameThatGoesOnnnnnnnnnnnnnn(argumentNumberOne) ||\n\t\tsomeOtherLongFunctionName(arg);\n}\n";
	assert fmt("x.y = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa + bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb;\n") == "x.y =\n\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa +\n\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb;\n";
	assert fmt("const o = { veryLongKeyNameHereToBeNotShort: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa + bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb };\n") == "const o = {\n\tveryLongKeyNameHereToBeNotShort:\n\t\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa +\n\t\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,\n};\n";
	assert fmt("const { a, b } = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa || bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb || ccccccccccccccc;\n") == "const { a, b } =\n\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ||\n\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ||\n\tccccccccccccccc;\n";
	assert fmt("f(aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa || bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb || ccccccccccccccccccccc);\n") == "f(\n\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ||\n\t\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ||\n\t\tccccccccccccccccccccc,\n);\n";
}
