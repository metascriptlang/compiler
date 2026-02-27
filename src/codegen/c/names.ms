// C Codegen — Name Mangling & Identifier Sanitization
//
// Follows Nim's mangleutils.nim: character-level mangling for C-safe identifiers,
// module-qualified proc names, C keyword avoidance.

import { sliceStr, charAt } from "../../utils/string";
import { test, check, testGroup } from "std/testing";

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

// ===== Special Character Replacement (Nim pattern) =====

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

// ===== Core Mangling (Nim's mangle) =====
// Makes any MetaScript identifier safe for C.
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

	let i = start;
	while (i < name.length) {
		const ch = charAt(name, i);
		if (isAlnumChar(ch)) {
			result = result + ch;
		} else if (ch === "_") {
			result = result + "_";
		} else {
			result = result + specialCharName(ch);
			requiresUnderscore = true;
		}
		i += 1;
	}

	if (requiresUnderscore) {
		result = result + "_";
	}
	return result;
}

// ===== Module Name Mangling =====

export function mangleModuleName(modulePath: string): string {
	let result = "";
	let i = 0;
	while (i < modulePath.length) {
		const ch = charAt(modulePath, i);
		if (isAlnumChar(ch) || ch === "_") {
			result = result + ch;
		} else {
			result = result + "_";
		}
		i += 1;
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

// ===== Safe Identifier — just keyword avoidance, no module prefix =====

export function safeName(name: string): string {
	const mangled = mangle(name);
	if (isCKeyword(mangled)) return mangled + "_";
	return mangled;
}

// ===== Tests =====

testGroup("C Name Mangle", () => {
	test("simple names pass through", () => {
		check(mangle("foo") === "foo");
		check(mangle("bar123") === "bar123");
		check(mangle("_private") === "_private");
	});
	test("leading digit", () => {
		check(mangle("3d") === "X3d");
	});
	test("special chars get word replacements", () => {
		check(mangle("a+b") === "aplusb_");
		check(mangle("x=y") === "xeqy_");
		check(mangle("<") === "lt_");
		check(mangle("a.b") === "adotb_");
	});
	test("empty name", () => {
		check(mangle("") === "empty_");
	});
	test("multiple special chars", () => {
		check(mangle("a+b*c") === "aplusbstarc_");
	});
});

testGroup("C Name Keywords", () => {
	test("C keywords detected", () => {
		check(isCKeyword("int"));
		check(isCKeyword("void"));
		check(isCKeyword("return"));
		check(isCKeyword("struct"));
	});
	test("non-keywords pass", () => {
		check(!isCKeyword("foo"));
		check(!isCKeyword("myVar"));
	});
});

testGroup("C Name Proc", () => {
	test("mangleProcName", () => {
		check(mangleProcName("myFunc", "mymod", 42) === "myFunc__mymod_u42");
	});
	test("mangleProcName with special", () => {
		check(mangleProcName("a+b", "ops", 1) === "aplusb___ops_u1");
	});
});

testGroup("C Name Field", () => {
	test("normal field", () => {
		check(mangleFieldName("x") === "x");
		check(mangleFieldName("myField") === "myField");
	});
	test("keyword field", () => {
		check(mangleFieldName("int") === "int_0");
		check(mangleFieldName("return") === "return_0");
	});
});

testGroup("C Name Local", () => {
	test("top scope", () => {
		check(mangleLocalName("x", 0) === "x");
		check(mangleLocalName("foo", 0) === "foo");
	});
	test("nested scope", () => {
		check(mangleLocalName("x", 1) === "x_1");
		check(mangleLocalName("x", 3) === "x_3");
	});
	test("keyword at top scope", () => {
		check(mangleLocalName("int", 0) === "int_0");
	});
});

testGroup("C Name Safe", () => {
	test("normal name", () => {
		check(safeName("foo") === "foo");
	});
	test("keyword gets suffix", () => {
		check(safeName("int") === "int_");
		check(safeName("void") === "void_");
	});
});

testGroup("C Module Name", () => {
	test("simple path", () => {
		check(mangleModuleName("mymod") === "mymod");
	});
	test("path with separators", () => {
		check(mangleModuleName("src/codegen/c") === "src_codegen_c");
	});
});
