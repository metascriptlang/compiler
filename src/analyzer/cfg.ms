// CFG-Based Last-Read Analysis — Mohnen Graph-Free Approach
//
// Matches the standard data flow implementation: linear instruction array with relative offsets.
// No graph data structure — control flow encoded via goto/fork/loop offsets.
//
// Used by DRC injection to determine if a variable use is the last read,
// enabling MOVE instead of COPY. Handles branches, loops, returns.

import { Node, NodeKind, ProgramData, Symbol, IdentifierData, BinaryExprData, UnaryExprData, CallExprData, MemberExprData, ArrayAccessData, ObjectLiteralData, ArrayLiteralData, ConditionalExprData, SpreadExprData, NewExprData, UpdateExprData, TypeAssertionData, MoveExprData, HiddenDerefData, HiddenStdConvData, VariableDeclData, ExprStmtData, ReturnStmtData, IfStmtData, WhileStmtData, BlockStmtData, TryCatchStmtData, SwitchStmtData, SwitchCaseData, ThrowStmtData, DoWhileStmtData, ExportDeclData, ForStmtData, ForOfStmtData, SymbolKind } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { AliasKind, aliases, getRootSym } from "./alias";
import { makeSymbol } from "../checker/symbol";
import { unknownType } from "../checker/types";

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
	n: Node;           // original AST node for alias-aware comparison (Phase B)
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
	vn: string;              // variable name for name-based matching (backwards compat)
	rootSym: Symbol;         // root symbol for identity-based matching (field-level tracking)
	loops: LoopInfo[];
}

// ===== Instruction Emitters =====

const nullNode = null as unknown as Node;

function emitUse(ctx: BuildCtx, line: number, col: number, node: Node): void {
	const instr: CfgInstr = { kind: CfgInstrKind.CfgUse, dest: 0, line, col, n: node };
	ctx.cfg.push(instr);
}

function emitDef(ctx: BuildCtx, line: number, col: number, node: Node): void {
	const instr: CfgInstr = { kind: CfgInstrKind.CfgDef, dest: 0, line, col, n: node };
	ctx.cfg.push(instr);
}

function emitGoto(ctx: BuildCtx): number {
	const idx = ctx.cfg.length;
	const instr: CfgInstr = { kind: CfgInstrKind.CfgGoto, dest: 0, line: 0, col: 0, n: nullNode };
	ctx.cfg.push(instr);
	return idx;
}

function emitFork(ctx: BuildCtx): number {
	const idx = ctx.cfg.length;
	const instr: CfgInstr = { kind: CfgInstrKind.CfgFork, dest: 0, line: 0, col: 0, n: nullNode };
	ctx.cfg.push(instr);
	return idx;
}

function emitLoop(ctx: BuildCtx, targetIdx: number): void {
	const idx = ctx.cfg.length;
	const offset = targetIdx - idx;
	const instr: CfgInstr = { kind: CfgInstrKind.CfgLoop, dest: offset, line: 0, col: 0, n: nullNode };
	ctx.cfg.push(instr);
}

function patchDest(ctx: BuildCtx, instrIdx: number, targetIdx: number): void {
	ctx.cfg[instrIdx].dest = targetIdx - instrIdx;
}

// ===== Root matching helper =====
// Returns true if the node's root matches the tracked variable (by symbol or name).

function matchesRoot(node: Node, ctx: BuildCtx): boolean {
	if (ctx.rootSym !== null) {
		const root = getRootSym(node);
		return root !== null && root === ctx.rootSym;
	}
	// Name-based fallback (backwards compat for buildCfg)
	const root = getRootSym(node);
	if (root !== null) return root.name === ctx.vn;
	// No resolvedSym — fall back to identifier name check
	return false;
}

function matchesName(node: Node, ctx: BuildCtx): boolean {
	if (node.kind !== NodeKind.Identifier) return false;
	const d = node.data as IdentifierData;
	if (ctx.rootSym !== null) {
		return node.resolvedSym !== null && node.resolvedSym === ctx.rootSym;
	}
	return d.name === ctx.vn;
}

