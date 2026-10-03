import { fullPipeline, findFnDecl } from "./helpers";
import { Node, NodeKind, FunctionDeclData, BlockStmtData, ReturnStmtData, BinaryExprData, CallExprData, IdentifierData } from "../../ast/node";

function returnValue(source: string): Node | null {
	const fn = findFnDecl(fullPipeline(source), "probe");
	if (fn == null) return null;
	const body = (fn.data as FunctionDeclData).fnBody;
	if (body.kind != NodeKind.BlockStmt) return null;
	for (const statement of (body.data as BlockStmtData).statements) {
		if (statement.kind == NodeKind.ReturnStmt) return (statement.data as ReturnStmtData).argument;
	}
	return null;
}

test "constant folding leaves overflowing typed integer addition for runtime semantics" {
	const value = returnValue("const HIGH: int32 = 2147483647; function probe(): int32 { return HIGH + 1; }");
	assert value != null && value.kind == NodeKind.BinaryExpr;
	assert (value.data as BinaryExprData).operator == "+";
}

test "constant folding leaves an int32 cast operand sum past the range for runtime semantics" {
	const value = returnValue("function probe(): int32 { return (2147483647 as int32) + 1; }");
	assert value != null && value.kind == NodeKind.BinaryExpr;
	assert (value.data as BinaryExprData).operator == "+";
}

test "the minimum integer remainder by negative one retains its checked runtime operation" {
	const value = returnValue("const LOW: int32 = -2147483648; function probe(): int32 { return LOW % -1; }");
	assert value != null && value.kind == NodeKind.CallExpr;
	const call = value.data as CallExprData;
	assert call.callee.kind == NodeKind.Identifier;
	assert (call.callee.data as IdentifierData).name == "msModI32";
	assert call.arguments.length == 2;
}

struct CheckedOperation {
	source: string;
	runtime: string;
	arity: int32;
}

test "integer fault boundaries reach the width-specific runtime ABI" {
	const cases: CheckedOperation[] = [
		{ source: "function probe(a: int32, b: int32): int32 { return a / b; }", runtime: "msDivI32", arity: 2 },
		{ source: "function probe(a: int32): int32 { return a / -1; }", runtime: "msDivI32", arity: 2 },
		{ source: "function probe(a: int64, b: int64): int64 { return a % b; }", runtime: "msModI64", arity: 2 },
		{ source: "function probe(a: int64, b: int64): int64 { return a ** b; }", runtime: "msPowI64", arity: 2 },
		{ source: "function probe(a: float64): int64 { return a as int64; }", runtime: "msCheckRangeI64", arity: 1 },
		{ source: "function probe(a: float64): int32 { return a as int32; }", runtime: "msCheckRangeI32", arity: 3 },
	];
	for (const c of cases) {
		const value = returnValue(c.source);
		assert value != null && value.kind == NodeKind.CallExpr, c.source;
		const call = value.data as CallExprData;
		assert call.callee.kind == NodeKind.Identifier, c.source;
		assert (call.callee.data as IdentifierData).name == c.runtime, c.source;
		assert call.arguments.length == c.arity, c.source;
	}
}
