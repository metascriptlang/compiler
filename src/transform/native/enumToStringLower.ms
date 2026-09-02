// Enum ToString Lowering — inject FunctionDecl for each EnumDecl
//
// Standard reference implementations generate enum-to-string procs in the semantic phase.
// We inject a synthetic FunctionDecl with a SwitchStmt body into the program statements.
// Codegen then sees a normal FunctionDecl and emits it.
//
// Primary path: extract enum info from checker's symbol table (post-DCE safe).
// Fallback path: walk AST programStmts (for tests without checker context).

import { Node, NodeKind, ProgramData, EnumDeclData, ExportDeclData, TypeKind, SymbolKind } from "../../ast/node";
import { TransformContext, NameSet, createNameSet, nameSetContains, nameSetAdd } from "../context";
import {
	makeSwitch, makeSwitchCase, makeReturn, makeString, makeNumber,
	makeIdent, makeBlock, makeFnDecl, enumToStringName, enumToStringNameFor,
} from "../util";
import { createEnum, stringType, createFunction } from "../../checker/types";
import { SourceLocation, makeLoc } from "../../ast/node";

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

// fnName comes from the caller: the checker-owned Type (module-qualified, the
// spelling every lowering site emits) or the bare name on the ctx-less fallback.
function makeEnumToString(fnName: string, enumName: string, members: string[], loc: SourceLocation): Node {
	const cases: Node[] = [];
	let i = 0;
	while (i < members.length) {
		const retStmt = makeReturn(makeString(members[i], loc), loc);
		cases.push(makeSwitchCase([makeNumber(i, loc)], [retStmt], false, loc));
		i = i + 1;
	}
	// Default case: return "<unknown>"
	cases.push(makeSwitchCase([], [makeReturn(makeString("<unknown>", loc), loc)], true, loc));

	const switchStmt = makeSwitch(makeIdent("v", loc), cases, loc);
	const body = makeBlock([switchStmt], loc);
	const fn = makeFnDecl(fnName, ["v"], ["int32"], body, "", "string", loc);
	// Override nodeType with proper enum param type
	fn.nodeType = createFunction([createEnum(enumName, members, null as unknown as number[])], ["v"], stringType());
	return fn;
}

function getEnumFromStmt(stmt: Node): Node {
	if (stmt === null) return null as unknown as Node;
	if (stmt.kind === NodeKind.EnumDecl) return stmt;
	if (stmt.kind === NodeKind.ExportDecl) {
		const d = stmt.data as ExportDeclData;
		if (d.exportedDecl !== null && d.exportedDecl.kind === NodeKind.EnumDecl) {
			return d.exportedDecl;
		}
	}
	return null as unknown as Node;
}

// ===== Tests =====


import { createNode } from "../../ast/node";
import { createToken, TokenKind } from "../../lexer/token";

function makeTestEnum(name: string, members: string[]): Node {
	const tok = createToken(TokenKind.Ident, name, 1);
	return createNode(NodeKind.EnumDecl, { enumName: name, enumMembers: members, nameLocation: makeLoc(1, 1), memberLocations: [] }, tok);
}

function makeTestProgram(stmts: Node[]): Node {
	const tok = createToken(TokenKind.Ident, "test", 1);
	return createNode(NodeKind.Program, { programStmts: stmts }, tok);
}

test "enum toString injects FunctionDecl" {
	const enumNode = makeTestEnum("Color", ["Red", "Green", "Blue"]);
	const prog = makeTestProgram([enumNode]);
	const pd = prog.data as ProgramData;
	assert pd.programStmts.length === 1;
	const result = lowerEnumToString(prog, null as unknown as TransformContext);
	const rd = result.data as ProgramData;
	assert rd.programStmts.length === 2;
	assert rd.programStmts[1].kind === NodeKind.FunctionDecl;
}

test "enum toString body has switch" {
	const enumNode = makeTestEnum("Dir", ["N", "S"]);
	const prog = makeTestProgram([enumNode]);
	const result = lowerEnumToString(prog, null as unknown as TransformContext);
	const rd = result.data as ProgramData;
	const fn = rd.programStmts[1];
	assert fn.kind === NodeKind.FunctionDecl;
	assert fn.nodeType !== null;
}

