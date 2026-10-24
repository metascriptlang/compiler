// Cursor Inference — Steensgaard's union-find algorithm (reference parity)
//
// Two-pass analysis before DRC injection:
//   Pass 1 (computeLiveRanges): collect variables, track alive ranges, mark reassigned
//   Pass 2 (traverse): build variable graphs via union-find, track mutations
//
// A "cursor" is a variable that:
//   - Does not own data (initialized from borrow, not constructor/call)
//   - Is not explicitly prevented (not addr-taken, not passed to mutable param)
//   - Is not conditionally reassigned in a loop, unless it is a read-only view that borrows only
//     from parameters and from other view cursors: repointing a view releases nothing
//   - Its graph is not mutated during its lifetime (dangerousMutation check)
//
// Safety: conservative — false negatives are fine (treated as owned),
// false positives would be unsound (dangling pointer).

import {
	Node, NodeFlag, NodeKind, Symbol, Type, TypeKind,
	VariableDeclData, MemberExprData, ArrayAccessData,
	BlockStmtData, ExprStmtData, ReturnStmtData, IfStmtData,
	WhileStmtData, ForStmtData, DoWhileStmtData,
	TryCatchStmtData, CallExprData, BinaryExprData,
	ObjectLiteralData, ArrayLiteralData, ConditionalExprData,
	ThrowStmtData, SwitchStmtData, SwitchCaseData,
	FunctionDeclData,
	MoveExprData, SpreadExprData, NewExprData,
	ExportDeclData, ProgramData,
	TypeAssertionData, HiddenStdConvData,
} from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { setFlag, hasFlag, isCursorSym, SymbolFlag, findOverloadImpl } from "../checker/symbol";
import { parseSource } from "../parser/statements/validation";
import { checkProgram } from "../checker/checkPass";
import { CK_ROOT_OF, Partitions, createPartitions, variableId, registerVariable as registerPartitionVariable, ufRoot, ufConnect, potentialMutation, dangerousMutation, containsPointer } from "../checker/varPartitions";
import { calledRoutineType, isImmutableModuleConst, isViewCall, receiverOf, viewCallSources } from "../checker/effects";
import { ANY_HEAP_SLOT, addressSlots, callerDefsOf, callsPlainRoutine, canAlias, createRoutineDecls, createWriteSummaries, LocalDefs, mayWrite, reachesModuleState, runsHooks, stepSlot, viewReturnSlots, WriteEffects } from "./writeEffects";
import { makeCtx } from "../transform/testUtil";
import { RcInfo, classifyType } from "./classify";
import { isReadonlyView } from "../checker/types";

// ===== VarFlag (per-variable analysis flags) =====

const VF_OWNS_DATA: int32 = 1;
const VF_PREVENT_CURSOR: int32 = 2;
const VF_IS_REASSIGNED: int32 = 4;
const VF_IS_COND_REASSIGNED: int32 = 8;
const VF_IS_PARAM: int32 = 16;

let borrowedSlots: string[][] = [];
let viewSources: int32[][] = [];
let writeSites: Node[] = [];
let writeTimes: int32[] = [];
let analysis: WriteEffects | null = null;

function registerVariable(p: Partitions, sym: Symbol | null, isParam: boolean): void {
	registerPartitionVariable(p, sym, isParam, VF_IS_PARAM);
}

// ===== Helpers =====

function isViewVar(p: Partitions, id: int32): boolean {
	const sym = p.vars[id].sym;
	return sym != null && isReadonlyView(sym.symbolType);
}

function getIdentSym(node: Node): Symbol | null {
	if (node == null) return null;
	if (node.kind == NodeKind.Identifier) return node.resolvedSym;
	return null;
}

function graphCanHold(holder: Type | null, part: Type | null): boolean {
	return containsPointer(holder, 0) && canAlias(analysis!, part, holder);
}

function lentSources(call: Node): Node[] {
	const sources: Node[] = [];
	viewCallSources(call, sources);
	const formals = calledRoutineType(call)?.typeChildren ?? null;
	const args = (call.data as CallExprData).arguments;
	const shift = call.flags.has(NodeFlag.ExtCall) ? 1 : 0;
	const recv = receiverOf(call);
	const out: Node[] = [];
	for (const a of sources) {
		const fi = a === recv ? shift - 1 : args.indexOf(a) + shift;
		if (formals == null || fi < 0 || fi >= formals.length || graphCanHold(formals[fi], call.nodeType)) out.push(a);
	}
	return out;
}

function lentTempInit(p: Partitions, sym: Symbol | null): Node | null {
	for (let i = 0; i < p.lentTemps.length; i += 1) {
		if (p.lentTemps[i] == sym) return p.lentInits[i];
	}
	return null;
}

function allRoots(p: Partitions, node: Node, result: Symbol[]): void {
	if (node == null) return;
	match (node.kind) {
		NodeKind.Identifier => {
			const lent = lentTempInit(p, node.resolvedSym);
			if (lent != null) allRoots(p, lent, result);
			else if (node.resolvedSym != null) result.push(node.resolvedSym);
		},
		NodeKind.MemberExpr => allRoots(p, (node.data as MemberExprData).object, result),
		NodeKind.ArrayAccess => allRoots(p, (node.data as ArrayAccessData).array, result),
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => allRoots(p, (node.data as { expr: Node }).expr, result),
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => allRoots(p, (node.data as HiddenStdConvData).convExpr, result),
		NodeKind.TypeAssertion => allRoots(p, (node.data as TypeAssertionData).asExpr, result),
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			allRoots(p, d.ternaryConsequent, result);
			allRoots(p, d.ternaryAlternate, result);
		},
		NodeKind.ArrayLiteral => { for (const e of (node.data as ArrayLiteralData).elements) { allRoots(p, e, result); } },
		NodeKind.ObjectLiteral => { for (const e of (node.data as ObjectLiteralData).properties) { allRoots(p, e, result); } },
		NodeKind.SpreadExpr => allRoots(p, (node.data as SpreadExprData).spreadArg, result),
		NodeKind.NewExpr => { for (const a of (node.data as NewExprData).newArguments) { allRoots(p, a, result); } },
		NodeKind.CallExpr => {
			if (isViewCall(node)) {
				for (const a of lentSources(node)) { allRoots(p, a, result); }
			} else if (containsPointer(node.nodeType, 0)) {
				const formals = callFormals(node);
				const receiverFormals = node.flags.has(NodeFlag.ExtCall) ? 1 : 0;
				const args = (node.data as CallExprData).arguments;
				for (let ai = 0; ai < args.length; ai += 1) {
					const fi = ai + receiverFormals;
					if (formals == null || fi >= formals.length || canAlias(analysis!, formals[fi], node.nodeType)) allRoots(p, args[ai], result);
				}
			}
		},
		_ => {},
	};
}

function sourceSlots(w: WriteEffects, p: Partitions, node: Node, out: string[]): void {
	if (node == null) return;
	const slot = stepSlot(w, node);
	if (slot != null) out.push(slot!);
	match (node.kind) {
		NodeKind.Identifier => {
			const lent = lentTempInit(p, node.resolvedSym);
			if (lent != null) sourceSlots(w, p, lent, out);
		},
		NodeKind.MemberExpr => sourceSlots(w, p, (node.data as MemberExprData).object, out),
		NodeKind.ArrayAccess => sourceSlots(w, p, (node.data as ArrayAccessData).array, out),
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => sourceSlots(w, p, (node.data as { expr: Node }).expr, out),
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => sourceSlots(w, p, (node.data as HiddenStdConvData).convExpr, out),
		NodeKind.TypeAssertion => sourceSlots(w, p, (node.data as TypeAssertionData).asExpr, out),
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			sourceSlots(w, p, d.ternaryConsequent, out);
			sourceSlots(w, p, d.ternaryAlternate, out);
		},
		NodeKind.ArrayLiteral => { for (const e of (node.data as ArrayLiteralData).elements) { sourceSlots(w, p, e, out); } },
		NodeKind.ObjectLiteral => { for (const e of (node.data as ObjectLiteralData).properties) { sourceSlots(w, p, e, out); } },
		NodeKind.SpreadExpr => sourceSlots(w, p, (node.data as SpreadExprData).spreadArg, out),
		NodeKind.NewExpr => { for (const a of (node.data as NewExprData).newArguments) { sourceSlots(w, p, a, out); } },
		NodeKind.CallExpr => {
			if (isViewCall(node)) {
				const inner = viewReturnSlots(w, node);
				if (inner == null) out.push(ANY_HEAP_SLOT);
				else for (const slot of inner) out.push(slot);
				for (const a of lentSources(node)) { sourceSlots(w, p, a, out); }
			} else if (containsPointer(node.nodeType, 0)) {
				for (const a of (node.data as CallExprData).arguments) { sourceSlots(w, p, a, out); }
			}
		},
		_ => {},
	};
}

