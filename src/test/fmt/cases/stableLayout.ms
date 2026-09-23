import { assertFmtIdempotent } from "../roundtrip";

test "fmt: a trailing comment after a statement the printer breaks is stable" {
	assert assertFmtIdempotent("const t = { a: overloadedOne(1, 2, 3), b: plainTwo(4, 5, 6), c: another(7, 8, 9) }; // object-literal field\nconst u = 1;\n");
}

test "fmt: a braceless if and else on one line whose body the printer breaks is stable" {
	assert assertFmtIdempotent("function f(c: int32): void {\n\tif (c > 0) afterOperatorComments.push(someVeryLongFunctionName(argumentNumberOne, argumentNumberTwo)); else before.push(c);\n}\n");
}
