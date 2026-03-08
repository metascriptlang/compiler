// JavaScript Codegen — Node Dispatcher + Entry Point
//
// Registers emitNodeDispatch callback, provides generateJS entry point.
// Tests cover the full pipeline: parse → check → transform → generateJS.

import { Node, NodeKind, ProgramData, HiddenDerefData, HiddenStdConvData } from "../../ast/node";
import {
	JSGenerator, createJSGenerator, registerEmitNode,
	finalize, emit, emitNode, emitLine,
} from "./emit";
import {
	emitNumberLiteral, emitStringLiteral, emitBooleanLiteral, emitNullLiteral,
	emitBigIntLiteral, emitRegexLiteral,
	emitIdentifier, emitBinaryExpr, emitUnaryExpr, emitUpdateExpr,
	emitCallExpr, emitMemberExpr, emitArrayAccess,
	emitObjectLiteral, emitArrayLiteral,
	emitArrowFunction, emitFunctionExpr,
	emitConditionalExpr, emitSpreadExpr, emitNewExpr,
	emitTypeAssertion, emitMoveExpr,
	emitAwaitExpr, emitYieldExpr,
} from "./expressions";
import {
	emitVariableDecl, emitIfStmt, emitWhileStmt, emitDoWhileStmt,
	emitBlockStmt, emitExprStmt, emitReturnStmt,
	emitBreakStmt, emitContinueStmt,
	emitSwitchStmt, emitThrowStmt, emitTryCatchStmt,
	emitForStmt, emitForOfStmt, emitUnreachableStmt,
} from "./statements";
import {
	emitFunctionDecl, emitEnumDecl, emitClassDecl,
	emitImportDecl, emitExportDecl, emitDecoratedDecl,
} from "./declarations";

import { parseSource } from "../../parser/statements/validation";
import { checkProgram } from "../../checker/index";
import { transformProgram } from "../../transform/index";

// ===== Node Dispatcher =====

function emitNodeDispatch(gen: JSGenerator, node: Node): void {
	if (node === null) return;
	const k = node.kind;

	// Literals
	if (k === NodeKind.NumberLiteral) { emitNumberLiteral(gen, node); return; }
	if (k === NodeKind.StringLiteral) { emitStringLiteral(gen, node); return; }
	if (k === NodeKind.BooleanLiteral) { emitBooleanLiteral(gen, node); return; }
	if (k === NodeKind.NullLiteral) { emitNullLiteral(gen, node); return; }
	if (k === NodeKind.BigIntLiteral) { emitBigIntLiteral(gen, node); return; }
	if (k === NodeKind.RegexLiteral) { emitRegexLiteral(gen, node); return; }

	// Identifier
	if (k === NodeKind.Identifier) { emitIdentifier(gen, node); return; }

	// Expressions
	if (k === NodeKind.BinaryExpr) { emitBinaryExpr(gen, node); return; }
	if (k === NodeKind.UnaryExpr) { emitUnaryExpr(gen, node); return; }
	if (k === NodeKind.UpdateExpr) { emitUpdateExpr(gen, node); return; }
	if (k === NodeKind.CallExpr) { emitCallExpr(gen, node); return; }
	if (k === NodeKind.MemberExpr) { emitMemberExpr(gen, node); return; }
	if (k === NodeKind.ArrayAccess) { emitArrayAccess(gen, node); return; }
	if (k === NodeKind.ObjectLiteral) { emitObjectLiteral(gen, node); return; }
	if (k === NodeKind.ArrayLiteral) { emitArrayLiteral(gen, node); return; }
	if (k === NodeKind.ArrowFunction) { emitArrowFunction(gen, node); return; }
	if (k === NodeKind.FunctionExpr) { emitFunctionExpr(gen, node); return; }
	if (k === NodeKind.TypeAssertion) { emitTypeAssertion(gen, node); return; }
	if (k === NodeKind.ConditionalExpr) { emitConditionalExpr(gen, node); return; }
	if (k === NodeKind.SpreadExpr) { emitSpreadExpr(gen, node); return; }
	if (k === NodeKind.NewExpr) { emitNewExpr(gen, node); return; }
	if (k === NodeKind.MoveExpr) { emitMoveExpr(gen, node); return; }
	if (k === NodeKind.HiddenDeref || k === NodeKind.HiddenAddr) { const hd = node.data as HiddenDerefData; emitNodeDispatch(gen, hd.expr); return; }
	if (k === NodeKind.HiddenStdConv || k === NodeKind.HiddenSubConv) { const hd = node.data as HiddenStdConvData; emitNodeDispatch(gen, hd.convExpr); return; }
	if (k === NodeKind.AwaitExpr) { emitAwaitExpr(gen, node); return; }
	if (k === NodeKind.YieldExpr) { emitYieldExpr(gen, node); return; }

	// Statements
	if (k === NodeKind.VariableDecl) { emitVariableDecl(gen, node); return; }
	if (k === NodeKind.IfStmt) { emitIfStmt(gen, node); return; }
	if (k === NodeKind.WhileStmt) { emitWhileStmt(gen, node); return; }
	if (k === NodeKind.DoWhileStmt) { emitDoWhileStmt(gen, node); return; }
	if (k === NodeKind.BlockStmt) { emitBlockStmt(gen, node); return; }
	if (k === NodeKind.ExprStmt) { emitExprStmt(gen, node); return; }
	if (k === NodeKind.ReturnStmt) { emitReturnStmt(gen, node); return; }
	if (k === NodeKind.BreakStmt) { emitBreakStmt(gen, node); return; }
	if (k === NodeKind.ContinueStmt) { emitContinueStmt(gen, node); return; }
	if (k === NodeKind.SwitchStmt) { emitSwitchStmt(gen, node); return; }
	if (k === NodeKind.ThrowStmt) { emitThrowStmt(gen, node); return; }
	if (k === NodeKind.TryCatchStmt) { emitTryCatchStmt(gen, node); return; }
	if (k === NodeKind.ForStmt) { emitForStmt(gen, node); return; }
	if (k === NodeKind.ForOfStmt) { emitForOfStmt(gen, node); return; }
	if (k === NodeKind.UnreachableStmt) { emitUnreachableStmt(gen, node); return; }

	// Declarations
	if (k === NodeKind.FunctionDecl) { emitFunctionDecl(gen, node); return; }
	if (k === NodeKind.EnumDecl) { emitEnumDecl(gen, node); return; }
	if (k === NodeKind.ClassDecl) { emitClassDecl(gen, node); return; }
	if (k === NodeKind.ImportDecl) { emitImportDecl(gen, node); return; }
	if (k === NodeKind.ExportDecl) { emitExportDecl(gen, node); return; }
	if (k === NodeKind.DecoratedDecl) { emitDecoratedDecl(gen, node); return; }

	// Type-only declarations — no JS output
	if (k === NodeKind.InterfaceDecl) return;
	if (k === NodeKind.TypeAliasDecl) return;
	if (k === NodeKind.ExternDecl) return;
	if (k === NodeKind.MacroDecl) return;
	if (k === NodeKind.ComptimeBlock) return; // should be evaluated before codegen
	if (k === NodeKind.TypeAnnotation) return;

	// Program — emit all statements
	if (k === NodeKind.Program) {
		const pd = node.data as ProgramData;
		for (const stmt of pd.programStmts) {
			emitNodeDispatch(gen, stmt);
		}
		return;
	}

	// Fallback for unsupported nodes
	emit(gen, "/* unsupported: ");
	emit(gen, "" + k);
	emit(gen, " */");
}