function holdsAddress(sym: Symbol | null): boolean {
	const t = sym != null ? sym.symbolType : null;
	return t == null || t.kind == TypeKind.Borrow || t.kind == TypeKind.Lent || t.kind == TypeKind.Var || t.kind == TypeKind.Ptr;
}

function onlyOtherPartitions(p: Partitions, roots: Symbol[], viewRoot: int32): boolean {
	if (roots.length == 0) return false;
	for (const r of roots) {
		const id = variableId(p, r);
		if (id < 0 || (p.vars[id].flags & (VF_IS_PARAM | VF_PREVENT_CURSOR)) != 0 || ufRoot(p, id) == viewRoot) return false;
	}
	return true;
}

function callArgumentRoots(w: WriteEffects, p: Partitions, call: Node, roots: Symbol[]): boolean {
	const recv = receiverOf(call);
	const operands: Node[] = recv != null ? [recv] : [];
	for (const a of (call.data as CallExprData).arguments) { operands.push(a); }
	for (const a of operands) {
		if (a == null) continue;
		if (runsHooks(w, a) || (a.nodeType != null && a.nodeType.kind == TypeKind.Function)) return false;
		if (containsPointer(a.nodeType, 0)) allRoots(p, a, roots);
	}
	return true;
}

function writesOtherPartition(w: WriteEffects, p: Partitions, site: Node, viewRoot: int32, defs: LocalDefs): boolean {
	const roots: Symbol[] = [];
	if (site.kind == NodeKind.CallExpr) {
		if (!callsPlainRoutine(site) || reachesModuleState(w, site, defs) || !callArgumentRoots(w, p, site, roots)) return false;
		return onlyOtherPartitions(p, roots, viewRoot);
	}
	if (site.kind != NodeKind.BinaryExpr) return false;
	const target = (site.data as BinaryExprData).left;
	if (runsHooks(w, target)) return false;
	allRoots(p, target, roots);
	return onlyOtherPartitions(p, roots, viewRoot);
}

function writtenWhileAlive(w: WriteEffects, p: Partitions, vid: int32, slots: string[], defs: LocalDefs): boolean {
	if (slots.length == 0) return false;
	const v = p.vars[vid];
	const viewRoot = ufRoot(p, vid);
	for (let k = 0; k < writeSites.length; k += 1) {
		if (writeTimes[k] >= v.aliveStart && writeTimes[k] <= v.aliveEnd && mayWrite(w, writeSites[k], slots, defs) && !writesOtherPartition(w, p, writeSites[k], viewRoot, defs)) return true;
	}
	return false;
}

function recordWrite(p: Partitions, site: Node): void {
	writeSites.push(site);
	writeTimes.push(p.abstractTime);
}

function connectStore(p: Partitions, targets: Symbol[], destType: Type | null, src: Node): void {
	if (!containsPointer(destType, 0)) return;
	const sources: Symbol[] = [];
	allRoots(p, src, sources);
	for (const t of targets) {
		for (const s of sources) { ufConnect(p, t, s); }
	}
}

function callFormals(call: Node): Type[] | null {
	let sym = call.resolvedSym;
	if (sym != null) {
		const impl = findOverloadImpl(sym);
		if (impl != null) sym = impl;
	}
	return sym != null && sym.symbolType != null && sym.symbolType.kind == TypeKind.Function ? sym.symbolType.typeChildren : null;
}

function readOnlyFormal(formals: Type[] | null, i: int32): boolean {
	return formals != null && i < formals.length && isReadonlyView(formals[i]);
}

function sinkFormal(formals: Type[] | null, i: int32): boolean {
	return formals != null && i < formals.length && formals[i] != null && formals[i].kind == TypeKind.Sink;
}

function isViewArg(arg: Node): boolean {
	if (isReadonlyView(arg.nodeType)) return true;
	return arg.kind == NodeKind.Identifier && arg.resolvedSym != null && isReadonlyView(arg.resolvedSym.symbolType);
}

function potentialMutationViaArg(p: Partitions, arg: Node): void {
	if (arg == null || arg.kind == NodeKind.HiddenAddr) return;
	if (!containsPointer(arg.nodeType, 0)) return;
	const roots: Symbol[] = [];
	allRoots(p, arg, roots);
	for (const r of roots) { potentialMutation(p, r); }
}

// ===== destMightOwn — determines if dest OWNS data from src =====
// If dest owns → marked ownsData → cannot be cursor.
// If dest borrows → connected via union-find → cursor candidate.

function destMightOwn(p: Partitions, destIdx: int32, src: Node): void {
	if (src == null) return;

	match (src.kind) {
		// Literals: harmless, no ownership
		NodeKind.NumberLiteral | NodeKind.StringLiteral | NodeKind.BooleanLiteral
		| NodeKind.NullLiteral | NodeKind.BigIntLiteral | NodeKind.RegexLiteral => {},

		// Conversions: recurse into inner expression
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => {
			destMightOwn(p, destIdx, (src.data as HiddenStdConvData).convExpr);
		},
		NodeKind.TypeAssertion => {
			destMightOwn(p, destIdx, (src.data as TypeAssertionData).asExpr);
		},

		// Identifier: just a dependency (connect), unless in constructor context
		NodeKind.Identifier => {
			const lent = lentTempInit(p, src.resolvedSym);
			if (lent != null) {
				destMightOwn(p, destIdx, lent);
				return;
			}
			const srcId = variableId(p, src.resolvedSym);
			if (srcId < 0) {
				// Unknown variable (module-level, imported) — unsafe to alias
				if (src.resolvedSym == null || !isImmutableModuleConst(src.resolvedSym)) p.vars[destIdx].flags = p.vars[destIdx].flags | VF_OWNS_DATA;
			} else {
				ufConnect(p, p.vars[destIdx].sym, p.vars[srcId].sym);
				// [x] or {field: x} context — container owns a copy
				if (p.inConstructor > 0) {
					p.vars[destIdx].flags = p.vars[destIdx].flags | VF_OWNS_DATA;
				}
			}
		},

		// Field/array/deref access: recurse into base (borrowing)
		NodeKind.MemberExpr => destMightOwn(p, destIdx, (src.data as MemberExprData).object),
		NodeKind.ArrayAccess => destMightOwn(p, destIdx, (src.data as ArrayAccessData).array),
		NodeKind.HiddenDeref => destMightOwn(p, destIdx, (src.data as { expr: Node }).expr),
		NodeKind.HiddenAddr => destMightOwn(p, destIdx, (src.data as { expr: Node }).expr),

		// Conditional branches: recurse with inConditional flag
		NodeKind.ConditionalExpr => {
			const d = src.data as ConditionalExprData;
			p.inConditional += 1;
			destMightOwn(p, destIdx, d.ternaryConsequent);
			destMightOwn(p, destIdx, d.ternaryAlternate);
			p.inConditional -= 1;
		},

		// Object/array constructors: dest owns data
		NodeKind.ObjectLiteral => {
			const d = src.data as ObjectLiteralData;
			p.inConstructor += 1;
			for (const prop of d.properties) { destMightOwn(p, destIdx, prop); }
			p.inConstructor -= 1;
			p.vars[destIdx].flags = p.vars[destIdx].flags | VF_OWNS_DATA;
		},
		NodeKind.ArrayLiteral => {
			const d = src.data as ArrayLiteralData;
			p.inConstructor += 1;
			for (const elem of d.elements) { destMightOwn(p, destIdx, elem); }
			p.inConstructor -= 1;
			p.vars[destIdx].flags = p.vars[destIdx].flags | VF_OWNS_DATA;
		},

		// Closures: dest owns data
		NodeKind.ArrowFunction | NodeKind.FunctionExpr => {
			p.vars[destIdx].flags = p.vars[destIdx].flags | VF_OWNS_DATA;
		},

		// Calls: return value is constructed → dest owns data
		NodeKind.CallExpr | NodeKind.NewExpr => {
			if (isViewCall(src)) {
				for (const a of lentSources(src)) { destMightOwn(p, destIdx, a); }
			} else {
				p.vars[destIdx].flags = p.vars[destIdx].flags | VF_OWNS_DATA;
			}
		},

		// Move: explicit ownership transfer
		NodeKind.MoveExpr => {
			p.vars[destIdx].flags = p.vars[destIdx].flags | VF_OWNS_DATA;
		},

		// Spread: dest owns
		NodeKind.SpreadExpr => {
			p.vars[destIdx].flags = p.vars[destIdx].flags | VF_OWNS_DATA;
		},

		// Anything else: conservative — prevent cursor
		_ => {
			p.vars[destIdx].flags = p.vars[destIdx].flags | VF_PREVENT_CURSOR;
		},
	};
}

