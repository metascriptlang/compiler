// Codegen — Name Mangling & Identifier Sanitization
//
// Shared utilities for all codegen backends.
// Character classification, core mangling, C keyword avoidance,
// module-qualified proc names, field/local manglers.

import { Symbol, SymbolKind } from "../../ast/node";
import { hasFlag, setFlag, SymbolFlag, makeSymbol } from "../../checker/symbol";
import { noneType } from "../../checker/types";


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
	// Ensure the mangled name starts with a letter so it is a valid C identifier
	// when used as the first token (e.g. in `<modname>__Init000`). Windows
	// absolute paths begin with a drive letter (`C:` → `67` + wildcard), and
	// uppercase-first relative paths (`MyMod` → `77y...`) start with a digit.
	// POSIX absolute paths avoid this by chance (leading `/` → `Z`).
	if (result.length > 0 && result.charAt(0) >= "0" && result.charAt(0) <= "9") {
		result = "M" + result;
	}
	return result;
}

// ===== Qualified Identifier — module-scoped C name =====
// Pattern: <mangledName>__<moduleName>
//
// Canonical composition used by every code path that needs a module-qualified
// global identifier in C: procs append their overload ID to this, globals use
// it as-is, future type-wrappers compose on top. Keeping the pattern in one
// helper prevents drift across codegen sites (reference parity: Nim's
// `fillBackendName` consolidates the same pattern behind one proc).

export function mangleQualified(name: string, moduleName: string): string {
	return `${mangle(name)}__${moduleName}`;
}

// ===== Proc Name Mangling (module-qualified + overload disambig) =====
// Pattern: <mangledName>__<moduleName>_u<id>

export function mangleProcName(name: string, moduleName: string, id: number): string {
	return `${mangleQualified(name, moduleName)}_u${id}`;
}

// ===== Type Name Mangling (module-qualified identity) =====
// Reference parity: Nim getTypeName — the C type name carries the declaring
// symbol's identity (Nim appends sigHash; here the module qualifier, matching
// the proc/global convention). extern/ImportC types keep the raw C name
// (Nim sfImportc/sfExportc rule). Monomorphized instances ("__") and
// compiler-generated ("$") names keep their existing spelling.

// One globally cached object per shape, shared by every module, name already
// encoding its content — so the sym it happens to carry is whichever module
// created it first, not an owner. Same carve-out as "$" and mono "__" above.
export function isSharedStructuralName(name: string): boolean {
	if (name.length > 6 && name.slice(0, 6) === "Maybe_") return true;
	if (name.length > 8 && name.slice(0, 8) === "msTuple_") return true;
	if (name.length > 7 && name.slice(0, 7) === "msAnon_") return true;
	if (name.length > 8 && name.slice(0, 8) === "msUnion_") return true;
	return false;
}

export function mangledTypeName(sym: Symbol | null, name: string): string {
	if (sym !== null) {
		const early = symExternOrImportName(sym, name);
		if (early !== "") return early;
	}
	if (name.length > 0 && name.slice(0, 1) === "$") return mangle(name);
	if (name.indexOf("__", 0) >= 0) return mangle(name);
	if (isSharedStructuralName(name)) return mangle(name);
	if (sym !== null && sym.modulePath !== "") {
		return mangleQualified(name, mangleModuleName(sym.modulePath));
	}
	return mangle(name);
}

// Static field global name: "Counter.total" → "Counter__total"
export function staticFieldCName(qualifiedName: string): string {
	const dotIdx = qualifiedName.indexOf(".");
	if (dotIdx >= 0) {
		return mangle(qualifiedName.slice(0, dotIdx)) + "__" + safeName(qualifiedName.slice(dotIdx + 1, qualifiedName.length));
	}
	return mangle(qualifiedName);
}

// ===== Symbol-aware C name: shared early-exit =====
// Every Symbol-aware wrapper (function, global, future type) first checks
// whether the symbol bypasses mangling: extern symbols (sym.nativeName set
// from `from "c_name"` clause) and ImportC symbols (runtime/C FFI) use their
// raw C name directly. Returns "" to signal the caller should fall through
// to its own rule (proc vs global vs type).
function symExternOrImportName(sym: Symbol | null, name: string): string {
	if (sym !== null && sym.nativeName !== "") return sym.nativeName;
	if (sym !== null && hasFlag(sym, SymbolFlag.ImportC)) return safeName(name);
	return "";
}

// ===== Symbol → C Name (Standard reference parity) =====
// Single source of truth for function C names. Reads sym.modulePath.
// extern functions use nativeName. main() stays main_. Others get module-qualified.

