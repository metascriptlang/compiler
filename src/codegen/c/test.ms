// C Codegen — Test Infrastructure
//
// Handles test-build-only emission:
//   - genTestDeclNode: TestDecl → static wrapper function + register entry
//   - emitTestHeader: #include "std/core/system/test.h"
//   - emitTestTable: MsTestEntry[] (non-static, referenced by dispatcher)
//   - genTestDispatcher: replaces genProjectDispatcher for test builds
//
// Only active when isTestBuild=true. Production builds strip TestDecl entirely.
// Runtime: runtime/test.h (header-only, not linked into production binaries).

import {
	Node, NodeKind,
	TestDeclData, BlockStmtData,
} from "../../ast/node";
import { Type } from "../../checker/types";
import {
	CGen, CProc, CSection, TestEntry,
	createProc, createBuilder, add, addLine, addNewline,
	sec, extract,
	readProcStmts, readProcLocals,
} from "./context";
import { genStmt } from "./statements";
import { mangleModuleName } from "./names";
import { escapeCString } from "./literals";

// ===== Test Declaration → Wrapper Function =====
// Emits: static void __ms_test_N(void) { body }
// Registers entry in g.testEntries for later table emission.

export function genTestDeclNode(g: CGen, node: Node): void {
	if (!g.isTestBuild) return;
	const d = node.data as TestDeclData;
	if (d.testBody === null) return;

	const funcName = `__ms_test_${g.nextTestId.toString()}`;
	g.nextTestId = g.nextTestId + 1;

	const procs = sec(g, CSection.Procs);
	addLine(procs, `static void ${funcName}(void) {`);

	if (d.testBody.kind === NodeKind.BlockStmt) {
		const bd = d.testBody.data as BlockStmtData;
		const p = createProc(funcName, null);
		g.currentProc = p;
		for (const stmt of bd.statements) {
			genStmt(g, p, stmt);
		}
		const locals = readProcLocals(p);
		if (locals.length > 0) add(procs, locals);
		const stmts = readProcStmts(p);
		if (stmts.length > 0) add(procs, stmts);
		g.currentProc = null as unknown as CProc;
	}

	addLine(procs, "}");
	addNewline(procs);

	g.testEntries.push({ name: d.testName, funcName });
}

// ===== Test Header Emission =====

export function emitTestHeader(g: CGen): void {
	if (!g.isTestBuild) return;
	addLine(sec(g, CSection.Headers), "#include \"std/core/system/test.h\"");
}

// ===== Test Table =====
// Every module in a test build emits:
//   MsTestEntry __ms_tests_<mod>[] = { ... {NULL,NULL,NULL} };
//
// Non-static so the dispatcher can reference it in the MsTestModule array.
// Modules with 0 tests emit an empty table (just the sentinel).

export function emitTestTable(g: CGen): void {
	if (!g.isTestBuild) return;

	const procs = sec(g, CSection.Procs);
	const modName = mangleModuleName(g.modulePath);
	const tableName = `__ms_tests_${modName}`;

	// Test entry table (non-static, referenced by dispatcher)
	const hdrs = sec(g, CSection.ProcHeaders);
	addLine(hdrs, `MsTestEntry ${tableName}[];`);
	addLine(procs, `MsTestEntry ${tableName}[] = {`);
	for (const entry of g.testEntries) {
		const escaped = escapeCString(entry.name);
		addLine(procs, `  {"${escaped}", NULL, ${entry.funcName}},`);
	}
	addLine(procs, "  {NULL, NULL, NULL}");
	addLine(procs, "};");
	addNewline(procs);
}

// ===== Test Dispatcher =====
// Replaces genProjectDispatcher for test builds.
// Runs all module DatInit + Init, then calls each module's test runner.

export function genTestDispatcher(modulePaths: string[], entryPath: string): string {
	const b = createBuilder();

	addLine(b, "#include \"std/core/system/test.h\"");
	addNewline(b);

	// Forward declarations: init functions + test entry tables
	for (const mp of modulePaths) {
		const modName = mangleModuleName(mp);
		addLine(b, `void ${modName}__DatInit000(void);`);
		addLine(b, `void ${modName}__Init000(void);`);
		addLine(b, `extern MsTestEntry __ms_tests_${modName}[];`);
	}
	addNewline(b);

	// Global test failure flag
	addLine(b, "int __ms_test_failed = 0;");
	// Cross-TU shared state (extern in test.h, defined here)
	addLine(b, "const char* __ms_last_assert_msg = NULL;");
	addLine(b, "const char* __ms_last_assert_file = NULL;");
	addLine(b, "int __ms_last_assert_line = 0;");
	addLine(b, "char __ms_pa_buffer[MS_PA_DIAG_SIZE];");
	addLine(b, "int __ms_pa_pending = 0;");
	addNewline(b);

	// Globals needed by module init code
	addLine(b, "int cmdCount;");
	addLine(b, "char** cmdLine;");
	addLine(b, "char** gEnv;");
	addLine(b, "int msProgramResult;");
	addNewline(b);

	addLine(b, "int main(int argc, char** argv, char** env) {");
	addLine(b, "  cmdLine = argv;");
	addLine(b, "  cmdCount = argc;");
	addLine(b, "  gEnv = env;");
	addNewline(b);

	// Init all modules
	for (const mp of modulePaths) {
		addLine(b, `  ${mangleModuleName(mp)}__DatInit000();`);
	}
	for (const mp of modulePaths) {
		addLine(b, `  ${mangleModuleName(mp)}__Init000();`);
	}
	addNewline(b);

	// Build module descriptor table and call runtime
	addLine(b, "  MsTestModule __ms_modules[] = {");
	for (const mp of modulePaths) {
		const modName = mangleModuleName(mp);
		const escaped = escapeCString(mp);
		addLine(b, `    {"${escaped}", __ms_tests_${modName}},`);
	}
	addLine(b, "    {NULL, NULL}");
	addLine(b, "  };");
	addLine(b, "  return ms_test_main(__ms_modules, argc, argv);");
	addLine(b, "}");

	return extract(b);
}

// escapeCString imported from literals.ms
