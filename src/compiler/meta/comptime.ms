// ComptimeEval — Evaluate @comptime blocks via Raiser VM, fold results into AST
//
// This module is the consumer side of the macro-system bridge:
//   1. Walks the AST looking for ComptimeBlock nodes
//   2. For each one: extracts the body, runs it in the Raiser VM
//   3. Converts the VM's result back to an AST literal node
//   4. Replaces the ComptimeBlock with the result
//
// All the Node ↔ RaiserValue serialization lives in src/compiler/meta/bridge.ms
// (also used by the future macro expansion pass).

import {
	Node, NodeKind, createNode,
	VariableDeclData, FunctionDeclData,
	ExprStmtData, ReturnStmtData, IfStmtData, WhileStmtData,
	BlockStmtData, ExportDeclData,
	ComptimeBlockData, ProgramData,
	NumberLiteralData, StringLiteralData, BooleanLiteralData,
} from "../../ast/node";
import { parseSource } from "../../parser/statements/validation";
import { evalASTFull } from "../../codegen/raiser/eval";
import {
	clearObjectHeap, clearArrayHeap,
} from "../../raiser/value";
import { RaiserContext } from "../../raiser/context";
import { valueToNode, synthToken } from "./bridge";

// --- Evaluate a single ComptimeBlock node ---

function evalComptimeBlock(node: Node): Node {
	const d = node.data as ComptimeBlockData;
	const body = d.comptimeBody;
	const loc = node.location;

	// Extract statements from the body block
	const bodyData = body.data as BlockStmtData;
	const stmts = bodyData.statements;

	// Transform last ExprStmt into ReturnStmt so the VM captures the value
	// (standard comptime/REPL semantics — implicit return of last expression)
	const finalStmts: Node[] = [];
	let si = 0;
	while (si < stmts.length) {
		if (si === stmts.length - 1 && stmts[si].kind === NodeKind.ExprStmt) {
			const ed = stmts[si].data as ExprStmtData;
			finalStmts.push(createNode(NodeKind.ReturnStmt, { argument: ed.expr }, synthToken(loc)));
		} else {
			finalStmts.push(stmts[si]);
		}
		si = si + 1;
	}

	// Wrap in a synthetic Program node for the Raiser pipeline
	const program = createNode(NodeKind.Program, { programStmts: finalStmts }, synthToken(loc));

	// Evaluate through the Raiser VM
	let ctx = evalASTFull(program);

	// Convert VM result back to an AST literal
	const result = valueToNode(ctx.lastResult, ctx.objectHeap, ctx.arrayHeap, loc);

	// Reclaim VM heaps — prevents monotonic growth during long builds
	clearObjectHeap(ctx.objectHeap);
	clearArrayHeap(ctx.arrayHeap);
	ctx = null as unknown as RaiserContext;

	return result;
}

// --- First pass: check if AST contains any ComptimeBlock nodes ---

function hasComptimeBlock(node: Node): boolean {
	if (node === null) return false;
	return match (node.kind) {
		NodeKind.ComptimeBlock => true,
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			return hasComptimeBlock(d.initializer);
		},
		NodeKind.ExprStmt => {
			const d = node.data as ExprStmtData;
			return hasComptimeBlock(d.expr);
		},
		NodeKind.ReturnStmt => {
			const d = node.data as ReturnStmtData;
			return hasComptimeBlock(d.argument);
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			for (const stmt of d.statements) {
				if (hasComptimeBlock(stmt)) return true;
			}
			return false;
		},
		NodeKind.ExportDecl => {
			const d = node.data as ExportDeclData;
			return hasComptimeBlock(d.exportedDecl);
		},
		NodeKind.FunctionDecl => {
			const d = node.data as FunctionDeclData;
			return hasComptimeBlock(d.fnBody);
		},
		NodeKind.Program => {
			const d = node.data as ProgramData;
			for (const stmt of d.programStmts) {
				if (hasComptimeBlock(stmt)) return true;
			}
			return false;
		},
		_ => false,
	};
}

// --- AST walker — find and replace ComptimeBlock nodes ---
// Uses if-else (not match) to avoid DRC workaround #24.

