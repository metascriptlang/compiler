// CFG-Based Last-Read Analysis — Mohnen Graph-Free Approach
//
// Matches Nim's dfa.nim: linear instruction array with relative offsets.
// No graph data structure — control flow encoded via goto/fork/loop offsets.
//
// Used by DRC injection to determine if a variable use is the last read,
// enabling MOVE instead of COPY. Handles branches, loops, returns.

import {
	Node, NodeKind, SourceLocation, ProgramData,
	IdentifierData, BinaryExprData, UnaryExprData, CallExprData,
	MemberExprData, ArrayAccessData, ObjectLiteralData, ArrayLiteralData,
	ConditionalExprData, SpreadExprData, NewExprData,
	UpdateExprData, TypeAssertionData, MoveExprData,
	VariableDeclData, ExprStmtData, ReturnStmtData, IfStmtData,
	WhileStmtData, BlockStmtData, TryCatchStmtData,
	SwitchStmtData, SwitchCaseData,
	ThrowStmtData, DoWhileStmtData, FunctionDeclData,
	ExportDeclData, ForStmtData, ForOfStmtData,
} from "../ast/node";
import { check } from "std/testing";
import { parseInput } from "../transform/testUtil";

// ===== Data Structures =====

export enum CfgInstrKind {
	CfgGoto,   // unconditional jump (return, break, goto end)
	CfgLoop,   // backward jump (while loop back-edge)
	CfgFork,   // conditional branch (if-else, while condition)
	CfgDef,    // variable definition/assignment
	CfgUse,    // variable read
}

export interface CfgInstr {
	kind: CfgInstrKind;
	dest: number;      // relative offset for goto/fork/loop
	line: number;      // source location for use/def (matching)
	col: number;
}

export interface Cfg {
	instrs: CfgInstr[];
}

// ===== Builder State =====

interface LoopInfo {
	conditionIdx: number;  // index of loop condition start (for continue → loop)
	breakPatches: number[];  // indices of goto instrs needing patch (for break)
}

interface BuildCtx {
	cfg: CfgInstr[];
	vn: string;
	loops: LoopInfo[];
}

// ===== Instruction Emitters =====

function emitUse(ctx: BuildCtx, line: number, col: number): void {
	const instr: CfgInstr = { kind: CfgInstrKind.CfgUse, dest: 0, line, col };
	ctx.cfg.push(instr);
}

function emitDef(ctx: BuildCtx, line: number, col: number): void {
	const instr: CfgInstr = { kind: CfgInstrKind.CfgDef, dest: 0, line, col };
	ctx.cfg.push(instr);
}

function emitGoto(ctx: BuildCtx): number {
	const idx = ctx.cfg.length;
	const instr: CfgInstr = { kind: CfgInstrKind.CfgGoto, dest: 0, line: 0, col: 0 };
	ctx.cfg.push(instr);
	return idx;
}

function emitFork(ctx: BuildCtx): number {
	const idx = ctx.cfg.length;
	const instr: CfgInstr = { kind: CfgInstrKind.CfgFork, dest: 0, line: 0, col: 0 };
	ctx.cfg.push(instr);
	return idx;
}

function emitLoop(ctx: BuildCtx, targetIdx: number): void {
	const idx = ctx.cfg.length;
	const offset = targetIdx - idx;
	const instr: CfgInstr = { kind: CfgInstrKind.CfgLoop, dest: offset, line: 0, col: 0 };
	ctx.cfg.push(instr);
}

function patchDest(ctx: BuildCtx, instrIdx: number, targetIdx: number): void {
	ctx.cfg[instrIdx].dest = targetIdx - instrIdx;
}

// ===== Expression Walker =====
// Walks expressions looking for uses of varName.

