// Generator Lowering — transforms function* into state machines
//
// Converts yield-based generator functions into regular functions returning
// iterator objects with a next() method containing a state dispatch loop.
//
// function* counter(max) {       function counter(max) {
//     let i = 0;                     let $state = 0;
//     while (i < max) {              let i;
//         yield i;           →       return { next: function() {
//         i = i + 1;                     while (true) {
//     }                                      if ($state === 0) { i = 0; $state = 1; }
// }                                          else if ($state === 1) { ... }
//                                            else { return { value: null, done: true }; }
//                                        }
//                                    }};
//                                }

import {
	Node, NodeKind, DeclKind, SourceLocation, createNode,
	ProgramData, BlockStmtData, FunctionDeclData, FunctionExprData,
	VariableDeclData, IfStmtData, WhileStmtData, DoWhileStmtData,
	SwitchStmtData, SwitchCaseData, BreakStmtData, ContinueStmtData,
	ExprStmtData, TryCatchStmtData, YieldExprData,
	ExportDeclData, ClassDeclData, MethodDeclData, DecoratedDeclData, Type, TypeKind,
	IdentifierData, Symbol, SymbolKind,
	isEmptyBlock,
} from "../../ast/node";
import { forEachChild } from "../../ast/visitor";
import { mapChildren } from "../walker";
import { makeSymbol, setFlag, SymbolFlag } from "../../checker/symbol";
import { isIterator, getIteratorYieldType, getIteratorNextFnType, hasGenericParams, createIteratorResult } from "../../checker/types";
import { TransformContext, NameSet, createNameSet, nameSetContains, reportTransformError } from "../context";
import {
	makeIdent, makeIdentResolved, makeTypedIdent, makeTypedIdentResolved, makeNull, makeNumber, makeBool,
	makeBlock, makeVarDecl, makeExprStmt, makeReturn,
	makeIf, makeWhile, makeBinary, makeAssign, makeContinue,
	makeObjectLiteral, syntheticToken, extractBodyStmts,
	collectDeclNames, makeTryCatch, makeCatchSym, makeMoveExpr,
	makeSwitch, makeSwitchCase, makeDefaultValue,
} from "../util";
import { numberType, createPtr, createPrimitive } from "../../checker/types";
import { cloneNodeKeepSem } from "../../monomorphize/clone";
import { renameRepeatedBindingsInFrame } from "./lambdaLiftingRename";
import { stmtCountAfter, firstStmtKindAfter, parseInput, makeCtx } from "../testUtil";

// ===== Data Structures =====

export interface GenState {
	index: number;
	isYield: boolean;
	nextState: number;
	stmts: Node[];
	yieldVarName: string;   // variable assigned from yield (for async resume)
	yieldVarType: Type | null;     // type of the variable (for unboxing msFutureRead)
	excLanding: number;     // reference exceptionTable[i]: state to jump to if this state raises (-1 = propagate)
}

// Active while-with-yield scope. break/continue inside the body must
// transition to these states; a bare C `break;`/`continue;` would exit the
// outer dispatcher while(1) and leave the future un-completed.
export interface LoopFrame {
	breakState: number;
	continueState: number;
	label: string;
	isLoop: boolean;
}

// Active finally scope (finallyPath port, reference closureiters): a
// yield-containing try with a yield-free finally inlines its finally body at
// every exit of the try. loopDepth = loopStack length when the try began; a
// break/continue only crosses the try — and so only runs the finally — when
// its target loop sits outside the try (frame.loopDepth > target loop index).
export interface FinallyFrame {
	stmts: Node[];
	loopDepth: number;
	hasYield: boolean;
}

export interface StateCollector {
	items: GenState[];
	loopStack: LoopFrame[];
	excType: Type | null;   // exception type carried by $curExc (from a catch's nodeType)
	finallyStack: FinallyFrame[];
	stateSym: Symbol;
	curExcSym: Symbol;
	genReturns?: boolean;
	genResultType?: Type;
}

interface SplitDiag {
	message: string;
	loc: SourceLocation;
}

let pendingSplitDiags: SplitDiag[] = [];

const YIELD_IN_EXPR = "a yield or await inside an expression is not supported on the C backend yet; bind it to a variable first (`const v = await p;`)";

function reportUnsplit(node: Node, message: string): void {
	pendingSplitDiags.push({ message, loc: node.location });
}


// ===== Helpers =====

function isFnBoundary(node: Node): boolean {
	return node.kind == NodeKind.FunctionDecl || node.kind == NodeKind.ArrowFunction
		|| node.kind == NodeKind.FunctionExpr || node.kind == NodeKind.MethodDecl
		|| node.kind == NodeKind.ConstructorDecl || node.kind == NodeKind.ClassDecl;
}

// Reference parity (captureVar): env fields always carry their original type.
function collectDeclTypes(node: Node, names: string[], types: Type[], syms: Symbol[]): void {
	if (node == null || isFnBoundary(node)) return;
	if (node.kind == NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		let t = node.nodeType;
		if (t == null && d.initializer != null) t = d.initializer.nodeType;
		if (t == null && node.resolvedSym != null) t = node.resolvedSym.symbolType;
		if (t != null) {
			names.push(d.declName);
			types.push(t);
			syms.push(node.resolvedSym!);
		}
	}
	forEachChild(node, (child: Node): void => { collectDeclTypes(child, names, types, syms); });
}

function cloneStmts(stmts: Node[]): Node[] {
	const out: Node[] = [];
	for (const s of stmts) out.push(cloneNodeKeepSem(s));
	return out;
}

function loopPrefix(frames: LoopFrame[], n: number): LoopFrame[] {
	const out: LoopFrame[] = [];
	for (let i = 0; i < n; i += 1) out.push(frames[i]);
	return out;
}

function finallyPrefix(frames: FinallyFrame[], n: number): FinallyFrame[] {
	const out: FinallyFrame[] = [];
	for (let i = 0; i < n; i += 1) out.push(frames[i]);
	return out;
}

function lookupDeclIdx(names: string[], name: string): int32 {
	let i = 0;
	while (i < names.length) {
		if (names[i] == name) return i as int32;
		i = i + 1;
	}
	return -1 as int32;
}

function buildIterResultType(returnNodeType: Type | null): Type | null {
	if (returnNodeType == null || !isIterator(returnNodeType)) return null;
	const yieldType = getIteratorYieldType(returnNodeType);
	if (yieldType == null) return null;
	return createIteratorResult(yieldType);
}

