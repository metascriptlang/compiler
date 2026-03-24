// Codegen — Name Mangling & Identifier Sanitization
//
// Shared utilities for all codegen backends.
// Character classification, core mangling, C keyword avoidance,
// module-qualified proc names, field/local manglers.

import { Symbol, SymbolKind } from "../../ast/node";
import { hasFlag, SymbolFlag } from "../../checker/symbol";


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
	const first = name.charAt(0);
	if (isDigitChar(first)) {
		result = "X" + first;
		start = 1;
	}

	for (let i = start; i < name.byteLength; i += 1) {
		const ch = name.charAt(i);
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
	for (let i = 0; i < modulePath.byteLength; i += 1) {
		const ch = modulePath.charAt(i);
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
	return `${mangled}__${moduleName}_u${id}`;
}

// Static field global name: "Counter.total" → "Counter__total"
export function staticFieldCName(qualifiedName: string): string {
	const dotIdx = qualifiedName.indexOf(".");
	if (dotIdx >= 0) {
		return mangle(qualifiedName.slice(0, dotIdx)) + "__" + safeName(qualifiedName.slice(dotIdx + 1, qualifiedName.length));
	}
	return mangle(qualifiedName);
}

// ===== Symbol → C Name (Standard reference parity) =====
// Single source of truth for function C names. Reads sym.modulePath.
// extern functions use nativeName. main() stays main_. Others get module-qualified.

export function mangledFunctionName(sym: Symbol, name: string, overloadIdx: number): string {
	if (sym !== null && sym.nativeName !== "") return sym.nativeName;
	if (name === "main") return safeName(name);
	if (sym !== null && hasFlag(sym, SymbolFlag.ImportC)) return safeName(name);
	// Use original declared name for mangling, not import alias
	const mangledName = (sym !== null && sym.originalName !== "") ? sym.originalName : name;
	if (sym !== null && sym.modulePath !== "") {
		return mangleProcName(mangledName, mangleModuleName(sym.modulePath), overloadIdx);
	}
	if (overloadIdx > 0) return `${safeName(mangledName)}__${overloadIdx}`;
	return safeName(mangledName);
}

// ===== Type Name Mangling =====

export function mangleTypeName(name: string, moduleName: string): string {
	return `${mangle(name)}__${moduleName}`;
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
		return `${mangled}_${scopeDepth}`;
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
	assert mangle("foo") === "foo";
	assert mangle("bar123") === "bar123";
	assert mangle("_private") === "_private";
}

test "leading digit" { assert mangle("3d") === "X3d"; }

test "special chars get word replacements" {
	assert mangle("a+b") === "aplusb_";
	assert mangle("x=y") === "xeqy_";
	assert mangle("<") === "lt_";
	assert mangle("a.b") === "adotb_";
}

test "empty name" { assert mangle("") === "empty_"; }

test "multiple special chars" { assert mangle("a+b*c") === "aplusbstarc_"; }

test "C keywords detected" {
	assert isCKeyword("int");
	assert isCKeyword("void");
	assert isCKeyword("return");
	assert isCKeyword("struct");
}

test "non-keywords pass" {
	assert !isCKeyword("foo");
	assert !isCKeyword("myVar");
}

test "mangleProcName" { assert mangleProcName("myFunc", "mymod", 42) === "myFunc__mymod_u42"; }

test "mangleProcName with special" { assert mangleProcName("a+b", "ops", 1) === "aplusb___ops_u1"; }

test "normal field" {
	assert mangleFieldName("x") === "x";
	assert mangleFieldName("myField") === "myField";
}

test "keyword field" {
	assert mangleFieldName("int") === "int_0";
	assert mangleFieldName("return") === "return_0";
}

test "top scope" {
	assert mangleLocalName("x", 0) === "x";
	assert mangleLocalName("foo", 0) === "foo";
}

test "nested scope" {
	assert mangleLocalName("x", 1) === "x_1";
	assert mangleLocalName("x", 3) === "x_3";
}

test "keyword at top scope" { assert mangleLocalName("int", 0) === "int_0"; }

test "normal name" { assert safeName("foo") === "foo"; }

test "keyword gets suffix" {
	assert safeName("int") === "int_";
	assert safeName("void") === "void_";
}

test "simple lowercase path" { assert mangleModuleName("mymod") === "mymod"; }

test "path separators become Z" { assert mangleModuleName("src/codegen/c") === "srcZcodegenZc"; }

test "dots become O" { assert mangleModuleName("foo.bar") === "fooObar"; }

test "uppercase becomes ordinal" {
	assert mangleModuleName("MyClass") === "77y67lass";
	assert mangleModuleName("AB") === "6566";
}

test "underscore becomes ordinal" { assert mangleModuleName("my_mod") === "my95mod"; }

test "full path with mixed case" { assert mangleModuleName("src/codegen/MyGen") === "srcZcodegenZ77y71en"; }
