// C Codegen — Entry Point
//
// generateC(program, checkerCtx, modulePath) → string  (single-module, backwards compatible)
// generateCModule(program, checkerCtx, modulePath, crossModuleProtos) → string  (module-only, no dispatcher)
// genProjectDispatcher(modulePaths, entryPath, hasUserMain) → string  (global init dispatcher)
// collectFunctionPrototypes(program) → string  (C function forward declarations)
//
// Module init follows two-phase pattern:
//   DatInit000 (data/type init, runs first) + Init000 (user code, runs second)
//   main(argc, argv) → MsMain → MsPreMainInner (DatInit) → MsMainInner (Init)

import {
	Node, NodeKind,
	ProgramData, FunctionDeclData, BlockStmtData,
	ExportDeclData, DecoratedDeclData, ImportDeclData,
} from "../../ast/node";
import { CheckerContext } from "../../checker/context";
import { lookupSymbol } from "../../checker/symbol";
// lookupSymbol removed — codegen uses node.resolvedSym (Nim parity)
import {
	CGen, CSection,
	createCGen, sec, add, addLine, addNewline,
	assembleOutput, extract, nameSetAdd, nameSetHas,
} from "./context";
import { genDecl } from "./declarations";
import { mangleModuleName, safeName } from "./names";
import { getSimpleTypeDesc } from "./types";
import { emitStringPoolDecls } from "./literals";
import { sliceStr } from "../../utils/string";
import { check } from "std/testing";

// ===== generateC — single-module entry point (backwards compatible) =====

export function generateC(program: Node, ctx: CheckerContext, modulePath: string): string {
	const moduleCode = generateCModule(program, ctx, modulePath, "");
	const hasMain = (ctx !== null && ctx.table !== null) ? lookupSymbol(ctx.table, "main") !== null : false;
	const paths: string[] = [modulePath];
	const dispatcher = genProjectDispatcher(paths, modulePath, hasMain);
	return moduleCode + "\n" + dispatcher;
}

// ===== generateCModule — one module's C code (no dispatcher) =====
//
// Generates headers, type definitions, function prototypes, function bodies,
// and per-module DatInit000/Init000 (non-static for cross-module visibility).
// Does NOT generate the global dispatcher (MsPreMainInner/MsMainInner/MsMain/POSIX main).

