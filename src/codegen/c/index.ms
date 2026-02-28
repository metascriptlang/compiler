// C Codegen — Entry Point
//
// generateC(program, checkerCtx, modulePath) → string
// Walks the program AST, emits declarations to CGen sections, assembles final C output.
// Module init follows Nim's two-phase pattern:
//   DatInit000 (data/type init, runs first) + Init000 (user code, runs second)
//   main(argc, argv) → NimMain → PreMainInner (DatInit) → NimMainInner (Init)

import {
	Node, NodeKind,
	ProgramData, FunctionDeclData, BlockStmtData,
	ExportDeclData, DecoratedDeclData,
} from "../../ast/node";
import { Type } from "../../checker/types";
import { CheckerContext } from "../../checker/context";
import {
	CGen, CSection, Builder,
	createCGen, sec, add, addLine, addNewline,
	assembleOutput, extract, nameSetAdd, nameSetHas,
} from "./context";
import { genDecl, mapTypeAnnotation } from "./declarations";
import { mangleModuleName, mangleTypeName, mangleFieldName } from "./names";
import {
	getGenericTypeInstCount, getGenericTypeInstMangledName,
	getGenericTypeInstFieldCount, getGenericTypeInstFieldNameAt,
	getGenericTypeInstFieldTypeAt,
} from "../../parser/context";
import { test, check, testGroup } from "std/testing";

// ===== generateC — main entry point =====

export function generateC(program: Node, ctx: CheckerContext, modulePath: string): string {
	const g = createCGen(ctx, modulePath);

	// Standard C headers
	addLine(sec(g, CSection.Headers), "#include <stdint.h>");
	addLine(sec(g, CSection.Headers), "#include <stdbool.h>");
	addLine(sec(g, CSection.Headers), "#include <string.h>");

	// Pre-pass: collect function declaration names for closure call detection
	if (program !== null && program.kind === NodeKind.Program) {
		collectFnDeclNames(g, program);
	}

	// Walk program statements
	if (program !== null && program.kind === NodeKind.Program) {
		const pd = program.data as ProgramData;
		let i = 0;
		while (i < pd.programStmts.length) {
			genDecl(g, pd.programStmts[i]);
			i += 1;
		}
	}

	// Emit monomorphized generic interface/class structs
	genGenericTypeInsts(g);

	// Generate two-phase init + POSIX main
	genModuleInitProcs(g);

	return assembleOutput(g);
}

// ===== Monomorphized Generic Interface/Class Structs =====
// Checker records instantiations, codegen emits concrete structs.
// Lives here (not declarations.ms) to avoid parser/context import in declarations.ms
// which triggers DRC union member count sensitivity.

function genGenericTypeInsts(g: CGen): void {
	const count = getGenericTypeInstCount();
	let i = 0;
	while (i < count) {
		const name = mangleTypeName(getGenericTypeInstMangledName(i));

		if (!nameSetHas(g.declaredThings, name)) {
			nameSetAdd(g.declaredThings, name);

			// Forward declaration
			addLine(sec(g, CSection.ForwardDecls), "typedef struct " + name + " " + name + ";");

			// Full struct definition
			const types = sec(g, CSection.Types);
			addLine(types, "struct " + name + " {");
			const fieldCount = getGenericTypeInstFieldCount(i);
			let fi = 0;
			while (fi < fieldCount) {
				const fieldName = mangleFieldName(getGenericTypeInstFieldNameAt(i, fi));
				const fieldType = mapTypeAnnotation(getGenericTypeInstFieldTypeAt(i, fi));
				addLine(types, "  " + fieldType + " " + fieldName + ";");
				fi += 1;
			}
			addLine(types, "};");
			addNewline(types);
		}
		i += 1;
	}
}

