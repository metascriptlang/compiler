// Lambda Lifting — converts closures with captures into lifted functions + env
// structs. Two-pass design:
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

import { Node, NodeKind, DeclKind, SourceLocation, NodeFlag, SymbolKind, Symbol, createNode, ProgramData, BlockStmtData, FunctionDeclData, ArrowFunctionData, FunctionExprData, MethodDeclData, ConstructorDeclData, ExportDeclData, ClassDeclData, DecoratedDeclData, VariableDeclData, IfStmtData, WhileStmtData, DoWhileStmtData, TryCatchStmtData, SwitchStmtData, SwitchCaseData, ExprStmtData, ReturnStmtData, BinaryExprData, CallExprData, UnaryExprData, ObjectLiteralData, ArrayLiteralData, TestDeclData, Type, TypeKind } from "../../ast/node";
import {
	TransformContext, SymSet, createSymSet, symSetAdd, symSetContains, reportTransformError, mintSym,
} from "../context";
import { mapChildren, isFuncBoundary } from "../walker";
import { initializerHoldsClosure } from "../../ast/visitor";
import {
	makeTypedIdentResolved, makeMember, makeReturn, makeBlock, makeVarDecl, makeFnDecl, makeObjectLiteral,
	makeHiddenDeref, makeNull, makeDefaultValue, makeAssign, makeExprStmt, syntheticToken, resolveSimpleTypeStr,
} from "../util";
import { createPtr, createRef, voidType, isUnresolvedType } from "../../checker/types";
import { stmtCountAfter, firstStmtKindAfter, parseInput, getStmts, makeCtx } from "../testUtil";
import { checkProgram } from "../../checker/checkPass";
import {
	detectPass, detectionGetCaptures, detectionGetCapturedIdents, routineBindingSym, routineSyms, refsAnySym,
	isOnceLoop,
} from "./lambdaLiftingDetect";
import {
	ScopeStack, cloneScopeStack, pushFuncBoundary, popFuncBoundary, pushLoopBoundary, popLoopBoundary,
	defineVar, defineLocalRoutines, defineParams, isModuleLevelVar, isDirectParentVar,
} from "./lambdaLiftingScope";
import {
	isCaptureLastUse, computeLastUseCaptures, detectCaptures, refsRoutine, findCapturedIdent,
} from "./lambdaLiftingCaptures";
import {
	UP_FIELD, freshEnvParamSym, freshEnvVarSym, envVarRef, envVarDeref, PendingEnvRewrite, LoopEnv, LiftState,
	RoutineInfo, registerVarType, registerVarTypeResolved, lookupVarResolvedType, lookupVarType, typeToEnvStr,
	createLiftState, inEnclosingFnBody, hasEnclosingFnEnv, currentEnvAccessSym, preRegisterVarTypes,
	makeEnvStruct, envHasField, envFieldName, envFieldType, rewriteNode, applyActiveRewrites, isRoutineSym,
	routineInfoOf, withoutRoutines, wrapFnAsClosure, makeEnvVarAndClosurePair, PreCreatedEnv,
	createSnapshotPairEnv, setupSharedEnv, makeClosurePairOnly,
} from "./lambdaLiftingEnv";
import {
	frameLoopSyms, loopEnvOf, envChainFrom, frameChain, innermostLoopHolding, splitLoopCaptures, loopsHoldAll,
	openLoopEnv,
} from "./lambdaLiftingLoops";

function mintLiftedSym(state: LiftState, name: string): Symbol {
	return mintSym(state.ctx, SymbolKind.Function, name, null);
}

function bindLiftedSym(sym: Symbol, fnNode: Node): void {
	sym.symbolType = fnNode.nodeType!;
	sym.declNode = fnNode;
	sym.location = fnNode.location;
	fnNode.resolvedSym = sym;
}

// Override lifted function's param/return types from checker-resolved originalNodeType.
// Reference parity: the reference reuses original proc symbol (types already set). We create new node
// via makeFnDecl (string-based), then fix types from the original's concrete type.
function preserveResolvedTypes(fnNode: Node, originalNodeType: Type): void {
	if (originalNodeType == null || fnNode.nodeType == null || fnNode.nodeType.typeChildren == null) return;
	if (originalNodeType.typeChildren != null) {
		const origCount = originalNodeType.typeChildren.length;
		for (let pi = 0; pi < origCount; pi += 1) {
			if (pi < fnNode.nodeType.typeChildren.length
				&& !isUnresolvedType(originalNodeType.typeChildren[pi])) {
				fnNode.nodeType.typeChildren[pi] = originalNodeType.typeChildren[pi];
			}
		}
	}
	if (originalNodeType.typeReturn != null
		&& !isUnresolvedType(originalNodeType.typeReturn)) {
		fnNode.nodeType.typeReturn = originalNodeType.typeReturn;
	}
}

// Loop safety: captures inside a loop body are never last-use (back-edge
// repeats them).
// Shared-env safety: captures stored in an enclosing function's shared env
// outlive any single invocation of this closure — moving from them nulls the
// field for the next call. sharedActive is unreliable here (deactivated on
// descent into nested closures); sharedEnvCapturedSyms stays populated.
// Module-level safety: a global's readers are not confined to the statement
// list scanned here — later top-level statements, any function, and the module
// teardown destroy all read it, and the destructuring lowering leaves the temp
// it was sliced from alive alongside it. The analyzer's CFG sees those and
// rejects the move the scan would have claimed.
function computeLastUseCapturesForState(captures: SymSet, state: LiftState): void {
	if (state.insideLoop > 0) {
		state.lastUseCaptures = createSymSet();
		return;
	}
	const candidates = computeLastUseCaptures(captures, state.currentStmtIdx, state.currentStmts);
	const filtered = createSymSet();
	for (const sym of candidates.items) {
		if (isModuleLevelVar(state.ss, sym)) continue;
		if (symSetContains(state.sharedEnvCapturedSyms, sym)) continue;
		symSetAdd(filtered, sym);
	}
	state.lastUseCaptures = filtered;
}

// ===== Closure Lifting =====
// Create env struct + lifted function, return closure pair ObjectLiteral.
function rewriteRoutineSelfRefs(node: Node, routine: Symbol, closureOf: (ref: Node) => Node): Node {
	if (node == null) return node;
	if (node.kind == NodeKind.Identifier) {
		return node.resolvedSym == routine ? closureOf(node) : node;
	}
	if (isFuncBoundary(node)) return node;
	mapChildren(node, (child: Node): Node => rewriteRoutineSelfRefs(child, routine, closureOf));
	return node;
}

function ownEnvClosure(liftedSym: Symbol, selfEnvSym: Symbol, envStructType: Type, ref: Node): Node {
	const loc = ref.location;
	const pair = makeObjectLiteral(["fn", "env"], [makeTypedIdentResolved(liftedSym, null, loc), envVarRef(selfEnvSym, envStructType, loc)], loc);
	pair.flags = pair.flags.incl(NodeFlag.Closure);
	pair.nodeType = ref.nodeType;
	return pair;
}

function ownEnvDecl(selfEnvSym: Symbol, envParamSym: Symbol, envName: string, envStructType: Type, loc: SourceLocation): Node {
	const typedEnv = createNode(NodeKind.TypeAssertion, { asExpr: makeTypedIdentResolved(envParamSym, null, loc), asType: envName }, syntheticToken(loc));
	typedEnv.nodeType = createRef(envStructType);
	const decl = makeVarDecl(selfEnvSym.name, typedEnv, DeclKind.Const, loc);
	decl.resolvedSym = selfEnvSym;
	decl.nodeType = createRef(envStructType);
	return decl;
}