import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { generateCModule } from "../../codegen/c/index";
import { CheckerContext } from "../../checker/context";
import { createAliveSet } from "../../codegen/c/context";
import { FunctionDeclData } from "../../ast/node";

test "enum toString E2E: parse → transform → codegen" {
	const pr = parseSource("enum Color { Red, Green, Blue }");
	assert pr.ok;
	const transformed = lowerEnumToString(pr.value, null as unknown as TransformContext);
	const td = transformed.data as ProgramData;
	// Verify transform injected FunctionDecl
	assert td.programStmts.length === 2;
	assert td.programStmts[0].kind === NodeKind.EnumDecl;
	assert td.programStmts[1].kind === NodeKind.FunctionDecl;
	const fd = td.programStmts[1].data as FunctionDeclData;
	assert fd.fnName === "Color_toString";
	// Generate C — should include the toString function
	const cCode = generateCModule(transformed, null as unknown as CheckerContext, "test/input", createAliveSet(), true, false);
	assert cCode.length > 50;
}

export function lowerEnumToString(program: Node, ctx: TransformContext): Node {
	if (program === null || program.kind !== NodeKind.Program) return program;
	const pd = program.data as ProgramData;

	// Primary path: extract enums from checker's symbol table (DCE-safe).
	// Walk all scopes from current up to global — user enums are typically
	// in the module scope (table.current), not the root global scope.
	if (ctx !== null && ctx.checkerCtx !== null && ctx.checkerCtx.table !== null) {
		const toStringFns: Node[] = [];
		const injected: NameSet = createNameSet();
		// Scope scan — C only. Each module is its own translation unit there, so
		// injecting every enum in scope costs a few unreferenced statics and
		// covers any lowering site that forgets to request. The JS bundle is ONE
		// flat scope: the same scan walks the scope chain into the prelude and
		// re-emits its whole enum set once per module (measured: 55 defs, 20+
		// copies of JsonKind_toString for a 3-member user enum). JS therefore
		// injects exactly what the lowering sites requested below — the request
		// list is complete, every site calls requestEnumToString.
		if (!ctx.jsBackend) {
			let scope = ctx.checkerCtx.table.current;
			while (scope !== null) {
				for (const sym of scope.symbols.values()) {
					if (sym.symbolKind === SymbolKind.Enum && sym.symbolType !== null && sym.symbolType.kind === TypeKind.Enum) {
						const t = sym.symbolType;
						if (nameSetContains(injected, t.typeName)) continue;
						nameSetAdd(injected, t.typeName);
						toStringFns.push(makeEnumToString(enumToStringNameFor(t), t.typeName, t.typeNames, sym.location));
					}
				}
				scope = scope.parent;
			}
		}
		// Lowering sites (builtinLower/debugLower) request enums that are not in
		// module scope — e.g. reached only through an imported field's type.
		for (const t of ctx.checkerCtx.pendingEnumToStrings) {
			if (t.kind !== TypeKind.Enum || nameSetContains(injected, t.typeName)) continue;
			nameSetAdd(injected, t.typeName);
			toStringFns.push(makeEnumToString(enumToStringNameFor(t), t.typeName, t.typeNames, program.location));
		}
		ctx.checkerCtx.pendingEnumToStrings = [];
		// Append to program stmts via return-value move (avoids local array aliasing)
		program.data = { programStmts: concatStmts(pd.programStmts, toStringFns) };
		return program;
	}

	// Fallback: walk programStmts (test mode without checker context)
	const newStmts: Node[] = [];
	let i = 0;
	while (i < pd.programStmts.length) {
		const stmt = pd.programStmts[i];
		newStmts.push(stmt);

		const enumNode = getEnumFromStmt(stmt);
		if (enumNode !== null) {
			const d = enumNode.data as EnumDeclData;
			const loc = enumNode.location;
			const toStringFn = makeEnumToString(enumToStringName(d.enumName), d.enumName, d.enumMembers, loc);
			newStmts.push(toStringFn);
		}
		i = i + 1;
	}

	program.data = { programStmts: newStmts };
	return program;
}
