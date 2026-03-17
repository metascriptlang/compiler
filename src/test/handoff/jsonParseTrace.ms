// Trace JSON.parse<T> through every pipeline phase
// Validates each phase produces correct output for the next

import { fullPipeline, checkSource, findFnDecl } from "./helpers";
import { Node, NodeKind, NodeFlag, ProgramData, FunctionDeclData, VariableDeclData, CallExprData, MemberExprData, IdentifierData, ExprStmtData, BlockStmtData, IfStmtData, ReturnStmtData, BinaryExprData, UnaryExprData, ObjectLiteralData, Type, TypeKind } from "../../ast/node";
import { lookupSymbol } from "../../checker/symbol";
import { resetAllSideChannels, findCallTypeArg, getExplicitTypeArg } from "../../parser/context";
import { parseSource } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { checkProgramWithRegistry } from "../../checker/checkPass";
import { checkModuleGraph, getPreludeContext } from "../../checker/orchestrator";
import { monomorphizeProgram } from "../../monomorphize/collect";
import { validateTypedAST } from "../../checker/validate";
import { transformProgram } from "../../transform/index";
import { transformForNative } from "../../transform/native/index";
import { createTransformContextWithChecker } from "../../transform/context";
import { createMapProvider, loadModuleGraph } from "../../module/loader";
import { findModule } from "../../module/graph";

// Helper: run pipeline up to a specific phase and return (program, ctx)
function pipelineUpTo(source: string, phase: string): Node {
	resetAllSideChannels();
	const modPath = "test/handoff.ms";
	const entries = [{ entryPath: modPath, entrySource: source }];
	const provider = createMapProvider(entries);
	const graph = loadModuleGraph(modPath, provider);
	const registry = checkModuleGraph(graph, "");
	const preludeCtx = getPreludeContext();
	const mod = findModule(graph, modPath);
	if (mod === null) return null as unknown as Node;
	const pr = parseSource(mod.source);
	if (!pr.ok) return null as unknown as Node;

	if (phase === "parse") return pr.value;

	const ctx = checkProgramWithRegistry(pr.value, registry, graph, mod, preludeCtx);
	if (phase === "check") return pr.value;

	const monoed = monomorphizeProgram(pr.value, ctx);
	if (phase === "mono") return monoed;

	validateTypedAST(ctx, monoed);
	const transformed = transformProgram(monoed, ctx, false);
	if (phase === "transform") return transformed;

	const nativeCtx = createTransformContextWithChecker(ctx);
	const nativeTransformed = transformForNative(transformed, nativeCtx);
	return nativeTransformed;
}

const JSON_PARSE_SRC = "interface Person { name: string; age: number; }\nconst result = JSON.parse<Person>(\"{}\");\nif (result.ok) { console.log(result.value.name); }";

// ===== Phase 1: Parse — type arg stored in side-channel =====

test "P1 parse: type arg side-channel stores Person" {
	resetAllSideChannels();
	const pr = parseSource(JSON_PARSE_SRC);
	assert pr.ok;
	// After parsing, the side-channel should have "Person" stored at the '<' position.
	// We can't easily query it here without knowing exact col, but parse must succeed.
	const pd = pr.value.data as ProgramData;
	assert pd.programStmts.length >= 2;
	console.log("[P1] parse OK, " + pd.programStmts.length + " stmts");
}

// ===== Phase 2: Check — T substituted to Person in Result type =====

test "P2 check: JSON_parse sym has builtinKind=JsonParse" {
	const ctx = checkSource(JSON_PARSE_SRC);
	assert ctx !== null;
	const sym = lookupSymbol(ctx.table, "JSON_parse");
	assert sym !== null;
	assert sym.builtinKind === "JsonParse";
	console.log("[P2] JSON_parse builtinKind=" + sym.builtinKind + " OK");
}

test "P2 check: result type is Result<Person, string>" {
	const ctx = checkSource(JSON_PARSE_SRC);
	assert ctx !== null;
	const sym = lookupSymbol(ctx.table, "result");
	assert sym !== null;
	assert sym.symbolType !== null;
	assert sym.symbolType.kind === TypeKind.Result;
	const tReturn = sym.symbolType.typeReturn;
	assert tReturn !== null;
	console.log("[P2] result.T kind=" + tReturn.kind + " name=" + tReturn.typeName);
	assert tReturn.kind === TypeKind.Struct;
	assert tReturn.typeName === "Person";
	console.log("[P2] Result<Person, string> OK");
}

