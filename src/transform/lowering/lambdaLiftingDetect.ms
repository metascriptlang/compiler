// Lambda Lifting Detection Pass (Pass 1 of two-pass design)
//
// Walks the entire program ONCE to collect capture info for every closure-bearing
// function before any lifting happens. The lift pass (`lambdaLifting.ms`) consumes
// this via `detectionGetCaptures` / `detectionGetCapturedIdents` instead of
// running per-function detection inline.
//
// Reference: Nim's `detectCapturedVars` (`compiler/lambdalifting.nim:430-516`) +
// `DetectionPass` struct (`lambdalifting.nim:297-310`).

import {
	Node, NodeKind, ArrowFunctionData, FunctionExprData,
	VariableDeclData, BlockStmtData, ExprStmtData, ReturnStmtData,
	IfStmtData, WhileStmtData, DoWhileStmtData, TryCatchStmtData,
	BinaryExprData, UnaryExprData, CallExprData, SwitchStmtData,
	SwitchCaseData, ExportDeclData, FunctionDeclData, MethodDeclData,
	ConstructorDeclData, TestDeclData, SymbolKind, DeclKind, Symbol, BooleanLiteralData,
} from "../../ast/node";
import { SymSet, createSymSet, symSetAdd, symSetContains } from "../context";
import { mapChildren, isFuncBoundary } from "../walker";
import { forEachChild } from "../../ast/visitor";
import { hasFlag, SymbolFlag } from "../../checker/symbol";
import {
	ScopeStack, createScopeStack, cloneScopeStack, pushFuncBoundary,
	popFuncBoundary, defineVar, defineParams, isLocalVar, isOuterVar, isModuleLevelVar,
} from "./lambdaLiftingScope";

// Result of capture detection over a single closure-bearing function body.
export interface DetectResult {
	captures: SymSet;
	capturedIdents: Node[];
}

// Per-FunctionDecl detection results. Parallel-array layout (lookup is O(n) by
// FunctionDecl Node identity; typically <100 fns per module so the linear scan
// is fine for first cut — switch to a real Map if profiling demands).
//
// Records the union of all captures across closures nested within each
// FunctionDecl / MethodDecl / ConstructorDecl. The lift pass consumes this via
// `detectionGetCaptures` and `detectionGetCapturedIdents`.
export interface DetectionState {
	fnNodes: Node[];
	fnCaptures: SymSet[];
	fnCapturedIdents: Node[][];
}

export function createDetectionState(): DetectionState {
	const s: DetectionState = {
		fnNodes: [],
		fnCaptures: [],
		fnCapturedIdents: [],
	};
	return s;
}

// Linear scan helper: find index of `target` in `arr` by reference equality.
// Returns -1 when not present. Centralizes the parallel-array lookup pattern
// used by the four `detectionGet*` accessors below.
function findNodeIdx(arr: Node[], target: Node): number {
	let i = 0;
	while (i < arr.length) {
		if (arr[i] == target) return i;
		i += 1;
	}
	return -1;
}

// Lookup captures for a given FunctionDecl. Returns an empty set for
// missing entries (the fn was not visited by Pass 1, or had no captures).
export function detectionGetCaptures(state: DetectionState, fnNode: Node): SymSet {
	const idx = findNodeIdx(state.fnNodes, fnNode);
	return idx >= 0 ? state.fnCaptures[idx] : createSymSet();
}

export function detectionGetCapturedIdents(state: DetectionState, fnNode: Node): Node[] {
	const idx = findNodeIdx(state.fnNodes, fnNode);
	return idx >= 0 ? state.fnCapturedIdents[idx] : [];
}


// ===== Capture Detection Walker =====
// Walks a function body, identifying which outer-scope vars are referenced from
// inside any nested closure. Tracks closure depth — only references inside arrow
// or function-expression bodies count as captures.
//
// Module-level state avoids closure-of-closure issues: this code itself is
// lambda-lifting-relevant and we run it BEFORE any lifting happens.

let _detectAllSyms: SymSet = createSymSet();
let _detectAllSS: ScopeStack = createScopeStack();
let _detectAllIdents: Node[] = [];
let _detectClosureDepth: number = 0;  // >0 when inside a closure
// Number of funcMarkers at start of the current detectAllCaptures call.
// Used to filter out captures whose defining frame was pushed DURING the walk
// (i.e., locals of nested closures owned by their own envs, not by F's env).
let _detectInitialMarkers: number = 0;
let _detectPendingRoutine: Symbol | null = null;
let _detectRoutine: Symbol | null = null;
let _detectRoutineDepth: number = 0;

