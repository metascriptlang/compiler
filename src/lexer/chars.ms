// Character Classification — Pure functions for lexer character tests
// No imports needed — operates on byte codes (int32)



// ===== Character Classifiers =====

export function isWhitespace(ch: int32): boolean {
	return ch === " ".code || ch === "\t".code || ch === "\r".code;
}

export function isNewline(ch: int32): boolean {
	return ch === "\n".code;
}

export function isDigit(ch: int32): boolean {
	return ch >= "0".code && ch <= "9".code;
}

export function isHexDigit(ch: int32): boolean {
	return (ch >= "0".code && ch <= "9".code) || (ch >= "A".code && ch <= "F".code) || (ch >= "a".code && ch <= "f".code);
}

export function isLetter(ch: int32): boolean {
	return (ch >= "A".code && ch <= "Z".code) || (ch >= "a".code && ch <= "z".code) || ch === "_".code;
}

export function isAlphanumeric(ch: int32): boolean {
	return isLetter(ch) || isDigit(ch);
}

export function isBinaryDigit(ch: int32): boolean {
	return ch === "0".code || ch === "1".code;
}

export function isOctalDigit(ch: int32): boolean {
	return ch >= "0".code && ch <= "7".code;
}

// ===== Tests =====
test "isWhitespace" {
	assert isWhitespace(" ".code);
	assert isWhitespace("\t".code);
	assert isWhitespace("\r".code);
	assert !isWhitespace("\n".code);
	assert !isWhitespace("a".code);
	assert !isWhitespace("0".code);
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
