// Enum ToString Lowering — inject FunctionDecl for each EnumDecl
//
// Standard reference implementations generate enum-to-string procs in the semantic phase.
// We inject a synthetic FunctionDecl with a SwitchStmt body into the program statements.
// Codegen then sees a normal FunctionDecl and emits it.
//
// Enum info comes from the checker's symbol table (post-DCE safe).

import { Node, NodeKind, ProgramData, Type, TypeKind, Symbol, SymbolKind } from "../../ast/node";
import { TransformContext, stampLoweredSym, createTransformContextWithChecker } from "../context";
import {
	makeSwitch, makeSwitchCase, makeReturn, makeString, makeNumber,
	makeTypedIdentResolved, makeBlock, makeFnDecl, declaredEnums,
} from "../util";
import { makeSymbol } from "../../checker/symbol";
import { createEnum, stringType, createFunction } from "../../checker/types";
import { SourceLocation, makeLoc, AttachedOp } from "../../ast/node";
import { requireOpByKey } from "../../codegen/c/types";

// Helper: concat two Node arrays — returns new array (moved, not destroyed)
function concatStmts(a: Node[], b: Node[]): Node[] {
	const result: Node[] = [];
	for (const s of a) { result.push(s); }
	for (const s of b) { result.push(s); }
	return result;
}

// Build a toString FunctionDecl for an enum:
//   function EnumName_toString(v: int32): string {
//     switch (v) { case 0: return "Member0"; ... default: return "<unknown>"; }
//   }

function makeEnumToString(ctx: TransformContext, fnSym: Symbol | null, fnName: string, enumType: Type, loc: SourceLocation): Node {
	const members = enumType.typeNames;
	const values = enumType.typeChildren;
	const cases: Node[] = [];
	let i = 0;
	while (i < members.length) {
		const retStmt = makeReturn(makeString(members[i], loc), loc);
		const value = values != null && i < values.length ? values[i].typeValue : i;
		cases.push(makeSwitchCase([makeNumber(value, loc)], [retStmt], false, loc));
		i = i + 1;
	}
	// Default case: return "<unknown>"
	cases.push(makeSwitchCase([], [makeReturn(makeString("<unknown>", loc), loc)], true, loc));

	const valueSym = stampLoweredSym(ctx, makeSymbol("v", SymbolKind.Parameter, enumType, false));
	const switchStmt = makeSwitch(makeTypedIdentResolved(valueSym, null, loc), cases, loc);
	const body = makeBlock([switchStmt], loc);
	const fn = makeFnDecl(fnSym != null ? fnSym.name : fnName, [valueSym], ["int32"], body, "", "string", loc);
	// Override nodeType with proper enum param type
	fn.nodeType = createFunction([enumType], [valueSym.name], stringType());
	if (fnSym != null) fn.resolvedSym = fnSym;
	return fn;
}

// ===== Tests =====


import { checkProgram } from "../../checker/checkPass";

function loweredEnums(source: string): { program: Node, checker: CheckerContext } {
	const pr = parseSource(source);
	if (!pr.ok) throw new Error(`enum test source failed to parse: ${source}`);
	const checker = checkProgram(pr.value);
	return { program: lowerEnumToString(pr.value, createTransformContextWithChecker(checker)), checker };
}

test "enum toString injects a typed FunctionDecl after the enum" {
	const rd = loweredEnums("enum Color { Red, Green, Blue }").program.data as ProgramData;
	assert rd.programStmts.length == 2;
	assert rd.programStmts[1].kind == NodeKind.FunctionDecl && rd.programStmts[1].nodeType != null;
}

import { BlockStmtData, SwitchStmtData, SwitchCaseData, NumberLiteralData } from "../../ast/node";

test "enum toString labels each case with the member's value" {
	const fn = makeEnumToString(createTransformContextWithChecker(createContext()), null, "Code_toString", createEnum("Code", ["Ok", "Bad"], [5, 9]), makeLoc(1, 1));
	const body = (fn.data as FunctionDeclData).fnBody.data as BlockStmtData;
	const cases = (body.statements[0].data as SwitchStmtData).switchCases;
	assert ((cases[0].data as SwitchCaseData).caseTests[0].data as NumberLiteralData).value == 5;
	assert ((cases[1].data as SwitchCaseData).caseTests[0].data as NumberLiteralData).value == 9;
}

import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { generateCModule } from "../../codegen/c/index";
import { CheckerContext, createContext } from "../../checker/context";
import { createAliveSet } from "../../codegen/c/context";
import { FunctionDeclData } from "../../ast/node";

test "enum toString E2E: parse → check → transform → codegen" {
	const lowered = loweredEnums("enum Color { Red, Green, Blue }");
	const td = lowered.program.data as ProgramData;
	assert td.programStmts.length == 2;
	assert td.programStmts[0].kind == NodeKind.EnumDecl;
	assert td.programStmts[1].kind == NodeKind.FunctionDecl;
	const cCode = generateCModule(lowered.program, lowered.checker, "test/input", createAliveSet(), true, false);
	assert cCode.includes("Color"), cCode;
}

export function lowerEnumToString(program: Node, ctx: TransformContext): Node {
	if (program == null || program.kind != NodeKind.Program) return program;
	const pd = program.data as ProgramData;

	if (ctx != null && ctx.checkerCtx != null && ctx.checkerCtx.table != null) {
		const toStringFns: Node[] = [];
		if (!ctx.jsBackend) {
			for (const t of declaredEnums(program)) {
				const op = requireOpByKey(t, AttachedOp.AttachedToString);
				toStringFns.push(makeEnumToString(ctx, op, op.name, t, program.location));
			}
		} else {
			const injected = new HashSet<Symbol>();
			for (const req of ctx.jsEnumToStrings) {
				const t = req.enumType;
				if (t.kind != TypeKind.Enum) continue;
				if (t.sym == null) throw new Error(`internal: enum '${t.typeName}' reached toString lowering without its declaration`);
				if (injected.has(t.sym)) continue;
				injected.add(t.sym);
				toStringFns.push(makeEnumToString(ctx, req.fnSym, req.fnSym.name, t, program.location));
			}
			ctx.jsEnumToStrings = [];
		}
		// Append to program stmts via return-value move (avoids local array aliasing)
		program.data = { programStmts: concatStmts(pd.programStmts, toStringFns) };
		return program;
	}

	throw new Error("internal: enum toString lowering runs without a checker context");
}