function makeIterResult(value: Node, done: boolean, loc: SourceLocation, resultType: Type | null): Node {
	const obj = makeObjectLiteral(
		["value", "done"],
		[value, makeBool(done, loc)],
		loc,
	);
	if (resultType != null) obj.nodeType = resultType;
	return obj;
}

function makeDoneResult(loc: SourceLocation, resultType: Type | null): Node {
	return makeIterResult(makeNull(loc), true, loc, resultType);
}

export function makeStateAssign(stateNum: number, loc: SourceLocation, stateSym: Symbol): Node {
	return makeExprStmt(
		makeAssign(makeTypedIdentResolved(stateSym, numberType(), loc), makeNumber(stateNum, loc), loc),
		loc,
	);
}

function findLabeledFrame(sc: StateCollector, label: string): number {
	for (let i = sc.loopStack.length - 1; i >= 0; i -= 1) {
		if (sc.loopStack[i].label == label) return i;
	}
	return -1;
}

function innermostLoopFrame(sc: StateCollector): number {
	for (let i = sc.loopStack.length - 1; i >= 0; i -= 1) {
		if (sc.loopStack[i].isLoop) return i;
	}
	return -1;
}

function jumpFrame(sc: StateCollector, node: Node, capBreak: boolean, capContinue: boolean): number {
	if (node.kind == NodeKind.BreakStmt) {
		const label = (node.data as BreakStmtData).breakLabel;
		if (label != "") return findLabeledFrame(sc, label);
		if (capBreak) return -1;
		return sc.loopStack.length - 1;
	}
	const label = (node.data as ContinueStmtData).continueLabel;
	if (label != "") return findLabeledFrame(sc, label);
	if (capContinue) return -1;
	return innermostLoopFrame(sc);
}

function isStateJump(stmt: Node, sc: StateCollector): boolean {
	if (stmt.kind == NodeKind.ReturnStmt) return sc.genReturns == true;
	if (stmt.kind == NodeKind.BreakStmt || stmt.kind == NodeKind.ContinueStmt) return jumpFrame(sc, stmt, false, false) >= 0;
	return false;
}

function jumpExit(stmt: Node, sc: StateCollector, frameIdx: number, loc: SourceLocation): Node[] {
	if (stmt.kind == NodeKind.ReturnStmt) {
		return [makeStateAssign(-1, loc, sc.stateSym), makeReturn(makeDoneResult(loc, sc.genResultType), loc)];
	}
	const frame = sc.loopStack[frameIdx];
	if (stmt.kind == NodeKind.BreakStmt) return [makeStateAssign(frame.breakState, loc, sc.stateSym)];
	if (!frame.isLoop) reportUnsplit(stmt, "internal: a continue targets a switch that was split into states");
	return [makeStateAssign(frame.continueState, loc, sc.stateSym)];
}

function crossesYieldFinally(sc: StateCollector, frameIdx: number): boolean {
	for (const f of sc.finallyStack) {
		if (f.loopDepth > frameIdx && f.hasYield) return true;
	}
	return false;
}

function inlineCrossedFinallies(sc: StateCollector, frameIdx: number, out: Node[], loc: SourceLocation): void {
	const loops = sc.loopStack;
	const fins = sc.finallyStack;
	for (let f = fins.length - 1; f >= 0; f -= 1) {
		if (fins[f].loopDepth > frameIdx) {
			sc.loopStack = loopPrefix(loops, fins[f].loopDepth);
			sc.finallyStack = finallyPrefix(fins, f);
			for (const s of fins[f].stmts) out.push(rewriteJumps(cloneNodeKeepSem(s), sc, false, false, loc));
		}
	}
	sc.loopStack = loops;
	sc.finallyStack = fins;
}

// The emitted `continue` must reach the state dispatcher: a jump nested in a C
// loop of its own is split instead (hasEscapingJump).
function rewriteJumps(node: Node, sc: StateCollector, capBreak: boolean, capContinue: boolean, loc: SourceLocation): Node {
	if (node == null || isFnBoundary(node)) return node;
	if (node.kind == NodeKind.ReturnStmt) {
		if (sc.genReturns != true) return node;
		const out: Node[] = [];
		inlineCrossedFinallies(sc, -1, out, loc);
		for (const s of jumpExit(node, sc, -1, loc)) out.push(s);
		return makeBlock(out, loc);
	}
	if (node.kind == NodeKind.BreakStmt || node.kind == NodeKind.ContinueStmt) {
		const idx = jumpFrame(sc, node, capBreak, capContinue);
		if (idx < 0) return node;
		const exits = jumpExit(node, sc, idx, loc);
		const out: Node[] = [];
		inlineCrossedFinallies(sc, idx, out, loc);
		for (const s of exits) out.push(s);
		out.push(makeContinue(loc));
		return makeBlock(out, loc);
	}
	let cb = capBreak;
	let cc = capContinue;
	if (node.kind == NodeKind.WhileStmt || node.kind == NodeKind.ForStmt || node.kind == NodeKind.ForOfStmt || node.kind == NodeKind.ForInStmt) {
		cb = true;
		cc = true;
	} else if (node.kind == NodeKind.DoWhileStmt) {
		cb = true;
		if (!(node.data as DoWhileStmtData).dwSwitchWrapper) cc = true;
	} else if (node.kind == NodeKind.SwitchStmt) {
		cb = true;
	}
	mapChildren(node, (child: Node): Node => rewriteJumps(child, sc, cb, cc, loc));
	return node;
}

function hasEscapingJump(node: Node, sc: StateCollector, capBreak: boolean, capContinue: boolean, inCLoop: boolean): boolean {
	if (node == null || isFnBoundary(node)) return false;
	if (node.kind == NodeKind.ReturnStmt) return sc.genReturns == true && crossesYieldFinally(sc, -1);
	if (node.kind == NodeKind.BreakStmt || node.kind == NodeKind.ContinueStmt) {
		const idx = jumpFrame(sc, node, capBreak, capContinue);
		return idx >= 0 && (inCLoop || crossesYieldFinally(sc, idx));
	}
	let cb = capBreak;
	let cc = capContinue;
	let inLoop = inCLoop;
	if (node.kind == NodeKind.WhileStmt || node.kind == NodeKind.ForStmt || node.kind == NodeKind.ForOfStmt || node.kind == NodeKind.ForInStmt) {
		cb = true;
		cc = true;
		inLoop = true;
	} else if (node.kind == NodeKind.DoWhileStmt) {
		cb = true;
		inLoop = true;
		if (!(node.data as DoWhileStmtData).dwSwitchWrapper) cc = true;
	} else if (node.kind == NodeKind.SwitchStmt) {
		cb = true;
	}
	let found = false;
	forEachChild(node, (child: Node): void => {
		if (!found && hasEscapingJump(child, sc, cb, cc, inLoop)) found = true;
	});
	return found;
}