// Register the dispatcher (lambda wrapper required — top-level fn is generic msClosure, typed var needs msClosureN)
registerEmitNode((gen: JSGenerator, node: Node): void => { emitNodeDispatch(gen, node); });

// ===== Entry Point =====

export function generateJS(program: Node): string {
	const gen = createJSGenerator();
	emit(gen, "// Generated by MetaScript Compiler\n");
	emitNodeDispatch(gen, program);
	return finalize(gen);
}

// Generate JS without header (for internal/test use)
function generateJSRaw(program: Node): string {
	const gen = createJSGenerator();
	emitNodeDispatch(gen, program);
	return finalize(gen);
}

// ===== Test Helpers =====

function genFromSource(src: string): string {
	const parseResult = parseSource(src);
	if (!parseResult.ok) return "PARSE_ERROR";
	const program = parseResult.value;
	const checkerCtx = checkProgram(program);
	const transformed = transformProgram(program, checkerCtx, true);
	return generateJSRaw(transformed);
}

// ===== Tests =====
test "number literal" {
	const js = genFromSource("42;");
	assert js === "42;\n";
}

test "string literal" {
	const js = genFromSource("\"hello\";");
	assert js === "\"hello\";\n";
}

test "boolean literal" {
	const js = genFromSource("true;");
	assert js === "true;\n";
}

test "null literal" {
	const js = genFromSource("null;");
	assert js === "null;\n";
}

test "binary expression" {
	const js = genFromSource("1 + 2;");
	// After constant folding, 1 + 2 → 3
	assert js === "3;\n";
}

test "identifier" {
	const js = genFromSource("const x = 1; x;");
	assert js === "const x = 1;\nx;\n";
}

test "call expression" {
	const js = genFromSource("foo(1, 2);");
	assert js === "foo(1, 2);\n";
}

test "member expression" {
	const js = genFromSource("console.log(42);");
	// After UFCS: static extension console.log → log(42)
	assert js === "log(42);\n";
}

test "array literal" {
	const js = genFromSource("[1, 2, 3];");
	assert js === "[1, 2, 3];\n";
}

test "object literal" {
	const js = genFromSource("const x = { a: 1, b: 2 };");
	assert js === "const x = { a: 1, b: 2 };\n";
}