// ===== Pass 1: computeLiveRanges =====
// Walk AST to register variables and compute alive ranges.
// Must traverse in the same order as pass 2 for consistent abstractTime.

function markReassigned(p: Partitions, vid: int32): void {
	p.vars[vid].flags = p.vars[vid].flags | VF_IS_REASSIGNED;
	if (p.inConditional > 0 && p.inLoop > 0) {
		p.vars[vid].flags = p.vars[vid].flags | VF_IS_COND_REASSIGNED;
	}
}

function liveRanges(p: Partitions, node: Node | null): void {
	if (node == null) return;
	p.abstractTime += 1;

	match (node.kind) {
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			liveRanges(p, d.initializer);
			if (d.initializer != null && node.resolvedSym != null && isViewCall(d.initializer) && hasFlag(node.resolvedSym, SymbolFlag.HoistedCall)) {
				p.lentTemps.push(node.resolvedSym);
				p.lentInits.push(d.initializer);
			}
			// A global is never a cursor candidate: the module owns it for the whole program.
			if (node.resolvedSym != null && !hasFlag(node.resolvedSym, SymbolFlag.Global)) registerVariable(p, node.resolvedSym, false);
			// Declared in loop body → effectively reassigned each iteration
			if (p.inLoop > 0 && d.initializer != null) {
				const vid = variableId(p, node.resolvedSym);
				if (vid >= 0) markReassigned(p, vid);
			}
		},

		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			liveRanges(p, d.left);
			liveRanges(p, d.right);
			if (d.operator == "=") {
				const lhs = getIdentSym(d.left);
				if (lhs != null) {
					const vid = variableId(p, lhs);
					if (vid >= 0) {
						// Track single reassignment source (for it = it.next pattern)
						const rhs = getIdentSym(d.right);
						if (rhs != null && (p.vars[vid].reassignedTo == null || p.vars[vid].reassignedTo == rhs)) {
							p.vars[vid].reassignedTo = rhs;
							if (p.inConditional > 0 && p.inLoop > 0) {
								p.vars[vid].flags = p.vars[vid].flags | VF_IS_COND_REASSIGNED;
							}
						} else {
							markReassigned(p, vid);
						}
					}
				}
			}
		},

		NodeKind.Identifier => {
			p.abstractTime -= 1; // Symbols don't advance time
			// Auto-register referenced variables not yet seen (params, outer scope).
			// Treat as "external" — alive for the full function, never a cursor candidate.
			if (node.resolvedSym != null && !hasFlag(node.resolvedSym, SymbolFlag.Global)) {
				registerVariable(p, node.resolvedSym, true);
			}
			const id = variableId(p, node.resolvedSym);
			if (id >= 0) {
				if (p.abstractTime > p.vars[id].aliveEnd) p.vars[id].aliveEnd = p.abstractTime;
				if (p.abstractTime < p.vars[id].aliveStart) p.vars[id].aliveStart = p.abstractTime;
			}
		},

		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			liveRanges(p, d.callee);
			for (const arg of d.arguments) { liveRanges(p, arg); }
		},

		// Loops: traverse twice for soundness (mutation after borrow in same loop iteration)
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			liveRanges(p, d.whileCondition);
			liveRanges(p, d.whileBody);
			p.inLoop += 1;
			liveRanges(p, d.whileCondition);
			liveRanges(p, d.whileBody);
			p.inLoop -= 1;
			liveRanges(p, d.whileCondition); // condition alive longer than body
		},
		NodeKind.ForStmt => {
			const d = node.data as ForStmtData;
			liveRanges(p, d.forInit);
			liveRanges(p, d.forCondition);
			liveRanges(p, d.forUpdate);
			liveRanges(p, d.forBody);
			p.inLoop += 1;
			liveRanges(p, d.forInit);
			liveRanges(p, d.forCondition);
			liveRanges(p, d.forUpdate);
			liveRanges(p, d.forBody);
			p.inLoop -= 1;
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			liveRanges(p, d.doBody);
			liveRanges(p, d.doCondition);
			p.inLoop += 1;
			liveRanges(p, d.doBody);
			liveRanges(p, d.doCondition);
			p.inLoop -= 1;
		},

		// Conditionals
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			liveRanges(p, d.condition);
			p.inConditional += 1;
			liveRanges(p, d.consequent);
			liveRanges(p, d.alternate);
			p.inConditional -= 1;
		},
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			liveRanges(p, d.switchDisc);
			p.inConditional += 1;
			for (const c of d.switchCases) { liveRanges(p, c); }
			p.inConditional -= 1;
		},
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			liveRanges(p, d.ternaryCondition);
			p.inConditional += 1;
			liveRanges(p, d.ternaryConsequent);
			liveRanges(p, d.ternaryAlternate);
			p.inConditional -= 1;
		},

		// Inner functions: skip (different scope)
		NodeKind.FunctionDecl | NodeKind.ArrowFunction | NodeKind.FunctionExpr | NodeKind.MethodDecl | NodeKind.ConstructorDecl
			| NodeKind.ClassDecl | NodeKind.ActorDecl | NodeKind.TestDecl => {
			p.abstractTime -= 1;
		},

		// Compound traversal
		NodeKind.BlockStmt => {
			for (const s of (node.data as BlockStmtData).statements) { liveRanges(p, s); }
		},
		NodeKind.Program => {
			for (const s of (node.data as ProgramData).programStmts) { liveRanges(p, s); }
		},
		NodeKind.ExprStmt => liveRanges(p, (node.data as ExprStmtData).expr),
		NodeKind.ReturnStmt => liveRanges(p, (node.data as ReturnStmtData).argument),
		NodeKind.ThrowStmt => liveRanges(p, (node.data as ThrowStmtData).throwArg),
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			liveRanges(p, d.tryBody);
			if (d.catchBody != null) registerVariable(p, node.resolvedSym, false);
			liveRanges(p, d.catchBody);
			liveRanges(p, d.finallyBody);
		},
		NodeKind.SwitchCase => {
			const d = node.data as SwitchCaseData;
			for (const t of d.caseTests) { liveRanges(p, t); }
			for (const s of d.caseStmts) { liveRanges(p, s); }
		},
		NodeKind.MemberExpr => liveRanges(p, (node.data as MemberExprData).object),
		NodeKind.ArrayAccess => {
			const d = node.data as ArrayAccessData;
			liveRanges(p, d.array);
			liveRanges(p, d.index);
		},
		NodeKind.ObjectLiteral => {
			for (const prop of (node.data as ObjectLiteralData).properties) { liveRanges(p, prop); }
		},
		NodeKind.ArrayLiteral => {
			for (const elem of (node.data as ArrayLiteralData).elements) { liveRanges(p, elem); }
		},
		NodeKind.UnaryExpr => liveRanges(p, (node.data as { unaryOp: string, operand: Node }).operand),
		NodeKind.SpreadExpr => liveRanges(p, (node.data as SpreadExprData).spreadArg),
		NodeKind.MoveExpr => liveRanges(p, (node.data as MoveExprData).moveArg),
		NodeKind.NewExpr => {
			const d = node.data as NewExprData;
			liveRanges(p, d.newCallee);
			for (const a of d.newArguments) { liveRanges(p, a); }
		},
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => {
			liveRanges(p, (node.data as HiddenStdConvData).convExpr);
		},
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => {
			liveRanges(p, (node.data as { expr: Node }).expr);
		},
		NodeKind.TypeAssertion => {
			liveRanges(p, (node.data as TypeAssertionData).asExpr);
		},
		NodeKind.ExportDecl => {
			liveRanges(p, (node.data as ExportDeclData).exportedDecl);
		},
		// Default: descend via canonical walker so live ranges of variables
		// referenced inside unknown kinds (future expr/stmt forms) are still
		// tracked. Inner function bodies are explicitly handled above and
		// terminate recursion — forEachChild will still hand them to us, but
		// the match routes them to the skip branch on re-entry.
		_ => { forEachChild(node, (child: Node): void => { liveRanges(p, child); }); },
	};
}