function needsSplit(stmt: Node, sc: StateCollector): boolean {
	return containsYield(stmt) || hasEscapingJump(stmt, sc, false, false, false);
}

export function allocState(sc: StateCollector): number {
	const idx = sc.items.length;
	const st: GenState = { index: idx, isYield: false, nextState: -1, stmts: [], yieldVarName: "", yieldVarType: null, excLanding: -1 };
	sc.items.push(st);
	return idx;
}

function isGeneratorFlag(flags: string): boolean {
	if (flags == "generator" || flags == "async_generator") return true;
	return flags.indexOf("generator") >= 0;
}

// ===== Yield Detection =====

export function containsYield(node: Node | null): boolean {
	if (node == null) return false;
	if (node.kind == NodeKind.YieldExpr) return true;
	if (isFnBoundary(node)) return false;
	let found = false;
	forEachChild(node, (child: Node): void => {
		if (!found && containsYield(child)) found = true;
	});
	return found;
}

function isDirectYield(expr: Node): boolean {
	return expr.kind == NodeKind.YieldExpr && !containsYield((expr.data as YieldExprData).yieldArg);
}

// Emit yield: transition to next state + return IteratorResult.
function emitYield(sc: StateCollector, currentState: number, nextSt: number, yieldArg: Node, loc: SourceLocation, resultType: Type | null): void {
	sc.items[currentState].stmts.push(makeStateAssign(nextSt, loc, sc.stateSym));
	sc.items[currentState].stmts.push(makeReturn(makeIterResult(yieldArg, false, loc, resultType), loc));
	sc.items[currentState].isYield = true;
	sc.items[currentState].nextState = nextSt;
}

// ===== State Splitting =====
// Split a linear sequence of statements at yield points.

function emitInline(stmts: Node[], sc: StateCollector, from: number, loc: SourceLocation, resultType: Type | null): number {
	let split = false;
	for (const s of stmts) {
		if (isStateJump(s, sc) || needsSplit(s, sc)) split = true;
	}
	if (!split) {
		for (const s of stmts) sc.items[from].stmts.push(rewriteJumps(s, sc, false, false, loc));
		return from;
	}
	const next = allocState(sc);
	splitStmts(stmts, sc, from, next, loc, resultType);
	return next;
}

function splitJump(stmt: Node, sc: StateCollector, currentState: number, loc: SourceLocation, resultType: Type | null): void {
	const frameIdx = stmt.kind == NodeKind.ReturnStmt ? -1 : jumpFrame(sc, stmt, false, false);
	const exits = jumpExit(stmt, sc, frameIdx, loc);
	const loops = sc.loopStack;
	const fins = sc.finallyStack;
	let cur = currentState;
	for (let f = fins.length - 1; f >= 0; f -= 1) {
		if (fins[f].loopDepth > frameIdx) {
			sc.loopStack = loopPrefix(loops, fins[f].loopDepth);
			sc.finallyStack = finallyPrefix(fins, f);
			cur = emitInline(cloneStmts(fins[f].stmts), sc, cur, loc, resultType);
		}
	}
	sc.loopStack = loops;
	sc.finallyStack = fins;
	for (const s of exits) sc.items[cur].stmts.push(s);
}

export function splitStmts(stmts: Node[], sc: StateCollector, startState: number, exitState: number, loc: SourceLocation, resultType: Type | null): void {
	let currentState = startState;
	let i = 0;
	while (i < stmts.length) {
		const stmt = stmts[i];
		if (isStateJump(stmt, sc)) {
			splitJump(stmt, sc, currentState, loc, resultType);
			return;
		} else if (!needsSplit(stmt, sc)) {
			sc.items[currentState].stmts.push(rewriteJumps(stmt, sc, false, false, loc));
			i += 1;
		} else if (stmt.kind == NodeKind.ExprStmt) {
			const ed = stmt.data as ExprStmtData;
			if (isDirectYield(ed.expr)) {
				// yield expr; → emit return { value: expr, done: false }, transition
				const yd = ed.expr.data as YieldExprData;
				const nextSt = allocState(sc);
				emitYield(sc, currentState, nextSt, yd.yieldArg, loc, resultType);
				currentState = nextSt;
				i += 1;
			} else {
				reportUnsplit(stmt, YIELD_IN_EXPR);
				sc.items[currentState].stmts.push(stmt);
				i += 1;
			}
		} else if (stmt.kind == NodeKind.VariableDecl) {
			const vd = stmt.data as VariableDeclData;
			if (vd.initializer != null && isDirectYield(vd.initializer)) {
				// const x = yield expr; → yield, then assign on resume
				const yd = vd.initializer.data as YieldExprData;
				const nextSt = allocState(sc);
				emitYield(sc, currentState, nextSt, yd.yieldArg, loc, resultType);
				sc.items[currentState].yieldVarName = vd.declName;
				sc.items[currentState].yieldVarType = stmt.nodeType;
				// On resume: convert decl to assignment (var is lifted)
				currentState = nextSt;
				i += 1;
			} else {
				reportUnsplit(stmt, YIELD_IN_EXPR);
				sc.items[currentState].stmts.push(stmt);
				i += 1;
			}
		} else if (stmt.kind == NodeKind.WhileStmt) {
			// Flush current state to a new condition state so pre-loop stmts
			// don't re-execute on back-edge. Same pattern as reference closureiters.
			const condState = allocState(sc);
			sc.items[currentState].stmts.push(makeStateAssign(condState, loc, sc.stateSym));
			const afterSt = (i + 1 < stmts.length) ? allocState(sc) : exitState;
			splitWhile(stmt, sc, condState, afterSt, loc, resultType);
			currentState = afterSt;
			i += 1;
		} else if (stmt.kind == NodeKind.DoWhileStmt) {
			const afterSt = (i + 1 < stmts.length) ? allocState(sc) : exitState;
			splitDoWhile(stmt, sc, currentState, afterSt, loc, resultType);
			currentState = afterSt;
			i += 1;
		} else if (stmt.kind == NodeKind.IfStmt) {
			const afterSt = (i + 1 < stmts.length) ? allocState(sc) : exitState;
			splitIf(stmt, sc, currentState, afterSt, loc, resultType);
			currentState = afterSt;
			i += 1;
		} else if (stmt.kind == NodeKind.SwitchStmt) {
			const afterSt = (i + 1 < stmts.length) ? allocState(sc) : exitState;
			splitSwitch(stmt, sc, currentState, afterSt, loc, resultType);
			currentState = afterSt;
			i += 1;
		} else if (stmt.kind == NodeKind.BlockStmt) {
			// Unwrap block: forOfLower wraps lowered while loops in BlockStmt.
			const bd = stmt.data as BlockStmtData;
			const merged: Node[] = [];
			for (const bs of bd.statements) { merged.push(bs); }
			let ri = i + 1;
			while (ri < stmts.length) { merged.push(stmts[ri]); ri = ri + 1; }
			splitStmts(merged, sc, currentState, exitState, loc, resultType);
			return;
		} else if (stmt.kind == NodeKind.TryCatchStmt) {
			const td = stmt.data as TryCatchStmtData;
			const hasFinally = td.finallyBody != null && !isEmptyBlock(td.finallyBody);
			if (hasFinally) {
				const afterSt = (i + 1 < stmts.length) ? allocState(sc) : exitState;
				splitTryFinally(stmt, sc, currentState, afterSt, loc, resultType);
				currentState = afterSt;
				i += 1;
			} else if (td.catchBody == null) {
				const merged: Node[] = extractBodyStmts(td.tryBody);
				for (let ri = i + 1; ri < stmts.length; ri += 1) merged.push(stmts[ri]);
				splitStmts(merged, sc, currentState, exitState, loc, resultType);
				return;
			} else {
				const afterSt = (i + 1 < stmts.length) ? allocState(sc) : exitState;
				splitTryCatch(stmt, sc, currentState, afterSt, loc, resultType);
				currentState = afterSt;
				i += 1;
			}
		} else {
			reportUnsplit(stmt, `internal: a ${stmt.kind.toString()} statement that contains a yield or await cannot be split into states`);
			sc.items[currentState].stmts.push(stmt);
			i += 1;
		}
	}
	// Final state transitions to exit
	if (currentState != exitState) {
		sc.items[currentState].stmts.push(makeStateAssign(exitState, loc, sc.stateSym));
	}
}

