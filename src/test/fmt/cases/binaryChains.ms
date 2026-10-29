import { fmt } from "../roundtrip";

test "fmt: a chain of one precedence level breaks as one flat chain, each operand under the first" {
	assert fmt("foo(aaaaaaaaaaaaaaaaaaaaaaaa && bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb && cccccccccccccccccccccccccc && dddddddddddddddddddd);\n") == "foo(\n\taaaaaaaaaaaaaaaaaaaaaaaa &&\n\t\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb &&\n\t\tcccccccccccccccccccccccccc &&\n\t\tdddddddddddddddddddd,\n);\n";
	assert fmt("foo(aaaaaaaaaaaaaaaaaaaaaaaa + bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb - cccccccccccccccccccccccccc + dddddddddddddddddddd, 1);\n") == "foo(\n\taaaaaaaaaaaaaaaaaaaaaaaa +\n\t\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb -\n\t\tcccccccccccccccccccccccccc +\n\t\tdddddddddddddddddddd,\n\t1,\n);\n";
	assert fmt("foo(aaaaaaaaaaaaaaaaaaaaaaaa * bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb * cccccccccccccccccccccccccc * dddddddddddd);\n") == "foo(\n\taaaaaaaaaaaaaaaaaaaaaaaa *\n\t\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb *\n\t\tcccccccccccccccccccccccccc *\n\t\tdddddddddddd,\n);\n";
	assert fmt("foo(aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa < bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb < cccccccccccccccccccccccccc);\n") == "foo(\n\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa <\n\t\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb <\n\t\tcccccccccccccccccccccccccc,\n);\n";
	assert fmt("foo(aaaaaaaaaaaaaaaaaaaaaaaa || bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb || cccccccccccccccccccccccccc || ddddddd, 1);\n") == "foo(\n\taaaaaaaaaaaaaaaaaaaaaaaa ||\n\t\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ||\n\t\tcccccccccccccccccccccccccc ||\n\t\tddddddd,\n\t1,\n);\n";
}

test "fmt: an operand of another precedence level stays whole on its line" {
	assert fmt("foo(aaaaaaaaaaaaaaaaaaaaaaaa * bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb + cccccccccccccccccccccccccc * dddddddddddddddd);\n") == "foo(\n\taaaaaaaaaaaaaaaaaaaaaaaa * bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb +\n\t\tcccccccccccccccccccccccccc * dddddddddddddddd,\n);\n";
	assert fmt("foo(aaaaaaaaaaaaaaaaaaaaaaaa + bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb * cccccccccccccccccccccccccc + dddddddddddd);\n") == "foo(\n\taaaaaaaaaaaaaaaaaaaaaaaa +\n\t\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb * cccccccccccccccccccccccccc +\n\t\tdddddddddddd,\n);\n";
	assert fmt("foo(aaaaaaaaaaaaaaaaaaaaaaaa + (bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb + cccccccccccccccccccccccccc) + dddddddddddd);\n") == "foo(\n\taaaaaaaaaaaaaaaaaaaaaaaa +\n\t\t(bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb + cccccccccccccccccccccccccc) +\n\t\tdddddddddddd,\n);\n";
	assert fmt("foo(aaaaaaaaaaaaaaaaaaaaaaaa instanceof bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb, cccccccccccccccccccccccccc in dddddddddddddddddddd);\n") == "foo(\n\taaaaaaaaaaaaaaaaaaaaaaaa instanceof bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,\n\tcccccccccccccccccccccccccc in dddddddddddddddddddd,\n);\n";
}

test "fmt: an arrow body keeps its operands at the indent the arrow gives it" {
	assert fmt("const h = () => aaaaaaaaaaaaaaaaaaaaaaaa && bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb && cccccccccccccccccccccccccc && dddddddddddddddddddd;\n") == "const h = () =>\n\taaaaaaaaaaaaaaaaaaaaaaaa &&\n\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb &&\n\tcccccccccccccccccccccccccc &&\n\tdddddddddddddddddddd;\n";
	assert fmt("const k = (x) => x.aaaaaaaaaaaaaaaaaaaaaaaa + bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb + cccccccccccccccccccccccccc + ddddddddddd;\n") == "const k = (x) =>\n\tx.aaaaaaaaaaaaaaaaaaaaaaaa +\n\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb +\n\tcccccccccccccccccccccccccc +\n\tddddddddddd;\n";
	assert fmt("foo((x) => aaaaaaaaaaaaaaaaaaaaaaaa && bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb && cccccccccccccccccccccccccc && ddddddddd);\n") == "foo(\n\t(x) =>\n\t\taaaaaaaaaaaaaaaaaaaaaaaa &&\n\t\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb &&\n\t\tcccccccccccccccccccccccccc &&\n\t\tddddddddd,\n);\n";
}

