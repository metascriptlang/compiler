import { fullPipeline, findFnDecl } from "./helpers";
import { Node, NodeKind, FunctionDeclData, BlockStmtData, ReturnStmtData, NumberLiteralData, ProgramData, ClassDeclData, PropertyDeclData } from "../../ast/node";

function foldedReturn(source: string, name: string): Node | null {
	const program = fullPipeline(source);
	const fn = findFnDecl(program, name);
	if (fn == null) return null;
	const body = (fn.data as FunctionDeclData).fnBody;
	if (body.kind != NodeKind.BlockStmt) return null;
	const statements = (body.data as BlockStmtData).statements;
	if (statements.length != 1 || statements[0].kind != NodeKind.ReturnStmt) return null;
	return (statements[0].data as ReturnStmtData).argument;
}

test "module const handoff: a scalar chain becomes one literal" {
	const value = foldedReturn("const ONE: int32 = 1 << 16; const STEP: int32 = ONE / 8; function read(): int32 { return STEP + 1; }", "read");
	assert value != null && value.kind == NodeKind.NumberLiteral;
	assert (value.data as NumberLiteralData).intVal == 8193;
}

test "module const handoff: an enum cast becomes one literal" {
	const value = foldedReturn("enum Level { Whole, Half } const STEP: int32 = (Level.Whole as int32) + 1; function read(): int32 { return STEP; }", "read");
	assert value != null && value.kind == NodeKind.NumberLiteral;
	assert (value.data as NumberLiteralData).intVal == 1;
}

test "module const handoff: a readonly scalar static is inlined without storage" {
	const source = "class Knobs { static readonly VALUE: int32 = 7; } function read(): int32 { return Knobs.VALUE; }";
	const program = fullPipeline(source);
	const value = foldedReturn(source, "read");
	assert value != null && value.kind == NodeKind.NumberLiteral;
	assert (value.data as NumberLiteralData).intVal == 7;
	for (const stmt of (program.data as ProgramData).programStmts) {
		if (stmt.kind != NodeKind.ClassDecl) continue;
		for (const member of (stmt.data as ClassDeclData).classBody) {
			if (member.kind != NodeKind.PropertyDecl) continue;
			assert (member.data as PropertyDeclData).propName != "VALUE";
		}
	}
}

function keepsStaticStorage(source: string, owner: string, name: string): boolean {
	const program = fullPipeline(source);
	for (const stmt of (program.data as ProgramData).programStmts) {
		if (stmt.kind != NodeKind.ClassDecl || (stmt.data as ClassDeclData).className != owner) continue;
		for (const member of (stmt.data as ClassDeclData).classBody) {
			if (member.kind == NodeKind.PropertyDecl && (member.data as PropertyDeclData).propName == name) return true;
		}
	}
	return false;
}

test "module const handoff: a readonly static a static block assigns keeps its storage" {
	const source = "class K { static readonly frozen: int32 = 0; static { K.frozen = 7; } } function read(): int32 { return K.frozen; }";
	assert keepsStaticStorage(source, "K", "frozen");
	const value = foldedReturn(source, "read");
	assert value == null || value.kind != NodeKind.NumberLiteral;
}

test "module const handoff: a readonly bool static a static block assigns is not folded" {
	const source = "class K { static readonly on: boolean = false; static { K.on = true; } } function read(): boolean { return K.on; }";
	assert keepsStaticStorage(source, "K", "on");
	const value = foldedReturn(source, "read");
	assert value == null || value.kind != NodeKind.BooleanLiteral;
}