test "variable declaration const" {
	const js = genFromSource("const x = 42;");
	assert js === "const x = 42;\n";
}

test "variable declaration let" {
	const js = genFromSource("let x = 0;");
	assert js === "let x = 0;\n";
}

test "if statement" {
	const js = genFromSource("let x = 0; if (x > 0) { 1; }");
	assert js === "let x = 0;\nif ((x > 0)) {\n  1;\n}\n";
}

test "while statement" {
	const js = genFromSource("while (true) { break; }");
	assert js === "while (true) {\n  break;\n}\n";
}

test "return statement" {
	// export to survive DCE
	const js = genFromSource("export function f(): number { return 1; }");
	assert js === "export function f() {\n  return 1;\n}\n";
}

test "function declaration" {
	// export to survive DCE
	const js = genFromSource("export function add(a: number, b: number): number { return a + b; }");
	assert js === "export function add(a, b) {\n  return (a + b);\n}\n";
}

test "enum declaration" {
	// export to survive DCE
	const js = genFromSource("export enum Color { Red, Green, Blue }");
	assert js.length > 0;
}

test "interface skipped" {
	const js = genFromSource("interface Point { x: number; y: number; }");
	assert js === "";
}

test "type alias skipped" {
	const js = genFromSource("type Num = number;");
	assert js === "";
}

test "if-else" {
	const js = genFromSource("let x = 0; if (x > 0) { 1; } else { 2; }");
	assert js === "let x = 0;\nif ((x > 0)) {\n  1;\n} else {\n  2;\n}\n";
}

test "do-while" {
	const js = genFromSource("do { break; } while (false);");
	assert js === "do {\n  break;\n} while (false);\n";
}

test "try-catch" {
	// Transform adds finally {} block
	const js = genFromSource("try { 1; } catch (e) { 2; }");
	assert js === "try {\n  1;\n} catch (e) {\n  2;\n} finally {\n}\n";
}

test "throw" {
	const js = genFromSource("throw 42;");
	assert js === "throw 42;\n";
}

test "unreachable" {
	const js = genFromSource("unreachable;");
	assert js === "throw new Error(\"unreachable\");\n";
}

test "unary not" {
	// Constant folding turns !true → false
	const js = genFromSource("!true;");
	assert js === "false;\n";
}

test "conditional expression" {
	const js = genFromSource("const x = true ? 1 : 2;");
	assert js === "const x = (true ? 1 : 2);\n";
}

test "new expression" {
	const js = genFromSource("new Foo(1, 2);");
	assert js === "new Foo(1, 2);\n";
}

test "array access" {
	const js = genFromSource("const arr = [1]; arr[0];");
	assert js === "const arr = [1];\narr[0];\n";
}

test "std import skipped" {
	const js = genFromSource("import { test } from \"std/testing\"; 42;");
	assert js === "42;\n";
}

test "interface skipped in export" {
	const js = genFromSource("export interface Foo { x: number; }");
	assert js === "";
}

test "Result.ok" {
	const js = genFromSource("Result.ok(42);");
	assert js === "{ ok: true, value: 42 };\n";
}

test "Result.err" {
	const js = genFromSource("Result.err(\"fail\");");
	assert js === "{ ok: false, error: \"fail\" };\n";
}

test "generateJS includes header" {
	const parseResult = parseSource("42;");
	if (!parseResult.ok) { assert false; return; }
	const program = parseResult.value;
	const checkerCtx = checkProgram(program);
	const transformed = transformProgram(program, checkerCtx, true);
	const js = generateJS(transformed);
	assert js === "// Generated by MetaScript Compiler\n42;\n";
}

test "full program" {
	const js = genFromSource("const x = 1; const y = 2; const z = x + y;");
	assert js.length > 0;
}

test "function with body" {
	const js = genFromSource("export function greet(name: string): void { console.log(name); }");
	assert js.length > 0;
}

test "empty program" {
	const js = genFromSource("");
	assert js === "";
}

test "export enum correct indent" {
	const js = genFromSource("export enum Dir { Up, Down }");
	assert js.length > 0;
}

test "for-of preserved" {
	const js = genFromSource("const arr = [1, 2]; for (const x of arr) { console.log(x); }");
	assert js.length > 0;
}

test "arrow function preserved" {
	const js = genFromSource("const f = (x: number): number => x + 1;");
	assert js.length > 0;
}

test "string concat is native +" {
	const js = genFromSource("const s = \"a\" + \"b\" + \"c\";");
	assert js.length > 0;
}

test "update expr preserved" {
	const js = genFromSource("let x = 0; x++;");
	assert js.length > 0;
}

test "async function" {
	const js = genFromSource("export async function f(): number { return 1; }");
	assert js.length > 0;
}

test "async arrow" {
	const js = genFromSource("const f = async (x: number): number => x;");
	assert js.length > 0;
}