export function mangledFunctionName(sym: Symbol | null, name: string, overloadIdx: number): string {
	if (name === "main") return safeName(name);
	const early = symExternOrImportName(sym, name);
	if (early !== "") return early;
	// Use original declared name for mangling, not import alias
	const baseName = (sym !== null && sym.originalName !== "") ? sym.originalName : name;
	if (sym !== null && sym.modulePath !== "") {
		return mangleProcName(baseName, mangleModuleName(sym.modulePath), overloadIdx);
	}
	if (overloadIdx > 0) return `${safeName(baseName)}__${overloadIdx}`;
	return safeName(baseName);
}

// ===== Overload winner selection (shared by C and JS call emission) =====
// rawIdx is the RAW winner slot from check-time overload resolution —
// slot 0 = primary, slot k = sym.overloads[k-1]. The winner may be a
// body-less signature (OverloadSig flag); redirect to the unique
// body-bearing sym in the set. Keeping the redirect in codegen lets
// check-time preserve the winner slot for LSP views (hover, sig help).

export interface OverloadWinner {
	winnerSym: Symbol;
	winnerIdx: number;
}

export function resolveOverloadWinner(sym: Symbol, rawIdx: number): OverloadWinner {
	let winnerSym: Symbol = sym;
	if (rawIdx > 0 && rawIdx - 1 < sym.overloads.length) {
		winnerSym = sym.overloads[rawIdx - 1];
	}
	let emitIdx = rawIdx;
	let emitSym = winnerSym;
	if (winnerSym !== null && hasFlag(winnerSym, SymbolFlag.OverloadSig)) {
		if (!hasFlag(sym, SymbolFlag.OverloadSig)) {
			emitSym = sym;
			emitIdx = 0;
		} else {
			for (let oi = 0; oi < sym.overloads.length; oi += 1) {
				const cand = sym.overloads[oi];
				if (cand !== null && !hasFlag(cand, SymbolFlag.OverloadSig)) {
					emitSym = cand;
					emitIdx = oi + 1;
					break;
				}
			}
		}
	}
	if (emitIdx < 0) emitIdx = 0;
	return { winnerSym: emitSym, winnerIdx: emitIdx };
}

// ===== Symbol-aware classification — is this a module-level global variable? =====
// Single source of truth for the condition that differentiates module-level `const`/`let`
// from locals and other SymbolKind.Variable cases. Used by multiple codegen emission sites
// (global decl, cross-module extern, identifier reference) — extracting prevents drift if
// the definition changes (e.g. future static class fields).
//
// Criteria: Symbol is a Variable, has Global flag (set by collectPass on module-level
// declarations), and has a known defining module.

export function isModuleGlobalVar(sym: Symbol | null): boolean {
	if (sym === null) return false;
	if (sym.symbolKind !== SymbolKind.Variable) return false;
	// Flag set in two places: (1) collectPass for own-module top-level VariableDecl,
	// (2) importSymFromRegistry for imported Variable syms (exports can only be
	// module-level). Distinguishes module-level globals from locals — both have
	// modulePath set (defineOrError stamps it), only globals carry this flag.
	if (!hasFlag(sym, SymbolFlag.Global)) return false;
	if (sym.modulePath === null || sym.modulePath === "") return false;
	return true;
}

// ===== Symbol → C Name for module-level globals =====
// Mirrors mangledFunctionName for `const`/`let` at module scope. Fixes latent
// cross-module C linker collision when two modules declare same-named constants
// (e.g. `MAX_TIME` in cursors.ms and varpartitions.ms). Same extern/ImportC
// early-exit as functions; same module-qualifier pattern minus the overload ID
// (module globals have no overloads).

export function mangledGlobalName(sym: Symbol | null, name: string): string {
	const early = symExternOrImportName(sym, name);
	if (early !== "") return early;
	const baseName = (sym !== null && sym.originalName !== "") ? sym.originalName : name;
	// A `static` decl inside a body shares the module namespace with every other
	// body in the module, so the module qualifier alone does not separate two
	// sites spelling the same name. Both the declaration and every read recompute
	// the name through here, so the site suffix must live here to stay one source.
	const site = (sym !== null && hasFlag(sym, SymbolFlag.StaticLocal))
		? `__static${sym.location.line.toString()}_${sym.location.column.toString()}`
		: "";
	if (sym !== null && sym.modulePath !== "") {
		return mangleQualified(baseName, mangleModuleName(sym.modulePath)) + site;
	}
	return safeName(baseName) + site;
}

// ===== Field Name — minimal mangling (no module prefix) =====

export function mangleFieldName(name: string): string {
	const mangled = mangle(name);
	if (isCKeyword(mangled)) return mangled + "_0";
	return mangled;
}

// Note: local variable unique naming happens in `fillLocalName` (statements.ms),
// which tracks occurrences per CProc and appends a scope-aware suffix. Nothing
// in codegen needs a standalone `mangleLocalName(name, depth)` helper.

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
		"stdin" | "stdout" | "stderr" => true,
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

test "mangleQualified basic" { assert mangleQualified("foo", "mymod") === "foo__mymod"; }

test "mangleQualified with special char" { assert mangleQualified("a+b", "mymod") === "aplusb___mymod"; }

