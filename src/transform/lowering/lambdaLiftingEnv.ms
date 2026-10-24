import { Node, NodeKind, DeclKind, SourceLocation, NodeFlag, SymbolKind, Symbol, createNode, BlockStmtData, VariableDeclData, IfStmtData, WhileStmtData, Type, TypeKind } from "../../ast/node";
import {
	TransformContext, SymSet, createSymSet, symSetAdd, symSetContains, reportTransformError, mintSym,
	newLoweredSym,
} from "../context";
import { mapChildren, isFuncBoundary } from "../walker";
import {
	makeTypedIdentResolved, makeMember, makeMoveExpr, makeVarDecl, makeInterfaceDeclFromTypes,
	makeObjectLiteral, makeHiddenDeref, makeNull, makeAssign, makeExprStmt, syntheticToken,
	resolveSimpleTypeStr,
} from "../util";
import { createPtr, createRef, voidType } from "../../checker/types";
import { hasFlag, SymbolFlag } from "../../checker/symbol";
import { DetectionState, createDetectionState } from "./lambdaLiftingDetect";
import { ScopeStack, createScopeStack, isModuleLevelVar } from "./lambdaLiftingScope";
import { findCapturedIdent } from "./lambdaLiftingCaptures";

// Synthetic env field — pointer to the lexical parent env. Each per-closure env
// gets one of these wired to its enclosing function's env. The `$` prefix marks it as a synthetic name unlikely
// to collide with user identifiers.
export const UP_FIELD: string = "$up";

// The hidden env-pointer parameter name on every lifted function. The C ABI
// for closure calls passes the env as the LAST argument (or only argument for
// nullary closures). Kept as a constant to avoid magic-string drift.
const ENV_PARAM_NAME: string = "_envP";

export function freshEnvParamSym(ctx: TransformContext): Symbol {
	return newLoweredSym(ctx, SymbolKind.Parameter, ENV_PARAM_NAME, createPtr(voidType()));
}

export function freshEnvVarSym(ctx: TransformContext, name: string, envStructType: Type | null): Symbol {
	return newLoweredSym(ctx, SymbolKind.Variable, name, envStructType != null ? createRef(envStructType) : createPtr(voidType()));
}

export function envVarRef(sym: Symbol, envStructType: Type, loc: SourceLocation): Node {
	return makeTypedIdentResolved(sym, createRef(envStructType), loc);
}

export function envVarDeref(sym: Symbol, envStructType: Type, loc: SourceLocation): Node {
	const deref = makeHiddenDeref(envVarRef(sym, envStructType, loc), loc);
	deref.nodeType = envStructType;
	return deref;
}

// ===== Lift State =====
// Accumulated during the walk — env structs and lifted functions prepended to program.

interface VarTypeEntry {
	sym: Symbol;
	typeStr: string;
	resolvedType: Type;  // resolved Type for env struct field (fallback when captured ident has no nodeType)
}

// Reference parity: after a closure captures variables, ALL subsequent references
// in the outer function are rewritten to go through the env struct.
// PendingEnvRewrite tracks what needs rewriting after a closure is lifted.
export interface PendingEnvRewrite {
	envVarSym: Symbol | null;  // e.g. "_env1"
	envStructType: Type;        // the env interface type
	capturedSyms: SymSet;       // which bindings to rewrite
	chainNames: string[];       // ancestor env names ($up walk when a ref isn't a field here)
	chainTypes: Type[];         // parallel ancestor env struct types
	envVarDecl: Node;           // the VarDecl node to insert before the closure
	snapshotOnly: boolean;      // a per-closure snapshot: emits its init, never becomes the home of a binding
}

export interface LoopEnv {
	envName: string;
	envVarSym: Symbol;
	envStructType: Type;
	syms: SymSet;
}

