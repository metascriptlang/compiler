import { strictErrorCount, hasError } from "./helpers";

test "a number-literal field is not read as a field of another numeric width" {
	assert hasError("const a: { n: 1; v: string } = { n: 1, v: \"x\" };\nconst b: { n: number; v: string } = a;", "memory layout differs");
	assert hasError("const a: { n: 1.5; v: string } = { n: 1.5, v: \"x\" };\nconst b: { n: int32; v: string } = a;", "memory layout differs");
	assert hasError("const a: { n: number; v: string } = { n: 1, v: \"x\" };\nconst b: { n: 1; v: string } = a;", "memory layout differs");
}

test "a number-literal field is read as the field of the width that stores it" {
	assert strictErrorCount("const a: { n: 1; v: string } = { n: 1, v: \"x\" };\nconst b: { n: int32; v: string } = a;") == 0;
	assert strictErrorCount("const a: { n: 1.5; v: string } = { n: 1.5, v: \"x\" };\nconst b: { n: number; v: string } = a;") == 0;
}
