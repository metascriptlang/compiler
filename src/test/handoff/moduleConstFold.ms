import { fullPipeline, findFnDecl } from "./helpers";
import { Node, NodeKind, FunctionDeclData, BlockStmtData, ReturnStmtData, NumberLiteralData } from "../../ast/node";

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
