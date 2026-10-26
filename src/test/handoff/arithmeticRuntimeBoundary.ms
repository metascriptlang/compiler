import { fullPipeline, findFnDecl } from "./helpers";
import { Node, NodeKind, FunctionDeclData, BlockStmtData, ReturnStmtData, ExprStmtData, CallExprData, IdentifierData } from "../../ast/node";
import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { checkProgramWithRegistry, preludeContextFor } from "../../checker/checkPass";
import { ExportRegistry } from "../../checker/context";
import { monomorphizeProgram } from "../../monomorphize/collect";
import { validateTypedAST } from "../../checker/validate";
import { transformProgram } from "../../transform/index";
import { transformForNative } from "../../transform/native/index";
import { createTransformContextWithChecker } from "../../transform/context";
import { Module, ModuleGraph } from "../../module/graph";
import { resetBuildState } from "../../compiler/buildSession";
import { SymbolFlag, hasFlag } from "../../checker/symbol";

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

function lastStatementValue(source: string): Node | null {
	const fn = findFnDecl(fullPipeline(source), "probe");
	if (fn == null) return null;
	const body = (fn.data as FunctionDeclData).fnBody;
	if (body.kind != NodeKind.BlockStmt) return null;
	let last: Node | null = null;
	for (const statement of (body.data as BlockStmtData).statements) {
		if (statement.kind == NodeKind.ExprStmt) last = (statement.data as ExprStmtData).expr;
	}
	return last;
}

function runtimeCallee(value: Node | null): string {
	if (value == null || value.kind != NodeKind.CallExpr) return "";
	const call = value.data as CallExprData;
	if (call.callee.kind != NodeKind.Identifier) return "";
	return (call.callee.data as IdentifierData).name;
}

test "constant folding leaves overflowing typed integer addition to the checked runtime add" {
	assert runtimeCallee(returnValue("const HIGH: int32 = 2147483647; function probe(): int32 { return HIGH + 1; }")) == "msAddI32";
}

