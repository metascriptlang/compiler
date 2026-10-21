// Codegen — Name Mangling & Identifier Sanitization
//
// Shared utilities for all codegen backends.
// Character classification, core mangling, C keyword avoidance,
// module-qualified proc names, field/local manglers.

import { Symbol, SymbolKind } from "../../ast/node";
import { hasFlag, setFlag, SymbolFlag, makeSymbol } from "../../checker/symbol";
import { noneType } from "../../checker/types";
import { isAbsolute, relative } from "std/fs/path";


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
	if (name.length == 0) return "empty_";
	const leadingDigit = isAsciiDigit(name.byteAt(0));
	if (!leadingDigit && isAsciiWord(name)) return name;
	let result = "";
	let start = 0;
	let requiresUnderscore = false;

	// Leading digit: prefix with X
	if (leadingDigit) {
		result = "X" + name.charAt(0);
		start = 1;
	}

	for (let i = start; i < name.byteLength; i += 1) {
		const ch = name.charAt(i);
		if (isAsciiWordChar(ch)) {
			result = result + ch;
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

const ESCAPED_PREFIX = "X_";

function isAsciiDigit(b: int32): boolean {
	return b >= "0".code && b <= "9".code;
}

function isAsciiAlnum(b: int32): boolean {
	return (b >= "a".code && b <= "z".code) || (b >= "A".code && b <= "Z".code) || isAsciiDigit(b);
}

function isAsciiWordChar(ch: string): boolean {
	return ch.byteLength == 1 && (isAsciiAlnum(ch.byteAt(0)) || ch.byteAt(0) == "_".code);
}

function isAsciiWord(name: string): boolean {
	for (let i = 0; i < name.byteLength; i += 1) {
		const b = name.byteAt(i);
		if (!(isAsciiAlnum(b) || b == "_".code)) return false;
	}
	return true;
}

function keepsMangledSpelling(name: string): boolean {
	if (name.byteLength == 0 || name.startsWith(ESCAPED_PREFIX)) return false;
	let hasDollar = false;
	for (let i = 0; i < name.byteLength; i += 1) {
		const b = name.byteAt(i);
		if (b == "$".code) {
			hasDollar = true;
		} else if (!(isAsciiAlnum(b) || b == "_".code) || (i == 0 && b >= "0".code && b <= "9".code)) {
			return false;
		}
	}
	if (name.indexOf("dollar") < 0) return true;
	return !hasDollar && !name.endsWith("_");
}

function escapedPropertyName(name: string): string {
	let out = ESCAPED_PREFIX;
	for (let i = 0; i < name.byteLength; i += 1) {
		const b = name.byteAt(i);
		out = isAsciiAlnum(b) && b != "X".code
			? out + name.byteSlice(i, i + 1)
			: out + "X" + b.toString(16).toUpperCase().padStart(2, "0");
	}
	return out;
}

export function mangleProperty(name: string): string {
	return keepsMangledSpelling(name) ? mangle(name) : escapedPropertyName(name);
}

export function mangleSeparatedProperty(name: string): string {
	const kept = mangleProperty(name);
	return kept.indexOf("__") >= 0 ? escapedPropertyName(name) : kept;
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

export interface ModuleNameRoots {
	compiler: string;
	packages: string;
	project: string;
}

let moduleNameRoots: ModuleNameRoots = { compiler: "", packages: "", project: "" };

export function setModuleNameRoots(roots: ModuleNameRoots): void {
	moduleNameRoots = roots;
}

function pathUnder(path: string, root: string): string {
	if (root == "" || !path.startsWith(`${root}/`)) return "";
	return path.slice(root.byteLength + 1, path.byteLength);
}

interface RootedModulePath {
	mark: string;
	path: string;
}

function rootModulePath(modulePath: string, roots: ModuleNameRoots): RootedModulePath {
	if (!isAbsolute(modulePath)) return { mark: "", path: modulePath };
	const inCompiler = pathUnder(modulePath, roots.compiler);
	if (inCompiler != "") return { mark: "S", path: inCompiler };
	const inPackages = pathUnder(modulePath, roots.packages);
	if (inPackages != "") return { mark: "P", path: inPackages };
	if (roots.project == "") return { mark: "", path: modulePath };
	return { mark: "", path: relative(roots.project, modulePath) };
}

export function moduleDisplayPath(modulePath: string): string {
	return rootModulePath(modulePath, moduleNameRoots).path;
}

export function mangleModuleName(modulePath: string): string {
	return mangleRootedModuleName(modulePath, moduleNameRoots);
}

function mangleRootedModuleName(modulePath: string, roots: ModuleNameRoots): string {
	const rooted = rootModulePath(modulePath, roots);
	return rooted.mark + encodeModulePath(rooted.path);
}

function encodeModulePath(modulePath: string): string {
	let result = "";
	for (let i = 0; i < modulePath.byteLength; i += 1) {
		const ch = modulePath.charAt(i);
		if (isLowerOrDigit(ch)) {
			result = result + ch;
		} else if (ch == "/" || ch == "\\") {
			result = result + "Z";
		} else if (ch == ".") {
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
// (Nim sfImportc/sfExportc rule). An instance symbol's name already carries the
// generic's owner, and a type without a declaring symbol is named by the
// compiler from its content, so both keep their spelling.

export function ownedGeneratedName(sym: Readonly<Symbol> | null): boolean {
	return sym != null && sym.modulePath != "";
}

export function mangledTypeName(sym: Readonly<Symbol> | null, name: string): string {
	if (sym != null) {
		const early = symExternOrImportName(sym, name);
		if (early != "") return early;
	}
	if (name.length > 0 && name.slice(0, 1) == "$") return ownedGeneratedName(sym) ? mangleQualified(name, mangleModuleName(sym!.modulePath)) : mangle(name);
	if (sym != null && sym.modulePath != "" && sym.instantiatedFrom == null) {
		return mangleQualified(name, mangleModuleName(sym.modulePath));
	}
	return mangle(name);
}

export function classInitCName(classCName: string): string {
	return classCName + "_init";
}

// Static field global name: "Counter.total" → "Counter__total__<module>"
export function staticFieldCName(sym: Readonly<Symbol>): string {
	const name = sym.name;
	const dotIdx = name.indexOf(".");
	const base = dotIdx >= 0
		? mangle(name.slice(0, dotIdx)) + "__" + safeName(name.slice(dotIdx + 1, name.length))
		: mangle(name);
	if (sym.modulePath != "") return `${base}__${mangleModuleName(sym.modulePath)}`;
	return base;
}

// ===== Symbol-aware C name: shared early-exit =====
// Every Symbol-aware wrapper (function, global, future type) first checks
// whether the symbol bypasses mangling: extern symbols (sym.nativeName set
// from `from "c_name"` clause) and ImportC symbols (runtime/C FFI) use their
// raw C name directly. Returns "" to signal the caller should fall through
// to its own rule (proc vs global vs type).
function symExternOrImportName(sym: Readonly<Symbol> | null, name: string): string {
	if (sym != null && sym.nativeName != "") return sym.nativeName;
	if (sym != null && hasFlag(sym, SymbolFlag.ImportC)) return safeName(name);
	return "";
}

// ===== Symbol → C Name (Standard reference parity) =====
// Single source of truth for function C names. Reads sym.modulePath.
// extern functions use nativeName. Others get module-qualified.

// A reference to a module-level symbol is named after its declaration: the text at the use site may be
// an import alias.
export function referenceName(sym: Readonly<Symbol | null>, text: string): string {
	return sym != null && sym.modulePath != "" ? sym.name : text;
}

export function mangledFunctionName(sym: Readonly<Symbol | null>, name: string, overloadIdx: number): string {
	if (sym != null && sym.exportName != "") return sym.exportName;
	const early = symExternOrImportName(sym, name);
	if (early != "") return early;
	const baseName = name;
	if (sym != null && sym.modulePath != "") {
		// The _u suffix is the symbol's per-(module, name) ordinal minted at
		// declaration — NOT the overload-set slot. A routine that never joins
		// an overload set (static member, routine nested in a body) still
		// needs one, and an importer must emit the defining module's number,
		// which only a carried field (not a recomputed position) gives.
		return mangleProcName(baseName, mangleModuleName(sym.modulePath), sym.disamb);
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

export function overloadAt(sym: Symbol, idx: number): Symbol;
export function overloadAt(sym: Readonly<Symbol>, idx: number): Readonly<Symbol>;
export function overloadAt(sym: Readonly<Symbol>, idx: number): Readonly<Symbol> {
	return idx > 0 && idx - 1 < sym.overloads.length ? sym.overloads[idx - 1] : sym;
}

export function resolveOverloadWinner(sym: Readonly<Symbol>, rawIdx: number): number {
	if (!hasFlag(overloadAt(sym, rawIdx), SymbolFlag.OverloadSig)) return rawIdx < 0 ? 0 : rawIdx;
	if (!hasFlag(sym, SymbolFlag.OverloadSig)) return 0;
	for (let oi = 0; oi < sym.overloads.length; oi += 1) {
		const cand = sym.overloads[oi];
		if (cand != null && !hasFlag(cand, SymbolFlag.OverloadSig)) return oi + 1;
	}
	return rawIdx < 0 ? 0 : rawIdx;
}

// ===== Symbol-aware classification — is this a module-level global variable? =====
// Single source of truth for the condition that differentiates module-level `const`/`let`
// from locals and other SymbolKind.Variable cases. Used by multiple codegen emission sites
// (global decl, cross-module extern, identifier reference) — extracting prevents drift if
// the definition changes (e.g. future static class fields).
//
// Criteria: Symbol is a Variable (or a lowering's Temp), has Global flag (set by
// collectPass on module-level declarations, and by the JS pipeline on bindings the
// lowerings declare at module scope), and has a known defining module.

export function isModuleGlobalVar(sym: Readonly<Symbol | null>): boolean {
	if (sym == null) return false;
	if (sym.symbolKind != SymbolKind.Variable && sym.symbolKind != SymbolKind.Temp) return false;
	// Flag set in two places: (1) collectPass for own-module top-level VariableDecl,
	// (2) importSymFromRegistry for imported Variable syms (exports can only be
	// module-level). Distinguishes module-level globals from locals — both have
	// modulePath set (defineOrError stamps it), only globals carry this flag.
	if (!hasFlag(sym, SymbolFlag.Global)) return false;
	if (sym.modulePath == null || sym.modulePath == "") return false;
	return true;
}

// ===== Symbol → C Name for module-level globals =====
// Mirrors mangledFunctionName for `const`/`let` at module scope. Fixes latent
// cross-module C linker collision when two modules declare same-named constants
// (e.g. `MAX_TIME` in cursors.ms and varpartitions.ms). Same extern/ImportC
// early-exit as functions; same module-qualifier pattern minus the overload ID
// (module globals have no overloads).

export function mangledGlobalName(sym: Readonly<Symbol | null>, name: string): string {
	const early = symExternOrImportName(sym, name);
	if (early != "") return early;
	const baseName = name;
	// A `static` decl inside a body shares the module namespace with every other
	// body in the module, so the module qualifier alone does not separate two
	// sites spelling the same name. Both the declaration and every read recompute
	// the name through here, so the site suffix must live here to stay one source.
	const site = (sym != null && hasFlag(sym, SymbolFlag.StaticLocal))
		? `__static${sym.location.line.toString()}_${sym.location.column.toString()}`
		: "";
	if (sym != null && sym.modulePath != "") {
		const ordinal = sym.disamb > 0 ? `_u${sym.disamb}` : "";
		return mangleQualified(baseName, mangleModuleName(sym.modulePath)) + ordinal + site;
	}
	return safeName(baseName) + site;
}

// ===== Field Name — minimal mangling (no module prefix) =====

export function mangleFieldName(name: string): string {
	const mangled = mangleProperty(name);
	if (isCKeyword(mangled) || isCMacroName(mangled)) return mangled + "_0";
	if (spellsAnEscapedKeyword(mangled)) return escapedPropertyName(name);
	return mangled;
}

function spellsAnEscapedKeyword(mangled: string): boolean {
	if (!mangled.endsWith("_0")) return false;
	const stem = mangled.slice(0, mangled.length - 2);
	return isCKeyword(stem) || isCMacroName(stem);
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
		_ => false,
	};
}

function isCMacroName(name: string): boolean {
	return match (name) {
		"stdin" | "stdout" | "stderr" | "errno" | "EOF" => true,
		"NAN" | "INFINITY" | "assert" | "offsetof" => true,
		_ => false,
	};
}

// ===== Safe Identifier — keyword + stdlib avoidance, no module prefix =====

export function safeName(name: string): string {
	const mangled = mangle(name);
	if (isCKeyword(mangled) || isCStdlibName(mangled) || isCMacroName(mangled)) return mangled + "_";
	return mangled;
}

// ===== Tests =====
test "simple names pass through" {
	assert mangle("foo") == "foo";
	assert mangle("bar123") == "bar123";
	assert mangle("_private") == "_private";
}

test "leading digit" { assert mangle("3d") == "X3d"; }

test "a name of letters, digits and underscores keeps its spelling unless a digit leads" {
	assert mangle("_x9_") == "_x9_";
	assert mangle("A1_b") == "A1_b";
	assert mangle("9a_") == "X9a_";
	assert mangle("9a+") == "X9aplus_";
}

test "special chars get word replacements" {
	assert mangle("a+b") == "aplusb_";
	assert mangle("x=y") == "xeqy_";
	assert mangle("<") == "lt_";
	assert mangle("a.b") == "adotb_";
}

test "empty name" { assert mangle("") == "empty_"; }

test "multiple special chars" { assert mangle("a+b*c") == "aplusbstarc_"; }

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

test "mangleQualified basic" { assert mangleQualified("foo", "mymod") == "foo__mymod"; }

test "mangleQualified with special char" { assert mangleQualified("a+b", "mymod") == "aplusb___mymod"; }

test "mangleProcName" { assert mangleProcName("myFunc", "mymod", 42) == "myFunc__mymod_u42"; }

test "mangleProcName with special" { assert mangleProcName("a+b", "ops", 1) == "aplusb___ops_u1"; }

test "mangledGlobalName no sym falls through to safeName" {
	assert mangledGlobalName(null, "FOO") == "FOO";
}

test "mangledGlobalName no modulePath falls through to safeName" {
	const sym = makeSymbol("FOO", SymbolKind.Variable, noneType(), false);
	assert mangledGlobalName(sym, "FOO") == "FOO";
}

test "mangledGlobalName extern nativeName bypass" {
	const sym = makeSymbol("x", SymbolKind.Variable, noneType(), false);
	sym.nativeName = "my_c_sym";
	sym.modulePath = "src/foo.ms";
	assert mangledGlobalName(sym, "FOO") == "my_c_sym";
}

test "mangledGlobalName module-qualified" {
	const sym = makeSymbol("MAX", SymbolKind.Variable, noneType(), false);
	sym.modulePath = "src/foo.ms";
	assert mangledGlobalName(sym, "MAX") == "MAX__srcZfooOms";
}

test "a reference through an import alias names the global after its declaration" {
	const sym = makeSymbol("ORIG", SymbolKind.Variable, noneType(), false);
	sym.modulePath = "src/foo.ms";
	assert mangledGlobalName(sym, referenceName(sym, "aliased")) == "ORIG__srcZfooOms";
}

test "mangledFunctionName main stays safe" {
	assert mangledFunctionName(null, "main", 0) == "main_";
}

test "mangledFunctionName qualifies main by its module" {
	const sym = makeSymbol("main", SymbolKind.Function, noneType(), false);
	sym.modulePath = "src/app.ms";
	assert mangledFunctionName(sym, "main", 0) != "main_";
	assert mangledFunctionName(sym, "main", 0).startsWith("main__");
}

test "mangledFunctionName plain name no sym" {
	assert mangledFunctionName(null, "foo", 0) == "foo";
}

test "mangledFunctionName module-qualified" {
	const sym = makeSymbol("bar", SymbolKind.Function, noneType(), false);
	sym.modulePath = "src/foo.ms";
	assert mangledFunctionName(sym, "bar", 0) == "bar__srcZfooOms_u0";
}

test "mangledFunctionName nativeName bypass (extern)" {
	const sym = makeSymbol("printf", SymbolKind.Function, noneType(), false);
	sym.nativeName = "printf";
	sym.modulePath = "std/io.ms";
	assert mangledFunctionName(sym, "printf", 0) == "printf";
}

test "mangledFunctionName ImportC bypass" {
	const sym = makeSymbol("malloc", SymbolKind.Function, noneType(), false);
	sym.modulePath = "std/core.ms";
	setFlag(sym, SymbolFlag.ImportC);
	// malloc is in isCStdlibName → safeName adds trailing underscore
	assert mangledFunctionName(sym, "malloc", 0) == "malloc_";
}

test "mangledFunctionName disamb disambiguates" {
	const sym = makeSymbol("foo", SymbolKind.Function, noneType(), false);
	sym.modulePath = "src/bar.ms";
	sym.disamb = 2;
	assert mangledFunctionName(sym, "foo", 0) == "foo__srcZbarOms_u2";
}

test "a reference through an import alias names the function after its declaration" {
	const sym = makeSymbol("realFn", SymbolKind.Function, noneType(), false);
	sym.modulePath = "src/bar.ms";
	assert mangledFunctionName(sym, referenceName(sym, "aliasedFn"), 0) == "realFn__srcZbarOms_u0";
}

test "mangledFunctionName no modulePath with overloadIdx" {
	assert mangledFunctionName(null, "foo", 3) == "foo__3";
}

test "normal field" {
	assert mangleFieldName("x") == "x";
	assert mangleFieldName("myField") == "myField";
}

test "a field named after a standard-header macro is escaped" {
	assert mangleFieldName("errno") == "errno_0";
	assert mangleFieldName("stdout") == "stdout_0";
	assert mangleFieldName("NAN") == "NAN_0";
}

test "a stdlib function name is a valid field name" {
	assert mangleFieldName("time") == "time";
	assert mangleFieldName("read") == "read";
}

test "keyword field" {
	assert mangleFieldName("int") == "int_0";
	assert mangleFieldName("return") == "return_0";
}

test "a property name mangle spells unambiguously keeps that spelling" {
	assert mangleProperty("plain") == "plain";
	assert mangleProperty("_private") == "_private";
	assert mangleProperty("aminusb_") == "aminusb_";
	assert mangleProperty("X1") == "X1";
	assert mangleProperty("$x") == "dollarx_";
	assert mangleProperty("$state1") == "dollarstate1_";
	assert mangleFieldName("$up") == "dollarup_";
}

test "any other property name is spelled byte by byte behind X_" {
	assert mangleProperty("data-probe") == "X_dataX2Dprobe";
	assert mangleProperty("é") == "X_XC3XA9";
	assert mangleProperty("Xa-") == "X_X58aX2D";
	assert mangleProperty("42") == "X_42";
	assert mangleProperty("") == "X_";
}

function distinctSpellings(names: string[], spell: (name: string) => string): boolean {
	for (let i = 0; i < names.length; i += 1) {
		for (let j = i + 1; j < names.length; j += 1) {
			if (spell(names[i]) == spell(names[j])) return false;
		}
	}
	return true;
}

test "a separated property name never holds the separator" {
	assert mangleSeparatedProperty("s__y") == "X_sX5FX5Fy";
	assert mangleSeparatedProperty("$__x") == "X_X24X5FX5Fx";
	assert mangleSeparatedProperty("_q") == "_q";
	assert mangleSeparatedProperty("a_") == "a_";
	assert mangleSeparatedProperty("data-probe") == "X_dataX2Dprobe";
}

test "property names mangle merges get distinct spellings" {
	assert distinctSpellings(["é", "è", "a-b", "aminusb_", "a+b", "aplusb_", "$x", "dollarx_", "$$", "$dollar", "42", "X42", "X_42", "", "empty_", "a b", "aspaceb_"], mangleProperty);
	assert distinctSpellings(["int", "int_0", "errno", "errno_0", "X_int", "int_"], mangleFieldName);
}

test "normal name" { assert safeName("foo") == "foo"; }

test "keyword gets suffix" {
	assert safeName("int") == "int_";
	assert safeName("void") == "void_";
}

test "simple lowercase path" { assert mangleModuleName("mymod") == "mymod"; }

test "path separators become Z" { assert mangleModuleName("src/codegen/c") == "srcZcodegenZc"; }

test "dots become O" { assert mangleModuleName("foo.bar") == "fooObar"; }

test "uppercase becomes ordinal" {
	assert mangleModuleName("MyClass") == "M77y67lass";
	assert mangleModuleName("AB") == "M6566";
}

test "windows drive letter does not produce digit-leading identifier" {
	// `C:` → `67` + wildcard — without guard this yields `6763Z…`, invalid as C ident.
	const out = mangleModuleName("C:/Users/foo/mod.cms");
	assert out.charAt(0) == "M";
}

test "underscore becomes ordinal" { assert mangleModuleName("my_mod") == "my95mod"; }

test "full path with mixed case" { assert mangleModuleName("src/codegen/MyGen") == "srcZcodegenZ77y71en"; }

test "a module name is spelled from its root, so a std module and a same-named project module stay apart" {
	const roots: ModuleNameRoots = { compiler: "/msc", packages: "/pkgs", project: "/proj" };
	assert mangleRootedModuleName("/msc/std/a.ms", roots) == "SstdZaOms";
	assert mangleRootedModuleName("/proj/std/a.ms", roots) == "stdZaOms";
	assert mangleRootedModuleName("/pkgs/p/a.ms", roots) == "PpZaOms";
	assert mangleRootedModuleName("/proj/sub/a.ms", roots) == "subZaOms";
	assert mangleRootedModuleName("/other/a.ms", roots) == "OOZotherZaOms";
	assert mangleRootedModuleName("/proj/std/a.ms", { compiler: "", packages: "", project: "" }) == "ZprojZstdZaOms";
}