// ===== Pass 2: traverse (build graphs) =====

function deps(w: WriteEffects, p: Partitions, dest: Symbol | null, src: Node): void {
	const destId = variableId(p, dest);
	if (destId < 0) return;
	if (src == null) return;

	// Classify: does dest own data or borrow?
	destMightOwn(p, destId, src);
	sourceSlots(w, p, src, borrowedSlots[destId]);

	// Source checks: prevent cursor when borrowing from unsafe sources
	const srcRoots: Symbol[] = [];
	allRoots(p, src, srcRoots);
	for (const srcSym of srcRoots) {
		if (srcSym == dest) continue; // self-assign ok (it = it.next)
		if (hasFlag(srcSym, SymbolFlag.Global)) {
			if (!isImmutableModuleConst(srcSym)) p.vars[destId].flags = p.vars[destId].flags | VF_PREVENT_CURSOR;
			continue;
		}
		const srcId = variableId(p, srcSym);
		if (srcId >= 0 && isViewVar(p, destId) && isViewVar(p, srcId)) {
			if ((p.vars[srcId].flags & VF_IS_PARAM) == 0) viewSources[destId].push(srcId);
			continue;
		}
		if (srcId >= 0) {
			// Source lives shorter than dest → can't borrow
			if ((p.vars[srcId].flags & VF_IS_PARAM) == 0 &&
				p.vars[srcId].aliveEnd < p.vars[destId].aliveEnd) {
				p.vars[destId].flags = p.vars[destId].flags | VF_PREVENT_CURSOR;
			}
			// Source is reassigned or prevented → can't borrow
			if ((p.vars[srcId].flags & (VF_IS_REASSIGNED | VF_PREVENT_CURSOR)) != 0) {
				p.vars[destId].flags = p.vars[destId].flags | VF_PREVENT_CURSOR;
			}
			// Source reassigned to different target → can't borrow
			if (p.vars[srcId].reassignedTo != null && p.vars[srcId].reassignedTo != dest) {
				p.vars[destId].flags = p.vars[destId].flags | VF_PREVENT_CURSOR;
			}
		}
	}
}

function trav(w: WriteEffects, p: Partitions, node: Node | null): void {
	if (node == null) return;
	p.abstractTime += 1;

	match (node.kind) {
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			// Initializer is an assignment source (for pretendOwnsData on [x], {x})
			p.inAsgnSource += 1;
			trav(w, p, d.initializer);
			p.inAsgnSource -= 1;
			if (node.resolvedSym != null && d.initializer != null) {
				connectStore(p, [node.resolvedSym], node.resolvedSym.symbolType, d.initializer);
			}
			deps(w, p, node.resolvedSym, d.initializer);
		},

		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			trav(w, p, d.left);
			if (d.operator == "=") {
				p.inAsgnSource += 1;
				trav(w, p, d.right);
				p.inAsgnSource -= 1;

				const lhsRoots: Symbol[] = [];
				allRoots(p, d.left, lhsRoots);
				if (d.left.kind != NodeKind.Identifier) {
					for (const r of lhsRoots) { potentialMutation(p, r); }
				}
				connectStore(p, lhsRoots, d.left.nodeType, d.right);
				recordWrite(p, node);

				// Cursor deps for assignment
				const lhs = getIdentSym(d.left);
				if (lhs != null) deps(w, p, lhs, d.right);
			} else {
				trav(w, p, d.right);
				recordWrite(p, node);
			}
		},

		NodeKind.Identifier => {
			p.abstractTime -= 1;
		},

		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			trav(w, p, d.callee);
			for (const arg of d.arguments) { trav(w, p, arg); }

			// Method call (obj.method(...)) → obj is potentially mutated
			if (d.callee != null && d.callee.kind == NodeKind.MemberExpr) {
				const objRoots: Symbol[] = [];
				allRoots(p, (d.callee.data as MemberExprData).object, objRoots);
				for (const r of objRoots) { potentialMutation(p, r); }
			}

			// HiddenAddr arguments → callee receives mutable pointer (var param)
			for (const arg of d.arguments) {
				if (arg != null && arg.kind == NodeKind.HiddenAddr) {
					const addrRoots: Symbol[] = [];
					allRoots(p, (arg.data as { expr: Node }).expr, addrRoots);
					for (const r of addrRoots) {
						potentialMutation(p, r);
						// Also prevent cursor on the variable itself
						const vid = variableId(p, r);
						if (vid >= 0) {
							p.vars[vid].flags = p.vars[vid].flags | VF_PREVENT_CURSOR;
						}
					}
				}
			}
			const formals = callFormals(node);
			const receiverFormals = node.flags.has(NodeFlag.ExtCall) ? 1 : 0;
			for (let ai = 0; ai < d.arguments.length; ai += 1) {
				const fi = ai + receiverFormals;
				if (!readOnlyFormal(formals, fi) && !sinkFormal(formals, fi) && !isViewArg(d.arguments[ai])) potentialMutationViaArg(p, d.arguments[ai]);
			}
			recordWrite(p, node);
		},

		// Loops: double traverse for soundness
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			trav(w, p, d.whileCondition);
			trav(w, p, d.whileBody);
			trav(w, p, d.whileCondition);
			trav(w, p, d.whileBody);
			trav(w, p, d.whileCondition);
		},
		NodeKind.ForStmt => {
			const d = node.data as ForStmtData;
			trav(w, p, d.forInit);
			trav(w, p, d.forCondition);
			trav(w, p, d.forUpdate);
			trav(w, p, d.forBody);
			trav(w, p, d.forInit);
			trav(w, p, d.forCondition);
			trav(w, p, d.forUpdate);
			trav(w, p, d.forBody);
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			trav(w, p, d.doBody);
			trav(w, p, d.doCondition);
			trav(w, p, d.doBody);
			trav(w, p, d.doCondition);
		},

		// Object/array in assignment source → elements pretend to own data
		NodeKind.ArrayLiteral => {
			const d = node.data as ArrayLiteralData;
			for (const elem of d.elements) { trav(w, p, elem); }
			if (p.inAsgnSource > 0) {
				for (const elem of d.elements) {
					const eid = variableId(p, getIdentSym(elem));
					if (eid >= 0) p.vars[eid].flags = p.vars[eid].flags | VF_OWNS_DATA;
				}
			}
		},
		NodeKind.ObjectLiteral => {
			const d = node.data as ObjectLiteralData;
			for (const prop of d.properties) { trav(w, p, prop); }
			if (p.inAsgnSource > 0) {
				for (const prop of d.properties) {
					const pid = variableId(p, getIdentSym(prop));
					if (pid >= 0) p.vars[pid].flags = p.vars[pid].flags | VF_OWNS_DATA;
				}
			}
		},

		// Move prevents cursoring of source
		NodeKind.MoveExpr => {
			trav(w, p, (node.data as MoveExprData).moveArg);
			const mid = variableId(p, getIdentSym((node.data as MoveExprData).moveArg));
			if (mid >= 0) p.vars[mid].flags = p.vars[mid].flags | VF_PREVENT_CURSOR;
		},

		// Inner functions: skip
		NodeKind.FunctionDecl | NodeKind.ArrowFunction | NodeKind.FunctionExpr | NodeKind.MethodDecl | NodeKind.ConstructorDecl
			| NodeKind.ClassDecl | NodeKind.ActorDecl | NodeKind.TestDecl => {
			p.abstractTime -= 1;
		},

		// Compound traversal (must match liveRanges order exactly)
		NodeKind.BlockStmt => {
			for (const s of (node.data as BlockStmtData).statements) { trav(w, p, s); }
		},
		NodeKind.Program => {
			for (const s of (node.data as ProgramData).programStmts) { trav(w, p, s); }
		},
		NodeKind.ExprStmt => trav(w, p, (node.data as ExprStmtData).expr),
		NodeKind.ReturnStmt => trav(w, p, (node.data as ReturnStmtData).argument),
		NodeKind.ThrowStmt => trav(w, p, (node.data as ThrowStmtData).throwArg),
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			trav(w, p, d.tryBody);
			trav(w, p, d.catchBody);
			trav(w, p, d.finallyBody);
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			trav(w, p, d.condition);
			trav(w, p, d.consequent);
			trav(w, p, d.alternate);
		},
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			trav(w, p, d.switchDisc);
			for (const c of d.switchCases) { trav(w, p, c); }
		},
		NodeKind.SwitchCase => {
			const d = node.data as SwitchCaseData;
			for (const t of d.caseTests) { trav(w, p, t); }
			for (const s of d.caseStmts) { trav(w, p, s); }
		},
		NodeKind.MemberExpr => trav(w, p, (node.data as MemberExprData).object),
		NodeKind.ArrayAccess => {
			const d = node.data as ArrayAccessData;
			trav(w, p, d.array);
			trav(w, p, d.index);
		},
		NodeKind.UnaryExpr => trav(w, p, (node.data as { unaryOp: string, operand: Node }).operand),
		NodeKind.SpreadExpr => trav(w, p, (node.data as SpreadExprData).spreadArg),
		NodeKind.NewExpr => {
			const d = node.data as NewExprData;
			trav(w, p, d.newCallee);
			for (const a of d.newArguments) { trav(w, p, a); }
			for (const a of d.newArguments) { potentialMutationViaArg(p, a); }
			recordWrite(p, node);
		},
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => {
			trav(w, p, (node.data as HiddenStdConvData).convExpr);
		},
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => {
			trav(w, p, (node.data as { expr: Node }).expr);
		},
		NodeKind.TypeAssertion => {
			trav(w, p, (node.data as TypeAssertionData).asExpr);
		},
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			trav(w, p, d.ternaryCondition);
			trav(w, p, d.ternaryConsequent);
			trav(w, p, d.ternaryAlternate);
		},
		NodeKind.ExportDecl => {
			trav(w, p, (node.data as ExportDeclData).exportedDecl);
		},
		// Default: descend via canonical walker so graph edges are built for
		// variables referenced inside unknown kinds. Keeps cursor inference
		// conservative: any use we miss defaults to "not a cursor" (owned),
		// which is always safe. Inner functions re-enter the match above and
		// hit the explicit skip branch.
		_ => { forEachChild(node, (child: Node): void => { trav(w, p, child); }); },
	};
}