// ===== Expression Walker =====
// Walks expressions looking for uses of the tracked variable.
// When rootSym is set, emits full path nodes (x.f, x[i]) for alias-aware BFS.
// When rootSym is null (name-based), behaves like the original name-only tracking.

function walkExpr(node: Node, ctx: BuildCtx): void {
	if (node === null) return;

	match (node.kind) {
		NodeKind.Identifier => {
			if (matchesName(node, ctx)) {
				emitUse(ctx, node.location.line, node.location.column, node);
			}
		},
		// Don't enter inner functions
		NodeKind.FunctionDecl | NodeKind.ArrowFunction | NodeKind.FunctionExpr => {},
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			walkExpr(d.left, ctx);
			walkExpr(d.right, ctx);
		},
		NodeKind.UnaryExpr => {
			walkExpr((node.data as UnaryExprData).operand, ctx);
		},
		NodeKind.UpdateExpr => {
			walkExpr((node.data as UpdateExprData).updateArg, ctx);
		},
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			walkExpr(d.callee, ctx);
			for (const arg of d.arguments) { walkExpr(arg, ctx); }
		},
		NodeKind.MemberExpr => {
			// Field-level: if root matches, emit use for full path and don't descend
			// (avoids double-counting bare x when we already recorded x.f)
			if (ctx.rootSym !== null && matchesRoot(node, ctx)) {
				emitUse(ctx, node.location.line, node.location.column, node);
			} else {
				walkExpr((node.data as MemberExprData).object, ctx);
			}
		},
		NodeKind.ArrayAccess => {
			const d = node.data as ArrayAccessData;
			// Field-level: if root matches, emit use for full path
			if (ctx.rootSym !== null && matchesRoot(node, ctx)) {
				emitUse(ctx, node.location.line, node.location.column, node);
				// Still walk index for sub-expression uses (e.g. x[x] edge case)
				walkExpr(d.index, ctx);
			} else {
				walkExpr(d.array, ctx);
				walkExpr(d.index, ctx);
			}
		},
		NodeKind.ObjectLiteral => {
			for (const p of (node.data as ObjectLiteralData).properties) { walkExpr(p, ctx); }
		},
		NodeKind.ArrayLiteral => {
			for (const e of (node.data as ArrayLiteralData).elements) { walkExpr(e, ctx); }
		},
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			walkExpr(d.ternaryCondition, ctx);
			walkExpr(d.ternaryConsequent, ctx);
			walkExpr(d.ternaryAlternate, ctx);
		},
		NodeKind.SpreadExpr => {
			walkExpr((node.data as SpreadExprData).spreadArg, ctx);
		},
		NodeKind.NewExpr => {
			const d = node.data as NewExprData;
			walkExpr(d.newCallee, ctx);
			for (const a of d.newArguments) { walkExpr(a, ctx); }
		},
		NodeKind.TypeAssertion => {
			walkExpr((node.data as TypeAssertionData).asExpr, ctx);
		},
		NodeKind.MoveExpr => {
			walkExpr((node.data as MoveExprData).moveArg, ctx);
		},
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => {
			// Field-level: if root matches, emit use for full path (reference: genUse stores orig node)
			if (ctx.rootSym !== null && matchesRoot(node, ctx)) {
				emitUse(ctx, node.location.line, node.location.column, node);
			} else {
				walkExpr((node.data as HiddenDerefData).expr, ctx);
			}
		},
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => {
			walkExpr((node.data as HiddenStdConvData).convExpr, ctx);
		},
		// Default: descend via canonical walker so new expression kinds still
		// contribute def/use edges. Function bodies are explicitly skipped
		// above (higher precedence), so inner functions stay isolated.
		_ => { forEachChild(node, (child: Node): void => { walkExpr(child, ctx); }); },
	};
}

// ===== Statement Walker =====
// Walks statements, emitting CFG instructions for control flow + def/use.