function walkNode(node: Node): Node {
	if (node.kind === NodeKind.ComptimeBlock) {
		return evalComptimeBlock(node);
	} else if (node.kind === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		const newInit = walkNode(d.initializer);
		return createNode(NodeKind.VariableDecl, {
			declName: d.declName, declType: d.declType,
			initializer: newInit, declKind: d.declKind,
			nameLocation: d.nameLocation,
		}, synthToken(node.location));
	} else if (node.kind === NodeKind.ExprStmt) {
		const d = node.data as ExprStmtData;
		const newExpr = walkNode(d.expr);
		return createNode(NodeKind.ExprStmt, { expr: newExpr }, synthToken(node.location));
	} else if (node.kind === NodeKind.ReturnStmt) {
		const d = node.data as ReturnStmtData;
		const newArg = walkNode(d.argument);
		return createNode(NodeKind.ReturnStmt, { argument: newArg }, synthToken(node.location));
	} else if (node.kind === NodeKind.BlockStmt) {
		const d = node.data as BlockStmtData;
		const newStmts: Node[] = [];
		let i = 0;
		while (i < d.statements.length) {
			newStmts.push(walkNode(d.statements[i]));
			i = i + 1;
		}
		return createNode(NodeKind.BlockStmt, { statements: newStmts }, synthToken(node.location));
	} else if (node.kind === NodeKind.FunctionDecl) {
		const d = node.data as FunctionDeclData;
		const newBody = walkNode(d.fnBody);
		return createNode(NodeKind.FunctionDecl, {
			fnName: d.fnName, params: d.params, fnParamTypes: d.fnParamTypes,
			fnBody: newBody, fnFlags: d.fnFlags, fnReturnType: d.fnReturnType,
			fnDefaults: d.fnDefaults, nameLocation: d.nameLocation,
		}, synthToken(node.location));
	} else if (node.kind === NodeKind.IfStmt) {
		const d = node.data as IfStmtData;
		const newCons = walkNode(d.consequent);
		const newAlt = walkNode(d.alternate);
		return createNode(NodeKind.IfStmt, {
			condition: d.condition, consequent: newCons, alternate: newAlt,
		}, synthToken(node.location));
	} else if (node.kind === NodeKind.WhileStmt) {
		const d = node.data as WhileStmtData;
		const newBody = walkNode(d.whileBody);
		return createNode(NodeKind.WhileStmt, {
			whileCondition: d.whileCondition, whileBody: newBody,
		}, synthToken(node.location));
	} else if (node.kind === NodeKind.ExportDecl) {
		const d = node.data as ExportDeclData;
		const newDecl = walkNode(d.exportedDecl);
		return createNode(NodeKind.ExportDecl, { exportedDecl: newDecl }, synthToken(node.location));
	} else if (node.kind === NodeKind.Program) {
		const d = node.data as ProgramData;
		const newStmts: Node[] = [];
		let i = 0;
		while (i < d.programStmts.length) {
			newStmts.push(walkNode(d.programStmts[i]));
			i = i + 1;
		}
		return createNode(NodeKind.Program, { programStmts: newStmts }, synthToken(node.location));
	}
	return node;
}

// --- Public API ---

export function evaluateComptimeBlocks(program: Node): Node {
	if (!hasComptimeBlock(program)) return program;
	return walkNode(program);
}

// --- E2E Comptime Tests ---

test "comptime int arithmetic" {
	const pr = parseSource("const VERSION = @comptime { 10 + 5 };");
	assert pr.ok;
	const result = evaluateComptimeBlocks(pr.value);
	const pd = result.data as ProgramData;
	const varDecl = pd.programStmts[0];
	assert varDecl.kind === NodeKind.VariableDecl;
	const vd = varDecl.data as VariableDeclData;
	assert vd.initializer.kind === NodeKind.NumberLiteral;
	const nd = vd.initializer.data as NumberLiteralData;
	assert nd.value === 15;
}

test "comptime string" {
	const pr = parseSource("const PLATFORM = @comptime { \"darwin\" };");
	assert pr.ok;
	const result = evaluateComptimeBlocks(pr.value);
	const pd = result.data as ProgramData;
	const varDecl = pd.programStmts[0];
	const vd = varDecl.data as VariableDeclData;
	assert vd.initializer.kind === NodeKind.StringLiteral;
	const sd = vd.initializer.data as StringLiteralData;
	assert sd.value === "darwin";
}

test "comptime boolean" {
	const pr = parseSource("const DEBUG = @comptime { true };");
	assert pr.ok;
	const result = evaluateComptimeBlocks(pr.value);
	const pd = result.data as ProgramData;
	const varDecl = pd.programStmts[0];
	const vd = varDecl.data as VariableDeclData;
	assert vd.initializer.kind === NodeKind.BooleanLiteral;
	const bd = vd.initializer.data as BooleanLiteralData;
	assert bd.boolValue === true;
}

test "no comptime passes through" {
	const pr = parseSource("const x = 42;");
	assert pr.ok;
	const result = evaluateComptimeBlocks(pr.value);
	assert result === pr.value;
}
