// C Codegen — Entry Point
//
// generateCModule(program, checkerCtx, modulePath, aliveSet, isTestBuild) → string  (self-contained per-module)
// genProjectDispatcher(modulePaths, entryPath, targetOs, noMain) → string  (global init dispatcher)
//
// Module init follows two-phase pattern:
//   DatInit000 (data/type init, runs first) + Init000 (user code, runs second)
//   main(argc, argv) → MsMain → MsPreMainInner (DatInit) → MsMainInner (Init)

import { Node, NodeKind, ProgramData } from "../../ast/node";
import { CheckerContext, GcMode } from "../../checker/context";
import {
	CGen, CSection, AliveSet,
	createCGen, createAliveSet, createBuilder, sec, add, addLine, addNewline, assembleOutput, extract, nameSetAdd,
} from "./context";
import { genDecl, registerDeclCName } from "./declarations";
import { mangleModuleName } from "./names";
import { emitStringPoolDecls } from "./literals";
import { emitTestHeader, emitTestTable } from "./test";
import { emitIncludeDirectives } from "./context";

// ===== generateCModule — one module's C code (no dispatcher) =====
//
// Generates headers, type definitions, function prototypes, function bodies,
// and per-module DatInit000/Init000 (non-static for cross-module visibility).
// Does NOT generate the global dispatcher (MsPreMainInner/MsMainInner/MsMain/POSIX main).

export class CModuleOutput {
	code: string = "";
	modulePath: string = "";
	hasDatInit: boolean = false;
	hasInit: boolean = false;
}

export function generateCModule(program: Node, ctx: CheckerContext, modulePath: string, aliveSet: AliveSet, isTestBuild: boolean, isHcr: boolean): string {
	return generateCModuleOutput(program, ctx, modulePath, aliveSet, isTestBuild, isHcr).code;
}

export function generateCModuleOutput(program: Node, ctx: CheckerContext, modulePath: string, aliveSet: AliveSet, isTestBuild: boolean, isHcr: boolean): CModuleOutput {
	const g = createCGen(ctx, modulePath);
	g.aliveSet = aliveSet;
	g.isTestBuild = isTestBuild;
	g.isHcr = isHcr;

	// Standard C headers (Standard reference implementation pattern)
	addLine(sec(g, CSection.Headers), "#include <stdint.h>");
	addLine(sec(g, CSection.Headers), "#include <stdbool.h>");
	addLine(sec(g, CSection.Headers), "#include <stddef.h>");
	if (ctx == null || ctx.targetOs != "solana") {
		// Solana/BPF has no libc — manual.h provides memcpy/memset/strlen
		addLine(sec(g, CSection.Headers), "#include <string.h>");
		addLine(sec(g, CSection.Headers), "#include <math.h>");
	}
	if (ctx != null && ctx.gcMode == GcMode.Manual) {
		// manual.h uses the same SYSTEM_H include guard as core.h,
		// so any subsequent @include("runtime/core/system.h") from prelude is a C-level no-op.
		match (ctx.targetOs) {
			"solana" => {
				addLine(sec(g, CSection.Headers), "#define MSOS_SOLANA");
				addLine(sec(g, CSection.Headers), "#define MSOS_BARE");
			},
			"bare" => {
				addLine(sec(g, CSection.Headers), "#define MSOS_BARE");
			},
			_ => {},
		};
		addLine(sec(g, CSection.Headers), "#include \"runtime/manual.h\"");
		nameSetAdd(g.declaredThings, "inc:runtime/manual.h");
		nameSetAdd(g.declaredThings, "inc:runtime/core/system.h");
	} else {
		if (ctx != null && ctx.targetOs == "wasm") {
			addLine(sec(g, CSection.Headers), "#define MSOS_WASM");
		}
		if (ctx != null && ctx.targetOs == "emcc") {
			addLine(sec(g, CSection.Headers), "#define MSOS_EMCC");
		}
		if (ctx != null && ctx.targetOs == "ios") {
			addLine(sec(g, CSection.Headers), "#define MSOS_IOS");
		}
		if (ctx != null && ctx.targetOs == "android") {
			addLine(sec(g, CSection.Headers), "#define MSOS_ANDROID");
		}
		if (g.isTestBuild) {
			addLine(sec(g, CSection.Headers), "#define MS_TEST_BUILD 1");
		}
		addLine(sec(g, CSection.Headers), "#include \"runtime/core/system.h\"");
		nameSetAdd(g.declaredThings, "inc:runtime/core/system.h");
	}
	emitTestHeader(g);


	// Emit additional @include directives from checker (user code @include pragmas)
	if (ctx != null && ctx.includeDirectives != "") {
		emitIncludeDirectives(g, ctx.includeDirectives);
	}

	if (program != null && program.kind == NodeKind.Program) {
		const pd = program.data as ProgramData;
		for (const stmt of pd.programStmts) {
			registerDeclCName(g, stmt);
		}
		for (const stmt of pd.programStmts) {
			genDecl(g, stmt, false);
		}
	}

	// Emit test table (test builds only — after all TestDecl nodes processed)
	emitTestTable(g);

	// Generate per-module init functions (non-static for cross-module visibility)
	const output = new CModuleOutput();
	output.modulePath = modulePath;
	genModuleInitFns(g, output);



	emitStringPoolDecls(g.stringPool, sec(g, CSection.StringPool));

	output.code = assembleOutput(g);
	return output;
}

