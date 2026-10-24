import { findFnDecl } from "./helpers";
import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { checkProgramWithRegistry, preludeContextFor } from "../../checker/checkPass";
import { ExportRegistry } from "../../checker/context";
import { monomorphizeProgram } from "../../monomorphize/collect";
import { validateTypedAST } from "../../checker/validate";
import { transformProgram } from "../../transform/index";
import { transformForNative } from "../../transform/native/index";
import { createTransformContextWithChecker } from "../../transform/context";
import { Node, NodeKind, FunctionDeclData, BlockStmtData, ExprStmtData, ReturnStmtData, CallExprData, IdentifierData } from "../../ast/node";
import { Module, ModuleGraph } from "../../module/graph";
import { resetBuildState } from "../../compiler/buildSession";
import { SymbolFlag, hasFlag } from "../../checker/symbol";

function lowered(source: string, rangeChecks: boolean): Node {
	resetBuildState();
	const prelude = preludeContextFor("", ".cms");
	const pr = parseSource(source);
	if (!pr.ok) throw new Error("probe does not parse: " + source);
	const ctx = checkProgramWithRegistry(pr.value, null as unknown as ExportRegistry, null as unknown as ModuleGraph, null as unknown as Module, prelude);
	const monoed = monomorphizeProgram(pr.value, ctx);
	validateTypedAST(ctx, monoed);
	const transformed = transformProgram(monoed, ctx, false);
	const nativeCtx = createTransformContextWithChecker(ctx);
	nativeCtx.rangeChecks = rangeChecks;
	return transformForNative(transformed, nativeCtx);
}

function probeCall(source: string, rangeChecks: boolean): CallExprData {
	const fn = findFnDecl(lowered(source, rangeChecks), "probe");
	if (fn == null) throw new Error("probe is not a top-level function: " + source);
	const body = (fn.data as FunctionDeclData).fnBody;
	let value: Node | null = null;
	for (const s of (body.data as BlockStmtData).statements) {
		if (s.kind == NodeKind.ReturnStmt) value = (s.data as ReturnStmtData).argument;
		else if (s.kind == NodeKind.ExprStmt) value = (s.data as ExprStmtData).expr;
	}
	if (value == null || value.kind != NodeKind.CallExpr) throw new Error("probe does not end in a call: " + source);
	return value.data as CallExprData;
}

function calleeName(call: CallExprData): string {
	if (call.callee.kind != NodeKind.Identifier) throw new Error("probe callee is not a name");
	return (call.callee.data as IdentifierData).name;
}

function isStdFunction(call: CallExprData): boolean {
	const sym = call.callee.resolvedSym;
	return sym != null && !hasFlag(sym, SymbolFlag.ImportC);
}

const WIDTHS = ["int8", "int16", "int32", "int64", "uint8", "uint16", "uint32", "uint64"];
const SUFFIXES = ["I8", "I16", "I32", "I64", "U8", "U16", "U32", "U64"];

test "an integer power reaches a std function written in MetaScript, not a C helper" {
	for (const t of ["int32", "int64", "uint32", "uint64"]) {
		const call = probeCall(`function probe(a: ${t}, b: ${t}): ${t} { return a ** b; }`, true);
		assert isStdFunction(call), t;
	}
}

test "a power assignment reaches an own-width std function on every integer width" {
	for (let w = 0; w < WIDTHS.length; w += 1) {
		const call = probeCall(`function probe(a: ${WIDTHS[w]}, b: ${WIDTHS[w]}): void { let x = a; x **= b; }`, true);
		assert calleeName(call) == "msPowAssign" + SUFFIXES[w], WIDTHS[w];
		assert isStdFunction(call), WIDTHS[w];
	}
}

test "a danger power and power assignment reach the wrapping std functions" {
	const power = ["msPowWrapI32", "msPowWrapI64", "msPowWrapU32", "msPowWrapU64"];
	const powerTypes = ["int32", "int64", "uint32", "uint64"];
	for (let i = 0; i < powerTypes.length; i += 1) {
		const t = powerTypes[i];
		const call = probeCall(`function probe(a: ${t}, b: ${t}): ${t} { return a ** b; }`, false);
		assert calleeName(call) == power[i], t;
		assert isStdFunction(call), t;
	}
	for (let w = 0; w < WIDTHS.length; w += 1) {
		const call = probeCall(`function probe(a: ${WIDTHS[w]}, b: ${WIDTHS[w]}): void { let x = a; x **= b; }`, false);
		assert calleeName(call) == "msPowWrapAssign" + SUFFIXES[w], WIDTHS[w];
		assert isStdFunction(call), WIDTHS[w];
	}
}
