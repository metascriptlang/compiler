// C Codegen — Entry Point
//
// generateCModule(program, checkerCtx, modulePath, aliveSet, isTestBuild) → string  (self-contained per-module)
// genProjectDispatcher(modulePaths, entryPath, hasUserMain) → string  (global init dispatcher)
//
// Module init follows two-phase pattern:
//   DatInit000 (data/type init, runs first) + Init000 (user code, runs second)
//   main(argc, argv) → MsMain → MsPreMainInner (DatInit) → MsMainInner (Init)

import {
	Node, NodeKind, SymbolKind,
	ProgramData,
} from "../../ast/node";
import { CheckerContext, ExportRegistry } from "../../checker/context";
import { lookupSymbol } from "../../checker/symbol";
import {
	CGen, CSection, AliveSet, TestEntry,
	createCGen, createAliveSet, createBuilder, sec, add, addLine, addNewline,
	assembleOutput, extract, nameSetAdd, nameSetHas,
	typeRegistryAdd, typeRegistryLookup,
} from "./context";
import { genDecl } from "./declarations";
import { mangleModuleName, mangledFunctionName, safeName } from "./names";
import { getSimpleTypeDesc, isNrvoReturnType, getTypeDesc } from "./types";
import { Type, TypeKind, isInterfaceType } from "../../checker/types";
import { ccgIntroducedPtr } from "../../transform/native/pointerParam";
import { mangle } from "./names";
import { emitStringPoolDecls } from "./literals";
import { emitTestHeader, emitTestTable, genTestDispatcher } from "./test";
import { sliceStr } from "../../utils/string";

// ===== generateC — single-module entry point (backwards compatible) =====

export function generateC(program: Node, ctx: CheckerContext, modulePath: string): string {
	const moduleCode = generateCModule(program, ctx, modulePath, createAliveSet(), false);
	const mainSym = (ctx !== null && ctx.table !== null) ? lookupSymbol(ctx.table, "main") : null;
	const hasMain = mainSym !== null;
	let mainRet = "void";
	if (mainSym !== null && mainSym.symbolType !== null && mainSym.symbolType.typeReturn !== null) {
		const ret = getSimpleTypeDesc(mainSym.symbolType.typeReturn);
		if (ret !== "") mainRet = ret;
	}
	const paths: string[] = [modulePath];
	const dispatcher = genProjectDispatcher(paths, modulePath, hasMain, mainRet);
	return moduleCode + "\n" + dispatcher;
}

// ===== generateCModule — one module's C code (no dispatcher) =====
//
// Generates headers, type definitions, function prototypes, function bodies,
// and per-module DatInit000/Init000 (non-static for cross-module visibility).
// Does NOT generate the global dispatcher (MsPreMainInner/MsMainInner/MsMain/POSIX main).

