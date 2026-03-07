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
	return ["std/core/system", "std/core/string", "std/core/array"];
}

export function isGlobalImport(path: string): boolean {
	for (const entry of globalImports()) {
		if (path === entry) return true;
	}
	return false;
}

// ===== Tests =====
test "globalImports has system, string, array" {
	const imports = globalImports();
	expect(imports.length === 3);
	expect(imports[0] === "std/core/system");
	expect(imports[1] === "std/core/string");
	expect(imports[2] === "std/core/array");
}

test "isGlobalImport matches" {
	expect(isGlobalImport("std/core/system"));
	expect(isGlobalImport("std/core/string"));
	expect(isGlobalImport("std/core/array"));
}

test "isGlobalImport rejects non-global" {
	expect(!isGlobalImport("std/testing"));
	expect(!isGlobalImport("./foo"));
}