export function routineBindingSym(node: Node): Symbol | null {
	if (node.kind != NodeKind.VariableDecl) return null;
	const d = node.data as VariableDeclData;
	if (d.declKind != DeclKind.Const || d.initializer == null) return null;
	if (d.initializer.kind != NodeKind.ArrowFunction && d.initializer.kind != NodeKind.FunctionExpr) return null;
	return node.resolvedSym;
}

// True if `sym`'s defining frame index is < `_detectInitialMarkers`,
// i.e., the var lives in F's own frame or one of F's ancestors — never in a
// frame pushed during F's body walk.
function definedAtOrAboveInitial(sym: Symbol): boolean {
	let symIdx = -1;
	let i = _detectAllSS.syms.length - 1;
	while (i >= 0) {
		if (_detectAllSS.syms[i] == sym) { symIdx = i; break; }
		i -= 1;
	}
	if (symIdx < 0) return false;
	// Find defining frame: highest funcMarker idx s.t. funcMarkers[idx] <= symIdx.
	// If no funcMarker is <= symIdx, the var is module-level — keep it (handled
	// elsewhere by isModuleLevelVar filter).
	let frameIdx = _detectAllSS.funcMarkers.length;
	let j = _detectAllSS.funcMarkers.length - 1;
	while (j >= 0) {
		if (_detectAllSS.funcMarkers[j] <= symIdx) { frameIdx = j; break; }
		j -= 1;
	}
	if (frameIdx >= _detectAllSS.funcMarkers.length) return true;
	return frameIdx < _detectInitialMarkers;
}

// Detect all captures from a function body. Single entry point; returns both
// the captured-symbol set and the parallel array of original Identifier nodes
// (preserved for symbol/type info during lifting).
//
// Only counts refs to vars defined in F's frame or one of F's ancestors. Vars
// declared inside a NESTED closure's body (e.g., `state` in an outer arrow when
// detection runs for the enclosing FunctionDecl) are EXCLUDED here — they
// belong to that nested closure's own env. Each closure boundary records its
// own captures via separate detectAllCaptures calls (see `detectPassWalk`).
export function detectAllCaptures(body: Node, ss: ScopeStack): DetectResult {
	_detectAllSyms = createSymSet();
	_detectAllIdents = [];
	_detectClosureDepth = 0;
	_detectPendingRoutine = null;
	_detectRoutine = null;
	_detectRoutineDepth = 0;
	_detectAllSS = cloneScopeStack(ss);
	_detectInitialMarkers = _detectAllSS.funcMarkers.length;
	detectAllWalk(body);
	const result: DetectResult = {
		captures: _detectAllSyms,
		capturedIdents: _detectAllIdents,
	};
	_detectAllSyms = createSymSet();
	_detectAllIdents = [];
	return result;
}

function detectClosureBody(paramSyms: Symbol[] | null, params: string[], body: Node): void {
	const savedRoutine = _detectRoutine;
	const savedRoutineDepth = _detectRoutineDepth;
	_detectRoutine = _detectPendingRoutine;
	_detectPendingRoutine = null;
	pushFuncBoundary(_detectAllSS);
	_detectClosureDepth += 1;
	_detectRoutineDepth = _detectClosureDepth;
	defineParams(_detectAllSS, paramSyms, params);
	detectAllWalk(body);
	_detectClosureDepth -= 1;
	popFuncBoundary(_detectAllSS);
	_detectRoutine = savedRoutine;
	_detectRoutineDepth = savedRoutineDepth;
}

