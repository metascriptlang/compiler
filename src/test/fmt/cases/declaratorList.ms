import { fmt } from "../roundtrip";

test "fmt: a declaration list with an initializer puts each declarator on its own line" {
	assert fmt("const x = 1, y = 2;\n") == "const x = 1,\n\ty = 2;\n";
	assert fmt("let a: number, b: number = 1, c: number;\n") == "let a: number,\n\tb: number = 1,\n\tc: number;\n";
}

test "fmt: a declaration list without an initializer breaks only when it does not fit" {
	assert fmt("let a: number, b: number;\n") == "let a: number, b: number;\n";
	assert fmt("let aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: number, bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb: number, cccccc: number;\n") == "let aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: number,\n\tbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb: number,\n\tcccccc: number;\n";
}