// ===== Cursor Decision =====

function computeCursorDecisions(w: WriteEffects, p: Partitions, defs: LocalDefs): Symbol[] {
	const result: Symbol[] = [];
	let i = 0;
	while (i < p.vars.length) {
		const v = p.vars[i];
		// Skip params (handled separately in inject.ms)
		if ((v.flags & VF_IS_PARAM) != 0) { i += 1; continue; }
		// Must not own data, be prevented, or be conditionally reassigned
		const condReassigned = isViewVar(p, i) ? 0 : VF_IS_COND_REASSIGNED;
		if ((v.flags & (VF_OWNS_DATA | VF_PREVENT_CURSOR | condReassigned)) != 0) {
			i += 1; continue;
		}

		// Check graph for dangerous mutation during cursor's lifetime
		const r = ufRoot(p, i);
		if (p.vars[r].con.kind == CK_ROOT_OF) {
			const g = p.graphs[p.vars[r].con.target];
			if (dangerousMutation(g, v)) { i += 1; continue; }
		}
		const slots = holdsAddress(v.sym) ? addressSlots(borrowedSlots[i]) : borrowedSlots[i];
		if (writtenWhileAlive(w, p, i, slots, defs)) { i += 1; continue; }

		result.push(v.sym);
		i += 1;
	}
	return dropViewsOfOwners(p, result);
}

function dropViewsOfOwners(p: Partitions, chosen: Symbol[]): Symbol[] {
	let kept = chosen;
	let changed = true;
	while (changed) {
		changed = false;
		const next: Symbol[] = [];
		for (const sym of kept) {
			const id = variableId(p, sym);
			let borrowsOwner = false;
			for (const src of viewSources[id]) {
				if (kept.indexOf(p.vars[src].sym) < 0) borrowsOwner = true;
			}
			if (borrowsOwner) changed = true;
			else next.push(sym);
		}
		kept = next;
	}
	return kept;
}

// ===== Public API =====

// Main entry point — called once per function body, before DRC injection.
export function inferCursors(w: WriteEffects, body: Node): void {
	if (body == null) return;
	if (body.kind != NodeKind.BlockStmt && body.kind != NodeKind.Program) return;

	analysis = w;
	const p = createPartitions();

	// Pass 1: compute live ranges and register variables
	liveRanges(p, body);

	// Reset time for pass 2 (consistent abstractTime required)
	p.abstractTime = 0;
	borrowedSlots = [];
	viewSources = [];
	for (let i = 0; i < p.vars.length; i += 1) {
		borrowedSlots.push([]);
		viewSources.push([]);
	}
	writeSites = [];
	writeTimes = [];

	// Pass 2: build union-find graphs and track mutations
	trav(w, p, body);

	// Decision: which variables can safely be cursors?
	const chosen = computeCursorDecisions(w, p, callerDefsOf(w, body));
	analysis = null;
	for (const sym of chosen) { setFlag(sym, SymbolFlag.Cursor); }
}

// ===== Tests =====

function inferredIn(input: string, pick: (stmts: Node[]) => Node): Node {
	const result = parseSource(input);
	if (!result.ok) return null as unknown as Node;
	const prog = result.value;
	const checker = checkProgram(prog);
	const ctx = makeCtx();
	const writes: WriteEffects = { tables: createWriteSummaries(createRoutineDecls(), []), checker, unit: "", rcOf: (t: Type | null): RcInfo => classifyType(t, ctx, false), aliasMemo: new HashMap<Type, HashMap<Type, int32>>() };
	const body = pick((prog.data as ProgramData).programStmts);
	inferCursors(writes, body);
	return body;
}

function inferredBody(input: string): Node {
	return inferredIn(input, (stmts: Node[]): Node => {
		if (stmts.length == 0 || stmts[0].kind != NodeKind.FunctionDecl) return null as unknown as Node;
		return (stmts[0].data as FunctionDeclData).fnBody;
	});
}