function detectAllWalk(node: Node | null): void {
	if (node == null) return;
	if (node.kind == NodeKind.Identifier) {
		const sym = node.resolvedSym;
		if (sym == null) return;
		if (_detectRoutine != null && sym == _detectRoutine && _detectClosureDepth == _detectRoutineDepth) return;
		// Only capture at closure depth > 0 (inside ArrowFunction/FunctionExpr).
		// Variables in the main function body are directly accessible — no capture needed.
		if (_detectClosureDepth > 0 && !isLocalVar(_detectAllSS, sym) && isOuterVar(_detectAllSS, sym) && definedAtOrAboveInitial(sym)) {
			// Reference parity (interestingVar): only capture variables and params.
			// Skip types (Class, Interface, TypeAlias, Enum) — they're not runtime values.
			const sk = sym.symbolKind;
			if (sk == SymbolKind.Class || sk == SymbolKind.Interface
				|| sk == SymbolKind.TypeAlias || sk == SymbolKind.Enum) {
				return;
			}
			// Reference parity (interestingVar): sfGlobal check on resolved symbol.
			// Only for Variable/Parameter — these have the Global flag set correctly.
			// Functions and other symbols use the frame they are bound in.
			const isModLevel = (sk == SymbolKind.Variable || sk == SymbolKind.Temp || sk == SymbolKind.Parameter)
				? hasFlag(sym, SymbolFlag.Global)
				: isModuleLevelVar(_detectAllSS, sym);
			if (!isModLevel) {
				if (!symSetContains(_detectAllSyms, sym)) {
					_detectAllIdents.push(node);
				}
				symSetAdd(_detectAllSyms, sym);
			}
		}
		return;
	}
	// Don't enter nested named functions (separate lift scope)
	if (node.kind == NodeKind.FunctionDecl || node.kind == NodeKind.MethodDecl || node.kind == NodeKind.ConstructorDecl) return;
	// Enter closures: push boundary, define params, recurse body, pop, track depth
	if (node.kind == NodeKind.ArrowFunction) {
		const d = node.data as ArrowFunctionData;
		detectClosureBody(node.paramSyms, d.arrowParams, d.arrowBody);
		return;
	}
	if (node.kind == NodeKind.FunctionExpr) {
		const d = node.data as FunctionExprData;
		detectClosureBody(node.paramSyms, d.funcExprParams, d.funcExprBody);
		return;
	}
	// Track variable definitions for scope awareness
	if (node.kind == NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		const isSelfRefClosureInit = d.initializer != null
			&& (d.initializer.kind == NodeKind.ArrowFunction
				|| d.initializer.kind == NodeKind.FunctionExpr);
		if (isSelfRefClosureInit) defineVar(_detectAllSS, node.resolvedSym, d.declName);
		_detectPendingRoutine = routineBindingSym(node);
		detectAllWalk(d.initializer);
		_detectPendingRoutine = null;
		if (!isSelfRefClosureInit) defineVar(_detectAllSS, node.resolvedSym, d.declName);
		return;
	}
	// Generic: recurse children via explicit dispatch (avoid deep mapChildren stack)
	if (node.kind == NodeKind.BlockStmt) {
		const d = node.data as BlockStmtData;
		for (const s of d.statements) detectAllWalk(s);
		return;
	}
	if (node.kind == NodeKind.ExprStmt) {
		detectAllWalk((node.data as ExprStmtData).expr);
		return;
	}
	if (node.kind == NodeKind.ReturnStmt) {
		detectAllWalk((node.data as ReturnStmtData).argument);
		return;
	}
	if (node.kind == NodeKind.IfStmt) {
		const d = node.data as IfStmtData;
		detectAllWalk(d.condition);
		detectAllWalk(d.consequent);
		detectAllWalk(d.alternate);
		return;
	}
	if (node.kind == NodeKind.WhileStmt) {
		const d = node.data as WhileStmtData;
		detectAllWalk(d.whileCondition);
		detectAllWalk(d.whileBody);
		return;
	}
	if (node.kind == NodeKind.DoWhileStmt) {
		const d = node.data as DoWhileStmtData;
		detectAllWalk(d.doBody);
		detectAllWalk(d.doCondition);
		return;
	}
	if (node.kind == NodeKind.TryCatchStmt) {
		const d = node.data as TryCatchStmtData;
		detectAllWalk(d.tryBody);
		if (d.catchName != "") defineVar(_detectAllSS, node.resolvedSym, d.catchName);
		detectAllWalk(d.catchBody);
		detectAllWalk(d.finallyBody);
		return;
	}
	if (node.kind == NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		detectAllWalk(d.left);
		detectAllWalk(d.right);
		return;
	}
	if (node.kind == NodeKind.UnaryExpr) {
		detectAllWalk((node.data as UnaryExprData).operand);
		return;
	}
	if (node.kind == NodeKind.CallExpr) {
		const d = node.data as CallExprData;
		detectAllWalk(d.callee);
		for (const a of d.arguments) detectAllWalk(a);
		return;
	}
	if (node.kind == NodeKind.SwitchStmt) {
		const d = node.data as SwitchStmtData;
		detectAllWalk(d.switchDisc);
		for (const c of d.switchCases) detectAllWalk(c);
		return;
	}
	if (node.kind == NodeKind.SwitchCase) {
		const d = node.data as SwitchCaseData;
		for (const t of d.caseTests) detectAllWalk(t);
		for (const s of d.caseStmts) detectAllWalk(s);
		return;
	}
	if (node.kind == NodeKind.ExportDecl) {
		detectAllWalk((node.data as ExportDeclData).exportedDecl);
		return;
	}
	// For remaining node kinds: use mapChildren as fallback
	mapChildren(node, (child: Node): Node => { detectAllWalk(child); return child; });
}

export function isOnceLoop(n: Node): boolean {
	if (n.kind != NodeKind.DoWhileStmt) return false;
	const c = (n.data as DoWhileStmtData).doCondition;
	return c != null && c.kind == NodeKind.BooleanLiteral && !(c.data as BooleanLiteralData).boolValue;
}

