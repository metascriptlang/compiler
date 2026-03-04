// Codegen — Name Mangling & Identifier Sanitization
//
// Shared utilities for all codegen backends.
// Character classification, core mangling, C keyword avoidance,
// module-qualified proc names, field/local manglers.

import { sliceStr, charAt } from "../../utils/string";
import { check } from "std/testing";

// ===== C Keywords — identifiers that need escaping =====

function isCKeyword(name: string): boolean {
	return match (name) {
		"auto" | "break" | "case" | "char" | "const" | "continue" => true,
		"default" | "do" | "double" | "else" | "enum" | "extern" => true,
		"float" | "for" | "goto" | "if" | "inline" | "int" | "long" => true,
		"register" | "restrict" | "return" | "short" | "signed" => true,
		"sizeof" | "static" | "struct" | "switch" | "typedef" => true,
		"typeof" | "union" | "unsigned" | "void" | "volatile" | "while" => true,
		"_Alignas" | "_Alignof" | "_Atomic" | "_Bool" | "_Complex" => true,
		"_Generic" | "_Imaginary" | "_Noreturn" | "_Static_assert" => true,
		"_Thread_local" => true,
		"bool" | "true" | "false" | "NULL" | "main" => true,
		_ => false,
	};
}

// ===== Character Classification (string-based, single char) =====

function isAlphaChar(ch: string): boolean {
	return match (ch) {
		"a" | "b" | "c" | "d" | "e" | "f" | "g" | "h" | "i" | "j" => true,
		"k" | "l" | "m" | "n" | "o" | "p" | "q" | "r" | "s" | "t" => true,
		"u" | "v" | "w" | "x" | "y" | "z" => true,
		"A" | "B" | "C" | "D" | "E" | "F" | "G" | "H" | "I" | "J" => true,
		"K" | "L" | "M" | "N" | "O" | "P" | "Q" | "R" | "S" | "T" => true,
		"U" | "V" | "W" | "X" | "Y" | "Z" => true,
		_ => false,
	};
}

function isDigitChar(ch: string): boolean {
	return match (ch) {
		"0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" => true,
		_ => false,
	};
}

function isAlnumChar(ch: string): boolean {
	return isAlphaChar(ch) || isDigitChar(ch);
}

// ===== Special Character Replacement =====

function specialCharName(ch: string): string {
	return match (ch) {
		"$" => "dollar",
		"%" => "percent",
		"&" => "amp",
		"^" => "roof",
		"!" => "emark",
		"?" => "qmark",
		"*" => "star",
		"+" => "plus",
		"-" => "minus",
		"/" => "slash",
		"\\" => "backslash",
		"=" => "eq",
		"<" => "lt",
		">" => "gt",
		"~" => "tilde",
		":" => "colon",
		"." => "dot",
		"@" => "at",
		"|" => "bar",
		" " => "space",
		_ => "X",
	};
}

// ===== Core Mangling =====
// Makes any identifier safe for native backends.
// Alphanumeric + underscore pass through. Special chars get word replacements.

export function mangle(name: string): string {
	if (name.length === 0) return "empty_";
	let result = "";
	let start = 0;
	let requiresUnderscore = false;

	// Leading digit: prefix with X
	const first = charAt(name, 0);
	if (isDigitChar(first)) {
		result = "X" + first;
		start = 1;
	}

	for (let i = start; i < name.length; i += 1) {
		const ch = charAt(name, i);
		if (isAlnumChar(ch)) {
			result = result + ch;
		} else if (ch === "_") {
			result = result + "_";
		} else {
			result = result + specialCharName(ch);
			requiresUnderscore = true;
		}
	}

	if (requiresUnderscore) {
		result = result + "_";
	}
	return result;
}

// ===== Character Ordinal =====
// Mangles uppercase, underscore, and special chars to decimal ASCII ordinals.
// Prevents clashes with Z (path sep) and O (dot) special meanings.

function charOrd(ch: string): string {
	return match (ch) {
		"A" => "65", "B" => "66", "C" => "67", "D" => "68", "E" => "69",
		"F" => "70", "G" => "71", "H" => "72", "I" => "73", "J" => "74",
		"K" => "75", "L" => "76", "M" => "77", "N" => "78", "O" => "79",
		"P" => "80", "Q" => "81", "R" => "82", "S" => "83", "T" => "84",
		"U" => "85", "V" => "86", "W" => "87", "X" => "88", "Y" => "89",
		"Z" => "90", "_" => "95", "-" => "45", " " => "32",
		_ => "63",
	};
}

function isLowerOrDigit(ch: string): boolean {
	return match (ch) {
		"a" | "b" | "c" | "d" | "e" | "f" | "g" | "h" | "i" | "j" => true,
		"k" | "l" | "m" | "n" | "o" | "p" | "q" | "r" | "s" | "t" => true,
		"u" | "v" | "w" | "x" | "y" | "z" => true,
		"0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" => true,
		_ => false,
	};
}

// ===== Module Name Mangling =====
// a-z, 0-9 pass through; / → Z; . → O;
// everything else (A-Z, _, special) → ord(c) as decimal string.

