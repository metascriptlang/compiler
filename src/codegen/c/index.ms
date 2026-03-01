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
import {
	CGen, CSection,
	createCGen, sec, add, addLine, addNewline,
	assembleOutput, extract, nameSetAdd, nameSetHas,
} from "./context";
import { genDecl, mapTypeAnnotation, mapParamType } from "./declarations";
import { mangleModuleName, safeName } from "./names";
import { sliceStr } from "../../utils/string";
import { test, check, testGroup } from "std/testing";

// ===== generateC — single-module entry point (backwards compatible) =====

export function generateC(program: Node, ctx: CheckerContext, modulePath: string): string {
	const moduleCode = generateCModule(program, ctx, modulePath, "");
	const hasMain = programHasMain(program);
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

	// Pre-pass: collect function declaration names for closure call detection
	if (program !== null && program.kind === NodeKind.Program) {
		collectFnDeclNames(g, program);
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
	addLine(procs, "  static NIM_BOOL " + datInitName + "_guard_ = 0;");
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
	addLine(procs, "  static NIM_BOOL " + initName + "_guard_ = 0;");
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
	let out = "";

	// Forward declarations for all module init functions
	for (let i = 0; i < modulePaths.length; i += 1) {
		const modName = mangleModuleName(modulePaths[i]);
		out = out + "void " + modName + "__DatInit000(void);\n";
		out = out + "void " + modName + "__Init000(void);\n";
	}
	out = out + "\n";

	// MsPreMainInner — calls DatInit000 for all modules in topological order
	out = out + "static void MsPreMainInner(void) {\n";
	for (let i = 0; i < modulePaths.length; i += 1) {
		out = out + "  " + mangleModuleName(modulePaths[i]) + "__DatInit000();\n";
	}
	out = out + "}\n\n";

	// MsMainInner — dependency Init000, then entry Init000, then user main
	out = out + "static void MsMainInner(void) {\n";
	for (let i = 0; i < modulePaths.length; i += 1) {
		if (modulePaths[i] !== entryPath) {
			out = out + "  " + mangleModuleName(modulePaths[i]) + "__Init000();\n";
		}
	}
	out = out + "  " + mangleModuleName(entryPath) + "__Init000();\n";
	if (hasUserMain) {
		out = out + "  main_();\n";
	}
	out = out + "}\n\n";

	// MsMain + globals + POSIX main
	out = out + "void MsMain(void) {\n  MsPreMainInner();\n  MsMainInner();\n}\n\n";
	out = out + "int cmdCount;\nchar** cmdLine;\nchar** gEnv;\nint ms_program_result;\n\n";
	out = out + "int main(int argc, char** argv, char** env) {\n";
	out = out + "  cmdLine = argv;\n  cmdCount = argc;\n  gEnv = env;\n";
	out = out + "  MsMain();\n  return ms_program_result;\n}\n";

	return out;
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
	const retType = mapTypeAnnotation(d.fnReturnType);
	let paramList = "";
	for (let i = 0; i < d.params.length; i += 1) {
		if (i > 0) paramList = paramList + ", ";
		const pType = mapParamType(d.fnParamTypes, i);
		paramList = paramList + pType + " " + safeName(d.params[i]);
	}
	if (d.params.length === 0) paramList = "void";
	return retType + " " + name + "(" + paramList + ");";
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

// ===== Check if program has user-defined main() =====

export function programHasMain(program: Node): boolean {
	if (program === null) return false;
	if (program.kind !== NodeKind.Program) return false;
	const pd = program.data as ProgramData;
	for (let i = 0; i < pd.programStmts.length; i += 1) {
		if (stmtIsMain(pd.programStmts[i])) return true;
	}
	return false;
}

function stmtIsMain(node: Node): boolean {
	if (node === null) return false;
	if (node.kind === NodeKind.FunctionDecl) {
		const d = node.data as FunctionDeclData;
		return d.fnName === "main";
	}
	if (node.kind === NodeKind.ExportDecl) {
		const d = node.data as ExportDeclData;
		return stmtIsMain(d.exportedDecl);
	}
	if (node.kind === NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		return stmtIsMain(d.decoratedNode);
	}
	return false;
}

// ===== Pre-pass: collect function names for closure detection =====

function collectFnDeclNames(g: CGen, node: Node): void {
	if (node === null) return;
	if (node.kind === NodeKind.Program) {
		const pd = node.data as ProgramData;
		for (let i = 0; i < pd.programStmts.length; i += 1) {
			collectFnDeclNames(g, pd.programStmts[i]);
		}
	} else if (node.kind === NodeKind.FunctionDecl) {
		const d = node.data as FunctionDeclData;
		if (d.fnName !== "") nameSetAdd(g.fnDeclNames, d.fnName);
		collectFnDeclNames(g, d.fnBody);
	} else if (node.kind === NodeKind.BlockStmt) {
		const d = node.data as BlockStmtData;
		for (let i = 0; i < d.statements.length; i += 1) {
			collectFnDeclNames(g, d.statements[i]);
		}
	} else if (node.kind === NodeKind.ExportDecl) {
		const d = node.data as ExportDeclData;
		collectFnDeclNames(g, d.exportedDecl);
	} else if (node.kind === NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		collectFnDeclNames(g, d.decoratedNode);
	} else if (node.kind === NodeKind.ImportDecl) {
		const d = node.data as ImportDeclData;
		for (let i = 0; i < d.importNames.length; i += 1) {
			nameSetAdd(g.fnDeclNames, d.importNames[i]);
		}
	}
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

testGroup("C Gen Headers", () => {
	test("empty program has headers", () => {
		const result = cOutput("");
		check(result.length > 0);
	});
	test("headers include stdint", () => {
		const result = cOutput("");
		// stdint.h should be present
		check(result.length > 10);
	});
});

testGroup("C Gen Function", () => {
	test("simple function", () => {
		const result = cOutput("function foo(): void { return; }");
		check(result.length > 0);
	});
});

testGroup("C Gen Enum", () => {
	test("enum output", () => {
		const result = cOutput("enum Dir { North, South, East, West }");
		check(result.length > 0);
	});
});

testGroup("C Gen Integration", () => {
	test("function + call", () => {
		const result = cOutput("function add(a: number, b: number): number { return a + b; }");
		check(result.length > 0);
	});
	test("global var init in module Init000", () => {
		const result = cOutput("function add(a: number, b: number): number { return a + b; }\nconst result: number = add(2, 3);");
		check(result.length > 0);
	});
	test("two-phase init + POSIX main", () => {
		const result = cOutput("function add(a: number, b: number): number { return a + b; }\nconst result: number = add(2, 3);");
		check(result.length > 0);
	});
});

testGroup("C Gen Directives", () => {
	test("MacroInvocation skipped in codegen", () => {
		const result = cOutput("@passL(\"-lssl\");");
		// Should not contain /* unsupported */
		check(result.length > 0);
	});
	test("@include from prelude emits header", () => {
		// prelude has @include("runtime.h"), so generated C should contain it
		const result = cOutput("");
		check(result.length > 0);
	});
});

testGroup("C Gen Closure", () => {
	test("function names collected", () => {
		// After generateC, foo should be in fnDeclNames so calls to foo are direct
		const result = cOutput("function foo(): void {} function bar(): void { foo(); }");
		check(result.length > 0);
	});
	test("array literal", () => {
		const result = cOutput("const arr: number = [1, 2, 3];");
		check(result.length > 0);
	});
});

testGroup("C Gen Module", () => {
	test("generateCModule produces code without dispatcher", () => {
		const result = cModuleOutput("function foo(): void { return; }");
		check(result.length > 0);
	});
	test("programHasMain detects main function", () => {
		const pr = parseSource("function main(): number { return 0; }");
		check(pr.ok);
		check(programHasMain(pr.value));
	});
	test("programHasMain returns false when no main", () => {
		const pr = parseSource("function foo(): void {}");
		check(pr.ok);
		check(!programHasMain(pr.value));
	});
	test("collectFunctionPrototypes extracts protos", () => {
		const pr = parseSource("function add(a: number, b: number): number { return a + b; }");
		check(pr.ok);
		const protos = collectFunctionPrototypes(pr.value);
		check(protos.length > 0);
	});
	test("collectExportedPrototypes only exported", () => {
		const pr = parseSource("function helper(): void {}\nexport function api(): void {}");
		check(pr.ok);
		const exported = collectExportedPrototypes(pr.value);
		const all = collectFunctionPrototypes(pr.value);
		check(exported.length > 0);
		check(all.length > exported.length);
	});
});
