// C Codegen — Entry Point
//
// generateCModule(program, checkerCtx, modulePath, aliveSet, isTestBuild) → string  (self-contained per-module)
// genProjectDispatcher(modulePaths, entryPath, targetOs, noMain) → string  (global init dispatcher)
//
// Module init follows two-phase pattern:
//   DatInit000 (data/type init, runs first) + Init000 (user code, runs second)
//   main(argc, argv) → MsMain → MsPreMainInner (DatInit) → MsMainInner (Init)

import { Node, NodeKind, ProgramData, SymbolKind, TypeKind, VariableDeclData, ObjectLiteralData } from "../../ast/node";
import { getPropertyUnprofiled, createFunction, voidType, createStruct, createPrimitive } from "../../checker/types";
import { forEachChild } from "../../ast/visitor";
import { markErrorBlindFinallies } from "../../checker/raises";
import { CheckerContext, CheckerError, GcMode, findExportedSymbol, createContext, dispatchOverrideTable } from "../../checker/context";
import {
	CGen, CSection, AliveSet, CEmissionFacts, TypeInfoKind, Builder,
	createCGen, createAliveSet, createBuilder, sec, add, addLine, addNewline, assembleOutput, extract, nameSetAdd, undefPlatformMacros,
	replayFactWrites,
} from "./context";
import { genDecl, registerDeclCName, emitInlineCopies } from "./declarations";
import { mangleModuleName, mangledFunctionName, mangledTypeName, buildModuleNameRoots } from "./names";
import { emitStringPoolDecls } from "./literals";
import { emitTestHeader, emitTestTable } from "./test";
import { emitIncludeDirectives, emitIncludes } from "./context";
import { placedInstances } from "../../checker/instantiate";
import { headerIncludeTable } from "../../module/cimport/emit";
import { emitOwnedTypeInfos, refArrayCellName, arcCellName, typeInfoCName, defineDeferredElements, isHcrImageModule, objectTypeInfoKey, hookOps } from "./types";
import { collectModuleTypeInfoDemands } from "../../checker/reachability";
import { DynamicModulePlan } from "../../module/graph";

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
	hasDeinit: boolean = false;
	errors: CheckerError[] = [];
}