test "mangleProcName" { assert mangleProcName("myFunc", "mymod", 42) === "myFunc__mymod_u42"; }

test "mangleProcName with special" { assert mangleProcName("a+b", "ops", 1) === "aplusb___ops_u1"; }

test "mangledGlobalName no sym falls through to safeName" {
	assert mangledGlobalName(null, "FOO") === "FOO";
}

test "mangledGlobalName no modulePath falls through to safeName" {
	const sym = makeSymbol("FOO", SymbolKind.Variable, noneType(), false);
	assert mangledGlobalName(sym, "FOO") === "FOO";
}

test "mangledGlobalName extern nativeName bypass" {
	const sym = makeSymbol("x", SymbolKind.Variable, noneType(), false);
	sym.nativeName = "my_c_sym";
	sym.modulePath = "src/foo.ms";
	assert mangledGlobalName(sym, "FOO") === "my_c_sym";
}

test "mangledGlobalName module-qualified" {
	const sym = makeSymbol("MAX", SymbolKind.Variable, noneType(), false);
	sym.modulePath = "src/foo.ms";
	assert mangledGlobalName(sym, "MAX") === "MAX__srcZfooOms";
}

test "mangledGlobalName prefers originalName over import alias" {
	const sym = makeSymbol("aliased", SymbolKind.Variable, noneType(), false);
	sym.modulePath = "src/foo.ms";
	sym.originalName = "ORIG";
	assert mangledGlobalName(sym, "aliased") === "ORIG__srcZfooOms";
}

test "mangledFunctionName main stays safe" {
	assert mangledFunctionName(null, "main", 0) === "main_";
}

test "mangledFunctionName plain name no sym" {
	assert mangledFunctionName(null, "foo", 0) === "foo";
}

test "mangledFunctionName module-qualified" {
	const sym = makeSymbol("bar", SymbolKind.Function, noneType(), false);
	sym.modulePath = "src/foo.ms";
	assert mangledFunctionName(sym, "bar", 0) === "bar__srcZfooOms_u0";
}

test "mangledFunctionName nativeName bypass (extern)" {
	const sym = makeSymbol("printf", SymbolKind.Function, noneType(), false);
	sym.nativeName = "printf";
	sym.modulePath = "std/io.ms";
	assert mangledFunctionName(sym, "printf", 0) === "printf";
}

test "mangledFunctionName ImportC bypass" {
	const sym = makeSymbol("malloc", SymbolKind.Function, noneType(), false);
	sym.modulePath = "std/core.ms";
	setFlag(sym, SymbolFlag.ImportC);
	// malloc is in isCStdlibName → safeName adds trailing underscore
	assert mangledFunctionName(sym, "malloc", 0) === "malloc_";
}

test "mangledFunctionName overloadIdx disambiguates" {
	const sym = makeSymbol("foo", SymbolKind.Function, noneType(), false);
	sym.modulePath = "src/bar.ms";
	assert mangledFunctionName(sym, "foo", 2) === "foo__srcZbarOms_u2";
}

test "mangledFunctionName prefers originalName over import alias" {
	const sym = makeSymbol("aliasedFn", SymbolKind.Function, noneType(), false);
	sym.modulePath = "src/bar.ms";
	sym.originalName = "realFn";
	assert mangledFunctionName(sym, "aliasedFn", 0) === "realFn__srcZbarOms_u0";
}

test "mangledFunctionName no modulePath with overloadIdx" {
	assert mangledFunctionName(null, "foo", 3) === "foo__3";
}

test "normal field" {
	assert mangleFieldName("x") === "x";
	assert mangleFieldName("myField") === "myField";
}

test "keyword field" {
	assert mangleFieldName("int") === "int_0";
	assert mangleFieldName("return") === "return_0";
}

test "normal name" { assert safeName("foo") === "foo"; }

test "keyword gets suffix" {
	assert safeName("int") === "int_";
	assert safeName("void") === "void_";
}

test "simple lowercase path" { assert mangleModuleName("mymod") === "mymod"; }

test "path separators become Z" { assert mangleModuleName("src/codegen/c") === "srcZcodegenZc"; }

test "dots become O" { assert mangleModuleName("foo.bar") === "fooObar"; }

test "uppercase becomes ordinal" {
	assert mangleModuleName("MyClass") === "M77y67lass";
	assert mangleModuleName("AB") === "M6566";
}

test "windows drive letter does not produce digit-leading identifier" {
	// `C:` → `67` + wildcard — without guard this yields `6763Z…`, invalid as C ident.
	const out = mangleModuleName("C:/Users/foo/mod.cms");
	assert out.charAt(0) === "M";
}

test "underscore becomes ordinal" { assert mangleModuleName("my_mod") === "my95mod"; }

test "full path with mixed case" { assert mangleModuleName("src/codegen/MyGen") === "srcZcodegenZ77y71en"; }
