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
	ExpectStmtData, CallExprData, IdentifierData,
} from "../../ast/node";
import { Type, TypeKind, isInterfaceType } from "../../checker/types";
import {
	CGen, CProc,
	emitStmts, emitStmtsLine, emitStmtsNl,
	getStmtsIndent, setStmtsIndent,
	pushBlock, popBlock, readProcStmts,
	nameSetHas,
} from "./context";
import { genExpr } from "./expressions";
import { safeName } from "./names";
import { getSimpleTypeDesc, getTypeDesc, isNrvoReturnType } from "./types";

// ===== NRVO Call Site Helpers =====
// G3 fix: detect calls to NRVO functions and emit fn(&dest, args) instead of dest = fn(args)

function isStructType(t: Type): boolean {
	if (t === null) return false;
	return match (t.kind) {
		TypeKind.String | TypeKind.Array | TypeKind.Map | TypeKind.Set => true,
		TypeKind.Object => { isInterfaceType(t) },
		TypeKind.Result | TypeKind.Tuple => true,
		TypeKind.Function => true,  // msClosure is a struct
		_ => false,
	};
}

function isNrvoCallSite(callNode: Node): boolean {
	// Only apply NRVO when callee is a known Function (not runtime macros)
	const cd = callNode.data as CallExprData;
	if (cd.callee !== null && cd.callee.nodeType !== null && cd.callee.nodeType.kind === TypeKind.Function) {
		if (cd.callee.nodeType.typeReturn !== null) return isNrvoReturnType(cd.callee.nodeType.typeReturn);
	}
	if (callNode.resolvedSym !== null && callNode.resolvedSym.symbolType !== null) {
		const st = callNode.resolvedSym.symbolType;
		if (st.kind === TypeKind.Function && st.typeReturn !== null) return isNrvoReturnType(st.typeReturn);
	}
	return false;
}

function getNrvoReturnType(callNode: Node): Type {
	const cd = callNode.data as CallExprData;
	if (cd.callee !== null && cd.callee.nodeType !== null && cd.callee.nodeType.kind === TypeKind.Function) {
		return cd.callee.nodeType.typeReturn;
	}
	if (callNode.resolvedSym !== null && callNode.resolvedSym.symbolType !== null) {
		const st = callNode.resolvedSym.symbolType;
		if (st.kind === TypeKind.Function) return st.typeReturn;
	}
	return null as unknown as Type;
}

function genNrvoCallExpr(g: CGen, p: CProc, callNode: Node, destVar: string): string {
	const cd = callNode.data as CallExprData;
	let callee = genExpr(g, p, cd.callee);
	let args = "&" + destVar;
	for (let i = 0; i < cd.arguments.length; i += 1) {
		args = args + ", " + genExpr(g, p, cd.arguments[i]);
	}
	return callee + "(" + args + ")";
}
import { sliceStr, charAt } from "../../utils/string";
import { check } from "std/testing";

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

function genVarDecl(g: CGen, p: CProc, node: Node): void {
	const d = node.data as VariableDeclData;
	const varName = safeName(d.declName);

	// Type resolution priority: nodeType (checker) > initializer.nodeType (DRC) > annotation fallback
	let cType = "";
	if (node.nodeType !== null) {
		cType = getTypeDesc(g, node.nodeType);
	} else if (d.initializer !== null && d.initializer.nodeType !== null) {
		cType = getTypeDesc(g, d.initializer.nodeType);
	}
	// Fallback: if type is void* or empty, check annotation against cross-module types
	if ((cType === "" || cType === "void*") && d.declType.length > 0) {
		const annotName = safeName(d.declType);
		if (nameSetHas(g.knownTypeNames, annotName)) {
			cType = nameSetHas(g.knownClassNames, annotName) ? annotName + "*" : annotName;
		}
	}
	if (cType === "") cType = "double";

	if (d.initializer !== null) {
		// G3 fix: NRVO call sites — when initializer is a call returning a struct,
		// emit "Type var; fn(&var, args);" instead of "Type var = fn(args);"
		if (d.initializer.kind === NodeKind.CallExpr && isNrvoCallSite(d.initializer)) {
			// Derive type from callee return type if cType is unresolved
			if (cType === "void*" || cType === "double") {
				const retType = getNrvoReturnType(d.initializer);
				if (retType !== null) cType = getTypeDesc(g, retType);
			}
			emitStmtsLine(p, cType + " " + varName + ";");
			const nrvoCall = genNrvoCallExpr(g, p, d.initializer, varName);
			emitStmtsLine(p, nrvoCall + ";");
		} else if (d.initializer.kind === NodeKind.NullLiteral && isStructType(node.nodeType)) {
			// D2 fix: struct-type null init → {0} instead of MS_NIL
			emitStmtsLine(p, cType + " " + varName + " = {0};");
		} else {
			const initSnippet = genExpr(g, p, d.initializer);
			emitStmtsLine(p, cType + " " + varName + " = " + initSnippet + ";");
		}
	} else {
		emitStmtsLine(p, cType + " " + varName + ";");
	}
}

// ===== If Statement =====

