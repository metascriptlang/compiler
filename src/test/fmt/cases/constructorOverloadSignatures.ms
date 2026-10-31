import { assertFmtContains, assertFmtIdempotent } from "../roundtrip";

test "fmt: constructor signatures retain semicolons" {
	const source = `class C {
		constructor(value: string);
		constructor(value: int32);
		constructor(value: string | int32) {}
	}`;
	assert assertFmtContains(source, "constructor(value: string);");
	assert assertFmtContains(source, "constructor(value: int32);");
	assert assertFmtContains(source, "constructor(value: string | int32) {}");
	assert assertFmtIdempotent(source);
}

test "fmt: abstract class constructor signatures retain visibility" {
	const source = `abstract class C {
		protected constructor(value: string);
		protected constructor(value: string) {}
	}`;
	assert assertFmtContains(source, "protected constructor(value: string);");
	assert assertFmtIdempotent(source);
}

test "fmt: an explicit abstract constructor keeps its refused modifier" {
	const source = "class C { abstract constructor(value: string) {} }";
	assert assertFmtContains(source, "abstract constructor(value: string) {}");
	assert assertFmtIdempotent(source);
}
