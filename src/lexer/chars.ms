// Character Classification — Pure functions for lexer character tests
// No imports needed — operates on byte codes (int32)



// ===== Character Classifiers =====

export function isWhitespace(ch: int32): boolean {
	return ch == " ".code || ch == "\t".code || ch == "\r".code || ch == 0x0B || ch == 0x0C;
}

export function isNewline(ch: int32): boolean {
	return ch == "\n".code;
}

export function whitespaceWidth(source: string, offset: int32): int32 {
	const length = source.byteLength;
	if (offset < 0 || offset >= length) return 0;
	const first = source.byteAt(offset);
	if (isWhitespace(first) || isNewline(first)) return 1;
	if (first < 0x80 || offset + 1 >= length) return 0;
	const second = source.byteAt(offset + 1);
	if (first == 0xC2 && (second == 0x85 || second == 0xA0)) return 2;
	if (offset + 2 >= length) return 0;
	const third = source.byteAt(offset + 2);
	if ((first == 0xE1 && second == 0x9A && third == 0x80) ||
		(first == 0xE2 && second == 0x80 &&
			((third >= 0x80 && third <= 0x8B) || third == 0xAF)) ||
		(first == 0xE2 && second == 0x81 && third == 0x9F) ||
		(first == 0xE3 && second == 0x80 && third == 0x80) ||
		(first == 0xEF && second == 0xBB && third == 0xBF)) return 3;
	return 0;
}

export function isDigit(ch: int32): boolean {
	return ch >= "0".code && ch <= "9".code;
}

export function isHexDigit(ch: int32): boolean {
	return (ch >= "0".code && ch <= "9".code) || (ch >= "A".code && ch <= "F".code) || (ch >= "a".code && ch <= "f".code);
}

export function isLetter(ch: int32): boolean {
	return (ch >= "A".code && ch <= "Z".code) || (ch >= "a".code && ch <= "z".code) || ch == "_".code;
}

export function isAlphanumeric(ch: int32): boolean {
	return isLetter(ch) || isDigit(ch);
}

export function isBinaryDigit(ch: int32): boolean {
	return ch == "0".code || ch == "1".code;
}

export function isOctalDigit(ch: int32): boolean {
	return ch >= "0".code && ch <= "7".code;
}

// ===== Tests =====
test "isWhitespace" {
	assert isWhitespace(" ".code);
	assert isWhitespace("\t".code);
	assert isWhitespace("\r".code);
	assert isWhitespace(0x0B);
	assert isWhitespace(0x0C);
	assert !isWhitespace(0xA0);
	assert !isWhitespace("\n".code);
	assert !isWhitespace("a".code);
	assert !isWhitespace("0".code);
}

test "horizontal whitespace widths preserve complete UTF-8 sequences" {
	const codes = [9, 11, 12, 32, 0x85, 0xA0, 0x1680, 0x2000, 0x2001,
		0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009,
		0x200A, 0x200B, 0x202F, 0x205F, 0x3000, 0xFEFF];
	for (const code of codes) {
		const space = String.fromCharCode(code);
		assert whitespaceWidth(space + "x", 0) == space.byteLength;
		assert whitespaceWidth("a" + space + "b", 1) == space.byteLength;
	}
}

test "whitespace width rejects absent truncated and non-whitespace input" {
	const bom = String.fromCharCode(0xFEFF);
	assert whitespaceWidth("", 0) == 0;
	assert whitespaceWidth(" ", -1) == 0;
	assert whitespaceWidth(" ", 1) == 0;
	assert whitespaceWidth("a", 0) == 0;
	assert whitespaceWidth(bom.byteSlice(0, 1), 0) == 0;
	assert whitespaceWidth(bom.byteSlice(0, 2), 0) == 0;
	assert whitespaceWidth(String.fromCharCode(0x180E), 0) == 0;
	assert whitespaceWidth(String.fromCharCode(0x200C), 0) == 0;
	assert whitespaceWidth(String.fromCharCode(0x2060), 0) == 0;
}

test "isNewline" {
	assert isNewline("\n".code);
	assert !isNewline("\r".code);
	assert !isNewline(" ".code);
	assert !isNewline("x".code);
}

test "isDigit" {
	assert isDigit("0".code);
	assert isDigit("5".code);
	assert isDigit("9".code);
	assert !isDigit("a".code);
	assert !isDigit("A".code);
	assert !isDigit(" ".code);
	assert !isDigit("/".code);
}

test "isHexDigit" {
	assert isHexDigit("0".code);
	assert isHexDigit("9".code);
	assert isHexDigit("a".code);
	assert isHexDigit("f".code);
	assert isHexDigit("A".code);
	assert isHexDigit("F".code);
	assert !isHexDigit("g".code);
	assert !isHexDigit("G".code);
	assert !isHexDigit("z".code);
	assert !isHexDigit(" ".code);
}

test "isLetter" {
	assert isLetter("a".code);
	assert isLetter("z".code);
	assert isLetter("A".code);
	assert isLetter("Z".code);
	assert isLetter("_".code);
	assert !isLetter("0".code);
	assert !isLetter("9".code);
	assert !isLetter(" ".code);
	assert !isLetter("-".code);
}

test "isAlphanumeric" {
	assert isAlphanumeric("a".code);
	assert isAlphanumeric("Z".code);
	assert isAlphanumeric("_".code);
	assert isAlphanumeric("0".code);
	assert isAlphanumeric("9".code);
	assert !isAlphanumeric(" ".code);
	assert !isAlphanumeric("-".code);
	assert !isAlphanumeric(".".code);
}

test "isBinaryDigit" {
	assert isBinaryDigit("0".code);
	assert isBinaryDigit("1".code);
	assert !isBinaryDigit("2".code);
	assert !isBinaryDigit("9".code);
	assert !isBinaryDigit("a".code);
}

test "isOctalDigit" {
	assert isOctalDigit("0".code);
	assert isOctalDigit("7".code);
	assert !isOctalDigit("8".code);
	assert !isOctalDigit("9".code);
	assert !isOctalDigit("a".code);
}
