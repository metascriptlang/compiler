import { fmt } from "../roundtrip";

test "fmt: a string or literal right side that does not fit moves below the operator" {
	assert fmt("const loooooooooooooooooooooooooooooooooooooooooooooooong = \"a long string rhs that goes over the line width\";\n") == "const loooooooooooooooooooooooooooooooooooooooooooooooong =\n\t\"a long string rhs that goes over the line width\";\n";
	assert fmt("const u = !\"a long string rhs that goes over the line width of eighty characters for sure yes sure\";\n") == "const u =\n\t!\"a long string rhs that goes over the line width of eighty characters for sure yes sure\";\n";
	assert fmt("const w = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;\n") == "const w =\n\taaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;\n";
	assert fmt("const s = await someFunction.anotherPropertyName.yetAnotherProp;\n") == "const s = await someFunction.anotherPropertyName.yetAnotherProp;\n";
	assert fmt("const sss = await someVeryLongFunctionName.anotherPropertyName.yetAnotherPropertyName;\n") == "const sss =\n\tawait someVeryLongFunctionName.anotherPropertyName.yetAnotherPropertyName;\n";
}

test "fmt: a poorly breakable chain moves below the operator" {
	assert fmt("const someVeryLongVariableNameHere = someObject.someProperty.anotherProperty.finalProperty;\n") == "const someVeryLongVariableNameHere =\n\tsomeObject.someProperty.anotherProperty.finalProperty;\n";
	assert fmt("const result = this.someVeryLongPropertyName.anotherVeryLongPropertyName.getTheValue();\n") == "const result =\n\tthis.someVeryLongPropertyName.anotherVeryLongPropertyName.getTheValue();\n";
}

test "fmt: a require call, a template, a number and a class never break after the operator" {
	assert fmt("const v = require(\"some-long-module-name-that-goes-on-and-on-and-on-and-on-and-on-and-on-and-on-and-on\");\n") == "const v = require(\"some-long-module-name-that-goes-on-and-on-and-on-and-on-and-on-and-on-and-on-and-on\");\n";
	assert fmt("const t = `template literal that is long enough to exceed the print width of eighty characters ok`;\n") == "const t = `template literal that is long enough to exceed the print width of eighty characters ok`;\n";
	assert fmt("const n = 123456789012345678901234567890123456789012345678901234567890123456789012345678901;\n") == "const n = 123456789012345678901234567890123456789012345678901234567890123456789012345678901;\n";
}

test "fmt: a call, an array and a conditional stay behind the operator and break inside" {
	assert fmt("const shortKey = someFunctionName(argumentNumberOne, argumentNumberTwo, argumentNumberThree, four);\n") == "const shortKey = someFunctionName(\n\targumentNumberOne,\n\targumentNumberTwo,\n\targumentNumberThree,\n\tfour,\n);\n";
	assert fmt("const yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy = [aaaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbb];\n") == "const yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy = [\n\taaaaaaaaaaaaaaaaaaaaa,\n\tbbbbbbbbbbbbbbbbbbbbbb,\n];\n";
	assert fmt("const veryLongVariableNameForTheResult = condition ? someValueWhenTrue : someOtherValueWhenFalse1;\n") == "const veryLongVariableNameForTheResult = condition\n\t? someValueWhenTrue\n\t: someOtherValueWhenFalse1;\n";
	assert fmt("const k = condition1 && condition2 ? aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa : bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb;\n") == "const k =\n\tcondition1 && condition2\n\t\t? aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n\t\t: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb;\n";
}

test "fmt: a complex type annotation keeps the call on the operator line" {
	assert fmt("const m: Map<string, Array<number>> = new Map();\n") == "const m: Map<string, Array<number>> = new Map();\n";
	assert fmt("const mm: Map<string, Array<number>> = someFunctionCall(argumentOne, argumentTwo, argumentThree, ar);\n") == "const mm: Map<string, Array<number>> = someFunctionCall(\n\targumentOne,\n\targumentTwo,\n\targumentThree,\n\tar,\n);\n";
	assert fmt("const fn: Foo<Bar> = (argumentNumberOne, argumentNumberTwo, argumentNumberThree, argumentFour) => 1;\n") == "const fn: Foo<Bar> = (\n\targumentNumberOne,\n\targumentNumberTwo,\n\targumentNumberThree,\n\targumentFour,\n) => 1;\n";
	assert fmt("const typed: Map<string, number> = someFunctionName(argumentNumberOne, argumentNumberTwo, three);\n") == "const typed: Map<string, number> = someFunctionName(\n\targumentNumberOne,\n\targumentNumberTwo,\n\tthree,\n);\n";
}

test "fmt: an object pattern breaks as its own group and a complex one stays open on the operator" {
	assert fmt("const { a: { b } } = x;\n") == "const {\n\ta: { b },\n} = x;\n";
	assert fmt("const { a, b: { c } } = x;\n") == "const {\n\ta,\n\tb: { c },\n} = x;\n";
	assert fmt("let { a, b, c = 1 } = obj;\n") == "let { a, b, c = 1 } = obj;\n";
	assert fmt("const { a, ...rest } = x;\n") == "const { a, ...rest } = x;\n";
	assert fmt("const { aaaaaaaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb, ccccccccccccccccccccccccccc } = x;\n") == "const {\n\taaaaaaaaaaaaaaaaaaaaaaaaa,\n\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,\n\tccccccccccccccccccccccccccc,\n} = x;\n";
	assert fmt("const { a, b, c: d } = some.very.long.chain.of.members.that.is.poorly.breakable.indeed.really.yes;\n") == "const {\n\ta,\n\tb,\n\tc: d,\n} = some.very.long.chain.of.members.that.is.poorly.breakable.indeed.really.yes;\n";
}

test "fmt: a class property follows the same layout as a declarator" {
	assert fmt("class A { prop = \"a long string rhs that goes over the line width of eighty characters for sure yes sure\"; }\n") == "class A {\n\tprop =\n\t\t\"a long string rhs that goes over the line width of eighty characters for sure yes sure\";\n}\n";
	assert fmt("class A { readonly y = someFunctionName(argumentNumberOne, argumentNumberTwo, argumentNumberThree); }\n") == "class A {\n\treadonly y = someFunctionName(\n\t\targumentNumberOne,\n\t\targumentNumberTwo,\n\t\targumentNumberThree,\n\t);\n}\n";
	assert fmt("class A { x: number = 1; }\n") == "class A {\n\tx: number = 1;\n}\n";
}

test "fmt: a type alias with a name-only right side moves it below the operator" {
	assert fmt("type G = Veryyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy;\n") == "type G =\n\tVeryyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy;\n";
	assert fmt("type Short = string;\n") == "type Short = string;\n";
}