function inferredNamed(input: string, name: string): Node {
	return inferredIn(input, (stmts: Node[]): Node => {
		for (const stmt of stmts) {
			let decl = stmt;
			if (decl.kind == NodeKind.ExportDecl) decl = (decl.data as ExportDeclData).exportedDecl;
			if (decl.kind == NodeKind.FunctionDecl && (decl.data as FunctionDeclData).fnName == name) return (decl.data as FunctionDeclData).fnBody;
		}
		return null as unknown as Node;
	});
}

const BOXES = "class Box { v: string; constructor(v: string) { this.v = v; } }\n"
	+ "class Holder { child: Box; constructor(s: string) { this.child = new Box(s); } }\n"
	+ "class Top { mid: Holder; mids: Holder[]; constructor() { this.mid = new Holder(\"i\"); this.mids = []; } }\n"
	+ "function replaceChild(h: Holder): void { h.child = new Box(\"n\"); }\n"
	+ "function replaceFirst(arr: Box[]): void { arr[0] = new Box(\"n\"); }\n"
	+ "function show(s: string): void { console.log(s); }\n";

function isCursorNamed(node: Node | null, name: string): boolean {
	if (node == null) return false;
	if (node.kind == NodeKind.VariableDecl && (node.data as VariableDeclData).declName == name) {
		return isCursorSym(node.resolvedSym);
	}
	let found = false;
	forEachChild(node, (child: Node): void => { if (!found && isCursorNamed(child, name)) found = true; });
	return found;
}

// --- Retained tests (adapted for union-find) ---

test "local read-only borrow is cursor" {
	const body = inferredBody("function f(arr: string[]) { const x = arr.length; }");
	assert isCursorNamed(body, "x");
}

test "returned variable is cursor (return copies, safe)" {
	// With union-find: x borrows from arr, no ownership, no mutation.
	// DRC handles return via copy (isLastReadSafe returns false for cursors).
	const body = inferredBody("function f(arr: string[]) { const x = arr[0]; return x; }");
	assert isCursorNamed(body, "x");
}

test "call argument is cursor (call copies, safe)" {
	// x borrows from arr[0]. Passing to call: inject.ms copies (incref).
	// No mutation on arr's graph → cursor is safe.
	const body = inferredBody("function f(arr: string[]) { const x = arr[0]; take(x); }\nfunction take(s: string): void {}");
	assert isCursorNamed(body, "x");
}

test "assigned to another var: source is cursor, dest connects" {
	// x borrows from arr[0]. y = x → y connects to x's graph.
	// Both can be cursors if neither owns data.
	const body = inferredBody("function f(arr: string[]) { const x = arr[0]; const y = x; }");
	assert isCursorNamed(body, "x");
	assert isCursorNamed(body, "y");
}

test "let variable without reassignment is cursor" {
	// let is fine if never reassigned — union-find tracks reassignment, not declKind.
	const body = inferredBody("function f(arr: string[]) { let x = arr[0]; }");
	assert isCursorNamed(body, "x");
}

test "index-write through alias is not cursor even when alias is never read" {
	const body = inferredBody("function f() { const vn: Vec<number> = [1, 2]; const cn = vn; cn[0] = 7; console.log(vn[0]); }");
	assert !isCursorNamed(body, "cn");
}

test "call result is NOT cursor (owns data)" {
	const body = inferredBody("function f() { const x = getValue(); }");
	assert !isCursorNamed(body, "x");
}

test "member access with only read use is cursor" {
	const body = inferredBody("function f(obj: { name: string }) { const name = obj.name; if (name) {} }");
	assert isCursorNamed(body, "name");
}

test "thrown variable is cursor (throw copies, safe)" {
	const body = inferredBody("function f(arr: string[]) { const x = arr[0]; throw x; }");
	assert isCursorNamed(body, "x");
}

test "stored in object is NOT cursor (constructor context)" {
	const body = inferredBody("function f(arr: string[]) { const x = arr[0]; const obj = { val: x }; }");
	// x appears in ObjectLiteral — pretendOwnsData in inAsgnSource context
	// obj owns data (ObjectLiteral constructor), x gets ownsData via constructor context
	assert !isCursorNamed(body, "x");
}

test "DRC temp is inferred like any local" {
	const body = inferredBody("function f(arr: string[]) { const $tmp = arr[0]; }");
	assert isCursorNamed(body, "$tmp");
}

test "nested block cursor" {
	const body = inferredBody("function f(obj: { name: string }) { if (true) { const x = obj.name; } }");
	assert isCursorNamed(body, "x");
}

// --- New tests for union-find-specific features ---

test "source mutated during cursor lifetime: NOT cursor" {
	// x borrows from arr[0]. arr.push() mutates arr while x is alive → dangerousMutation.
	const body = inferredBody("function f(arr: string[]) { const x = arr[0]; arr.push(\"new\"); process(x); }");
	assert !isCursorNamed(body, "x");
}

test "source mutated BEFORE cursor: IS cursor" {
	// arr.push() happens before x borrows → mutation not in cursor lifetime.
	const body = inferredBody("function f(arr: string[]) { arr.push(\"new\"); const x = arr[0]; take(x); }\nfunction take(s: string): void {}");
	assert isCursorNamed(body, "x");
}

test "a variable reassigned unconditionally from a parameter is cursor" {
	const body = inferredBody("function f(arr: string[]) { let x = arr[0]; x = arr[1]; }");
	assert isCursorNamed(body, "x");
}

test "a variable that outlives the catch binding it reads is NOT cursor" {
	const body = inferredBody("function f(): string { let m = \"\"; try { throw new Error(\"x\"); } catch (e) { m = e.message; } return m; }");
	assert !isCursorNamed(body, "m");
}

test "new expression result is NOT cursor" {
	const body = inferredBody("function f() { const x = new Foo(); }");
	assert !isCursorNamed(body, "x");
}

test "object literal result is NOT cursor" {
	const body = inferredBody("function f() { const x = { a: 1, b: 2 }; }");
	assert !isCursorNamed(body, "x");
}

test "array literal result is NOT cursor" {
	const body = inferredBody("function f() { const x = [1, 2, 3]; }");
	assert !isCursorNamed(body, "x");
}

test "move expression prevents cursor" {
	const body = inferredBody("function f(arr: string[]) { const x = arr[0]; const y = move x; }");
	assert !isCursorNamed(body, "x");
}

test "connected variables share mutation graph" {
	// a borrows from arr. b borrows from a (connected).
	// arr.push mutates arr's graph → both a and b see it while they're alive.
	const body = inferredBody("function f(arr: string[]) { const a = arr[0]; const b = a; arr.push(\"x\"); process(a); process(b); }");
	assert !isCursorNamed(body, "a");
	assert !isCursorNamed(body, "b");
}

test "same-named declarations in sibling scopes are separate variables" {
	const body = inferredBody("function f(arr: string[]) { if (true) { const x = arr[0]; take(x); } else { const x = getValue(); } }\nfunction take(s: string): void {}\nfunction getValue(): string { return \"v\"; }");
	assert isCursorNamed(body, "x");
}

test "borrow from a module global is NOT cursor" {
	const body = inferredNamed(BOXES + "let g = new Holder(\"a\");\nfunction f(): void { const c = g.child; show(c.v); }", "f");
	assert !isCursorNamed(body, "c");
}

test "borrow from an exported module global is NOT cursor" {
	const body = inferredNamed(BOXES + "export let g = new Holder(\"a\");\nfunction f(): void { const c = g.child; show(c.v); }", "f");
	assert !isCursorNamed(body, "c");
}

test "passing the borrowed-from object to a function mutates its graph" {
	const body = inferredNamed(BOXES + "function f(h: Holder): void { const c = h.child; replaceChild(h); show(c.v); }", "f");
	assert !isCursorNamed(body, "c");
}

test "passing the array an element was borrowed from mutates its graph" {
	const body = inferredNamed(BOXES + "function f(boxes: Box[]): void { const b = boxes[0]; replaceFirst(boxes); show(b.v); }", "f");
	assert !isCursorNamed(body, "b");
}

