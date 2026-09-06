// Conditional-symbol table — port of Nim `condsyms.nim` (defineSymbol / undefSymbol /
// initDefines / definedSymbolNames) plus the tiered lookup of `options.nim:634 isDefined`.
//
// A define is a name → string value; a valueless define stores "true"
// (condsyms.nim:18 uses the same default). Primitive facts (backend, OS, gc, build
// mode, user -d flags) live in the table; derived answers (posix/unix/bsd families)
// are COMPUTED at lookup, never stored — mirroring Nim, where conf.target answers
// for the exact OS/CPU name and the alias set is a `case` in isDefined.
//
// Deliberate deviation from Nim, one axis only: Nim's table is style-INsensitive
// because the Nim language is. MetaScript identifiers are case-sensitive, so define
// names are too — the rule is "defines follow the language's identifier rules",
// which is what Nim is expressing. Haxe's dash rule is adopted verbatim: a `-d:a-b`
// key reaches the source as `a_b`, since `a-b` lexes as subtraction.

export interface DefineTable {
	symbols: HashMap<string, string>;
	names: string[];
}

export function createDefineTable(): DefineTable {
	return { symbols: new HashMap<string, string>(), names: [] };
}

export function normalizeDefineName(name: string): string {
	let out = "";
	for (let i = 0; i < name.length; i += 1) {
		const c = name.charAt(i);
		out = out + (c == "-" ? "_" : c);
	}
	return out;
}

export function defineSymbol(t: DefineTable, name: string, value: string): void {
	const key = normalizeDefineName(name);
	if (key == "") return;
	if (!t.symbols.has(key)) { t.names.push(key); }
	t.symbols.set(key, value);
}

export function undefSymbol(t: DefineTable, name: string): void {
	const key = normalizeDefineName(name);
	if (!t.symbols.has(key)) return;
	t.symbols.delete(key);
	const kept: string[] = [];
	for (const n of t.names) { if (n != key) kept.push(n); }
	t.names = kept;
}

export function hasSymbol(t: DefineTable, name: string): boolean {
	return t.symbols.has(normalizeDefineName(name));
}

// Raw value of a define ("" when absent). The `{.strdefine.}`-style typed read
// (semfold.nim:526 foldDefine) converts at the READ site; the table stays strings.
export function definedValue(t: DefineTable, name: string): string {
	const v = t.symbols.get(normalizeDefineName(name));
	return v != null ? v : "";
}

// Tiered lookup, shape of options.nim:634-684: stored symbols first, then the
// computed OS-family aliases. An unknown symbol is FALSE, never an error
// (options.nim:684) — the open-world price both Nim and Haxe accept, answered by
// `msc --help-defines` rather than by a diagnostic.
export function isDefined(t: DefineTable, name: string): boolean {
	const key = normalizeDefineName(name);
	if (t.symbols.has(key)) return true;
	const os = definedValue(t, "os");
	return match (key) {
		"posix" | "unix" => os == "linux" || os == "macos" || os == "ios"
			|| os == "android" || os == "freebsd",
		"bsd" => os == "freebsd",
		_ => false,
	};
}

// Nim seeds initDefines BEFORE the command line is processed so a -d: switch wins
// (condsyms.nim:34 then commands.nim:703). MetaScript parses argv in one pass, so
// the seeding runs after it and skips any name the user already set — same
// precedence, reached from the other side.
export function initDefines(t: DefineTable, backendName: string, targetOs: string, gcMode: string, mode: number): void {
	const os = targetOs == "darwin" ? "macos" : targetOs;
	const modeName = mode == 2 ? "danger" : (mode == 1 ? "release" : "debug");

	seed(t, "msc", "true");
	seed(t, backendName, "true");
	seed(t, os, "true");
	seed(t, gcMode, "true");
	seed(t, modeName, "true");

	seed(t, "backend", backendName);
	seed(t, "os", os);
	seed(t, "gc", gcMode);
	seed(t, "mode", modeName);
}

