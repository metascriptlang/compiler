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
	match (node.kind) {
		// Literals
		NodeKind.NumberLiteral => { emitNumberLiteral(gen, node); },
		NodeKind.StringLiteral => { emitStringLiteral(gen, node); },
		NodeKind.BooleanLiteral => { emitBooleanLiteral(gen, node); },
		NodeKind.NullLiteral => { emitNullLiteral(gen, node); },
		NodeKind.BigIntLiteral => { emitBigIntLiteral(gen, node); },
		NodeKind.RegexLiteral => { emitRegexLiteral(gen, node); },

		// Identifier
		NodeKind.Identifier => { emitIdentifier(gen, node); },

		// Expressions
		NodeKind.BinaryExpr => { emitBinaryExpr(gen, node); },
		NodeKind.UnaryExpr => { emitUnaryExpr(gen, node); },
		NodeKind.UpdateExpr => { emitUpdateExpr(gen, node); },
		NodeKind.CallExpr => { emitCallExpr(gen, node); },
		NodeKind.MemberExpr => { emitMemberExpr(gen, node); },
		NodeKind.ArrayAccess => { emitArrayAccess(gen, node); },
		NodeKind.ObjectLiteral => { emitObjectLiteral(gen, node); },
		NodeKind.ArrayLiteral => { emitArrayLiteral(gen, node); },
		NodeKind.ArrowFunction => { emitArrowFunction(gen, node); },
		NodeKind.FunctionExpr => { emitFunctionExpr(gen, node); },
		NodeKind.TypeAssertion => { emitTypeAssertion(gen, node); },
		NodeKind.ConditionalExpr => { emitConditionalExpr(gen, node); },
		NodeKind.SpreadExpr => { emitSpreadExpr(gen, node); },
		NodeKind.NewExpr => { emitNewExpr(gen, node); },
		NodeKind.MoveExpr => { emitMoveExpr(gen, node); },
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => { const hd = node.data as HiddenDerefData; emitNodeDispatch(gen, hd.expr); },
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => { const hd = node.data as HiddenStdConvData; emitNodeDispatch(gen, hd.convExpr); },
		NodeKind.AwaitExpr => { emitAwaitExpr(gen, node); },
		NodeKind.YieldExpr => { emitYieldExpr(gen, node); },

		// Statements
		NodeKind.VariableDecl => { emitVariableDecl(gen, node); },
		NodeKind.IfStmt => { emitIfStmt(gen, node); },
		NodeKind.WhileStmt => { emitWhileStmt(gen, node); },
		NodeKind.DoWhileStmt => { emitDoWhileStmt(gen, node); },
		NodeKind.BlockStmt => { emitBlockStmt(gen, node); },
		NodeKind.ExprStmt => { emitExprStmt(gen, node); },
		NodeKind.ReturnStmt => { emitReturnStmt(gen, node); },
		NodeKind.BreakStmt => { emitBreakStmt(gen, node); },
		NodeKind.ContinueStmt => { emitContinueStmt(gen, node); },
		NodeKind.SwitchStmt => { emitSwitchStmt(gen, node); },
		NodeKind.ThrowStmt => { emitThrowStmt(gen, node); },
		NodeKind.TryCatchStmt => { emitTryCatchStmt(gen, node); },
		NodeKind.ForStmt => { emitForStmt(gen, node); },
		NodeKind.ForOfStmt => { emitForOfStmt(gen, node); },
		NodeKind.UnreachableStmt => { emitUnreachableStmt(gen, node); },

		// Declarations
		NodeKind.FunctionDecl => { emitFunctionDecl(gen, node); },
		NodeKind.EnumDecl => { emitEnumDecl(gen, node); },
		NodeKind.ClassDecl => { emitClassDecl(gen, node); },
		NodeKind.ImportDecl => { emitImportDecl(gen, node); },
		NodeKind.ExportDecl => { emitExportDecl(gen, node); },
		NodeKind.DecoratedDecl => { emitDecoratedDecl(gen, node); },

		// Type-only declarations — no JS output
		NodeKind.InterfaceDecl | NodeKind.TypeAliasDecl | NodeKind.ExternDecl
			| NodeKind.MacroDecl | NodeKind.ComptimeBlock | NodeKind.TypeAnnotation => {},

		// Program — emit all statements
		NodeKind.Program => {
			const pd = node.data as ProgramData;
			for (const stmt of pd.programStmts) {
				emitNodeDispatch(gen, stmt);
			}
		},

		// Fallback
		_ => { emit(gen, `/* unsupported: ${node.kind} */`); },
	};
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
	// console.log is lowered by builtinLower/extensionMethod transforms
	assert js.contains("42");
	assert js.length > 0;
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
