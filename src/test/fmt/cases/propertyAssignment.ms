import { fmt } from "../roundtrip";

test "fmt: an object property follows the assignment layout with a short key rule" {
	assert fmt("const o = { \"quoted-key\": someObject.someProperty.anotherProperty.finalProperty.yetAnotherPropertyName1 };\n") == "const o = {\n\t\"quoted-key\":\n\t\tsomeObject.someProperty.anotherProperty.finalProperty\n\t\t\t.yetAnotherPropertyName1,\n};\n";
	assert fmt("const o = { abcde: \"a long string rhs that goes over the line width of eighty characters for sure yes sure yes\" };\n") == "const o = {\n\tabcde:\n\t\t\"a long string rhs that goes over the line width of eighty characters for sure yes sure yes\",\n};\n";
	assert fmt("const o = { abcd: \"a long string rhs that goes over the line width of eighty characters for sure yes sure yes\" };\n") == "const o = {\n\tabcd: \"a long string rhs that goes over the line width of eighty characters for sure yes sure yes\",\n};\n";
	assert fmt("const o = { [computed]: someValueeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee };\n") == "const o = {\n\t[computed]:\n\t\tsomeValueeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee,\n};\n";
	assert fmt("const o = { [a]: \"a long string rhs that goes over the line width of eighty characters for sure yes sure yes\" };\n") == "const o = {\n\t[a]: \"a long string rhs that goes over the line width of eighty characters for sure yes sure yes\",\n};\n";
	assert fmt("const o = { someLongKeyName: someFunctionName(argumentNumberOne, argumentNumberTwo, argumentNumberThree) };\n") == "const o = {\n\tsomeLongKeyName: someFunctionName(\n\t\targumentNumberOne,\n\t\targumentNumberTwo,\n\t\targumentNumberThree,\n\t),\n};\n";
}
