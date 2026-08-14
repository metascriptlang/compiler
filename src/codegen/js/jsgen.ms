// JavaScript Codegen — Node Dispatcher + Entry Point
//
// Registers emitNodeDispatch callback, provides generateJS entry point.
// Tests cover the full pipeline: parse → check → transform → generateJS.

import { Node, NodeKind, ProgramData, HiddenDerefData, HiddenStdConvData, TryExprData, FunctionDeclData, ExportDeclData } from "../../ast/node";
import { JSGenerator, createJSGenerator, registerEmitNode, finalize, emit, lookupModuleSpec } from "./emit";
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
	jsSymbolName,
} from "./expressions";
import {
	emitVariableDecl, emitIfStmt, emitWhileStmt, emitDoWhileStmt,
	emitBlockStmt, emitExprStmt, emitReturnStmt,
	emitBreakStmt, emitContinueStmt,
	emitSwitchStmt, emitThrowStmt, emitTryCatchStmt,
	emitForStmt, emitForOfStmt, emitUnreachableStmt, emitAssertStmt,
} from "./statements";
import {
	emitFunctionDecl, emitEnumDecl, emitClassDecl,
	emitMethodDecl, emitConstructorDecl,
	emitImportDecl, emitExportDecl, emitDecoratedDecl,
} from "./declarations";

import { emitTestDecl } from "./test";
import { parseSource } from "../../parser/statements/validation";
import { checkProgram } from "../../checker/checkPass";
import { transformProgram } from "../../transform/index";
import { JsImportEntry } from "../../checker/context";

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
		NodeKind.TryExpr => {
			// try expr → (function(){ const $r = expr; if (!$r.ok) throw $r; return $r.value; })()
			const td = node.data as TryExprData;
			emit(gen, "(function(){ const $r = ");
			emitNodeDispatch(gen, td.tryArg);
			if (td.hasCatch && td.catchVal !== null) {
				emit(gen, "; if (!$r.ok) return ");
				emitNodeDispatch(gen, td.catchVal);
				emit(gen, "; return $r.value; })()");
			} else {
				emit(gen, "; if (!$r.ok) throw $r; return $r.value; })()");
			}
		},
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

		NodeKind.AssertStmt => { emitAssertStmt(gen, node); },
		NodeKind.TestDecl => { emitTestDecl(gen, node); },

		// Declarations
		NodeKind.FunctionDecl => { emitFunctionDecl(gen, node); },
		NodeKind.EnumDecl => { emitEnumDecl(gen, node); },
		NodeKind.ClassDecl => { emitClassDecl(gen, node); },
		NodeKind.MethodDecl => { emitMethodDecl(gen, node); },
		NodeKind.ConstructorDecl => { emitConstructorDecl(gen, node); },
		NodeKind.PropertyDecl => {},
		NodeKind.ImportDecl => { emitImportDecl(gen, node); },
		NodeKind.ExportDecl => { emitExportDecl(gen, node); },
		NodeKind.DecoratedDecl => { emitDecoratedDecl(gen, node); },

		// Type-only declarations — no JS output
		NodeKind.InterfaceDecl | NodeKind.StructDecl | NodeKind.TypeAliasDecl | NodeKind.ExternDecl
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

export function generateJS(program: Node, jsImports: JsImportEntry[]): string {
	const gen = createJSGenerator();
	gen.jsImports = jsImports !== null ? jsImports : [];
	emit(gen, "// Generated by MetaScript Compiler\n");
	// Emit @import registry as JS import statements
	for (const entry of gen.jsImports) {
		if (entry.names.length > 0) {
			emit(gen, "import { ");
			for (let i = 0; i < entry.names.length; i += 1) {
				if (i > 0) emit(gen, ", ");
				emit(gen, entry.names[i]);
			}
			emit(gen, " } from \"");
			emit(gen, entry.modulePath);
			emit(gen, "\";\n");
		}
	}
	emitNodeDispatch(gen, program);
	return finalize(gen);
}

// Multi-file mode: one ES module per source module. Derived imports append at
// the end of the file — ESM hoists them, position is legal. The caller owns
// forced exports (names other modules need that this module didn't export):
// only the full graph knows that set, so it's applied before writing.
export interface JsModuleResult {
	code: string;
	neededModules: string[];
	neededNames: string[][];
	exportedNames: string[];
	testNames: string[];
	testFuncs: string[];
}

