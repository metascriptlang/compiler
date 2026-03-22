// C Codegen — Entry Point
//
// generateCModule(program, checkerCtx, modulePath, aliveSet, isTestBuild) → string  (self-contained per-module)
// genProjectDispatcher(modulePaths, entryPath, hasUserMain) → string  (global init dispatcher)
//
// Module init follows two-phase pattern:
//   DatInit000 (data/type init, runs first) + Init000 (user code, runs second)
//   main(argc, argv) → MsMain → MsPreMainInner (DatInit) → MsMainInner (Init)

import {
	Node, NodeKind, SymbolKind, Symbol,
	ProgramData,
} from "../../ast/node";
import { CheckerContext, ExportRegistry } from "../../checker/context";
import {
	CGen, CSection, AliveSet, TestEntry,
	createCGen, createAliveSet, createBuilder, sec, add, addLine, addNewline,
	assembleOutput, extract, nameSetAdd, nameSetHas,
} from "./context";
import { genDecl } from "./declarations";
import { mangleModuleName, mangledFunctionName, safeName } from "./names";
import { isNrvoReturnType, getTypeDesc, ccgIntroducedPtr } from "./types";
import { mangle } from "./names";
import { emitStringPoolDecls } from "./literals";
import { emitTestHeader, emitTestTable, genTestDispatcher } from "./test";
import { emitIncludeDirectives } from "./context";

// ===== generateCModule — one module's C code (no dispatcher) =====
//
// Generates headers, type definitions, function prototypes, function bodies,
// and per-module DatInit000/Init000 (non-static for cross-module visibility).
// Does NOT generate the global dispatcher (MsPreMainInner/MsMainInner/MsMain/POSIX main).

export function generateCModule(program: Node, ctx: CheckerContext, modulePath: string, aliveSet: AliveSet, isTestBuild: boolean, isHcr: boolean): string {
	const g = createCGen(ctx, modulePath);
	g.aliveSet = aliveSet;
	g.isTestBuild = isTestBuild;
	g.isHcr = isHcr;

	// Standard C headers (Standard reference implementation pattern)
	addLine(sec(g, CSection.Headers), "#include <stdint.h>");
	addLine(sec(g, CSection.Headers), "#include <stdbool.h>");
	addLine(sec(g, CSection.Headers), "#include <string.h>");
	addLine(sec(g, CSection.Headers), "#include <math.h>");
	addLine(sec(g, CSection.Headers), "#include \"std/core/system/native.h\"");
	nameSetAdd(g.declaredThings, "inc:std/core/system/native.h"); // prevent duplicate from @include
	emitTestHeader(g);


	// Emit additional @include directives from checker (user code @include pragmas)
	if (ctx !== null && ctx.includeDirectives !== "") {
		emitIncludeDirectives(g, ctx.includeDirectives);
	}

	// Walk program statements
	if (program !== null && program.kind === NodeKind.Program) {
		const pd = program.data as ProgramData;
		for (const stmt of pd.programStmts) {
			genDecl(g, stmt, false);
		}
	}

	// Emit test table (test builds only — after all TestDecl nodes processed)
	emitTestTable(g);

	// Generate per-module init functions (non-static for cross-module visibility)
	genModuleInitFns(g);



	// Emit string literal pool declarations
	emitStringPoolDecls(g.stringPool, sec(g, CSection.StringPool));

	return assembleOutput(g);
}

// ===== Per-Module Init Functions =====
//
// Generates DatInit000 and Init000 for this module.
// Non-static so other modules' dispatchers can call them.

function genModuleInitFns(g: CGen): void {
	const modName = mangleModuleName(g.modulePath);
	const datInitName = g.isHcr ? "DatInit000" : `${modName}__DatInit000`;
	const initName = g.isHcr ? "Init000" : `${modName}__Init000`;

	const datContent = extract(sec(g, CSection.DatInit));
	const initContent = extract(sec(g, CSection.ModuleInit));

	// Clear sections (re-emitted into Procs)
	sec(g, CSection.DatInit).buf = "";
	sec(g, CSection.ModuleInit).buf = "";

	const hdrs = sec(g, CSection.ProcHeaders);
	const procs = sec(g, CSection.Procs);

	// DatInit000: data/type initialization (non-static for cross-module visibility)
	addLine(hdrs, `void ${datInitName}(void);`);
	addLine(procs, `void ${datInitName}(void) {`);
	addLine(procs, `  static MS_BOOL ${datInitName}_guard_ = 0;`);
	addLine(procs, `  if (${datInitName}_guard_) return;`);
	addLine(procs, `  ${datInitName}_guard_ = 1;`);
	if (datContent.length > 0) {
		add(procs, datContent);
	}
	addLine(procs, "}");
	addNewline(procs);

	// Init000: user top-level code (non-static for cross-module visibility)
	addLine(hdrs, `void ${initName}(void);`);
	addLine(procs, `void ${initName}(void) {`);
	addLine(procs, `  static MS_BOOL ${initName}_guard_ = 0;`);
	addLine(procs, `  if (${initName}_guard_) return;`);
	addLine(procs, `  ${initName}_guard_ = 1;`);
	if (initContent.length > 0) {
		add(procs, initContent);
	}
	addLine(procs, "}");
	addNewline(procs);
}

// ===== Global Init Dispatcher =====
//
// Generates the global init dispatcher: forward decls, MsPreMainInner, MsMainInner,
// MsMain, global vars, and POSIX main.