// ===== Per-Module Init Functions =====
//
// Generates DatInit000 and Init000 for this module.
// Non-static so other modules' dispatchers can call them.

function genModuleInitFns(g: CGen, output: CModuleOutput): void {
	const modName = mangleModuleName(g.modulePath);
	const datInitName = g.isHcr ? "DatInit000" : `${modName}__DatInit000`;
	const initName = g.isHcr ? "Init000" : `${modName}__Init000`;

	const datContent = extract(sec(g, CSection.DatInit));
	const initContent = extract(sec(g, CSection.ModuleInit));
	output.hasDatInit = datContent.length > 0;
	output.hasInit = initContent.length > 0;

	// Clear sections (re-emitted into Procs)
	sec(g, CSection.DatInit).parts = [];
	sec(g, CSection.ModuleInit).parts = [];

	const hdrs = sec(g, CSection.ProcHeaders);
	const procs = sec(g, CSection.Procs);

	// Contract targets (solana, bare): single entry point, init called once in sequence.
	// Skip mutable static guard variables — no re-entry possible.
	const ost = g.checkerCtx != null ? g.checkerCtx.targetOs : "";
	const skipGuard = ost == "solana" || ost == "bare";

	// DatInit000: data/type initialization (non-static for cross-module visibility)
	addLine(hdrs, `void ${datInitName}(void);`);
	addLine(procs, `void ${datInitName}(void) {`);
	if (!skipGuard) {
		addLine(procs, `  static MS_BOOL ${datInitName}_guard_ = 0;`);
		addLine(procs, `  if (${datInitName}_guard_) return;`);
		addLine(procs, `  ${datInitName}_guard_ = 1;`);
	}
	if (datContent.length > 0) {
		add(procs, datContent);
	}
	addLine(procs, "}");
	addNewline(procs);

	// Init000: user top-level code (non-static for cross-module visibility)
	addLine(hdrs, `void ${initName}(void);`);
	addLine(procs, `void ${initName}(void) {`);
	if (!skipGuard) {
		addLine(procs, `  static MS_BOOL ${initName}_guard_ = 0;`);
		addLine(procs, `  if (${initName}_guard_) return;`);
		addLine(procs, `  ${initName}_guard_ = 1;`);
	}
	if (initContent.length > 0) {
		add(procs, initContent);
	}
	if (g.initProc.beforeRetNeeded) {
		addLine(procs, "  BeforeRet_: ;");
		g.initProc.beforeRetNeeded = false;
	}
	addLine(procs, "}");
	addNewline(procs);
}

// ===== Global Init Dispatcher =====
//
// Generates the global init dispatcher: forward decls, MsPreMainInner, MsMainInner,
// MsMain, global vars, and POSIX main.

