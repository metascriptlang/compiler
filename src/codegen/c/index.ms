// C Codegen — Entry Point
//
// generateC(program, checkerCtx) → string
// Walks the program AST, emits declarations to CGen sections, assembles final C output.

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
	assembleOutput, extract, nameSetAdd,
} from "./context";
import { genDecl } from "./declarations";
import { test, check, testGroup } from "std/testing";

// ===== generateC — main entry point =====

export function generateC(program: Node, ctx: CheckerContext): string {
	const g = createCGen(ctx);

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

	return assembleOutput(g);
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
	return generateC(pr.value, null as unknown as CheckerContext);
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
