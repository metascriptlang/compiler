import { fullPipeline, findFnDecl } from "./helpers";
import { Node, NodeKind, TypeKind, FunctionDeclData, BlockStmtData, ReturnStmtData, NumberLiteralData, ProgramData, ClassDeclData, PropertyDeclData } from "../../ast/node";

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

test "module const handoff: a float32 const inlines as a float32 literal" {
	const value = foldedReturn("const STEP: float32 = 0.42; function read(): float32 { return STEP; }", "read");
	assert value != null && value.kind == NodeKind.NumberLiteral;
	assert value.nodeType != null && value.nodeType.kind == TypeKind.Float32;
}

test "module const handoff: float32 arithmetic is left to the backend" {
	const sum = foldedReturn("const A: float32 = 16777217.0; const B: float32 = 1.0; function read(): float32 { return A + B; }", "read");
	assert sum != null && sum.kind == NodeKind.BinaryExpr;
	const product = foldedReturn("const A: float32 = 0.42; function read(): float64 { return A * 3.0; }", "read");
	assert product != null && product.kind == NodeKind.BinaryExpr;
}

test "module const handoff: a float32 value read as float64 is not retyped" {
	const value = foldedReturn("const STEP: float32 = 0.42; const WIDE: float64 = STEP; function read(): float64 { return WIDE; }", "read");
	assert value != null && value.kind == NodeKind.Identifier;
	const source = "const STEP: float32 = 0.42; class K { static readonly WIDE: float64 = STEP; } function read(): float64 { return K.WIDE; }";
	assert keepsStaticStorage(source, "K", "WIDE");
}

test "module const handoff: a readonly bool static a static block assigns is not folded" {
	const source = "class K { static readonly on: boolean = false; static { K.on = true; } } function read(): boolean { return K.on; }";
	assert keepsStaticStorage(source, "K", "on");
	const value = foldedReturn(source, "read");
	assert value == null || value.kind != NodeKind.BooleanLiteral;
}

function foldedValue(source: string): number {
	const value = foldedReturn(source, "read");
	if (value == null || value.kind != NodeKind.NumberLiteral) return -1.5;
	return (value.data as NumberLiteralData).value;
}

function foldedInteger(source: string): int64 {
	const value = foldedReturn(source, "read");
	if (value == null || value.kind != NodeKind.NumberLiteral || (value.data as NumberLiteralData).isFloat) return -77;
	return (value.data as NumberLiteralData).intVal;
}

test "module const handoff: a 64-bit integer constant converted to float32 rounds once" {
	assert foldedValue("const I: int64 = 1152921573326323713; const F = I as float32; function read(): float32 { return F; }") == 1152921642045800448.0;
	assert foldedValue("const I: int64 = -1152921573326323713; const F = I as float32; function read(): float32 { return F; }") == -1152921642045800448.0;
	assert foldedValue("const U: uint64 = 1152921573326323713; const F = U as float32; function read(): float32 { return F; }") == 1152921642045800448.0;
	assert foldedValue("const U: uint64 = 9223372586610589697; const F = U as float32; function read(): float32 { return F; }") == 9223373136366403584.0;
	assert foldedValue("const F = 1152921573326323713 as float32; function read(): float32 { return F; }") == 1152921642045800448.0;
	assert foldedValue("const I: int64 = 1152921573326323712; const F = I as float32; function read(): float32 { return F; }") == 1152921504606846976.0;
}

test "module const handoff: a float constant converted to an integer folds to its truncation" {
	assert foldedInteger("const S: int32 = 3.9 as int32; function read(): int32 { return S; }") == 3;
	assert foldedInteger("const S: int8 = (-128.9) as int8; function read(): int8 { return S; }") == -128;
	assert foldedInteger("const S: uint8 = 255.9 as uint8; function read(): uint8 { return S; }") == 255;
	assert foldedInteger("const S: uint8 = (-0.5) as uint8; function read(): uint8 { return S; }") == 0;
	assert foldedInteger("const K: number = 70000.5; const S: uint16 = (K - 10000.0) as uint16; function read(): uint16 { return S; }") == 60000;
	assert foldedInteger("const S: uint64 = 18446744073709549568.0 as uint64; function read(): uint64 { return S; }") == -2048;
	assert foldedInteger("const F: float32 = 16777217.0 as float32; const S: int32 = F as int32; function read(): int32 { return S; }") == 16777216;
}