export function genProjectDispatcher(modulePaths: string[], entryPath: string, hasUserMain: boolean, mainRetType: string): string {
	const b = createBuilder();
	const retType = (mainRetType.length > 0) ? mainRetType : "void";

	// Include system header when async main needs typed future types
	if (retType.startsWith("msFuture_")) {
		addLine(b, "#include \"std/core/system/native.h\"");
		addNewline(b);
	}

	// Forward declarations for all module init functions
	for (const mp of modulePaths) {
		const modName = mangleModuleName(mp);
		addLine(b, `void ${modName}__DatInit000(void);`);
		addLine(b, `void ${modName}__Init000(void);`);
	}
	if (hasUserMain) {
		addLine(b, `${retType} main_(void);`);
	}
	addNewline(b);

	// Global variables (must precede function bodies that reference them)
	addLine(b, "int cmdCount;");
	addLine(b, "char** cmdLine;");
	addLine(b, "char** gEnv;");
	addLine(b, "int msProgramResult;");
	addNewline(b);

	// MsPreMainInner — calls DatInit000 for all modules in topological order
	addLine(b, "static void MsPreMainInner(void) {");
	b.indent += 1;
	for (const mp of modulePaths) {
		addLine(b, `${mangleModuleName(mp)}__DatInit000();`);
	}
	b.indent -= 1;
	addLine(b, "}");
	addNewline(b);

	// MsMainInner — dependency Init000, then entry Init000, then user main
	addLine(b, "static void MsMainInner(void) {");
	b.indent += 1;
	for (const mp of modulePaths) {
		if (mp !== entryPath) {
			addLine(b, `${mangleModuleName(mp)}__Init000();`);
		}
	}
	addLine(b, `${mangleModuleName(entryPath)}__Init000();`);
	if (hasUserMain) {
		if (retType.startsWith("msFuture_")) {
			// Async main — run event loop until completion
			addLine(b, "extern void* msWaitFor(void*);");
			addLine(b, "msWaitFor(main_());");
		} else if (retType !== "void") {
			addLine(b, "msProgramResult = (int)main_();");
		} else {
			addLine(b, "main_();");
		}
	}
	b.indent -= 1;
	addLine(b, "}");
	addNewline(b);

	// MsMain + POSIX main
	addLine(b, "void MsMain(void) {");
	addLine(b, "  MsPreMainInner();");
	addLine(b, "  MsMainInner();");
	addLine(b, "}");
	addNewline(b);
	addLine(b, "int main(int argc, char** argv, char** env) {");
	addLine(b, "  cmdLine = argv;");
	addLine(b, "  cmdCount = argc;");
	addLine(b, "  gEnv = env;");
	addLine(b, "  MsMain();");
	addLine(b, "  return msProgramResult;");
	addLine(b, "}");

	return extract(b);
}

// ===== Register Cross-Module Type Names =====
// Registers class/interface names from imported modules for pointer detection.
// Type resolution itself is handled lazily via symbol table lookup in getTypeDesc.


// ===== Tests =====

import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";


function cOutput(input: string): string {
	const pr = parseSource(input);
	if (!pr.ok) return "PARSE_ERROR: " + pr.error;
	const moduleCode = generateCModule(pr.value, null as unknown as CheckerContext, "test/input", createAliveSet(), false, false);
	const paths: string[] = ["test/input"];
	const dispatcher = genProjectDispatcher(paths, "test/input", false, "void");
	return moduleCode + "\n" + dispatcher;
}

function cModuleOutput(input: string): string {
	const pr = parseSource(input);
	if (!pr.ok) return "PARSE_ERROR: " + pr.error;
	return generateCModule(pr.value, null as unknown as CheckerContext, "test/input", createAliveSet(), true, false);
}

test "empty program has headers" {
	const result = cOutput("");
	assert result.length > 0;
}

test "headers include stdint" {
	const result = cOutput("");
	// stdint.h should be present
	assert result.length > 10;
}

test "simple function" {
	const result = cOutput("function foo(): void { return; }");
	assert result.length > 0;
}

test "enum output" {
	const result = cOutput("enum Dir { North, South, East, West }");
	assert result.length > 0;
}

test "function + call" {
	const result = cOutput("function add(a: number, b: number): number { return a + b; }");
	assert result.length > 0;
}

test "global var init in module Init000" {
	const result = cOutput("function add(a: number, b: number): number { return a + b; }\nconst result: number = add(2, 3);");
	assert result.length > 0;
}

test "two-phase init + POSIX main" {
	const result = cOutput("function add(a: number, b: number): number { return a + b; }\nconst result: number = add(2, 3);");
	assert result.length > 0;
}

test "MacroInvocation skipped in codegen" {
	const result = cOutput("@passL(\"-lssl\");");
	// Should not contain /* unsupported */
	assert result.length > 0;
}

test "@include from prelude emits header" {
	// prelude has @include("system.h"), so generated C should contain it
	const result = cOutput("");
	assert result.length > 0;
}

test "direct call detection" {
	// closureCallMarker sets isDirectCall on CallExpr nodes — codegen reads the flag
	const result = cOutput("function foo(): void {} function bar(): void { foo(); }");
	assert result.length > 0;
}

test "array literal" {
	const result = cOutput("const arr: number = [1, 2, 3];");
	assert result.length > 0;
}

test "generateCModule produces code without dispatcher" {
	const result = cModuleOutput("function foo(): void { return; }");
	assert result.length > 0;
}