function walkStmt(node: Node, ctx: BuildCtx): void {
	if (node === null) return;

	match (node.kind) {
		// Don't enter inner functions
		NodeKind.FunctionDecl | NodeKind.ArrowFunction | NodeKind.FunctionExpr => {},
		NodeKind.Program => {
			const d = node.data as ProgramData;
			for (const s of d.programStmts) { walkStmt(s, ctx); }
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			for (const s of d.statements) { walkStmt(s, ctx); }
		},
		NodeKind.ExprStmt => {
			const d = node.data as ExprStmtData;
			// Check for assignment: x = expr (def on LHS, use on RHS)
			if (d.expr !== null && d.expr.kind === NodeKind.BinaryExpr) {
				const bd = d.expr.data as BinaryExprData;
				if (bd.operator === "=" || bd.operator === "+=" || bd.operator === "-=" || bd.operator === "*=" || bd.operator === "/=") {
					// RHS first (uses before def)
					walkExpr(bd.right, ctx);
					// LHS: check if it's a direct identifier or field path to our var
					if (bd.left !== null && bd.left.kind === NodeKind.Identifier) {
						if (matchesName(bd.left, ctx)) {
							if (bd.operator === "=") {
								emitDef(ctx, bd.left.location.line, bd.left.location.column, bd.left);
							} else {
								// Compound: read + write
								emitUse(ctx, bd.left.location.line, bd.left.location.column, bd.left);
								emitDef(ctx, bd.left.location.line, bd.left.location.column, bd.left);
							}
							return;
						}
					} else if (bd.left !== null && ctx.rootSym !== null &&
							(bd.left.kind === NodeKind.MemberExpr || bd.left.kind === NodeKind.ArrayAccess)) {
						// Field-level: x.f = expr or x[i] = expr → def on the field path
						if (matchesRoot(bd.left, ctx)) {
							if (bd.operator === "=") {
								emitDef(ctx, bd.left.location.line, bd.left.location.column, bd.left);
							} else {
								emitUse(ctx, bd.left.location.line, bd.left.location.column, bd.left);
								emitDef(ctx, bd.left.location.line, bd.left.location.column, bd.left);
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
		},
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			// Initializer first (RHS uses before def)
			walkExpr(d.initializer, ctx);
			// Match by symbol on the decl node, or by name fallback
			if (ctx.rootSym !== null && node.resolvedSym !== null && node.resolvedSym === ctx.rootSym) {
				emitDef(ctx, node.location.line, node.location.column, node);
			} else if (d.declName === ctx.vn) {
				emitDef(ctx, node.location.line, node.location.column, node);
			}
		},
		NodeKind.ReturnStmt => {
			walkExpr((node.data as ReturnStmtData).argument, ctx);
			// goto end of CFG (patched to jump past all instructions)
			const gotoIdx = emitGoto(ctx);
			patchDest(ctx, gotoIdx, 99999);  // sentinel: end of CFG
		},
		NodeKind.ThrowStmt => {
			walkExpr((node.data as ThrowStmtData).throwArg, ctx);
			const gotoIdx = emitGoto(ctx);
			patchDest(ctx, gotoIdx, 99999);
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			walkExpr(d.condition, ctx);
			const forkIdx = emitFork(ctx);
			walkStmt(d.consequent, ctx);
			if (d.alternate !== null) {
				const gotoIdx = emitGoto(ctx);
				patchDest(ctx, forkIdx, ctx.cfg.length);
				walkStmt(d.alternate, ctx);
				patchDest(ctx, gotoIdx, ctx.cfg.length);
			} else {
				patchDest(ctx, forkIdx, ctx.cfg.length);
			}
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			const loopInfo: LoopInfo = { conditionIdx: ctx.cfg.length, breakPatches: [] };
			ctx.loops.push(loopInfo);
			walkExpr(d.whileCondition, ctx);
			const forkIdx = emitFork(ctx);
			walkStmt(d.whileBody, ctx);
			emitLoop(ctx, loopInfo.conditionIdx);
			patchDest(ctx, forkIdx, ctx.cfg.length);
			for (const bIdx of loopInfo.breakPatches) {
				patchDest(ctx, bIdx, ctx.cfg.length);
			}
			ctx.loops.pop();
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			const loopStart = ctx.cfg.length;
			const loopInfo: LoopInfo = { conditionIdx: loopStart, breakPatches: [] };
			ctx.loops.push(loopInfo);
			walkStmt(d.doBody, ctx);
			walkExpr(d.doCondition, ctx);
			const forkIdx = emitFork(ctx);
			patchDest(ctx, forkIdx, loopStart);
			for (const bIdx of loopInfo.breakPatches) {
				patchDest(ctx, bIdx, ctx.cfg.length);
			}
			ctx.loops.pop();
		},
		NodeKind.BreakStmt => {
			if (ctx.loops.length > 0) {
				const gotoIdx = emitGoto(ctx);
				const loop = ctx.loops[ctx.loops.length - 1];
				loop.breakPatches.push(gotoIdx);
			}
		},
		NodeKind.ContinueStmt => {
			if (ctx.loops.length > 0) {
				const loop = ctx.loops[ctx.loops.length - 1];
				emitLoop(ctx, loop.conditionIdx);
			}
		},
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			walkStmt(d.tryBody, ctx);
			const forkIdx = emitFork(ctx);
			const gotoIdx = emitGoto(ctx);
			patchDest(ctx, forkIdx, ctx.cfg.length);
			walkStmt(d.catchBody, ctx);
			patchDest(ctx, gotoIdx, ctx.cfg.length);
			walkStmt(d.finallyBody, ctx);
		},
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			walkExpr(d.switchDisc, ctx);
			for (const c of d.switchCases) { walkStmt(c, ctx); }
		},
		NodeKind.SwitchCase => {
			const d = node.data as SwitchCaseData;
			for (const t of d.caseTests) { walkExpr(t, ctx); }
			for (const s of d.caseStmts) { walkStmt(s, ctx); }
		},
		NodeKind.ExportDecl => {
			walkStmt((node.data as ExportDeclData).exportedDecl, ctx);
		},
		NodeKind.ForStmt => {
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
		},
		NodeKind.ForOfStmt => {
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
		},
		// Default: for any unknown statement kind, descend via the canonical
		// walker to harvest def/use edges from sub-expressions. CFG control-flow
		// edges (fork/goto/loop) are NOT synthesized for unknown kinds — that's
		// a known degradation, but use tracking remains sound. Post-transform,
		// all known control-flow kinds are listed explicitly above.
		_ => { forEachChild(node, (child: Node): void => { walkExpr(child, ctx); }); },
	};
}

// ===== Public API =====

function finalizeCfg(ctx: BuildCtx): Cfg {
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

export function buildCfg(body: Node, vn: string): Cfg {
	const ctx: BuildCtx = {
		cfg: [],
		vn,
		rootSym: null as unknown as Symbol,
		loops: [],
	};
	walkStmt(body, ctx);
	return finalizeCfg(ctx);
}

export function buildCfgForSym(body: Node, rootSym: Symbol): Cfg {
	const ctx: BuildCtx = {
		cfg: [],
		vn: rootSym !== null ? rootSym.name : "",
		rootSym,
		loops: [],
	};
	walkStmt(body, ctx);
	return finalizeCfg(ctx);
}

// ===== Last-Read Query: BFS (reference isLastRead implementation) =====

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
	if (j >= len) return false;  // use not found in CFG — conservative: assume NOT last read (don't move)

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

// ===== Alias-Aware Last-Read Query (Phase B) =====
// Uses aliases() for field-level comparison instead of line:col matching.
// Reference: isLastReadImpl with bidirectional alias checks.

export function isLastReadCfgNode(cfg: Cfg, queryNode: Node): boolean {
	if (queryNode === null) return false;
	const instrs = cfg.instrs;
	const len = instrs.length;

	// Find the use instruction matching this exact node (by identity)
	let j = 0;
	while (j < len) {
		const instr = instrs[j];
		if (instr.kind === CfgInstrKind.CfgUse && instr.n === queryNode) break;
		j = j + 1;
	}
	if (j >= len) return false;  // use not found — conservative

	// BFS from j+1: explore all forward paths
	const pcs: number[] = [];
	pcs.push(j + 1);
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
					break;
				}
			} else if (instr.kind === CfgInstrKind.CfgGoto) {
				pc = pc + instr.dest;
			} else if (instr.kind === CfgInstrKind.CfgFork) {
				const fallthrough = pc + 1;
				if (fallthrough < len && visited[fallthrough] === 0) {
					pcs.push(fallthrough);
				}
				pc = pc + instr.dest;
			} else if (instr.kind === CfgInstrKind.CfgUse) {
				// Bidirectional alias check: does this other use alias our query?
				if (instr.n !== null) {
					if (aliases(instr.n, queryNode) !== AliasKind.No || aliases(queryNode, instr.n) !== AliasKind.No) {
						return false;  // another aliasing use reachable
					}
				}
				// Non-aliasing use (different field) → safe, continue
				pc = pc + 1;
			} else if (instr.kind === CfgInstrKind.CfgDef) {
				// Check if this def fully overwrites our query location
				if (instr.n !== null) {
					if (aliases(instr.n, queryNode) === AliasKind.Yes) {
						break;  // full overwrite → path safe
					} else if (aliases(queryNode, instr.n) !== AliasKind.No) {
						return false;  // partial write reads from variable → not safe
					}
				}
				// Def on unrelated path → continue
				pc = pc + 1;
			} else {
				pc = pc + 1;
			}
		}
	}

	return true;
}