function walkExpr(node: Node, ctx: BuildCtx): void {
	if (node === null) return;

	if (node.kind === NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		if (d.name === ctx.vn) {
			emitUse(ctx, node.location.line, node.location.column);
		}
		return;
	}

	// Don't enter inner functions
	if (node.kind === NodeKind.FunctionDecl || node.kind === NodeKind.ArrowFunction || node.kind === NodeKind.FunctionExpr) return;

	if (node.kind === NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		walkExpr(d.left, ctx);
		walkExpr(d.right, ctx);
		return;
	}
	if (node.kind === NodeKind.UnaryExpr) {
		walkExpr((node.data as UnaryExprData).operand, ctx);
		return;
	}
	if (node.kind === NodeKind.UpdateExpr) {
		walkExpr((node.data as UpdateExprData).updateArg, ctx);
		return;
	}
	if (node.kind === NodeKind.CallExpr) {
		const d = node.data as CallExprData;
		walkExpr(d.callee, ctx);
		for (const arg of d.arguments) { walkExpr(arg, ctx); }
		return;
	}
	if (node.kind === NodeKind.MemberExpr) {
		walkExpr((node.data as MemberExprData).object, ctx);
		return;
	}
	if (node.kind === NodeKind.ArrayAccess) {
		const d = node.data as ArrayAccessData;
		walkExpr(d.array, ctx);
		walkExpr(d.index, ctx);
		return;
	}
	if (node.kind === NodeKind.ObjectLiteral) {
		for (const p of (node.data as ObjectLiteralData).properties) { walkExpr(p, ctx); }
		return;
	}
	if (node.kind === NodeKind.ArrayLiteral) {
		for (const e of (node.data as ArrayLiteralData).elements) { walkExpr(e, ctx); }
		return;
	}
	if (node.kind === NodeKind.ConditionalExpr) {
		const d = node.data as ConditionalExprData;
		walkExpr(d.ternaryCondition, ctx);
		walkExpr(d.ternaryConsequent, ctx);
		walkExpr(d.ternaryAlternate, ctx);
		return;
	}
	if (node.kind === NodeKind.SpreadExpr) {
		walkExpr((node.data as SpreadExprData).spreadArg, ctx);
		return;
	}
	if (node.kind === NodeKind.NewExpr) {
		const d = node.data as NewExprData;
		walkExpr(d.newCallee, ctx);
		for (const a of d.newArguments) { walkExpr(a, ctx); }
		return;
	}
	if (node.kind === NodeKind.TypeAssertion) {
		walkExpr((node.data as TypeAssertionData).asExpr, ctx);
		return;
	}
	if (node.kind === NodeKind.MoveExpr) {
		walkExpr((node.data as MoveExprData).moveArg, ctx);
		return;
	}
}

// ===== Statement Walker =====
// Walks statements, emitting CFG instructions for control flow + def/use.

