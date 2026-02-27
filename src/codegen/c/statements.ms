// C Codegen — Statement Emission
//
// Follows Nim's ccgstmts.nim: if/while/do-while/block/break/continue/return.
// Uses emitStmts/emitStmtsLine for direct write (avoids value-type Builder copy).

import {
	Node, NodeKind,
	VariableDeclData, IfStmtData, WhileStmtData, DoWhileStmtData,
	BlockStmtData, ExprStmtData, ReturnStmtData,
	BreakStmtData, ContinueStmtData, DeclKind,
	TryCatchStmtData, ThrowStmtData,
} from "../../ast/node";
import { Type, TypeKind } from "../../checker/types";
import {
	CGen, CProc,
	emitStmts, emitStmtsLine, emitStmtsNl,
	getStmtsIndent, setStmtsIndent,
	pushBlock, popBlock, readProcStmts,
} from "./context";
import { genExpr } from "./expressions";
import { safeName } from "./names";
import { test, check, testGroup } from "std/testing";

// ===== genStmt — main statement dispatcher =====

export function genStmt(g: CGen, p: CProc, node: Node): void {
	if (node === null) return;

	const k = node.kind;
	if (k === NodeKind.ExprStmt) { genExprStmt(g, p, node); }
	else if (k === NodeKind.VariableDecl) { genVarDecl(g, p, node); }
	else if (k === NodeKind.IfStmt) { genIfStmt(g, p, node); }
	else if (k === NodeKind.WhileStmt) { genWhileStmt(g, p, node); }
	else if (k === NodeKind.DoWhileStmt) { genDoWhileStmt(g, p, node); }
	else if (k === NodeKind.BlockStmt) { genBlockStmt(g, p, node); }
	else if (k === NodeKind.ReturnStmt) { genReturnStmt(g, p, node); }
	else if (k === NodeKind.BreakStmt) { genBreakStmt(g, p, node); }
	else if (k === NodeKind.ContinueStmt) { genContinueStmt(g, p, node); }
	else if (k === NodeKind.ThrowStmt) { genThrowStmt(g, p, node); }
	else if (k === NodeKind.TryCatchStmt) { genTryCatchStmt(g, p, node); }
	else { emitStmtsLine(p, "/* unsupported stmt: " + k + " */"); }
}

// ===== genStmts — emit a list of statements =====

export function genStmts(g: CGen, p: CProc, stmts: Node[]): void {
	let i = 0;
	while (i < stmts.length) {
		genStmt(g, p, stmts[i]);
		i += 1;
	}
}

// ===== Expression Statement =====

function genExprStmt(g: CGen, p: CProc, node: Node): void {
	const d = node.data as ExprStmtData;
	const snippet = genExpr(g, p, d.expr);
	emitStmtsLine(p, snippet + ";");
}

// ===== Variable Declaration =====

function genVarDecl(g: CGen, p: CProc, node: Node): void {
	const d = node.data as VariableDeclData;
	const varName = safeName(d.declName);

	const cType = match (d.declType) {
		"number" | "float64" | "" => "double",
		"int32" => "int32_t",
		"int64" => "int64_t",
		"uint32" => "uint32_t",
		"float32" => "float",
		"boolean" => "NIM_BOOL",
		"string" => "msString",
		"void" => "void",
		_ => "/* " + d.declType + " */ void*",
	};

	if (d.initializer !== null) {
		const initSnippet = genExpr(g, p, d.initializer);
		emitStmtsLine(p, cType + " " + varName + " = " + initSnippet + ";");
	} else {
		emitStmtsLine(p, cType + " " + varName + ";");
	}
}

// ===== If Statement =====

function genIfStmt(g: CGen, p: CProc, node: Node): void {
	const d = node.data as IfStmtData;
	const condSnippet = genExpr(g, p, d.condition);

	emitStmts(p, "if (" + condSnippet + ") ");
	genBlockOrBraces(g, p, d.consequent);

	if (isEmptyBlock(d.alternate)) {
		// No else — genBlockOrBraces already emitted closing brace + newline
	} else if (d.alternate.kind === NodeKind.IfStmt) {
		emitStmts(p, " else ");
		genStmt(g, p, d.alternate);
	} else {
		emitStmts(p, " else ");
		genBlockOrBraces(g, p, d.alternate);
		emitStmtsNl(p);
	}
}

// ===== While Statement =====

function genWhileStmt(g: CGen, p: CProc, node: Node): void {
	const d = node.data as WhileStmtData;
	const condSnippet = genExpr(g, p, d.whileCondition);

	emitStmts(p, "while (" + condSnippet + ") ");
	genBlockOrBraces(g, p, d.whileBody);
	emitStmtsNl(p);
}

// ===== Do-While Statement =====

function genDoWhileStmt(g: CGen, p: CProc, node: Node): void {
	const d = node.data as DoWhileStmtData;

	emitStmts(p, "do ");
	genBlockOrBraces(g, p, d.doBody);
	const condSnippet = genExpr(g, p, d.doCondition);
	emitStmtsLine(p, " while (" + condSnippet + ");");
}

// ===== Block Statement =====

function genBlockStmt(g: CGen, p: CProc, node: Node): void {
	const d = node.data as BlockStmtData;
	emitStmtsLine(p, "{");
	const oldIndent = getStmtsIndent(p);
	setStmtsIndent(p, oldIndent + 1);
	genStmts(g, p, d.statements);
	setStmtsIndent(p, oldIndent);
	emitStmtsLine(p, "}");
}

// ===== Return Statement =====