// Split while loop containing yield into states:
// condState: if (cond) { $state = bodyStart } else { $state = exitState }
// bodyStates: ... (recursive split, last transitions back to condState)
function splitWhile(node: Node, sc: StateCollector, currentState: number, exitState: number, loc: SourceLocation, resultType: Type | null): void {
	const wd = node.data as WhileStmtData;
	if (containsYield(wd.whileCondition)) reportUnsplit(node, YIELD_IN_EXPR);

	// Condition state = currentState (reuse, already allocated)
	const condState = currentState;

	// Allocate body start (exit comes from caller — same pattern as splitIf)
	const bodyStart = allocState(sc);

	// Condition: if (cond) { $state = bodyStart } else { $state = exitState }
	sc.items[condState].stmts.push(
		makeIf(
			wd.whileCondition,
			makeBlock([makeStateAssign(bodyStart, loc, sc.stateSym)], loc),
			makeBlock([makeStateAssign(exitState, loc, sc.stateSym)], loc),
			loc,
		),
	);

	const bodyStmts = extractBodyStmts(wd.whileBody);
	sc.loopStack.push({ breakState: exitState, continueState: condState, label: wd.whileLabel, isLoop: true });
	splitStmts(bodyStmts, sc, bodyStart, condState, loc, resultType);
	sc.loopStack.pop();
}

function splitDoWhile(node: Node, sc: StateCollector, currentState: number, exitState: number, loc: SourceLocation, resultType: Type | null): void {
	const dd = node.data as DoWhileStmtData;
	if (containsYield(dd.doCondition)) reportUnsplit(node, YIELD_IN_EXPR);
	const bodyStart = allocState(sc);
	const condState = allocState(sc);
	sc.items[currentState].stmts.push(makeStateAssign(bodyStart, loc, sc.stateSym));
	sc.loopStack.push({ breakState: exitState, continueState: condState, label: dd.dwLabel, isLoop: !dd.dwSwitchWrapper });
	splitStmts(extractBodyStmts(dd.doBody), sc, bodyStart, condState, loc, resultType);
	sc.loopStack.pop();
	sc.items[condState].stmts.push(
		makeIf(
			dd.doCondition,
			makeBlock([makeStateAssign(bodyStart, loc, sc.stateSym)], loc),
			makeBlock([makeStateAssign(exitState, loc, sc.stateSym)], loc),
			loc,
		),
	);
}

function splitSwitch(node: Node, sc: StateCollector, currentState: number, exitState: number, loc: SourceLocation, resultType: Type | null): void {
	const sd = node.data as SwitchStmtData;
	if (containsYield(sd.switchDisc)) reportUnsplit(node, YIELD_IN_EXPR);
	const starts: number[] = [];
	for (const c of sd.switchCases) starts.push(allocState(sc));
	const dispatch: Node[] = [];
	let hasDefault = false;
	for (let k = 0; k < sd.switchCases.length; k += 1) {
		const cd = sd.switchCases[k].data as SwitchCaseData;
		if (cd.isDefault) hasDefault = true;
		dispatch.push(makeSwitchCase(cd.caseTests, [makeStateAssign(starts[k], loc, sc.stateSym)], cd.isDefault, loc));
	}
	if (!hasDefault) dispatch.push(makeSwitchCase([], [makeStateAssign(exitState, loc, sc.stateSym)], true, loc));
	sc.items[currentState].stmts.push(makeSwitch(sd.switchDisc, dispatch, loc));
	sc.loopStack.push({ breakState: exitState, continueState: -1, label: "", isLoop: false });
	for (let k = 0; k < sd.switchCases.length; k += 1) {
		const cd = sd.switchCases[k].data as SwitchCaseData;
		splitStmts(cd.caseStmts, sc, starts[k], exitState, loc, resultType);
	}
	sc.loopStack.pop();
}

