// Checker contract of `&&=`, `||=` and `??=`: the right side is stored into the place under the
// place's own type, and the operators are statements like every assignment.

import { strictErrorCount, hasError } from "./helpers";

const PRELUDE = "class Item { n: int32 = 1; label: string | null = null; }\n";

test "each logical assignment on a name, a field and an element checks clean" {
	const src = PRELUDE + "function f(o: Item, xs: int32[]): void {\n"
		+ "\tlet a: int32 | null = null;\n\ta ??= 1;\n\tlet b: int32 = 0;\n\tb ||= 2;\n\tb &&= 3;\n"
		+ "\to.label ??= \"x\";\n\to.n ||= 4;\n\txs[0] &&= 5;\n}";
	assert strictErrorCount(src) == 0;
}

test "the right side must fit the place under its declared type" {
	assert hasError("let a: int32 | null = null;\na ??= \"s\";", "Type 'string' is not assignable to type 'int32 | null'");
	assert hasError("let b: int32 = 0;\nb ||= \"s\";", "Type 'string' is not assignable to type 'int32'");
	assert hasError("let c: int32 = 1;\nc &&= \"s\";", "Type 'string' is not assignable");
}

test "a logical assignment is a statement, not a value" {
	assert hasError("let a: int32 | null = null;\nconst r = (a ??= 5);", "assignment is a statement");
	assert hasError("let b: int32 = 0;\nconst r = (b ||= 5);", "assignment is a statement");
	assert hasError("let c: int32 = 0;\nconst r = (c &&= 5);", "assignment is a statement");
}

test "a const place is refused" {
	assert hasError("const a: int32 = 0;\na ||= 1;", "cannot assign to 'a'");
}

test "a reference place reads as the class after ??= and ||= and stays nullable without them" {
	const read = "\tconst z: Item = held;\n\treturn z;\n}";
	const head = PRELUDE + "function f(given: Item | null): Item {\n\tlet held: Item | null = given;\n";
	assert strictErrorCount(head + "\theld ??= new Item();\n" + read) == 0;
	assert strictErrorCount(head + "\theld ||= new Item();\n" + read) == 0;
	assert hasError(head + read, "Type 'Item | null' is not assignable to type 'Item'");
}
