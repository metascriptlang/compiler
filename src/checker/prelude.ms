// Global Imports — auto-imported system modules available in every user module.
//
// User code runs in a child Module scope, so prelude names can be shadowed.
// See docs/LANG-PRELUDE.md for full design.
//
// checkProgram() reads globalImports from disk, parses + checks in Global scope.
// Later: concat with globalImports from build.ms (user-configurable).

import { test, check, testGroup } from "std/testing";

// Default global imports. Returns array (module-level const string[] hits DRC bug).
// Later: merge with build.ms globalImports.
export function globalImports(): string[] {
	return ["std/core.ms"];
}

export function isGlobalImport(path: string): boolean {
	for (const entry of globalImports()) {
		if (path === entry) return true;
		if (path + ".ms" === entry) return true;
	}
	return false;
}

// ===== Tests =====

testGroup("Global Imports", () => {
	test("globalImports has std/core.ms", () => {
		const imports = globalImports();
		check(imports.length === 1);
		check(imports[0] === "std/core.ms");
	});

	test("isGlobalImport with extension", () => {
		check(isGlobalImport("std/core.ms"));
	});

	test("isGlobalImport without extension", () => {
		check(isGlobalImport("std/core"));
	});

	test("isGlobalImport rejects non-global", () => {
		check(!isGlobalImport("std/testing"));
		check(!isGlobalImport("./foo"));
	});
});