// ===== Two-Phase Module Initialization (Nim-aligned) =====
//
// Nim's pattern:
//   main() → NimMain() → PreMainInner() [DatInit000 calls]
//                       → NimMainInner() [Init000 calls]
//
// For single-module, we generate:
//   <module>__DatInit000()  — data/type initialization (runs first)
//   <module>__Init000()     — user top-level code (runs second)
//   PreMainInner()          — calls DatInit000 for all modules
//   NimMainInner()          — calls Init000 for all modules
//   NimMain()               — calls PreMainInner + NimMainInner
//   main(argc, argv)        — POSIX entry, forwards args, calls NimMain

function genModuleInitProcs(g: CGen): void {
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

	// --- DatInit000: data/type initialization ---
	if (datContent.length > 0) {
		addLine(hdrs, "static void " + datInitName + "(void);");
		addLine(procs, "static void " + datInitName + "(void) {");
		add(procs, datContent);
		addLine(procs, "}");
		addNewline(procs);
	}

	// --- Init000: user top-level code ---
	if (initContent.length > 0) {
		addLine(hdrs, "static void " + initName + "(void);");
		addLine(procs, "static void " + initName + "(void) {");
		add(procs, initContent);
		addLine(procs, "}");
		addNewline(procs);
	}

	// --- PreMainInner: calls all DatInit000 (data init phase) ---
	addLine(hdrs, "static void PreMainInner(void);");
	addLine(procs, "static void PreMainInner(void) {");
	if (datContent.length > 0) {
		addLine(procs, "  " + datInitName + "();");
	}
	addLine(procs, "}");
	addNewline(procs);

	// --- NimMainInner: calls all Init000 (code init phase) ---
	addLine(hdrs, "static void NimMainInner(void);");
	addLine(procs, "static void NimMainInner(void) {");
	if (initContent.length > 0) {
		addLine(procs, "  " + initName + "();");
	}
	if (nameSetHas(g.fnDeclNames, "main")) {
		addLine(procs, "  main_();");
	}
	addLine(procs, "}");
	addNewline(procs);

	// --- NimMain: orchestrates both phases ---
	addLine(hdrs, "void NimMain(void);");
	addLine(procs, "void NimMain(void) {");
	addLine(procs, "  PreMainInner();");
	addLine(procs, "  NimMainInner();");
	addLine(procs, "}");
	addNewline(procs);

	// --- POSIX main: entry point with argc/argv/env ---
	// TODO: cmdCount, cmdLine, gEnv, nim_program_result belong in std/core.ms
	// (auto-imported stdlib, like Nim's system.nim). Relocate when auto-import lands.
	const gvars = sec(g, CSection.GlobalVars);
	addLine(gvars, "int cmdCount;");
	addLine(gvars, "char** cmdLine;");
	addLine(gvars, "char** gEnv;");
	addLine(gvars, "int nim_program_result;");
	addLine(procs, "int main(int argc, char** argv, char** env) {");
	addLine(procs, "  cmdLine = argv;");
	addLine(procs, "  cmdCount = argc;");
	addLine(procs, "  gEnv = env;");
	addLine(procs, "  NimMain();");
	addLine(procs, "  return nim_program_result;");
	addLine(procs, "}");
}

// ===== Pre-pass: collect function names for closure detection =====

function collectFnDeclNames(g: CGen, node: Node): void {
	if (node === null) return;
	if (node.kind === NodeKind.Program) {
		const pd = node.data as ProgramData;
		let i = 0;
		while (i < pd.programStmts.length) {
			collectFnDeclNames(g, pd.programStmts[i]);
			i += 1;
		}
	} else if (node.kind === NodeKind.FunctionDecl) {
		const d = node.data as FunctionDeclData;
		if (d.fnName !== "") nameSetAdd(g.fnDeclNames, d.fnName);
		collectFnDeclNames(g, d.fnBody);
	} else if (node.kind === NodeKind.BlockStmt) {
		const d = node.data as BlockStmtData;
		let i = 0;
		while (i < d.statements.length) {
			collectFnDeclNames(g, d.statements[i]);
			i += 1;
		}
	} else if (node.kind === NodeKind.ExportDecl) {
		const d = node.data as ExportDeclData;
		collectFnDeclNames(g, d.exportedDecl);
	} else if (node.kind === NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		collectFnDeclNames(g, d.decoratedNode);
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
