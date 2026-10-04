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
	assert "".length == 0;
	assert "a".length == 1;
	assert "hello".length == 5;
	assert "hello world".length == 11;
}

test "string concatenation" {
	assert "" + "" == "";
	assert "a" + "b" == "ab";
	assert "hello" + " " + "world" == "hello world";
	assert "x" + "" == "x";
}

test "string + number coercion" {
	assert "val=" + 42 == "val=42";
	assert "neg=" + -1 == "neg=-1";
	assert "zero=" + 0 == "zero=0";
}

test "string comparison" {
	assert "abc" == "abc";
	assert "abc" != "def";
	assert "" == "";
	assert "a" != "";
	assert "abc" != "abcd";
}

test "string slice" {
	assert "hello".slice(0, 5) == "hello";
	assert "hello".slice(0, 1) == "h";
	assert "hello".slice(1, 3) == "el";
	assert "hello".slice(4, 5) == "o";
}

test "charCodeAt" {
	assert "A".charCodeAt(0) == 65;
	assert "a".charCodeAt(0) == 97;
	assert "0".charCodeAt(0) == 48;
	assert " ".charCodeAt(0) == 32;
}

test ".code compile-time" {
	assert "a".code == 97;
	assert "A".code == 65;
	assert "0".code == 48;
	assert "\n".code == 10;
	assert "\t".code == 9;
	assert "\\".code == 92;
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
	assert "\n".length == 1;
	assert "\t".length == 1;
	assert "\\".length == 1;
	assert "\"".length == 1;
}

test "char-by-char counting" {
	assert countUpperCase("Hello World") == 2;
	assert countUpperCase("ABC") == 3;
	assert countUpperCase("abc") == 0;
	assert countUpperCase("") == 0;
}

test "string repeat builder" {
	assert repeatStr("ab", 3) == "ababab";
	assert repeatStr("x", 1) == "x";
	assert repeatStr("y", 0) == "";
}

test "manual string search" {
	assert "hello world".contains("world");
	assert "hello world".contains("hello");
	assert "hello world".contains("lo wo");
	assert !"hello".contains("xyz");
	assert "abc".contains("");
}

function byteChar(s: string, i: int32): char {
	return s.byteAt(i) as char;
}

test "a char converts to its character in a concatenation" {
	const c = byteChar("a", 0);
	assert "<" + c + ">" + c == "<a>a";
	assert c + "x" == "ax";
	assert `${c}-${c}` == "a-a";
	let acc = "";
	for (let i: int32 = 0; i < 3; i += 1) acc += c;
	assert acc == "aaa";
}

test "a char converts to its character through toString and String" {
	const c = byteChar("b", 0);
	assert c.toString() == "b";
	assert String(c) == "b";
	assert c.toString(16) == "62";
}

struct TextPoint { x: int32; y: int32 }
struct TextSize { w: int32 }

struct TextPrice { cents: int32 }

function toString(this p: TextPrice): string {
	return "$" + (p.cents / 100).toString();
}

function textShape(k: int32): TextPoint | TextSize | TextPrice | string {
	if (k == 0) return { x: 1, y: 2 };
	if (k == 1) return { w: 7 };
	if (k == 3) return { cents: 500 } as TextPrice;
	return "none";
}

test "a union converts through the toString of the member its tag selects" {
	assert String(textShape(0)) == "{\"x\":1,\"y\":2}";
	assert textShape(1).toString() == "{\"w\":7}";
	assert String(textShape(2)) == "none";
	assert String(textShape(3)) == "$5";
}

test "a lone byte of 0x80 or more converts to U+FFFD" {
	const hi = byteChar("\u{00E9}", 0);
	assert String(hi) == "\u{FFFD}";
	assert "[" + hi + "]" == "[\u{FFFD}]";
	assert `${hi}`.byteLength == 3;
}
