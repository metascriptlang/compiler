// Lambda Lifting — converts closures with captures into lifted functions + env
// structs. Two-pass design (Nim parity, see `compiler/lambdalifting.nim`):
//
//   Pass 1 — `detectPass` (in `lambdaLiftingDetect.ms`): walks the whole
//            program once, records per-FunctionDecl/Method/Ctor the union of
//            all captures from nested closures.
//   Pass 2 — `walkLift` (this file): rewrites + lifts, consuming Pass 1
//            results. Captures are accessed via either a per-fn shared env
//            or the `$up` chain walk for grandparent captures.
//
// function outer() {
//   let x = 10;
//   const f = () => x + 1;        // captures x
// }
//
// Becomes:
//   interface $Env_outer_1 { $up: unknown; x: unknown; }
//   function $lifted_outer_1(_envP, ...) { return _envP.x + 1; }
//   function outer() {
//     let x = 10;
//     const f = { fn: $lifted_outer_1, env: { x: x } };
//   }

import { Node, NodeKind, DeclKind, SourceLocation, NodeFlag, SymbolKind, Symbol, createNode, ProgramData, BlockStmtData, FunctionDeclData, ArrowFunctionData, FunctionExprData, MethodDeclData, ConstructorDeclData, ExportDeclData, ClassDeclData, DecoratedDeclData, VariableDeclData, IfStmtData, WhileStmtData, DoWhileStmtData, TryCatchStmtData, SwitchStmtData, SwitchCaseData, ExprStmtData, ReturnStmtData, BinaryExprData, CallExprData, UnaryExprData, IdentifierData, ObjectLiteralData, ArrayLiteralData, TestDeclData, Type, TypeKind } from "../../ast/node";
import { TransformContext, NameSet, createNameSet, nameSetAdd, nameSetContains } from "../context";
import { mapChildren, isFuncBoundary } from "../walker";
import {
	makeIdent, makeMember, makeMoveExpr, makeReturn, makeBlock, makeVarDecl,
	makeFnDecl, makeInterfaceDeclFromTypes, makeObjectLiteral, makeHiddenDeref,
	makeNull, makeAssign, makeExprStmt, syntheticToken, resolveSimpleTypeStr,
} from "../util";
import { createPtr, createRef, voidType, isUnresolvedType } from "../../checker/types";
import { hasFlag, SymbolFlag } from "../../checker/symbol";
import { stmtCountAfter, firstStmtKindAfter, parseInput, getStmts, makeCtx } from "../testUtil";
import {
	DetectionState, createDetectionState, detectPass,
	detectionGetCaptures, detectionGetCapturedIdents,
} from "./lambdaLiftingDetect";
import {
	ScopeStack, createScopeStack, pushFuncBoundary, popFuncBoundary,
	defineVar, isLocalVar, isOuterVar, isModuleLevelVar, isDirectParentVar,
	isBuiltinName,
} from "./lambdaLiftingScope";

// Synthetic env field — pointer to the lexical parent env. Each per-closure env
// gets one of these wired to its enclosing function's env (see Nim's `:up`,
// lambdalifting.nim:125). The `$` prefix marks it as a synthetic name unlikely
// to collide with user identifiers.
const UP_FIELD: string = "$up";

// The hidden env-pointer parameter name on every lifted function. The C ABI
// for closure calls passes the env as the LAST argument (or only argument for
// nullary closures). Kept as a constant to avoid magic-string drift; analyzer
// (`src/analyzer/inject.ms:isEnvParam`) recognizes the same prefix.
const ENV_PARAM_NAME: string = "_envP";

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
	chainNames: string[];       // ancestor env names ($up walk when a ref isn't a field here)
	chainTypes: Type[];         // parallel ancestor env struct types
	envVarDecl: Node;           // the VarDecl node to insert before the closure
	// Snapshot envs (created inside a loop for an escaping closure) only emit
	// their init statement; they do NOT activate an outer-ref rewrite, because
	// code in the outer function must continue to read/write the shared env,
	// not the per-closure snapshot. Default false = classic behavior.
	snapshotOnly: boolean;
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
	sharedEnvChainNames: string[];      // enclosing shared-env names, immediate-parent first ($up walk)
	sharedEnvChainTypes: Type[];        // parallel: enclosing shared-env struct types
	// Pass 1 result: pre-computed per-FunctionDecl captures (consumed by lift's
	// FunctionDecl path instead of running detection inline).
	detection: DetectionState;
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
				&& !isUnresolvedType(originalNodeType.typeChildren[pi])) {
				fnNode.nodeType.typeChildren[pi] = originalNodeType.typeChildren[pi];
			}
		}
	}
	if (originalNodeType.typeReturn !== null
		&& !isUnresolvedType(originalNodeType.typeReturn)) {
		fnNode.nodeType.typeReturn = originalNodeType.typeReturn;
	}
}

// Derive type string from resolved nodeType (Reference parity: use resolved symbol types for field typing)
// Used when string annotation is empty but checker has resolved the type.
function typeToEnvStr(t: Type | null): string {
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
		sharedEnvChainNames: [],
		sharedEnvChainTypes: [],
		detection: createDetectionState(),
	};
	return state;
}

// Lift-state context discriminator. `tryLiftClosure` invokes `saveSharedEnv`
// on entry, which flips `sharedEnvActive` to false but keeps the enclosing
// fn's `sharedEnvName/VarName/StructType` intact. So:
//   - sharedEnvActive=true  → emitting in fn body (named hoisted var in scope)
//   - sharedEnvActive=false && sharedEnvName!="" → in nested-arrow body
//     (the enclosing fn's env arrived as `_envP`)
//   - sharedEnvName=""      → no enclosing fn (module level)
//
// `currentEnvAccessName` returns the right C identifier to read the enclosing
// fn's env from wherever the emitted code lands.
function inEnclosingFnBody(state: LiftState): boolean {
	return state.sharedEnvActive;
}

function hasEnclosingFnEnv(state: LiftState): boolean {
	return state.sharedEnvName !== "";
}

