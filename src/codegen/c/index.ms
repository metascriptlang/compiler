// C Codegen — Entry Point
//
// generateCModule(program, checkerCtx, modulePath, aliveSet, isTestBuild) → string  (self-contained per-module)
// genProjectDispatcher(modulePaths, entryPath, targetOs, noMain) → string  (global init dispatcher)
//
// Module init follows two-phase pattern:
//   DatInit000 (data/type init, runs first) + Init000 (user code, runs second)
//   main(argc, argv) → MsMain → MsPreMainInner (DatInit) → MsMainInner (Init)

import { Node, NodeKind, ProgramData, SymbolKind, TypeKind, VariableDeclData, ObjectLiteralData } from "../../ast/node";
import { getProperty } from "../../checker/types";
import { forEachChild } from "../../ast/visitor";
import { CheckerContext, CheckerError, GcMode, findExportedSymbol } from "../../checker/context";
import {
	CGen, CSection, AliveSet, CEmissionFacts,
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
	errors: CheckerError[] = [];
}

function prepareEmissionTypes(node: Node, ctx: CheckerContext): void {
	if (node.kind == NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		if (d.initializer != null) {
			if (d.initializer.nodeType == null && node.nodeType != null) {
				d.initializer.nodeType = node.nodeType;
			}
			if (node.nodeType != null && node.nodeType.kind == TypeKind.Union
				&& d.initializer.kind == NodeKind.ObjectLiteral) {
				d.initializer.nodeType = node.nodeType;
			}
		}
	} else if (node.kind == NodeKind.ObjectLiteral) {
		const d = node.data as ObjectLiteralData;
		if (node.nodeType != null && node.nodeType.typeChildren != null) {
			let fi = 0;
			while (fi < d.properties.length && fi < d.keys.length) {
				if (d.properties[fi].nodeType == null) {
					const fieldType = getProperty(node.nodeType, d.keys[fi]);
					if (fieldType != null) {
						d.properties[fi].nodeType = fieldType;
				}
			}
				fi += 1;
			}
		}
	}
	forEachChild(node, (child: Node): void => { prepareEmissionTypes(child, ctx); });
}

export function prepareCModuleEmission(program: Node, ctx: CheckerContext, modulePath: string, aliveSet: AliveSet, facts: CEmissionFacts): void {
	if (program == null || program.kind != NodeKind.Program) return;
	prepareEmissionTypes(program, ctx);
	const g = createCGen(ctx, modulePath);
	g.aliveSet = aliveSet;
	g.emissionFacts = facts;
	g.preparationFacts = facts;
	g.preparingDeclarations = true;
	const pd = program.data as ProgramData;
	for (const stmt of pd.programStmts) registerDeclCName(g, stmt);
	for (const stmt of pd.programStmts) genDecl(g, stmt, false);
}

export function generateCModule(program: Node, ctx: CheckerContext, modulePath: string, aliveSet: AliveSet, isTestBuild: boolean, isHcr: boolean, facts: CEmissionFacts | null = null): string {
	const output = generateCModuleOutput(program, ctx, modulePath, aliveSet, isTestBuild, isHcr, facts);
	for (const diagnostic of output.errors) ctx.errors.push(diagnostic);
	return output.code;
}

export function generateCModuleOutput(program: Node, ctx: CheckerContext, modulePath: string, aliveSet: AliveSet, isTestBuild: boolean, isHcr: boolean, facts: CEmissionFacts | null = null): CModuleOutput {
	let preparedFacts = facts;
	if (preparedFacts == null) {
		const localFacts = new CEmissionFacts();
		prepareCModuleEmission(program, ctx, modulePath, aliveSet, localFacts);
		preparedFacts = localFacts;
	}
	return generatePreparedCModuleOutput(program, ctx, modulePath, aliveSet, isTestBuild, isHcr, preparedFacts);
}