function collectRoutines(program: Node, state: LiftState): void {
	state.routines = routineSyms(program, 0, state.splitLoopLocals);
}

function envPointerTo(target: Type, envName: string, envType: Type, chainNames: string[], chainTypes: Type[], envParamSym: Symbol, loc: SourceLocation): Node | null {
	const own = createNode(NodeKind.TypeAssertion, { asExpr: makeTypedIdentResolved(envParamSym, null, loc), asType: envName }, syntheticToken(loc));
	if (envType == target) {
		own.nodeType = createRef(envType);
		return own;
	}
	own.nodeType = createPtr(envType);
	let access: Node = makeHiddenDeref(own, loc);
	access.nodeType = envType;
	for (let k = 0; k < chainTypes.length; k += 1) {
		const up = makeMember(access, UP_FIELD, loc);
		up.nodeType = createPtr(voidType());
		const next = createNode(NodeKind.TypeAssertion, { asExpr: up, asType: chainNames[k] }, syntheticToken(loc));
		if (chainTypes[k] == target) {
			next.nodeType = createRef(chainTypes[k]);
			return next;
		}
		next.nodeType = createPtr(chainTypes[k]);
		access = makeHiddenDeref(next, loc);
		access.nodeType = chainTypes[k];
	}
	return null;
}

function rewriteRoutineRefs(node: Node, state: LiftState, own: Symbol | null, closureOf: (ref: Node, info: RoutineInfo) => Node): Node {
	if (node == null) return node;
	if (node.kind == NodeKind.Identifier) {
		const sym = node.resolvedSym;
		if (sym == null || sym == own || !isRoutineSym(state, sym)) return node;
		if (symSetContains(state.liftOwnLocals, sym)) return node;
		const info = routineInfoOf(state, sym);
		if (info == null) {
			reportTransformError(state.ctx, `internal: no closure recorded for the routine '${sym.name}' at this use`, node.location);
			return node;
		}
		return closureOf(node, info);
	}
	if (isFuncBoundary(node)) return node;
	mapChildren(node, (child: Node): Node => rewriteRoutineRefs(child, state, own, closureOf));
	return node;
}

function routineClosure(liftedSym: Symbol, env: Node, ref: Node): Node {
	const pair = makeObjectLiteral(["fn", "env"], [makeTypedIdentResolved(liftedSym, null, ref.location), env], ref.location);
	pair.flags = pair.flags.incl(NodeFlag.Closure);
	pair.nodeType = ref.nodeType;
	return pair;
}