function currentEnvAccessName(state: LiftState): string {
	if (state.sharedEnvActive) return state.sharedEnvVarName;
	if (state.sharedEnvName !== "") return ENV_PARAM_NAME;
	return "";
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

// Loop safety: captures inside a loop body are never last-use (back-edge
// repeats them).
// Shared-env safety: captures stored in an enclosing function's shared env
// outlive any single invocation of this closure — moving from them nulls the
// field for the next call. sharedActive is unreliable here (deactivated on
// descent into nested closures); sharedEnvCapturedNames stays populated.
function computeLastUseCapturesForState(captures: NameSet, state: LiftState): void {
	if (state.insideLoop > 0) {
		state.lastUseCaptures = createNameSet();
		return;
	}
	const candidates = computeLastUseCaptures(captures, state.currentStmtIdx, state.currentStmts);
	if (state.sharedEnvCapturedNames.items.length === 0) {
		state.lastUseCaptures = candidates;
		return;
	}
	const filtered: NameSet = createNameSet();
	for (const name of candidates.items) {
		if (!nameSetContains(state.sharedEnvCapturedNames, name)) {
			nameSetAdd(filtered, name);
		}
	}
	state.lastUseCaptures = filtered;
}

// ===== Detection Pre-Pass (reference parity: DetectionPass) =====
// Scans a function body to find ALL captures across ALL closures BEFORE lifting.
// Reference parity: DetectionPass + ownerToType creates one shared env type per function.
// Pre-register VarDecl types from a function body so setupSharedEnv can resolve env field types.
// Without this, captured vars from async transforms lack nodeType → env fields become void*.
function preRegisterVarTypes(body: Node, state: LiftState): void {
	if (body === null) return;
	if (body.kind === NodeKind.VariableDecl) {
		const d = body.data as VariableDeclData;
		if (d.declType !== "") {
			registerVarType(state, d.declName, d.declType);
		} else if (body.nodeType !== null) {
			const derived = typeToEnvStr(body.nodeType);
			if (derived !== "") {
				registerVarTypeResolved(state, d.declName, derived, body.nodeType);
			}
		}
		return;
	}
	if (body.kind === NodeKind.FunctionDecl || body.kind === NodeKind.ArrowFunction || body.kind === NodeKind.FunctionExpr) return;
	if (body.kind === NodeKind.BlockStmt) {
		const d = body.data as BlockStmtData;
		for (const s of d.statements) preRegisterVarTypes(s, state);
		return;
	}
	if (body.kind === NodeKind.IfStmt) {
		const d = body.data as IfStmtData;
		preRegisterVarTypes(d.consequent, state);
		preRegisterVarTypes(d.alternate, state);
		return;
	}
	if (body.kind === NodeKind.WhileStmt) {
		preRegisterVarTypes((body.data as WhileStmtData).whileBody, state);
		return;
	}
}

// Detection logic lives in `lambdaLiftingDetect.ms` (Pass 1).

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
		if (!isBuiltinName(d.name) && !isLocalVar(_captureSS, d.name) && isOuterVar(_captureSS, d.name)) {
			// Reference parity (interestingVar): skip types — not runtime values.
			if (node.resolvedSym !== null) {
				const sk = node.resolvedSym.symbolKind;
				if (sk === SymbolKind.Class || sk === SymbolKind.Interface
					|| sk === SymbolKind.TypeAlias || sk === SymbolKind.Enum) {
					return;
				}
			}
			const sym = node.resolvedSym;
			const isModLevel = (sym !== null && (sym.symbolKind === SymbolKind.Variable || sym.symbolKind === SymbolKind.Parameter))
				? hasFlag(sym, SymbolFlag.Global)
				: isModuleLevelVar(_captureSS, d.name);
			if (!isModLevel) {
				if (!nameSetContains(_captureCC, d.name)) {
					_captureIdents.push(node);
				}
				nameSetAdd(_captureCC, d.name);
			}
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
			if (i >= envStructType.typeChildren.length) return false;
			const ft = envStructType.typeChildren[i];
			if (ft === null || ft.kind !== TypeKind.Ptr) return false;
			// Only match ccgIntroducedPtr captures (Array, Union, Span stored as Ptr<T>).
			// Regular Ptr-typed variables (void*, msAwaitGroup*, etc.) should NOT get extra deref.
			const inner = ft.typeReturn;
			return inner !== null && (inner.kind === TypeKind.Array || inner.kind === TypeKind.Union || inner.kind === TypeKind.Span);
		}
		i += 1;
	}
	return false;
}

// Whether a struct/interface type has a field with the given name. Used by
// chain walk to decide whether a capture lives in the current env or further
// up the `$up` chain.
function envHasField(envStructType: Type, fieldName: string): boolean {
	if (envStructType === null || envStructType.typeNames === null) return false;
	let i = 0;
	while (i < envStructType.typeNames.length) {
		if (envStructType.typeNames[i] === fieldName) return true;
		i += 1;
	}
	return false;
}

// Declared type of an env struct field by name. A lifted member access derives its
// type from the env field (the type authority), not from the captured identifier —
// which may itself be untyped (e.g. destructuring/async-synthesized captures). Leaving
// the lifted member untyped makes the DRC save-temp fall back to C `double`.
function envFieldType(envStructType: Type, fieldName: string): Type {
	if (envStructType === null || envStructType.typeNames === null || envStructType.typeChildren === null) return null as unknown as Type;
	for (let i = 0; i < envStructType.typeNames.length; i += 1) {
		if (envStructType.typeNames[i] === fieldName && i < envStructType.typeChildren.length) {
			return envStructType.typeChildren[i];
		}
	}
	return null as unknown as Type;
}

// Index of the ancestor env in the chain that stores `fieldName`, or -1.
function chainIndexOf(chainTypes: Type[], fieldName: string): number {
	let i = 0;
	while (i < chainTypes.length) {
		if (envHasField(chainTypes[i], fieldName)) return i;
		i += 1;
	}
	return -1;
}

// Walk `$up` from a base env-struct access up the ancestor chain to the env that
// stores `fieldName` (chainTypes[targetIdx]) — Nim accessViaEnvParam, lambdalifting.nim:529.
// `access0` is the starting env-struct value: `(*((Cur*)_envP))` for a lifted body
// (chainWalkAccess), or the named env var for the outer-ref rewrite (rewriteOuterRef).
function chainWalkFrom(access0: Node, curType0: Type, fieldName: string, chainNames: string[], chainTypes: Type[], targetIdx: number, nodeOriginalType: Type, loc: SourceLocation): Node {
	let access = access0;
	let curType = curType0;
	let k = 0;
	while (k <= targetIdx) {
		const upMember = makeMember(access, UP_FIELD, loc);
		upMember.nodeType = createPtr(voidType());  // read $up (owning Ref<parent>, or void* at a root env) then cast
		const nextCast = createNode(NodeKind.TypeAssertion, { asExpr: upMember, asType: chainNames[k] }, syntheticToken(loc));
		nextCast.nodeType = createPtr(chainTypes[k]);
		access = makeHiddenDeref(nextCast, loc);
		access.nodeType = chainTypes[k];
		curType = chainTypes[k];
		k += 1;
	}
	let result = makeMember(access, fieldName, loc);
	result.nodeType = nodeOriginalType !== null ? nodeOriginalType : envFieldType(curType, fieldName);
	// If the storing env keeps this field as a ccgIntroducedPtr (Array/Union/
	// Span as `Ptr<T>`), one extra deref recovers T.
	if (isEnvPtrField(curType, fieldName)) {
		result = makeHiddenDeref(result, loc);
		result.nodeType = nodeOriginalType !== null ? nodeOriginalType : envFieldType(curType, fieldName);
	}
	return result;
}