// Split try/catch (no finally) containing a yield into states.
// Reference closureiters model: the try body's states form the exceptionTable
// entries (they land on the catch state); the catch body is its own state
// sequence; both rejoin at afterSt. The runtime routing (exceptionTable lookup
// on raise) is emitted by buildExcRouting as the wrapping catch.
function splitTryCatch(node: Node, sc: StateCollector, currentState: number, afterSt: number, loc: SourceLocation, resultType: Type | null): void {
	const td = node.data as TryCatchStmtData;
	const catchSt = allocState(sc);
	const tryStart = allocState(sc);
	// tryExit sits inside the excLanding range below so a trailing await's resume
	// (the re-raising read) routes to the catch, not the shared post-try state.
	const tryExit = allocState(sc);
	sc.items[currentState].stmts.push(makeStateAssign(tryStart, loc, sc.stateSym));

	splitStmts(extractBodyStmts(td.tryBody), sc, tryStart, tryExit, loc, resultType);
	// exceptionTable: every state produced for the try body lands on the catch.
	// Guard `excLanding < 0` so a nested inner try keeps its own (already-set) catch.
	for (let s = tryStart; s < sc.items.length; s += 1) {
		if (sc.items[s].excLanding < 0) sc.items[s].excLanding = catchSt;
	}
	sc.items[tryExit].stmts.push(makeStateAssign(afterSt, loc, sc.stateSym));

	// Rewrite the catch variable to read the env-carried current exception
	// ($curExc, reference :curExc) directly. buildExcRouting stores $excCaught into
	// $curExc on the raise path, which survives the await→raise→catch state
	// boundary that the runtime global msCurrException does not. Reading the env
	// field (not a per-state local) keeps the value in scope across every split
	// state and lets the env's DRC hooks own its lifetime — a local would be
	// cleaned up per-state and dangle on the try-body unwind paths.
	// $curExc carries the caught exception; its type must be the exception type
	// (DRC-owned) even when the handler never reads the catch var — otherwise the
	// env field falls back to void* and the exception leaks (no destructor hook).
	if (node.nodeType != null) sc.excType = node.nodeType;
	if (node.resolvedSym != null) {
		renameIdentInSubtree(td.catchBody, node.resolvedSym, "$curExc", node.nodeType, sc.curExcSym);
	}
	splitStmts(extractBodyStmts(td.catchBody), sc, catchSt, afterSt, loc, resultType);
}

// finallyPath helpers: the normal exit routes through a dedicated landing-free
// finally state (an exception raised BY the finally body propagates directly
// instead of re-entering a landing that would run the finally a second time);
// the exception path runs the finally then re-raises $curExc out of the
// machine (reference closureiters end-finally raise branch). Returns the
// finally state index so later excLanding mark-loops can skip it.
function appendNormalFinally(sc: StateCollector, exitStateIdx: number, frame: FinallyFrame, afterSt: number, loc: SourceLocation, resultType: Type | null): number {
	const finNormal = allocState(sc);
	sc.items[exitStateIdx].stmts.push(makeStateAssign(finNormal, loc, sc.stateSym));
	const end = emitInline(cloneStmts(frame.stmts), sc, finNormal, loc, resultType);
	sc.items[end].stmts.push(makeStateAssign(afterSt, loc, sc.stateSym));
	return finNormal;
}

function appendReraiseFinally(sc: StateCollector, finReraiseIdx: number, frame: FinallyFrame, loc: SourceLocation, resultType: Type | null): void {
	const end = emitInline(cloneStmts(frame.stmts), sc, finReraiseIdx, loc, resultType);
	sc.items[end].stmts.push(makeStateAssign(-1, loc, sc.stateSym));
	const curExcRef = makeTypedIdentResolved(sc.curExcSym, null, loc);
	if (sc.excType != null) curExcRef.nodeType = sc.excType;
	sc.items[end].stmts.push(createNode(NodeKind.ThrowStmt, { throwArg: curExcRef }, syntheticToken(loc)));
}

// Split a try that has a finally and contains a yield (in any of its bodies),
// with or without a catch. finallyPath port (reference closureiters): the
// reference routes finally exits through a runtime :finallyPath env array;
// here each exit runs its own copy of the finally body (split into states when
// the finally yields), which is equivalent because the exits are mutually
// exclusive (the reference itself inlines single-entry states). Exits covered:
//   normal try completion   → finNormal  [fin..., goto afterSt]
//   normal catch completion → finNormal2 [fin..., goto afterSt]  (catch case)
//   raise in try body       → catchSt (catch case) / finReraise
//   raise in catch body     → finReraise [fin..., $state=-1, rethrow $curExc]
//   break/continue/return crossing the try → splitStmts via sc.finallyStack
// tryExit/catchExit keep an excLanding on purpose: a
// trailing await's resume read (the re-raising read) executes at their entry.
// Known divergence from the reference's runtime routing: a finally body that
// itself raises can run twice on the resume-read boundary path (the reference
// runs it once) — a corner documented at corpus 420.
function splitTryFinally(node: Node, sc: StateCollector, currentState: number, afterSt: number, loc: SourceLocation, resultType: Type | null): void {
	const td = node.data as TryCatchStmtData;
	if (node.nodeType != null) sc.excType = node.nodeType;
	const tryStart = allocState(sc);
	const tryExit = allocState(sc);
	sc.items[currentState].stmts.push(makeStateAssign(tryStart, loc, sc.stateSym));
	const frame: FinallyFrame = { stmts: extractBodyStmts(td.finallyBody), loopDepth: sc.loopStack.length, hasYield: containsYield(td.finallyBody) };
	sc.finallyStack.push(frame);

	if (td.catchBody == null) {
		const finReraise = allocState(sc);
		splitStmts(extractBodyStmts(td.tryBody), sc, tryStart, tryExit, loc, resultType);
		for (let s = tryStart; s < sc.items.length; s += 1) {
			if (s != finReraise && sc.items[s].excLanding < 0) sc.items[s].excLanding = finReraise;
		}
		sc.finallyStack.pop();
		appendReraiseFinally(sc, finReraise, frame, loc, resultType);
		appendNormalFinally(sc, tryExit, frame, afterSt, loc, resultType);
	} else {
		// tryStart/tryExit are pre-allocated above, so catchSt's index sits
		// INSIDE the try-body mark range — the `s !== catchSt` guard keeps the
		// catch from landing on itself (splitTryCatch avoids this by allocating
		// catchSt first; here the two mark loops below cover both orders).
		const catchSt = allocState(sc);
		splitStmts(extractBodyStmts(td.tryBody), sc, tryStart, tryExit, loc, resultType);
		for (let s = tryStart; s < sc.items.length; s += 1) {
			if (s != catchSt && sc.items[s].excLanding < 0) sc.items[s].excLanding = catchSt;
		}
		sc.finallyStack.pop();
		const finNormalStart = sc.items.length;
		appendNormalFinally(sc, tryExit, frame, afterSt, loc, resultType);
		const finNormalEnd = sc.items.length;
		sc.finallyStack.push(frame);
		const catchExit = allocState(sc);
		const finReraise = allocState(sc);
		splitStmts(extractBodyStmts(td.catchBody), sc, catchSt, catchExit, loc, resultType);
		// The normal-exit finally states stay landing-free (single finally run);
		// everything else in the catch range — catchSt itself, catchExit's entry
		// read included — runs the finally then re-raises.
		for (let s = catchSt; s < sc.items.length; s += 1) {
			const inFinNormal = s >= finNormalStart && s < finNormalEnd;
			if (s != finReraise && !inFinNormal && sc.items[s].excLanding < 0) sc.items[s].excLanding = finReraise;
		}
		sc.finallyStack.pop();
		appendReraiseFinally(sc, finReraise, frame, loc, resultType);
		appendNormalFinally(sc, catchExit, frame, afterSt, loc, resultType);
	}
}