function genReturnStmt(g: CGen, p: CProc, node: Node): void {
	const d = node.data as ReturnStmtData;
	if (d.argument !== null) {
		const snippet = genExpr(g, p, d.argument);
		emitStmtsLine(p, "return " + snippet + ";");
	} else {
		emitStmtsLine(p, "return;");
	}
}

// ===== Break / Continue =====

function genBreakStmt(g: CGen, p: CProc, node: Node): void {
	emitStmtsLine(p, "break;");
}

function genContinueStmt(g: CGen, p: CProc, node: Node): void {
	emitStmtsLine(p, "continue;");
}

// ===== Throw Statement =====

function genThrowStmt(g: CGen, p: CProc, node: Node): void {
	const d = node.data as ThrowStmtData;
	const snippet = genExpr(g, p, d.throwArg);
	emitStmtsLine(p, "ms_throw(" + snippet + ");");
}

// ===== Try/Catch (setjmp/longjmp) =====

function genTryCatchStmt(g: CGen, p: CProc, node: Node): void {
	const d = node.data as TryCatchStmtData;

	emitStmtsLine(p, "{");
	const oldIndent = getStmtsIndent(p);
	setStmtsIndent(p, oldIndent + 1);
	emitStmtsLine(p, "msSafePoint __sp;");
	emitStmtsLine(p, "ms_push_safepoint(&__sp);");
	emitStmtsLine(p, "if (setjmp(__sp.context) == 0) {");
	setStmtsIndent(p, oldIndent + 2);
	genStmt(g, p, d.tryBody);
	setStmtsIndent(p, oldIndent + 1);
	emitStmtsLine(p, "} else {");
	setStmtsIndent(p, oldIndent + 2);
	if (d.catchName !== "") {
		emitStmtsLine(p, "msException* " + safeName(d.catchName) + " = ms_curr_exception;");
	}
	emitStmtsLine(p, "ms_clear_exception();");
	if (d.catchBody !== null) {
		genStmt(g, p, d.catchBody);
	}
	setStmtsIndent(p, oldIndent + 1);
	emitStmtsLine(p, "}");
	emitStmtsLine(p, "ms_pop_safepoint();");

	if (d.finallyBody !== null) {
		genStmt(g, p, d.finallyBody);
	}

	setStmtsIndent(p, oldIndent);
	emitStmtsLine(p, "}");
}

// ===== Helper: check if node is empty block (no else clause) =====

function isEmptyBlock(node: Node): boolean {
	if (node === null) return true;
	if (node.kind !== NodeKind.BlockStmt) return false;
	const d = node.data as BlockStmtData;
	return d.statements.length === 0;
}

// ===== Helper: emit block content or wrap in braces =====

function genBlockOrBraces(g: CGen, p: CProc, node: Node): void {
	if (node.kind === NodeKind.BlockStmt) {
		const d = node.data as BlockStmtData;
		emitStmts(p, "{\n");
		const oldIndent = getStmtsIndent(p);
		setStmtsIndent(p, oldIndent + 1);
		genStmts(g, p, d.statements);
		setStmtsIndent(p, oldIndent);
		emitStmtsLine(p, "}");
	} else {
		emitStmts(p, "{\n");
		const oldIndent = getStmtsIndent(p);
		setStmtsIndent(p, oldIndent + 1);
		genStmt(g, p, node);
		setStmtsIndent(p, oldIndent);
		emitStmtsLine(p, "}");
	}
}

// ===== Tests =====

import { createCGen, createProc } from "./context";
import { CheckerContext } from "../../checker/context";
import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { ProgramData } from "../../ast/node";

function stmtOutput(input: string): string {
	const pr = parseSource(input);
	if (!pr.ok) return "PARSE_ERROR: " + pr.error;
	const prog = pr.value;
	const pd = prog.data as ProgramData;
	const g = createCGen(null as unknown as CheckerContext);
	const p = createProc("test", null as unknown as Type);
	// Inline loop instead of genStmts to reduce call depth
	let i = 0;
	while (i < pd.programStmts.length) {
		genStmt(g, p, pd.programStmts[i]);
		i += 1;
	}
	return readProcStmts(p);
}

testGroup("C Stmt ExprStmt", () => {
	test("simple call", () => {
		check(stmtOutput("foo();") === "foo();\n");
	});
});

testGroup("C Stmt VarDecl", () => {
	test("const with init", () => {
		check(stmtOutput("const x: number = 42;") === "double x = 42;\n");
	});
	test("let with init", () => {
		check(stmtOutput("let x: number = 0;") === "double x = 0;\n");
	});
	test("int32 type", () => {
		check(stmtOutput("const n: int32 = 0;") === "int32_t n = 0;\n");
	});
	test("bool type", () => {
		check(stmtOutput("const flag: boolean = true;") === "NIM_BOOL flag = NIM_TRUE;\n");
	});
});

testGroup("C Stmt If", () => {
	test("simple if", () => {
		const result = stmtOutput("if (x) { foo(); }");
		check(result === "if (x) {\n  foo();\n}\n");
	});
	test("if-else", () => {
		const result = stmtOutput("if (x) { a(); } else { b(); }");
		check(result === "if (x) {\n  a();\n}\n else {\n  b();\n}\n\n");
	});
});

testGroup("C Stmt While", () => {
	test("simple while", () => {
		const result = stmtOutput("while (x) { foo(); }");
		check(result === "while (x) {\n  foo();\n}\n\n");
	});
});

testGroup("C Stmt Return", () => {
	test("return value", () => {
		check(stmtOutput("return 42;") === "return 42;\n");
	});
});

testGroup("C Stmt Break/Continue", () => {
	test("break", () => {
		check(stmtOutput("break;") === "break;\n");
	});
	test("continue", () => {
		check(stmtOutput("continue;") === "continue;\n");
	});
});
