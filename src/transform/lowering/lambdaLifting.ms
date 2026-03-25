// Lambda Lifting — converts closures with captures into lifted functions + env structs
// Single-pass implementation: detect captures + rewrite in one top-down recursive walk
//
// function outer() {
//   let x = 10;
//   const f = () => x + 1;        // captures x
// }
//
// Becomes:
//   interface $Env_outer_1 { x: unknown; }
//   function $lifted_outer_1(_envP, ...) { return _envP.x + 1; }
//   function outer() {
//     let x = 10;
//     const f = { fn: $lifted_outer_1, env: { x: x } };
//   }

import { Node, NodeKind, DeclKind, SourceLocation, NodeFlag, SymbolKind, createNode, ProgramData, BlockStmtData, FunctionDeclData, ArrowFunctionData, FunctionExprData, MethodDeclData, ConstructorDeclData, ExportDeclData, ClassDeclData, DecoratedDeclData, VariableDeclData, IfStmtData, WhileStmtData, DoWhileStmtData, TryCatchStmtData, SwitchStmtData, SwitchCaseData, ExprStmtData, ReturnStmtData, BinaryExprData, CallExprData, UnaryExprData, IdentifierData, Type, TypeKind } from "../../ast/node";
import { TransformContext, NameSet, createNameSet, nameSetAdd, nameSetContains } from "../context";
import { mapChildren, isFuncBoundary } from "../walker";
import {
	makeIdent, makeMember, makeMoveExpr, makeReturn, makeBlock, makeVarDecl,
	makeFnDecl, makeInterfaceDeclFromTypes, makeObjectLiteral, makeHiddenDeref,
	makeNull, makeAssign, makeExprStmt, syntheticToken, resolveSimpleTypeStr,
} from "../util";
import { createPtr, createRef, unknownType } from "../../checker/types";
import { stmtCountAfter, firstStmtKindAfter, parseInput, getStmts } from "../testUtil";

// ===== Scope Stack =====
// Tracks variable declarations with function boundary awareness.

interface ScopeStack {
	names: string[];
	funcMarkers: number[];
}

function createScopeStack(): ScopeStack {
	const ss: ScopeStack = { names: [], funcMarkers: [] };
	return ss;
}

function pushFuncBoundary(ss: ScopeStack): void {
	ss.funcMarkers.push(ss.names.length);
}

function popFuncBoundary(ss: ScopeStack): void {
	const marker = ss.funcMarkers[ss.funcMarkers.length - 1];
	while (ss.names.length > marker) {
		ss.names.pop();
	}
	ss.funcMarkers.pop();
}

function defineVar(ss: ScopeStack, name: string): void {
	ss.names.push(name);
}

function isLocalVar(ss: ScopeStack, name: string): boolean {
	if (ss.funcMarkers.length === 0) return false;
	const funcStart = ss.funcMarkers[ss.funcMarkers.length - 1];
	for (let i = funcStart; i < ss.names.length; i += 1) {
		if (ss.names[i] === name) return true;
	}
	return false;
}

function isOuterVar(ss: ScopeStack, name: string): boolean {
	if (ss.funcMarkers.length === 0) return false;
	const funcStart = ss.funcMarkers[ss.funcMarkers.length - 1];
	for (let i = 0; i < funcStart; i += 1) {
		if (ss.names[i] === name) return true;
	}
	return false;
}

// Reference parity (interestingVar): module-level symbols are always accessible as C globals.
// They don't need capture — global symbols are excluded from capture analysis.
// A variable is module-level if defined before the first function boundary marker.
function isModuleLevelVar(ss: ScopeStack, name: string): boolean {
	if (ss.funcMarkers.length === 0) return true;
	const firstBoundary = ss.funcMarkers[0];
	let i = 0;
	while (i < firstBoundary) {
		if (ss.names[i] === name) return true;
		i += 1;
	}
	return false;
}

// Reference parity (up-field chains): classify capture as direct parent local vs grandparent+.
// Direct parent = defined in the scope immediately before the current closure boundary.
// Grandparent = defined in an ancestor scope further up. Needs Ptr-field (pointer to live value).
// Called AFTER tryLiftClosure pops the closure boundary — scope stack shows parent as last boundary.
function isDirectParentVar(ss: ScopeStack, name: string): boolean {
	if (ss.funcMarkers.length < 2) return true;
	const parentStart = ss.funcMarkers[ss.funcMarkers.length - 2];
	const myStart = ss.funcMarkers[ss.funcMarkers.length - 1];
	let i = parentStart;
	while (i < myStart) {
		if (ss.names[i] === name) return true;
		i += 1;
	}
	return false;
}

// ===== Built-in Names =====

function isBuiltinName(name: string): boolean {
	return match (name) {
		"console" | "Result" | "true" | "false" | "null" | "undefined" |
		"NaN" | "Infinity" | "Math" | "JSON" | "parseInt" | "parseFloat" |
		"String" | "Number" | "Boolean" | "Array" | "Object" | "Error" |
		"Promise" | "Map" | "Set" | "require" | "module" | "exports" |
		"globalThis" | "check" | "test" | "testGroup" => true,
		_ => false,
	};
}

// ===== Lift State =====
// Accumulated during the walk — env structs and lifted functions prepended to program.

interface VarTypeEntry {
	name: string;
	typeStr: string;
	resolvedType: Type;  // resolved Type for env struct field (fallback when captured ident has no nodeType)
}

// Reference parity: after a closure captures variables, ALL subsequent references
// in the outer function are rewritten to go through the env struct.
// PendingEnvRewrite tracks what needs rewriting after a closure is lifted.
interface PendingEnvRewrite {
	envVarName: string;         // e.g. "_env1"
	envStructType: Type;        // the env interface type
	capturedNames: NameSet;     // which variable names to rewrite
	envVarDecl: Node;           // the VarDecl node to insert before the closure
}

interface LiftState {
	liftedFunctions: Node[];
	envStructs: Node[];
	closureCounter: number;
	currentFnName: string;
	ss: ScopeStack;
	lastUseCaptures: NameSet;  // Phase F: captures that are last-use (can be moved)
	currentStmts: Node[];      // Phase F: current statement list (for last-use scan)
	currentStmtIdx: number;    // Phase F: current statement index in list
	insideLoop: number;        // >0 when inside a loop body (disables last-use move optimization)
	varTypes: VarTypeEntry[];  // Variable name → type string for env field typing
	capturedIdents: Node[];    // Parallel to captures NameSet: original Identifier nodes with resolvedSym
	currentParams: NameSet;    // Names of current function's params (for pointer-in-env detection)
	pendingEnvRewrites: PendingEnvRewrite[];  // Reference parity: outer-ref rewrites queued by liftClosure
	activeEnvRewrites: PendingEnvRewrite[];   // Currently active rewrites (applied to subsequent stmts)
	hoistedEnvDecls: Node[];  // Env VarDecls hoisted to function-level scope (reference parity)
	// Shared env per function (reference parity: ownerToType — one env for all closures)
	sharedEnvActive: boolean;           // whether shared env is in use for current function
	sharedEnvName: string;              // "$Env_fnName_shared"
	sharedEnvVarName: string;           // "_env_fnName_"
	sharedEnvStructType: Type;          // the shared env struct type
	sharedEnvCapturedNames: NameSet;    // union of ALL captured vars across all closures
	sharedEnvCapturedIdents: Node[];    // captured ident nodes from detection pre-pass
}