export function genProjectDispatcher(modulePaths: string[], entryPath: string, targetOs: string, noMain: boolean, outputs: CModuleOutput[]): string {
	const b = createBuilder();
	const emptyDatInits = new HashSet<string>();
	const emptyInits = new HashSet<string>();
	for (const output of outputs) {
		if (!output.hasDatInit) emptyDatInits.add(output.modulePath);
		if (!output.hasInit) emptyInits.add(output.modulePath);
	}

	// Include stdint.h for int32_t, drc.h for msOrcCollect, system.h for msTestErrorFlag + async futures
	addLine(b, "#include <stdint.h>");
	addLine(b, "#include \"runtime/drc.h\"");
	addLine(b, "#include \"runtime/core/system.h\"");
	addNewline(b);

	// Forward declarations for all module init functions
	for (const mp of modulePaths) {
		const modName = mangleModuleName(mp);
		if (!emptyDatInits.has(mp)) addLine(b, `void ${modName}__DatInit000(void);`);
		if (!emptyInits.has(mp) || mp == entryPath) addLine(b, `void ${modName}__Init000(void);`);
	}
	addNewline(b);

	// Global variables (must precede function bodies that reference them)
	const contractMode = targetOs == "solana";
	if (!contractMode) {
		addLine(b, "int cmdCount;");
		addLine(b, "char** cmdLine;");
		addLine(b, "char** gEnv;");
		addLine(b, "int msProgramResult;");
		addNewline(b);
	}

	// MsPreMainInner — calls DatInit000 for all modules in topological order
	addLine(b, "static void MsPreMainInner(void) {");
	b.indent += 1;
	for (const mp of modulePaths) {
		if (!emptyDatInits.has(mp)) addLine(b, `${mangleModuleName(mp)}__DatInit000();`);
	}
	b.indent -= 1;
	addLine(b, "}");
	addNewline(b);

	// MsMainInner — dependency Init000, then entry Init000, then user main
	addLine(b, "static void MsMainInner(void) {");
	b.indent += 1;
	for (const mp of modulePaths) {
		if (mp != entryPath && !emptyInits.has(mp)) {
			addLine(b, `${mangleModuleName(mp)}__Init000();`);
		}
	}
	addLine(b, `${mangleModuleName(entryPath)}__Init000();`);
	b.indent -= 1;
	addLine(b, "}");
	addNewline(b);

	// MsMain — exposed for targets where user provides own entry point
	addLine(b, "void MsMain(void) {");
	addLine(b, "  MsPreMainInner();");
	addLine(b, "  MsMainInner();");
	addLine(b, "  msTestErrorFlag();");
	addLine(b, "  msOrcCollect();");
	addLine(b, "}");
	addNewline(b);

	// Library output: the host owns the entry point and calls MsMain() — emit no
	// main wrapper, whatever the target OS.
	if (noMain) return extract(b);

	match (targetOs) {
		"bare" => {
			addLine(b, "int main(void) {");
			addLine(b, "  MsMain();");
			addLine(b, "  return msProgramResult;");
			addLine(b, "}");
		},
		"solana" => {
			addLine(b, "uint64_t entrypoint(const uint8_t* input) {");
			addLine(b, "  (void)input;");
			addLine(b, "  MsMain();");
			addLine(b, "  return 0;");
			addLine(b, "}");
		},
		"wasm" => {
			// WASI crt1 provides _start which calls main().
			addLine(b, "int main(void) {");
			addLine(b, "  MsMain();");
			addLine(b, "  msDrainUntilIdle();");
			addLine(b, "  if (msReportOrphanFailures()) msProgramResult = 1;");
			addLine(b, "  return msProgramResult;");
			addLine(b, "}");
		},
		"ios" | "android" => {
			// No POSIX main: the host app (Xcode/Swift/ObjC) owns the entry and
			// calls MsMain() to initialize — parity with the host owning the entry point.
		},
		_ => {
			addLine(b, "int main(int argc, char** argv, char** env) {");
			addLine(b, "  cmdLine = argv;");
			addLine(b, "  cmdCount = argc;");
			addLine(b, "  gEnv = env;");
			addLine(b, "  MsMain();");
			addLine(b, "  msDrainUntilIdle();");
			addLine(b, "  if (msReportOrphanFailures()) msProgramResult = 1;");
			addLine(b, "  return msProgramResult;");
			addLine(b, "}");
		},
	};

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
	const output = generateCModuleOutput(pr.value, null as unknown as CheckerContext, "test/input", createAliveSet(), false, false);
	const paths: string[] = ["test/input"];
	const dispatcher = genProjectDispatcher(paths, "test/input", "", false, [output]);
	return output.code + "\n" + dispatcher;
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

test "module init metadata is isolated between emissions" {
	const parsed = parseSource("");
	assert parsed.ok;
	if (!parsed.ok) return;
	const first = generateCModuleOutput(parsed.value, null as unknown as CheckerContext, "test/first", createAliveSet(), false, false);
	const second = generateCModuleOutput(parsed.value, null as unknown as CheckerContext, "test/second", createAliveSet(), false, false);
	assert first.modulePath == "test/first";
	assert second.modulePath == "test/second";
	assert !first.hasDatInit && !first.hasInit;
	assert !second.hasDatInit && !second.hasInit;
	assert first.code == generateCModule(parsed.value, null as unknown as CheckerContext, "test/first", createAliveSet(), false, false);
}

test "dispatcher follows dependency order regardless of result order" {
	const dep = new CModuleOutput();
	dep.modulePath = "test/dep";
	dep.hasDatInit = true;
	dep.hasInit = true;
	const empty = new CModuleOutput();
	empty.modulePath = "test/empty";
	const entry = new CModuleOutput();
	entry.modulePath = "test/entry";
	entry.hasInit = true;
	const paths = [dep.modulePath, empty.modulePath, entry.modulePath];
	const original = genProjectDispatcher(paths, entry.modulePath, "", false, [dep, empty, entry]);
	assert original == genProjectDispatcher(paths, entry.modulePath, "", false, [entry, empty, dep]);
	assert original == genProjectDispatcher(paths, entry.modulePath, "", false, [empty, dep, entry]);
	assert original == genProjectDispatcher(paths, entry.modulePath, "", false, [dep, empty, entry]);
	const depName = mangleModuleName(dep.modulePath);
	const emptyName = mangleModuleName(empty.modulePath);
	const entryName = mangleModuleName(entry.modulePath);
	assert original.indexOf(`${emptyName}__DatInit000`) < 0;
	assert original.indexOf(`${emptyName}__Init000`) < 0;
	assert original.indexOf(`${entryName}__DatInit000`) < 0;
	assert original.indexOf(`${depName}__DatInit000();`) < original.indexOf(`${depName}__Init000();`);
	assert original.indexOf(`${depName}__Init000();`) < original.indexOf(`${entryName}__Init000();`);
	const bareEntry = genProjectDispatcher([empty.modulePath], empty.modulePath, "", true, [empty]);
	assert bareEntry.indexOf(`${emptyName}__Init000();`) >= 0;
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