function walkStmt(node: Node, ctx: BuildCtx): void {
	if (node === null) return;

	// Don't enter inner functions
	if (node.kind === NodeKind.FunctionDecl || node.kind === NodeKind.ArrowFunction || node.kind === NodeKind.FunctionExpr) return;

	if (node.kind === NodeKind.Program) {
		const d = node.data as ProgramData;
		for (const s of d.programStmts) { walkStmt(s, ctx); }
		return;
	}

	if (node.kind === NodeKind.BlockStmt) {
		const d = node.data as BlockStmtData;
		for (const s of d.statements) { walkStmt(s, ctx); }
		return;
	}

	if (node.kind === NodeKind.ExprStmt) {
		const d = node.data as ExprStmtData;
		// Check for assignment: x = expr (def on LHS, use on RHS)
		if (d.expr !== null && d.expr.kind === NodeKind.BinaryExpr) {
			const bd = d.expr.data as BinaryExprData;
			if (bd.operator === "=" || bd.operator === "+=" || bd.operator === "-=" || bd.operator === "*=" || bd.operator === "/=") {
				// RHS first (uses before def)
				walkExpr(bd.right, ctx);
				// LHS: if direct assignment to varName, emit def
				if (bd.left !== null && bd.left.kind === NodeKind.Identifier) {
					const ld = bd.left.data as IdentifierData;
					if (ld.name === ctx.vn) {
						if (bd.operator === "=") {
							emitDef(ctx, bd.left.location.line, bd.left.location.column);
						} else {
							// Compound: read + write
							emitUse(ctx, bd.left.location.line, bd.left.location.column);
							emitDef(ctx, bd.left.location.line, bd.left.location.column);
						}
						return;
					}
				}
				// LHS is not our var — walk both sides for uses
				walkExpr(bd.left, ctx);
				return;
			}
		}
		walkExpr(d.expr, ctx);
		return;
	}

	if (node.kind === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		// Initializer first (RHS uses before def)
		walkExpr(d.initializer, ctx);
		if (d.declName === ctx.vn) {
			emitDef(ctx, node.location.line, node.location.column);
		}
		return;
	}

	if (node.kind === NodeKind.ReturnStmt) {
		walkExpr((node.data as ReturnStmtData).argument, ctx);
		// goto end of CFG (patched to jump past all instructions)
		const gotoIdx = emitGoto(ctx);
		patchDest(ctx, gotoIdx, 99999);  // sentinel: end of CFG
		return;
	}

	if (node.kind === NodeKind.ThrowStmt) {
		walkExpr((node.data as ThrowStmtData).throwArg, ctx);
		const gotoIdx = emitGoto(ctx);
		patchDest(ctx, gotoIdx, 99999);
		return;
	}

	if (node.kind === NodeKind.IfStmt) {
		const d = node.data as IfStmtData;
		// Condition
		walkExpr(d.condition, ctx);
		// Fork: if false, jump to else
		const forkIdx = emitFork(ctx);
		// Then branch
		walkStmt(d.consequent, ctx);
		if (d.alternate !== null) {
			// Goto: skip else branch
			const gotoIdx = emitGoto(ctx);
			// Patch fork to else start
			patchDest(ctx, forkIdx, ctx.cfg.length);
			// Else branch
			walkStmt(d.alternate, ctx);
			// Patch goto to after else
			patchDest(ctx, gotoIdx, ctx.cfg.length);
		} else {
			// No else: fork jumps to after then
			patchDest(ctx, forkIdx, ctx.cfg.length);
		}
		return;
	}

	if (node.kind === NodeKind.WhileStmt) {
		const d = node.data as WhileStmtData;
		// Loop info for break/continue
		const loopInfo: LoopInfo = { conditionIdx: ctx.cfg.length, breakPatches: [] };
		ctx.loops.push(loopInfo);
		// Condition
		walkExpr(d.whileCondition, ctx);
		// Fork: if false, exit loop
		const forkIdx = emitFork(ctx);
		// Body
		walkStmt(d.whileBody, ctx);
		// Loop back to condition
		emitLoop(ctx, loopInfo.conditionIdx);
		// Patch fork to after loop
		patchDest(ctx, forkIdx, ctx.cfg.length);
		// Patch all break gotos
		for (const bIdx of loopInfo.breakPatches) {
			patchDest(ctx, bIdx, ctx.cfg.length);
		}
		ctx.loops.pop();
		return;
	}

	if (node.kind === NodeKind.DoWhileStmt) {
		const d = node.data as DoWhileStmtData;
		const loopStart = ctx.cfg.length;
		const loopInfo: LoopInfo = { conditionIdx: loopStart, breakPatches: [] };
		ctx.loops.push(loopInfo);
		// Body
		walkStmt(d.doBody, ctx);
		// Condition
		walkExpr(d.doCondition, ctx);
		// Fork: if true, loop back (Nim pattern: fork can go either way)
		const forkIdx = emitFork(ctx);
		patchDest(ctx, forkIdx, loopStart);
		// Patch break gotos
		for (const bIdx of loopInfo.breakPatches) {
			patchDest(ctx, bIdx, ctx.cfg.length);
		}
		ctx.loops.pop();
		return;
	}

	if (node.kind === NodeKind.BreakStmt) {
		if (ctx.loops.length > 0) {
			const gotoIdx = emitGoto(ctx);
			const loop = ctx.loops[ctx.loops.length - 1];
			loop.breakPatches.push(gotoIdx);
		}
		return;
	}

	if (node.kind === NodeKind.ContinueStmt) {
		if (ctx.loops.length > 0) {
			const loop = ctx.loops[ctx.loops.length - 1];
			emitLoop(ctx, loop.conditionIdx);
		}
		return;
	}

	if (node.kind === NodeKind.TryCatchStmt) {
		const d = node.data as TryCatchStmtData;
		// Try body
		walkStmt(d.tryBody, ctx);
		// Fork: try might throw → jump to catch
		const forkIdx = emitFork(ctx);
		// Goto past catch (try succeeded)
		const gotoIdx = emitGoto(ctx);
		// Catch
		patchDest(ctx, forkIdx, ctx.cfg.length);
		walkStmt(d.catchBody, ctx);
		// Patch goto to after catch
		patchDest(ctx, gotoIdx, ctx.cfg.length);
		// Finally (always executes — walk on both paths)
		walkStmt(d.finallyBody, ctx);
		return;
	}

	if (node.kind === NodeKind.SwitchStmt) {
		const d = node.data as SwitchStmtData;
		walkExpr(d.switchDisc, ctx);
		// Each case as fork-chain (simplified)
		for (const c of d.switchCases) {
			walkStmt(c, ctx);
		}
		return;
	}

	if (node.kind === NodeKind.SwitchCase) {
		const d = node.data as SwitchCaseData;
		for (const t of d.caseTests) { walkExpr(t, ctx); }
		for (const s of d.caseStmts) { walkStmt(s, ctx); }
		return;
	}

	if (node.kind === NodeKind.ExportDecl) {
		walkStmt((node.data as ExportDeclData).exportedDecl, ctx);
		return;
	}

	if (node.kind === NodeKind.ForStmt) {
		const d = node.data as ForStmtData;
		walkStmt(d.forInit, ctx);
		const condIdx = ctx.cfg.length;
		const loopInfo: LoopInfo = { conditionIdx: condIdx, breakPatches: [] };
		ctx.loops.push(loopInfo);
		walkExpr(d.forCondition, ctx);
		const forkIdx = emitFork(ctx);
		walkStmt(d.forBody, ctx);
		walkStmt(d.forUpdate, ctx);
		emitLoop(ctx, condIdx);
		patchDest(ctx, forkIdx, ctx.cfg.length);
		for (const bIdx of loopInfo.breakPatches) {
			patchDest(ctx, bIdx, ctx.cfg.length);
		}
		ctx.loops.pop();
		return;
	}

	if (node.kind === NodeKind.ForOfStmt) {
		const d = node.data as ForOfStmtData;
		walkExpr(d.forOfIterable, ctx);
		const condIdx = ctx.cfg.length;
		const loopInfo: LoopInfo = { conditionIdx: condIdx, breakPatches: [] };
		ctx.loops.push(loopInfo);
		const forkIdx = emitFork(ctx);
		walkStmt(d.forOfBody, ctx);
		emitLoop(ctx, condIdx);
		patchDest(ctx, forkIdx, ctx.cfg.length);
		for (const bIdx of loopInfo.breakPatches) {
			patchDest(ctx, bIdx, ctx.cfg.length);
		}
		ctx.loops.pop();
		return;
	}
}