function registerVarType(state: LiftState, name: string, typeStr: string): void {
	state.varTypes.push({ name, typeStr, resolvedType: null as unknown as Type });
}

function registerVarTypeResolved(state: LiftState, name: string, typeStr: string, resolved: Type): void {
	state.varTypes.push({ name, typeStr, resolvedType: resolved });
}

function lookupVarResolvedType(state: LiftState, name: string): Type {
	let i = state.varTypes.length - 1;
	while (i >= 0) {
		if (state.varTypes[i].name === name && state.varTypes[i].resolvedType !== null) return state.varTypes[i].resolvedType;
		i -= 1;
	}
	return null as unknown as Type;
}

function lookupVarType(state: LiftState, name: string): string {
	let i = state.varTypes.length - 1;
	while (i >= 0) {
		if (state.varTypes[i].name === name) return state.varTypes[i].typeStr;
		i -= 1;
	}
	return "unknown";
}

// Override lifted function's param/return types from checker-resolved originalNodeType.
// Reference parity: the reference reuses original proc symbol (types already set). We create new node
// via makeFnDecl (string-based), then fix types from the original's concrete type.
function preserveResolvedTypes(fnNode: Node, originalNodeType: Type): void {
	if (originalNodeType === null || fnNode.nodeType === null || fnNode.nodeType.typeChildren === null) return;
	if (originalNodeType.typeChildren !== null) {
		const origCount = originalNodeType.typeChildren.length;
		for (let pi = 0; pi < origCount; pi += 1) {
			if (pi < fnNode.nodeType.typeChildren.length
				&& originalNodeType.typeChildren[pi].kind !== TypeKind.Unknown) {
				fnNode.nodeType.typeChildren[pi] = originalNodeType.typeChildren[pi];
			}
		}
	}
	if (originalNodeType.typeReturn !== null
		&& originalNodeType.typeReturn.kind !== TypeKind.Unknown) {
		fnNode.nodeType.typeReturn = originalNodeType.typeReturn;
	}
}

// Derive type string from resolved nodeType (Reference parity: use resolved symbol types for field typing)
// Used when string annotation is empty but checker has resolved the type.
function typeToEnvStr(t: Type): string {
	if (t === null) return "";
	return match (t.kind) {
		TypeKind.Number | TypeKind.Float64 => "number",
		TypeKind.String => "string",
		TypeKind.Boolean => "boolean",
		TypeKind.Void => "void",
		TypeKind.Int8 => "int8",
		TypeKind.Int16 => "int16",
		TypeKind.Int32 => "int32",
		TypeKind.Int64 => "int64",
		TypeKind.Uint8 => "uint8",
		TypeKind.Uint16 => "uint16",
		TypeKind.Uint32 => "uint32",
		TypeKind.Uint64 => "uint64",
		TypeKind.Float32 => "float32",
		TypeKind.Function => "msClosure",
		TypeKind.Struct | TypeKind.Enum => {
			if (t.typeName !== null && t.typeName !== "") {
				const name = t.typeName;
				return name;
			}
			return "";
		},
		TypeKind.Ref | TypeKind.Ptr => {
			if (t.typeReturn !== null) return typeToEnvStr(t.typeReturn);
			return "";
		},
		TypeKind.Array => {
			if (t.typeReturn !== null) {
				const elem = typeToEnvStr(t.typeReturn);
				if (elem !== "") { return elem + "[]"; } else { return "unknown[]"; }
			} else { return "unknown[]"; }
		},
		TypeKind.GenericInstance => t.typeName,
		_ => "",
	};
}

// Check if a type would be pointer-promoted by ccgIntroducedPtr in the C codegen.
// Mirrors the codegen check — Array, Union, Span are promoted to pointers as params.
// Mirrors ccgIntroducedPtr in codegen/types.ms — kept in sync manually
// (transform must not import codegen to avoid circular dependency).
function isCcgPtrType(t: Type): boolean {
	if (t === null) return false;
	return t.kind === TypeKind.Array || t.kind === TypeKind.Union || t.kind === TypeKind.Span;
}
// Note: ccgIntroducedPtr also promotes GenericInstance and large Tuples.
// Those are rare as captured params — add here if needed.

function createLiftState(): LiftState {
	const state: LiftState = {
		liftedFunctions: [],
		envStructs: [],
		closureCounter: 0,
		currentFnName: "anon",
		ss: createScopeStack(),
		lastUseCaptures: createNameSet(),
		currentStmts: [],
		currentStmtIdx: 0,
		insideLoop: 0,
		varTypes: [],
		capturedIdents: [],
		currentParams: createNameSet(),
		pendingEnvRewrites: [],
		activeEnvRewrites: [],
		hoistedEnvDecls: [],
		sharedEnvActive: false,
		sharedEnvName: "",
		sharedEnvVarName: "",
		sharedEnvStructType: null as unknown as Type,
		sharedEnvCapturedNames: createNameSet(),
		sharedEnvCapturedIdents: [],
	};
	return state;
}

// ===== Phase F: Last-Use Capture Detection =====
// Check if a variable name appears in any statement after index `afterIdx`.
// Used to determine if a capture can be moved instead of copied.

function nodeRefsName(node: Node, varName: string): boolean {
	if (node === null) return false;
	if (node.kind === NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		return d.name === varName;
	}
	if (isFuncBoundary(node)) return false;
	let found = false;
	mapChildren(node, (child: Node): Node => {
		if (!found && nodeRefsName(child, varName)) {
			found = true;
		}
		return child;
	});
	return found;
}

function isCaptureLastUse(varName: string, closureIdx: number, stmts: Node[]): boolean {
	let i = closureIdx + 1;
	while (i < stmts.length) {
		if (nodeRefsName(stmts[i], varName)) return false;
		i += 1;
	}
	return true;
}

function computeLastUseCaptures(captures: NameSet, closureIdx: number, stmts: Node[]): NameSet {
	const result: NameSet = createNameSet();
	for (const name of captures.items) {
		if (isCaptureLastUse(name, closureIdx, stmts)) {
			nameSetAdd(result, name);
		}
	}
	return result;
}

// Phase F + loop safety: inside a loop body, captures are NEVER last-use
// (loop back-edge repeats the capture). Outside loops, use forward scan.
function computeLastUseCapturesForState(captures: NameSet, state: LiftState): void {
	if (state.insideLoop > 0) {
		state.lastUseCaptures = createNameSet();
	} else {
		state.lastUseCaptures = computeLastUseCaptures(captures, state.currentStmtIdx, state.currentStmts);
	}
}

// ===== Detection Pre-Pass (reference parity: DetectionPass) =====
// Scans a function body to find ALL captures across ALL closures BEFORE lifting.
// Reference parity: DetectionPass + ownerToType creates one shared env type per function.
// Module-level state (no closure captures — binary-safe).

