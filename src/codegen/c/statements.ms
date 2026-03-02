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
	SwitchStmtData, SwitchCaseData,
	ExpectStmtData,
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
import { getSimpleTypeDesc, getTypeDesc } from "./types";
import { sliceStr } from "../../utils/string";
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
	else if (k === NodeKind.SwitchStmt) { genSwitchStmt(g, p, node); }
	else if (k === NodeKind.ExpectStmt) { genExpectStmt(g, p, node); }
	else { emitStmtsLine(p, "/* unsupported stmt: " + k + " */"); }
}

// ===== genStmts — emit a list of statements =====

export function genStmts(g: CGen, p: CProc, stmts: Node[]): void {
	for (let i = 0; i < stmts.length; i += 1) {
		genStmt(g, p, stmts[i]);
	}
}

// ===== Expression Statement =====

function genExprStmt(g: CGen, p: CProc, node: Node): void {
	const d = node.data as ExprStmtData;
	if (d.expr.kind === NodeKind.MacroInvocation) return;
	const snippet = genExpr(g, p, d.expr);
	emitStmtsLine(p, snippet + ";");
}

// ===== Variable Declaration =====

function mapDeclTypeStr(dt: string): string {
	return match (dt) {
		"number" | "float64" => "double",
		"int32" => "int32_t",
		"int64" => "int64_t",
		"uint32" => "uint32_t",
		"float32" => "float",
		"boolean" => "MS_BOOL",
		"string" => "msString",
		"void" => "void",
		_ => "",
	};
}

