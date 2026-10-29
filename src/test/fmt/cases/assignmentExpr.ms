import { fmt } from "../roundtrip";

test "fmt: an assignment expression takes the assignment layout of its right side" {
	assert fmt("a = b = someFunctionName(argumentNumberOne, argumentNumberTwo, argumentNumberThree, argumentNumberFour);\n") == "a = b = someFunctionName(\n\targumentNumberOne,\n\targumentNumberTwo,\n\targumentNumberThree,\n\targumentNumberFour,\n);\n";
	assert fmt("a.b = c.d = someFunctionName(argumentNumberOne, argumentNumberTwo, argumentNumberThree, argumentNumber);\n") == "a.b = c.d = someFunctionName(\n\targumentNumberOne,\n\targumentNumberTwo,\n\targumentNumberThree,\n\targumentNumber,\n);\n";
	assert fmt("a ||= someFunctionName(argumentNumberOne, argumentNumberTwo, argumentNumberThree, argumentNumberFour);\n") == "a ||= someFunctionName(\n\targumentNumberOne,\n\targumentNumberTwo,\n\targumentNumberThree,\n\targumentNumberFour,\n);\n";
}

test "fmt: a long assignment right side moves below the operator" {
	assert fmt("this.someVeryLongPropertyNameForTheTarget.anotherPropertyName = someFunctionName(argumentOne, argumentTwo);\n") == "this.someVeryLongPropertyNameForTheTarget.anotherPropertyName =\n\tsomeFunctionName(argumentOne, argumentTwo);\n";
	assert fmt("someObject.someVeryLongPropertyNameHere.anotherLongPropertyName += \"a long string rhs that goes over the line width\";\n") == "someObject.someVeryLongPropertyNameHere.anotherLongPropertyName +=\n\t\"a long string rhs that goes over the line width\";\n";
}