// Rewrite every Identifier named `oldName` in `node`'s subtree to `newName`,
// stamping `typ` so member access (e.g. `$curExc.message`) resolves post-check.
function renameIdentInSubtree(node: Node, oldSym: Symbol, newName: string, typ: Type | null, newSym: Symbol): void {
	if (node == null) return;
	if (node.kind == NodeKind.Identifier) {
		if (node.resolvedSym == oldSym) {
			(node.data as IdentifierData).name = newName;
			if (typ != null) node.nodeType = typ;
			node.resolvedSym = newSym;
		}
		return;
	}
	forEachChild(node, (child: Node): void => { renameIdentInSubtree(child, oldSym, newName, typ, newSym); });
}

// Wrapping-catch body: capture the exception into $exc, then map the raising
// state to its landing (reference exceptionTable[:state]) as an if-chain; a state
// with no landing propagates out (go terminal + re-raise).
export function buildExcRouting(sc: StateCollector, caughtSym: Symbol, loc: SourceLocation): Node {
	const stmts: Node[] = [];
	// Carry the caught exception across the state boundary (reference :curExc) so
	// the catch state can bind its variable from $curExc after control resumes.
	// MOVE (reference nkFastAsgn — no incref): $curExc becomes the exception's sole
	// owner and the env's DRC hooks free it once. A copy here over-owns (the sole
	// currException ref is dropped by the clear without decref) → leak on every catch.
	stmts.push(makeExprStmt(makeAssign(makeTypedIdentResolved(sc.curExcSym, null, loc), makeMoveExpr(makeTypedIdentResolved(caughtSym, null, loc), loc), loc), loc));
	// Terminal re-raises $curExc — the slot the store above just filled — never
	// $excCaught, which the store's move already nulled (reference closureiters
	// wrapIntoTryExcept re-raises :curExc). Typed so the raise-arg sink fires.
	const curExcRef = makeTypedIdentResolved(sc.curExcSym, null, loc);
	if (sc.excType != null) curExcRef.nodeType = sc.excType;
	const rethrow = createNode(NodeKind.ThrowStmt, { throwArg: curExcRef }, syntheticToken(loc));
	let chain: Node = makeBlock([makeStateAssign(-1, loc, sc.stateSym), rethrow], loc);
	for (let i = sc.items.length - 1; i >= 0; i -= 1) {
		if (sc.items[i].excLanding >= 0) {
			const cond = makeBinary(makeTypedIdentResolved(sc.stateSym, null, loc), "===", makeNumber(i, loc), loc);
			const then = makeBlock([makeStateAssign(sc.items[i].excLanding, loc, sc.stateSym)], loc);
			chain = makeIf(cond, then, chain, loc);
		}
	}
	stmts.push(chain);
	return makeBlock(stmts, loc);
}

export function hasExcLanding(sc: StateCollector): boolean {
	for (const st of sc.items) { if (st.excLanding >= 0) return true; }
	return false;
}

export function wrapExcRouting(dispatch: Node, sc: StateCollector, loc: SourceLocation): Node {
	if (!hasExcLanding(sc)) return dispatch;
	const caughtSym = makeCatchSym("$excCaught");
	return makeTryCatch(dispatch, caughtSym, buildExcRouting(sc, caughtSym, loc), null as unknown as Node, loc);
}

export function makeCurExcDecl(sc: StateCollector, loc: SourceLocation): Node {
	const curExcDecl = makeVarDecl("$curExc", makeNull(loc), DeclKind.Let, loc);
	curExcDecl.resolvedSym = sc.curExcSym;
	// No known exception type (catch-less try/finally): a raw Ptr<void> holder.
	// Never noneType() — TypeKind.None is a sentinel that trips the codegen
	// unresolved-type gate. DRC corner (documented, same as an untyped env
	// field): a ref exception rethrown through a catch-less finally has no
	// destructor hook on this holder and leaks on the error path.
	curExcDecl.nodeType = sc.excType != null ? sc.excType : createPtr(createPrimitive(TypeKind.Void));
	return curExcDecl;
}