function genVarDecl(g: CGen, p: CProc, node: Node): void {
	const d = node.data as VariableDeclData;
	const varName = safeName(d.declName);

	let cType = "";
	if (d.declType !== "") {
		cType = mapDeclTypeStr(d.declType);
		if (cType === "") {
			cType = "/* " + d.declType + " */ void*";
		}
	} else if (node.nodeType !== null) {
		// Use checker's inferred type
		cType = getSimpleTypeDesc(node.nodeType);
		if (cType === "") {
			cType = getTypeDesc(g, node.nodeType);
		}
	}
	if (cType === "") cType = "double";

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
	// NRVO: assign to *__result instead of returning (name prefix convention)
	const isNrvo = p.name.length > 8 && sliceStr(p.name, 0, 8) === "__nrvo__";
	if (d.argument !== null) {
		const snippet = genExpr(g, p, d.argument);
		if (isNrvo) {
			emitStmtsLine(p, "*__result = " + snippet + ";");
			emitStmtsLine(p, "return;");
		} else {
			emitStmtsLine(p, "return " + snippet + ";");
		}
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

// ===== Try/Catch (goto-based — Nim's genTryGoto) =====
// Goto-based exceptions: no setjmp overhead. Each try block gets unique labels.
// After each potentially-raising call, check *nimErr_ and goto catch.

function genTryCatchStmt(g: CGen, p: CProc, node: Node): void {
	const d = node.data as TryCatchStmtData;
	p.labels = p.labels + 1;
	const labelId = p.labels;
	const catchLabel = "__catch_" + labelId;
	const finallyLabel = "__finally_" + labelId;
	const endLabel = "__end_" + labelId;

	emitStmtsLine(p, "{");
	const oldIndent = getStmtsIndent(p);
	setStmtsIndent(p, oldIndent + 1);

	// Try body
	genStmt(g, p, d.tryBody);
	// After try body, check error flag
	emitStmtsLine(p, "if (msErr) goto " + catchLabel + ";");
	emitStmtsLine(p, "goto " + finallyLabel + ";");

	// Catch label
	emitStmtsLine(p, catchLabel + ": {");
	setStmtsIndent(p, oldIndent + 2);
	if (d.catchName !== "") {
		emitStmtsLine(p, "msException* " + safeName(d.catchName) + " = ms_curr_exception;");
	}
	emitStmtsLine(p, "msErr = MS_FALSE;");
	emitStmtsLine(p, "msClearException();");
	if (d.catchBody !== null) {
		genStmt(g, p, d.catchBody);
	}
	setStmtsIndent(p, oldIndent + 1);
	emitStmtsLine(p, "}");

	// Finally label
	emitStmtsLine(p, finallyLabel + ":");

	if (d.finallyBody !== null) {
		genStmt(g, p, d.finallyBody);
	}

	setStmtsIndent(p, oldIndent);
	emitStmtsLine(p, "}");
}

// ===== Try/Catch (setjmp/longjmp fallback) =====
// Kept as alternative strategy. Goto-based (above) is the default.

function genTryCatchSetjmp(g: CGen, p: CProc, node: Node): void {
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
	emitStmtsLine(p, "msClearException();");
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

// ===== Switch Statement (hash dispatch) =====

function genSwitchStmt(g: CGen, p: CProc, node: Node): void {
	const d = node.data as SwitchStmtData;
	const discSnippet = genExpr(g, p, d.switchDisc);
	emitStmtsLine(p, "switch (" + discSnippet + ") {");
	const oldIndent = getStmtsIndent(p);
	setStmtsIndent(p, oldIndent + 1);

	for (let i = 0; i < d.switchCases.length; i += 1) {
		const caseNode = d.switchCases[i];
		const cd = caseNode.data as SwitchCaseData;

		if (cd.isDefault) {
			emitStmtsLine(p, "default: {");
		} else {
			for (let j = 0; j < cd.caseTests.length; j += 1) {
				const testSnippet = genExpr(g, p, cd.caseTests[j]);
				emitStmtsLine(p, "case " + testSnippet + ":");
			}
			emitStmts(p, "{");
			emitStmtsNl(p);
		}

		setStmtsIndent(p, oldIndent + 2);
		genStmts(g, p, cd.caseStmts);
		emitStmtsLine(p, "break;");
		setStmtsIndent(p, oldIndent + 1);
		emitStmtsLine(p, "}");
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

// ===== Expect Statement =====

function genExpectStmt(g: CGen, p: CProc, node: Node): void {
	const d = node.data as ExpectStmtData;
	const cond = genExpr(g, p, d.expectExpr);
	emitStmtsLine(p, `if (!(${cond})) { ms_test_check_fail("expect failed", __FILE__, __LINE__); return; }`);
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
	for (let i = 0; i < pd.programStmts.length; i += 1) {
		genStmt(g, p, pd.programStmts[i]);
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
		check(stmtOutput("const flag: boolean = true;") === "MS_BOOL flag = MS_TRUE;\n");
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

testGroup("C Stmt TryCatch Goto", () => {
	test("try-catch emits goto labels", () => {
		const tc = stmtOutput("try { foo(); } catch (e) { bar(); }");
		const len = tc.length;
		// Should contain goto-based labels, not setjmp
		check(len > 20);
		// Should NOT contain setjmp (we use goto-based now)
		let hasSetjmp = false;
		let i = 0;
		while (i < len - 6) {
			if (sliceStr(tc, i, i + 6) === "setjmp") {
				hasSetjmp = true;
			}
			i = i + 1;
		}
		check(!hasSetjmp);
	});
	test("try-catch has catch label", () => {
		const tc = stmtOutput("try { foo(); } catch (e) { bar(); }");
		const len = tc.length;
		// Should contain __catch_ label
		let hasCatch = false;
		let i = 0;
		while (i < len - 8) {
			if (sliceStr(tc, i, i + 8) === "__catch_") {
				hasCatch = true;
			}
			i = i + 1;
		}
		check(hasCatch);
	});
	test("try-finally has finally label", () => {
		const tf = stmtOutput("try { foo(); } finally { cleanup(); }");
		const len = tf.length;
		let hasFinally = false;
		let i = 0;
		while (i < len - 10) {
			if (sliceStr(tf, i, i + 10) === "__finally_") {
				hasFinally = true;
			}
			i = i + 1;
		}
		check(hasFinally);
	});
});