test "constant folding leaves an int32 cast operand sum past the range to the checked runtime add" {
	assert runtimeCallee(returnValue("function probe(): int32 { return (2147483647 as int32) + 1; }")) == "msAddI32";
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
		{ source: "function probe(a: int8, b: int8): int8 { return a / b; }", runtime: "msDivI8", arity: 2 },
		{ source: "function probe(a: int16, b: int16): int16 { return a ** b; }", runtime: "msPowI16", arity: 2 },
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

struct OverflowSite {
	declare: string;
	place: string;
}

test "signed + - * and unary minus reach the own-width overflow check on a local, a field and an element" {
	const widths = ["int8", "int16", "int32", "int64"];
	const suffixes = ["I8", "I16", "I32", "I64"];
	const ops = ["+", "-", "*"];
	const prefixes = ["msAdd", "msSub", "msMul"];
	const sites: OverflowSite[] = [
		{ declare: "let x = a;", place: "x" },
		{ declare: "const b = new Box(); b.v = a;", place: "b.v" },
		{ declare: "const xs = [a];", place: "xs[0]" },
	];
	for (let w = 0; w < widths.length; w += 1) {
		const head = `class Box { v: ${widths[w]} = 0; } function probe(a: ${widths[w]}, k: ${widths[w]}): ${widths[w]} { `;
		for (const site of sites) {
			for (let o = 0; o < ops.length; o += 1) {
				const source = head + `${site.declare} return ${site.place} ${ops[o]} k; }`;
				assert runtimeCallee(returnValue(source)) == prefixes[o] + suffixes[w], source;
			}
			const negated = head + `${site.declare} return -${site.place}; }`;
			assert runtimeCallee(returnValue(negated)) == "msNeg" + suffixes[w], negated;
		}
	}
}

test "signed compound assignment and steps reach the checked in-place helpers on a local, a field and an element" {
	const forms = ["+= k", "-= k", "*= k", "++", "--"];
	const helpers = ["msAddAssign", "msSubAssign", "msMulAssign", "msAddAssign", "msSubAssign"];
	const sites: OverflowSite[] = [
		{ declare: "let x = a;", place: "x" },
		{ declare: "const b = new Box(); b.v = a;", place: "b.v" },
		{ declare: "const xs = [a];", place: "xs[0]" },
	];
	for (const width of ["int8", "int16", "int32", "int64"]) {
		const head = `class Box { v: ${width} = 0; } function probe(a: ${width}, k: ${width}): void { `;
		for (const site of sites) {
			for (let f = 0; f < forms.length; f += 1) {
				const source = head + `${site.declare} ${site.place} ${forms[f]}; }`;
				assert runtimeCallee(lastStatementValue(source)) == helpers[f], source;
			}
			const prefixed = head + `${site.declare} ++${site.place}; }`;
			assert runtimeCallee(lastStatementValue(prefixed)) == "msAddAssign", prefixed;
		}
	}
}

test "signed power assignment reaches the own-width checked helper on a local, a field and an element" {
	const sites: OverflowSite[] = [
		{ declare: "let x = a;", place: "x" },
		{ declare: "const b = new Box(); b.v = a;", place: "b.v" },
		{ declare: "const xs = [a];", place: "xs[0]" },
	];
	const widths = ["int8", "int16", "int32", "int64"];
	const suffixes = ["I8", "I16", "I32", "I64"];
	for (let w = 0; w < widths.length; w += 1) {
		const head = `class Box { v: ${widths[w]} = 0; } function probe(a: ${widths[w]}, k: ${widths[w]}): void { `;
		for (const site of sites) {
			const source = head + `${site.declare} ${site.place} **= k; }`;
			assert runtimeCallee(lastStatementValue(source)) == "msPowAssign" + suffixes[w], source;
		}
	}
}

test "unsigned arithmetic and a negated literal keep their operators" {
	assert runtimeCallee(returnValue("function probe(a: uint32, b: uint32): uint32 { return a + b; }")) == "";
	assert runtimeCallee(lastStatementValue("function probe(a: uint8): void { let x = a; x++; }")) == "";
	assert runtimeCallee(returnValue("function probe(): int32 { return -5; }")) == "";
}

test "a pointer difference keeps its operator" {
	assert runtimeCallee(returnValue("function probe(p: Ptr<int64>, q: Ptr<int64>): int32 { return q - p; }")) == "";
	assert runtimeCallee(returnValue("struct Pair { left: int32; right: int32; } function probe(p: Ptr<Pair>, q: Ptr<Pair>): int32 { return q - p; }")) == "";
	assert runtimeCallee(returnValue("function probe(p: Ptr<uint8>, n: int32): int32 { return ((p + n) - p) * n; }")) == "msMulI32";
}

function loweredWithRangeChecks(source: string, rangeChecks: boolean): Node {
	resetBuildState();
	const prelude = preludeContextFor("", ".cms");
	const pr = parseSource(source);
	if (!pr.ok) throw new Error("probe does not parse: " + source);
	const ctx = checkProgramWithRegistry(
		pr.value,
		null as unknown as ExportRegistry,
		null as unknown as ModuleGraph,
		null as unknown as Module,
		prelude,
	);
	const monoed = monomorphizeProgram(pr.value, ctx);
	validateTypedAST(ctx, monoed);
	const transformed = transformProgram(monoed, ctx, false);
	const nativeCtx = createTransformContextWithChecker(ctx);
	nativeCtx.rangeChecks = rangeChecks;
	return transformForNative(transformed, nativeCtx);
}

function probeCall(source: string, rangeChecks: boolean): CallExprData {
	const fn = findFnDecl(loweredWithRangeChecks(source, rangeChecks), "probe");
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
const POWER_WIDTHS = ["int32", "int64", "uint32", "uint64"];
const POWER_SUFFIXES = ["I32", "I64", "U32", "U64"];

function powerSource(t: string): string {
	return `function probe(a: ${t}, b: ${t}): ${t} { return a ** b; }`;
}

function powerAssignSource(t: string): string {
	return `function probe(a: ${t}, b: ${t}): void { let x = a; x **= b; }`;
}

test "an integer power reaches a std function written in MetaScript, not a C helper" {
	for (const t of POWER_WIDTHS) {
		assert isStdFunction(probeCall(powerSource(t), true)), t;
	}
}

test "a power assignment reaches an own-width std function on every integer width" {
	for (let w = 0; w < WIDTHS.length; w += 1) {
		const call = probeCall(powerAssignSource(WIDTHS[w]), true);
		assert calleeName(call) == "msPowAssign" + SUFFIXES[w], WIDTHS[w];
		assert isStdFunction(call), WIDTHS[w];
	}
}

test "a danger power reaches the wrapping std function of its width" {
	for (let w = 0; w < POWER_WIDTHS.length; w += 1) {
		const call = probeCall(powerSource(POWER_WIDTHS[w]), false);
		assert calleeName(call) == "msPowWrap" + POWER_SUFFIXES[w], POWER_WIDTHS[w];
		assert isStdFunction(call), POWER_WIDTHS[w];
	}
}

test "a danger power assignment reaches the wrapping std function on every integer width" {
	for (let w = 0; w < WIDTHS.length; w += 1) {
		const call = probeCall(powerAssignSource(WIDTHS[w]), false);
		assert calleeName(call) == "msPowWrapAssign" + SUFFIXES[w], WIDTHS[w];
		assert isStdFunction(call), WIDTHS[w];
	}
}
