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
	Node, NodeKind, IdentifierData, ArrowFunctionData, FunctionExprData,
	VariableDeclData, BlockStmtData, ExprStmtData, ReturnStmtData,
	IfStmtData, WhileStmtData, DoWhileStmtData, TryCatchStmtData,
	BinaryExprData, UnaryExprData, CallExprData, SwitchStmtData,
	SwitchCaseData, ExportDeclData, FunctionDeclData, MethodDeclData,
	ConstructorDeclData, TestDeclData, SymbolKind,
} from "../../ast/node";
import { NameSet, createNameSet, nameSetAdd, nameSetContains } from "../context";
import { mapChildren } from "../walker";
import { hasFlag, SymbolFlag } from "../../checker/symbol";
import {
	ScopeStack, createScopeStack, cloneScopeStack, pushFuncBoundary,
	popFuncBoundary, defineVar, isLocalVar, isOuterVar, isModuleLevelVar,
	isBuiltinName,
} from "./lambdaLiftingScope";

// Result of capture detection over a single closure-bearing function body.
export interface DetectResult {
	captures: NameSet;
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
	fnCaptures: NameSet[];
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
		if (arr[i] === target) return i;
		i += 1;
	}
	return -1;
}

// Lookup captures for a given FunctionDecl. Returns an empty NameSet for
// missing entries (the fn was not visited by Pass 1, or had no captures).
export function detectionGetCaptures(state: DetectionState, fnNode: Node): NameSet {
	const idx = findNodeIdx(state.fnNodes, fnNode);
	return idx >= 0 ? state.fnCaptures[idx] : createNameSet();
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

let _detectAllNames: NameSet = createNameSet();
let _detectAllSS: ScopeStack = { names: [], funcMarkers: [] };
let _detectAllIdents: Node[] = [];
let _detectClosureDepth: number = 0;  // >0 when inside a closure
// Number of funcMarkers at start of the current detectAllCaptures call.
// Used to filter out captures whose defining frame was pushed DURING the walk
// (i.e., locals of nested closures owned by their own envs, not by F's env).
let _detectInitialMarkers: number = 0;

// True if `name`'s defining frame index is < `_detectInitialMarkers`,
// i.e., the var lives in F's own frame or one of F's ancestors — never in a
// frame pushed during F's body walk.
function definedAtOrAboveInitial(name: string): boolean {
	let nameIdx = -1;
	let i = _detectAllSS.names.length - 1;
	while (i >= 0) {
		if (_detectAllSS.names[i] === name) { nameIdx = i; break; }
		i -= 1;
	}
	if (nameIdx < 0) return false;
	// Find defining frame: highest funcMarker idx s.t. funcMarkers[idx] <= nameIdx.
	// If no funcMarker is <= nameIdx, the var is module-level — keep it (handled
	// elsewhere by isModuleLevelVar filter).
	let frameIdx = _detectAllSS.funcMarkers.length;
	let j = _detectAllSS.funcMarkers.length - 1;
	while (j >= 0) {
		if (_detectAllSS.funcMarkers[j] <= nameIdx) { frameIdx = j; break; }
		j -= 1;
	}
	if (frameIdx >= _detectAllSS.funcMarkers.length) return true;
	return frameIdx < _detectInitialMarkers;
}

// Detect all captures from a function body. Single entry point; returns both
// the captured-name set and the parallel array of original Identifier nodes
// (preserved for symbol/type info during lifting).
//
// Only counts refs to vars defined in F's frame or one of F's ancestors. Vars
// declared inside a NESTED closure's body (e.g., `state` in an outer arrow when
// detection runs for the enclosing FunctionDecl) are EXCLUDED here — they
// belong to that nested closure's own env. Each closure boundary records its
// own captures via separate detectAllCaptures calls (see `detectPassWalk`).
export function detectAllCaptures(body: Node, ss: ScopeStack): DetectResult {
	_detectAllNames = createNameSet();
	_detectAllIdents = [];
	_detectClosureDepth = 0;
	_detectAllSS = cloneScopeStack(ss);
	_detectInitialMarkers = _detectAllSS.funcMarkers.length;
	detectAllWalk(body);
	const result: DetectResult = {
		captures: _detectAllNames,
		capturedIdents: _detectAllIdents,
	};
	_detectAllNames = createNameSet();
	_detectAllIdents = [];
	return result;
}

function detectAllWalk(node: Node): void {
	if (node === null) return;
	if (node.kind === NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		// Only capture at closure depth > 0 (inside ArrowFunction/FunctionExpr).
		// Variables in the main function body are directly accessible — no capture needed.
		if (_detectClosureDepth > 0 && !isBuiltinName(d.name) && !isLocalVar(_detectAllSS, d.name) && isOuterVar(_detectAllSS, d.name) && definedAtOrAboveInitial(d.name)) {
			// Reference parity (interestingVar): only capture variables and params.
			// Skip types (Class, Interface, TypeAlias, Enum) — they're not runtime values.
			if (node.resolvedSym !== null) {
				const sk = node.resolvedSym.symbolKind;
				if (sk === SymbolKind.Class || sk === SymbolKind.Interface
					|| sk === SymbolKind.TypeAlias || sk === SymbolKind.Enum) {
					return;
				}
			}
			// Reference parity (interestingVar): sfGlobal check on resolved symbol.
			// Only for Variable/Parameter — these have the Global flag set correctly.
			// Functions and other symbols use name-based check (existing behavior).
			const sym = node.resolvedSym;
			const isModLevel = (sym !== null && (sym.symbolKind === SymbolKind.Variable || sym.symbolKind === SymbolKind.Parameter))
				? hasFlag(sym, SymbolFlag.Global)
				: isModuleLevelVar(_detectAllSS, d.name);
			if (!isModLevel) {
				if (!nameSetContains(_detectAllNames, d.name)) {
					_detectAllIdents.push(node);
				}
				nameSetAdd(_detectAllNames, d.name);
			}
		}
		return;
	}
	// Don't enter nested named functions (separate lift scope)
	if (node.kind === NodeKind.FunctionDecl || node.kind === NodeKind.MethodDecl || node.kind === NodeKind.ConstructorDecl) return;
	// Enter closures: push boundary, define params, recurse body, pop, track depth
	if (node.kind === NodeKind.ArrowFunction) {
		const d = node.data as ArrowFunctionData;
		pushFuncBoundary(_detectAllSS);
		_detectClosureDepth += 1;
		for (const p of d.arrowParams) defineVar(_detectAllSS, p);
		detectAllWalk(d.arrowBody);
		_detectClosureDepth -= 1;
		popFuncBoundary(_detectAllSS);
		return;
	}
	if (node.kind === NodeKind.FunctionExpr) {
		const d = node.data as FunctionExprData;
		pushFuncBoundary(_detectAllSS);
		_detectClosureDepth += 1;
		for (const p of d.funcExprParams) defineVar(_detectAllSS, p);
		detectAllWalk(d.funcExprBody);
		_detectClosureDepth -= 1;
		popFuncBoundary(_detectAllSS);
		return;
	}
	// Track variable definitions for scope awareness
	if (node.kind === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		// Self-recursive closure binding: pre-define for arrow/funcExpr inits so
		// the body's reference to the bound name detects as a capture (mirrors
		// the same heuristic in checker `checkVariableDecl` and detectPassWalk).
		const isSelfRefClosureInit = d.initializer !== null
			&& (d.initializer.kind === NodeKind.ArrowFunction
				|| d.initializer.kind === NodeKind.FunctionExpr);
		if (isSelfRefClosureInit) defineVar(_detectAllSS, d.declName);
		detectAllWalk(d.initializer);
		if (!isSelfRefClosureInit) defineVar(_detectAllSS, d.declName);
		return;
	}
	// Generic: recurse children via explicit dispatch (avoid deep mapChildren stack)
	if (node.kind === NodeKind.BlockStmt) {
		const d = node.data as BlockStmtData;
		for (const s of d.statements) detectAllWalk(s);
		return;
	}
	if (node.kind === NodeKind.ExprStmt) {
		detectAllWalk((node.data as ExprStmtData).expr);
		return;
	}
	if (node.kind === NodeKind.ReturnStmt) {
		detectAllWalk((node.data as ReturnStmtData).argument);
		return;
	}
	if (node.kind === NodeKind.IfStmt) {
		const d = node.data as IfStmtData;
		detectAllWalk(d.condition);
		detectAllWalk(d.consequent);
		detectAllWalk(d.alternate);
		return;
	}
	if (node.kind === NodeKind.WhileStmt) {
		const d = node.data as WhileStmtData;
		detectAllWalk(d.whileCondition);
		detectAllWalk(d.whileBody);
		return;
	}
	if (node.kind === NodeKind.DoWhileStmt) {
		const d = node.data as DoWhileStmtData;
		detectAllWalk(d.doBody);
		detectAllWalk(d.doCondition);
		return;
	}
	if (node.kind === NodeKind.TryCatchStmt) {
		const d = node.data as TryCatchStmtData;
		detectAllWalk(d.tryBody);
		if (d.catchName !== "") defineVar(_detectAllSS, d.catchName);
		detectAllWalk(d.catchBody);
		detectAllWalk(d.finallyBody);
		return;
	}
	if (node.kind === NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		detectAllWalk(d.left);
		detectAllWalk(d.right);
		return;
	}
	if (node.kind === NodeKind.UnaryExpr) {
		detectAllWalk((node.data as UnaryExprData).operand);
		return;
	}
	if (node.kind === NodeKind.CallExpr) {
		const d = node.data as CallExprData;
		detectAllWalk(d.callee);
		for (const a of d.arguments) detectAllWalk(a);
		return;
	}
	if (node.kind === NodeKind.SwitchStmt) {
		const d = node.data as SwitchStmtData;
		for (const c of d.switchCases) detectAllWalk(c);
		return;
	}
	if (node.kind === NodeKind.SwitchCase) {
		const d = node.data as SwitchCaseData;
		for (const s of d.caseStmts) detectAllWalk(s);
		return;
	}
	if (node.kind === NodeKind.ExportDecl) {
		detectAllWalk((node.data as ExportDeclData).exportedDecl);
		return;
	}
	// For remaining node kinds: use mapChildren as fallback
	mapChildren(node, (child: Node): Node => { detectAllWalk(child); return child; });
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
	detectPassWalk(program, state, createScopeStack(), null as unknown as Node);
	return state;
}

// Record a fn-like declaration's captures (FunctionDecl / MethodDecl /
// ConstructorDecl): build a fresh scope frame, run capture detection on the
// body, push results into the parallel arrays, then recurse into the body
// with this fn as the new enclosing fn.
function recordFnCaptures(node: Node, body: Node, params: string[], state: DetectionState, ss: ScopeStack): void {
	const fnSS = cloneScopeStack(ss);
	pushFuncBoundary(fnSS);
	for (const p of params) defineVar(fnSS, p);
	const result = detectAllCaptures(body, fnSS);
	state.fnNodes.push(node);
	state.fnCaptures.push(result.captures);
	state.fnCapturedIdents.push(result.capturedIdents);
	detectPassWalk(body, state, fnSS, node);
}

// Recursive walker. `enclosingFn` is the nearest containing FunctionDecl /
// MethodDecl / ConstructorDecl, or null at module scope.
function detectPassWalk(node: Node, state: DetectionState, ss: ScopeStack, enclosingFn: Node): void {
	if (node === null) return;
	if (node.kind === NodeKind.FunctionDecl) {
		const d = node.data as FunctionDeclData;
		recordFnCaptures(node, d.fnBody, d.params, state, ss);
		return;
	}
	if (node.kind === NodeKind.MethodDecl) {
		const d = node.data as MethodDeclData;
		recordFnCaptures(node, d.methodBody, d.methodParams, state, ss);
		return;
	}
	if (node.kind === NodeKind.ConstructorDecl) {
		const d = node.data as ConstructorDeclData;
		recordFnCaptures(node, d.ctorBody, d.ctorParams, state, ss);
		return;
	}
	if (node.kind === NodeKind.TestDecl) {
		const d = node.data as TestDeclData;
		recordFnCaptures(node, d.testBody, [], state, ss);
		return;
	}
	if (node.kind === NodeKind.ArrowFunction) {
		const d = node.data as ArrowFunctionData;
		// Arrows are env-owners too (Nim parity): each arrow that has captures
		// gets its own per-call env, so locals declared inside its body don't
		// share storage across multiple invocations of the same arrow. See
		// `detectAllCaptures`'s defined-at-or-above-initial filter for how each
		// boundary's captures are scoped.
		recordFnCaptures(node, d.arrowBody, d.arrowParams, state, ss);
		return;
	}
	if (node.kind === NodeKind.FunctionExpr) {
		const d = node.data as FunctionExprData;
		recordFnCaptures(node, d.funcExprBody, d.funcExprParams, state, ss);
		return;
	}
	if (node.kind === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		// Self-recursive closure binding: pre-define the name so the arrow/
		// funcExpr initializer's body sees the bound name as a capture
		// (e.g. `const fact = n => fact(n-1)`). For non-closure initializers
		// keep TDZ-style ordering so `const x = x + 1` still errors.
		const isSelfRefClosureInit = d.initializer !== null
			&& (d.initializer.kind === NodeKind.ArrowFunction
				|| d.initializer.kind === NodeKind.FunctionExpr);
		if (isSelfRefClosureInit) defineVar(ss, d.declName);
		detectPassWalk(d.initializer, state, ss, enclosingFn);
		if (!isSelfRefClosureInit) defineVar(ss, d.declName);
		return;
	}
	// Generic: recurse children, propagating enclosingFn.
	mapChildren(node, (child: Node): Node => { detectPassWalk(child, state, ss, enclosingFn); return child; });
}
