test "a BOM and nonbreaking space are code trivia" {
	const value = 42;
	assert value == 42;
}

test "a BOM between a keyword and a name keeps the binding" {
	const﻿value = 7;
	assert value == 7;
}

test "quoted horizontal trivia keeps its text value" {
	const text = "﻿ ";
	assert text.length == 2;
}