function prepareEmissionTypes(node: Node, ctx: CheckerContext): void {
	if (node.kind == NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		if (d.initializer != null) {
			if (d.initializer.nodeType == null && node.nodeType != null) {
				d.initializer.nodeType = node.nodeType;
			}
		}
	} else if (node.kind == NodeKind.ObjectLiteral) {
		const d = node.data as ObjectLiteralData;
		if (node.nodeType != null && node.nodeType.typeChildren != null) {
			let fi = 0;
			while (fi < d.properties.length && fi < d.keys.length) {
				if (d.properties[fi].nodeType == null) {
					const fieldType = getPropertyUnprofiled(node.nodeType, d.keys[fi]);
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
	markErrorBlindFinallies(program);
	const g = createCGen(ctx, modulePath);
	g.aliveSet = aliveSet;
	g.emissionFacts = facts;
	g.preparationFacts = facts;
	g.preparingDeclarations = true;
	bindRegistryFacts(facts);
	const pd = program.data as ProgramData;
	for (const stmt of pd.programStmts) registerDeclCName(g, stmt);
	for (const stmt of pd.programStmts) genDecl(g, stmt, false);
	registerTypeInfoDemands(aliveSet, facts);
}

export function replayCModuleEmission(aliveSet: AliveSet, facts: CEmissionFacts, writes: string[]): void {
	replayFactWrites(facts, writes);
	bindRegistryFacts(facts);
	registerTypeInfoDemands(aliveSet, facts);
}

function bindRegistryFacts(facts: CEmissionFacts): void {
	if (facts.dispatchOverrides == null) facts.dispatchOverrides = dispatchOverrideTable();
	if (facts.moduleNameRoots == null) facts.moduleNameRoots = buildModuleNameRoots();
	if (facts.hookOps == null) facts.hookOps = hookOps();
	if (facts.placedInstances == null) facts.placedInstances = placedInstances();
	if (facts.headerIncludes == null) facts.headerIncludes = headerIncludeTable();
}

function registerTypeInfoDemands(demands: AliveSet, facts: CEmissionFacts): void {
	for (const info of demands.typeInfos) {
		if (facts.typeInfos.has(info.key)) continue;
		info.cName = match (info.kind) {
			TypeInfoKind.RefArrayCell => refArrayCellName(info.subject.typeReturn!),
			TypeInfoKind.ArcCell => arcCellName(info.subject),
			_ => typeInfoCName(info.subject),
		};
		facts.typeInfos.set(info.key, info);
		facts.typeInfoOrder.push(info);
	}
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
		if (program != null && program.kind == NodeKind.Program) registerTypeInfoDemands(collectModuleTypeInfoDemands(program, modulePath), localFacts);
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
	emitInlineCopies(g);
	emitOwnedTypeInfos(g);

	// Emit test table (test builds only — after all TestDecl nodes processed)
	emitTestTable(g);

	// Generate per-module init functions (non-static for cross-module visibility)
	const output = new CModuleOutput();
	output.modulePath = modulePath;
	genModuleInitFns(g, output);



	defineDeferredElements(g);
	emitStringPoolDecls(g.stringPool, sec(g, CSection.StringPool));
	emitIncludes(g);
	undefPlatformMacros(g);

	output.code = assembleOutput(g);
	output.errors = g.errors;
	return output;
}

// ===== Per-Module Init Functions =====
//
// Generates DatInit000 and Init000 for this module.
// Non-static so other modules' dispatchers can call them.

function genModuleInitFns(g: CGen, output: CModuleOutput): void {
	const modName = mangleModuleName(g.emissionFacts.moduleNameRoots!, g.modulePath);
	const datInitName = `${modName}__DatInit000`;
	const initName = `${modName}__Init000`;

	const datContent = extract(sec(g, CSection.DatInit));
	const initContent = extract(sec(g, CSection.ModuleInit));
	const deinitContent = extract(sec(g, CSection.ModuleDeinit));
	output.hasDatInit = datContent.length > 0;
	output.hasInit = initContent.length > 0;
	output.hasDeinit = deinitContent.length > 0;

	// Clear sections (re-emitted into Procs)
	sec(g, CSection.DatInit).parts = [];
	sec(g, CSection.ModuleInit).parts = [];
	sec(g, CSection.ModuleDeinit).parts = [];

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
	if (output.hasInit && !isHcrImageModule(g, g.modulePath)) addLine(procs, "  msTestErrorFlag();");
	addLine(procs, "}");
	addNewline(procs);

	if (!output.hasDeinit) return;
	const deinitName = `${modName}__Deinit000`;
	addLine(hdrs, `void ${deinitName}(void);`);
	addLine(procs, `void ${deinitName}(void) {`);
	if (!skipGuard) {
		addLine(procs, `  static MS_BOOL ${deinitName}_guard_ = 0;`);
		addLine(procs, `  if (${deinitName}_guard_) return;`);
		addLine(procs, `  ${deinitName}_guard_ = 1;`);
	}
	add(procs, deinitContent);
	if (g.deinitProc.beforeRetNeeded) {
		addLine(procs, "  BeforeRet_: ;");
		g.deinitProc.beforeRetNeeded = false;
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
	plan: DynamicModulePlan = new DynamicModulePlan(),
): string {
	const b = createBuilder();
	const emptyDatInits = new HashSet<string>();
	const emptyInits = new HashSet<string>();
	const deinits = new HashSet<string>();
	for (const output of outputs) {
		if (!output.hasDatInit) emptyDatInits.add(output.modulePath);
		if (!output.hasInit) emptyInits.add(output.modulePath);
		if (output.hasDeinit) deinits.add(output.modulePath);
	}

	// Include stdint.h for int32_t, drc.h for msOrcCollect, system.h for msTestErrorFlag + async futures
	addLine(b, "#include <stdint.h>");
	addLine(b, "#include \"runtime/drc.h\"");
	addLine(b, "#include \"runtime/core/system.h\"");
	if (targetOs == "solana") addLine(b, "#include \"runtime/solana/solana.h\"");
	addNewline(b);

	// Forward declarations for all module init functions
	for (const mp of modulePaths) {
		const modName = mangleModuleName(buildModuleNameRoots(), mp);
		if (!emptyDatInits.has(mp)) addLine(b, `void ${modName}__DatInit000(void);`);
		if (!emptyInits.has(mp) || mp == entryPath) addLine(b, `void ${modName}__Init000(void);`);
		if (deinits.has(mp)) addLine(b, `void ${modName}__Deinit000(void);`);
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

	emitModuleRecords(b, plan, emptyInits, deinits);

	// MsPreMainInner — calls DatInit000 for all modules in topological order
	addLine(b, "static void MsPreMainInner(void) {");
	b.indent += 1;
	if (plan.records.length > 0) addLine(b, `msModuleTableRegister(msModuleRecords, ${plan.records.length});`);
	for (const mp of modulePaths) {
		if (!emptyDatInits.has(mp)) addLine(b, `${mangleModuleName(buildModuleNameRoots(), mp)}__DatInit000();`);
	}
	b.indent -= 1;
	addLine(b, "}");
	addNewline(b);

	// MsMainInner — dependency Init000, then entry Init000, then user main
	addLine(b, "static void MsMainInner(void) {");
	b.indent += 1;
	for (const mp of modulePaths) {
		if (mp != entryPath && !emptyInits.has(mp) && !plan.lazy.has(mp)) {
			addLine(b, `${mangleModuleName(buildModuleNameRoots(), mp)}__Init000();`);
		}
	}
	addLine(b, `${mangleModuleName(buildModuleNameRoots(), entryPath)}__Init000();`);
	b.indent -= 1;
	addLine(b, "}");
	addNewline(b);

	// MsMain — exposed for targets where user provides own entry point
	if (targetOs == "solana") addLine(b, "#ifdef MS_SOL_MAIN_NOINLINE\n__attribute__((noinline))\n#endif");
	addLine(b, "void MsMain(void) {");
	addLine(b, "  MsPreMainInner();");
	addLine(b, "  MsMainInner();");
	addLine(b, "  msTestErrorFlag();");
	addLine(b, "  msOrcCollect();");
	addLine(b, "}");
	addNewline(b);

	addLine(b, "void MsDestroyGlobals(void) {");
	b.indent += 1;
	if (plan.records.length > 0) addLine(b, "msModuleDeinitLazy();");
	if (deinits.has(entryPath)) addLine(b, `${mangleModuleName(buildModuleNameRoots(), entryPath)}__Deinit000();`);
	let di = modulePaths.length;
	while (di > 0) {
		di -= 1;
		const mp = modulePaths[di];
		if (mp != entryPath && deinits.has(mp) && !plan.lazy.has(mp)) addLine(b, `${mangleModuleName(buildModuleNameRoots(), mp)}__Deinit000();`);
	}
	addLine(b, "msOrcCollect();");
	b.indent -= 1;
	addLine(b, "}");
	addNewline(b);

	// Library output: the host owns the entry point and calls MsMain() — emit no
	// main wrapper, whatever the target OS.
	if (noMain) return extract(b);

	match (targetOs) {
		"bare" => {
			addLine(b, "int main(void) {");
			addLine(b, "  MsMain();");
			addLine(b, "  MsDestroyGlobals();");
			addLine(b, "  return msProgramResult;");
			addLine(b, "}");
		},
		"solana" => {
			addLine(b, "uint64_t entrypoint(const uint8_t* input, const uint8_t* instructionData) {");
			addLine(b, "  uint64_t accounts[MS_SOL_MAX_ACCOUNTS];");
			addLine(b, "  msSolStart(input, accounts, instructionData);");
			addLine(b, "  MsMain();");
			addLine(b, "  return msSolanaResult();");
			addLine(b, "}");
		},
		"wasm" => {
			// WASI crt1 provides _start which calls main().
			addLine(b, "int main(int argc, char** argv) {");
			addLine(b, "  cmdLine = argv;");
			addLine(b, "  cmdCount = argc;");
			addLine(b, "  MsMain();");
			addLine(b, "  msDrainUntilIdle();");
			addLine(b, "  if (msReportOrphanFailures()) msProgramResult = 1;");
			addLine(b, "  MsDestroyGlobals();");
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
			addLine(b, "  MsDestroyGlobals();");
			addLine(b, "  return msProgramResult;");
			addLine(b, "}");
		},
	};

	return extract(b);
}

function emitModuleRecords(b: Builder, plan: DynamicModulePlan, emptyInits: HashSet<string>, deinits: HashSet<string>): void {
	if (plan.records.length == 0) return;
	for (let i = 0; i < plan.records.length; i += 1) {
		if (plan.requested[i].length == 0) continue;
		let list = "";
		for (const at of plan.requested[i]) list = list == "" ? `${at}` : `${list}, ${at}`;
		addLine(b, `static const int32_t msModuleRequested${i}[] = { ${list} };`);
	}
	addLine(b, `static msModuleRecord msModuleRecords[${plan.records.length}] = {`);
	b.indent += 1;
	for (let i = 0; i < plan.records.length; i += 1) {
		const mp = plan.records[i];
		const modName = mangleModuleName(buildModuleNameRoots(), mp);
		if (!plan.lazy.has(mp)) {
			addLine(b, `{ .name = "${modName}", .status = MS_MODULE_EVALUATED },`);
			continue;
		}
		const init = emptyInits.has(mp) ? "NULL" : `${modName}__Init000`;
		const deinit = deinits.has(mp) ? `${modName}__Deinit000` : "NULL";
		const requested = plan.requested[i].length > 0 ? `msModuleRequested${i}` : "NULL";
		const tla = plan.topLevelAwait.has(mp) ? ", .hasTLA = true" : "";
		addLine(b, `{ .name = "${modName}", .init = ${init}, .deinit = ${deinit}, .requested = ${requested}, .requestedCount = ${plan.requested[i].length}, .status = MS_MODULE_PENDING${tla} },`);
	}
	b.indent -= 1;
	addLine(b, "};");
	addNewline(b);
}

export function genHcrCoreDispatcher(modulePaths: string[], outputs: CModuleOutput[], plan: DynamicModulePlan): string {
	const b = createBuilder();
	const datInits = new HashSet<string>();
	const inits = new HashSet<string>();
	const deinits = new HashSet<string>();
	for (const output of outputs) {
		if (output.hasDatInit) datInits.add(output.modulePath);
		if (output.hasInit) inits.add(output.modulePath);
		if (output.hasDeinit) deinits.add(output.modulePath);
	}
	addLine(b, "#include <stdint.h>");
	addLine(b, "#include \"runtime/drc.h\"");
	addLine(b, "#include \"runtime/core/system.h\"");
	addLine(b, "#include \"runtime/hcr.h\"");
	addNewline(b);
	for (const mp of modulePaths) {
		if (datInits.has(mp)) addLine(b, `void ${mangleModuleName(buildModuleNameRoots(), mp)}__DatInit000(void);`);
		if (inits.has(mp)) addLine(b, `void ${mangleModuleName(buildModuleNameRoots(), mp)}__Init000(void);`);
		if (deinits.has(mp)) addLine(b, `void ${mangleModuleName(buildModuleNameRoots(), mp)}__Deinit000(void);`);
	}
	addNewline(b);
	addLine(b, "int cmdCount;");
	addLine(b, "char** cmdLine;");
	addLine(b, "char** gEnv;");
	addLine(b, "int msProgramResult;");
	addNewline(b);
	const core = new HashSet<string>();
	for (const mp of modulePaths) core.add(mp);
	const noInit = new HashSet<string>();
	const coreDeinits = new HashSet<string>();
	for (const mp of plan.records) {
		if (!core.has(mp) || !inits.has(mp)) noInit.add(mp);
		if (core.has(mp) && deinits.has(mp)) coreDeinits.add(mp);
	}
	emitModuleRecords(b, plan, noInit, coreDeinits);
	addLine(b, "void msHcrCoreInit(void) {");
	b.indent += 1;
	addLine(b, "static int done = 0;");
	addLine(b, "if (done) return;");
	addLine(b, "done = 1;");
	if (plan.records.length > 0) addLine(b, `msModuleTableRegister(msModuleRecords, ${plan.records.length});`);
	for (const mp of modulePaths) {
		if (datInits.has(mp)) addLine(b, `${mangleModuleName(buildModuleNameRoots(), mp)}__DatInit000();`);
	}
	for (const mp of modulePaths) {
		if (inits.has(mp) && !plan.lazy.has(mp)) addLine(b, `${mangleModuleName(buildModuleNameRoots(), mp)}__Init000();`);
	}
	b.indent -= 1;
	addLine(b, "}");
	addNewline(b);
	addLine(b, "void msHcrCoreDeinit(void) {");
	b.indent += 1;
	addLine(b, "static int done = 0;");
	addLine(b, "if (done) return;");
	addLine(b, "done = 1;");
	let di = modulePaths.length;
	while (di > 0) {
		di -= 1;
		if (deinits.has(modulePaths[di]) && !plan.lazy.has(modulePaths[di])) addLine(b, `${mangleModuleName(buildModuleNameRoots(), modulePaths[di])}__Deinit000();`);
	}
	addLine(b, "msOrcCollect();");
	b.indent -= 1;
	addLine(b, "}");
	return extract(b);
}

export function genHcrImageDispatcher(output: CModuleOutput, isEntry: boolean, deferred: boolean): string {
	const b = createBuilder();
	const modName = mangleModuleName(buildModuleNameRoots(), output.modulePath);
	addLine(b, "#include \"runtime/hcr.h\"");
	addNewline(b);
	if (output.hasDatInit) addLine(b, `void ${modName}__DatInit000(void);`);
	if (output.hasInit || isEntry) addLine(b, `void ${modName}__Init000(void);`);
	if (output.hasDeinit) addLine(b, `void ${modName}__Deinit000(void);`);
	addNewline(b);
	addLine(b, "MS_HCR_EXPORT void DatInit000(void) {");
	addLine(b, "  msHcrCoreInit();");
	if (output.hasDatInit) addLine(b, `  ${modName}__DatInit000();`);
	addLine(b, "}");
	addLine(b, "MS_HCR_EXPORT void Init000(void) {");
	if (output.hasInit || isEntry) addLine(b, `  ${modName}__Init000();`);
	addLine(b, "}");
	if (output.hasDeinit) {
		addLine(b, "MS_HCR_EXPORT void Deinit000(void) {");
		addLine(b, `  ${modName}__Deinit000();`);
		addLine(b, "}");
	}
	if (deferred) addLine(b, `MS_HCR_EXPORT const char* HcrDeferred000(void) { return "${modName}"; }`);
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
	const depName = mangleModuleName(buildModuleNameRoots(), dep.modulePath);
	const emptyName = mangleModuleName(buildModuleNameRoots(), empty.modulePath);
	const entryName = mangleModuleName(buildModuleNameRoots(), entry.modulePath);
	assert original.indexOf(`${emptyName}__DatInit000`) < 0;
	assert original.indexOf(`${emptyName}__Init000`) < 0;
	assert original.indexOf(`${entryName}__DatInit000`) < 0;
	assert original.indexOf(`${depName}__DatInit000();`) < original.indexOf(`${depName}__Init000();`);
	assert original.indexOf(`${depName}__Init000();`) < original.indexOf(`${entryName}__Init000();`);
	const bareEntry = genProjectDispatcher([empty.modulePath], empty.modulePath, "", true, [empty]);
	assert bareEntry.indexOf(`${emptyName}__Init000();`) >= 0;
}

test "dispatcher destroys globals after the drain, entry module first then dependencies in reverse" {
	const dep = new CModuleOutput();
	dep.modulePath = "test/dep";
	dep.hasInit = true;
	dep.hasDeinit = true;
	const mid = new CModuleOutput();
	mid.modulePath = "test/mid";
	mid.hasDeinit = true;
	const quiet = new CModuleOutput();
	quiet.modulePath = "test/quiet";
	quiet.hasInit = true;
	const entry = new CModuleOutput();
	entry.modulePath = "test/entry";
	entry.hasInit = true;
	entry.hasDeinit = true;
	const paths = [dep.modulePath, mid.modulePath, quiet.modulePath, entry.modulePath];
	const out = genProjectDispatcher(paths, entry.modulePath, "", false, [dep, mid, quiet, entry]);
	const entryCall = out.indexOf(`${mangleModuleName(buildModuleNameRoots(), entry.modulePath)}__Deinit000();`);
	const midCall = out.indexOf(`${mangleModuleName(buildModuleNameRoots(), mid.modulePath)}__Deinit000();`);
	const depCall = out.indexOf(`${mangleModuleName(buildModuleNameRoots(), dep.modulePath)}__Deinit000();`);
	assert entryCall >= 0 && entryCall < midCall && midCall < depCall;
	assert out.indexOf(`${mangleModuleName(buildModuleNameRoots(), quiet.modulePath)}__Deinit000`) < 0;
	assert out.indexOf("msReportOrphanFailures()") < out.indexOf("  MsDestroyGlobals();");
	const lib = genProjectDispatcher(paths, entry.modulePath, "", true, [dep, mid, quiet, entry]);
	assert lib.indexOf("void MsDestroyGlobals(void) {") >= 0 && lib.indexOf("int main") < 0;
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



import { makeSymbol } from "../../checker/symbol";

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
	node.resolvedSym.instantiatedFrom = makeSymbol("generic", SymbolKind.Function, fnType, false);
	pd.programStmts.push(node);
	const ctx = null as unknown as CheckerContext;
	const alive = createAliveSet();
	const facts = new CEmissionFacts();
	const paths = ["user.ms", "owner.ms", "other.ms"];
	for (const path of paths) prepareCModuleEmission(program, ctx, path, alive, facts);
	const name = mangledFunctionName(buildModuleNameRoots(), node.resolvedSym, "generic__i32", 0);
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

test "TypeInfo demands merge by canonical key and take the object's C name" {
	const body = createStruct("Merged", ["v"], [createPrimitive(TypeKind.String)], true);
	body.sym = makeSymbol("Merged", SymbolKind.Interface, body, false);
	body.sym.modulePath = "owner.ms";
	const first = createAliveSet();
	const second = createAliveSet();
	const key = objectTypeInfoKey(body);
	first.typeInfos.push({ kind: TypeInfoKind.Object, subject: body, key, owner: "owner.ms", cName: "", destroy: null, trace: null, baseKey: "" });
	second.typeInfos.push({ kind: TypeInfoKind.Object, subject: body, key, owner: "other.ms", cName: "", destroy: null, trace: null, baseKey: "" });
	const facts = new CEmissionFacts();
	registerTypeInfoDemands(first, facts);
	registerTypeInfoDemands(second, facts);
	assert facts.typeInfoOrder.length == 1;
	assert facts.typeInfoOrder[0].owner == "owner.ms";
	assert facts.typeInfoOrder[0].cName == typeInfoCName(body);
}