// Shared logic for lifting arrow functions and function expressions
// originalNodeType: resolved Type from checker (preserved through lifting)
function liftClosure(body: Node, paramSyms: Symbol[], paramTypes: string[], flags: string, returnType: string, captures: SymSet, state: LiftState, loc: SourceLocation, originalNodeType: Type, preEnv: PreCreatedEnv, envParamSym: Symbol, routine: Symbol | null, carrierIdx: number): Node {
	state.closureCounter += 1;
	const counter = state.closureCounter;
	const liftedSym = state.pendingLiftedSym != null ? state.pendingLiftedSym : mintLiftedSym(state, `$lifted_${state.currentFnName}_${counter}`);
	state.pendingLiftedSym = null;
	captures = withoutRoutines(captures, state);

	let envName: string;
	let envVarSym: Symbol;
	let envStructType: Type;

	const carrier = (preEnv == null && carrierIdx >= 0) ? state.loopEnvs[carrierIdx] : null;
	const useShared = carrier == null && preEnv == null && state.sharedEnvActive;

	if (carrier != null) {
		envName = carrier.envName;
		envVarSym = carrier.envVarSym;
		envStructType = carrier.envStructType;
	} else if (useShared) {
		// Shared env path (reference parity: ownerToType — all closures share one env)
		envName = state.sharedEnvName;
		envVarSym = state.sharedEnvVarSym!;
		envStructType = state.sharedEnvStructType;
	} else if (preEnv != null) {
		// Loop-site closure: the snapshot pair env was created pre-walk (so
		// `setupSharedEnv` could wire `$up` against its real type). Reuse it.
		envName = preEnv.envName;
		envVarSym = preEnv.envVarSym;
		envStructType = preEnv.envStructType;
	} else {
		// Per-closure env path — own env struct, fresh alloc at closure creation.
		// Used for module-level closures AND for closures inside loops (snapshot).
		envName = `$Env_${state.currentFnName}_${counter}`;
		envVarSym = freshEnvVarSym(state.ctx, `_env${counter}_`, null);

		const envFieldSyms: Symbol[] = [];
		const envFieldTypes: string[] = [];
		const envResolvedTypes: Type[] = [];
		// Up-chain field: pointer to lexical parent env. Wired to enclosing fn's
		// shared env at closure construction time. Drives chain walk in rewriteNode.
		envFieldSyms.push(null as unknown as Symbol);
		envFieldTypes.push("unknown");
		envResolvedTypes.push(createPtr(voidType()));
		for (const sym of captures.items) {
			// Grandparent captures (vars defined in a scope that is NOT the
			// immediate function frame and NOT module-level) are not stored in
			// this env. They live in the parent env and are reached via the
			// `$up` chain walk in `rewriteNode`.
			const orig = findCapturedIdent(sym, state.capturedIdents);
			const isGrandparent = !isDirectParentVar(state.ss, sym)
				&& !isModuleLevelVar(state.ss, sym);
			if (isGrandparent) continue;  // reached via chain walk
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
		envStructType = envDecl.nodeType!;
		state.envStructs.push(envDecl);
	}

	// Rewrite closure body: captured vars → (*((EnvType*)_envP)).field
	// For shared env, rewrite ALL captured bindings (env has fields for all captures)
	const rewriteCaptures = useShared ? state.sharedEnvCapturedSyms : captures;
	// Ancestor chain for `$up` walk (immediate parent first). A shared-env closure
	// walks the current shared env's own chain; a per-closure env prepends the
	// enclosing shared env (its `$up` target) then that env's chain.
	let rwChainNames: string[] = [];
	let rwChainTypes: Type[] = [];
	if (carrier != null) {
		const chain = envChainFrom(state.loopEnvs, carrierIdx - 1, state.sharedEnvName, state.sharedEnvStructType, state.sharedEnvChainNames, state.sharedEnvChainTypes);
		rwChainNames = chain.names;
		rwChainTypes = chain.types;
	} else if (useShared) {
		for (const n of state.sharedEnvChainNames) rwChainNames.push(n);
		for (const t of state.sharedEnvChainTypes) rwChainTypes.push(t);
	} else {
		const chain = envChainFrom(state.loopEnvs, carrierIdx, state.sharedEnvName, state.sharedEnvStructType, state.sharedEnvChainNames, state.sharedEnvChainTypes);
		rwChainNames = chain.names;
		rwChainTypes = chain.types;
	}
	let selfEnvDecl: Node | null = null;
	if (routine != null && refsRoutine(body, routine)) {
		const selfEnvSym = freshEnvVarSym(state.ctx, `_self${counter}_`, envStructType);
		const selfEnvType = envStructType;
		selfEnvDecl = ownEnvDecl(selfEnvSym, envParamSym, envName, envStructType, loc);
		rewriteRoutineSelfRefs(body, routine, (ref: Node): Node => ownEnvClosure(liftedSym, selfEnvSym, selfEnvType, ref));
	}
	const reachDecls: Node[] = [];
	if (state.routines.items.length > 0) {
		const reachTypes: Type[] = [];
		const reachSyms: Symbol[] = [];
		body = rewriteRoutineRefs(body, state, routine, (ref: Node, info: RoutineInfo): Node => {
			const target = info.envStructType;
			if (target == null) return routineClosure(info.liftedSym, makeNull(ref.location), ref);
			let idx = -1;
			for (let k = 0; k < reachTypes.length; k += 1) {
				if (reachTypes[k] == target) idx = k;
			}
			if (idx < 0) {
				const pointer = envPointerTo(target, envName, envStructType, rwChainNames, rwChainTypes, envParamSym, loc);
				if (pointer == null) {
					reportTransformError(state.ctx, `internal: the env of '${info.sym.name}' is not reachable from this closure`, ref.location);
					return ref;
				}
				const reachSym = freshEnvVarSym(state.ctx, `_reach${counter}_${reachTypes.length}_`, target);
				const decl = makeVarDecl(reachSym.name, pointer, DeclKind.Const, loc);
				decl.resolvedSym = reachSym;
				decl.nodeType = createRef(target);
				reachDecls.push(decl);
				reachTypes.push(target);
				reachSyms.push(reachSym);
				idx = reachTypes.length - 1;
			}
			return routineClosure(info.liftedSym, envVarRef(reachSyms[idx], target, ref.location), ref);
		});
	}
	let rewrittenBody = rewriteNode(state, body, rewriteCaptures, envName, envStructType, rwChainNames, rwChainTypes, envParamSym);
	if (rewrittenBody == null) {
		rewrittenBody = makeBlock([], loc);
	} else if (rewrittenBody.kind != NodeKind.BlockStmt) {
		rewrittenBody = makeBlock([makeReturn(rewrittenBody, loc)], loc);
	}
	if (reachDecls.length > 0) {
		const bd = rewrittenBody.data as BlockStmtData;
		bd.statements = prependHoistedEnvDecls(reachDecls, bd.statements);
	}
	if (selfEnvDecl != null) {
		const bd = rewrittenBody.data as BlockStmtData;
		bd.statements = prependHoistedEnvDecls([selfEnvDecl], bd.statements);
	}

	// Create lifted function
	const liftedParams: Symbol[] = [];
	const liftedParamTypes: string[] = [];
	for (const ps of paramSyms) { liftedParams.push(ps); }
	for (const t of paramTypes) { liftedParamTypes.push(t); }
	liftedParams.push(envParamSym);
	liftedParamTypes.push("void*");
	const fnNode = makeFnDecl(liftedSym.name, liftedParams, liftedParamTypes, rewrittenBody, flags, returnType, loc);
	preserveResolvedTypes(fnNode, originalNodeType);
	bindLiftedSym(liftedSym, fnNode);
	state.liftedFunctions.push(fnNode);

	if (carrier != null || useShared) {
		// Shared env: env initialized at function entry, all-refs rewrite already active.
		// No pendingEnvRewrites needed — setupSharedEnv activated the rewrite.
		const sharedPair = makeClosurePairOnly(liftedSym, envVarSym, envStructType, loc);
		// Load-bearing for DRC: the analyzer classifies a fresh closure value (→ RcKind.Closure) by
		// nodeType; without it ensureDestructionIfNeeded bails on null and the closure-pair temporary
		// passed as a non-sink call argument is never destroyed → its captured env leaks.
		sharedPair.nodeType = originalNodeType;
		return sharedPair;
	} else {
		// Per-closure env: each closure gets its own env declaration + init.
		// Up-chain parent: per-closure env's `$up` points to enclosing fn's
		// shared env. Use `currentEnvAccessSym` to pick the right access form
		// for the surrounding scope (named var in fn body, `_envP` in nested
		// closure body).
		const parentLoop = carrierIdx >= 0 ? state.loopEnvs[carrierIdx] : null;
		const parentEnvVarSym = parentLoop != null ? parentLoop.envVarSym : currentEnvAccessSym(state);
		const parentEnvStructType = parentLoop != null ? parentLoop.envStructType : (hasEnclosingFnEnv(state) ? state.sharedEnvStructType : (null as unknown as Type));
		const initCaptures = preEnv != null ? preEnv.fields : captures;
		const initIdents = preEnv != null ? preEnv.fieldIdents : state.capturedIdents;
		const envPair = makeEnvVarAndClosurePair(state, envVarSym, liftedSym, envStructType, initCaptures, initIdents, parentEnvVarSym, parentEnvStructType, loc);
		state.hoistedEnvDecls.push(envPair.envDeclHoisted);
		state.pendingEnvRewrites.push({
			envVarSym, envStructType,
			capturedSyms: initCaptures,
			chainNames: [] as string[],
			chainTypes: [] as Type[],
			envVarDecl: envPair.envInitStmt,
			snapshotOnly: preEnv != null,
		});
		// Load-bearing for DRC (see the shared-env branch): nodeType lets the analyzer classify +
		// destroy the fresh closure-pair temporary so its captured env doesn't leak as a call arg.
		envPair.closurePair.nodeType = originalNodeType;
		return envPair.closurePair;
	}
}

function liftArrow(node: Node, captures: SymSet, state: LiftState, preEnv: PreCreatedEnv, envParamSym: Symbol, routine: Symbol | null, carrierIdx: number): Node {
	const d = node.data as ArrowFunctionData;
	return liftClosure(d.arrowBody, node.paramSyms!, d.arrowParamTypes, d.arrowFlags, d.arrowReturnType, captures, state, node.location, node.nodeType!, preEnv, envParamSym, routine, carrierIdx);
}

function liftFuncExpr(node: Node, captures: SymSet, state: LiftState, preEnv: PreCreatedEnv, envParamSym: Symbol, routine: Symbol | null, carrierIdx: number): Node {
	const d = node.data as FunctionExprData;
	return liftClosure(d.funcExprBody, node.paramSyms!, d.funcExprParamTypes, d.funcExprFlags, d.funcExprReturnType, captures, state, node.location, node.nodeType!, preEnv, envParamSym, routine, carrierIdx);
}

// Non-capturing lift: module-level FunctionDecl + closure pair with env=null.
// Reference parity: plain->closure conversion wraps fn ptr
// in { .ClP_0 = fn, .ClE_0 = NULL }. We emit the same via NF_CLOSURE ObjectLiteral.
// originalNodeType: resolved Type from checker (symbol type preserved)
function liftNonCapturing(body: Node, paramSyms: Symbol[], paramTypes: string[], flags: string, returnType: string, state: LiftState, loc: SourceLocation, originalNodeType: Type, routine: Symbol | null): Node {
	state.closureCounter += 1;
	const liftedSym = state.pendingLiftedSym != null ? state.pendingLiftedSym : mintLiftedSym(state, `$fn_${state.currentFnName}_${state.closureCounter}`);
	state.pendingLiftedSym = null;
	if (routine != null) {
		rewriteRoutineSelfRefs(body, routine, (ref: Node): Node => {
			const selfFn = makeTypedIdentResolved(liftedSym, null, ref.location);
			selfFn.nodeType = originalNodeType;
			const pair = wrapFnAsClosure(selfFn, ref.location);
			pair.nodeType = ref.nodeType;
			return pair;
		});
	}
	let liftedBody = body;
	if (liftedBody.kind != NodeKind.BlockStmt) {
		liftedBody = makeBlock([makeReturn(liftedBody, loc)], loc);
	}
	const fnNode = makeFnDecl(liftedSym.name, paramSyms, paramTypes, liftedBody, flags, returnType, loc);
	preserveResolvedTypes(fnNode, originalNodeType);
	bindLiftedSym(liftedSym, fnNode);
	state.liftedFunctions.push(fnNode);
	// Wrap in closure pair { fn: lifted, env: null } so codegen emits
	// (msClosure){ .fn = (void*)ptr, .env = NULL } instead of raw function pointer.
	// IMPORTANT: set the lifted Identifier's nodeType to the original arrow's
	// Function type. genClosureCall (in C codegen) reads this via
	// getCalleeFuncType to emit correct type casts (return type + param
	// types) for `((RetType(*)(Params))fn)(args)`. Without this, the cast
	// defaults to `void(*)(void)` and IIFE fails to compile.
	const fnIdent = makeTypedIdentResolved(liftedSym, null, loc);
	if (originalNodeType != null && originalNodeType.kind == TypeKind.Function) {
		fnIdent.nodeType = originalNodeType;
	}
	const pair = wrapFnAsClosure(fnIdent, loc);
	pair.nodeType = originalNodeType;
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
		if (rewrite.envVarDecl != null) {
			// Apply already-active rewrites to the init statement so that any
			// captured-var references inside it resolve to the enclosing env
			// (typically the shared function-scope env). Without this, a
			// snapshot init `_env1 = { j: j }` would emit a bare `j` ident
			// that has no C-level declaration when `j` is actually a shared-env
			// field. Skip self — the newly-pushed rewrite isn't in activeEnvRewrites yet.
			let decl = rewrite.envVarDecl;
			if (state.activeEnvRewrites.length > 0) {
				decl = applyActiveRewrites(state, decl, state.activeEnvRewrites);
			}
			result.push(decl);
		}
		if (!rewrite.snapshotOnly) state.activeEnvRewrites.push(rewrite);
		pi += 1;
	}
	// Truncate processed entries
	if (pendingBefore == 0) {
		state.pendingEnvRewrites = [];
	} else {
		const kept: PendingEnvRewrite[] = [];
		let ki = 0;
		while (ki < pendingBefore) { kept.push(state.pendingEnvRewrites[ki]); ki += 1; }
		state.pendingEnvRewrites = kept;
	}
}