function chainWalkAccess(
	fieldName: string,
	currentEnvName: string, currentEnvType: Type,
	chainNames: string[], chainTypes: Type[], targetIdx: number,
	nodeOriginalType: Type,
	loc: SourceLocation,
): Node {
	// access = (*((currentEnv*)_envP)) — this closure's own env struct.
	const envIdent = makeIdent(ENV_PARAM_NAME, loc);
	const curCast = createNode(NodeKind.TypeAssertion, { asExpr: envIdent, asType: currentEnvName }, syntheticToken(loc));
	curCast.nodeType = createPtr(currentEnvType);
	const access = makeHiddenDeref(curCast, loc);
	access.nodeType = currentEnvType;
	return chainWalkFrom(access, currentEnvType, fieldName, chainNames, chainTypes, targetIdx, nodeOriginalType, loc);
}

// rewriteNode parameters:
// - body: the closure body to rewrite
// - captures: names captured by this closure (rewrite targets)
// - envTypeName / envStructType: this closure's env (cast target for `_envP`)
// - chainNames / chainTypes: ancestor envs, immediate-parent first. A capture
//   not stored in the current env lives in one of these — reached by walking
//   `$up` (Nim accessViaEnvParam), never copied down (that was bug D).
function rewriteNode(
	node: Node,
	captures: NameSet,
	envTypeName: string, envStructType: Type,
	chainNames: string[], chainTypes: Type[],
): Node | null {
	if (node === null) return null;
	if (node.kind === NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		if (nameSetContains(captures, d.name)) {
			// If the captured name is NOT a field of the current env, walk the
			// `$up` chain to the ancestor env that stores it (Nim parity).
			if (!envHasField(envStructType, d.name)) {
				const idx = chainIndexOf(chainTypes, d.name);
				if (idx >= 0) {
					return chainWalkAccess(d.name, envTypeName, envStructType, chainNames, chainTypes, idx, node.nodeType, node.location);
				}
			}
			// Implementation parity: env param is void*, cast+deref to typed pointer for field access
			// Produces: (*((EnvType*)_envP)).field  in C
			const envIdent = makeIdent(ENV_PARAM_NAME, node.location);
			const ptrType = createPtr(envStructType);
			const cast = createNode(NodeKind.TypeAssertion, { asExpr: envIdent, asType: envTypeName }, syntheticToken(node.location));
			cast.nodeType = ptrType;
			const deref = makeHiddenDeref(cast, node.location);
			let result = makeMember(deref, d.name, node.location);
			result.nodeType = node.nodeType !== null ? node.nodeType : envFieldType(envStructType, d.name);
			// Ptr field (pointer-promoted param capture): extra deref to get T from T*
			if (isEnvPtrField(envStructType, d.name)) {
				result = makeHiddenDeref(result, node.location);
				result.nodeType = node.nodeType !== null ? node.nodeType : envFieldType(envStructType, d.name);
			}
			return result;
		}
		return node;
	}
	if (isFuncBoundary(node)) return node;
	mapChildren(node, (child: Node): Node => rewriteNode(child, captures, envTypeName, envStructType, chainNames, chainTypes));
	return node;
}

// ===== Outer Reference Rewrite (accessViaEnvVar parity) =====
// After a closure captures variables, ALL subsequent references to those variables
// in the outer function are rewritten to access through the named env variable.
// This ensures mutations inside closures are visible to the outer function and vice versa.