let _detectAllNames: NameSet = createNameSet();
let _detectAllSS: ScopeStack = { names: [], funcMarkers: [] };
let _detectAllIdents: Node[] = [];
let _detectClosureDepth: number = 0;  // >0 when inside a closure — only capture at depth > 0

function cloneScopeStack(ss: ScopeStack): ScopeStack {
	const names: string[] = [];
	for (const n of ss.names) names.push(n);
	const markers: number[] = [];
	for (const m of ss.funcMarkers) markers.push(m);
	return { names, funcMarkers: markers };
}

function detectAllCaptures(body: Node, ss: ScopeStack): NameSet {
	_detectAllNames = createNameSet();
	_detectAllIdents = [];
	_detectClosureDepth = 0;
	_detectAllSS = cloneScopeStack(ss);
	detectAllWalk(body);
	const result = _detectAllNames;
	_detectAllNames = createNameSet();
	return result;
}

function detectAllWalk(node: Node): void {
	if (node === null) return;
	if (node.kind === NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		// Only capture at closure depth > 0 (inside ArrowFunction/FunctionExpr).
		// Variables in the main function body are directly accessible — no capture needed.
		if (_detectClosureDepth > 0 && !isBuiltinName(d.name) && !isLocalVar(_detectAllSS, d.name) && isOuterVar(_detectAllSS, d.name) && !isModuleLevelVar(_detectAllSS, d.name)) {
			// Reference parity (interestingVar): only capture variables and params.
			// Skip types (Class, Interface, TypeAlias, Enum) — they're not runtime values.
			if (node.resolvedSym !== null) {
				const sk = node.resolvedSym.symbolKind;
				if (sk === SymbolKind.Class || sk === SymbolKind.Interface
					|| sk === SymbolKind.TypeAlias || sk === SymbolKind.Enum) {
					return;
				}
			}
			if (!nameSetContains(_detectAllNames, d.name)) {
				_detectAllIdents.push(node);
			}
			nameSetAdd(_detectAllNames, d.name);
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
		detectAllWalk(d.initializer);
		defineVar(_detectAllSS, d.declName);
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

// ===== Capture Detection =====
// Detect which outer variables a function body references.
// Walk the body recursively, collecting identifier names that are in outer scopes.
// Module-level state avoids closure capture of value-type arrays (use-after-free in C backend).

let _captureCC: NameSet = createNameSet();
let _captureIdents: Node[] = [];
let _captureSS: ScopeStack = { names: [], funcMarkers: [] };

function detectCaptures(body: Node, ss: ScopeStack, identNodes: Node[]): NameSet {
	_captureCC = createNameSet();
	_captureIdents = identNodes;
	_captureSS = ss;
	collectCaptures(body);
	const result = _captureCC;
	_captureCC = createNameSet();
	_captureIdents = [];
	return result;
}

function collectCaptures(node: Node): void {
	if (node === null) return;
	if (node.kind === NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		if (!isBuiltinName(d.name) && !isLocalVar(_captureSS, d.name) && isOuterVar(_captureSS, d.name) && !isModuleLevelVar(_captureSS, d.name)) {
			// Reference parity (interestingVar): skip types — not runtime values.
			if (node.resolvedSym !== null) {
				const sk = node.resolvedSym.symbolKind;
				if (sk === SymbolKind.Class || sk === SymbolKind.Interface
					|| sk === SymbolKind.TypeAlias || sk === SymbolKind.Enum) {
					return;
				}
			}
			if (!nameSetContains(_captureCC, d.name)) {
				_captureIdents.push(node);
			}
			nameSetAdd(_captureCC, d.name);
		}
		return;
	}
	if (isFuncBoundary(node)) return;
	if (node.kind === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		collectCaptures(d.initializer);
		defineVar(_captureSS, d.declName);
		return;
	}
	mapChildren(node, (child: Node): Node => { collectCaptures(child); return child; });
}

// Replace captured Identifier nodes with env field access.
// Inner (rewriteNode): captured vars → (*((EnvType*)_envP)).field (closure body)
// Outer (rewriteOuterRef): captured vars → _envN->field (outer function, post-closure)

// Check if an env struct field is a Ptr type (pointer-promoted param or grandparent capture).
function isEnvPtrField(envStructType: Type, fieldName: string): boolean {
	if (envStructType === null || envStructType.typeNames === null) return false;
	let i = 0;
	while (i < envStructType.typeNames.length) {
		if (envStructType.typeNames[i] === fieldName) {
			return i < envStructType.typeChildren.length
				&& envStructType.typeChildren[i] !== null
				&& envStructType.typeChildren[i].kind === TypeKind.Ptr;
		}
		i += 1;
	}
	return false;
}

function rewriteNode(node: Node, captures: NameSet, envTypeName: string, envStructType: Type): Node {
	if (node === null) return null;
	if (node.kind === NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		if (nameSetContains(captures, d.name)) {
			// Implementation parity: env param is void*, cast+deref to typed pointer for field access
			// Produces: (*((EnvType*)_envP)).field  in C
			const envIdent = makeIdent("_envP", node.location);
			const ptrType = createPtr(envStructType);
			const cast = createNode(NodeKind.TypeAssertion, { asExpr: envIdent, asType: envTypeName }, syntheticToken(node.location));
			cast.nodeType = ptrType;
			const deref = makeHiddenDeref(cast, node.location);
			let result = makeMember(deref, d.name, node.location);
			if (node.nodeType !== null) result.nodeType = node.nodeType;
			// Ptr field (pointer-promoted param capture): extra deref to get T from T*
			if (isEnvPtrField(envStructType, d.name)) {
				result = makeHiddenDeref(result, node.location);
				if (node.nodeType !== null) result.nodeType = node.nodeType;
			}
			return result;
		}
		return node;
	}
	if (isFuncBoundary(node)) return node;
	mapChildren(node, (child: Node): Node => rewriteNode(child, captures, envTypeName, envStructType));
	return node;
}

// ===== Outer Reference Rewrite (accessViaEnvVar parity) =====
// After a closure captures variables, ALL subsequent references to those variables
// in the outer function are rewritten to access through the named env variable.
// This ensures mutations inside closures are visible to the outer function and vice versa.

function rewriteOuterRef(node: Node, rewrite: PendingEnvRewrite): Node {
	if (node === null) return null;
	if (node.kind === NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		// Skip function captures — module-level functions are always accessible in C,
		// only local variables need outer-ref rewriting through the env.
		const isFnCapture = node.resolvedSym !== null && node.resolvedSym.symbolKind === SymbolKind.Function;
		if (!isFnCapture && nameSetContains(rewrite.capturedNames, d.name) && rewrite.envVarName !== "") {
			// Rewrite: x → _envN->field (env is Ref<Struct>, pointer in C)
			const envIdent = makeIdent(rewrite.envVarName, node.location);
			envIdent.nodeType = createRef(rewrite.envStructType);
			let result = makeMember(envIdent, d.name, node.location);
			if (node.nodeType !== null) result.nodeType = node.nodeType;
			// Ptr field (ccgIntroducedPtr capture): extra deref to get T from T*
			if (isEnvPtrField(rewrite.envStructType, d.name)) {
				result = makeHiddenDeref(result, node.location);
				if (node.nodeType !== null) result.nodeType = node.nodeType;
			}
			return result;
		}
		return node;
	}
	// Don't enter nested function bodies or already-lifted closure pairs
	if (isFuncBoundary(node)) return node;
	if ((node.flags & NodeFlag.Closure) !== 0) return node;
	mapChildren(node, (child: Node): Node => rewriteOuterRef(child, rewrite));
	return node;
}

function applyActiveRewrites(node: Node, rewrites: PendingEnvRewrite[]): Node {
	let result = node;
	let i = 0;
	while (i < rewrites.length) {
		result = rewriteOuterRef(result, rewrites[i]);
		i += 1;
	}
	return result;
}

// ===== Closure Lifting =====
// Create env struct + lifted function, return closure pair ObjectLiteral.

// Shared logic for lifting arrow functions and function expressions
// originalNodeType: resolved Type from checker (preserved through lifting)
function liftClosure(body: Node, params: string[], paramTypes: string[], flags: string, returnType: string, captures: NameSet, state: LiftState, loc: SourceLocation, originalNodeType: Type): Node {
	state.closureCounter += 1;
	const counter = state.closureCounter;
	const liftedName = "$lifted_" + state.currentFnName + "_" + counter.toString();

	let envName: string;
	let envVarName: string;
	let envStructType: Type;

	if (state.sharedEnvActive) {
		// Shared env path (reference parity: ownerToType — all closures share one env)
		envName = state.sharedEnvName;
		envVarName = state.sharedEnvVarName;
		envStructType = state.sharedEnvStructType;
	} else {
		// Per-closure env path (module-level closures, no shared env context)
		envName = "$Env_" + state.currentFnName + "_" + counter.toString();
		envVarName = "_env" + counter.toString() + "_";

		const envFields: string[] = [];
		const envFieldTypes: string[] = [];
		const envResolvedTypes: Type[] = [];
		for (const name of captures.items) {
			envFields.push(name);
			envFieldTypes.push(lookupVarType(state, name));
			const orig = findCapturedIdent(name, state.capturedIdents);
			if (orig !== null && orig.nodeType !== null) {
				let resolvedType = orig.nodeType;
				if (isCcgPtrType(resolvedType)) { resolvedType = createPtr(resolvedType); }
				// Up-field parity: grandparent captures stored as Ptr (pointer to ancestor env field)
				else if (!isDirectParentVar(state.ss, name) && !isModuleLevelVar(state.ss, name)) {
					resolvedType = createPtr(resolvedType);
				}
				envResolvedTypes.push(resolvedType);
			} else {
				const resolvedFallback = lookupVarResolvedType(state, name);
				if (resolvedFallback !== null) { envResolvedTypes.push(resolvedFallback); }
				else { envResolvedTypes.push(resolveSimpleTypeStr(lookupVarType(state, name))); }
			}
		}
		const envDecl = makeInterfaceDeclFromTypes(envName, envFields, envFieldTypes, envResolvedTypes, loc);
		envStructType = envDecl.nodeType;
		state.envStructs.push(envDecl);
	}

	// Rewrite closure body: captured vars → (*((EnvType*)_envP)).field
	// For shared env, rewrite ALL captured names (env has fields for all captures)
	const rewriteCaptures = state.sharedEnvActive ? state.sharedEnvCapturedNames : captures;
	let rewrittenBody = rewriteNode(body, rewriteCaptures, envName, envStructType);
	if (rewrittenBody.kind !== NodeKind.BlockStmt) {
		rewrittenBody = makeBlock([makeReturn(rewrittenBody, loc)], loc);
	}

	// Create lifted function
	const liftedParams: string[] = [];
	const liftedParamTypes: string[] = [];
	for (const p of params) { liftedParams.push(p); }
	for (const t of paramTypes) { liftedParamTypes.push(t); }
	liftedParams.push("_envP");
	liftedParamTypes.push("void*");
	const fnNode = makeFnDecl(liftedName, liftedParams, liftedParamTypes, rewrittenBody, flags, returnType, loc);
	preserveResolvedTypes(fnNode, originalNodeType);
	state.liftedFunctions.push(fnNode);

	if (state.sharedEnvActive) {
		// Shared env: env initialized at function entry, all-refs rewrite already active.
		// No pendingEnvRewrites needed — setupSharedEnv activated the rewrite.
		return makeClosurePairOnly(liftedName, envVarName, envStructType, loc);
	} else {
		// Per-closure env: each closure gets its own env declaration + init
		const envPair = makeEnvVarAndClosurePair(envVarName, liftedName, envStructType, captures, state.lastUseCaptures, state.capturedIdents, state.currentParams, state.ss, loc);
		state.hoistedEnvDecls.push(envPair.envDeclHoisted);
		state.pendingEnvRewrites.push({
			envVarName, envStructType,
			capturedNames: captures,
			envVarDecl: envPair.envInitStmt,
		});
		return envPair.closurePair;
	}
}

function liftArrow(node: Node, captures: NameSet, state: LiftState): Node {
	const d = node.data as ArrowFunctionData;
	return liftClosure(d.arrowBody, d.arrowParams, d.arrowParamTypes, d.arrowFlags, d.arrowReturnType, captures, state, node.location, node.nodeType);
}

function liftFuncExpr(node: Node, captures: NameSet, state: LiftState): Node {
	const d = node.data as FunctionExprData;
	return liftClosure(d.funcExprBody, d.funcExprParams, d.funcExprParamTypes, d.funcExprFlags, d.funcExprReturnType, captures, state, node.location, node.nodeType);
}

// Non-capturing lift: module-level FunctionDecl + closure pair with env=null.
// Reference parity: plain->closure conversion wraps fn ptr
// in { .ClP_0 = fn, .ClE_0 = NULL }. We emit the same via NF_CLOSURE ObjectLiteral.
// originalNodeType: resolved Type from checker (symbol type preserved)
function liftNonCapturing(body: Node, params: string[], paramTypes: string[], flags: string, returnType: string, state: LiftState, loc: SourceLocation, originalNodeType: Type): Node {
	state.closureCounter += 1;
	const liftedName = "$fn_" + state.currentFnName + "_" + state.closureCounter.toString();
	let liftedBody = body;
	if (liftedBody.kind !== NodeKind.BlockStmt) {
		liftedBody = makeBlock([makeReturn(liftedBody, loc)], loc);
	}
	const fnNode = makeFnDecl(liftedName, params, paramTypes, liftedBody, flags, returnType, loc);
	preserveResolvedTypes(fnNode, originalNodeType);
	state.liftedFunctions.push(fnNode);
	// Wrap in closure pair { fn: liftedName, env: null } so codegen emits
	// (msClosure){ .fn = (void*)ptr, .env = NULL } instead of raw function pointer.
	return wrapFnAsClosure(makeIdent(liftedName, loc), loc);
}

// Reference parity: look up original Identifier node for a captured name
// to preserve resolvedSym (needed for codegen name mangling).
function findCapturedIdent(name: string, capturedIdents: Node[]): Node {
	for (const n of capturedIdents) {
		const d = n.data as IdentifierData;
		if (d.name === name) return n;
	}
	return null as unknown as Node;
}

// Wrap a raw function Identifier in a closure pair { fn: ident, env: null }.
// Reference parity: plain->closure wraps fn ptr in { ClP_0, ClE_0=NULL }.
function wrapFnAsClosure(ident: Node, loc: SourceLocation): Node {
	const wrapKeys: string[] = [];
	wrapKeys.push("fn");
	wrapKeys.push("env");
	const wrapVals: Node[] = [];
	wrapVals.push(ident);
	wrapVals.push(makeNull(loc));
	const pair = makeObjectLiteral(wrapKeys, wrapVals, loc);
	pair.flags = pair.flags | NodeFlag.Closure;
	return pair;
}

// Reference parity: create env declaration (hoisted) + initialization (at closure site) + closure pair.
// Split into declaration and init so the variable is visible at function scope (setupEnvVar + genCreateEnv).
// envDeclHoisted: let _envN = null (at function body start — just declares the variable)
// envInitStmt: _envN = { field1: val1, ... } (at closure site — initializes the env)
// closurePair: { fn: liftedName, env: _envN }
function makeEnvVarAndClosurePair(envVarName: string, liftedName: string, envStructType: Type, captures: NameSet, lastUseCaptures: NameSet, capturedIdents: Node[], currentParams: NameSet, ss: ScopeStack, loc: SourceLocation): { envDeclHoisted: Node, envInitStmt: Node, closurePair: Node } {
	const envKeys: string[] = [];
	const envValues: Node[] = [];
	for (const name of captures.items) {
		envKeys.push(name);
		let ident = makeIdent(name, loc);
		const orig = findCapturedIdent(name, capturedIdents);
		if (orig !== null && orig.resolvedSym !== null) {
			ident.resolvedSym = orig.resolvedSym;
			ident.nodeType = orig.nodeType;
		}
		const isFnCapture = orig !== null && orig.resolvedSym !== null
			&& orig.resolvedSym.symbolKind === SymbolKind.Function;
		let envVal: Node = ident;
		if (isFnCapture) {
			envVal = wrapFnAsClosure(ident, loc);
		}
		// ccgIntroducedPtr captures (Array, Union, Span) store pointer via HiddenAddr.
		const isCcgCapture = orig !== null && orig.nodeType !== null && isCcgPtrType(orig.nodeType);
		if (isCcgCapture) {
			envVal = createNode(NodeKind.HiddenAddr, { expr: envVal }, syntheticToken(loc));
			if (orig.nodeType !== null) envVal.nodeType = createPtr(orig.nodeType);
		}
		// Up-field parity: grandparent captures store pointer to ancestor env field.
		// Takes address of the ancestor's env field (which was rewritten by parent's lifting).
		const isGrandparent = !isCcgCapture && !isFnCapture && !isDirectParentVar(ss, name) && !isModuleLevelVar(ss, name);
		if (isGrandparent) {
			envVal = createNode(NodeKind.HiddenAddr, { expr: envVal }, syntheticToken(loc));
			if (orig !== null && orig.nodeType !== null) envVal.nodeType = createPtr(orig.nodeType);
		}
		if (nameSetContains(lastUseCaptures, name)) {
			envValues.push(makeMoveExpr(envVal, loc));
		} else {
			envValues.push(envVal);
		}
	}
	// Env ObjectLiteral — Ref<Struct> so codegen heap-allocates via msAllocTyped
	const envObj = makeObjectLiteral(envKeys, envValues, loc);
	envObj.nodeType = createRef(envStructType);
	const refEnvType = createRef(envStructType);

	// Hoisted declaration: let _envN = null (visible at function scope)
	const nullInit = makeNull(loc);
	const envDeclHoisted = makeVarDecl(envVarName, nullInit, DeclKind.Let, loc);
	envDeclHoisted.nodeType = refEnvType;

	// Initialization at closure site: _envN = { field1: val1, ... }
	const envLhs = makeIdent(envVarName, loc);
	envLhs.nodeType = refEnvType;
	const envInitStmt = makeExprStmt(makeAssign(envLhs, envObj, loc), loc);

	// Closure pair: { fn: liftedName, env: _envN }
	const closureKeys: string[] = [];
	closureKeys.push("fn");
	closureKeys.push("env");
	const closureValues: Node[] = [];
	closureValues.push(makeIdent(liftedName, loc));
	const envRef = makeIdent(envVarName, loc);
	envRef.nodeType = refEnvType;
	closureValues.push(envRef);
	const pair = makeObjectLiteral(closureKeys, closureValues, loc);
	pair.flags = pair.flags | NodeFlag.Closure;
	return { envDeclHoisted, envInitStmt, closurePair: pair };
}

// ===== Shared Env Setup (reference parity: getEnvTypeForOwner + rawClosureCreation) =====
// Creates the shared env struct type and hoisted declaration for a function.
// Called after detectAllCaptures finds captures, before walkLiftBody.

function setupSharedEnv(state: LiftState, allCaptures: NameSet, loc: SourceLocation): void {
	state.sharedEnvActive = true;
	state.sharedEnvName = "$Env_" + state.currentFnName + "_shared";
	state.sharedEnvVarName = "_env_" + state.currentFnName + "_";
	state.sharedEnvCapturedNames = allCaptures;
	state.sharedEnvCapturedIdents = _detectAllIdents;

	// Build env struct fields from all captured vars
	const envFields: string[] = [];
	const envFieldTypes: string[] = [];
	const envResolvedTypes: Type[] = [];
	for (const name of allCaptures.items) {
		envFields.push(name);
		envFieldTypes.push(lookupVarType(state, name));
		const orig = findCapturedIdent(name, state.sharedEnvCapturedIdents);
		if (orig !== null && orig.nodeType !== null) {
			// Shared env: captured vars live IN the env as values (no ccgIntroducedPtr promotion).
			// Per-closure envs store POINTERS to locals; shared envs ARE the storage.
			envResolvedTypes.push(orig.nodeType);
		} else {
			const fallback = lookupVarResolvedType(state, name);
			if (fallback !== null) { envResolvedTypes.push(fallback); }
			else { envResolvedTypes.push(resolveSimpleTypeStr(lookupVarType(state, name))); }
		}
	}
	const envDecl = makeInterfaceDeclFromTypes(state.sharedEnvName, envFields, envFieldTypes, envResolvedTypes, loc);
	state.sharedEnvStructType = envDecl.nodeType;
	state.envStructs.push(envDecl);

	// Reference parity (rawClosureCreation): allocate env at function entry.
	// Use empty ObjectLiteral — codegen emits msAllocTyped with zeroed fields.
	// Params are copied into env fields via param-copy statements.
	// Local vars are written to env via all-refs rewrite (accessViaEnvVar).
	const emptyEnvObj = makeObjectLiteral([], [], loc);
	emptyEnvObj.nodeType = createRef(state.sharedEnvStructType);
	const refEnvType = createRef(state.sharedEnvStructType);
	const envDeclInit = makeVarDecl(state.sharedEnvVarName, emptyEnvObj, DeclKind.Let, loc);
	envDeclInit.nodeType = refEnvType;
	state.hoistedEnvDecls.push(envDeclInit);

	// Reference parity (rawClosureCreation line 617-627): copy available values into env fields.
	// Params and module-level vars/functions are available at function entry.
	// Local vars (declared later) are handled by VarDecl→assignment rewrite.
	for (const name of allCaptures.items) {
		const isParam = nameSetContains(state.currentParams, name);
		const isModLevel = isModuleLevelVar(state.ss, name);
		if (isParam || isModLevel) {
			const lhs = makeMember(makeIdent(state.sharedEnvVarName, loc), name, loc);
			const orig = findCapturedIdent(name, state.sharedEnvCapturedIdents);
			if (orig !== null && orig.nodeType !== null) lhs.nodeType = orig.nodeType;
			let rhs = makeIdent(name, loc);
			if (orig !== null && orig.resolvedSym !== null) {
				rhs.resolvedSym = orig.resolvedSym;
				rhs.nodeType = orig.nodeType;
			}
			// Module-level functions: wrap as msClosure { fn: func, env: null }
			const isFnCapture = orig !== null && orig.resolvedSym !== null
				&& orig.resolvedSym.symbolKind === SymbolKind.Function;
			if (isFnCapture) {
				rhs = wrapFnAsClosure(rhs, loc);
			}
			state.hoistedEnvDecls.push(makeExprStmt(makeAssign(
				lhs, rhs, loc
			), loc));
		}
	}

	// Reference parity (accessViaEnvVar): activate all-refs rewrite from function entry.
	// ALL references to captured vars in the function body go through the env.
	// Combined with VarDecl→assignment in walkLiftStmtList, this ensures mutations are shared.
	state.activeEnvRewrites.push({
		envVarName: state.sharedEnvVarName,
		envStructType: state.sharedEnvStructType,
		capturedNames: allCaptures,
		envVarDecl: null as unknown as Node,
	});
}

// Create closure pair referencing the shared env variable.
function makeClosurePairOnly(liftedName: string, envVarName: string, envStructType: Type, loc: SourceLocation): Node {
	const closureKeys: string[] = [];
	closureKeys.push("fn");
	closureKeys.push("env");
	const closureValues: Node[] = [];
	closureValues.push(makeIdent(liftedName, loc));
	const envRef = makeIdent(envVarName, loc);
	envRef.nodeType = createRef(envStructType);
	closureValues.push(envRef);
	const pair = makeObjectLiteral(closureKeys, closureValues, loc);
	pair.flags = pair.flags | NodeFlag.Closure;
	return pair;
}

// ===== Main Walk =====
// Single top-down recursive walk. When encountering a closure (ArrowFunction/FunctionExpr),
// detect captures and immediately lift if captures found.

// Reference parity: walk a statement list, inserting env VarDecls and rewriting
// outer references to captured variables after each closure is lifted.
// Drain new pending rewrites: hoist env VarDecls to function scope, activate for subsequent rewriting.
function drainPendingRewrites(state: LiftState, pendingBefore: number, result: Node[]): void {
	let pi = pendingBefore;
	while (pi < state.pendingEnvRewrites.length) {
		const rewrite = state.pendingEnvRewrites[pi];
		if (rewrite.envVarDecl !== null) {
			result.push(rewrite.envVarDecl);
		}
		state.activeEnvRewrites.push(rewrite);
		pi += 1;
	}
	// Truncate processed entries
	if (pendingBefore === 0) {
		state.pendingEnvRewrites = [];
	} else {
		const kept: PendingEnvRewrite[] = [];
		let ki = 0;
		while (ki < pendingBefore) { kept.push(state.pendingEnvRewrites[ki]); ki += 1; }
		state.pendingEnvRewrites = kept;
	}
}

function walkLiftStmtList(stmts: Node[], state: LiftState): Node[] {
	const result: Node[] = [];
	let si = 0;
	while (si < stmts.length) {
		state.currentStmtIdx = si;
		// Apply active rewrites BEFORE walk — rewriteOuterRef skips closure pairs
		// (NF_CLOSURE flag) and function bodies (isFuncBoundary), so capture detection
		// in subsequent closures isn't confused by rewritten refs.
		if (state.activeEnvRewrites.length > 0) {
			stmts[si] = applyActiveRewrites(stmts[si], state.activeEnvRewrites);
		}
		const pendingBefore = state.pendingEnvRewrites.length;
		walkLift(stmts[si], state);
		// Check if liftClosure queued new env rewrites
		if (state.pendingEnvRewrites.length > pendingBefore) {
			drainPendingRewrites(state, pendingBefore, result);
		}
		// Reference parity (accessViaEnvVar): replace captured VarDecl with env field assignment.
		// Create a NEW node instead of mutating in-place (C union layout forbids kind change).
		// walkLift already processed the initializer; we just replace the stmt in the list.
		if (state.sharedEnvActive && stmts[si].kind === NodeKind.VariableDecl) {
			const vd = stmts[si].data as VariableDeclData;
			if (nameSetContains(state.sharedEnvCapturedNames, vd.declName)) {
				const envIdent = makeIdent(state.sharedEnvVarName, stmts[si].location);
				envIdent.nodeType = createRef(state.sharedEnvStructType);
				const lhs = makeMember(envIdent, vd.declName, stmts[si].location);
				if (stmts[si].nodeType !== null) lhs.nodeType = stmts[si].nodeType;
				const init = (vd.initializer !== null) ? vd.initializer : makeNull(stmts[si].location);
				stmts[si] = makeExprStmt(makeAssign(lhs, init, stmts[si].location), stmts[si].location);
			}
		}
		result.push(stmts[si]);
		si += 1;
	}
	return result;
}

function walkLift(node: Node, state: LiftState): void {
	match (node.kind) {
		NodeKind.Program => {
			const d = node.data as ProgramData;
			const savedStmts = state.currentStmts;
			const savedIdx = state.currentStmtIdx;
			const savedHoisted = state.hoistedEnvDecls;
			state.currentStmts = d.programStmts;
			state.hoistedEnvDecls = [];
			d.programStmts = walkLiftStmtList(d.programStmts, state);
			d.programStmts = prependHoistedEnvDecls(state.hoistedEnvDecls, d.programStmts);
			state.hoistedEnvDecls = savedHoisted;
			state.currentStmts = savedStmts;
			state.currentStmtIdx = savedIdx;
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			const savedStmts = state.currentStmts;
			const savedIdx = state.currentStmtIdx;
			state.currentStmts = d.statements;
			d.statements = walkLiftStmtList(d.statements, state);
			state.currentStmts = savedStmts;
			state.currentStmtIdx = savedIdx;
		},
		NodeKind.FunctionDecl => {
			const d = node.data as FunctionDeclData;
			const savedName = state.currentFnName;
			if (d.fnName !== "") {
				state.currentFnName = d.fnName;
				defineVar(state.ss, d.fnName);
				// Reference parity: captured function refs → closure type
				registerVarType(state, d.fnName, "msClosure");
			}
			// Push function boundary, define params + register types for env field resolution
			// Prefer resolved types from nodeType (handles type aliases like NumFn → Function)
			pushFuncBoundary(state.ss);
			const savedParams = state.currentParams;
			const savedActiveRewrites = state.activeEnvRewrites;
			state.currentParams = createNameSet();
			state.activeEnvRewrites = [];
			const fnType = node.nodeType;
			let pi = 0;
			while (pi < d.params.length) {
				defineVar(state.ss, d.params[pi]);
				nameSetAdd(state.currentParams, d.params[pi]);
				let paramTypeStr = (pi < d.fnParamTypes.length) ? d.fnParamTypes[pi] : "";
				// Reference parity: use resolved type from checker for env field typing
				if (fnType !== null && fnType.typeChildren !== null && pi < fnType.typeChildren.length) {
					const pt = fnType.typeChildren[pi];
					if (pt !== null) {
						const derived = typeToEnvStr(pt);
						if (derived !== "") {
							paramTypeStr = derived;
						}
					}
				}
				if (paramTypeStr !== "") {
					registerVarType(state, d.params[pi], paramTypeStr);
				}
				pi += 1;
			}
			const savedShared = saveSharedEnv(state);

			// Detection pre-pass: find ALL captures across ALL closures in this function
			// Reference parity: DetectionPass runs before LiftingPass
			const allCaptures = detectAllCaptures(d.fnBody, state.ss);

			// Inline walkLiftBody: save/clear hoisted FIRST, then setup shared env
			// so the shared env hoisted decl lands in the function body, not outer scope
			const savedHoisted = state.hoistedEnvDecls;
			state.hoistedEnvDecls = [];
			if (allCaptures.items.length > 0) {
				setupSharedEnv(state, allCaptures, node.location);
			}
			walkLift(d.fnBody, state);
			if (state.hoistedEnvDecls.length > 0 && d.fnBody !== null && d.fnBody.kind === NodeKind.BlockStmt) {
				const bd = d.fnBody.data as BlockStmtData;
				bd.statements = prependHoistedEnvDecls(state.hoistedEnvDecls, bd.statements);
			}
			state.hoistedEnvDecls = savedHoisted;
			popFuncBoundary(state.ss);
			state.currentParams = savedParams;
			state.activeEnvRewrites = savedActiveRewrites;
			restoreSharedEnv(state, savedShared);
			state.currentFnName = savedName;
		},
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			d.initializer = walkOrLift(d.initializer, state);
			defineVar(state.ss, d.declName);
			if (d.declType !== "") {
				registerVarType(state, d.declName, d.declType);
			} else if (node.nodeType !== null) {
				// Reference parity: use resolved type from checker when no annotation
				const derived = typeToEnvStr(node.nodeType);
				if (derived !== "") {
					registerVarTypeResolved(state, d.declName, derived, node.nodeType);
				}
			}
		},
		NodeKind.ExprStmt => {
			const d = node.data as ExprStmtData;
			d.expr = walkOrLift(d.expr, state);
		},
		NodeKind.ReturnStmt => {
			const d = node.data as ReturnStmtData;
			d.argument = walkOrLift(d.argument, state);
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			d.condition = walkOrLift(d.condition, state);
			walkLift(d.consequent, state);
			walkLift(d.alternate, state);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			d.whileCondition = walkOrLift(d.whileCondition, state);
			state.insideLoop += 1;
			walkLift(d.whileBody, state);
			state.insideLoop -= 1;
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			state.insideLoop += 1;
			walkLift(d.doBody, state);
			state.insideLoop -= 1;
			d.doCondition = walkOrLift(d.doCondition, state);
		},
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			walkLift(d.tryBody, state);
			if (d.catchName !== "") {
				defineVar(state.ss, d.catchName);
			}
			walkLift(d.catchBody, state);
			walkLift(d.finallyBody, state);
		},
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			for (const c of d.switchCases) {
				walkLift(c, state);
			}
		},
		NodeKind.SwitchCase => {
			const d = node.data as SwitchCaseData;
			for (const s of d.caseStmts) {
				walkLift(s, state);
			}
		},
		NodeKind.ExportDecl => {
			const d = node.data as ExportDeclData;
			walkLift(d.exportedDecl, state);
		},
		NodeKind.ClassDecl => {
			const d = node.data as ClassDeclData;
			if (d.className !== "") {
				defineVar(state.ss, d.className);
			}
			for (const member of d.classBody) {
				walkLift(member, state);
			}
		},
		NodeKind.MethodDecl => {
			const d = node.data as MethodDeclData;
			pushFuncBoundary(state.ss);
			for (const p of d.methodParams) { defineVar(state.ss, p); }
			walkLiftBody(d.methodBody, state);
			popFuncBoundary(state.ss);
		},
		NodeKind.ConstructorDecl => {
			const d = node.data as ConstructorDeclData;
			pushFuncBoundary(state.ss);
			for (const p of d.ctorParams) { defineVar(state.ss, p); }
			walkLiftBody(d.ctorBody, state);
			popFuncBoundary(state.ss);
		},
		NodeKind.DecoratedDecl => {
			const d = node.data as DecoratedDeclData;
			walkLift(d.decoratedNode, state);
		},
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			walkLift(d.callee, state);
			let i = 0;
			while (i < d.arguments.length) {
				const arg = d.arguments[i];
				if (arg.kind === NodeKind.ArrowFunction || arg.kind === NodeKind.FunctionExpr) {
					const lifted = tryLiftClosure(arg, state);
					if (lifted.kind !== arg.kind) {
						d.arguments[i] = lifted;
					}
				} else {
					walkLift(arg, state);
				}
				i += 1;
			}
		},
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			d.right = walkOrLift(d.right, state);
			walkLift(d.left, state);
		},
		NodeKind.UnaryExpr => {
			const d = node.data as UnaryExprData;
			d.operand = walkOrLift(d.operand, state);
		},
		_ => {},
	};
}

