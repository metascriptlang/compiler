// Language tests: string operations

function countUpperCase(s: string): number {
	let count = 0;
	let i = 0;
	while (i < s.length) {
		const ch = s.charCodeAt(i);
		if (ch >= "A".code && ch <= "Z".code) count += 1;
		i += 1;
	}
	return count;
}

function repeatStr(s: string, n: number): string {
	let result = "";
	let i = 0;
	while (i < n) {
		result = result + s;
		i += 1;
	}
	return result;
}

test "string length" {
	assert "".length === 0;
	assert "a".length === 1;
	assert "hello".length === 5;
	assert "hello world".length === 11;
}

test "string concatenation" {
	assert "" + "" === "";
	assert "a" + "b" === "ab";
	assert "hello" + " " + "world" === "hello world";
	assert "x" + "" === "x";
}

test "string + number coercion" {
	assert "val=" + 42 === "val=42";
	assert "neg=" + -1 === "neg=-1";
	assert "zero=" + 0 === "zero=0";
}

test "string comparison" {
	assert "abc" === "abc";
	assert "abc" !== "def";
	assert "" === "";
	assert "a" !== "";
	assert "abc" !== "abcd";
}

test "string slice" {
	assert "hello".slice(0, 5) === "hello";
	assert "hello".slice(0, 1) === "h";
	assert "hello".slice(1, 3) === "el";
	assert "hello".slice(4, 5) === "o";
}

test "charCodeAt" {
	assert "A".charCodeAt(0) === 65;
	assert "a".charCodeAt(0) === 97;
	assert "0".charCodeAt(0) === 48;
	assert " ".charCodeAt(0) === 32;
}

test ".code compile-time" {
	assert "a".code === 97;
	assert "A".code === 65;
	assert "0".code === 48;
	assert "\n".code === 10;
	assert "\t".code === 9;
	assert "\\".code === 92;
}

test "startsWith / endsWith" {
	assert "hello world".startsWith("hello");
	assert !"hello world".startsWith("world");
	assert "hello world".endsWith("world");
	assert !"hello world".endsWith("hello");
	assert "test.ms".endsWith(".ms");
	assert "src/index.ms".startsWith("src/");
}

test "escape sequences" {
	assert "\n".length === 1;
	assert "\t".length === 1;
	assert "\\".length === 1;
	assert "\"".length === 1;
}

test "char-by-char counting" {
	assert countUpperCase("Hello World") === 2;
	assert countUpperCase("ABC") === 3;
	assert countUpperCase("abc") === 0;
	assert countUpperCase("") === 0;
}

test "string repeat builder" {
	assert repeatStr("ab", 3) === "ababab";
	assert repeatStr("x", 1) === "x";
	assert repeatStr("y", 0) === "";
}

test "manual string search" {
	assert "hello world".contains("world");
	assert "hello world".contains("hello");
	assert "hello world".contains("lo wo");
	assert !"hello".contains("xyz");
	assert "abc".contains("");
}