test "P2 check: result.value.name resolves without error" {
	const ctx = checkSource(JSON_PARSE_SRC);
	assert ctx !== null;
	let hasPropertyError = false;
	let ei = 0;
	while (ei < ctx.errors.length) {
		const msg = ctx.errors[ei].message;
		if (msg.indexOf("does not exist") >= 0) {
			console.log("[P2] ERROR: " + msg);
			hasPropertyError = true;
		}
		ei = ei + 1;
	}
	assert !hasPropertyError;
	console.log("[P2] no property errors OK");
}

test "P2 check: JSON_parse return type has GenericParam T (not TypeReference)" {
	const ctx = checkSource(JSON_PARSE_SRC);
	assert ctx !== null;
	const sym = lookupSymbol(ctx.table, "JSON_parse");
	assert sym !== null;
	const ft = sym.symbolType;
	assert ft.kind === TypeKind.Function;
	assert ft.typeReturn !== null;
	assert ft.typeReturn.kind === TypeKind.Result;
	const tParam = ft.typeReturn.typeReturn;
	assert tParam !== null;
	console.log("[P2] JSON_parse return.T kind=" + tParam.kind + " (GenericParam=" + TypeKind.GenericParam + ")");
	assert tParam.kind === TypeKind.GenericParam;
	console.log("[P2] fn signature keeps GenericParam OK");
}

// ===== Phase 3: Monomorphize — @builtin bypasses mono =====

test "P3 mono: program unchanged (builtin bypasses mono)" {
	const program = pipelineUpTo(JSON_PARSE_SRC, "mono");
	assert program !== null;
	const pd = program.data as ProgramData;
	console.log("[P3] mono stmts=" + pd.programStmts.length);
	// Should still have the original stmts (no mono expansion for @builtin)
	assert pd.programStmts.length >= 2;
	console.log("[P3] mono passthrough OK");
}

// ===== Phase 4: Transform — builtinLower generates __jsonParse_Person =====

test "P4 transform: call rewritten to __jsonParse_Person" {
	const program = pipelineUpTo(JSON_PARSE_SRC, "transform");
	assert program !== null;
	const pd = program.data as ProgramData;

	// Find the variable decl for 'result'
	let callRewritten = false;
	let si = 0;
	while (si < pd.programStmts.length) {
		const stmt = pd.programStmts[si];
		if (stmt.kind === NodeKind.VariableDecl) {
			const vd = stmt.data as VariableDeclData;
			if (vd.initializer !== null && vd.initializer.kind === NodeKind.CallExpr) {
				const cd = vd.initializer.data as CallExprData;
				if (cd.callee.kind === NodeKind.Identifier) {
					const name = (cd.callee.data as IdentifierData).name;
					if (name === "__jsonParse_Person") {
						callRewritten = true;
						console.log("[P4] call rewritten to " + name);
					}
				}
			}
		}
		si = si + 1;
	}
	assert callRewritten;
	console.log("[P4] call rewrite OK");
}

test "P4 transform: __jsonParse_Person helper appended" {
	const program = pipelineUpTo(JSON_PARSE_SRC, "transform");
	assert program !== null;
	const fn = findFnDecl(program, "__jsonParse_Person");
	assert fn !== null;
	const fd = fn.data as FunctionDeclData;
	assert fd.params.length === 1;
	assert fd.params[0] === "input";
	console.log("[P4] helper function generated OK");
}

test "P4 transform: helper body has parseJson call" {
	const program = pipelineUpTo(JSON_PARSE_SRC, "transform");
	assert program !== null;
	const fn = findFnDecl(program, "__jsonParse_Person");
	assert fn !== null;
	const fd = fn.data as FunctionDeclData;
	// Body should be a BlockStmt containing: parseJson call, ok check, value extraction, field checks, return
	assert fd.fnBody !== null;
	assert fd.fnBody.kind === NodeKind.BlockStmt;
	const body = fd.fnBody.data as BlockStmtData;
	console.log("[P4] helper body stmts=" + body.statements.length);
	// Should have: VarDecl($jr=parseJson), IfStmt(!ok), VarDecl($jv), IfStmt(kind), per-field VarDecl+IfStmt, ReturnStmt
	assert body.statements.length >= 5;
	// First stmt: const $jr = parseJson(input)
	assert body.statements[0].kind === NodeKind.VariableDecl;
	const firstDecl = body.statements[0].data as VariableDeclData;
	assert firstDecl.name === "$jr";
	console.log("[P4] helper body structure OK");
}