// Prepend hoisted env declarations to a statement array ( setupEnvVar at function entry).
function prependHoistedEnvDecls(hoisted: Node[], stmts: Node[]): Node[] {
	if (hoisted.length === 0) return stmts;
	const newStmts: Node[] = [];
	let hi = 0;
	while (hi < hoisted.length) { newStmts.push(hoisted[hi]); hi += 1; }
	let si = 0;
	while (si < stmts.length) { newStmts.push(stmts[si]); si += 1; }
	return newStmts;
}

function walkLiftBody(body: Node, state: LiftState): void {
	const savedHoisted = state.hoistedEnvDecls;
	state.hoistedEnvDecls = [];
	walkLift(body, state);
	if (state.hoistedEnvDecls.length > 0 && body !== null && body.kind === NodeKind.BlockStmt) {
		const bd = body.data as BlockStmtData;
		bd.statements = prependHoistedEnvDecls(state.hoistedEnvDecls, bd.statements);
	}
	state.hoistedEnvDecls = savedHoisted;
}

// Walk a node, lifting closures if it's an ArrowFunction/FunctionExpr with captures.
// Returns the (possibly replaced) node.
function walkOrLift(node: Node, state: LiftState): Node {
	if (node === null) return null as unknown as Node;
	if (node.kind === NodeKind.ArrowFunction || node.kind === NodeKind.FunctionExpr) {
		return tryLiftClosure(node, state);
	}
	walkLift(node, state);
	return node;
}

