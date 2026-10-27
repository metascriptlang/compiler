import { assertFmtLossless, assertFmtIdempotent } from "../roundtrip";

function keeps(src: string): boolean {
	return assertFmtLossless(src) && assertFmtIdempotent(src);
}

test "fmt: a comment after a one-line static block stays after its brace" {
	assert keeps("class L {\n\tstatic b: number = 0;\n\tstatic { L.b = 1; } // c\n}\n");
}

test "fmt: a comment after a one-line struct stays after its brace, at top level and in a body" {
	assert keeps("struct S { a: number; } // c\n");
	assert keeps("function f(): void {\n\tstruct S { a: number; } // c\n}\n");
}

test "fmt: a comment after a decorator stays on the decorator's line" {
	assert keeps("class C {\n\t@dec // c\n\tname: string = \"x\";\n}\n");
}

test "fmt: a comment after a decorated member stays after the member" {
	assert keeps("class C {\n\t@dec\n\tname: string = \"x\"; // c\n}\n");
	assert keeps("class C {\n\t@dec\n\tname: string = \"x\"; // c\n\tother: number = 1;\n}\n");
}