// ===== CFG Cache =====

export interface CfgCacheEntry {
	varName: string;
	cfg: Cfg;
}

export interface CfgCache {
	entries: CfgCacheEntry[];      // name-based CFGs (buildCfg)
	symEntries: CfgCacheEntry[];   // symbol-based CFGs (buildCfgForSym) — separate to avoid collision
}

export function createCfgCache(): CfgCache {
	return { entries: [], symEntries: [] };
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
	while (cache.symEntries.length > 0) {
		cache.symEntries.pop();
	}
}

// ===== Cached Last-Read Query (Phase C) =====
// Builds CFG once per variable per function, caches for reuse.

export function isLastReadCfgCached(varName: string, node: Node, funcBody: Node, cache: CfgCache): boolean {
	if (node === null || funcBody === null) return false;
	let cfg = getCachedCfg(cache, varName);
	if (cfg === null) {
		cfg = buildCfg(funcBody, varName);
		cacheCfg(cache, varName, cfg);
	}
	return isLastReadCfg(cfg, node.location.line, node.location.column);
}

// ===== Alias-Aware Cached Last-Read Query (Phase B) =====
// Builds CFG once per root symbol per function, caches for reuse.
// Uses isLastReadCfgNode for field-level alias comparison.

function getCachedCfgBySym(cache: CfgCache, rootSym: Symbol): Cfg {
	for (const entry of cache.symEntries) {
		if (entry.varName === rootSym.name) return entry.cfg;
	}
	return null as unknown as Cfg;
}

