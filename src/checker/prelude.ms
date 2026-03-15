// Global Imports — auto-imported system modules available in every user module.
//
// User code runs in a child Module scope, so prelude names can be shadowed.
// See docs/LANG-PRELUDE.md for full design.
//
// checkProgram() reads globalImports from disk, parses + checks in Global scope.
// Later: concat with globalImports from build.ms (user-configurable).



// Default global imports. Returns array (module-level const string[] hits DRC bug).
// Later: merge with build.ms globalImports.
export function globalImports(): string[] {
	return ["std/core/system", "std/core/string", "std/core/array", "std/core/map", "std/core/json", "std/core/buffer", "std/core/promise"];
}

export function isGlobalImport(path: string): boolean {
	for (const entry of globalImports()) {
		if (path === entry) return true;
	}
	return false;
}

// ===== Tests =====
test "globalImports has system, string, array, map, json, buffer, promise" {
	const imports = globalImports();
	assert imports.length === 7;
	assert imports[0] === "std/core/system";
	assert imports[1] === "std/core/string";
	assert imports[2] === "std/core/array";
	assert imports[3] === "std/core/map";
	assert imports[4] === "std/core/json";
	assert imports[5] === "std/core/buffer";
	assert imports[6] === "std/core/promise";
}

test "isGlobalImport matches" {
	assert isGlobalImport("std/core/system");
	assert isGlobalImport("std/core/string");
	assert isGlobalImport("std/core/array");
	assert isGlobalImport("std/core/map");
}

test "isGlobalImport rejects non-global" {
	assert !isGlobalImport("std/testing");
	assert !isGlobalImport("./foo");
}