export interface LiftState {
	liftedFunctions: Node[];
	envStructs: Node[];
	closureCounter: number;
	currentFnName: string;
	ss: ScopeStack;
	lastUseCaptures: SymSet;   // Phase F: captures that are last-use (can be moved)
	currentStmts: Node[];      // Phase F: current statement list (for last-use scan)
	currentStmtIdx: number;    // Phase F: current statement index in list
	insideLoop: number;        // >0 when inside a loop body (disables last-use move optimization)
	varTypes: VarTypeEntry[];  // Binding → type string for env field typing
	capturedIdents: Node[];    // Parallel to the capture set: original Identifier nodes with resolvedSym
	currentParams: SymSet;     // Current function's params (copied into the shared env at entry)
	pendingEnvRewrites: PendingEnvRewrite[];  // Reference parity: outer-ref rewrites queued by liftClosure
	activeEnvRewrites: PendingEnvRewrite[];   // Currently active rewrites (applied to subsequent stmts)
	hoistedEnvDecls: Node[];  // Env VarDecls hoisted to function-level scope (reference parity)
	// Shared env per function (reference parity: ownerToType — one env for all closures)
	sharedEnvActive: boolean;           // whether shared env is in use for current function
	sharedEnvName: string;              // "$Env_fnName_shared"
	sharedEnvVarSym: Symbol | null;     // "_env_fnName_"
	envParamSym: Symbol;                // `_envP` of the closure body being walked
	sharedEnvStructType: Type;          // the shared env struct type
	sharedEnvCapturedSyms: SymSet;      // union of ALL captured vars across all closures
	sharedEnvCapturedIdents: Node[];    // captured ident nodes from detection pre-pass
	sharedEnvChainNames: string[];      // enclosing shared-env names, immediate-parent first ($up walk)
	sharedEnvChainTypes: Type[];        // parallel: enclosing shared-env struct types
	loopEnvs: LoopEnv[];                // per-iteration envs open in the current frame, innermost last
	splitLoopLocals: Symbol[];          // TransformContext.splitLoopLocals: captured by value (snapshot)
	// Pass 1 result: pre-computed per-FunctionDecl captures (consumed by lift's
	// FunctionDecl path instead of running detection inline).
	detection: DetectionState;
	pendingRoutine: Symbol | null;
	routines: SymSet;
	routineInfos: RoutineInfo[];
	pendingLiftedSym: Symbol | null;
	liftOwnLocals: SymSet;
	envFieldSyms: HashMap<Type, Symbol[]>;
	ctx: TransformContext;
}

export interface RoutineInfo {
	sym: Symbol;
	liftedSym: Symbol;
	envStructType: Type | null;
	promised: boolean;
}

export function registerVarType(state: LiftState, sym: Symbol | null, typeStr: string): void {
	if (sym != null) state.varTypes.push({ sym, typeStr, resolvedType: null as unknown as Type });
}

export function registerVarTypeResolved(state: LiftState, sym: Symbol | null, typeStr: string, resolved: Type): void {
	if (sym != null) state.varTypes.push({ sym, typeStr, resolvedType: resolved });
}

export function lookupVarResolvedType(state: LiftState, sym: Symbol): Type {
	let i = state.varTypes.length - 1;
	while (i >= 0) {
		if (state.varTypes[i].sym == sym && state.varTypes[i].resolvedType != null) return state.varTypes[i].resolvedType;
		i -= 1;
	}
	return null as unknown as Type;
}

export function lookupVarType(state: LiftState, sym: Symbol): string {
	let i = state.varTypes.length - 1;
	while (i >= 0) {
		if (state.varTypes[i].sym == sym) return state.varTypes[i].typeStr;
		i -= 1;
	}
	return "unknown";
}

// Derive type string from resolved nodeType (Reference parity: use resolved symbol types for field typing)
// Used when string annotation is empty but checker has resolved the type.
export function typeToEnvStr(t: Type | null): string {
	if (t == null) return "";
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
			if (t.typeName != null && t.typeName != "") {
				const name = t.typeName;
				return name;
			}
			return "";
		},
		TypeKind.Ref | TypeKind.Ptr => {
			if (t.typeReturn != null) return typeToEnvStr(t.typeReturn);
			return "";
		},
		TypeKind.Array => {
			if (t.typeReturn != null) {
				const elem = typeToEnvStr(t.typeReturn);
				if (elem != "") { return elem + "[]"; } else { return "unknown[]"; }
			} else { return "unknown[]"; }
		},
		TypeKind.GenericInstance => t.typeName,
		_ => "",
	};
}