function walkLiftStmtList(stmts: Node[], state: LiftState, isTopLevel: boolean): Node[] {
	if (!isTopLevel) defineLocalRoutines(state.ss, stmts);
	const result: Node[] = [];
	let si = 0;
	while (si < stmts.length) {
		state.currentStmtIdx = si;
		// Apply active rewrites BEFORE walk — rewriteOuterRef skips function bodies
		// (isFuncBoundary), so capture detection in subsequent closures isn't confused
		// by rewritten refs.
		if (state.activeEnvRewrites.length > 0) {
			stmts[si] = applyActiveRewrites(state, stmts[si], state.activeEnvRewrites);
		}
		if (!isTopLevel) promiseRun(state, stmts, si);
		const pendingBefore = state.pendingEnvRewrites.length;
		walkLift(stmts[si], state);
		// Check if liftClosure queued new env rewrites
		if (state.pendingEnvRewrites.length > pendingBefore) {
			drainPendingRewrites(state, pendingBefore, result);
		}
		if (stmts[si].kind == NodeKind.VariableDecl) {
			const vd = stmts[si].data as VariableDeclData;
			const declSym = stmts[si].resolvedSym;
			const loopEnv = loopEnvOf(state, declSym);
			if (loopEnv != null && vd.initializer == null) {
				stmts[si] = makeBlock([], stmts[si].location);
			} else if (loopEnv != null) {
				const stmtLoc = stmts[si].location;
				const lhs = makeMember(envVarDeref(loopEnv.envVarSym, loopEnv.envStructType, stmtLoc), envFieldName(state, loopEnv.envStructType, declSym!), stmtLoc);
				const ft = envFieldType(state, loopEnv.envStructType, declSym!);
				lhs.nodeType = ft != null ? ft : stmts[si].nodeType;
				stmts[si] = makeExprStmt(makeAssign(lhs, vd.initializer, stmtLoc), stmtLoc);
			}
		}
		// Reference parity (accessViaEnvVar): replace captured VarDecl with env field assignment.
		// Create a NEW node instead of mutating in-place (C union layout forbids kind change).
		// walkLift already processed the initializer; we just replace the stmt in the list.
		//
		// `hasEnclosingFnEnv` (sharedEnvName !== "") rather than `sharedEnvActive`:
		// `tryLiftClosure`'s `saveSharedEnv` flips active off when walking
		// nested-arrow bodies but keeps the enclosing fn's env identifiers
		// intact, so VarDecls inside such bodies still need rewriting.
		if (hasEnclosingFnEnv(state) && stmts[si].kind == NodeKind.VariableDecl
			&& symSetContains(state.sharedEnvCapturedSyms, stmts[si].resolvedSym)) {
			const vd = stmts[si].data as VariableDeclData;
			const declSym = stmts[si].resolvedSym!;
			if (!envHasField(state, state.sharedEnvStructType, declSym)) {
				reportTransformError(state.ctx, `internal: the shared env has no field for the captured '${declSym.name}'`, stmts[si].location);
			} else {
				// VarDecl of a captured var: rewrite to env field assignment.
				// Access form depends on lexical context — see comments on
				// `inEnclosingFnBody` (true → named hoisted var; false → `_envP`).
				const stmtLoc = stmts[si].location;
				let envAccess: Node;
				if (inEnclosingFnBody(state)) {
					envAccess = envVarDeref(state.sharedEnvVarSym!, state.sharedEnvStructType, stmtLoc);
				} else {
					const envIdent = makeTypedIdentResolved(state.envParamSym, null, stmtLoc);
					const cast = createNode(NodeKind.TypeAssertion, { asExpr: envIdent, asType: state.sharedEnvName }, syntheticToken(stmtLoc));
					cast.nodeType = createPtr(state.sharedEnvStructType);
					envAccess = makeHiddenDeref(cast, stmtLoc);
					envAccess.nodeType = state.sharedEnvStructType;
				}
				const lhs = makeMember(envAccess, envFieldName(state, state.sharedEnvStructType, declSym), stmtLoc);
				if (stmts[si].nodeType != null) lhs.nodeType = stmts[si].nodeType;
				const init = (vd.initializer != null) ? vd.initializer : makeDefaultValue(declSym.symbolType, stmtLoc);
				stmts[si] = makeExprStmt(makeAssign(lhs, init, stmtLoc), stmtLoc);
			}
		}
		if (!isTopLevel && stmts[si].kind == NodeKind.FunctionDecl) {
			state.liftedFunctions.push(stmts[si]);
		} else {
			result.push(stmts[si]);
		}
		si += 1;
	}
	return result;
}