// Shared env state snapshot — saved/restored when entering closure bodies.
interface SharedEnvSnapshot {
	active: boolean;
	name: string;
	varName: string;
	structType: Type;
	capturedNames: NameSet;
	capturedIdents: Node[];
}

function saveSharedEnv(state: LiftState): SharedEnvSnapshot {
	const snap: SharedEnvSnapshot = {
		active: state.sharedEnvActive,
		name: state.sharedEnvName,
		varName: state.sharedEnvVarName,
		structType: state.sharedEnvStructType,
		capturedNames: state.sharedEnvCapturedNames,
		capturedIdents: state.sharedEnvCapturedIdents,
	};
	state.sharedEnvActive = false;
	return snap;
}

function restoreSharedEnv(state: LiftState, snap: SharedEnvSnapshot): void {
	state.sharedEnvActive = snap.active;
	state.sharedEnvName = snap.name;
	state.sharedEnvVarName = snap.varName;
	state.sharedEnvStructType = snap.structType;
	state.sharedEnvCapturedNames = snap.capturedNames;
	state.sharedEnvCapturedIdents = snap.capturedIdents;
}

// Try to lift a closure. Returns the original node if no captures, or a closure pair if lifted.
function tryLiftClosure(node: Node, state: LiftState): Node {
	// Save+clear scope state: closure body is a new scope.
	pushFuncBoundary(state.ss);
	const savedActiveRewrites = state.activeEnvRewrites;
	state.activeEnvRewrites = [];
	const savedShared = saveSharedEnv(state);

	if (node.kind === NodeKind.ArrowFunction) {
		const d = node.data as ArrowFunctionData;
		for (const p of d.arrowParams) { defineVar(state.ss, p); }
		walkLiftBody(d.arrowBody, state);
		state.capturedIdents = [];
		const captures = detectCaptures(d.arrowBody, state.ss, state.capturedIdents);
		popFuncBoundary(state.ss);
		state.activeEnvRewrites = savedActiveRewrites;
		restoreSharedEnv(state, savedShared);
		if (captures.items.length > 0) {
			computeLastUseCapturesForState(captures, state);
			return liftArrow(node, captures, state);
		}
		return liftNonCapturing(d.arrowBody, d.arrowParams, d.arrowParamTypes, d.arrowFlags, d.arrowReturnType, state, node.location, node.nodeType);
	} else if (node.kind === NodeKind.FunctionExpr) {
		const d = node.data as FunctionExprData;
		for (const p of d.funcExprParams) { defineVar(state.ss, p); }
		walkLiftBody(d.funcExprBody, state);
		state.capturedIdents = [];
		const captures = detectCaptures(d.funcExprBody, state.ss, state.capturedIdents);
		popFuncBoundary(state.ss);
		state.activeEnvRewrites = savedActiveRewrites;
		restoreSharedEnv(state, savedShared);
		if (captures.items.length > 0) {
			computeLastUseCapturesForState(captures, state);
			return liftFuncExpr(node, captures, state);
		}
		return liftNonCapturing(d.funcExprBody, d.funcExprParams, d.funcExprParamTypes, d.funcExprFlags, d.funcExprReturnType, state, node.location, node.nodeType);
	} else {
		popFuncBoundary(state.ss);
		state.activeEnvRewrites = savedActiveRewrites;
		restoreSharedEnv(state, savedShared);
	}
	return node;
}