test "passing a value without references keeps the borrow a cursor" {
	const body = inferredNamed(BOXES + "function f(h: Holder): void { const c = h.child; show(\"x\"); show(c.v); }", "f");
	assert isCursorNamed(body, "c");
}

test "pushing the borrow into another array keeps it a cursor" {
	const body = inferredNamed(BOXES + "function f(src: Box[], dst: Box[]): void { const b = src[0]; dst.push(b); show(b.v); }", "f");
	assert isCursorNamed(body, "b");
}

test "passing the borrow to a sink parameter keeps it a cursor" {
	const body = inferredNamed(BOXES + "function keep(sink b: Box): void { show(b.v); }\nfunction f(h: Holder): void { const c = h.child; keep(c); show(c.v); }", "f");
	assert isCursorNamed(body, "c");
}

test "passing the borrow through an overload whose implementation takes Readonly keeps it a cursor" {
	const body = inferredNamed(BOXES + "function look(b: Box): void;\nfunction look(b: Readonly<Box>): void;\nfunction look(b: Readonly<Box>): void { show(b.v); }\nfunction f(h: Holder): void { const c = h.child; look(c); show(c.v); }", "f");
	assert isCursorNamed(body, "c");
}

test "passing the owner through an overload whose implementation mutates it ends the cursor" {
	const body = inferredNamed(BOXES + "function grab(h: Holder): void;\nfunction grab(h: Holder): void { replaceChild(h); }\nfunction f(h: Holder): void { const c = h.child; grab(h); show(c.v); }", "f");
	assert !isCursorNamed(body, "c");
}

test "pushing the borrow into the array it came from ends the cursor" {
	const body = inferredNamed(BOXES + "function f(src: Box[]): void { const b = src[0]; src.push(b); show(b.v); }", "f");
	assert !isCursorNamed(body, "b");
}

test "a callee that writes the borrowed field through another path ends the cursor" {
	const body = inferredNamed(BOXES + "function f(h: Holder, g: Holder): void { const c = h.child; replaceChild(g); show(c.v); }", "f");
	assert !isCursorNamed(body, "c");
}

test "a store to the borrowed field through another path ends the cursor" {
	const body = inferredNamed(BOXES + "function f(h: Holder, g: Holder): void { const c = h.child; g.child = new Box(\"n\"); show(c.v); }", "f");
	assert !isCursorNamed(body, "c");
}

test "a store to another field keeps the cursor" {
	const body = inferredNamed(BOXES + "function f(h: Holder, t: Top): void { const c = h.child; t.mid = new Holder(\"m\"); show(c.v); }", "f");
	assert isCursorNamed(body, "c");
}

test "a callee that writes only an object it allocated keeps the cursor" {
	const body = inferredNamed(BOXES + "function fill(): Holder { const m = new Holder(\"o\"); m.child = new Box(\"n\"); return m; }\n"
		+ "function f(h: Holder): void { const c = h.child; fill(); show(c.v); }", "f");
	assert isCursorNamed(body, "c");
}

test "a callee that writes an object a fresh routine returned keeps the cursor" {
	const body = inferredNamed(BOXES + "function mk(): Holder { return new Holder(\"o\"); }\n"
		+ "function fill(): void { const m = mk(); m.child = new Box(\"n\"); }\n"
		+ "function f(h: Holder): void { const c = h.child; fill(); show(c.v); }", "f");
	assert isCursorNamed(body, "c");
}

test "a callee that writes an object a routine returned from module state ends the cursor" {
	const body = inferredNamed(BOXES + "let held = new Holder(\"g\");\n"
		+ "function shared(): Holder { return held; }\n"
		+ "function fill(): void { const m = shared(); m.child = new Box(\"n\"); }\n"
		+ "function f(h: Holder): void { const c = h.child; fill(); show(c.v); }", "f");
	assert !isCursorNamed(body, "c");
}

test "a callee that writes through a field of an object it allocated ends the cursor" {
	const body = inferredNamed(BOXES + "function fill(h: Holder): void { const m = new Top(); m.mid = h; m.mid.child = new Box(\"n\"); }\n"
		+ "function f(h: Holder): void { const c = h.child; fill(h); show(c.v); }", "f");
	assert !isCursorNamed(body, "c");
}

test "a field store joins the stored object to the target's graph" {
	const body = inferredNamed(BOXES + "function f(t: Top): void { const m = new Holder(\"o\"); t.mid = m; const z = m.child; t.mid.child = new Box(\"n\"); show(z.v); show(m.child.v); }", "f");
	assert !isCursorNamed(body, "z");
}

test "an element store joins the stored object to the array's graph" {
	const body = inferredNamed(BOXES + "function f(arr: Holder[]): void { const m = new Holder(\"o\"); arr[0] = m; const z = m.child; arr[0].child = new Box(\"n\"); show(z.v); show(m.child.v); }", "f");
	assert !isCursorNamed(body, "z");
}

test "a declaration holding a local joins the local to its graph" {
	const body = inferredNamed(BOXES + "class Wrap { h: Holder; constructor(h: Holder) { this.h = h; } }\nfunction f(): void { const m = new Holder(\"o\"); const w = new Wrap(m); const z = m.child; w.h.child = new Box(\"n\"); show(z.v); show(m.child.v); }", "f");
	assert !isCursorNamed(body, "z");
}

test "storing an array literal joins its elements to the target's graph" {
	const body = inferredNamed(BOXES + "function f(t: Top): void { const m = new Holder(\"o\"); t.mids = [m]; const z = m.child; t.mids[0].child = new Box(\"n\"); show(z.v); show(m.child.v); }", "f");
	assert !isCursorNamed(body, "z");
}

const APPLY = "function noop(h: Holder): void { show(\"x\"); }\n"
	+ "function apply(h: Holder, fn: (h: Holder) => void): void { fn(h); }\n"
	+ "function forward(h: Holder, fn: (h: Holder) => void): void { apply(h, fn); }\n"
	+ "function rebind(h: Holder, fn: (h: Holder) => void): void { fn = replaceChild; fn(h); }\n";

test "a routine calling its function parameter writes what the passed routine writes" {
	const body = inferredNamed(BOXES + APPLY + "function f(h: Holder, g: Holder): void { const c = h.child; apply(g, replaceChild); show(c.v); }", "f");
	assert !isCursorNamed(body, "c");
}

test "a routine calling its function parameter with a pure routine keeps the cursor" {
	const body = inferredNamed(BOXES + APPLY + "function f(h: Holder, g: Holder): void { const c = h.child; apply(g, noop); show(c.v); }", "f");
	assert isCursorNamed(body, "c");
}

test "a function parameter forwarded one call deeper still carries the passed routine's writes" {
	const pure = inferredNamed(BOXES + APPLY + "function f(h: Holder, g: Holder): void { const c = h.child; forward(g, noop); show(c.v); }", "f");
	assert isCursorNamed(pure, "c");
	const writes = inferredNamed(BOXES + APPLY + "function f(h: Holder, g: Holder): void { const c = h.child; forward(g, replaceChild); show(c.v); }", "f");
	assert !isCursorNamed(writes, "c");
}

test "a function parameter reassigned before the call ends the cursor whatever the caller passes" {
	const body = inferredNamed(BOXES + APPLY + "function f(h: Holder, g: Holder): void { const c = h.child; rebind(g, noop); show(c.v); }", "f");
	assert !isCursorNamed(body, "c");
}

test "loop binding over an array written in the loop is NOT cursor" {
	const body = inferredNamed(BOXES + "function f(boxes: Box[]): void { let i = 0; while (i < 2) { const b = boxes[i]; i = i + 1; boxes[0] = new Box(\"n\"); show(b.v); } }", "f");
	assert !isCursorNamed(body, "b");
}

test "loop binding over an array nobody writes is cursor" {
	const body = inferredNamed(BOXES + "function f(boxes: Box[]): void { let i = 0; while (i < 2) { const b = boxes[i]; i = i + 1; show(b.v); } }", "f");
	assert isCursorNamed(body, "b");
}