function rewriteOuterRef(node: Node, rewrite: PendingEnvRewrite): Node | null {
	if (node === null) return null;
	if (node.kind === NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		// Skip function captures — module-level functions are always accessible in C,
		// only local variables need outer-ref rewriting through the env.
		const isFnCapture = node.resolvedSym !== null && node.resolvedSym.symbolKind === SymbolKind.Function;
		if (!isFnCapture && nameSetContains(rewrite.capturedNames, d.name) && rewrite.envVarName !== "") {
			// Ancestor capture skipped from this env: walk `$up` from the named
			// env var to the ancestor env that stores it (Nim accessViaEnvParam).
			// Without this, an ancestor ref at THIS scope emits `_envN->field` for
			// a field that no longer exists (bug D fix skips it) → invalid C.
			if (!envHasField(rewrite.envStructType, d.name)) {
				const idx = chainIndexOf(rewrite.chainTypes, d.name);
				if (idx >= 0) {
					const baseIdent = makeIdent(rewrite.envVarName, node.location);
					baseIdent.nodeType = createRef(rewrite.envStructType);
					return chainWalkFrom(baseIdent, rewrite.envStructType, d.name, rewrite.chainNames, rewrite.chainTypes, idx, node.nodeType, node.location);
				}
			}
			// Rewrite: x → _envN->field (env is Ref<Struct>, pointer in C)
			const envIdent = makeIdent(rewrite.envVarName, node.location);
			envIdent.nodeType = createRef(rewrite.envStructType);
			let result = makeMember(envIdent, d.name, node.location);
			result.nodeType = node.nodeType !== null ? node.nodeType : envFieldType(rewrite.envStructType, d.name);
			// Ptr field (ccgIntroducedPtr capture): extra deref to get T from T*
			if (isEnvPtrField(rewrite.envStructType, d.name)) {
				result = makeHiddenDeref(result, node.location);
				result.nodeType = node.nodeType !== null ? node.nodeType : envFieldType(rewrite.envStructType, d.name);
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
	for (const rw of rewrites) {
		result = rewriteOuterRef(result, rw);
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
	const liftedName = `$lifted_${state.currentFnName}_${counter}`;

	let envName: string;
	let envVarName: string;
	let envStructType: Type;

	// Closures created inside a loop body must NOT use the function-scope shared
	// env — the shared env has one slot per variable, overwritten each iteration.
	// A closure stored past the iteration (spawn, .then, actor.send, array.push)
	// would later read whatever the LAST iteration wrote, not its own. Fix: when
	// inside a loop, allocate a per-closure env (snapshot of captures at creation
	// site). Outside loops, shared env is safe and faster.
	const useShared = state.sharedEnvActive && state.insideLoop === 0;

	if (useShared) {
		// Shared env path (reference parity: ownerToType — all closures share one env)
		envName = state.sharedEnvName;
		envVarName = state.sharedEnvVarName;
		envStructType = state.sharedEnvStructType;
	} else {
		// Per-closure env path — own env struct, fresh alloc at closure creation.
		// Used for module-level closures AND for closures inside loops (snapshot).
		envName = `$Env_${state.currentFnName}_${counter}`;
		envVarName = `_env${counter}_`;

		const envFields: string[] = [];
		const envFieldTypes: string[] = [];
		const envResolvedTypes: Type[] = [];
		// Up-chain field: pointer to lexical parent env. Wired to enclosing fn's
		// shared env at closure construction time. Drives chain walk in rewriteNode.
		envFields.push(UP_FIELD);
		envFieldTypes.push("unknown");
		envResolvedTypes.push(createPtr(voidType()));
		for (const name of captures.items) {
			// Grandparent captures (vars defined in a scope that is NOT the
			// immediate function frame and NOT module-level) are not stored in
			// this env. They live in the parent env and are reached via the
			// `$up` chain walk in `rewriteNode`.
			const orig = findCapturedIdent(name, state.capturedIdents);
			const isCcgCapture = orig !== null && orig.nodeType !== null && isCcgPtrType(orig.nodeType);
			const isGrandparent = !isCcgCapture
				&& !isDirectParentVar(state.ss, name)
				&& !isModuleLevelVar(state.ss, name);
			if (isGrandparent) continue;  // reached via chain walk
			envFields.push(name);
			envFieldTypes.push(lookupVarType(state, name));
			if (orig !== null && orig.nodeType !== null) {
				let resolvedType = orig.nodeType;
				if (isCcgPtrType(resolvedType)) { resolvedType = createPtr(resolvedType); }
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
	const rewriteCaptures = useShared ? state.sharedEnvCapturedNames : captures;
	// Ancestor chain for `$up` walk (immediate parent first). A shared-env closure
	// walks the current shared env's own chain; a per-closure env prepends the
	// enclosing shared env (its `$up` target) then that env's chain.
	const rwChainNames: string[] = [];
	const rwChainTypes: Type[] = [];
	if (useShared) {
		for (const n of state.sharedEnvChainNames) rwChainNames.push(n);
		for (const t of state.sharedEnvChainTypes) rwChainTypes.push(t);
	} else if (hasEnclosingFnEnv(state)) {
		rwChainNames.push(state.sharedEnvName);
		rwChainTypes.push(state.sharedEnvStructType);
		for (const n of state.sharedEnvChainNames) rwChainNames.push(n);
		for (const t of state.sharedEnvChainTypes) rwChainTypes.push(t);
	}
	let rewrittenBody = rewriteNode(body, rewriteCaptures, envName, envStructType, rwChainNames, rwChainTypes);
	if (rewrittenBody === null) {
		rewrittenBody = makeBlock([], loc);
	} else if (rewrittenBody.kind !== NodeKind.BlockStmt) {
		rewrittenBody = makeBlock([makeReturn(rewrittenBody, loc)], loc);
	}

	// Create lifted function
	const liftedParams: string[] = [];
	const liftedParamTypes: string[] = [];
	for (const p of params) { liftedParams.push(p); }
	for (const t of paramTypes) { liftedParamTypes.push(t); }
	liftedParams.push(ENV_PARAM_NAME);
	liftedParamTypes.push("void*");
	const fnNode = makeFnDecl(liftedName, liftedParams, liftedParamTypes, rewrittenBody, flags, returnType, loc);
	preserveResolvedTypes(fnNode, originalNodeType);
	state.liftedFunctions.push(fnNode);

	if (useShared) {
		// Shared env: env initialized at function entry, all-refs rewrite already active.
		// No pendingEnvRewrites needed — setupSharedEnv activated the rewrite.
		const sharedPair = makeClosurePairOnly(liftedName, envVarName, envStructType, loc);
		// Load-bearing for DRC: the analyzer classifies a fresh closure value (→ RcKind.Closure) by
		// nodeType; without it ensureDestructionIfNeeded bails on null and the closure-pair temporary
		// passed as a non-sink call argument is never destroyed → its captured env leaks.
		sharedPair.nodeType = originalNodeType;
		return sharedPair;
	} else {
		// Per-closure env: each closure gets its own env declaration + init.
		// If we're here BECAUSE of a loop escape (snapshot mode), outer function
		// code must keep using the shared env, so mark this rewrite snapshot-only.
		const snapshotOnly = state.sharedEnvActive;
		// Up-chain parent: per-closure env's `$up` points to enclosing fn's
		// shared env. Use `currentEnvAccessName` to pick the right access form
		// for the surrounding scope (named var in fn body, `_envP` in nested
		// closure body).
		const parentEnvVarName = currentEnvAccessName(state);
		const parentEnvStructType = hasEnclosingFnEnv(state) ? state.sharedEnvStructType : (null as unknown as Type);
		const envPair = makeEnvVarAndClosurePair(envVarName, liftedName, envStructType, captures, state.lastUseCaptures, state.capturedIdents, state.currentParams, state.ss, parentEnvVarName, parentEnvStructType, loc);
		state.hoistedEnvDecls.push(envPair.envDeclHoisted);
		state.pendingEnvRewrites.push({
			envVarName, envStructType,
			capturedNames: captures,
			chainNames: [] as string[],
			chainTypes: [] as Type[],
			envVarDecl: envPair.envInitStmt,
			snapshotOnly,
		});
		// Load-bearing for DRC (see the shared-env branch): nodeType lets the analyzer classify +
		// destroy the fresh closure-pair temporary so its captured env doesn't leak as a call arg.
		envPair.closurePair.nodeType = originalNodeType;
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
	const liftedName = `$fn_${state.currentFnName}_${state.closureCounter}`;
	let liftedBody = body;
	if (liftedBody.kind !== NodeKind.BlockStmt) {
		liftedBody = makeBlock([makeReturn(liftedBody, loc)], loc);
	}
	const fnNode = makeFnDecl(liftedName, params, paramTypes, liftedBody, flags, returnType, loc);
	preserveResolvedTypes(fnNode, originalNodeType);
	state.liftedFunctions.push(fnNode);
	// Wrap in closure pair { fn: liftedName, env: null } so codegen emits
	// (msClosure){ .fn = (void*)ptr, .env = NULL } instead of raw function pointer.
	// IMPORTANT: set the lifted Identifier's nodeType to the original arrow's
	// Function type. genClosureCall (in C codegen) reads this via
	// getCalleeFuncType to emit correct type casts (return type + param
	// types) for `((RetType(*)(Params))fn)(args)`. Without this, the cast
	// defaults to `void(*)(void)` and IIFE fails to compile.
	const fnIdent = makeIdent(liftedName, loc);
	if (originalNodeType !== null && originalNodeType.kind === TypeKind.Function) {
		fnIdent.nodeType = originalNodeType;
	}
	return wrapFnAsClosure(fnIdent, loc);
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
function makeEnvVarAndClosurePair(envVarName: string, liftedName: string, envStructType: Type, captures: NameSet, lastUseCaptures: NameSet, capturedIdents: Node[], currentParams: NameSet, ss: ScopeStack, parentEnvVarName: string, parentEnvStructType: Type, loc: SourceLocation): { envDeclHoisted: Node, envInitStmt: Node, closurePair: Node } {
	const envKeys: string[] = [];
	const envValues: Node[] = [];
	// Up-chain field init: pointer to lexical parent env, or null at module-level.
	envKeys.push(UP_FIELD);
	if (parentEnvVarName !== "" && parentEnvStructType !== null) {
		const upInit = makeIdent(parentEnvVarName, loc);
		upInit.nodeType = createRef(parentEnvStructType);
		envValues.push(upInit);
	} else {
		envValues.push(makeNull(loc));
	}
	for (const name of captures.items) {
		// Grandparent captures are not stored in this env (matches the struct
		// field skip in `liftClosure` per-closure env construction). They are
		// reached via the `$up` chain walk in `rewriteNode`.
		const orig = findCapturedIdent(name, capturedIdents);
		const isCcgCapture = orig !== null && orig.nodeType !== null && isCcgPtrType(orig.nodeType);
		const isFnCapture = orig !== null && orig.resolvedSym !== null
			&& orig.resolvedSym.symbolKind === SymbolKind.Function;
		const isGrandparent = !isCcgCapture && !isFnCapture
			&& !isDirectParentVar(ss, name)
			&& !isModuleLevelVar(ss, name);
		if (isGrandparent) continue;
		envKeys.push(name);
		let ident = makeIdent(name, loc);
		if (orig !== null && orig.resolvedSym !== null) {
			ident.resolvedSym = orig.resolvedSym;
			ident.nodeType = orig.nodeType;
		}
		let envVal: Node = ident;
		if (isFnCapture) {
			envVal = wrapFnAsClosure(ident, loc);
		}
		// ccgIntroducedPtr captures (Array, Union, Span) store pointer via HiddenAddr.
		if (isCcgCapture) {
			envVal = createNode(NodeKind.HiddenAddr, { expr: envVal }, syntheticToken(loc));
			if (orig.nodeType !== null) envVal.nodeType = createPtr(orig.nodeType);
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

function setupSharedEnv(state: LiftState, allCaptures: NameSet, allCapturedIdents: Node[], loc: SourceLocation): void {
	// Snapshot OUTER (enclosing) shared env BEFORE we override — used below to
	// emit copy-from-_envP stmts for ancestor captures (vars defined in an
	// enclosing closure's frame, neither this closure's param nor module-level).
	// When sharedEnvName === "" the closure has no enclosing env (top-level
	// FunctionDecl), so ancestor copies don't apply.
	const outerEnvName = state.sharedEnvName;
	const outerEnvStructType = state.sharedEnvStructType;
	state.sharedEnvActive = true;
	state.sharedEnvName = `$Env_${state.currentFnName}_shared`;
	state.sharedEnvVarName = `_env_${state.currentFnName}_`;
	state.sharedEnvCapturedNames = allCaptures;
	state.sharedEnvCapturedIdents = allCapturedIdents;

	// Ancestor chain for the `$up` walk: [enclosing env] ++ its own ancestors,
	// immediate-parent first. Empty when there is no enclosing env (top-level
	// function). Nested closures reach ancestor-frame vars by walking this chain
	// (Nim accessViaEnvParam), never by copying values down (that was bug D).
	const parentChainNames: string[] = [];
	const parentChainTypes: Type[] = [];
	if (outerEnvName !== "" && outerEnvStructType !== null) {
		parentChainNames.push(outerEnvName);
		parentChainTypes.push(outerEnvStructType);
		for (const n of state.sharedEnvChainNames) parentChainNames.push(n);
		for (const t of state.sharedEnvChainTypes) parentChainTypes.push(t);
	}
	state.sharedEnvChainNames = parentChainNames;
	state.sharedEnvChainTypes = parentChainTypes;

	// Build env struct fields from all captured vars
	const envFields: string[] = [];
	const envFieldTypes: string[] = [];
	const envResolvedTypes: Type[] = [];
	// Up-chain field: pointer to lexical parent env. For shared (function-root)
	// envs this is null; per-closure envs created inside functions point back to
	// the function's shared env via this field. Drives chain walk in rewriteNode.
	envFields.push(UP_FIELD);
	if (outerEnvName !== "" && outerEnvStructType !== null) {
		// Owning ref to the enclosing env (Nim's `up` is a ref): keeps the parent
		// frame alive while any nested closure holds this env, so the `$up` walk
		// never dangles for an escaping closure (DRC increfs on wire, ORC decrefs
		// on destroy). Chain is acyclic → no cycle, short → no destroy-recursion.
		envFieldTypes.push("");
		envResolvedTypes.push(createRef(outerEnvStructType));
	} else {
		envFieldTypes.push("unknown");
		envResolvedTypes.push(createPtr(voidType()));
	}
	for (const name of allCaptures.items) {
		// Ancestor capture: an enclosing env already stores this var. Do NOT add a
		// field here — it is read via the `$up` walk, never copied (Nim parity).
		let isAncestor = false;
		for (const at of parentChainTypes) { if (envHasField(at, name)) { isAncestor = true; break; } }
		if (isAncestor) continue;
		envFields.push(name);
		envFieldTypes.push(lookupVarType(state, name));
		const orig = findCapturedIdent(name, state.sharedEnvCapturedIdents);
		const isParamCapture = nameSetContains(state.currentParams, name);
		if (orig !== null && orig.nodeType !== null) {
			let resolvedType = orig.nodeType;
			// Intentional divergence from standard reference (see CLAUDE.md):
			// ccgIntroducedPtr params (Array, Union, Span): store POINTER in shared env.
			// Standard ref copies param value + forbids capturing var params (illegalCapture).
			// MetaScript arrays are reference types (JS semantics) — closure and caller must
			// share the same array. Without Ptr, closure pushes to env copy, caller never sees changes.
			if (isParamCapture && isCcgPtrType(resolvedType)) {
				resolvedType = createPtr(resolvedType);
			}
			envResolvedTypes.push(resolvedType);
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

	// Wire `$up` to the enclosing env. This closure's lifted body receives the
	// enclosing env as `_envP` (the closure pair carries it), so nested closures
	// walk `$up` to reach ancestor-frame slots (Nim rawClosureCreation up-field).
	if (outerEnvName !== "" && outerEnvStructType !== null) {
		const upLhs = makeMember(makeIdent(state.sharedEnvVarName, loc), UP_FIELD, loc);
		upLhs.nodeType = createRef(outerEnvStructType);
		// Cast the void* enclosing-env param to Ref<outerEnv> so DRC sees an owning
		// ref copy and increfs the parent (balanced by ORC decref on env destroy).
		const upRhs = createNode(NodeKind.TypeAssertion, { asExpr: makeIdent(ENV_PARAM_NAME, loc), asType: outerEnvName }, syntheticToken(loc));
		upRhs.nodeType = createRef(outerEnvStructType);
		state.hoistedEnvDecls.push(makeExprStmt(makeAssign(upLhs, upRhs, loc), loc));
	}

	// Reference parity (rawClosureCreation): copy available values into env fields.
	// Params and module-level vars/functions are available at function entry.
	// Local vars (declared later) are handled by VarDecl→assignment rewrite.
	//
	// Module-level check must be symbol-based (Global flag), not name-based scope:
	// when a local captured var shadows a module-level var of the same name
	// (e.g. module-level `const me` + async-local `const me = await ...`), a
	// name-based check mistakes the inner hoisted local for a module-level capture
	// and emits `env.name = name` whose RHS has no declaration in function scope.
	// Mirrors detectAllWalk's interestingVar check and Nim's `sfGlobal notin s.flags`.
	for (const name of allCaptures.items) {
		const isParam = nameSetContains(state.currentParams, name);
		const orig = findCapturedIdent(name, state.sharedEnvCapturedIdents);
		const symOrig = (orig !== null) ? orig.resolvedSym : null as unknown as Symbol;
		const isModLevel = (symOrig !== null
				&& (symOrig.symbolKind === SymbolKind.Variable || symOrig.symbolKind === SymbolKind.Parameter))
			? hasFlag(symOrig, SymbolFlag.Global)
			: isModuleLevelVar(state.ss, name);
		if (isParam || isModLevel) {
			const lhs = makeMember(makeIdent(state.sharedEnvVarName, loc), name, loc);
			const isCcgParam = isParam && orig !== null && orig.nodeType !== null && isCcgPtrType(orig.nodeType);
			if (isCcgParam) {
				// Ptr field: LHS type must be Ptr<T> so DRC skips RC hooks (noRcInfo for Ptr)
				lhs.nodeType = createPtr(orig.nodeType);
			} else if (orig !== null && orig.nodeType !== null) {
				lhs.nodeType = orig.nodeType;
			}
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
			// ccgIntroducedPtr params: store pointer via HiddenAddr (share, don't copy)
			if (isCcgParam) {
				rhs = createNode(NodeKind.HiddenAddr, { expr: rhs }, syntheticToken(loc));
				rhs.nodeType = createPtr(orig.nodeType);
			}
			state.hoistedEnvDecls.push(makeExprStmt(makeAssign(
				lhs, rhs, loc
			), loc));
		}
		// Ancestor captures need NO init here — they live in an enclosing env and
		// are read in the body via the `$up` walk (rewriteNode/chainWalkAccess).
		// (Previously copied by value → nested-closure writes were lost: bug D.)
	}

	// Reference parity (accessViaEnvVar): activate all-refs rewrite from function entry.
	// ALL references to captured vars in the function body go through the env.
	// Combined with VarDecl→assignment in walkLiftStmtList, this ensures mutations are shared.
	state.activeEnvRewrites.push({
		envVarName: state.sharedEnvVarName,
		envStructType: state.sharedEnvStructType,
		capturedNames: allCaptures,
		chainNames: state.sharedEnvChainNames,
		chainTypes: state.sharedEnvChainTypes,
		envVarDecl: null as unknown as Node,
		snapshotOnly: false,
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
			// Apply already-active rewrites to the init statement so that any
			// captured-var references inside it resolve to the enclosing env
			// (typically the shared function-scope env). Without this, a
			// snapshot init `_env1 = { j: j }` would emit a bare `j` ident
			// that has no C-level declaration when `j` is actually a shared-env
			// field. Skip self — the newly-pushed rewrite isn't in activeEnvRewrites yet.
			let decl = rewrite.envVarDecl;
			if (state.activeEnvRewrites.length > 0) {
				decl = applyActiveRewrites(decl, state.activeEnvRewrites);
			}
			result.push(decl);
		}
		// Snapshot envs (escaping closure inside a loop) only emit the init;
		// they don't activate an outer-ref rewrite because the outer function
		// must keep writing to the shared env, not the snapshot.
		if (!rewrite.snapshotOnly) {
			state.activeEnvRewrites.push(rewrite);
		}
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

function walkLiftStmtList(stmts: Node[], state: LiftState, isTopLevel: boolean): Node[] {
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
		//
		// `hasEnclosingFnEnv` (sharedEnvName !== "") rather than `sharedEnvActive`:
		// `tryLiftClosure`'s `saveSharedEnv` flips active off when walking
		// nested-arrow bodies but keeps the enclosing fn's env identifiers
		// intact, so VarDecls inside such bodies still need rewriting.
		if (hasEnclosingFnEnv(state) && stmts[si].kind === NodeKind.VariableDecl) {
			const vd = stmts[si].data as VariableDeclData;
			if (nameSetContains(state.sharedEnvCapturedNames, vd.declName)) {
				// VarDecl of a captured var: rewrite to env field assignment.
				// Access form depends on lexical context — see comments on
				// `inEnclosingFnBody` (true → named hoisted var; false → `_envP`).
				const stmtLoc = stmts[si].location;
				let envAccess: Node;
				if (inEnclosingFnBody(state)) {
					envAccess = makeIdent(state.sharedEnvVarName, stmtLoc);
					envAccess.nodeType = createRef(state.sharedEnvStructType);
				} else {
					const envIdent = makeIdent(ENV_PARAM_NAME, stmtLoc);
					const cast = createNode(NodeKind.TypeAssertion, { asExpr: envIdent, asType: state.sharedEnvName }, syntheticToken(stmtLoc));
					cast.nodeType = createPtr(state.sharedEnvStructType);
					envAccess = makeHiddenDeref(cast, stmtLoc);
					envAccess.nodeType = state.sharedEnvStructType;
				}
				const lhs = makeMember(envAccess, vd.declName, stmtLoc);
				if (stmts[si].nodeType !== null) lhs.nodeType = stmts[si].nodeType;
				const init = (vd.initializer !== null) ? vd.initializer : makeNull(stmtLoc);
				stmts[si] = makeExprStmt(makeAssign(lhs, init, stmtLoc), stmtLoc);
			}
		}
		if (!isTopLevel && stmts[si].kind === NodeKind.FunctionDecl) {
			state.liftedFunctions.push(stmts[si]);
		} else {
			result.push(stmts[si]);
		}
		si += 1;
	}
	return result;
}

function walkLift(node: Node, state: LiftState): void {
	if (node === null) return;
	match (node.kind) {
		NodeKind.Program => {
			const d = node.data as ProgramData;
			const savedStmts = state.currentStmts;
			const savedIdx = state.currentStmtIdx;
			const savedHoisted = state.hoistedEnvDecls;
			state.currentStmts = d.programStmts;
			state.hoistedEnvDecls = [];
			d.programStmts = walkLiftStmtList(d.programStmts, state, true);
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
			d.statements = walkLiftStmtList(d.statements, state, false);
			state.currentStmts = savedStmts;
			state.currentStmtIdx = savedIdx;
		},
		NodeKind.FunctionDecl => {
			const d = node.data as FunctionDeclData;
			// Generic template: never lifted. Monomorphization (instantiate.ms strips the `gen:`
			// flag) emits concrete instances, which ARE lifted. Lifting the T-unbound template only
			// manufactures orphan closures (void* env, unlowered methods) that codegen later drops.
			if (d.fnFlags.indexOf("gen:") >= 0) return;
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

			// Read pre-computed captures from detection state (populated by
			// Pass 1 / `detectPass` at start of `lowerLambda`). FunctionDecl
			// Node identity is the lookup key.
			const allCaptures = detectionGetCaptures(state.detection, node);
			const allCapturedIdents = detectionGetCapturedIdents(state.detection, node);

			// Pre-register VarDecl types from the function body so setupSharedEnv
			// can resolve env field types for vars not yet walked (async transforms, etc.)
			if (allCaptures.items.length > 0) {
				preRegisterVarTypes(d.fnBody, state);
			}

			// Walk + manage hoisted env decls via the shared helper. The
			// preWalk slot is where `setupSharedEnv` runs — it MUST happen
			// after the helper has reset `hoistedEnvDecls` (so the shared
			// env decl lands here, not in the outer scope) and before the
			// body walk (so the env name is in scope when closures inside
			// reference it).
			const fnLoc = node.location;
			walkLiftBody(d.fnBody, state, () => {
				if (allCaptures.items.length > 0) {
					setupSharedEnv(state, allCaptures, allCapturedIdents, fnLoc);
				}
			});
			popFuncBoundary(state.ss);
			state.currentParams = savedParams;
			state.activeEnvRewrites = savedActiveRewrites;
			restoreSharedEnv(state, savedShared);
			state.currentFnName = savedName;
		},
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			// Self-recursive closure binding: pre-define for arrow/funcExpr inits
			// so per-closure `detectCaptures` (called inside `tryLiftClosure`
			// during `walkOrLift`) sees the bound name as an outer var and
			// captures it. Same heuristic mirrored in checker `checkVariableDecl`
			// and detection pass `detectPassWalk` / `detectAllWalk`.
			const isSelfRefClosureInit = d.initializer !== null
				&& (d.initializer.kind === NodeKind.ArrowFunction
					|| d.initializer.kind === NodeKind.FunctionExpr);
			if (isSelfRefClosureInit) defineVar(state.ss, d.declName);
			d.initializer = walkOrLift(d.initializer, state);
			if (!isSelfRefClosureInit) defineVar(state.ss, d.declName);
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
		NodeKind.TestDecl => {
			// Test bodies compile to standalone C functions (one per `test "..."`
			// block). Treat as a function boundary so arrows inside get lifted —
			// without this, codegen sees raw ArrowFunction nodes and emits
			// `0 /* unlowered ArrowFunction */`. Build mode never hits this path
			// (DCE strips test bodies pre-lifting) but test mode keeps them.
			//
			// Save/restore the same broader state slots a FunctionDecl arm does
			// (currentFnName, currentParams, activeEnvRewrites, sharedEnv) so
			// processing one test body doesn't pollute the next sibling. The
			// inner hoisted-env-decl lifecycle goes through `walkLiftBody` —
			// this is what Bug 10 was missing (inline reset+walk+restore was
			// silently dropping any lifted env declaration that captured a
			// `let` inside the test body).
			const d = node.data as TestDeclData;
			const savedName = state.currentFnName;
			// Each test block lowers to its own C function — give its shared env a
			// unique name so sibling test blocks don't collide on `$Env__shared`.
			state.closureCounter += 1;
			state.currentFnName = `test${state.closureCounter}`;
			pushFuncBoundary(state.ss);
			const savedParams = state.currentParams;
			const savedActiveRewrites = state.activeEnvRewrites;
			state.currentParams = createNameSet();
			state.activeEnvRewrites = [];
			const savedShared = saveSharedEnv(state);
			const allCaptures = detectionGetCaptures(state.detection, node);
			const allCapturedIdents = detectionGetCapturedIdents(state.detection, node);
			if (allCaptures.items.length > 0) {
				preRegisterVarTypes(d.testBody, state);
			}
			const testLoc = node.location;
			walkLiftBody(d.testBody, state, () => {
				if (allCaptures.items.length > 0) {
					setupSharedEnv(state, allCaptures, allCapturedIdents, testLoc);
				}
			});
			popFuncBoundary(state.ss);
			state.currentParams = savedParams;
			state.activeEnvRewrites = savedActiveRewrites;
			restoreSharedEnv(state, savedShared);
			state.currentFnName = savedName;
		},
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			// IIFE — `((s) => { ... })(arg)` — has ArrowFunction at the
			// callee position. walkLift alone doesn't lift, leaving the
			// arrow unlowered for codegen which emits
			// `0 /* unlowered ArrowFunction */`. walkOrLift handles both
			// the IIFE case (lift the arrow → closure pair) and the normal
			// case (just walk).
			const calleeWasArrow = d.callee.kind === NodeKind.ArrowFunction
				|| d.callee.kind === NodeKind.FunctionExpr;
			d.callee = walkOrLift(d.callee, state);
			// After lifting an arrow callee, the call must use the closure-call
			// convention: `callee.fn(args, callee.env)`. closureCallMarker only
			// detects MemberExpr-typed callees with Function nodeType, so it'd
			// miss our ObjectLiteral closure-pair callee. Mark it here.
			if (calleeWasArrow && d.callee.kind === NodeKind.ObjectLiteral) {
				d.isDirectCall = false;
			}
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
		NodeKind.ObjectLiteral => {
			const d = node.data as ObjectLiteralData;
			for (let oi = 0; oi < d.properties.length; oi += 1) {
				d.properties[oi] = walkOrLift(d.properties[oi], state);
			}
		},
		NodeKind.ArrayLiteral => {
			const d = node.data as ArrayLiteralData;
			for (let ei = 0; ei < d.elements.length; ei += 1) {
				d.elements[ei] = walkOrLift(d.elements[ei], state);
			}
		},
		// Uniform child traversal (Nim transf walks every sub-node): any
		// expression wrapper not handled above — MemberExpr/ArrayAccess/
		// ConditionalExpr/TypeAssertion/… — must still reach an inline arrow
		// nested in a call it holds (`g(x => …).m()`), else codegen emits
		// `0 /* unlowered ArrowFunction */`. walkOrLift lifts arrows and routes
		// statement children back through their own arms; leaves no-op.
		_ => {
			mapChildren(node, (child: Node): Node => walkOrLift(child, state));
		},
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

// No-op default for `walkLiftBody`'s `preWalk` slot. Callers without any
// pre-walk work (Method/Ctor/Arrow/FuncExpr/Test) can rely on the default and
// don't need to thread a callback through.
function noopPreWalk(): void {}

// Walk a function-body-shaped node and own the full env-hoisting lifecycle:
//
//   save current hoisted env decls list
//   reset to empty (so anything hoisted during this walk lands in this scope)
//   preWalk()                       <-- only FunctionDecl uses this slot
//                                       (its `setupSharedEnv` MUST run between
//                                        the reset and the walk so the shared
//                                        env decl lands in *this* function's
//                                        body, not the outer scope's)
//   walkLift(body)
//   prepend hoisted decls into body's statements   <-- always runs
//   restore the outer scope's hoisted list
//
// The "always runs" prepend is the load-bearing invariant. Bug 10 was
// TestDecl re-implementing this lifecycle inline and forgetting the prepend
// step — so any closure capturing a `let` inside a test block ended up with a
// dangling `_envN_` reference at codegen. Owning the full lifecycle inside
// this helper means callers physically can't skip the prepend.
function walkLiftBody(body: Node, state: LiftState, preWalk: () => void = noopPreWalk): void {
	const savedHoisted = state.hoistedEnvDecls;
	state.hoistedEnvDecls = [];
	preWalk();
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
	chainNames: string[];
	chainTypes: Type[];
}

function saveSharedEnv(state: LiftState): SharedEnvSnapshot {
	const snap: SharedEnvSnapshot = {
		active: state.sharedEnvActive,
		name: state.sharedEnvName,
		varName: state.sharedEnvVarName,
		structType: state.sharedEnvStructType,
		capturedNames: state.sharedEnvCapturedNames,
		capturedIdents: state.sharedEnvCapturedIdents,
		chainNames: state.sharedEnvChainNames,
		chainTypes: state.sharedEnvChainTypes,
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
	state.sharedEnvChainNames = snap.chainNames;
	state.sharedEnvChainTypes = snap.chainTypes;
}

// Walk + lift one capturing closure (Arrow or FunctionExpr). Drives the
// per-closure env setup: bumps the closure counter so this closure's shared
// env gets a unique name, calls `setupSharedEnv` in walkLiftBody's preWalk
// when detection found nested-capture refs, then restores currentFnName /
// currentParams.
//
// `lifter` is the per-kind closure constructor (liftArrow vs liftFuncExpr).
// `body` is guaranteed BlockStmt via `normalizeArrowBodies`.
function liftCapturingClosureBody(
	state: LiftState,
	node: Node,
	body: Node,
	params: string[],
	paramTypes: string[],
	flags: string,
	returnType: string,
	suffix: string,
	savedActiveRewrites: PendingEnvRewrite[],
	savedShared: SharedEnvSnapshot,
	lifter: (n: Node, captures: NameSet, state: LiftState) => Node,
): Node {
	for (const p of params) { defineVar(state.ss, p); }
	// Each capturing closure is its own env-owner (Nim parity). Locals
	// declared inside its body MUST live in this closure's per-call env, not
	// in an enclosing FunctionDecl's shared env — otherwise multiple
	// invocations of the same closure share storage and overwrite each
	// other's per-call state. Detection's `fnCaptures` for this node = vars
	// in the closure's frame or above referenced by its nested closures
	// (already filtered by `definedAtOrAboveInitial`).
	const ownCaptures = detectionGetCaptures(state.detection, node);
	const ownCapturedIdents = detectionGetCapturedIdents(state.detection, node);
	const savedFnName = state.currentFnName;
	const savedCurrentParams = state.currentParams;
	if (ownCaptures.items.length > 0) {
		state.closureCounter += 1;
		state.currentFnName = `${savedFnName}_${suffix}${state.closureCounter}`;
		state.currentParams = createNameSet();
		for (const p of params) nameSetAdd(state.currentParams, p);
		preRegisterVarTypes(body, state);
	}
	const loc = node.location;
	walkLiftBody(body, state, () => {
		if (ownCaptures.items.length > 0) {
			setupSharedEnv(state, ownCaptures, ownCapturedIdents, loc);
		}
	});
	state.capturedIdents = [];
	const captures = detectCaptures(body, state.ss, state.capturedIdents);
	popFuncBoundary(state.ss);
	state.activeEnvRewrites = savedActiveRewrites;
	restoreSharedEnv(state, savedShared);
	state.currentFnName = savedFnName;
	state.currentParams = savedCurrentParams;
	// The closure needs the outer env at runtime if either its body has
	// direct outer refs (captured) OR detection found refs from nested
	// closures (ownCaptures). In the latter case, walkLiftBody's per-closure
	// shared env already rewrote body refs through its own env var, so
	// `captures` is empty post-walk — fall back to ownCaptures to keep the
	// closure-pair carrying its outer env, which the body now needs to copy
	// ancestor captures from at entry.
	if (captures.items.length > 0 || ownCaptures.items.length > 0) {
		computeLastUseCapturesForState(captures, state);
		return lifter(node, captures, state);
	}
	return liftNonCapturing(body, params, paramTypes, flags, returnType, state, loc, node.nodeType);
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
		return liftCapturingClosureBody(state, node, d.arrowBody, d.arrowParams, d.arrowParamTypes, d.arrowFlags, d.arrowReturnType, "arrow", savedActiveRewrites, savedShared, liftArrow);
	} else if (node.kind === NodeKind.FunctionExpr) {
		const d = node.data as FunctionExprData;
		return liftCapturingClosureBody(state, node, d.funcExprBody, d.funcExprParams, d.funcExprParamTypes, d.funcExprFlags, d.funcExprReturnType, "fexpr", savedActiveRewrites, savedShared, liftFuncExpr);
	} else {
		popFuncBoundary(state.ss);
		state.activeEnvRewrites = savedActiveRewrites;
		restoreSharedEnv(state, savedShared);
	}
	return node;
}

// ===== Main Entry Point =====

// Wrap every `ArrowFn(body=Arrow|FuncExpr)` into block-bodied form so
// lifting always sees a BlockStmt. Without this, capturing curried arrows
// hit a special case that bypassed env setup (fixedbugs/bug039).
function normalizeArrowBodies(node: Node): Node {
	if (node === null) return null as unknown as Node;
	if (node.kind === NodeKind.ArrowFunction) {
		const d = node.data as ArrowFunctionData;
		if (d.arrowBody !== null
			&& (d.arrowBody.kind === NodeKind.ArrowFunction
				|| d.arrowBody.kind === NodeKind.FunctionExpr)) {
			const loc = d.arrowBody.location;
			d.arrowBody = makeBlock([makeReturn(d.arrowBody, loc)], loc);
		}
	}
	mapChildren(node, normalizeArrowBodies);
	return node;
}

export function lowerLambda(program: Node, ctx: TransformContext): Node {
	const state = createLiftState();
	normalizeArrowBodies(program);
	// Pass 1: collect per-fn capture info upfront (Nim parity).
	state.detection = detectPass(program);
	// Pass 2: rewrite + lift closures, consuming Pass 1 results.
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

test "nested function hoisted to top level" {
	const result = parseInput("function outer() { function f() { return 1; } f(); }");
	if (!result.ok) { assert false; return; }
	const lowered = lowerLambda(result.value, makeCtx());
	const stmts = getStmts(lowered);
	assert stmts.length === 2;
	assert stmts[0].kind === NodeKind.FunctionDecl;
	assert stmts[1].kind === NodeKind.FunctionDecl;
}

test "non-capturing arrow lifted" {
	// Arrow lifted to module-level FunctionDecl + original VariableDecl = 2 stmts
	assert stmtCountAfter("const f = (x) => x + 1;", lowerLambda) === 2;
	assert firstStmtKindAfter("const f = (x) => x + 1;", lowerLambda) === NodeKind.FunctionDecl;
}

test "arrow inside array literal lifted" {
	assert stmtCountAfter("const a = [() => 1];", lowerLambda) === 2;
	assert firstStmtKindAfter("const a = [() => 1];", lowerLambda) === NodeKind.FunctionDecl;
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
