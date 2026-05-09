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

import { Node, NodeKind, DeclKind, SourceLocation, NodeFlag, SymbolKind, Symbol, createNode, ProgramData, BlockStmtData, FunctionDeclData, ArrowFunctionData, FunctionExprData, MethodDeclData, ConstructorDeclData, ExportDeclData, ClassDeclData, DecoratedDeclData, VariableDeclData, IfStmtData, WhileStmtData, DoWhileStmtData, TryCatchStmtData, SwitchStmtData, SwitchCaseData, ExprStmtData, ReturnStmtData, BinaryExprData, CallExprData, UnaryExprData, IdentifierData, ObjectLiteralData, TestDeclData, Type, TypeKind } from "../../ast/node";
import { TransformContext, NameSet, createNameSet, nameSetAdd, nameSetContains } from "../context";
import { mapChildren, isFuncBoundary } from "../walker";
import {
	makeIdent, makeMember, makeMoveExpr, makeReturn, makeBlock, makeVarDecl,
	makeFnDecl, makeInterfaceDeclFromTypes, makeObjectLiteral, makeHiddenDeref,
	makeNull, makeAssign, makeExprStmt, syntheticToken, resolveSimpleTypeStr,
} from "../util";
import { createPtr, createRef, unknownType } from "../../checker/types";
import { hasFlag, SymbolFlag } from "../../checker/symbol";
import { stmtCountAfter, firstStmtKindAfter, parseInput, getStmts } from "../testUtil";
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

// Build an AST that walks one step up the env chain to access a field.
// Emits the C equivalent of:
//   (*((ParentEnvType*)((CurEnvType*)_envP)->$up)).fieldName
// Mirrors Nim's accessViaEnvParam (lambdalifting.nim:529-545) — single step.
// Multi-step chain walks are handled by recursive emission (rare in our model).
//
// `nodeOriginalType` is the captured Identifier's nodeType, used to set the
// returned member's nodeType so downstream codegen sees the right C type.
function chainWalkAccess(
	fieldName: string,
	currentEnvName: string, currentEnvType: Type,
	parentEnvName: string, parentEnvType: Type,
	nodeOriginalType: Type,
	loc: SourceLocation,
): Node {
	// Step 1: cast _envP to current env, deref, access $up
	const envIdent = makeIdent(ENV_PARAM_NAME, loc);
	const curCast = createNode(NodeKind.TypeAssertion, { asExpr: envIdent, asType: currentEnvName }, syntheticToken(loc));
	curCast.nodeType = createPtr(currentEnvType);
	const curDeref = makeHiddenDeref(curCast, loc);
	curDeref.nodeType = currentEnvType;
	const upMember = makeMember(curDeref, UP_FIELD, loc);
	upMember.nodeType = unknownType();  // void* — `$up` field is typed as `unknown`

	// Step 2: cast `$up` to parent env, deref, access target field
	const parentCast = createNode(NodeKind.TypeAssertion, { asExpr: upMember, asType: parentEnvName }, syntheticToken(loc));
	parentCast.nodeType = createPtr(parentEnvType);
	const parentDeref = makeHiddenDeref(parentCast, loc);
	parentDeref.nodeType = parentEnvType;
	let result = makeMember(parentDeref, fieldName, loc);
	if (nodeOriginalType !== null) result.nodeType = nodeOriginalType;
	// If the parent env stores this field as a ccgIntroducedPtr (Array/Union/
	// Span as `Ptr<T>`), one extra deref is needed to get back T — mirroring
	// `rewriteNode`'s handling of the same case for current-env access.
	if (isEnvPtrField(parentEnvType, fieldName)) {
		result = makeHiddenDeref(result, loc);
		if (nodeOriginalType !== null) result.nodeType = nodeOriginalType;
	}
	return result;
}