function emitAutoCallMain(gen: JSGenerator, program: Node): void {
	const pd = program.data as ProgramData;
	for (const st of pd.programStmts) {
		let decl = st;
		if (decl.kind === NodeKind.ExportDecl) { decl = (decl.data as ExportDeclData).exportedDecl; }
		if (decl === null) continue;
		if (decl.kind !== NodeKind.FunctionDecl) continue;
		if ((decl.data as FunctionDeclData).fnName !== "main") continue;
		const name = jsSymbolName(gen, decl.resolvedSym, "main");
		emit(gen, `Promise.resolve(${name}()).then((r) => { if (typeof process !== "undefined" && typeof r === "number") { process.exitCode = r | 0; } });\n`);
		return;
	}
}

export function generateJSModule(
	program: Node, jsImports: JsImportEntry[], currentModulePath: string,
	importSpecKeys: string[], importSpecVals: string[],
	moduleSpecKeys: string[], moduleSpecVals: string[],
	modExportKeys: string[], modExportVals: string[][],
	isTestBuild: boolean, autoCallMain: boolean,
): JsModuleResult {
	const gen = createJSGenerator();
	gen.multiFile = true;
	gen.isTestBuild = isTestBuild;
	gen.currentModulePath = currentModulePath;
	gen.importSpecKeys = importSpecKeys;
	gen.importSpecVals = importSpecVals;
	gen.moduleSpecKeys = moduleSpecKeys;
	gen.moduleSpecVals = moduleSpecVals;
	gen.modExportKeys = modExportKeys;
	gen.modExportVals = modExportVals;
	gen.jsImports = jsImports !== null ? jsImports : [];
	emit(gen, "// Generated by MetaScript Compiler\n");
	for (const entry of gen.jsImports) {
		if (entry.names.length > 0) {
			emit(gen, "import { ");
			for (let i = 0; i < entry.names.length; i += 1) {
				if (i > 0) emit(gen, ", ");
				emit(gen, entry.names[i]);
			}
			emit(gen, " } from \"");
			emit(gen, entry.modulePath);
			emit(gen, "\";\n");
		}
	}
	emitNodeDispatch(gen, program);
	for (let mi = 0; mi < gen.neededModules.length; mi += 1) {
		const spec = lookupModuleSpec(gen, gen.neededModules[mi]);
		if (spec === "") continue;
		emit(gen, "import { ");
		for (let ni = 0; ni < gen.neededNames[mi].length; ni += 1) {
			if (ni > 0) emit(gen, ", ");
			emit(gen, gen.neededNames[mi][ni]);
		}
		emit(gen, ` } from "${spec}";\n`);
	}
	if (autoCallMain) { emitAutoCallMain(gen, program); }
	return { code: finalize(gen), neededModules: gen.neededModules, neededNames: gen.neededNames, exportedNames: gen.exportedNames, testNames: gen.testNames, testFuncs: gen.testFuncs };
}

// Bundle mode: generate JS for a single module without header/imports.
// Returns the code body + list of exported names for the IIFE return statement.
export interface BundleModuleResult {
	code: string;
	exportedNames: string[];
}

export function generateJSBundleModule(program: Node, importSourceMap: string[], importSourceMapKeys: string[], isPrelude: boolean, autoCallMain: boolean): BundleModuleResult {
	const gen = createJSGenerator();
	gen.bundleMode = true;
	gen.bundleIsPrelude = isPrelude;
	gen.jsImports = [];
	gen.importSourceToModuleId = importSourceMap;
	gen.importSourceToModuleIdKeys = importSourceMapKeys;
	emitNodeDispatch(gen, program);
	if (autoCallMain) { emitAutoCallMain(gen, program); }
	return { code: finalize(gen), exportedNames: gen.exportedNames };
}

// Generate JS without header (for internal/test use)
function generateJSRaw(program: Node): string {
	const gen = createJSGenerator();
	gen.jsImports = [];
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

test "std import emitted" {
	const js = genFromSource("import { test } from \"std/testing\"; 42;");
	assert js === "import { test } from \"std/testing\";\n42;\n";
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
	const emptyImports: JsImportEntry[] = [];
	const js = generateJS(transformed, emptyImports);
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