// ===== Public API =====

export function buildCfg(body: Node, vn: string): Cfg {
	const ctx: BuildCtx = {
		cfg: [],
		vn,
		loops: [],
	};
	walkStmt(body, ctx);
	// Patch sentinel gotos (99999) to actual end
	const endIdx = ctx.cfg.length;
	for (let i = 0; i < ctx.cfg.length; i += 1) {
		if (ctx.cfg[i].kind === CfgInstrKind.CfgGoto) {
			const target = i + ctx.cfg[i].dest;
			if (target >= 99999) {
				patchDest(ctx, i, endIdx);
			}
		}
	}
	return { instrs: ctx.cfg };
}

// ===== Last-Read Query: BFS (Nim's isLastReadImpl) =====

export function isLastReadCfg(cfg: Cfg, line: number, col: number): boolean {
	const instrs = cfg.instrs;
	const len = instrs.length;

	// Find the use instruction matching this location
	let j = 0;
	while (j < len) {
		const instr = instrs[j];
		if (instr.kind === CfgInstrKind.CfgUse && instr.line === line && instr.col === col) break;
		j = j + 1;
	}
	if (j >= len) return true;  // use not found in CFG — conservatively say last read

	// BFS from j+1: explore all forward paths
	// If any path finds another use before a def → not last read
	const pcs: number[] = [];
	pcs.push(j + 1);
	// Visited set: use number array (0=unvisited, 1=visited; no bool array in runtime)
	const visited: number[] = [];
	let vi = 0;
	while (vi < len + 1) {
		visited.push(0);
		vi = vi + 1;
	}

	while (pcs.length > 0) {
		let pc = pcs.pop();

		while (pc >= 0 && pc < len) {
			if (visited[pc] === 1) break;
			visited[pc] = 1;

			const instr = instrs[pc];

			if (instr.kind === CfgInstrKind.CfgLoop) {
				const target = pc + instr.dest;
				if (target >= 0 && target < len && visited[target] === 0) {
					pc = target;
				} else {
					break;  // already visited back-edge
				}
			} else if (instr.kind === CfgInstrKind.CfgGoto) {
				const target = pc + instr.dest;
				pc = target;
			} else if (instr.kind === CfgInstrKind.CfgFork) {
				// Queue fallthrough path, follow fork target
				const fallthrough = pc + 1;
				if (fallthrough < len && visited[fallthrough] === 0) {
					pcs.push(fallthrough);
				}
				const target = pc + instr.dest;
				pc = target;
			} else if (instr.kind === CfgInstrKind.CfgUse) {
				// Another use of this variable reachable — NOT last read
				return false;
			} else if (instr.kind === CfgInstrKind.CfgDef) {
				// Variable redefined on this path — this path is safe
				break;
			} else {
				pc = pc + 1;
			}
		}
		// pc >= len or < 0: reached end of CFG on this path — safe (no more uses)
	}

	return true;
}