// rewriteNode parameters:
// - body: the closure body to rewrite
// - captures: names captured by this closure (rewrite targets)
// - envTypeName / envStructType: this closure's env (cast target for `_envP`)
// - parentEnvName / parentEnvType: lexical parent env, or empty/null when none.
//   Used by chain walk when a capture is not a field of the current env.
function rewriteNode(
	node: Node,
	captures: NameSet,
	envTypeName: string, envStructType: Type,
	parentEnvName: string, parentEnvType: Type,
): Node | null {
	if (node === null) return null;
	if (node.kind === NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		if (nameSetContains(captures, d.name)) {
			// If the captured name is NOT a field of the current env, fall back
			// to chain walk via `$up` to the parent env (Nim parity).
			if (!envHasField(envStructType, d.name)
					&& parentEnvName !== "" && parentEnvType !== null
					&& envHasField(parentEnvType, d.name)) {
				return chainWalkAccess(d.name, envTypeName, envStructType, parentEnvName, parentEnvType, node.nodeType, node.location);
			}
			// Implementation parity: env param is void*, cast+deref to typed pointer for field access
			// Produces: (*((EnvType*)_envP)).field  in C
			const envIdent = makeIdent(ENV_PARAM_NAME, node.location);
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
	mapChildren(node, (child: Node): Node => rewriteNode(child, captures, envTypeName, envStructType, parentEnvName, parentEnvType));
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
		envResolvedTypes.push(unknownType());
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
	// Chain walk parent: this per-closure env's `$up` points to the enclosing
	// fn's shared env, so chain-walks read fields that live there.
	const rwParentEnvName = (!useShared && hasEnclosingFnEnv(state)) ? state.sharedEnvName : "";
	const rwParentEnvType = (!useShared && hasEnclosingFnEnv(state)) ? state.sharedEnvStructType : (null as unknown as Type);
	let rewrittenBody = rewriteNode(body, rewriteCaptures, envName, envStructType, rwParentEnvName, rwParentEnvType);
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
		return makeClosurePairOnly(liftedName, envVarName, envStructType, loc);
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
			envVarDecl: envPair.envInitStmt,
			snapshotOnly,
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
	state.sharedEnvActive = true;
	state.sharedEnvName = `$Env_${state.currentFnName}_shared`;
	state.sharedEnvVarName = `_env_${state.currentFnName}_`;
	state.sharedEnvCapturedNames = allCaptures;
	state.sharedEnvCapturedIdents = allCapturedIdents;

	// Build env struct fields from all captured vars
	const envFields: string[] = [];
	const envFieldTypes: string[] = [];
	const envResolvedTypes: Type[] = [];
	// Up-chain field: pointer to lexical parent env. For shared (function-root)
	// envs this is null; per-closure envs created inside functions point back to
	// the function's shared env via this field. Drives chain walk in rewriteNode.
	envFields.push(UP_FIELD);
	envFieldTypes.push("unknown");
	envResolvedTypes.push(unknownType());
	for (const name of allCaptures.items) {
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

	// Reference parity (rawClosureCreation line 617-627): copy available values into env fields.
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
	}

	// Reference parity (accessViaEnvVar): activate all-refs rewrite from function entry.
	// ALL references to captured vars in the function body go through the env.
	// Combined with VarDecl→assignment in walkLiftStmtList, this ensures mutations are shared.
	state.activeEnvRewrites.push({
		envVarName: state.sharedEnvVarName,
		envStructType: state.sharedEnvStructType,
		capturedNames: allCaptures,
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
		result.push(stmts[si]);
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

			// Inline walkLiftBody: save/clear hoisted FIRST, then setup shared env
			// so the shared env hoisted decl lands in the function body, not outer scope
			const savedHoisted = state.hoistedEnvDecls;
			state.hoistedEnvDecls = [];
			if (allCaptures.items.length > 0) {
				setupSharedEnv(state, allCaptures, allCapturedIdents, node.location);
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
			// Save/restore the SAME state slots a FunctionDecl arm does, otherwise
			// processing test bodies pollutes module-level state used by the next
			// FunctionDecl.
			const d = node.data as TestDeclData;
			const savedName = state.currentFnName;
			pushFuncBoundary(state.ss);
			const savedParams = state.currentParams;
			const savedActiveRewrites = state.activeEnvRewrites;
			state.currentParams = createNameSet();
			state.activeEnvRewrites = [];
			const savedShared = saveSharedEnv(state);
			const savedHoisted = state.hoistedEnvDecls;
			state.hoistedEnvDecls = [];
			walkLift(d.testBody, state);
			state.hoistedEnvDecls = savedHoisted;
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
		if (d.arrowBody !== null
			&& (d.arrowBody.kind === NodeKind.ArrowFunction
				|| d.arrowBody.kind === NodeKind.FunctionExpr)) {
			d.arrowBody = walkOrLift(d.arrowBody, state);
		} else {
			walkLiftBody(d.arrowBody, state);
		}
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