function seed(t: DefineTable, name: string, value: string): void {
	if (hasSymbol(t, name)) return;
	defineSymbol(t, name, value);
}

// `-d:name` / `-d:name=value` / `--define:...` — commands.nim:703-711 splits on
// {':', '='} and stores the remainder verbatim; a bare flag defaults to "true".
export function applyDefineSwitch(t: DefineTable, arg: string): void {
	let body = arg;
	if (body.startsWith("--define:")) { body = body.slice(9, body.length); }
	else if (body.startsWith("--define=")) { body = body.slice(9, body.length); }
	else if (body.startsWith("-d:")) { body = body.slice(3, body.length); }
	else if (body.startsWith("-d=")) { body = body.slice(3, body.length); }
	if (body == "") return;
	const eq = body.indexOf("=");
	if (eq >= 0) {
		defineSymbol(t, body.slice(0, eq), body.slice(eq + 1, body.length));
	} else {
		defineSymbol(t, body, "true");
	}
}

// `msc --help-defines`, the listing both Nim (--help-defines) and Haxe
// (--help-defines) ship in place of a typo diagnostic.
export function formatDefines(t: DefineTable): string {
	let out = "";
	for (const n of t.names) {
		const v = definedValue(t, n);
		out = out + "  " + n + (v == "true" ? "" : "=" + v) + "\n";
	}
	return out;
}

test "define: bare flag stores true" {
	const t = createDefineTable();
	defineSymbol(t, "myFlag", "true");
	assert isDefined(t, "myFlag");
	assert definedValue(t, "myFlag") == "true";
}

test "define: unknown flag is false, never an error" {
	const t = createDefineTable();
	assert !isDefined(t, "maccos");
	assert definedValue(t, "maccos") == "";
}

test "define: dash normalizes to underscore (Haxe rule)" {
	const t = createDefineTable();
	applyDefineSwitch(t, "-d:my-flag");
	assert isDefined(t, "my_flag");
	assert isDefined(t, "my-flag");
}

test "define: -d carries a value" {
	const t = createDefineTable();
	applyDefineSwitch(t, "-d:tier=3");
	assert definedValue(t, "tier") == "3";
	assert isDefined(t, "tier");
}

test "define: --define: long form" {
	const t = createDefineTable();
	applyDefineSwitch(t, "--define:featureX=on");
	assert definedValue(t, "featureX") == "on";
}

test "define: undef removes" {
	const t = createDefineTable();
	defineSymbol(t, "gone", "true");
	undefSymbol(t, "gone");
	assert !isDefined(t, "gone");
}

test "initDefines seeds backend, os, gc and mode" {
	const t = createDefineTable();
	initDefines(t, "js", "darwin", "orc", 0);
	assert isDefined(t, "js");
	assert isDefined(t, "macos");
	assert isDefined(t, "orc");
	assert isDefined(t, "debug");
	assert definedValue(t, "backend") == "js";
	assert definedValue(t, "os") == "macos";
	assert definedValue(t, "gc") == "orc";
	assert definedValue(t, "mode") == "debug";
}

test "initDefines never overwrites a user -d" {
	const t = createDefineTable();
	applyDefineSwitch(t, "-d:os=custom");
	initDefines(t, "c", "linux", "drc", 1);
	assert definedValue(t, "os") == "custom";
	assert isDefined(t, "linux");
}

test "isDefined answers computed os families" {
	const t = createDefineTable();
	initDefines(t, "c", "linux", "drc", 0);
	assert isDefined(t, "posix");
	assert isDefined(t, "unix");
	assert !isDefined(t, "bsd");
}

test "isDefined: windows is not posix" {
	const t = createDefineTable();
	initDefines(t, "c", "windows", "drc", 0);
	assert !isDefined(t, "posix");
	assert isDefined(t, "windows");
}

test "formatDefines lists names with values" {
	const t = createDefineTable();
	initDefines(t, "c", "linux", "drc", 2);
	const listing = formatDefines(t);
	assert listing.contains("  c\n");
	assert listing.contains("  backend=c\n");
	assert listing.contains("  danger\n");
}