function genIfStmt(g: CGen, p: CProc, node: Node): void {
	let current = node;
	let isFirst = true;
	while (current !== null && current.kind === NodeKind.IfStmt) {
		const d = current.data as IfStmtData;
		const condSnippet = genExpr(g, p, d.condition);
		if (isFirst) {
			emitStmts(p, "if (" + condSnippet + ") ");
			isFirst = false;
		} else {
			emitStmts(p, " else if (" + condSnippet + ") ");
		}
		genBlockOrBraces(g, p, d.consequent);
		if (isEmptyBlock(d.alternate)) {
			current = null;
		} else if (d.alternate.kind === NodeKind.IfStmt) {
			current = d.alternate;
		} else {
			emitStmts(p, " else ");
			genBlockOrBraces(g, p, d.alternate);
			emitStmtsNl(p);
			current = null;
		}
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
	// NRVO: assign to *__result instead of returning (boolean flag, not name prefix)
	const isNrvo = p.isNrvo;
	if (d.argument !== null) {
		const snippet = genExpr(g, p, d.argument);
		if (isNrvo) {
			// G4 fix: compound literals need (StructType) cast for C99
			// If genObjectLiteral didn't add the cast (nodeType was null), add it here
			const needsCast = d.argument.kind === NodeKind.ObjectLiteral && snippet.length > 0 && charAt(snippet, 0) !== "(";
			if (needsCast && p.returnType !== null && p.returnType.typeName !== "") {
				emitStmtsLine(p, "*__result = (" + safeName(p.returnType.typeName) + ")" + snippet + ";");
			} else {
				emitStmtsLine(p, "*__result = " + snippet + ";");
			}
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
	emitStmtsLine(p, "msThrow(" + snippet + ");");
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
		emitStmtsLine(p, "msException* " + safeName(d.catchName) + " = msCurrException;");
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
	emitStmtsLine(p, "msPushSafepoint(&__sp);");
	emitStmtsLine(p, "if (setjmp(__sp.context) == 0) {");
	setStmtsIndent(p, oldIndent + 2);
	genStmt(g, p, d.tryBody);
	setStmtsIndent(p, oldIndent + 1);
	emitStmtsLine(p, "} else {");
	setStmtsIndent(p, oldIndent + 2);
	if (d.catchName !== "") {
		emitStmtsLine(p, "msException* " + safeName(d.catchName) + " = msCurrException;");
	}
	emitStmtsLine(p, "msClearException();");
	if (d.catchBody !== null) {
		genStmt(g, p, d.catchBody);
	}
	setStmtsIndent(p, oldIndent + 1);
	emitStmtsLine(p, "}");
	emitStmtsLine(p, "msPopSafepoint();");

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
	emitStmtsLine(p, `if (!(${cond})) { msTestCheckFail("expect failed", __FILE__, __LINE__); return; }`);
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
	const g = createCGen(null as unknown as CheckerContext, "");
	const p = createProc("test", null as unknown as Type);
	// Inline loop instead of genStmts to reduce call depth
	for (let i = 0; i < pd.programStmts.length; i += 1) {
		genStmt(g, p, pd.programStmts[i]);
	}
	return readProcStmts(p);
}

test "simple call" { check(stmtOutput("foo();") === "foo();\n"); }

test "const with init" { check(stmtOutput("const x: number = 42;") === "double x = 42;\n"); }

test "let with init" { check(stmtOutput("let x: number = 0;") === "double x = 0;\n"); }

test "int32 type" { check(stmtOutput("const n: int32 = 0;") === "int32_t n = 0;\n"); }

test "bool type" { check(stmtOutput("const flag: boolean = true;") === "MS_BOOL flag = MS_TRUE;\n"); }

test "simple if" {
	const result = stmtOutput("if (x) { foo(); }");
	check(result === "if (x) {\n  foo();\n}\n");
}

test "if-else" {
	const result = stmtOutput("if (x) { a(); } else { b(); }");
	check(result === "if (x) {\n  a();\n}\n else {\n  b();\n}\n\n");
}

test "simple while" {
	const result = stmtOutput("while (x) { foo(); }");
	check(result === "while (x) {\n  foo();\n}\n\n");
}

test "return value" { check(stmtOutput("return 42;") === "return 42;\n"); }

test "break" { check(stmtOutput("break;") === "break;\n"); }

test "continue" { check(stmtOutput("continue;") === "continue;\n"); }

test "try-catch emits goto labels" {
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
}

test "try-catch has catch label" {
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
}

test "try-finally has finally label" {
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
}

test "long if-else chain (100 branches)" {
	// Build: if (a) { f(); } else if (b) { f(); } else if ... (100 branches)
	// This simulates match-lowered code that previously caused stack overflow.
	let input = "if (a) { f(); }";
	let i = 0;
	while (i < 99) {
		input = input + " else if (b) { f(); }";
		i += 1;
	}
	const result = stmtOutput(input);
	check(result.length > 0);
	// Should contain "else if" pattern (iterative, not recursive)
	let elseIfCount = 0;
	let j = 0;
	while (j < result.length - 7) {
		if (sliceStr(result, j, j + 7) === "else if") {
			elseIfCount = elseIfCount + 1;
		}
		j += 1;
	}
	check(elseIfCount === 99);
}
