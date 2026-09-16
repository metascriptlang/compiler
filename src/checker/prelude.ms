// Global Imports — auto-imported system modules available in every user module.
//
// User code runs in a child Module scope, so prelude names can be shadowed.
// See docs/LANG-PRELUDE.md for full design.
//
// checkProgram() reads globalImports from disk, parses + checks in Global scope.
// Later: concat with globalImports from build.ms (user-configurable).



// Default global imports. Returns array (module-level const string[] hits DRC bug).
export function defaultGlobalImports(): string[] {
	return ["std/core/system", "std/core/array", "std/core/string", "std/core/bigint", "std/core/json", "std/core/buffer", "std/core/promise", "std/core/struct", "std/core/fetch", "std/core/date", "std/core/performance", "std/core/websocket", "std/core/math", "std/core/number", "std/core/boolean", "std/core/object"];
}

let _extraGlobalImports: string[] = [];
let _extraGlobalImportModules: Map<string, boolean> = new Map<string, boolean>();

export function setExtraGlobalImports(paths: string[]): void {
	_extraGlobalImports = paths;
	_extraGlobalImportModules = new Map<string, boolean>();
}

export function extraGlobalImports(): string[] {
	return _extraGlobalImports;
}

export function isGlobalImport(path: string): boolean {
	for (const entry of defaultGlobalImports()) {
		if (path == entry) return true;
	}
	return false;
}

export function hasExtraGlobalImports(): boolean {
	return _extraGlobalImports.length > 0;
}

export function noteExtraGlobalImportModule(moduleIdentity: string): void {
	_extraGlobalImportModules.set(moduleIdentity, true);
}

export function isExtraGlobalImportModule(moduleIdentity: string): boolean {
	return _extraGlobalImportModules.has(moduleIdentity);
}

// ===== Tests =====
test "setExtraGlobalImports keeps build.ms entries apart from the std defaults" {
	const base = defaultGlobalImports().length;
	setExtraGlobalImports(["/abs/neon/src/converters"]);
	assert hasExtraGlobalImports();
	assert extraGlobalImports().length == 1;
	assert extraGlobalImports()[0] == "/abs/neon/src/converters";
	assert defaultGlobalImports().length == base;
	setExtraGlobalImports([]);
	assert !hasExtraGlobalImports();
}

test "setExtraGlobalImports replaces previous extras" {
	setExtraGlobalImports(["/a"]);
	setExtraGlobalImports(["/b"]);
	assert extraGlobalImports().length == 1;
	assert extraGlobalImports()[0] == "/b";
	setExtraGlobalImports([]);
}

test "isGlobalImport is the std prelude only; an extra takes the ordinary import path" {
	setExtraGlobalImports(["/abs/neon/converters"]);
	assert !isGlobalImport("/abs/neon/converters");
	setExtraGlobalImports([]);
}

test "globalImports has system, string, array, bigint, json, buffer, promise, struct, fetch, date, performance, websocket, math, number, boolean, object" {
	const imports = defaultGlobalImports();
	assert imports.length == 16;
	assert imports[0] == "std/core/system";
	assert imports[1] == "std/core/array";
	assert imports[2] == "std/core/string";
	assert imports[3] == "std/core/bigint";
	assert imports[4] == "std/core/json";
	assert imports[5] == "std/core/buffer";
	assert imports[6] == "std/core/promise";
	assert imports[7] == "std/core/struct";
	assert imports[8] == "std/core/fetch";
	assert imports[9] == "std/core/date";
	assert imports[10] == "std/core/performance";
	assert imports[11] == "std/core/websocket";
	assert imports[12] == "std/core/math";
	assert imports[13] == "std/core/number";
	assert imports[14] == "std/core/boolean";
	assert imports[15] == "std/core/object";
}

test "isGlobalImport matches" {
	assert isGlobalImport("std/core/system");
	assert isGlobalImport("std/core/string");
	assert isGlobalImport("std/core/array");
	assert isGlobalImport("std/core/struct");
}

test "isGlobalImport rejects non-global" {
	assert !isGlobalImport("std/testing");
	assert !isGlobalImport("./foo");
}

test "an extra global import is matched by loader identity, never by spelling" {
	setExtraGlobalImports(["/proj/gi"]);
	assert !isExtraGlobalImportModule("/proj/gi.ms");
	noteExtraGlobalImportModule("/elsewhere/gi.ms");
	assert isExtraGlobalImportModule("/elsewhere/gi.ms");
	assert !isExtraGlobalImportModule("/proj/gi.ms");
	setExtraGlobalImports([]);
	assert !isExtraGlobalImportModule("/elsewhere/gi.ms");
}