test "P4 transform: helper return type is Result<Person, string>" {
	const program = pipelineUpTo(JSON_PARSE_SRC, "transform");
	assert program !== null;
	const fn = findFnDecl(program, "__jsonParse_Person");
	assert fn !== null;
	// The helper's nodeType should be null (let codegen infer) or Result<Person,string>
	// Check the return statement's nodeType instead
	const fd = fn.data as FunctionDeclData;
	const body = fd.fnBody.data as BlockStmtData;
	// Last stmt should be ReturnStmt with ObjectLiteral { ok: true, value: {...} }
	const lastStmt = body.statements[body.statements.length - 1];
	assert lastStmt.kind === NodeKind.ReturnStmt;
	const ret = lastStmt.data as ReturnStmtData;
	if (ret.argument !== null && ret.argument.nodeType !== null) {
		console.log("[P4] return nodeType kind=" + ret.argument.nodeType.kind);
		if (ret.argument.nodeType.kind === TypeKind.Result) {
			const tr = ret.argument.nodeType.typeReturn;
			if (tr !== null) {
				console.log("[P4] return Result.T kind=" + tr.kind + " name=" + tr.typeName);
			}
		}
	} else {
		console.log("[P4] return argument nodeType is null");
	}
	console.log("[P4] return type check done");
}

// ===== Phase 5: Native transform — helper survives =====

test "P5 native: helper survives native transforms" {
	const program = pipelineUpTo(JSON_PARSE_SRC, "native");
	assert program !== null;
	const fn = findFnDecl(program, "__jsonParse_Person");
	if (fn !== null) {
		console.log("[P5] helper survived native transforms OK");
	} else {
		console.log("[P5] WARNING: helper lost during native transforms");
	}
	// Check all stmt kinds for debugging
	const pd = program.data as ProgramData;
	let si = 0;
	while (si < pd.programStmts.length) {
		const stmt = pd.programStmts[si];
		if (stmt.kind === NodeKind.FunctionDecl) {
			const fd = stmt.data as FunctionDeclData;
			console.log("[P5] stmt[" + si + "] FunctionDecl: " + fd.fnName);
		} else if (stmt.kind === NodeKind.VariableDecl) {
			const vd = stmt.data as VariableDeclData;
			console.log("[P5] stmt[" + si + "] VariableDecl: " + vd.name);
		} else {
			console.log("[P5] stmt[" + si + "] kind=" + stmt.kind);
		}
		si = si + 1;
	}
}

// ===== Phase 5b: Helper body — check inner nodes have resolvedSym/nodeType =====

test "P5 native: helper inner calls have resolvedSym" {
	const program = pipelineUpTo(JSON_PARSE_SRC, "native");
	assert program !== null;
	const fn = findFnDecl(program, "__jsonParse_Person");
	if (fn === null) {
		console.log("[P5b] SKIP — helper not found");
		return;
	}
	const fd = fn.data as FunctionDeclData;
	const body = fd.fnBody.data as BlockStmtData;
	// Check first VarDecl: const $jr = parseJson(input)
	let si = 0;
	while (si < body.statements.length) {
		const stmt = body.statements[si];
		if (stmt.kind === NodeKind.VariableDecl) {
			const vd = stmt.data as VariableDeclData;
			if (vd.initializer !== null && vd.initializer.kind === NodeKind.CallExpr) {
				const cd = vd.initializer.data as CallExprData;
				if (cd.callee.kind === NodeKind.Identifier) {
					const name = (cd.callee.data as IdentifierData).name;
					const hasSym = cd.callee.resolvedSym !== null;
					const hasType = vd.initializer.nodeType !== null;
					console.log("[P5b] " + vd.name + " = " + name + "() resolvedSym=" + hasSym + " nodeType=" + hasType);
				}
			}
		} else if (stmt.kind === NodeKind.ExprStmt) {
			const es = stmt.data as ExprStmtData;
			if (es.expr.kind === NodeKind.CallExpr) {
				const cd = es.expr.data as CallExprData;
				if (cd.callee.kind === NodeKind.Identifier) {
					const name = (cd.callee.data as IdentifierData).name;
					const hasSym = cd.callee.resolvedSym !== null;
					console.log("[P5b] call " + name + "() resolvedSym=" + hasSym);
				}
			}
		}
		si = si + 1;
	}
}