export function iterationBodyOf(n: Node): Node | null {
	if (n.kind == NodeKind.WhileStmt) return (n.data as WhileStmtData).whileBody;
	if (n.kind == NodeKind.DoWhileStmt && !isOnceLoop(n)) return (n.data as DoWhileStmtData).doBody;
	return null;
}

export function collectIterationDecls(n: Node | null, out: Node[]): void {
	if (n == null) return;
	if (n.kind == NodeKind.VariableDecl) {
		const sym = n.resolvedSym;
		if (sym == null || !hasFlag(sym, SymbolFlag.Global)) out.push(n);
		return;
	}
	if (isFuncBoundary(n) || iterationBodyOf(n) != null) return;
	if (n.kind == NodeKind.ForStmt || n.kind == NodeKind.ForOfStmt || n.kind == NodeKind.ForInStmt) return;
	forEachChild(n, (c: Node): void => { collectIterationDecls(c, out); });
}

// ===== detectPass: Top-level Pass 1 entry =====
// Walks the entire program, finding every FunctionDecl/MethodDecl/ConstructorDecl
// boundary and recording the captures of closures nested within. Result is keyed
// by the FunctionDecl node — `lambdaLifting.ms`'s walkLift consumes via
// `detectionGetCaptures(state.detection, fnNode)` instead of running detection
// inline.
export function detectPass(program: Node): DetectionState {
	const state = createDetectionState();
	// Top-level walk: no enclosing fn yet (module scope).
	detectPassWalk(program, state, createScopeStack(), null);
	return state;
}

// Record a fn-like declaration's captures (FunctionDecl / MethodDecl /
// ConstructorDecl): build a fresh scope frame, run capture detection on the
// body, push results into the parallel arrays, then recurse into the body
// with this fn as the new enclosing fn.
function recordFnCaptures(node: Node, body: Node, params: string[], state: DetectionState, ss: ScopeStack): void {
	const fnSS = cloneScopeStack(ss);
	pushFuncBoundary(fnSS);
	defineParams(fnSS, node.paramSyms, params);
	const result = detectAllCaptures(body, fnSS);
	state.fnNodes.push(node);
	state.fnCaptures.push(result.captures);
	state.fnCapturedIdents.push(result.capturedIdents);
	detectPassWalk(body, state, fnSS, node);
}

// Recursive walker. `enclosingFn` is the nearest containing FunctionDecl /
// MethodDecl / ConstructorDecl, or null at module scope.
function detectPassWalk(node: Node, state: DetectionState, ss: ScopeStack, enclosingFn: Node | null): void {
	if (node == null) return;
	if (node.kind == NodeKind.FunctionDecl) {
		const d = node.data as FunctionDeclData;
		recordFnCaptures(node, d.fnBody, d.params, state, ss);
		return;
	}
	if (node.kind == NodeKind.MethodDecl) {
		const d = node.data as MethodDeclData;
		recordFnCaptures(node, d.methodBody, d.methodParams, state, ss);
		return;
	}
	if (node.kind == NodeKind.ConstructorDecl) {
		const d = node.data as ConstructorDeclData;
		recordFnCaptures(node, d.ctorBody, d.ctorParams, state, ss);
		return;
	}
	if (node.kind == NodeKind.TestDecl) {
		const d = node.data as TestDeclData;
		recordFnCaptures(node, d.testBody, [], state, ss);
		return;
	}
	if (node.kind == NodeKind.ArrowFunction) {
		const d = node.data as ArrowFunctionData;
		// Arrows are env-owners too (Nim parity): each arrow that has captures
		// gets its own per-call env, so locals declared inside its body don't
		// share storage across multiple invocations of the same arrow. See
		// `detectAllCaptures`'s defined-at-or-above-initial filter for how each
		// boundary's captures are scoped.
		recordFnCaptures(node, d.arrowBody, d.arrowParams, state, ss);
		return;
	}
	if (node.kind == NodeKind.FunctionExpr) {
		const d = node.data as FunctionExprData;
		recordFnCaptures(node, d.funcExprBody, d.funcExprParams, state, ss);
		return;
	}
	if (node.kind == NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		const isSelfRefClosureInit = d.initializer != null
			&& (d.initializer.kind == NodeKind.ArrowFunction
				|| d.initializer.kind == NodeKind.FunctionExpr);
		if (isSelfRefClosureInit) defineVar(ss, node.resolvedSym, d.declName);
		detectPassWalk(d.initializer, state, ss, enclosingFn);
		if (!isSelfRefClosureInit) defineVar(ss, node.resolvedSym, d.declName);
		return;
	}
	// Generic: recurse children, propagating enclosingFn.
	mapChildren(node, (child: Node): Node => { detectPassWalk(child, state, ss, enclosingFn); return child; });
}
