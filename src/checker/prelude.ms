// Global Imports — auto-imported system modules available in every user module.
//
// User code runs in a child Module scope, so prelude names can be shadowed.
// See docs/LANG-PRELUDE.md for full design.
//
// checkProgram() reads globalImports from disk, parses + checks in Global scope.
// Later: concat with globalImports from build.ms (user-configurable).

import { Symbol } from "../ast/node";


// Default global imports. Returns array (module-level const string[] hits DRC bug).
export function defaultGlobalImports(): string[] {
	return ["std/core/system", "std/core/array", "std/core/string", "std/core/bigint", "std/core/json", "std/core/buffer", "std/core/promise", "std/core/struct", "std/core/fetch", "std/core/date", "std/core/performance", "std/core/websocket", "std/core/math", "std/core/number", "std/core/boolean", "std/core/object"];
}

let _extraGlobalImports: string[] = [];
let _extraGlobalImportsBuildFile: string = "";

export function setExtraGlobalImports(paths: string[], buildFile: string = ""): void {
	_extraGlobalImports = paths;
	_extraGlobalImportsBuildFile = buildFile;
}

export function extraGlobalImports(): string[] {
	return _extraGlobalImports;
}

export function extraGlobalImportsBuildFile(): string {
	return _extraGlobalImportsBuildFile;
}

export enum ModulePassState { Unbound, Bound, Broken }

export interface ModulePass {
	entry: string;
	macro: string;
	modulePath: string;
	state: ModulePassState;
	sym: Symbol | null;
}

let _modulePasses: ModulePass[] = [];
let _modulePassExempt: HashSet<string> = new HashSet<string>();
let _modulePassStdPath: string = "";

export function setModulePasses(entries: string[], macros: string[]): void {
	_modulePasses = [];
	for (let i = 0; i < entries.length; i += 1) {
		_modulePasses.push({ entry: entries[i], macro: macros[i], modulePath: "", state: ModulePassState.Unbound, sym: null });
	}
	_modulePassExempt = new HashSet<string>();
	_modulePassStdPath = "";
}

export function modulePasses(): ModulePass[] {
	return _modulePasses;
}

export function modulePassIdentity(): string {
	let out = "";
	for (const pass of _modulePasses) out = out + ` modulePass=${pass.entry}#${pass.macro}`;
	return out;
}

export function setModulePassExempt(paths: HashSet<string>, stdPath: string): void {
	_modulePassExempt = paths;
	_modulePassStdPath = stdPath;
}

export function modulePassExempt(path: string): boolean {
	if (_modulePassExempt.has(path)) return true;
	return _modulePassStdPath != "" && path.startsWith(_modulePassStdPath);
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

test "module passes enter the build identity, and none leave it empty" {
	setModulePasses([], []);
	assert modulePassIdentity() == "";
	setModulePasses(["/p/src/refresh"], ["refreshModule"]);
	assert modulePassIdentity() == " modulePass=/p/src/refresh#refreshModule";
	setModulePasses(["/p/src/refresh"], ["other"]);
	assert modulePassIdentity() != " modulePass=/p/src/refresh#refreshModule";
	setModulePasses([], []);
}

test "a module pass skips std and the globalImports closure, and nothing else" {
	setModulePasses(["/p/src/refresh"], ["refreshModule"]);
	const closure = new HashSet<string>();
	closure.add("/p/src/refresh.ms");
	closure.add("/p/src/render.ms");
	setModulePassExempt(closure, "/std/");
	assert modulePassExempt("/p/src/render.ms");
	assert modulePassExempt("/std/core/array.ms");
	assert !modulePassExempt("/p/src/app.ms");
	setModulePasses([], []);
	assert !modulePassExempt("/p/src/render.ms");
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