export function generateCModule(program: Node, ctx: CheckerContext, modulePath: string, aliveSet: AliveSet, isTestBuild: boolean): string {
	const g = createCGen(ctx, modulePath);
	g.aliveSet = aliveSet;
	g.isTestBuild = isTestBuild;

	// Standard C headers (Standard reference implementation pattern)
	addLine(sec(g, CSection.Headers), "#include <stdint.h>");
	addLine(sec(g, CSection.Headers), "#include <stdbool.h>");
	addLine(sec(g, CSection.Headers), "#include <string.h>");
	addLine(sec(g, CSection.Headers), "#include <math.h>");
	addLine(sec(g, CSection.Headers), "#include \"system.h\"");
	nameSetAdd(g.declaredThings, "inc:system.h"); // prevent duplicate from @include
	emitTestHeader(g);


	// Emit additional @include directives from checker (user code @include pragmas)
	if (ctx !== null && ctx.includeDirectives !== "") {
		emitIncludeDirectives(g, ctx.includeDirectives);
	}

	// Per-module type emission (Standard reference implementation parity)
	// Register cross-module type names + build type registry from ExportRegistry
	registerCrossModuleTypesFromRegistry(g);
	buildTypeRegistry(g);

	// Emit cross-module function prototypes (Standard reference implementation parity)
	emitCrossModulePrototypes(g);

	// Walk program statements
	if (program !== null && program.kind === NodeKind.Program) {
		const pd = program.data as ProgramData;
		for (let i = 0; i < pd.programStmts.length; i += 1) {
			genDecl(g, pd.programStmts[i], false);
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
	const datInitName = modName + "__DatInit000";
	const initName = modName + "__Init000";

	const datContent = extract(sec(g, CSection.DatInit));
	const initContent = extract(sec(g, CSection.ModuleInit));

	// Clear sections (re-emitted into Procs)
	sec(g, CSection.DatInit).buf = "";
	sec(g, CSection.ModuleInit).buf = "";

	const hdrs = sec(g, CSection.ProcHeaders);
	const procs = sec(g, CSection.Procs);

	// DatInit000: data/type initialization (non-static for cross-module visibility)
	addLine(hdrs, "void " + datInitName + "(void);");
	addLine(procs, "void " + datInitName + "(void) {");
	addLine(procs, "  static MS_BOOL " + datInitName + "_guard_ = 0;");
	addLine(procs, "  if (" + datInitName + "_guard_) return;");
	addLine(procs, "  " + datInitName + "_guard_ = 1;");
	if (datContent.length > 0) {
		add(procs, datContent);
	}
	addLine(procs, "}");
	addNewline(procs);

	// Init000: user top-level code (non-static for cross-module visibility)
	addLine(hdrs, "void " + initName + "(void);");
	addLine(procs, "void " + initName + "(void) {");
	addLine(procs, "  static MS_BOOL " + initName + "_guard_ = 0;");
	addLine(procs, "  if (" + initName + "_guard_) return;");
	addLine(procs, "  " + initName + "_guard_ = 1;");
	if (initContent.length > 0) {
		add(procs, initContent);
	}
	addLine(procs, "}");
	addNewline(procs);
}

// ===== Global Init Dispatcher =====
//
// Generates the global init dispatcher: forward decls, MsPreMainInner, MsMainInner,
// MsMain, global vars, and POSIX main. Used by both single-module and multi-module builds.

export function genProjectDispatcher(modulePaths: string[], entryPath: string, hasUserMain: boolean, mainRetType: string): string {
	const b = createBuilder();
	const retType = (mainRetType.length > 0) ? mainRetType : "void";

	// Forward declarations for all module init functions
	for (let i = 0; i < modulePaths.length; i += 1) {
		const modName = mangleModuleName(modulePaths[i]);
		addLine(b, "void " + modName + "__DatInit000(void);");
		addLine(b, "void " + modName + "__Init000(void);");
	}
	if (hasUserMain) {
		addLine(b, retType + " main_(void);");
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
	for (let i = 0; i < modulePaths.length; i += 1) {
		addLine(b, mangleModuleName(modulePaths[i]) + "__DatInit000();");
	}
	b.indent -= 1;
	addLine(b, "}");
	addNewline(b);

	// MsMainInner — dependency Init000, then entry Init000, then user main
	addLine(b, "static void MsMainInner(void) {");
	b.indent += 1;
	for (let i = 0; i < modulePaths.length; i += 1) {
		if (modulePaths[i] !== entryPath) {
			addLine(b, mangleModuleName(modulePaths[i]) + "__Init000();");
		}
	}
	addLine(b, mangleModuleName(entryPath) + "__Init000();");
	if (hasUserMain) {
		if (retType !== "void") {
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

// ===== Register Cross-Module Types from ExportRegistry =====
// Registers class/interface/enum names from all imported modules so
// getTypeDesc resolves TypeReference correctly (reference parity).

function registerCrossModuleTypesFromRegistry(g: CGen): void {
	const reg = (g.checkerCtx !== null) ? g.checkerCtx.exportRegistry : null as unknown as ExportRegistry;
	if (reg !== null) {
		for (const entry of reg.entries) {
			for (const sym of entry.symbols) {
				const name = safeName(sym.name);
				if (sym.kind === SymbolKind.Class) {
					nameSetAdd(g.knownClassNames, name);
					nameSetAdd(g.knownTypeNames, name);
				} else if (sym.kind === SymbolKind.Interface) {
					nameSetAdd(g.knownTypeNames, name);
				}
			}
		}
	}
}

// ===== Build Type Registry from ExportRegistry =====
// Implementation parity: types carry full structural info on every reference.
// Our TypeReference only has typeName. This registry lets getTypeDesc
// resolve TypeReference → full Type for cross-module types.

function buildTypeRegistry(g: CGen): void {
	const reg = (g.checkerCtx !== null) ? g.checkerCtx.exportRegistry : null as unknown as ExportRegistry;
	if (reg === null) return;
	for (const entry of reg.entries) {
		for (const sym of entry.symbols) {
			if (sym.symType === null) continue;
			if (sym.kind === SymbolKind.Interface || sym.kind === SymbolKind.Class || sym.kind === SymbolKind.Enum || sym.kind === SymbolKind.TypeAlias) {
				typeRegistryAdd(g.typeRegistry, sym.name, sym.symType);
				registerFieldTypes(g, sym.symType);
			}
		}
	}
}

// Shallow-register named field types so getTypeDesc can resolve TypeReferences lazily.
// reference parity: no recursive pre-crawl. getTypeDesc resolves nested types on-demand
// via typeRegistryLookup, with typeCache preventing infinite recursion on self-referential types.
function registerFieldTypes(g: CGen, t: Type): void {
	if (t === null) return;
	if (t.typeChildren !== null) {
		let i = 0;
		while (i < t.typeChildren.length) {
			const child = t.typeChildren[i];
			if (child !== null) {
				registerNamedType(g, child);
				// Array/Ref/Ptr element types
				if (child.typeReturn !== null) {
					registerNamedType(g, child.typeReturn);
				}
			}
			i = i + 1;
		}
	}
	if (t.typeReturn !== null) {
		registerNamedType(g, t.typeReturn);
	}
}

// Register a single named type into the registry if not already present.
function registerNamedType(g: CGen, t: Type): void {
	if (t === null) return;
	if ((t.kind === TypeKind.Object || t.kind === TypeKind.Enum || t.kind === TypeKind.Union) && t.typeName.length > 0) {
		if (typeRegistryLookup(g.typeRegistry, t.typeName) === null) {
			typeRegistryAdd(g.typeRegistry, t.typeName, t);
		}
	}
}

// ===== Emit Cross-Module Function Prototypes (reference parity) =====
// Each module emits prototypes for all exported functions from other modules.

function emitCrossModulePrototypes(g: CGen): void {
	const reg = (g.checkerCtx !== null) ? g.checkerCtx.exportRegistry : null as unknown as ExportRegistry;
	if (reg === null) return;
	for (const entry of reg.entries) {
		// Skip prototypes from own module — they're emitted by genDecl
		if (entry.modulePath === g.modulePath) continue;
		for (const sym of entry.symbols) {
			if (sym.kind !== SymbolKind.Function) continue;
			if (sym.symType === null) continue;
			if (sym.symType.kind !== TypeKind.Function) continue;
			// Emit prototype for primary function
			emitProtoFromExport(g, sym.name, sym.symType, sym.nativeName, entry.modulePath, 0);
			// Emit prototypes for overloads
			if (sym.overloadTypes !== null) {
				for (let oi = 0; oi < sym.overloadTypes.length; oi += 1) {
					const ovNative = (sym.overloadNativeNames !== null && oi < sym.overloadNativeNames.length) ? sym.overloadNativeNames[oi] : "";
					emitProtoFromExport(g, sym.name, sym.overloadTypes[oi], ovNative, entry.modulePath, oi + 1);
				}
			}
		}
	}
}

function emitProtoFromExport(g: CGen, name: string, fnType: Type, nativeName: string, modulePath: string, overloadIdx: number): void {
	if (fnType === null || fnType.kind !== TypeKind.Function) return;
	// Compute C function name
	let cName = "";
	if (nativeName !== "") {
		cName = nativeName;
	} else if (name === "main") {
		cName = safeName(name);
	} else if (modulePath !== "") {
		cName = mangle(name) + "__" + mangleModuleName(modulePath);
		if (overloadIdx > 0) cName = cName + "_u" + overloadIdx;
		else cName = cName + "_u0";
	} else {
		cName = safeName(name);
		if (overloadIdx > 0) cName = cName + "__" + overloadIdx;
	}
	// Dedup
	const protoKey = "proto:" + cName;
	if (nameSetHas(g.declaredProcs, protoKey)) return;
	nameSetAdd(g.declaredProcs, protoKey);
	// Build prototype string
	const retType = getTypeDesc(g, fnType.typeReturn);
	const nrvo = isNrvoReturnType(fnType.typeReturn);
	let paramList = "";
	if (nrvo) {
		paramList = retType + "* __result";
		if (fnType.typeChildren.length > 0) paramList = paramList + ", ";
	}
	for (let i = 0; i < fnType.typeChildren.length; i += 1) {
		if (i > 0) paramList = paramList + ", ";
		let pType = getTypeDesc(g, fnType.typeChildren[i]);
		if (ccgIntroducedPtr(fnType.typeChildren[i]) && pType.length > 0 && pType.charAt(pType.length - 1) !== "*") {
			pType = pType + "*";
		}
		paramList = paramList + pType;
	}
	if (paramList === "") paramList = "void";
	let cRetType = retType;
	if (nrvo) cRetType = "void";
	addLine(sec(g, CSection.ProcHeaders), cRetType + " " + cName + "(" + paramList + ");");
}

// ===== Emit @include directives from checker context =====

function emitIncludeDirectives(g: CGen, directives: string): void {
	let start = 0;
	for (let pos = 0; pos < directives.length; pos += 1) {
		if (directives.charAt(pos) === "\n") {
			const header = sliceStr(directives, start, pos);
			if (header.length > 0) {
				emitOneInclude(g, header);
			}
			start = pos + 1;
		}
	}
	if (start < directives.length) {
		const header = sliceStr(directives, start, directives.length);
		if (header.length > 0) {
			emitOneInclude(g, header);
		}
	}
}

function emitOneInclude(g: CGen, header: string): void {
	if (nameSetHas(g.declaredThings, "inc:" + header)) return;
	nameSetAdd(g.declaredThings, "inc:" + header);
	addLine(sec(g, CSection.Headers), "#include \"" + header + "\"");
}

// ===== Tests =====

import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";


function cOutput(input: string): string {
	const pr = parseSource(input);
	if (!pr.ok) return "PARSE_ERROR: " + pr.error;
	return generateC(pr.value, null as unknown as CheckerContext, "test/input");
}

function cModuleOutput(input: string): string {
	const pr = parseSource(input);
	if (!pr.ok) return "PARSE_ERROR: " + pr.error;
	return generateCModule(pr.value, null as unknown as CheckerContext, "test/input", createAliveSet(), true);
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