// ===== Convenience Wrapper =====

export function isLastReadViaCfg(cfg: Cfg, node: Node): boolean {
	return isLastReadCfg(cfg, node.location.line, node.location.column);
}

// ===== CFG Cache =====

export interface CfgCacheEntry {
	varName: string;
	cfg: Cfg;
}

export interface CfgCache {
	entries: CfgCacheEntry[];
}

export function createCfgCache(): CfgCache {
	return { entries: [] };
}

export function getCachedCfg(cache: CfgCache, vn: string): Cfg {
	for (const entry of cache.entries) {
		if (entry.varName === vn) return entry.cfg;
	}
	return null as unknown as Cfg;
}

export function cacheCfg(cache: CfgCache, vn: string, cfg: Cfg): void {
	const entry: CfgCacheEntry = { varName: vn, cfg };
	cache.entries.push(entry);
}

export function clearCfgCache(cache: CfgCache): void {
	while (cache.entries.length > 0) {
		cache.entries.pop();
	}
}

// ===== Test Helpers =====

function getBody(code: string): Node {
	const result = parseInput(code);
	if (!result.ok) return null as unknown as Node;
	return result.value;
}

function countKind(code: string, vn: string, kind: CfgInstrKind): number {
	const body = getBody(code);
	if (body === null) return 0;
	const cfg = buildCfg(body, vn);
	let count = 0;
	for (const instr of cfg.instrs) {
		if (instr.kind === kind) count = count + 1;
	}
	return count;
}

// ===== Tests =====
test "simple use" {
	const vn = "a";
	const ts = "const a = 1; foo(a);";
	check(countKind(ts, vn, CfgInstrKind.CfgUse) === 1);
	check(countKind(ts, vn, CfgInstrKind.CfgDef) === 1);
}

test "multiple uses" {
	const vn = "a";
	const ts = "const a = 1; foo(a); bar(a);";
	check(countKind(ts, vn, CfgInstrKind.CfgUse) === 2);
}

test "assignment is def" {
	const vn = "a";
	const ts = "let a = 1; a = 2;";
	check(countKind(ts, vn, CfgInstrKind.CfgDef) === 2);
}

test "if-else has fork" {
	const vn = "x";
	const ts = "if (c) { foo(x); } else { bar(x); }";
	check(countKind(ts, vn, CfgInstrKind.CfgFork) === 1);
}

test "while has fork and loop" {
	const vn = "x";
	const ts = "while (c) { foo(x); }";
	check(countKind(ts, vn, CfgInstrKind.CfgFork) === 1);
	check(countKind(ts, vn, CfgInstrKind.CfgLoop) === 1);
}

test "return has goto" {
	const vn = "x";
	const ts = "foo(x); return x;";
	check(countKind(ts, vn, CfgInstrKind.CfgGoto) === 1);
}

test "function boundary stops" {
	const vn = "x";
	const ts = "const x = 1; function f() { return x; }";
	check(countKind(ts, vn, CfgInstrKind.CfgUse) === 0);
	check(countKind(ts, vn, CfgInstrKind.CfgDef) === 1);
}

test "last stmt is last read" {
	const ts = "const a = 1; const b = a;";
	const body = getBody(ts);
	if (body === null) { check(false); return; }
	const vn = "a";
	const cfg = buildCfg(body, vn);
	// Find the use of a
	let useLine = 0;
	let useCol = 0;
	for (const instr of cfg.instrs) {
		if (instr.kind === CfgInstrKind.CfgUse) {
			useLine = instr.line;
			useCol = instr.col;
		}
	}
	check(isLastReadCfg(cfg, useLine, useCol));
}