export function isLastReadCfgNodeCached(rootSym: Symbol, queryNode: Node, funcBody: Node, cache: CfgCache): boolean {
	if (rootSym === null || queryNode === null || funcBody === null) return false;
	let cfg = getCachedCfgBySym(cache, rootSym);
	if (cfg === null) {
		cfg = buildCfgForSym(funcBody, rootSym);
		const entry: CfgCacheEntry = { varName: rootSym.name, cfg };
		cache.symEntries.push(entry);
	}
	return isLastReadCfgNode(cfg, queryNode);
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

function findFirstUse(cfg: Cfg): CfgInstr {
	for (const instr of cfg.instrs) {
		if (instr.kind === CfgInstrKind.CfgUse) return instr;
	}
	return null as unknown as CfgInstr;
}

function findLastUse(cfg: Cfg): CfgInstr {
	let last: CfgInstr = null as unknown as CfgInstr;
	for (const instr of cfg.instrs) {
		if (instr.kind === CfgInstrKind.CfgUse) last = instr;
	}
	return last;
}

// ===== Tests =====
test "simple use" {
	const vn = "a";
	const ts = "const a = 1; foo(a);";
	assert countKind(ts, vn, CfgInstrKind.CfgUse) === 1;
	assert countKind(ts, vn, CfgInstrKind.CfgDef) === 1;
}

test "multiple uses" {
	const vn = "a";
	const ts = "const a = 1; foo(a); bar(a);";
	assert countKind(ts, vn, CfgInstrKind.CfgUse) === 2;
}

test "assignment is def" {
	const vn = "a";
	const ts = "let a = 1; a = 2;";
	assert countKind(ts, vn, CfgInstrKind.CfgDef) === 2;
}

test "if-else has fork" {
	const vn = "x";
	const ts = "if (c) { foo(x); } else { bar(x); }";
	assert countKind(ts, vn, CfgInstrKind.CfgFork) === 1;
}

test "while has fork and loop" {
	const vn = "x";
	const ts = "while (c) { foo(x); }";
	assert countKind(ts, vn, CfgInstrKind.CfgFork) === 1;
	assert countKind(ts, vn, CfgInstrKind.CfgLoop) === 1;
}

test "return has goto" {
	const vn = "x";
	const ts = "foo(x); return x;";
	assert countKind(ts, vn, CfgInstrKind.CfgGoto) === 1;
}

test "function boundary stops" {
	const vn = "x";
	const ts = "const x = 1; function f() { return x; }";
	assert countKind(ts, vn, CfgInstrKind.CfgUse) === 0;
	assert countKind(ts, vn, CfgInstrKind.CfgDef) === 1;
}

test "last stmt is last read" {
	const ts = "const a = 1; const b = a;";
	const body = getBody(ts);
	if (body === null) { assert false; return; }
	const cfg = buildCfg(body, "a");
	const use = findLastUse(cfg);
	assert isLastReadCfg(cfg, use.line, use.col);
}

test "not last when used after" {
	const ts = "const a = 1; const b = a; const c = a;";
	const body = getBody(ts);
	if (body === null) { assert false; return; }
	const cfg = buildCfg(body, "a");
	const use = findFirstUse(cfg);
	assert !isLastReadCfg(cfg, use.line, use.col);
}

test "branch merge: both branches consume" {
	// KEY TEST: x used in both branches, not after → last read before if
	const ts = "const x = getValue(); if (c) { use(x); } else { other(x); }";
	const body = getBody(ts);
	if (body === null) { assert false; return; }
	const cfg = buildCfg(body, "x");
	assert countKind(ts, "x", CfgInstrKind.CfgUse) === 2;
	const use = findFirstUse(cfg);
	assert isLastReadCfg(cfg, use.line, use.col);
}

test "branch merge: used after if is not last read" {
	const ts = "const x = getValue(); if (c) { use(x); } else { other(x); } final(x);";
	const body = getBody(ts);
	if (body === null) { assert false; return; }
	const cfg = buildCfg(body, "x");
	const use = findFirstUse(cfg);
	assert !isLastReadCfg(cfg, use.line, use.col);
}

test "def in one branch makes other last-read" {
	// x is used in if-branch, then reassigned in else-branch
	const ts = "let x = 1; if (c) { use(x); } else { x = 2; } foo(x);";
	const body = getBody(ts);
	if (body === null) { assert false; return; }
	const cfg = buildCfg(body, "x");
	// The use in use(x) in the if-branch: foo(x) follows on that path → not last read
	const use = findFirstUse(cfg);
	assert !isLastReadCfg(cfg, use.line, use.col);
}

test "return terminates path" {
	// After return, outer scope is unreachable on this path
	const ts = "const x = 1; if (c) { return x; } foo(x);";
	const body = getBody(ts);
	if (body === null) { assert false; return; }
	const cfg = buildCfg(body, "x");
	// The first use (return x) is last read on its path because return terminates
	const use = findFirstUse(cfg);
	assert isLastReadCfg(cfg, use.line, use.col);
}

test "loop use is not last read" {
	// x used in loop body — loop repeats → not last read
	const ts = "const x = 1; while (c) { use(x); }";
	const body = getBody(ts);
	if (body === null) { assert false; return; }
	const cfg = buildCfg(body, "x");
	const use = findFirstUse(cfg);
	assert !isLastReadCfg(cfg, use.line, use.col);
}

// ===== Field-Level Tests (Phase B: alias-aware BFS) =====

function makeTestSym(name: string): Symbol {
	return makeSymbol(name, SymbolKind.Variable, unknownType(), false);
}

// Test helper: walk a subtree and attach `sym` to every Identifier whose
// name matches `name`. Also tags matching VariableDecl nodes directly.
// Scope boundaries (nested function bodies) terminate recursion.
function attachSymAll(node: Node, name: string, sym: Symbol): void {
	if (node === null) return;
	if (node.kind === NodeKind.Identifier) {
		if ((node.data as IdentifierData).name === name) node.resolvedSym = sym;
		return;
	}
	if (node.kind === NodeKind.VariableDecl) {
		if ((node.data as VariableDeclData).declName === name) node.resolvedSym = sym;
	}
	if (node.kind === NodeKind.FunctionDecl
		|| node.kind === NodeKind.ArrowFunction
		|| node.kind === NodeKind.FunctionExpr) return;
	forEachChild(node, (c: Node): void => { attachSymAll(c, name, sym); });
}

// Test helper alias kept for backward compatibility with existing test call sites.
function attachSymToStmts(body: Node, name: string, sym: Symbol): void {
	attachSymAll(body, name, sym);
}

test "field-level: x.b last-read when only x.a used later" {
	const ts = "foo(x.b); bar(x.a);";
	const body = getBody(ts);
	if (body === null) { assert false; return; }
	const symX = makeTestSym("x");
	attachSymToStmts(body, "x", symX);
	const cfg = buildCfgForSym(body, symX);
	// Find the x.b use node (first arg of first call)
	const d = (body.data as ProgramData).programStmts;
	const firstArg = ((d[0].data as ExprStmtData).expr.data as CallExprData).arguments[0];
	assert isLastReadCfgNode(cfg, firstArg);  // x.b IS last-read (x.a is different field)
}

test "field-level: x.a not last-read when x.a used again" {
	const ts = "foo(x.a); bar(x.a);";
	const body = getBody(ts);
	if (body === null) { assert false; return; }
	const symX = makeTestSym("x");
	attachSymToStmts(body, "x", symX);
	const cfg = buildCfgForSym(body, symX);
	const d = (body.data as ProgramData).programStmts;
	const firstArg = ((d[0].data as ExprStmtData).expr.data as CallExprData).arguments[0];
	assert !isLastReadCfgNode(cfg, firstArg);  // x.a NOT last-read (used again)
}

test "field-level: x.a not last-read when whole x used later" {
	const ts = "foo(x.a); bar(x);";
	const body = getBody(ts);
	if (body === null) { assert false; return; }
	const symX = makeTestSym("x");
	attachSymToStmts(body, "x", symX);
	const cfg = buildCfgForSym(body, symX);
	const d = (body.data as ProgramData).programStmts;
	const firstArg = ((d[0].data as ExprStmtData).expr.data as CallExprData).arguments[0];
	assert !isLastReadCfgNode(cfg, firstArg);  // x.a NOT last-read (x contains x.a)
}

test "field-level: x.f last-read when x.g assigned later" {
	const ts = "foo(x.f); x.g = 1;";
	const body = getBody(ts);
	if (body === null) { assert false; return; }
	const symX = makeTestSym("x");
	attachSymToStmts(body, "x", symX);
	const cfg = buildCfgForSym(body, symX);
	const d = (body.data as ProgramData).programStmts;
	const firstArg = ((d[0].data as ExprStmtData).expr.data as CallExprData).arguments[0];
	assert isLastReadCfgNode(cfg, firstArg);  // x.f IS last-read (x.g def doesn't alias x.f)
}