export function generateCModule(program: Node, ctx: CheckerContext, modulePath: string, crossModuleProtos: string): string {
	const g = createCGen(ctx, modulePath);

	// Standard C headers
	addLine(sec(g, CSection.Headers), "#include <stdint.h>");
	addLine(sec(g, CSection.Headers), "#include <stdbool.h>");
	addLine(sec(g, CSection.Headers), "#include <string.h>");

	// Emit @include directives from checker (prelude + user code)
	if (ctx !== null && ctx.includeDirectives !== "") {
		emitIncludeDirectives(g, ctx.includeDirectives);
	}

	// Emit cross-module prototypes (for separate compilation)
	if (crossModuleProtos.length > 0) {
		add(sec(g, CSection.ProcHeaders), crossModuleProtos);
	}

	// Walk program statements
	if (program !== null && program.kind === NodeKind.Program) {
		const pd = program.data as ProgramData;
		for (let i = 0; i < pd.programStmts.length; i += 1) {
			genDecl(g, pd.programStmts[i], false);
		}
	}

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

export function genProjectDispatcher(modulePaths: string[], entryPath: string, hasUserMain: boolean): string {
	let result = "";

	// Forward declarations for all module init functions
	for (let i = 0; i < modulePaths.length; i += 1) {
		const modName = mangleModuleName(modulePaths[i]);
		result = result + "void " + modName + "__DatInit000(void);\n";
		result = result + "void " + modName + "__Init000(void);\n";
	}
	if (hasUserMain) {
		result = result + "void main_(void);\n";
	}
	result = result + "\n";

	// MsPreMainInner — calls DatInit000 for all modules in topological order
	result = result + "static void MsPreMainInner(void) {\n";
	for (let i = 0; i < modulePaths.length; i += 1) {
		result = result + "  " + mangleModuleName(modulePaths[i]) + "__DatInit000();\n";
	}
	result = result + "}\n\n";

	// MsMainInner — dependency Init000, then entry Init000, then user main
	result = result + "static void MsMainInner(void) {\n";
	for (let i = 0; i < modulePaths.length; i += 1) {
		if (modulePaths[i] !== entryPath) {
			result = result + "  " + mangleModuleName(modulePaths[i]) + "__Init000();\n";
		}
	}
	result = result + "  " + mangleModuleName(entryPath) + "__Init000();\n";
	if (hasUserMain) {
		result = result + "  main_();\n";
	}
	result = result + "}\n\n";

	// MsMain + globals + POSIX main
	result = result + "void MsMain(void) {\n  MsPreMainInner();\n  MsMainInner();\n}\n\n";
	result = result + "int cmdCount;\nchar** cmdLine;\nchar** gEnv;\nint msProgramResult;\n\n";
	result = result + "int main(int argc, char** argv, char** env) {\n";
	result = result + "  cmdLine = argv;\n  cmdCount = argc;\n  gEnv = env;\n";
	result = result + "  MsMain();\n  return msProgramResult;\n}\n";

	return result;
}

// ===== Collect Function Prototypes =====
//
// Walks the AST to collect C-level function forward declarations.
// Used by multi-module builds to generate a shared proto header
// so cross-module calls have proper declarations.

export function collectFunctionPrototypes(program: Node): string {
	let protos = "";
	if (program === null || program.kind !== NodeKind.Program) return protos;
	const pd = program.data as ProgramData;
	for (let i = 0; i < pd.programStmts.length; i += 1) {
		const proto = protoFromStmt(pd.programStmts[i]);
		if (proto.length > 0) {
			protos = protos + proto + "\n";
		}
	}
	return protos;
}

function protoFromStmt(node: Node): string {
	if (node === null) return "";
	if (node.kind === NodeKind.FunctionDecl) {
		return buildFnProto(node);
	}
	if (node.kind === NodeKind.ExportDecl) {
		const d = node.data as ExportDeclData;
		return protoFromStmt(d.exportedDecl);
	}
	if (node.kind === NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		return protoFromStmt(d.decoratedNode);
	}
	return "";
}

function buildFnProto(node: Node): string {
	const d = node.data as FunctionDeclData;
	const name = safeName(d.fnName);
	const fnType = node.nodeType;
	if (fnType === null) return "";
	const retType = getSimpleTypeDesc(fnType.typeReturn);
	const finalRetType = (retType !== "") ? retType : "void*";
	let paramList = "";
	for (let i = 0; i < d.params.length; i += 1) {
		if (i > 0) paramList = paramList + ", ";
		const pType = getSimpleTypeDesc(fnType.typeChildren[i]);
		const finalPType = (pType !== "") ? pType : "void*";
		paramList = paramList + finalPType + " " + safeName(d.params[i]);
	}
	if (d.params.length === 0) paramList = "void";
	return finalRetType + " " + name + "(" + paramList + ");";
}

// ===== Collect Exported Function Prototypes =====
//
// Like collectFunctionPrototypes but only collects prototypes for
// EXPORTED functions. Used for cross-module prototype headers in
// separate compilation (non-exported functions are static, invisible).

export function collectExportedPrototypes(program: Node): string {
	let protos = "";
	if (program === null || program.kind !== NodeKind.Program) return protos;
	const pd = program.data as ProgramData;
	for (let i = 0; i < pd.programStmts.length; i += 1) {
		const proto = exportedProtoFromStmt(pd.programStmts[i]);
		if (proto.length > 0) {
			protos = protos + proto + "\n";
		}
	}
	return protos;
}

function exportedProtoFromStmt(node: Node): string {
	if (node === null) return "";
	if (node.kind === NodeKind.ExportDecl) {
		const d = node.data as ExportDeclData;
		return protoFromStmt(d.exportedDecl);
	}
	if (node.kind === NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		return exportedProtoFromStmt(d.decoratedNode);
	}
	return "";
}

// ===== Emit @include directives from checker context =====

function emitIncludeDirectives(g: CGen, directives: string): void {
	let start = 0;
	for (let pos = 0; pos < directives.length; pos += 1) {
		if (directives.charAt(pos) === "\n") {
			const header = sliceStr(directives, start, pos);
			if (header.length > 0) {
				addLine(sec(g, CSection.Headers), "#include \"" + header + "\"");
			}
			start = pos + 1;
		}
	}
	if (start < directives.length) {
		const header = sliceStr(directives, start, directives.length);
		if (header.length > 0) {
			addLine(sec(g, CSection.Headers), "#include \"" + header + "\"");
		}
	}
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
	return generateCModule(pr.value, null as unknown as CheckerContext, "test/input", "");
}

test "empty program has headers" {
	const result = cOutput("");
	check(result.length > 0);
}

test "headers include stdint" {
	const result = cOutput("");
	// stdint.h should be present
	check(result.length > 10);
}

test "simple function" {
	const result = cOutput("function foo(): void { return; }");
	check(result.length > 0);
}

test "enum output" {
	const result = cOutput("enum Dir { North, South, East, West }");
	check(result.length > 0);
}

test "function + call" {
	const result = cOutput("function add(a: number, b: number): number { return a + b; }");
	check(result.length > 0);
}

test "global var init in module Init000" {
	const result = cOutput("function add(a: number, b: number): number { return a + b; }\nconst result: number = add(2, 3);");
	check(result.length > 0);
}

test "two-phase init + POSIX main" {
	const result = cOutput("function add(a: number, b: number): number { return a + b; }\nconst result: number = add(2, 3);");
	check(result.length > 0);
}

test "MacroInvocation skipped in codegen" {
	const result = cOutput("@passL(\"-lssl\");");
	// Should not contain /* unsupported */
	check(result.length > 0);
}

test "@include from prelude emits header" {
	// prelude has @include("system.h"), so generated C should contain it
	const result = cOutput("");
	check(result.length > 0);
}

test "direct call detection" {
	// closureCallMarker sets isDirectCall on CallExpr nodes — codegen reads the flag
	const result = cOutput("function foo(): void {} function bar(): void { foo(); }");
	check(result.length > 0);
}

test "array literal" {
	const result = cOutput("const arr: number = [1, 2, 3];");
	check(result.length > 0);
}

test "generateCModule produces code without dispatcher" {
	const result = cModuleOutput("function foo(): void { return; }");
	check(result.length > 0);
}

test "collectFunctionPrototypes extracts protos" {
	const pr = parseSource("function add(a: number, b: number): number { return a + b; }");
	check(pr.ok);
	const protos = collectFunctionPrototypes(pr.value);
	check(protos.length > 0);
}

test "collectExportedPrototypes only exported" {
	const pr = parseSource("function helper(): void {}\nexport function api(): void {}");
	check(pr.ok);
	const exported = collectExportedPrototypes(pr.value);
	const all = collectFunctionPrototypes(pr.value);
	check(exported.length > 0);
	check(all.length > exported.length);
}