test "not last when used after" {
	const ts = "const a = 1; const b = a; const c = a;";
	const body = getBody(ts);
	if (body === null) { check(false); return; }
	const vn = "a";
	const cfg = buildCfg(body, vn);
	// Find first use of a
	let useLine = 0;
	let useCol = 0;
	for (const instr of cfg.instrs) {
		if (instr.kind === CfgInstrKind.CfgUse) {
			useLine = instr.line;
			useCol = instr.col;
			break;
		}
	}
	check(!isLastReadCfg(cfg, useLine, useCol));
}

test "branch merge: both branches consume" {
	// KEY TEST: x used in both branches, not after → last read before if
	const ts = "const x = getValue(); if (c) { use(x); } else { other(x); }";
	const body = getBody(ts);
	if (body === null) { check(false); return; }
	const vn = "x";
	const cfg = buildCfg(body, vn);
	// Find uses of x (getValue() init is a def, not use)
	let firstUseLine = 0;
	let firstUseCol = 0;
	let useCount = 0;
	for (const instr of cfg.instrs) {
		if (instr.kind === CfgInstrKind.CfgUse) {
			if (useCount === 0) {
				firstUseLine = instr.line;
				firstUseCol = instr.col;
			}
			useCount = useCount + 1;
		}
	}
	// Both branches use x, but each branch's use is last on its path
	check(useCount === 2);
	check(isLastReadCfg(cfg, firstUseLine, firstUseCol));
}

test "branch merge: used after if is not last read" {
	const ts = "const x = getValue(); if (c) { use(x); } else { other(x); } final(x);";
	const body = getBody(ts);
	if (body === null) { check(false); return; }
	const vn = "x";
	const cfg = buildCfg(body, vn);
	// First use should not be last read (final(x) follows)
	let firstUseLine = 0;
	let firstUseCol = 0;
	for (const instr of cfg.instrs) {
		if (instr.kind === CfgInstrKind.CfgUse) {
			firstUseLine = instr.line;
			firstUseCol = instr.col;
			break;
		}
	}
	check(!isLastReadCfg(cfg, firstUseLine, firstUseCol));
}

test "def in one branch makes other last-read" {
	// x is used in if-branch, then reassigned in else-branch
	const ts = "let x = 1; if (c) { use(x); } else { x = 2; } foo(x);";
	const body = getBody(ts);
	if (body === null) { check(false); return; }
	const vn = "x";
	const cfg = buildCfg(body, vn);
	// The use in use(x) in the if-branch: foo(x) follows on that path → not last read
	let firstUseLine = 0;
	let firstUseCol = 0;
	for (const instr of cfg.instrs) {
		if (instr.kind === CfgInstrKind.CfgUse) {
			firstUseLine = instr.line;
			firstUseCol = instr.col;
			break;
		}
	}
	check(!isLastReadCfg(cfg, firstUseLine, firstUseCol));
}

test "return terminates path" {
	// After return, outer scope is unreachable on this path
	const ts = "const x = 1; if (c) { return x; } foo(x);";
	const body = getBody(ts);
	if (body === null) { check(false); return; }
	const vn = "x";
	const cfg = buildCfg(body, vn);
	// Find the use in "return x"
	let returnUseLine = 0;
	let returnUseCol = 0;
	let useCount = 0;
	for (const instr of cfg.instrs) {
		if (instr.kind === CfgInstrKind.CfgUse) {
			if (useCount === 0) {
				returnUseLine = instr.line;
				returnUseCol = instr.col;
			}
			useCount = useCount + 1;
		}
	}
	// The first use (return x) is last read on its path because return terminates
	check(isLastReadCfg(cfg, returnUseLine, returnUseCol));
}

test "loop use is not last read" {
	// x used in loop body — loop repeats → not last read
	const ts = "const x = 1; while (c) { use(x); }";
	const body = getBody(ts);
	if (body === null) { check(false); return; }
	const vn = "x";
	const cfg = buildCfg(body, vn);
	let useLine = 0;
	let useCol = 0;
	for (const instr of cfg.instrs) {
		if (instr.kind === CfgInstrKind.CfgUse) {
			useLine = instr.line;
			useCol = instr.col;
			break;
		}
	}
	check(!isLastReadCfg(cfg, useLine, useCol));
}