export function createLiftState(ctx: TransformContext): LiftState {
	const state: LiftState = {
		liftedFunctions: [],
		envStructs: [],
		closureCounter: 0,
		currentFnName: "anon",
		ss: createScopeStack(),
		lastUseCaptures: createSymSet(),
		currentStmts: [],
		currentStmtIdx: 0,
		insideLoop: 0,
		varTypes: [],
		capturedIdents: [],
		currentParams: createSymSet(),
		pendingEnvRewrites: [],
		activeEnvRewrites: [],
		hoistedEnvDecls: [],
		sharedEnvActive: false,
		sharedEnvName: "",
		sharedEnvVarSym: null,
		envParamSym: freshEnvParamSym(ctx),
		sharedEnvStructType: null as unknown as Type,
		sharedEnvCapturedSyms: createSymSet(),
		sharedEnvCapturedIdents: [],
		sharedEnvChainNames: [],
		sharedEnvChainTypes: [],
		loopEnvs: [],
		splitLoopLocals: [],
		detection: createDetectionState(),
		pendingRoutine: null,
		routines: createSymSet(),
		routineInfos: [],
		pendingLiftedSym: null,
		liftOwnLocals: createSymSet(),
		envFieldSyms: new HashMap<Type, Symbol[]>(),
		ctx,
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
// `currentEnvAccessSym` returns the right C identifier to read the enclosing
// fn's env from wherever the emitted code lands.
export function inEnclosingFnBody(state: LiftState): boolean {
	return state.sharedEnvActive;
}

export function hasEnclosingFnEnv(state: LiftState): boolean {
	return state.sharedEnvName != "";
}

export function currentEnvAccessSym(state: LiftState): Symbol | null {
	if (state.sharedEnvActive) return state.sharedEnvVarSym;
	if (state.sharedEnvName != "") return state.envParamSym;
	return null;
}

// ===== Detection Pre-Pass (reference parity: DetectionPass) =====
// Scans a function body to find ALL captures across ALL closures BEFORE lifting.
// Reference parity: DetectionPass + ownerToType creates one shared env type per function.
// Pre-register VarDecl types from a function body so setupSharedEnv can resolve env field types.
// Without this, captured vars from async transforms lack nodeType → env fields become void*.
export function preRegisterVarTypes(body: Node, state: LiftState): void {
	if (body == null) return;
	if (body.kind == NodeKind.VariableDecl) {
		const d = body.data as VariableDeclData;
		if (d.declType != "") {
			registerVarType(state, body.resolvedSym, d.declType);
		} else if (body.nodeType != null) {
			const derived = typeToEnvStr(body.nodeType);
			if (derived != "") {
				registerVarTypeResolved(state, body.resolvedSym, derived, body.nodeType);
			}
		}
		return;
	}
	if (body.kind == NodeKind.FunctionDecl || body.kind == NodeKind.ArrowFunction || body.kind == NodeKind.FunctionExpr) return;
	if (body.kind == NodeKind.BlockStmt) {
		const d = body.data as BlockStmtData;
		for (const s of d.statements) preRegisterVarTypes(s, state);
		return;
	}
	if (body.kind == NodeKind.IfStmt) {
		const d = body.data as IfStmtData;
		preRegisterVarTypes(d.consequent, state);
		preRegisterVarTypes(d.alternate, state);
		return;
	}
	if (body.kind == NodeKind.WhileStmt) {
		preRegisterVarTypes((body.data as WhileStmtData).whileBody, state);
		return;
	}
}

// Replace captured Identifier nodes with env field access.
// Inner (rewriteNode): captured vars → (*((EnvType*)_envP)).field (closure body)
// Outer (rewriteOuterRef): captured vars → _envN->field (outer function, post-closure)

export function makeEnvStruct(state: LiftState, envName: string, fieldSyms: Symbol[], fieldTypes: string[], resolvedTypes: Type[], loc: SourceLocation): Node {
	const fields: string[] = [];
	for (let i = 0; i < fieldSyms.length; i += 1) {
		const sym = fieldSyms[i];
		fields.push(sym == null ? UP_FIELD : `${sym.name}${i}`);
	}
	const envDecl = makeInterfaceDeclFromTypes(envName, fields, fieldTypes, resolvedTypes, loc);
	const envSym = mintSym(state.ctx, SymbolKind.Interface, envName, createRef(envDecl.nodeType!));
	envSym.declNode = envDecl;
	envSym.location = loc;
	envDecl.nodeType!.sym = envSym;
	state.envFieldSyms.set(envDecl.nodeType!, fieldSyms);
	return envDecl;
}

function envFieldIndex(state: LiftState, envStructType: Type, sym: Symbol): int32 {
	if (envStructType == null) return -1;
	const fieldSyms = state.envFieldSyms.get(envStructType);
	if (fieldSyms == null) return -1;
	for (let i = 0; i < fieldSyms.length; i += 1) {
		if (fieldSyms[i] == sym) return i as int32;
	}
	return -1;
}

// Whether an env holds a field for the binding. Used by chain walk to decide
// whether a capture lives in the current env or further up the `$up` chain.
export function envHasField(state: LiftState, envStructType: Type, sym: Symbol): boolean {
	return envFieldIndex(state, envStructType, sym) >= 0;
}

export function envFieldName(state: LiftState, envStructType: Type, sym: Symbol): string {
	return envStructType.typeNames[envFieldIndex(state, envStructType, sym)];
}

// Declared type of an env struct field. A lifted member access derives its
// type from the env field (the type authority), not from the captured identifier —
// which may itself be untyped (e.g. destructuring/async-synthesized captures). Leaving
// the lifted member untyped makes the DRC save-temp fall back to C `double`.
export function envFieldType(state: LiftState, envStructType: Type, sym: Symbol): Type {
	const i = envFieldIndex(state, envStructType, sym);
	if (i < 0 || envStructType.typeChildren == null || i >= envStructType.typeChildren.length) return null as unknown as Type;
	return envStructType.typeChildren[i];
}

// Index of the ancestor env in the chain that stores the binding, or -1.
export function chainIndexOf(state: LiftState, chainTypes: Type[], sym: Symbol): number {
	let i = 0;
	while (i < chainTypes.length) {
		if (envHasField(state, chainTypes[i], sym)) return i;
		i += 1;
	}
	return -1;
}

function envHasUp(state: LiftState, envStructType: Type): boolean {
	const fieldSyms = state.envFieldSyms.get(envStructType);
	if (fieldSyms == null) return false;
	for (const s of fieldSyms) {
		if (s == null) return true;
	}
	return false;
}

export function requireUp(state: LiftState, envStructType: Type, target: string, loc: SourceLocation): void {
	if (!envHasUp(state, envStructType)) {
		reportTransformError(state.ctx, `internal: the env '${envStructType.typeName}' has no $up on the walk to '${target}'`, loc);
	}
}

function readsAncestorEnv(state: LiftState, nestedReads: SymSet, ownLocals: SymSet | null, chainTypes: Type[]): boolean {
	for (const sym of nestedReads.items) {
		if (ownLocals != null && symSetContains(ownLocals, sym)) continue;
		if (!isRoutineSym(state, sym)) {
			if (chainIndexOf(state, chainTypes, sym) >= 0) return true;
			continue;
		}
		const info = routineInfoOf(state, sym);
		if (info == null) return true;
		for (const t of chainTypes) {
			if (t == info.envStructType) return true;
		}
	}
	return false;
}

// Walk `$up` from a base env-struct access up the ancestor chain to the env that
// stores `sym` (chainTypes[targetIdx]).
// `access0` is the starting env-struct value: `(*((Cur*)_envP))` for a lifted body
// (chainWalkAccess), or the named env var for the outer-ref rewrite (rewriteOuterRef).
function chainWalkFrom(state: LiftState, access0: Node, curType0: Type, sym: Symbol, chainNames: string[], chainTypes: Type[], targetIdx: number, nodeOriginalType: Type, loc: SourceLocation): Node {
	let access = access0;
	let curType = curType0;
	let k = 0;
	while (k <= targetIdx) {
		requireUp(state, curType, sym.name, loc);
		const upMember = makeMember(access, UP_FIELD, loc);
		upMember.nodeType = createPtr(voidType());  // read $up (owning Ref<parent>, or void* at a root env) then cast
		const nextCast = createNode(NodeKind.TypeAssertion, { asExpr: upMember, asType: chainNames[k] }, syntheticToken(loc));
		nextCast.nodeType = createPtr(chainTypes[k]);
		access = makeHiddenDeref(nextCast, loc);
		access.nodeType = chainTypes[k];
		curType = chainTypes[k];
		k += 1;
	}
	const result = makeMember(access, envFieldName(state, curType, sym), loc);
	const declaredFt = envFieldType(state, curType, sym);
	result.nodeType = declaredFt != null ? declaredFt : nodeOriginalType;
	return result;
}

function chainWalkAccess(
	state: LiftState,
	sym: Symbol,
	currentEnvName: string, currentEnvType: Type,
	chainNames: string[], chainTypes: Type[], targetIdx: number,
	nodeOriginalType: Type,
	envParamSym: Symbol,
	loc: SourceLocation,
): Node {
	// access = (*((currentEnv*)_envP)) — this closure's own env struct.
	const envIdent = makeTypedIdentResolved(envParamSym, null, loc);
	const curCast = createNode(NodeKind.TypeAssertion, { asExpr: envIdent, asType: currentEnvName }, syntheticToken(loc));
	curCast.nodeType = createPtr(currentEnvType);
	const access = makeHiddenDeref(curCast, loc);
	access.nodeType = currentEnvType;
	return chainWalkFrom(state, access, currentEnvType, sym, chainNames, chainTypes, targetIdx, nodeOriginalType, loc);
}

// rewriteNode parameters:
// - body: the closure body to rewrite
// - captures: bindings captured by this closure (rewrite targets)
// - envTypeName / envStructType: this closure's env (cast target for `_envP`)
// - chainNames / chainTypes: ancestor envs, immediate-parent first. A capture
//   not stored in the current env lives in one of these — reached by walking
//   `$up`, never copied down (that was bug D).
export function rewriteNode(
	state: LiftState,
	node: Node,
	captures: SymSet,
	envTypeName: string, envStructType: Type,
	chainNames: string[], chainTypes: Type[],
	envParamSym: Symbol,
): Node | null {
	if (node == null) return null;
	if (node.kind == NodeKind.Identifier) {
		const sym = node.resolvedSym;
		if (sym != null && symSetContains(captures, sym)) {
			// If the captured binding is NOT a field of the current env, walk the
			// `$up` chain to the ancestor env that stores it.
			if (!envHasField(state, envStructType, sym)) {
				const idx = chainIndexOf(state, chainTypes, sym);
				if (idx < 0) {
					reportTransformError(state.ctx, `internal: no env holds the captured '${sym.name}'`, node.location);
					return node;
				}
				return chainWalkAccess(state, sym, envTypeName, envStructType, chainNames, chainTypes, idx, node.nodeType!, envParamSym, node.location);
			}
			// Implementation parity: env param is void*, cast+deref to typed pointer for field access
			// Produces: (*((EnvType*)_envP)).field  in C
			const envIdent = makeTypedIdentResolved(envParamSym, null, node.location);
			const ptrType = createPtr(envStructType);
			const cast = createNode(NodeKind.TypeAssertion, { asExpr: envIdent, asType: envTypeName }, syntheticToken(node.location));
			cast.nodeType = ptrType;
			const deref = makeHiddenDeref(cast, node.location);
			const result = makeMember(deref, envFieldName(state, envStructType, sym), node.location);
			const declaredFt = envFieldType(state, envStructType, sym);
			result.nodeType = declaredFt != null ? declaredFt : node.nodeType;
			return result;
		}
		return node;
	}
	if (isFuncBoundary(node)) return node;
	mapChildren(node, (child: Node): Node => {
		const rewritten = rewriteNode(state, child, captures, envTypeName, envStructType, chainNames, chainTypes, envParamSym);
		return rewritten == null ? child : rewritten;
	});
	return node;
}

// ===== Outer Reference Rewrite (accessViaEnvVar parity) =====
// After a closure captures variables, ALL subsequent references to those variables
// in the outer function are rewritten to access through the named env variable.
// This ensures mutations inside closures are visible to the outer function and vice versa.

function rewriteOuterRef(state: LiftState, node: Node, rewrite: PendingEnvRewrite): Node | null {
	if (node == null) return null;
	if (node.kind == NodeKind.Identifier) {
		const sym = node.resolvedSym;
		// Skip function captures — module-level functions are always accessible in C,
		// only local variables need outer-ref rewriting through the env.
		const isFnCapture = sym != null && sym.symbolKind == SymbolKind.Function;
		if (!isFnCapture && sym != null && symSetContains(rewrite.capturedSyms, sym) && rewrite.envVarSym != null) {
			// Ancestor capture skipped from this env: walk `$up` from the named
			// env var to the ancestor env that stores it.
			// Neither held nor reachable here: the scope that owns it rewrites it.
			if (!envHasField(state, rewrite.envStructType, sym)) {
				const idx = chainIndexOf(state, rewrite.chainTypes, sym);
				if (idx < 0) return node;
				const baseIdent = envVarDeref(rewrite.envVarSym, rewrite.envStructType, node.location);
				return chainWalkFrom(state, baseIdent, rewrite.envStructType, sym, rewrite.chainNames, rewrite.chainTypes, idx, node.nodeType!, node.location);
			}
			// Rewrite: x → _envN->field (env is Ref<Struct>, pointer in C)
			const envIdent = envVarDeref(rewrite.envVarSym, rewrite.envStructType, node.location);
			const result = makeMember(envIdent, envFieldName(state, rewrite.envStructType, sym), node.location);
			const declaredFt = envFieldType(state, rewrite.envStructType, sym);
			result.nodeType = declaredFt != null ? declaredFt : node.nodeType;
			return result;
		}
		return node;
	}
	if (isFuncBoundary(node)) return node;
	mapChildren(node, (child: Node): Node => {
		const rewritten = rewriteOuterRef(state, child, rewrite);
		return rewritten == null ? child : rewritten;
	});
	return node;
}

export function applyActiveRewrites(state: LiftState, node: Node, rewrites: PendingEnvRewrite[]): Node {
	let result = node;
	for (const rw of rewrites) {
		const rewritten = rewriteOuterRef(state, result, rw);
		if (rewritten != null) { result = rewritten; }
	}
	return result;
}

export function isRoutineSym(state: LiftState, sym: Symbol | null): boolean {
	return symSetContains(state.routines, sym);
}

export function routineInfoOf(state: LiftState, sym: Symbol | null): RoutineInfo | null {
	if (sym == null) return null;
	for (const info of state.routineInfos) {
		if (info.sym == sym) return info;
	}
	return null;
}

export function withoutRoutines(syms: SymSet, state: LiftState): SymSet {
	if (state.routines.items.length == 0) return syms;
	const out = createSymSet();
	for (const sym of syms.items) {
		if (!isRoutineSym(state, sym)) symSetAdd(out, sym);
	}
	return out;
}

// Wrap a raw function Identifier in a closure pair { fn: ident, env: null }.
// Reference parity: plain->closure wraps fn ptr in { ClP_0, ClE_0=NULL }.
export function wrapFnAsClosure(ident: Node, loc: SourceLocation): Node {
	const wrapKeys: string[] = [];
	wrapKeys.push("fn");
	wrapKeys.push("env");
	const wrapVals: Node[] = [];
	wrapVals.push(ident);
	wrapVals.push(makeNull(loc));
	const pair = makeObjectLiteral(wrapKeys, wrapVals, loc);
	pair.flags = pair.flags.incl(NodeFlag.Closure);
	return pair;
}

// Reference parity: create env declaration (hoisted) + initialization (at closure site) + closure pair.
// Split into declaration and init so the variable is visible at function scope (setupEnvVar + genCreateEnv).
// envDeclHoisted: let _envN = null (at function body start — just declares the variable)
// envInitStmt: _envN = { field1: val1, ... } (at closure site — initializes the env)
// closurePair: { fn: lifted, env: _envN }
export function makeEnvVarAndClosurePair(state: LiftState, envVarSym: Symbol, liftedSym: Symbol, envStructType: Type, captures: SymSet, capturedIdents: Node[], parentEnvVarSym: Symbol | null, parentEnvStructType: Type, loc: SourceLocation): { envDeclHoisted: Node, envInitStmt: Node, closurePair: Node } {
	const envKeys: string[] = [];
	const envValues: Node[] = [];
	// Up-chain field init: pointer to lexical parent env, or null at module-level.
	envKeys.push(UP_FIELD);
	if (parentEnvVarSym != null && parentEnvStructType != null) {
		const upInit = envVarRef(parentEnvVarSym, parentEnvStructType, loc);
		envValues.push(upInit);
	} else {
		envValues.push(makeNull(loc));
	}
	for (const sym of captures.items) {
		// Grandparent captures are not stored in this env (the struct built in
		// `liftClosure` skips them). They are reached via the `$up` chain walk
		// in `rewriteNode`.
		const field = envFieldIndex(state, envStructType, sym);
		if (field < 0) continue;
		envKeys.push(envStructType.typeNames[field]);
		const orig = findCapturedIdent(sym, capturedIdents);
		const isFnCapture = sym.symbolKind == SymbolKind.Function;
		const ident = makeTypedIdentResolved(sym, orig != null ? orig.nodeType : null, loc);
		let envVal: Node = ident;
		if (isFnCapture) {
			envVal = wrapFnAsClosure(ident, loc);
		}
		if (symSetContains(state.lastUseCaptures, sym)) {
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
	envVarSym.symbolType = refEnvType;
	const envDeclHoisted = makeVarDecl(envVarSym.name, nullInit, DeclKind.Let, loc);
	envDeclHoisted.resolvedSym = envVarSym;
	envDeclHoisted.nodeType = refEnvType;

	// Initialization at closure site: _envN = { field1: val1, ... }
	const envLhs = envVarRef(envVarSym, envStructType, loc);
	const envInitStmt = makeExprStmt(makeAssign(envLhs, envObj, loc), loc);

	// Closure pair: { fn: lifted, env: _envN }
	const closureKeys: string[] = [];
	closureKeys.push("fn");
	closureKeys.push("env");
	const closureValues: Node[] = [];
	closureValues.push(makeTypedIdentResolved(liftedSym, null, loc));
	const envRef = envVarRef(envVarSym, envStructType, loc);
	closureValues.push(envRef);
	const pair = makeObjectLiteral(closureKeys, closureValues, loc);
	pair.flags = pair.flags.incl(NodeFlag.Closure);
	return { envDeclHoisted, envInitStmt, closurePair: pair };
}

// Created before the body walk so `setupSharedEnv` casts `$up` to it: at the
// creation site `_envP` IS this env.
export interface PreCreatedEnv {
	envName: string;
	envVarSym: Symbol;
	envStructType: Type;
	fields: SymSet;
	fieldIdents: Node[];
}

export function createSnapshotPairEnv(captures: SymSet, capturedIdents: Node[], state: LiftState, loc: SourceLocation, parentType: Type | null): PreCreatedEnv {
	state.closureCounter += 1;
	const counter = state.closureCounter;
	const envName = `$Env_${state.currentFnName}_${counter}`;
	const envFieldSyms: Symbol[] = [];
	const envFieldTypes: string[] = [];
	const envResolvedTypes: Type[] = [];
	envFieldSyms.push(null as unknown as Symbol);
	envFieldTypes.push(parentType != null ? "" : "unknown");
	envResolvedTypes.push(parentType != null ? createRef(parentType) : createPtr(voidType()));
	for (const sym of captures.items) {
		const orig = findCapturedIdent(sym, capturedIdents);
		envFieldSyms.push(sym);
		envFieldTypes.push(lookupVarType(state, sym));
		if (orig != null && orig.nodeType != null) {
			envResolvedTypes.push(orig.nodeType);
		} else {
			const resolvedFallback = lookupVarResolvedType(state, sym);
			if (resolvedFallback != null) { envResolvedTypes.push(resolvedFallback); }
			else { envResolvedTypes.push(resolveSimpleTypeStr(lookupVarType(state, sym))); }
		}
	}
	const envDecl = makeEnvStruct(state, envName, envFieldSyms, envFieldTypes, envResolvedTypes, loc);
	state.envStructs.push(envDecl);
	return { envName, envVarSym: freshEnvVarSym(state.ctx, `_env${counter}_`, envDecl.nodeType!), envStructType: envDecl.nodeType!, fields: captures, fieldIdents: capturedIdents };
}

// ===== Shared Env Setup (reference parity: getEnvTypeForOwner + rawClosureCreation) =====
// Creates the shared env struct type and hoisted declaration for a function.
// Called after detectAllCaptures finds captures, before walkLiftBody.

export function setupSharedEnv(state: LiftState, allCaptures: SymSet, allCapturedIdents: Node[], loc: SourceLocation, entryChainNames: string[], entryChainTypes: Type[], ownLocals: SymSet | null, loopSyms: SymSet): void {
	const outerEnvName = entryChainNames.length > 0 ? entryChainNames[0] : "";
	const outerEnvStructType = entryChainTypes.length > 0 ? entryChainTypes[0] : (null as unknown as Type);
	const frameCaptures = createSymSet();
	for (const sym of withoutRoutines(allCaptures, state).items) {
		if (!symSetContains(loopSyms, sym)) symSetAdd(frameCaptures, sym);
	}
	const nestedReads = allCaptures;
	allCaptures = frameCaptures;
	state.sharedEnvActive = true;
	state.sharedEnvName = `$Env_${state.currentFnName}_shared`;
	state.sharedEnvVarSym = freshEnvVarSym(state.ctx, `_env_${state.currentFnName}_`, null);
	state.sharedEnvCapturedSyms = allCaptures;
	state.sharedEnvCapturedIdents = allCapturedIdents;
	const parentChainNames: string[] = [];
	const parentChainTypes: Type[] = [];
	for (const n of entryChainNames) parentChainNames.push(n);
	for (const t of entryChainTypes) parentChainTypes.push(t);
	state.sharedEnvChainNames = parentChainNames;
	state.sharedEnvChainTypes = parentChainTypes;

	// Build env struct fields from all captured vars
	const envFieldSyms: Symbol[] = [];
	const envFieldTypes: string[] = [];
	const envResolvedTypes: Type[] = [];
	const wiresUp = outerEnvName != "" && outerEnvStructType != null && readsAncestorEnv(state, nestedReads, ownLocals, parentChainTypes);
	if (wiresUp) {
		// Owning ref to the enclosing env: keeps the parent
		// frame alive while any nested closure holds this env, so the `$up` walk
		// never dangles for an escaping closure (DRC increfs on wire, ORC decrefs
		// on destroy). Chain is acyclic → no cycle, short → no destroy-recursion.
		envFieldSyms.push(null as unknown as Symbol);
		envFieldTypes.push("");
		envResolvedTypes.push(createRef(outerEnvStructType));
	}
	for (const sym of allCaptures.items) {
		// Ancestor capture: an enclosing env already stores this var. Do NOT add a
		// field here — it is read via the `$up` walk, never copied.
		let isAncestor = false;
		if (ownLocals == null || !symSetContains(ownLocals, sym)) {
			for (const at of parentChainTypes) { if (envHasField(state, at, sym)) { isAncestor = true; break; } }
		}
		if (isAncestor) continue;
		envFieldSyms.push(sym);
		envFieldTypes.push(lookupVarType(state, sym));
		const orig = findCapturedIdent(sym, state.sharedEnvCapturedIdents);
		if (orig != null && orig.nodeType != null) {
			envResolvedTypes.push(orig.nodeType);
		} else {
			const fallback = lookupVarResolvedType(state, sym);
			if (fallback != null) { envResolvedTypes.push(fallback); }
			else { envResolvedTypes.push(resolveSimpleTypeStr(lookupVarType(state, sym))); }
		}
	}
	const envDecl = makeEnvStruct(state, state.sharedEnvName, envFieldSyms, envFieldTypes, envResolvedTypes, loc);
	if (envDecl.nodeType != null) { state.sharedEnvStructType = envDecl.nodeType; }
	state.envStructs.push(envDecl);

	// Reference parity (rawClosureCreation): allocate env at function entry.
	// Use empty ObjectLiteral — codegen emits msAllocTyped with zeroed fields.
	// Params are copied into env fields via param-copy statements.
	// Local vars are written to env via all-refs rewrite (accessViaEnvVar).
	const emptyEnvObj = makeObjectLiteral([], [], loc);
	emptyEnvObj.nodeType = createRef(state.sharedEnvStructType);
	const refEnvType = createRef(state.sharedEnvStructType);
	state.sharedEnvVarSym.symbolType = refEnvType;
	const envDeclInit = makeVarDecl(state.sharedEnvVarSym.name, emptyEnvObj, DeclKind.Let, loc);
	envDeclInit.resolvedSym = state.sharedEnvVarSym;
	envDeclInit.nodeType = refEnvType;
	state.hoistedEnvDecls.push(envDeclInit);

	// Wire `$up` to the enclosing env. This closure's lifted body receives the
	// enclosing env as `_envP` (the closure pair carries it), so nested closures
	// walk `$up` to reach ancestor-frame slots.
	if (wiresUp) {
		const upLhs = makeMember(envVarDeref(state.sharedEnvVarSym!, state.sharedEnvStructType, loc), UP_FIELD, loc);
		upLhs.nodeType = createRef(outerEnvStructType);
		// Cast the void* enclosing-env param to Ref<outerEnv> so DRC sees an owning
		// ref copy and increfs the parent (balanced by ORC decref on env destroy).
		const upRhs = createNode(NodeKind.TypeAssertion, { asExpr: makeTypedIdentResolved(state.envParamSym, null, loc), asType: outerEnvName }, syntheticToken(loc));
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
	// Mirrors detectAllWalk's interestingVar check.
	for (const sym of allCaptures.items) {
		const isParam = symSetContains(state.currentParams, sym);
		const orig = findCapturedIdent(sym, state.sharedEnvCapturedIdents);
		const sk = sym.symbolKind;
		const isModLevel = (sk == SymbolKind.Variable || sk == SymbolKind.Temp || sk == SymbolKind.Parameter)
			? hasFlag(sym, SymbolFlag.Global)
			: isModuleLevelVar(state.ss, sym);
		if (isParam || isModLevel) {
			if (!envHasField(state, state.sharedEnvStructType, sym)) {
				reportTransformError(state.ctx, `internal: the shared env has no field for the captured '${sym.name}'`, loc);
				continue;
			}
			const lhs = makeMember(envVarDeref(state.sharedEnvVarSym!, state.sharedEnvStructType, loc), envFieldName(state, state.sharedEnvStructType, sym), loc);
			if (orig != null && orig.nodeType != null) {
				lhs.nodeType = orig.nodeType;
			}
			let rhs = makeTypedIdentResolved(sym, orig != null ? orig.nodeType : null, loc);
			// Module-level functions: wrap as msClosure { fn: func, env: null }
			const isFnCapture = sk == SymbolKind.Function;
			if (isFnCapture) {
				rhs = wrapFnAsClosure(rhs, loc);
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
		envVarSym: state.sharedEnvVarSym,
		envStructType: state.sharedEnvStructType,
		capturedSyms: allCaptures,
		chainNames: state.sharedEnvChainNames,
		chainTypes: state.sharedEnvChainTypes,
		envVarDecl: null as unknown as Node,
		snapshotOnly: false,
	});
}

// Create closure pair referencing the shared env variable.
export function makeClosurePairOnly(liftedSym: Symbol, envVarSym: Symbol, envStructType: Type, loc: SourceLocation): Node {
	const closureKeys: string[] = [];
	closureKeys.push("fn");
	closureKeys.push("env");
	const closureValues: Node[] = [];
	closureValues.push(makeTypedIdentResolved(liftedSym, null, loc));
	const envRef = envVarRef(envVarSym, envStructType, loc);
	closureValues.push(envRef);
	const pair = makeObjectLiteral(closureKeys, closureValues, loc);
	pair.flags = pair.flags.incl(NodeFlag.Closure);
	return pair;
}
