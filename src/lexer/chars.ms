// Character Classification — Pure functions for lexer character tests
// No imports needed — operates on character codes (numbers)

import { test, check, testGroup } from "std/testing";

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

testGroup("Char Classification", () => {
	test("isWhitespace", () => {
		check(isWhitespace(" ".code));
		check(isWhitespace("\t".code));
		check(isWhitespace("\r".code));
		check(!isWhitespace("\n".code));
		check(!isWhitespace("a".code));
		check(!isWhitespace("0".code));
	});

	test("isNewline", () => {
		check(isNewline("\n".code));
		check(!isNewline("\r".code));
		check(!isNewline(" ".code));
		check(!isNewline("x".code));
	});

	test("isDigit", () => {
		check(isDigit("0".code));
		check(isDigit("5".code));
		check(isDigit("9".code));
		check(!isDigit("a".code));
		check(!isDigit("A".code));
		check(!isDigit(" ".code));
		check(!isDigit("/".code));
	});

	test("isHexDigit", () => {
		check(isHexDigit("0".code));
		check(isHexDigit("9".code));
		check(isHexDigit("a".code));
		check(isHexDigit("f".code));
		check(isHexDigit("A".code));
		check(isHexDigit("F".code));
		check(!isHexDigit("g".code));
		check(!isHexDigit("G".code));
		check(!isHexDigit("z".code));
		check(!isHexDigit(" ".code));
	});

	test("isLetter", () => {
		check(isLetter("a".code));
		check(isLetter("z".code));
		check(isLetter("A".code));
		check(isLetter("Z".code));
		check(isLetter("_".code));
		check(!isLetter("0".code));
		check(!isLetter("9".code));
		check(!isLetter(" ".code));
		check(!isLetter("-".code));
	});

	test("isAlphanumeric", () => {
		check(isAlphanumeric("a".code));
		check(isAlphanumeric("Z".code));
		check(isAlphanumeric("_".code));
		check(isAlphanumeric("0".code));
		check(isAlphanumeric("9".code));
		check(!isAlphanumeric(" ".code));
		check(!isAlphanumeric("-".code));
		check(!isAlphanumeric(".".code));
	});

	test("isBinaryDigit", () => {
		check(isBinaryDigit("0".code));
		check(isBinaryDigit("1".code));
		check(!isBinaryDigit("2".code));
		check(!isBinaryDigit("9".code));
		check(!isBinaryDigit("a".code));
	});

	test("isOctalDigit", () => {
		check(isOctalDigit("0".code));
		check(isOctalDigit("7".code));
		check(!isOctalDigit("8".code));
		check(!isOctalDigit("9".code));
		check(!isOctalDigit("a".code));
	});
});