// Split if-else containing yield:
// currentState: if (cond) { $state = thenStart } else { $state = elseStart }
// thenStates: ... → joinState
// elseStates: ... → joinState
function splitIf(node: Node, sc: StateCollector, currentState: number, joinState: number, loc: SourceLocation, resultType: Type | null): void {
	const id = node.data as IfStmtData;
	if (containsYield(id.condition)) reportUnsplit(node, YIELD_IN_EXPR);

	const thenStart = allocState(sc);
	const hasElse = id.alternate != null && (id.alternate.kind != NodeKind.NullLiteral && id.alternate.kind != NodeKind.BlockStmt || (id.alternate.kind == NodeKind.BlockStmt && (id.alternate.data as BlockStmtData).statements.length > 0));

	if (hasElse && needsSplit(id.alternate, sc)) {
		const elseStart = allocState(sc);
		sc.items[currentState].stmts.push(
			makeIf(
				id.condition,
				makeBlock([makeStateAssign(thenStart, loc, sc.stateSym)], loc),
				makeBlock([makeStateAssign(elseStart, loc, sc.stateSym)], loc),
				loc,
			),
		);
		const thenStmts = extractBodyStmts(id.consequent);
		splitStmts(thenStmts, sc, thenStart, joinState, loc, resultType);
		const elseStmts = extractBodyStmts(id.alternate);
		splitStmts(elseStmts, sc, elseStart, joinState, loc, resultType);
	} else {
		// Only then branch has yield (or no else). Since else has no await,
		// inline its body inside the if-else's else branch (executed
		// conditionally when cond=false), followed by transition to joinState.
		// Earlier this incorrectly pushed else body into joinState's stmts,
		// which leaked the else body into the parent context (e.g. an
		// enclosing while-condition state ran the else body unconditionally).
		const elseBlockStmts: Node[] = [];
		if (hasElse) {
			const elseStmts = extractBodyStmts(id.alternate);
			for (const s of elseStmts) elseBlockStmts.push(rewriteJumps(s, sc, false, false, loc));
		}
		elseBlockStmts.push(makeStateAssign(joinState, loc, sc.stateSym));

		sc.items[currentState].stmts.push(
			makeIf(
				id.condition,
				makeBlock([makeStateAssign(thenStart, loc, sc.stateSym)], loc),
				makeBlock(elseBlockStmts, loc),
				loc,
			),
		);
		const thenStmts = extractBodyStmts(id.consequent);
		splitStmts(thenStmts, sc, thenStart, joinState, loc, resultType);
	}
}

// ===== Variable Declaration → Assignment =====
// Convert lifted variable declarations to assignments in state bodies.
// Variables are hoisted to function scope, so decls become assignments.

export function convertDeclsToAssigns(stmts: Node[], liftedNames: NameSet, loc: SourceLocation): void {
	for (let i = 0; i < stmts.length; i += 1) {
		const stmt = stmts[i];
		if (stmt.kind == NodeKind.VariableDecl) {
			const vd = stmt.data as VariableDeclData;
			if (nameSetContains(liftedNames, vd.declName) && vd.initializer != null) {
				// Convert: const/let x = init → x = init (assignment)
				// Preserve the VarDecl's resolvedSym on the LHS Identifier so downstream
				// passes (lambdaLifting capture resolution, codegen) identify this as the
				// original local binding — not a fall-through to an outer/global with the
				// same name. Critical for shadow-safe rewriting of async state machines.
				const lhs = (stmt.resolvedSym != null)
					? makeIdentResolved(stmt.resolvedSym, loc)
					: makeIdent(vd.declName, loc);
				(lhs.data as IdentifierData).name = vd.declName;
				stmts[i] = makeExprStmt(makeAssign(lhs, vd.initializer, loc), loc);
			}
		}
	}
}

// ===== State Machine Builder =====

function buildStateDispatch(sc: StateCollector, loc: SourceLocation, resultType: Type | null): Node {
	// Default (terminal) state: return { value: null, done: true }
	let current: Node = makeBlock([makeReturn(makeDoneResult(loc, resultType), loc)], loc);

	// Build if-else chain from last state to first
	for (let i = sc.items.length - 1; i >= 0; i -= 1) {
		const stateIdx = sc.items[i].index;
		const cond = makeBinary(
			makeTypedIdentResolved(sc.stateSym, null, loc), "===",
			makeNumber(stateIdx, loc), loc,
		);
		const body = makeBlock(sc.items[i].stmts, loc);
		current = makeIf(cond, body, current, loc);
	}
	return current;
}

// ===== Generator Function Transform =====

function transformGeneratorFn(params: string[], paramTypes: string[], body: Node, flags: string, returnType: string, returnNodeType: Type | null, loc: SourceLocation): Node {
	// 1. Collect all local variable names and their types
	renameRepeatedBindingsInFrame(params, body, "$g");
	const nc: NameSet = createNameSet();
	collectDeclNames(body, nc, false);
	const dtNames: string[] = [];
	const dtTypes: Type[] = [];
	const dtSyms: Symbol[] = [];
	collectDeclTypes(body, dtNames, dtTypes, dtSyms);

	// 2. Extract body statements
	const bodyStmts = extractBodyStmts(body);

	// Build IteratorResult<T> type for stamping yield/return literals
	const iterResultType = buildIterResultType(returnNodeType);
	const stateSym = makeSymbol("$state", SymbolKind.Variable, numberType(), true);
	setFlag(stateSym, SymbolFlag.StateMachine);
	const curExcSym = makeSymbol("$curExc", SymbolKind.Variable, null as unknown as Type, true);

	// 4. Split at yield points
	const sc: StateCollector = { items: [], loopStack: [], excType: null, finallyStack: [], stateSym, curExcSym, genReturns: true, genResultType: iterResultType };
	const initState = allocState(sc);
	const doneState = -1;  // terminal

	splitStmts(bodyStmts, sc, initState, doneState, loc, iterResultType);

	// 5. Convert variable declarations to assignments in all state bodies
	for (const st of sc.items) {
		convertDeclsToAssigns(st.stmts, nc, loc);
	}

	// 6. Build the state dispatch (if-else chain)
	const dispatch = buildStateDispatch(sc, loc, iterResultType);

	// 6b. If any state has an exception landing (a try with a yield inside),
	// wrap the dispatch in a try/catch that routes a raised state to its
	// landing (reference closureiters exceptionTable + the wrapping except).
	const hasExc = hasExcLanding(sc);
	const dispatchBody = wrapExcRouting(dispatch, sc, loc);

	// 7. Wrap in while(true) { dispatch }
	const loop = makeWhile(makeBool(true, loc), dispatchBody, loc);

	// 8. Build next() function body
	const nextBody = makeBlock([loop], loc);

	// 9. Create next FunctionExpr with proper return type (IteratorResult<T>)
	// Lambda lifting uses nodeType to determine the lifted function's return type.
	const nextFnType = getIteratorNextFnType(returnNodeType);
	const nextFn = createNode(NodeKind.FunctionExpr, {
		funcExprParams: [],
		funcExprParamTypes: [],
		funcExprBody: nextBody,
		funcExprFlags: "",
		funcExprReturnType: "",
	}, syntheticToken(loc));
	if (nextFnType != null) nextFn.nodeType = nextFnType;
	nextFn.paramSyms = [];

	// 10. Build iterator object: { next: function() { ... } }
	// Set nodeType to Iterator so C codegen emits the named struct, not anonymous.
	const iterObj = makeObjectLiteral(["next"], [nextFn], loc);
	if (returnNodeType != null && isIterator(returnNodeType)) {
		iterObj.nodeType = returnNodeType;
	}

	// 11. Build new function body:
	//   let $state = 0;
	//   let local1; let local2; ...
	//   return { next: function() { while(true) { if-else dispatch } } };
	const newBodyStmts: Node[] = [];
	const stateDecl = makeVarDecl("$state", makeNumber(0, loc), DeclKind.Let, loc);
	stateDecl.resolvedSym = stateSym;
	newBodyStmts.push(stateDecl);
	if (hasExc) newBodyStmts.push(makeCurExcDecl(sc, loc));
	for (const localName of nc.items) {
		// Stamp original nodeType so lambda lifting creates correctly-typed env fields.
		// Reference parity: captureVar always adds field with original type.
		const dtIdx = lookupDeclIdx(dtNames, localName);
		const decl = makeVarDecl(localName, dtIdx >= 0 ? makeDefaultValue(dtTypes[dtIdx], loc) : makeNull(loc), DeclKind.Let, loc);
		if (dtIdx >= 0) {
			decl.nodeType = dtTypes[dtIdx];
			decl.resolvedSym = dtSyms[dtIdx];
		}
		newBodyStmts.push(decl);
	}
	newBodyStmts.push(makeReturn(iterObj, loc));

	return makeBlock(newBodyStmts, loc);
}