test "fmt: an operand that needs its parentheses breaks inside them" {
	assert fmt("foo(!(aaaaaaaaaaaaaaaaaaaaaaaa && bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb && cccccccccccccccccccccccccc && dddddddddddd));\n") == "foo(\n\t!(\n\t\taaaaaaaaaaaaaaaaaaaaaaaa &&\n\t\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb &&\n\t\tcccccccccccccccccccccccccc &&\n\t\tdddddddddddd\n\t),\n);\n";
	assert fmt("foo((aaaaaaaaaaaaaaaaaaaaaaaa + bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb + cccccccccccccccccccccccccc + dddddddddddd).toString());\n") == "foo(\n\t(\n\t\taaaaaaaaaaaaaaaaaaaaaaaa +\n\t\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb +\n\t\tcccccccccccccccccccccccccc +\n\t\tdddddddddddd\n\t).toString(),\n);\n";
	assert fmt("(aaaaaaaaaaaaaaaaaaaaaaaa || bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb || cccccccccccccccccccccccccc || dddddddddd)(arg);\n") == "(\n\taaaaaaaaaaaaaaaaaaaaaaaa ||\n\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ||\n\tcccccccccccccccccccccccccc ||\n\tdddddddddd\n)(arg);\n";
	assert fmt("foo(new (aaaaaaaaaaaaaaaaaaaaaaaa || bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb || cccccccccccccccccccccccccc || dddddd)());\n") == "foo(\n\tnew (\n\t\taaaaaaaaaaaaaaaaaaaaaaaa ||\n\t\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ||\n\t\tcccccccccccccccccccccccccc ||\n\t\tdddddd\n\t)(),\n);\n";
}

test "fmt: a non-empty object or array as the last logical operand stays on the operator's line" {
	assert fmt("foo(aaaaaaaaaaaaaaaaaaaaaaaa && bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb && cccccccccccccccccccccccccc && { a: 1, b: 2 });\n") == "foo(\n\taaaaaaaaaaaaaaaaaaaaaaaa &&\n\t\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb &&\n\t\tcccccccccccccccccccccccccc && { a: 1, b: 2 },\n);\n";
	assert fmt("foo(aaaaaaaaaaaaaaaaaaaaaaaa && bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb && cccccccccccccccccccccccccc && ddddddddd && [1, 2]);\n") == "foo(\n\taaaaaaaaaaaaaaaaaaaaaaaa &&\n\t\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb &&\n\t\tcccccccccccccccccccccccccc &&\n\t\tddddddddd && [1, 2],\n);\n";
	assert fmt("foo(aaaaaaaaaaaaaaaaaaaaaaaa && [aaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbb, cccccccccccccccccccccccccccccccc]);\n") == "foo(\n\taaaaaaaaaaaaaaaaaaaaaaaa && [\n\t\taaaaaaaaaaaaaaaaaaa,\n\t\tbbbbbbbbbbbbbbbbbb,\n\t\tcccccccccccccccccccccccccccccccc,\n\t],\n);\n";
	assert fmt("foo(aaaaaaaaaaaaaaaaaaaaaaaa && {});\n") == "foo(aaaaaaaaaaaaaaaaaaaaaaaa && {});\n";
	assert fmt("const v13 = aaaaaaaaaaaaaaaaaaaaaaaa || { aaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbb, cccccccccccccccccccccccccccccccc };\n") == "const v13 = aaaaaaaaaaaaaaaaaaaaaaaa || {\n\taaaaaaaaaaaaaaaaaaa,\n\tbbbbbbbbbbbbbbbbbb,\n\tcccccccccccccccccccccccccccccccc,\n};\n";
}