// ===== Main Entry Point =====

export function lowerLambda(program: Node, ctx: TransformContext): Node {
	const state = createLiftState();
	walkLift(program, state);

	// Prepend env structs + lifted functions to program
	if (state.envStructs.length === 0 && state.liftedFunctions.length === 0) {
		return program;
	}

	if (program.kind === NodeKind.Program) {
		const d = program.data as ProgramData;
		const newStmts: Node[] = [];
		for (const s of state.envStructs) {
			newStmts.push(s);
		}
		for (const f of state.liftedFunctions) {
			newStmts.push(f);
		}
		for (const s of d.programStmts) {
			newStmts.push(s);
		}
		program.data = { programStmts: newStmts };
	}

	return program;
}

// ===== Tests =====
test "no closures passthrough" { assert stmtCountAfter("const x = 1;", lowerLambda) === 1; }

test "function without capture unchanged" { assert firstStmtKindAfter("function foo(x) { return x; }", lowerLambda) === NodeKind.FunctionDecl; }

test "non-capturing arrow lifted" {
	// Arrow lifted to module-level FunctionDecl + original VariableDecl = 2 stmts
	assert stmtCountAfter("const f = (x) => x + 1;", lowerLambda) === 2;
	assert firstStmtKindAfter("const f = (x) => x + 1;", lowerLambda) === NodeKind.FunctionDecl;
}

