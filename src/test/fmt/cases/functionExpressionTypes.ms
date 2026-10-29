import { fmt } from "../roundtrip";

test "fmt: an arrow prints its parameter and return types from their tree" {
	assert fmt("const h = (): { a: number, b: string } => x;\n") == "const h = (): { a: number; b: string } => x;\n";
	assert fmt("const p = (o: { a: number, b: string }) => o;\n") == "const p = (o: { a: number; b: string }) => o;\n";
}

test "fmt: a function expression prints its return type from its tree" {
	assert fmt("const g = function (): { a: number, b: string } { return x; };\n") == "const g = function (): { a: number; b: string } {\n\treturn x;\n};\n";
}
