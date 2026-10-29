import { assertFmtLossless, assertFmtIdempotent, fmt } from "../roundtrip";

function one(source: string): string {
	return fmt("f(" + source + ");\n");
}

test "fmt: a single-quoted string prints in double quotes" {
	assert one("'a'") == "f(\"a\");\n";
	assert one("\"b\"") == "f(\"b\");\n";
	assert one("''") == "f(\"\");\n";
}

test "fmt: an apostrophe in a single-quoted string loses its escape" {
	assert one("'it\\'s'") == "f(\"it's\");\n";
}

test "fmt: a string keeps the quote that needs fewer escapes" {
	assert one("'say \"hi\"'") == "f('say \"hi\"');\n";
	assert one("\"say \\\"hi\\\"\"") == "f('say \"hi\"');\n";
	assert one("'both \\' and \"'") == "f(\"both ' and \\\"\");\n";
	assert one("'\\\"'") == "f('\\\"');\n";
}

test "fmt: an escape is rewritten only where the quote changes" {
	assert one("\"\\'\"") == "f(\"\\'\");\n";
	assert one("'a\\nb\\\\'") == "f(\"a\\nb\\\\\");\n";
}

test "fmt: a double-quoted string with an unescaped single quote is untouched" {
	assert one("\"'\\\"\"") == "f(\"'\\\"\");\n";
}

test "fmt: import and export sources print in double quotes" {
	assert fmt("import { x } from 'mod';\n") == "import { x } from \"mod\";\n";
	assert fmt("import { y } from 'mod2';\n") == "import { y } from \"mod2\";\n";
	assert fmt("export * from 'mod3';\n") == "export * from \"mod3\";\n";
}

test "fmt: an object key loses quotes it does not need and keeps the rest" {
	assert fmt("const o = { 'one': 1, \"a-b\": 2, 'it\\'s': 3 };\n") == "const o = { one: 1, \"a-b\": 2, \"it's\": 3 };\n";
	assert fmt("const o = { \"new\": 1, \"1\": 2, \"\": 3, '$x': 4 };\n") == "const o = { \"new\": 1, \"1\": 2, \"\": 3, $x: 4 };\n";
}

test "fmt: an object key that is a reserved word is unquoted and still parses" {
	const keys = ["class", "match", "type", "async", "get", "static", "of", "when", "defer", "move", "test", "struct", "actor", "extern", "from", "default", "null", "true", "this", "typeof", "in", "char", "ref", "function", "if", "return", "enum", "let", "const", "await", "yield", "delete", "void", "macro", "quote", "sizeof", "template", "converter", "distinct", "out", "unreachable", "assert", "undefined", "false", "super", "as", "is", "set", "interface", "import", "export", "case", "var", "while", "for", "do", "else", "try", "catch", "finally", "throw", "switch", "with", "debugger", "continue", "instanceof", "extends"];
	for (const k of keys) {
		const source = "const o = { \"" + k + "\": 1 };\n";
		assert fmt(source) == "const o = { " + k + ": 1 };\n";
		assert assertFmtLossless(source);
	}
}

test "fmt: a string stays lossless and stable after normalization" {
	assert assertFmtLossless("f('a', 'it\\'s', 'say \"hi\"', \"\\'\");\n");
	assert assertFmtIdempotent("f('a', 'it\\'s', 'say \"hi\"', \"\\'\");\n");
}