test "non-capturing arrow in function lifted" {
	// Inner arrow lifted to program level: lifted fn + outer fn = 2 stmts
	assert stmtCountAfter("function f(x) { const g = (y) => y + 1; }", lowerLambda) === 2;
}

test "arrow with capture generates 3 stmts" {
	// function outer() { let x = 1; const f = () => x; }
	// → env struct + lifted fn + original fn = 3 stmts
	assert stmtCountAfter("function outer() { let x = 1; const f = () => x; }", lowerLambda) === 3;
}

test "env struct is first stmt" { assert firstStmtKindAfter("function outer() { let x = 1; const f = () => x; }", lowerLambda) === NodeKind.InterfaceDecl; }

test "builtin name not captured" {
	// Arrow referencing builtin is non-capturing, but still lifted: lifted fn + outer fn = 2
	assert stmtCountAfter("function f() { const g = () => console; }", lowerLambda) === 2;
}

test "multiple captures one env" { assert stmtCountAfter("function f() { let a = 1; let b = 2; const g = () => a + b; }", lowerLambda) === 3; }

test "non-capturing function expr lifted" {
	assert stmtCountAfter("const f = function(x) { return x + 1; };", lowerLambda) === 2;
	assert firstStmtKindAfter("const f = function(x) { return x + 1; };", lowerLambda) === NodeKind.FunctionDecl;
}

test "isCaptureLastUse: var not used after closure" {
	// Simulate: [let x = 1, const f = () => x]  — x not used after index 1
	const result = parseInput("function f() { let x = 1; const g = () => x; }");
	if (result.ok) {
		const stmts = getStmts(result.value);
		// In function body
		const fd = stmts[0].data as FunctionDeclData;
		const bd = fd.fnBody.data as BlockStmtData;
		// x captured at index 1, not used at index 2+ (no stmts after)
		assert isCaptureLastUse("x", 1, bd.statements);
	}
}

test "isCaptureLastUse: var used after closure" {
	const result = parseInput("function f() { let x = 1; const g = () => x; return x; }");
	if (result.ok) {
		const stmts = getStmts(result.value);
		const fd = stmts[0].data as FunctionDeclData;
		const bd = fd.fnBody.data as BlockStmtData;
		// x captured at index 1, but used in return at index 2
		assert !isCaptureLastUse("x", 1, bd.statements);
	}
}