export function mangleModuleName(modulePath: string): string {
	let result = "";
	for (let i = 0; i < modulePath.length; i += 1) {
		const ch = charAt(modulePath, i);
		if (isLowerOrDigit(ch)) {
			result = result + ch;
		} else if (ch === "/" || ch === "\\") {
			result = result + "Z";
		} else if (ch === ".") {
			result = result + "O";
		} else {
			result = result + charOrd(ch);
		}
	}
	return result;
}

// ===== Proc Name Mangling (module-qualified) =====
// Pattern: <mangledName>__<moduleName>_u<id>

export function mangleProcName(name: string, moduleName: string, id: number): string {
	const mangled = mangle(name);
	return mangled + "__" + moduleName + "_u" + id;
}

// ===== Type Name Mangling =====

export function mangleTypeName(name: string, moduleName: string): string {
	return mangle(name) + "__" + moduleName;
}

// ===== Field Name — minimal mangling (no module prefix) =====

export function mangleFieldName(name: string): string {
	const mangled = mangle(name);
	if (isCKeyword(mangled)) return mangled + "_0";
	return mangled;
}

// ===== Local Variable Name =====

export function mangleLocalName(name: string, scopeDepth: number): string {
	const mangled = mangle(name);
	if (scopeDepth > 0 || isCKeyword(mangled)) {
		return mangled + "_" + scopeDepth;
	}
	return mangled;
}

// ===== C Standard Library Collision Check =====
// Names that conflict with C stdlib/POSIX functions and must be mangled.

function isCStdlibName(name: string): boolean {
	return match (name) {
		"exit" | "abort" | "free" | "malloc" | "calloc" | "realloc" => true,
		"printf" | "fprintf" | "sprintf" | "snprintf" | "puts" | "putchar" => true,
		"getchar" | "gets" | "fgets" | "fopen" | "fclose" | "fread" | "fwrite" => true,
		"strlen" | "strcmp" | "strcpy" | "strcat" | "strncmp" | "strncpy" => true,
		"memcpy" | "memset" | "memmove" | "memcmp" => true,
		"atoi" | "atof" | "atol" | "strtol" | "strtod" => true,
		"signal" | "raise" | "time" | "clock" | "sleep" | "usleep" => true,
		"read" | "write" | "open" | "close" | "stat" | "fstat" | "lstat" => true,
		"getenv" | "setenv" | "system" | "remove" | "rename" => true,
		"isdigit" | "isalpha" | "isalnum" | "isspace" | "toupper" | "tolower" => true,
		_ => false,
	};
}

// ===== Safe Identifier — keyword + stdlib avoidance, no module prefix =====

export function safeName(name: string): string {
	const mangled = mangle(name);
	if (isCKeyword(mangled) || isCStdlibName(mangled)) return mangled + "_";
	return mangled;
}

// ===== Tests =====
test "simple names pass through" {
	check(mangle("foo") === "foo");
	check(mangle("bar123") === "bar123");
	check(mangle("_private") === "_private");
}

test "leading digit" { check(mangle("3d") === "X3d"); }

test "special chars get word replacements" {
	check(mangle("a+b") === "aplusb_");
	check(mangle("x=y") === "xeqy_");
	check(mangle("<") === "lt_");
	check(mangle("a.b") === "adotb_");
}

test "empty name" { check(mangle("") === "empty_"); }

test "multiple special chars" { check(mangle("a+b*c") === "aplusbstarc_"); }

test "C keywords detected" {
	check(isCKeyword("int"));
	check(isCKeyword("void"));
	check(isCKeyword("return"));
	check(isCKeyword("struct"));
}

test "non-keywords pass" {
	check(!isCKeyword("foo"));
	check(!isCKeyword("myVar"));
}

test "mangleProcName" { check(mangleProcName("myFunc", "mymod", 42) === "myFunc__mymod_u42"); }

test "mangleProcName with special" { check(mangleProcName("a+b", "ops", 1) === "aplusb___ops_u1"); }

test "normal field" {
	check(mangleFieldName("x") === "x");
	check(mangleFieldName("myField") === "myField");
}

test "keyword field" {
	check(mangleFieldName("int") === "int_0");
	check(mangleFieldName("return") === "return_0");
}

test "top scope" {
	check(mangleLocalName("x", 0) === "x");
	check(mangleLocalName("foo", 0) === "foo");
}

test "nested scope" {
	check(mangleLocalName("x", 1) === "x_1");
	check(mangleLocalName("x", 3) === "x_3");
}

test "keyword at top scope" { check(mangleLocalName("int", 0) === "int_0"); }

test "normal name" { check(safeName("foo") === "foo"); }

test "keyword gets suffix" {
	check(safeName("int") === "int_");
	check(safeName("void") === "void_");
}

test "simple lowercase path" { check(mangleModuleName("mymod") === "mymod"); }

test "path separators become Z" { check(mangleModuleName("src/codegen/c") === "srcZcodegenZc"); }

test "dots become O" { check(mangleModuleName("foo.bar") === "fooObar"); }

test "uppercase becomes ordinal" {
	check(mangleModuleName("MyClass") === "77y67lass");
	check(mangleModuleName("AB") === "6566");
}

test "underscore becomes ordinal" { check(mangleModuleName("my_mod") === "my95mod"); }

test "full path with mixed case" { check(mangleModuleName("src/codegen/MyGen") === "srcZcodegenZ77y71en"); }