// ===== Main Walk =====

function walkGenerators(node: Node): void {
	match (node.kind) {
		NodeKind.Program => {
			const d = node.data as ProgramData;
			for (const s of d.programStmts) { walkGenerators(s); }
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			for (const s of d.statements) { walkGenerators(s); }
		},
		NodeKind.FunctionDecl => {
			const d = node.data as FunctionDeclData;
			walkGenerators(d.fnBody);
			if (isGeneratorFlag(d.fnFlags)) {
				// Skip generic templates — only monomorphized instances should be lowered.
				// Generic templates have unresolved type params that produce void in C.
				const fnType = node.resolvedSym != null ? node.resolvedSym.symbolType : null;
				if (fnType != null && hasGenericParams(fnType)) {
					// Keep generator flag so monomorphized instances still get lowered
				} else {
					const retType = fnType != null ? fnType.typeReturn : null;
					d.fnBody = transformGeneratorFn(
						d.params, d.fnParamTypes, d.fnBody,
						d.fnFlags, d.fnReturnType, retType, node.location,
					);
					d.fnFlags = "";
				}
			}
		},
		NodeKind.ExportDecl => {
			const d = node.data as ExportDeclData;
			walkGenerators(d.exportedDecl);
		},
		NodeKind.ClassDecl => {
			const d = node.data as ClassDeclData;
			for (const member of d.classBody) { walkGenerators(member); }
		},
		NodeKind.MethodDecl => {
			const d = node.data as MethodDeclData;
			walkGenerators(d.methodBody);
		},
		NodeKind.DecoratedDecl => {
			const d = node.data as DecoratedDeclData;
			walkGenerators(d.decoratedNode);
		},
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			if (d.initializer != null) walkCheckFuncExpr(d.initializer);
		},
		_ => {},
	};
}

// Check FunctionExpr for generator flag
function walkCheckFuncExpr(node: Node): void {
	if (node.kind == NodeKind.FunctionExpr) {
		const d = node.data as FunctionExprData;
		walkGenerators(d.funcExprBody);
		if (isGeneratorFlag(d.funcExprFlags)) {
			d.funcExprBody = transformGeneratorFn(
				d.funcExprParams, d.funcExprParamTypes, d.funcExprBody,
				d.funcExprFlags, d.funcExprReturnType, node.nodeType != null ? node.nodeType.typeReturn : null, node.location,
			);
			d.funcExprFlags = "";
		}
	}
}

// ===== Main Entry Point =====

export function lowerGenerator(program: Node, ctx: TransformContext): Node {
	walkGenerators(program);
	for (const d of pendingSplitDiags) {
		reportTransformError(ctx, d.message, d.loc);
	}
	pendingSplitDiags = [];
	return program;
}

// ===== Tests =====
test "non-generator passthrough" { assert firstStmtKindAfter("function foo() { return 1; }", lowerGenerator) == NodeKind.FunctionDecl; }

test "stmt count passthrough" { assert stmtCountAfter("const x = 1;", lowerGenerator) == 1; }

test "generator still one stmt" {
	// function* gen() { yield 1; } → function gen() { ... } — still 1 top-level stmt
	assert stmtCountAfter("function* gen() { yield 1; }", lowerGenerator) == 1;
}

test "generator flag removed" { assert firstStmtKindAfter("function* gen() { yield 1; }", lowerGenerator) == NodeKind.FunctionDecl; }

test "try finally with yield splits" { assert stmtCountAfter("function* gen() { try { yield 1; } finally { x = 2; } }", lowerGenerator) == 1; }

test "try catch finally with yield splits" { assert stmtCountAfter("function* gen() { try { yield 1; } catch (e) { y = 3; } finally { x = 2; } }", lowerGenerator) == 1; }

test "yield in finally splits" { assert stmtCountAfter("function* gen() { try { x = 1; } finally { yield 2; } }", lowerGenerator) == 1; }

test "two yields" { assert stmtCountAfter("function* gen() { yield 1; yield 2; }", lowerGenerator) == 1; }

test "yield with locals" { assert stmtCountAfter("function* gen() { let x = 1; yield x; }", lowerGenerator) == 1; }

test "while yield loop" { assert stmtCountAfter("function* gen() { let i = 0; while (i < 3) { yield i; i = i + 1; } }", lowerGenerator) == 1; }

test "regular function unchanged" { assert stmtCountAfter("function f() { while (true) {} }", lowerGenerator) == 1; }

function splitErrorsFor(src: string): int32 {
	const parsed = parseInput(src);
	if (!parsed.ok) return -1 as int32;
	const ctx = makeCtx();
	lowerGenerator(parsed.value, ctx);
	return ctx.errors.length as int32;
}

test "a yield inside an expression is reported, not passed through" { assert splitErrorsFor("function* gen() { const v = (yield 1) + 1; }") == 1; }

test "a statement kind the splitter cannot split is reported" { assert splitErrorsFor("function* gen() { throw (yield 1); }") == 1; }

test "a splittable body reports nothing" { assert splitErrorsFor("function* gen() { do { yield 1; } while (false); switch (1) { case 1: yield 2; } }") == 0; }