function walkLift(node: Node, state: LiftState): void {
	if (node == null) return;
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
		NodeKind.MacroDecl => {},
		NodeKind.FunctionDecl => {
			const d = node.data as FunctionDeclData;
			// Generic template: never lifted. Monomorphization (instantiate.ms strips the `gen:`
			// flag) emits concrete instances, which ARE lifted. Lifting the T-unbound template only
			// manufactures orphan closures (void* env, unlowered methods) that codegen later drops.
			if (d.fnFlags.indexOf("gen:") >= 0) return;
			const savedName = state.currentFnName;
			if (d.fnName != "") {
				state.currentFnName = d.fnName;
				defineVar(state.ss, node.resolvedSym, d.fnName);
				// Reference parity: captured function refs → closure type
				registerVarType(state, node.resolvedSym, "msClosure");
			}
			// Push function boundary, define params + register types for env field resolution
			// Prefer resolved types from nodeType (handles type aliases like NumFn → Function)
			pushFuncBoundary(state.ss);
			const savedParams = state.currentParams;
			const savedActiveRewrites = state.activeEnvRewrites;
			state.currentParams = createSymSet();
			state.activeEnvRewrites = [];
			const fnType = node.nodeType;
			let pi = 0;
			while (pi < d.params.length) {
				const paramSym = node.paramSyms != null && pi < node.paramSyms.length ? node.paramSyms[pi] : null;
				defineVar(state.ss, paramSym, d.params[pi]);
				if (paramSym != null) symSetAdd(state.currentParams, paramSym);
				let paramTypeStr = (pi < d.fnParamTypes.length) ? d.fnParamTypes[pi] : "";
				// Reference parity: use resolved type from checker for env field typing
				if (fnType != null && fnType.typeChildren != null && pi < fnType.typeChildren.length) {
					const pt = fnType.typeChildren[pi];
					if (pt != null) {
						const derived = typeToEnvStr(pt);
						if (derived != "") {
							paramTypeStr = derived;
						}
					}
				}
				if (paramTypeStr != "") {
					registerVarType(state, paramSym, paramTypeStr);
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
			const fnChain = frameChain(state);
			const fnLoopSyms = frameLoopSyms(d.fnBody, state);
			walkLiftBody(d.fnBody, state, () => {
				if (allCaptures.items.length > 0) {
					setupSharedEnv(state, allCaptures, allCapturedIdents, fnLoc, fnChain.names, fnChain.types, null, fnLoopSyms);
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
			const boundBeforeInitializer = initializerHoldsClosure(d.initializer);
			if (boundBeforeInitializer) defineVar(state.ss, node.resolvedSym, d.declName);
			state.pendingRoutine = routineBindingSym(node);
			d.initializer = walkOrLift(d.initializer, state);
			state.pendingRoutine = null;
			if (!boundBeforeInitializer) defineVar(state.ss, node.resolvedSym, d.declName);
			if (d.declType != "") {
				registerVarType(state, node.resolvedSym, d.declType);
			} else if (node.nodeType != null) {
				// Reference parity: use resolved type from checker when no annotation
				const derived = typeToEnvStr(node.nodeType);
				if (derived != "") {
					registerVarTypeResolved(state, node.resolvedSym, derived, node.nodeType);
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
			pushLoopBoundary(state.ss);
			const savedWhileRewrites = state.activeEnvRewrites;
			const whileBodyRewrites: PendingEnvRewrite[] = [];
			for (const rw of savedWhileRewrites) whileBodyRewrites.push(rw);
			state.activeEnvRewrites = whileBodyRewrites;
			const openLoops = state.loopEnvs.length;
			d.whileBody = openLoopEnv(d.whileBody, state, node.location);
			walkLift(d.whileBody, state);
			if (state.loopEnvs.length > openLoops) state.loopEnvs.pop();
			state.activeEnvRewrites = savedWhileRewrites;
			popLoopBoundary(state.ss);
			state.insideLoop -= 1;
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			state.insideLoop += 1;
			pushLoopBoundary(state.ss);
			const savedDoRewrites = state.activeEnvRewrites;
			const doBodyRewrites: PendingEnvRewrite[] = [];
			for (const rw of savedDoRewrites) doBodyRewrites.push(rw);
			state.activeEnvRewrites = doBodyRewrites;
			const openLoops = state.loopEnvs.length;
			if (!isOnceLoop(node)) d.doBody = openLoopEnv(d.doBody, state, node.location);
			walkLift(d.doBody, state);
			if (state.loopEnvs.length > openLoops) state.loopEnvs.pop();
			state.activeEnvRewrites = savedDoRewrites;
			popLoopBoundary(state.ss);
			state.insideLoop -= 1;
			d.doCondition = walkOrLift(d.doCondition, state);
		},
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			walkLift(d.tryBody, state);
			if (d.catchName != "") {
				defineVar(state.ss, node.resolvedSym, d.catchName);
			}
			walkLift(d.catchBody, state);
			walkLift(d.finallyBody, state);
		},
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			d.switchDisc = walkOrLift(d.switchDisc, state);
			for (const c of d.switchCases) {
				walkLift(c, state);
			}
		},
		NodeKind.SwitchCase => {
			const d = node.data as SwitchCaseData;
			for (let t = 0; t < d.caseTests.length; t += 1) d.caseTests[t] = walkOrLift(d.caseTests[t], state);
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
			if (d.className != "") {
				defineVar(state.ss, node.resolvedSym, d.className);
			}
			for (const member of d.classBody) {
				walkLift(member, state);
			}
		},
		NodeKind.MethodDecl => {
			const d = node.data as MethodDeclData;
			if (d.methodFlags.indexOf("gen:") >= 0) return;
			pushFuncBoundary(state.ss);
			defineParams(state.ss, node.paramSyms, d.methodParams);
			walkLiftBody(d.methodBody, state);
			popFuncBoundary(state.ss);
		},
		NodeKind.ConstructorDecl => {
			const d = node.data as ConstructorDeclData;
			pushFuncBoundary(state.ss);
			defineParams(state.ss, node.paramSyms, d.ctorParams);
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
			state.currentParams = createSymSet();
			state.activeEnvRewrites = [];
			const savedShared = saveSharedEnv(state);
			const allCaptures = detectionGetCaptures(state.detection, node);
			const allCapturedIdents = detectionGetCapturedIdents(state.detection, node);
			if (allCaptures.items.length > 0) {
				preRegisterVarTypes(d.testBody, state);
			}
			const testLoc = node.location;
			const testChain = frameChain(state);
			const testLoopSyms = frameLoopSyms(d.testBody, state);
			walkLiftBody(d.testBody, state, () => {
				if (allCaptures.items.length > 0) {
					setupSharedEnv(state, allCaptures, allCapturedIdents, testLoc, testChain.names, testChain.types, null, testLoopSyms);
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
			const calleeWasArrow = d.callee.kind == NodeKind.ArrowFunction
				|| d.callee.kind == NodeKind.FunctionExpr;
			d.callee = walkOrLift(d.callee, state);
			// After lifting an arrow callee, the call must use the closure-call
			// convention: `callee.fn(args, callee.env)`. closureCallMarker only
			// detects MemberExpr-typed callees with Function nodeType, so it'd
			// miss our ObjectLiteral closure-pair callee. Mark it here.
			if (calleeWasArrow && d.callee.kind == NodeKind.ObjectLiteral) {
				d.isDirectCall = false;
			}
			let i = 0;
			while (i < d.arguments.length) {
				const arg = d.arguments[i];
				if (arg.kind == NodeKind.ArrowFunction || arg.kind == NodeKind.FunctionExpr) {
					const lifted = tryLiftClosure(arg, state);
					if (lifted.kind != arg.kind) {
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
		// Uniform child traversal: any
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
	if (hoisted.length == 0) return stmts;
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
	// Loop depth is per-function-frame; every call site of this helper is a frame boundary.
	const savedInsideLoop = state.insideLoop;
	const savedLoopMarkers = state.ss.loopMarkers;
	state.insideLoop = 0;
	state.ss.loopMarkers = [];
	state.hoistedEnvDecls = [];
	preWalk();
	walkLift(body, state);
	if (state.hoistedEnvDecls.length > 0 && body != null && body.kind == NodeKind.BlockStmt) {
		const bd = body.data as BlockStmtData;
		bd.statements = prependHoistedEnvDecls(state.hoistedEnvDecls, bd.statements);
	}
	state.hoistedEnvDecls = savedHoisted;
	state.insideLoop = savedInsideLoop;
	state.ss.loopMarkers = savedLoopMarkers;
}

// Walk a node, lifting closures if it's an ArrowFunction/FunctionExpr with captures.
// Returns the (possibly replaced) node.
function walkOrLift(node: Node | null, state: LiftState): Node {
	if (node == null) return null as unknown as Node;
	if (node.kind == NodeKind.ArrowFunction || node.kind == NodeKind.FunctionExpr) {
		return tryLiftClosure(node, state);
	}
	walkLift(node, state);
	return node;
}

// Shared env state snapshot — saved/restored when entering closure bodies.
interface SharedEnvSnapshot {
	active: boolean;
	name: string;
	varSym: Symbol | null;
	structType: Type;
	capturedSyms: SymSet;
	capturedIdents: Node[];
	chainNames: string[];
	chainTypes: Type[];
	loopEnvs: LoopEnv[];
}

function currentSharedEnv(state: LiftState): SharedEnvSnapshot {
	return {
		active: state.sharedEnvActive,
		name: state.sharedEnvName,
		varSym: state.sharedEnvVarSym,
		structType: state.sharedEnvStructType,
		capturedSyms: state.sharedEnvCapturedSyms,
		capturedIdents: state.sharedEnvCapturedIdents,
		chainNames: state.sharedEnvChainNames,
		chainTypes: state.sharedEnvChainTypes,
		loopEnvs: state.loopEnvs,
	};
}

function saveSharedEnv(state: LiftState): SharedEnvSnapshot {
	const snap = currentSharedEnv(state);
	state.sharedEnvActive = false;
	state.loopEnvs = [];
	return snap;
}

function restoreSharedEnv(state: LiftState, snap: SharedEnvSnapshot): void {
	state.sharedEnvActive = snap.active;
	state.sharedEnvName = snap.name;
	state.sharedEnvVarSym = snap.varSym;
	state.sharedEnvStructType = snap.structType;
	state.sharedEnvCapturedSyms = snap.capturedSyms;
	state.sharedEnvCapturedIdents = snap.capturedIdents;
	state.sharedEnvChainNames = snap.chainNames;
	state.sharedEnvChainTypes = snap.chainTypes;
	state.loopEnvs = snap.loopEnvs;
}

// Walk + lift one capturing closure (Arrow or FunctionExpr). Drives the
// per-closure env setup: bumps the closure counter so this closure's shared
// env gets a unique name, calls `setupSharedEnv` in walkLiftBody's preWalk
// when detection found nested-capture refs, then restores currentFnName /
// currentParams.
//
function collectOwnDeclSyms(node: Node, acc: SymSet): void {
	if (node == null) return;
	match (node.kind) {
		NodeKind.VariableDecl => {
			if (node.resolvedSym != null) symSetAdd(acc, node.resolvedSym);
			collectOwnDeclSyms((node.data as VariableDeclData).initializer, acc);
		},
		NodeKind.FunctionDecl | NodeKind.FunctionExpr | NodeKind.ArrowFunction | NodeKind.MethodDecl | NodeKind.ConstructorDecl => {},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			for (const s of d.statements) { collectOwnDeclSyms(s, acc); }
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			collectOwnDeclSyms(d.consequent, acc);
			collectOwnDeclSyms(d.alternate, acc);
		},
		NodeKind.WhileStmt => { collectOwnDeclSyms((node.data as WhileStmtData).whileBody, acc); },
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			collectOwnDeclSyms(d.tryBody, acc);
			collectOwnDeclSyms(d.catchBody, acc);
			collectOwnDeclSyms(d.finallyBody, acc);
		},
		_ => {},
	};
}

interface LoopPlan {
	carrierIdx: number;
	preSyms: SymSet | null;
	preIdents: Node[];
	preParent: Type | null;
}

function planLoopEnv(state: LiftState, body: Node, ss: ScopeStack, routine: Symbol | null, ownCaptures: SymSet, ownCapturedIdents: Node[], ownLocals: SymSet, shared: SharedEnvSnapshot): LoopPlan {
	const plan: LoopPlan = { carrierIdx: -1, preSyms: null, preIdents: [], preParent: null };
	const enclosingLoops = shared.loopEnvs;
	if (enclosingLoops.length == 0 && state.insideLoop == 0) return plan;
	const directIdents: Node[] = [];
	const direct = detectCaptures(body, cloneScopeStack(ss), directIdents, routine, null);
	const fullSet = createSymSet();
	const fullIdents: Node[] = [];
	for (const ds of withoutRoutines(direct, state).items) { symSetAdd(fullSet, ds); }
	for (const di of directIdents) { fullIdents.push(di); }
	for (const os of withoutRoutines(ownCaptures, state).items) {
		if (symSetContains(ownLocals, os)) continue;
		if (!symSetContains(fullSet, os)) {
			symSetAdd(fullSet, os);
			const oi = findCapturedIdent(os, ownCapturedIdents);
			if (oi != null) { fullIdents.push(oi); }
		}
	}
	let carrierIdx = innermostLoopHolding(enclosingLoops, fullSet);
	for (const ri of directIdents) {
		const info = routineInfoOf(state, ri.resolvedSym);
		if (info == null || info.envStructType == null) continue;
		for (let li = enclosingLoops.length - 1; li > carrierIdx; li -= 1) {
			if (enclosingLoops[li].envStructType == info.envStructType) carrierIdx = li;
		}
	}
	for (const ri of ownCapturedIdents) {
		const info = routineInfoOf(state, ri.resolvedSym);
		if (info == null || info.envStructType == null) continue;
		for (let li = enclosingLoops.length - 1; li > carrierIdx; li -= 1) {
			if (enclosingLoops[li].envStructType == info.envStructType) carrierIdx = li;
		}
	}
	if (!shared.active) {
		if (carrierIdx >= 0 && !loopsHoldAll(enclosingLoops, carrierIdx, fullSet)) carrierIdx = -1;
		if (carrierIdx < 0 && state.insideLoop > 0 && fullSet.items.length > 0) {
			plan.preSyms = fullSet;
			plan.preIdents = fullIdents;
		}
	} else {
		const snap = splitLoopCaptures(fullSet, fullIdents, enclosingLoops, state.splitLoopLocals);
		if (snap.syms.items.length > 0) {
			plan.preSyms = snap.syms;
			plan.preIdents = snap.idents;
			plan.preParent = carrierIdx >= 0 ? enclosingLoops[carrierIdx].envStructType : shared.structType;
		}
	}
	plan.carrierIdx = carrierIdx;
	return plan;
}

interface RoutineEnv {
	captures: boolean;
	known: boolean;
	envStructType: Type | null;
}

function routineEnv(state: LiftState, body: Node, ss: ScopeStack, routine: Symbol, ownCaptures: SymSet, plan: LoopPlan, shared: SharedEnvSnapshot): RoutineEnv {
	const pre = detectCaptures(body, cloneScopeStack(ss), [], routine, null);
	const captures = pre.items.length > 0 || ownCaptures.items.length > 0;
	if (!captures) return { captures, known: true, envStructType: null };
	if (plan.preSyms == null && plan.carrierIdx >= 0) return { captures, known: true, envStructType: shared.loopEnvs[plan.carrierIdx].envStructType };
	if (plan.preSyms == null && shared.active) return { captures, known: true, envStructType: shared.structType };
	return { captures, known: false, envStructType: null };
}

function routineFn(state: LiftState, stmt: Node): Node | null {
	if (stmt.kind != NodeKind.VariableDecl || !isRoutineSym(state, routineBindingSym(stmt))) return null;
	return (stmt.data as VariableDeclData).initializer;
}

function fnParamsAndBody(fn: Node): { params: string[], body: Node } {
	if (fn.kind == NodeKind.ArrowFunction) {
		const d = fn.data as ArrowFunctionData;
		return { params: d.arrowParams, body: d.arrowBody };
	}
	const d = fn.data as FunctionExprData;
	return { params: d.funcExprParams, body: d.funcExprBody };
}

function promiseRun(state: LiftState, stmts: Node[], from: number): void {
	if (routineFn(state, stmts[from]) == null || (from > 0 && routineFn(state, stmts[from - 1]) != null)) return;
	let end = from;
	while (end < stmts.length && routineFn(state, stmts[end]) != null) end += 1;
	let forward = false;
	for (let k = from; k < end && !forward; k += 1) {
		const later: Symbol[] = [];
		for (let m = k + 1; m < end; m += 1) later.push(stmts[m].resolvedSym!);
		forward = refsAnySym(routineFn(state, stmts[k]), later);
	}
	if (!forward) return;
	const shared = currentSharedEnv(state);
	let changed = true;
	while (changed) {
		changed = false;
		for (let k = from; k < end; k += 1) {
			const sym = stmts[k].resolvedSym!;
			const fn = routineFn(state, stmts[k])!;
			const pb = fnParamsAndBody(fn);
			const ss = cloneScopeStack(state.ss);
			pushFuncBoundary(ss);
			defineParams(ss, fn.paramSyms, pb.params);
			const ownCaptures = detectionGetCaptures(state.detection, fn);
			const ownLocals = createSymSet();
			if (fn.paramSyms != null) {
				for (const p of fn.paramSyms) symSetAdd(ownLocals, p);
			}
			collectOwnDeclSyms(pb.body, ownLocals);
			const plan = planLoopEnv(state, pb.body, ss, sym, ownCaptures, detectionGetCapturedIdents(state.detection, fn), ownLocals, shared);
			const env = routineEnv(state, pb.body, ss, sym, ownCaptures, plan, shared);
			if (!env.known) continue;
			const info = routineInfoOf(state, sym);
			if (info == null) {
				state.closureCounter += 1;
				const lifted = mintLiftedSym(state, `${env.captures ? "$lifted" : "$fn"}_${state.currentFnName}_${state.closureCounter}`);
				state.routineInfos.push({ sym, liftedSym: lifted, envStructType: env.envStructType, promised: true });
				changed = true;
			} else if (info.promised && info.envStructType != env.envStructType) {
				info.envStructType = env.envStructType;
				changed = true;
			}
		}
	}
}

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
	lifter: (n: Node, captures: SymSet, state: LiftState, preEnv: PreCreatedEnv, envParamSym: Symbol, routine: Symbol | null, carrierIdx: number) => Node,
): Node {
	const routine = state.pendingRoutine;
	state.pendingRoutine = null;
	const outerEnvParamSym = state.envParamSym;
	const ownEnvParamSym = freshEnvParamSym(state.ctx);
	state.envParamSym = ownEnvParamSym;
	defineParams(state.ss, node.paramSyms, params);
	// Each capturing closure is its own env-owner. Locals
	// declared inside its body MUST live in this closure's per-call env, not
	// in an enclosing FunctionDecl's shared env — otherwise multiple
	// invocations of the same closure share storage and overwrite each
	// other's per-call state. Detection's `fnCaptures` for this node = vars
	// in the closure's frame or above referenced by its nested closures
	// (already filtered by `definedAtOrAboveInitial`).
	const ownCaptures = detectionGetCaptures(state.detection, node);
	const ownCapturedIdents = detectionGetCapturedIdents(state.detection, node);
	const ownLocals = createSymSet();
	if (node.paramSyms != null) {
		for (const p of node.paramSyms) symSetAdd(ownLocals, p);
	}
	collectOwnDeclSyms(body, ownLocals);
	const savedFnName = state.currentFnName;
	const savedCurrentParams = state.currentParams;
	// Decided before the body walk so `setupSharedEnv` and `liftClosure` agree on the
	// env `_envP` carries; uses the outer fn name, so it runs before the rename below.
	const enclosingLoops = savedShared.loopEnvs;
	const plan = planLoopEnv(state, body, state.ss, routine, ownCaptures, ownCapturedIdents, ownLocals, savedShared);
	const carrierIdx = plan.carrierIdx;
	let preEnv: PreCreatedEnv = null as unknown as PreCreatedEnv;
	if (plan.preSyms != null) preEnv = createSnapshotPairEnv(plan.preSyms, plan.preIdents, state, node.location, plan.preParent);
	let entryChain = envChainFrom(enclosingLoops, carrierIdx, savedShared.name, savedShared.structType, savedShared.chainNames, savedShared.chainTypes);
	if (preEnv != null) {
		const names: string[] = [preEnv.envName];
		const types: Type[] = [preEnv.envStructType];
		for (const n of entryChain.names) names.push(n);
		for (const t of entryChain.types) types.push(t);
		entryChain = { names, types };
	}
	let routineSym: Symbol | null = null;
	let routineCaptures = false;
	if (routine != null && isRoutineSym(state, routine)) {
		const env = routineEnv(state, body, state.ss, routine, ownCaptures, plan, savedShared);
		routineCaptures = env.captures;
		const promised = routineInfoOf(state, routine);
		if (promised != null && promised.promised) {
			promised.promised = false;
			if (!env.known || promised.envStructType != env.envStructType) {
				reportTransformError(state.ctx, `internal: '${routine.name}' was promised another env than its lift decided`, node.location);
			}
			routineSym = promised.liftedSym;
		} else {
			state.closureCounter += 1;
			routineSym = mintLiftedSym(state, `${routineCaptures ? "$lifted" : "$fn"}_${savedFnName}_${state.closureCounter}`);
			if (env.known) state.routineInfos.push({ sym: routine, liftedSym: routineSym, envStructType: env.envStructType, promised: false });
		}
	}
	if (ownCaptures.items.length > 0) {
		state.closureCounter += 1;
		state.currentFnName = `${savedFnName}_${suffix}${state.closureCounter}`;
		state.currentParams = createSymSet();
		if (node.paramSyms != null) {
			for (const p of node.paramSyms) symSetAdd(state.currentParams, p);
		}
		preRegisterVarTypes(body, state);
	}
	const loc = node.location;
	const bodyLoopSyms = frameLoopSyms(body, state);
	walkLiftBody(body, state, () => {
		if (ownCaptures.items.length > 0) {
			setupSharedEnv(state, ownCaptures, ownCapturedIdents, loc, entryChain.names, entryChain.types, ownLocals, bodyLoopSyms);
		}
	});
	state.capturedIdents = [];
	const captures = detectCaptures(body, state.ss, state.capturedIdents, routine, state.ctx);
	popFuncBoundary(state.ss);
	state.activeEnvRewrites = savedActiveRewrites;
	restoreSharedEnv(state, savedShared);
	state.envParamSym = outerEnvParamSym;
	state.currentFnName = savedFnName;
	state.currentParams = savedCurrentParams;
	// The closure needs the outer env at runtime if either its body has
	// direct outer refs (captured) OR detection found refs from nested
	// closures (ownCaptures). In the latter case, walkLiftBody's per-closure
	// shared env already rewrote body refs through its own env var, so
	// `captures` is empty post-walk — fall back to ownCaptures to keep the
	// closure-pair carrying its outer env, which the body now needs to copy
	// ancestor captures from at entry.
	const capturing = captures.items.length > 0 || ownCaptures.items.length > 0;
	if (routineSym != null && capturing != routineCaptures) {
		reportTransformError(state.ctx, `internal: '${routine!.name}' was promised to lift ${routineCaptures ? "with" : "without"} an env`, loc);
	}
	state.pendingLiftedSym = routineSym;
	state.liftOwnLocals = ownLocals;
	if (capturing) {
		computeLastUseCapturesForState(captures, state);
		return lifter(node, captures, state, preEnv, ownEnvParamSym, routine, carrierIdx);
	}
	return liftNonCapturing(body, node.paramSyms!, paramTypes, flags, returnType, state, loc, node.nodeType!, routine);
}

// Try to lift a closure. Returns the original node if no captures, or a closure pair if lifted.
function tryLiftClosure(node: Node, state: LiftState): Node {
	// Save+clear scope state: closure body is a new scope.
	pushFuncBoundary(state.ss);
	const savedActiveRewrites = state.activeEnvRewrites;
	state.activeEnvRewrites = [];
	const savedShared = saveSharedEnv(state);

	if (node.kind == NodeKind.ArrowFunction) {
		const d = node.data as ArrowFunctionData;
		return liftCapturingClosureBody(state, node, d.arrowBody, d.arrowParams, d.arrowParamTypes, d.arrowFlags, d.arrowReturnType, "arrow", savedActiveRewrites, savedShared, liftArrow);
	} else if (node.kind == NodeKind.FunctionExpr) {
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

// Wrap every expression-bodied arrow into block-bodied form so lifting
// always sees a BlockStmt. `walkLiftBody` can only prepend hoisted env
// decls into a BlockStmt; a non-block body silently drops them — curried
// arrows (fixedbugs/bug039) and nested arrows inside an expression body
// (fixedbugs/bug095) both died on that.
function normalizeArrowBodies(node: Node): Node {
	if (node == null) return null as unknown as Node;
	if (node.kind == NodeKind.ArrowFunction) {
		const d = node.data as ArrowFunctionData;
		if (d.arrowBody != null && d.arrowBody.kind != NodeKind.BlockStmt) {
			const loc = d.arrowBody.location;
			d.arrowBody = makeBlock([makeReturn(d.arrowBody, loc)], loc);
		}
	}
	mapChildren(node, normalizeArrowBodies);
	return node;
}

export function lowerLambda(program: Node, ctx: TransformContext): Node {
	const state = createLiftState(ctx);
	normalizeArrowBodies(program);
	// Pass 1: collect per-fn capture info upfront.
	state.detection = detectPass(program);
	state.splitLoopLocals = ctx.splitLoopLocals;
	collectRoutines(program, state);
	// Pass 2: rewrite + lift closures, consuming Pass 1 results.
	walkLift(program, state);

	// Prepend env structs + lifted functions to program
	if (state.envStructs.length == 0 && state.liftedFunctions.length == 0) {
		return program;
	}

	if (program.kind == NodeKind.Program) {
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

function checkedLifted(input: string): Node[] {
	const result = parseInput(input);
	if (!result.ok) return [];
	checkProgram(result.value);
	return getStmts(lowerLambda(result.value, makeCtx()));
}

test "no closures passthrough" { assert stmtCountAfter("const x = 1;", lowerLambda) == 1; }

test "function without capture unchanged" { assert firstStmtKindAfter("function foo(x) { return x; }", lowerLambda) == NodeKind.FunctionDecl; }

test "nested function hoisted to top level" {
	const stmts = checkedLifted("function outer() { function f() { return 1; } f(); }");
	assert stmts.length == 2;
	assert stmts[0].kind == NodeKind.FunctionDecl;
	assert stmts[1].kind == NodeKind.FunctionDecl;
}

test "non-capturing arrow lifted" {
	// Arrow lifted to module-level FunctionDecl + original VariableDecl = 2 stmts
	assert checkedLifted("const f = (x) => x + 1;").length == 2;
	assert checkedLifted("const f = (x) => x + 1;")[0].kind == NodeKind.FunctionDecl;
}

test "arrow inside array literal lifted" {
	assert checkedLifted("const a = [() => 1];").length == 2;
	assert checkedLifted("const a = [() => 1];")[0].kind == NodeKind.FunctionDecl;
}

test "non-capturing arrow in function lifted" {
	// Inner arrow lifted to program level: lifted fn + outer fn = 2 stmts
	assert checkedLifted("function f(x) { const g = (y) => y + 1; }").length == 2;
}

test "arrow with capture generates 3 stmts" {
	// function outer() { let x = 1; const f = () => x; }
	// → env struct + lifted fn + original fn = 3 stmts
	assert checkedLifted("function outer() { let x = 1; const f = () => x; }").length == 3;
}

test "env struct is first stmt" { assert checkedLifted("function outer() { let x = 1; const f = () => x; }")[0].kind == NodeKind.InterfaceDecl; }

test "builtin name not captured" {
	// Arrow referencing builtin is non-capturing, but still lifted: lifted fn + outer fn = 2
	assert checkedLifted("function f() { const g = () => console; }").length == 2;
}

test "multiple captures one env" { assert checkedLifted("function f() { let a = 1; let b = 2; const g = () => a + b; }").length == 3; }

test "non-capturing function expr lifted" {
	assert checkedLifted("const f = function(x) { return x + 1; };").length == 2;
	assert checkedLifted("const f = function(x) { return x + 1; };")[0].kind == NodeKind.FunctionDecl;
}

test "a macro body is not lifted" {
	assert stmtCountAfter("macro twice(x: Node): Node { const f = (y: Node): Node => y; return f(x); }", lowerLambda) == 1;
}

function checkedFnBody(input: string): Node[] {
	const result = parseInput(input);
	if (!result.ok) return [];
	checkProgram(result.value);
	const fd = getStmts(result.value)[0].data as FunctionDeclData;
	return (fd.fnBody.data as BlockStmtData).statements;
}

test "isCaptureLastUse: var not used after closure" {
	const stmts = checkedFnBody("function f() { let x = 1; const g = () => x; }");
	assert stmts.length == 2;
	assert isCaptureLastUse(stmts[0].resolvedSym!, 1, stmts);
}

test "isCaptureLastUse: var used after closure" {
	const stmts = checkedFnBody("function f(): int32 { let x = 1; const g = () => x; return x; }");
	assert stmts.length == 3;
	assert !isCaptureLastUse(stmts[0].resolvedSym!, 1, stmts);
}

test "isCaptureLastUse: a later binding of the same spelling is not a use" {
	const stmts = checkedFnBody("function f(): int32 { let x = 1; const g = () => x; { const x = 2; return x; } }");
	assert stmts.length == 3;
	assert isCaptureLastUse(stmts[0].resolvedSym!, 1, stmts);
}

function envFieldsOf(stmts: Node[]): string[] {
	for (const s of stmts) {
		if (s.kind == NodeKind.InterfaceDecl && s.nodeType != null) return s.nodeType.typeNames;
	}
	return [];
}

test "two captured bindings of one spelling get a field each" {
	const fields = envFieldsOf(checkedLifted("function f(): void { let n: int32 = 0; { const x: int32 = 1; const g = (): int32 => x + n; n = g(); } { const x: int32 = 2; const h = (): int32 => x + n; n = h(); } }"));
	assert fields.length == 4;
	assert fields[0] == "$up";
	assert fields[1] != fields[2] && fields[2] != fields[3] && fields[1] != fields[3];
}

test "a lifted closure is a routine symbol that its closure pair refers to" {
	const stmts = checkedLifted("function outer(): int32 { let x: int32 = 1; const f = (): int32 => x; return f(); }");
	let lifted: Node | null = null;
	let outerFn: Node | null = null;
	for (const s of stmts) {
		if (s.kind != NodeKind.FunctionDecl) continue;
		if ((s.data as FunctionDeclData).fnName == "outer") { outerFn = s; } else { lifted = s; }
	}
	assert lifted != null && outerFn != null;
	const sym = lifted!.resolvedSym;
	assert sym != null && sym.symbolKind == SymbolKind.Function && sym.declNode == lifted;
	assert refsAnySym((outerFn!.data as FunctionDeclData).fnBody, [sym!]);
}