const LINKS = "class Link { v: int32 = 0; next: Link | null = null; }\n"
	+ "function use(n: int32): void { console.log(n); }\n";

test "a walker reassigned from its own field is cursor" {
	const body = inferredNamed(LINKS + "function f(n: Link): void { let it: Link | null = n; while (it != null) { use(it.v); it = it.next; } }", "f");
	assert isCursorNamed(body, "it");
}

test "a read-only view repointed under a loop condition is cursor" {
	const body = inferredNamed(LINKS + "function f(n: Readonly<Link>): int32 { let cur: Readonly<Link> = n; while (cur.next != null) { const nx = cur.next; if (nx == null) break; cur = nx; } return cur.v; }", "f");
	assert isCursorNamed(body, "cur");
	assert isCursorNamed(body, "nx");
}

test "a read-only view repointed at a local that owns its value is NOT cursor" {
	const body = inferredNamed(LINKS + "function f(k: int32): int32 { let keep: Readonly<Link> | null = null; for (let i = 0; i < k; i += 1) { const o: Readonly<Link> = new Link(); if (i == 1) keep = o; } return keep != null ? keep.v : -1; }", "f");
	assert !isCursorNamed(body, "o");
	assert !isCursorNamed(body, "keep");
}

test "a store to the same field of a local in another partition keeps a view cursor" {
	const body = inferredNamed(LINKS + "function f(n: Link): int32 { const v = n.next; const own = new Link(); own.next = new Link(); return v != null ? v.v : 0; }", "f");
	assert isCursorNamed(body, "v");
}

test "a store into a generic holder of another partition keeps a view cursor" {
	const body = inferredNamed(LINKS + "class Cell<T> { v: int32 = 0; next: T | null = null; }\nfunction f(n: Cell<Link>): int32 { const v = n.next; const own = new Cell<Link>(); own.next = new Link(); return v != null ? v.v : 0; }", "f");
	assert isCursorNamed(body, "v");
}

test "a store through a local aliasing the view's source ends the view" {
	const body = inferredNamed(LINKS + "function f(n: Link): int32 { const v = n.next; const alias = n; alias.next = new Link(); return v != null ? v.v : 0; }", "f");
	assert !isCursorNamed(body, "v");
}

test "a store that links a local to the view's source joins their partitions and ends the view" {
	const body = inferredNamed(LINKS + "function f(n: Link): int32 { const v = n.next; const own = new Link(); own.next = n.next; own.next = new Link(); return v != null ? v.v : 0; }", "f");
	assert !isCursorNamed(body, "v");
}

test "a store through a local read from module state ends the view" {
	const body = inferredNamed(LINKS + "let head = new Link();\nfunction f(n: Link): int32 { const v = n.next; const x = head; x.next = new Link(); return v != null ? v.v : 0; }", "f");
	assert !isCursorNamed(body, "v");
}

test "a store through a parameter of the same class ends the view" {
	const body = inferredNamed(LINKS + "function f(n: Link, m: Link): int32 { const v = n.next; m.next = new Link(); return v != null ? v.v : 0; }", "f");
	assert !isCursorNamed(body, "v");
}

const FN_VALUES = LINKS + "function nextOf(x: Readonly<Link>): Readonly<Link> | null { return x.next; }\n"
	+ "function clearNext(x: Readonly<Link>): Readonly<Link> | null { head.next = null; return x.next; }\n"
	+ "let head = new Link();\n";

test "a view through a function value bound to a reading routine keeps the cursor" {
	const body = inferredNamed(FN_VALUES + "function f(n: Link): int32 { const pick = nextOf; const a = pick(n); const b = pick(n); return a != null && b != null ? a.v + b.v : 0; }", "f");
	assert isCursorNamed(body, "a");
	assert isCursorNamed(body, "b");
}

test "a view through a function value bound to a writing routine ends the cursor" {
	const body = inferredNamed(FN_VALUES + "function f(n: Link): int32 { const pick = clearNext; const a = pick(n); const b = pick(n); return a != null && b != null ? a.v + b.v : 0; }", "f");
	assert !isCursorNamed(body, "a");
}

test "a view through a function parameter ends the cursor, as its routine is unknown" {
	const body = inferredNamed(FN_VALUES + "function f(n: Link, pick: (x: Readonly<Link>) => Readonly<Link> | null): int32 { const a = pick(n); const b = pick(n); return a != null && b != null ? a.v + b.v : 0; }", "f");
	assert !isCursorNamed(body, "a");
}

test "a view through a function value reassigned between calls ends the cursor" {
	const body = inferredNamed(FN_VALUES + "function f(n: Link): int32 { let pick = nextOf; const a = pick(n); pick = clearNext; const b = pick(n); return a != null && b != null ? a.v + b.v : 0; }", "f");
	assert !isCursorNamed(body, "a");
}

const SETTERS = "class LinkM { v: int32 = 0; next: LinkM | null = null; setNext(x: LinkM): void { this.next = x; } }\n"
	+ "let shared = new LinkM();\n"
	+ "class Spill { v: int32 = 0; next: LinkM | null = null; setNext(x: LinkM): void { shared.next = x; } }\n";

test "a call on a local of another partition keeps a view cursor" {
	const body = inferredNamed(SETTERS + "function f(n: LinkM): int32 { const v = n.next; const own = new LinkM(); own.setNext(new LinkM()); return v != null ? v.v : 0; }", "f");
	assert isCursorNamed(body, "v");
}

test "a call with an argument rooted in the view's partition ends the view" {
	const body = inferredNamed(SETTERS + "function f(n: LinkM): int32 { const v = n.next; const own = new LinkM(); own.setNext(n); return v != null ? v.v : 0; }", "f");
	assert !isCursorNamed(body, "v");
}

test "a call on a parameter ends the view" {
	const body = inferredNamed(SETTERS + "function f(n: LinkM, m: LinkM): int32 { const v = n.next; m.setNext(new LinkM()); return v != null ? v.v : 0; }", "f");
	assert !isCursorNamed(body, "v");
}

test "a call on a local aliasing the view's source ends the view" {
	const body = inferredNamed(SETTERS + "function f(n: LinkM): int32 { const v = n.next; const alias = n; alias.setNext(new LinkM()); return v != null ? v.v : 0; }", "f");
	assert !isCursorNamed(body, "v");
}

test "a call whose routine writes module state ends the view whatever it is called on" {
	const body = inferredNamed(SETTERS + "function f(n: LinkM): int32 { const v = shared.next; const own = new Spill(); own.setNext(new LinkM()); return v != null ? v.v : 0; }", "f");
	assert !isCursorNamed(body, "v");
}

test "a call through a local closure that writes the view's source through a capture ends the view" {
	const body = inferredNamed(SETTERS + "function f(n: LinkM): int32 { const v = n.next; const own = new LinkM(); const clear = (o: LinkM): void => { o.next = null; n.next = null; }; clear(own); return v != null ? v.v : 0; }", "f");
	assert !isCursorNamed(body, "v");
}

test "a call through a function parameter ends the view" {
	const body = inferredNamed(SETTERS + "function f(n: LinkM, clear: (o: LinkM) => void): int32 { const v = n.next; const own = new LinkM(); clear(own); return v != null ? v.v : 0; }", "f");
	assert !isCursorNamed(body, "v");
}

test "a call passing a closure that writes through a capture ends the view" {
	const body = inferredNamed(SETTERS + "function run(o: LinkM, cb: (o: LinkM) => void): void { cb(o); }\nfunction f(n: LinkM): int32 { const v = n.next; const own = new LinkM(); run(own, (o: LinkM): void => { n.next = null; }); return v != null ? v.v : 0; }", "f");
	assert !isCursorNamed(body, "v");
}

test "a call to a nested function that writes the view's source through a capture ends the view" {
	const body = inferredNamed(SETTERS + "function f(n: LinkM): int32 { const v = n.next; const own = new LinkM(); function clear(o: LinkM): void { o.next = null; n.next = null; } clear(own); return v != null ? v.v : 0; }", "f");
	assert !isCursorNamed(body, "v");
}
