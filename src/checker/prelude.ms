// Global Imports — auto-imported system modules available in every user module.
//
// User code runs in a child Module scope, so prelude names can be shadowed.
// See docs/LANG-PRELUDE.md for full design.
//
// checkProgram() reads globalImports from disk, parses + checks in Global scope.
// Later: concat with globalImports from build.ms (user-configurable).



// Default global imports. Returns array (module-level const string[] hits DRC bug).
export function defaultGlobalImports(): string[] {
	return ["std/core/system", "std/core/array", "std/core/string", "std/core/json", "std/core/buffer", "std/core/promise", "std/core/struct", "std/core/fetch", "std/core/date", "std/core/performance", "std/core/websocket"];
}

let _extraGlobalImports: string[] = [];

export function setExtraGlobalImports(paths: string[]): void {
	_extraGlobalImports = paths;
}

export function globalImports(): string[] {
	const result = defaultGlobalImports();
	for (const p of _extraGlobalImports) result.push(p);
	return result;
}

export function isGlobalImport(path: string): boolean {
	for (const entry of globalImports()) {
		if (path === entry) return true;
	}
	return false;
}

// ===== Tests =====
test "setExtraGlobalImports appends build.ms entries after the defaults" {
	const base = defaultGlobalImports().length;
	setExtraGlobalImports(["/abs/neon/src/converters"]);
	const imports = globalImports();
	assert imports.length === base + 1;
	assert imports[0] === "std/core/system";
	assert imports[base] === "/abs/neon/src/converters";
	assert isGlobalImport("/abs/neon/src/converters");
	setExtraGlobalImports([]);
	assert globalImports().length === base;
	assert !isGlobalImport("/abs/neon/src/converters");
}

test "setExtraGlobalImports replaces previous extras" {
	setExtraGlobalImports(["/a"]);
	setExtraGlobalImports(["/b"]);
	const imports = globalImports();
	assert imports.length === defaultGlobalImports().length + 1;
	assert imports[imports.length - 1] === "/b";
	setExtraGlobalImports([]);
}

test "isGlobalImport sees extras" {
	setExtraGlobalImports(["/abs/neon/converters"]);
	assert isGlobalImport("/abs/neon/converters");
	setExtraGlobalImports([]);
	assert !isGlobalImport("/abs/neon/converters");
}

test "globalImports has system, string, array, json, buffer, promise, struct, fetch, date, performance, websocket" {
	const imports = defaultGlobalImports();
	assert imports.length === 11;
	assert imports[0] === "std/core/system";
	assert imports[1] === "std/core/array";
	assert imports[2] === "std/core/string";
	assert imports[3] === "std/core/json";
	assert imports[4] === "std/core/buffer";
	assert imports[5] === "std/core/promise";
	assert imports[6] === "std/core/struct";
	assert imports[7] === "std/core/fetch";
	assert imports[8] === "std/core/date";
	assert imports[9] === "std/core/performance";
	assert imports[10] === "std/core/websocket";
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
