// Character Classification — Pure functions for lexer character tests
// No imports needed — operates on character codes (numbers)



// ===== Character Classifiers =====

export function isWhitespace(ch: number): boolean {
	return ch === " ".code || ch === "\t".code || ch === "\r".code;
}

export function isNewline(ch: number): boolean {
	return ch === "\n".code;
}

export function isDigit(ch: number): boolean {
	return ch >= "0".code && ch <= "9".code;
}

export function isHexDigit(ch: number): boolean {
	return (ch >= "0".code && ch <= "9".code) || (ch >= "A".code && ch <= "F".code) || (ch >= "a".code && ch <= "f".code);
}

export function isLetter(ch: number): boolean {
	return (ch >= "A".code && ch <= "Z".code) || (ch >= "a".code && ch <= "z".code) || ch === "_".code;
}

export function isAlphanumeric(ch: number): boolean {
	return isLetter(ch) || isDigit(ch);
}

export function isBinaryDigit(ch: number): boolean {
	return ch === "0".code || ch === "1".code;
}

export function isOctalDigit(ch: number): boolean {
	return ch >= "0".code && ch <= "7".code;
}

// ===== Tests =====
test "isWhitespace" {
	expect(isWhitespace(" ".code));
	expect(isWhitespace("\t".code));
	expect(isWhitespace("\r".code));
	expect(!isWhitespace("\n".code));
	expect(!isWhitespace("a".code));
	expect(!isWhitespace("0".code));
}

test "isNewline" {
	expect(isNewline("\n".code));
	expect(!isNewline("\r".code));
	expect(!isNewline(" ".code));
	expect(!isNewline("x".code));
}

test "isDigit" {
	expect(isDigit("0".code));
	expect(isDigit("5".code));
	expect(isDigit("9".code));
	expect(!isDigit("a".code));
	expect(!isDigit("A".code));
	expect(!isDigit(" ".code));
	expect(!isDigit("/".code));
}

test "isHexDigit" {
	expect(isHexDigit("0".code));
	expect(isHexDigit("9".code));
	expect(isHexDigit("a".code));
	expect(isHexDigit("f".code));
	expect(isHexDigit("A".code));
	expect(isHexDigit("F".code));
	expect(!isHexDigit("g".code));
	expect(!isHexDigit("G".code));
	expect(!isHexDigit("z".code));
	expect(!isHexDigit(" ".code));
}

test "isLetter" {
	expect(isLetter("a".code));
	expect(isLetter("z".code));
	expect(isLetter("A".code));
	expect(isLetter("Z".code));
	expect(isLetter("_".code));
	expect(!isLetter("0".code));
	expect(!isLetter("9".code));
	expect(!isLetter(" ".code));
	expect(!isLetter("-".code));
}

test "isAlphanumeric" {
	expect(isAlphanumeric("a".code));
	expect(isAlphanumeric("Z".code));
	expect(isAlphanumeric("_".code));
	expect(isAlphanumeric("0".code));
	expect(isAlphanumeric("9".code));
	expect(!isAlphanumeric(" ".code));
	expect(!isAlphanumeric("-".code));
	expect(!isAlphanumeric(".".code));
}

test "isBinaryDigit" {
	expect(isBinaryDigit("0".code));
	expect(isBinaryDigit("1".code));
	expect(!isBinaryDigit("2".code));
	expect(!isBinaryDigit("9".code));
	expect(!isBinaryDigit("a".code));
}

test "isOctalDigit" {
	expect(isOctalDigit("0".code));
	expect(isOctalDigit("7".code));
	expect(!isOctalDigit("8".code));
	expect(!isOctalDigit("9".code));
	expect(!isOctalDigit("a".code));
}