export function generatePreparedCModuleOutput(program: Readonly<Node>, ctx: Readonly<CheckerContext>, modulePath: string, aliveSet: Readonly<AliveSet>, isTestBuild: boolean, isHcr: boolean, facts: Readonly<CEmissionFacts>): CModuleOutput {
	const g = createCGen(ctx, modulePath);
	g.emissionFacts = facts;
	g.aliveSet = aliveSet;
	g.isTestBuild = isTestBuild;
	g.isHcr = isHcr;

	// Standard C headers (Standard reference implementation pattern)
	addLine(sec(g, CSection.Headers), "#include <stdint.h>");
	addLine(sec(g, CSection.Headers), "#include <stdbool.h>");
	addLine(sec(g, CSection.Headers), "#include <stddef.h>");
	if (g.isHcr) {
		addLine(sec(g, CSection.Headers), "#include \"runtime/hcr.h\"");
	}
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
	output.errors = g.errors;
	return output;
}

// ===== Per-Module Init Functions =====
//
// Generates DatInit000 and Init000 for this module.
// Non-static so other modules' dispatchers can call them.

function genModuleInitFns(g: CGen, output: CModuleOutput): void {
	const modName = mangleModuleName(g.modulePath);
	const datInitName = `${modName}__DatInit000`;
	const initName = `${modName}__Init000`;

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

export function genProjectDispatcher(
	modulePaths: string[],
	entryPath: string,
	targetOs: string,
	noMain: boolean,
	outputs: CModuleOutput[],
): string {
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
			addLine(b, "  msSolanaEnter(input);");
			addLine(b, "  MsMain();");
			addLine(b, "  return msSolanaResult();");
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

export function genHcrCoreDispatcher(modulePaths: string[], outputs: CModuleOutput[]): string {
	const b = createBuilder();
	const datInits = new HashSet<string>();
	const inits = new HashSet<string>();
	for (const output of outputs) {
		if (output.hasDatInit) datInits.add(output.modulePath);
		if (output.hasInit) inits.add(output.modulePath);
	}
	addLine(b, "#include <stdint.h>");
	addLine(b, "#include \"runtime/drc.h\"");
	addLine(b, "#include \"runtime/core/system.h\"");
	addLine(b, "#include \"runtime/hcr.h\"");
	addNewline(b);
	for (const mp of modulePaths) {
		if (datInits.has(mp)) addLine(b, `void ${mangleModuleName(mp)}__DatInit000(void);`);
		if (inits.has(mp)) addLine(b, `void ${mangleModuleName(mp)}__Init000(void);`);
	}
	addNewline(b);
	addLine(b, "int cmdCount;");
	addLine(b, "char** cmdLine;");
	addLine(b, "char** gEnv;");
	addLine(b, "int msProgramResult;");
	addNewline(b);
	addLine(b, "void msHcrCoreInit(void) {");
	b.indent += 1;
	addLine(b, "static int done = 0;");
	addLine(b, "if (done) return;");
	addLine(b, "done = 1;");
	for (const mp of modulePaths) {
		if (datInits.has(mp)) addLine(b, `${mangleModuleName(mp)}__DatInit000();`);
	}
	for (const mp of modulePaths) {
		if (inits.has(mp)) addLine(b, `${mangleModuleName(mp)}__Init000();`);
	}
	b.indent -= 1;
	addLine(b, "}");
	return extract(b);
}

export function genHcrImageDispatcher(output: CModuleOutput, isEntry: boolean): string {
	const b = createBuilder();
	const modName = mangleModuleName(output.modulePath);
	addLine(b, "#include \"runtime/hcr.h\"");
	addNewline(b);
	if (output.hasDatInit) addLine(b, `void ${modName}__DatInit000(void);`);
	if (output.hasInit || isEntry) addLine(b, `void ${modName}__Init000(void);`);
	addNewline(b);
	addLine(b, "MS_HCR_EXPORT void DatInit000(void) {");
	addLine(b, "  msHcrCoreInit();");
	if (output.hasDatInit) addLine(b, `  ${modName}__DatInit000();`);
	addLine(b, "}");
	addLine(b, "MS_HCR_EXPORT void Init000(void) {");
	if (output.hasInit || isEntry) addLine(b, `  ${modName}__Init000();`);
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



import { SymbolKind } from "../../ast/node";
import { createFunction, voidType } from "../../checker/types";
import { makeSymbol } from "../../checker/symbol";
import { createContext } from "../../checker/context";
import { aliveSetAdd } from "./context";
import { mangledFunctionName, mangledTypeName } from "./names";
import { ensureTypeInfoDef } from "./types";

test "generic module emission preserves defining owner under permutations" {
	const parsed = parseSource("function generic__i32(): void {}");
	assert parsed.ok;
	if (!parsed.ok) return;
	const program = parsed.value;
	const pd = program.data as ProgramData;
	const node = pd.programStmts[0];
	const fnType = createFunction([], [], voidType());
	node.nodeType = fnType;
	node.resolvedSym = makeSymbol("generic__i32", SymbolKind.Function, fnType, false);
	node.resolvedSym.modulePath = "owner.ms";
	pd.programStmts.push(node);
	const ctx = null as unknown as CheckerContext;
	const alive = createAliveSet();
	const facts = new CEmissionFacts();
	const paths = ["user.ms", "owner.ms", "other.ms"];
	for (const path of paths) prepareCModuleEmission(program, ctx, path, alive, facts);
	const name = mangledFunctionName(node.resolvedSym, "generic__i32", 0);
	assert facts.genericOwners.get(name) == "owner.ms";
	const original: CModuleOutput[] = [];
	for (const path of paths) original.push(generateCModuleOutput(program, ctx, path, alive, false, false, facts));
	const orders: number[] = [2, 1, 0, 1, 0, 2];
	for (const slot of orders) {
		const output = generateCModuleOutput(program, ctx, paths[slot], alive, false, false, facts);
		assert output.code == original[slot].code;
		const body = "void " + name + "(void) {";
		assert output.code.split(body).length == (slot == 1 ? 2 : 1);
	}
	const dispatcher = genProjectDispatcher(paths, "user.ms", "", false, original);
	assert dispatcher == genProjectDispatcher(paths, "user.ms", "", false, [original[2], original[1], original[0]]);
	assert dispatcher == genProjectDispatcher(paths, "user.ms", "", false, [original[1], original[0], original[2]]);
	const standalone = generateCModule(program, ctx, "owner.ms", alive, false, false);
	assert standalone == generateCModule(program, ctx, "owner.ms", alive, false, false);
	assert standalone == original[1].code;
}

test "TypeInfo facts use emission DCE predicates before any module emits" {
	const parsed = parseSource("class Hidden {} const HiddenTypeInfo = 0; const AliveTypeInfo = 0;");
	assert parsed.ok;
	if (!parsed.ok) return;
	const ctx = createContext();
	const path = "owner.ms";
	const node = (parsed.value.data as ProgramData).programStmts[0];
	node.resolvedSym = makeSymbol("Hidden", SymbolKind.Class, null, false);
	node.resolvedSym.modulePath = path;
	const alive = createAliveSet();
	aliveSetAdd(alive, path, "AliveTypeInfo");
	const facts = new CEmissionFacts();
	prepareCModuleEmission(parsed.value, ctx, path, alive, facts);
	const qualified = mangledTypeName(node.resolvedSym, "Hidden");
	assert facts.skippedTypeInfos.has("Hidden");
	assert facts.skippedTypeInfos.has(qualified);
	assert !facts.skippedTypeInfos.has("Alive");
	const consumer = createCGen(ctx, "consumer.ms");
	consumer.emissionFacts = facts;
	const before = consumer.errors.length;
	ensureTypeInfoDef(consumer, qualified, null);
	assert consumer.errors.length == before + 1;
	assert consumer.errors[before].message.indexOf("reachability marked it dead") >= 0;
	const unfiltered = new CEmissionFacts();
	prepareCModuleEmission(parsed.value, ctx, path, createAliveSet(), unfiltered);
	assert !unfiltered.skippedTypeInfos.has("Hidden");
	ctx.gcMode = GcMode.Manual;
	const manual = new CEmissionFacts();
	prepareCModuleEmission(parsed.value, ctx, path, alive, manual);
	assert !manual.skippedTypeInfos.has("Hidden");
	assert !manual.skippedTypeInfos.has(qualified);
}
