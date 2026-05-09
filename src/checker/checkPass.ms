// Statement Checker — Pass 3 statement validation and control flow
// Expression checking extracted to checkExprPass.ms. Uses checkerCallbacks for mutual recursion.

import { Node, NodeKind, NodeFlag, DeclKind, SourceLocation, createNodeAt, ExprStmtData, ThrowStmtData, DeferStmtData, DecoratedDeclData, IdentifierData, BinaryExprData, MemberExprData, UnaryExprData, ArrayAccessData, VariableDeclData, FunctionDeclData, ClassDeclData, ActorDeclData, MethodDeclData, ConstructorDeclData, ExportDeclData, ImportDeclData, IfStmtData, WhileStmtData, ForStmtData, ForOfStmtData, ForInStmtData, DoWhileStmtData, BlockStmtData, ReturnStmtData, TryCatchStmtData, SwitchStmtData, SwitchCaseData, MatchStmtData, MatchCaseData, DestructuringDeclData, ArrayPatternData, ObjectPatternData, ObjectPatternPropData, ObjectLiteralData, ProgramData, MacroInvocationData, MacroDeclData, StringLiteralData, CallExprData, TestDeclData, AssertStmtData, Type, TypeKind, Symbol, SymbolKind, SymbolState } from "../ast/node";
import { linkFlags, linkObjects } from "../utils/linkState";

import { unknownType, charType, float64Type, voidType, nullType, createFunction, createPromise, typeDisplayName, isAwaitable, isAffineAwaitable, awaitedType, isIterator, getIteratorYieldType, isResult, getResultOkType, getResultErrType, detectUnionDiscriminant, collectStringDiscriminantValues } from "./types";
import { AffineTracker, saveConsumeState, restoreConsumeState, collectNewConsumes, mergeConsumeBranches, isConsumedName, removeConsumedName, symbolConsumeKey } from "./spawnAffinity";
import { Scope, ScopeKind, defineSymbol, lookupSymbol, lookupLocal, makeSymbol, openScope, closeScope, addSymbolToScope, setFlag, hasFlag, markConsumed, markUsed, SymbolFlag } from "./symbol";
import { CheckerContext, CancelCtx, JsImportEntry, createContext, createContextWithCache, createModuleContextWithCache, addError, addFatalError, addWarning, addWarningRange, addHintRange, hasErrors, errorCount, createExtensionRegistry, registerExtension, createExtMethod, ExportRegistry, ExportedSymInfo, registerModuleExports, findModuleExports, buildExportInfo, isCancelled, isGenericFn, sgRecordSym, sgSortRecords } from "./context";
import { IdentCache, createIdentCache } from "./idents";
import { Module, ModuleGraph } from "../module/graph";
import { collectTopLevel, defineOrError } from "./collectPass";
import { readFile } from "std/fs";
import { resolveRuntimeDir } from "../utils/path";
import { join } from "std/fs/path";
import { translateCHeader } from "../module/cimport/emit";
import { inlineHeaderImports, createFileSystemProvider } from "../module/loader";
import { globalImports } from "./prelude";
import { isAssignable } from "./compat";
import { setConditionalAssignFn } from "./types";
setConditionalAssignFn(isAssignable);
import { resolveDeclarations, resolveAnnotation, resolveTypeExpr, ensureShaped, defineGenericParam } from "./resolvePass";
import { registerModuleCtx } from "./instantiate";
import { getGenericDecl } from "../parser/context";
import { splitTopLevel } from "../utils/string";
import { bindFlowGraph } from "../binder/index";
import { getFlowTypeOfReference } from "./flow";
import { inferOwnership } from "./ownershipInference";
import { analyzeParamMutations } from "./paramMutationAnalysis";
import { getModuleDir, appendFlag } from "../utils/string";
import { checkExpr, checkEnumExhaustiveness, checkDuplicatePatterns, fitNode, estimateExprEndCol } from "./checkExprPass";
import { registerCheckStmt, registerCheckFunctionBody } from "./checkerCallbacks";
import "./instantiate"; // side-effect: registers instantiateGenericFunction callback
import { forEachChild } from "../ast/visitor";
import { parseSource } from "../parser/statements/validation";
import { BreakState, markInitialized, saveInitState, restoreInitState, breaksBlock, mergeInitBranches, collectNewInits, isAlwaysTrue, varDecl } from "./initTracker";

// Extract directory from module path (e.g. "src/foo/bar.ms" → "src/foo")
// Brief type description for error messages
function formatTypeBrief(t: Type | null): string {
	if (t === null) return "unknown";
	if (isResult(t)) {
		const ok = getResultOkType(t);
		const err = getResultErrType(t);
		const okName = ok !== null ? typeDisplayName(ok) : "?";
		const errName = err !== null ? typeDisplayName(err) : "?";
		return "Result<" + okName + ", " + errName + ">";
	}
	return typeDisplayName(t);
}

// ===== PARALOCK Phase 1: Scope-Exit Affine Check =====

// Called before each closeScope(). Walks all symbols in the scope, and for
// every binding whose static type is a affine Promise<T>, verifies it has been
// consumed. Unconsumed bindings produce an R1/E2 error.
//
// Consumption is recorded in two channels:
//   1. The AffineTracker.consumed list (branch-aware, path-sensitive, keyed by
//      symbolConsumeKey which distinguishes shadowed bindings).
//   2. The SymbolFlag.Consumed bit (promoted once consumption is observed anywhere).
// Either channel satisfies the scope-exit check. After verification, we purge
// the key from the tracker so it doesn't pollute outer scopes.
//
// Lives here (not in spawnAffinity.ms) to avoid a cycle with context.ms:
// spawnAffinity stays pure data/logic; the checker-facing glue belongs in
// the pass that owns the scope lifecycle.
function checkAffineConsumption(ctx: CheckerContext, scope: Ptr<Scope>, tracker: AffineTracker): void {
	for (const sym of scope.symbols.values()) {
		if (sym !== null && sym.symbolType !== null && isAffineAwaitable(sym.symbolType)) {
			const key = symbolConsumeKey(sym);
			const consumed = hasFlag(sym, SymbolFlag.Consumed) || isConsumedName(tracker, key);
			if (!consumed) {
				const loc = sym.location;
				const line = loc !== null ? loc.line : 0;
				const col = loc !== null ? loc.column : 0;
				addError(ctx,
					`affine Promise '${sym.name}' from spawn(...) is never awaited; every spawn result must be consumed before its scope exits (PARALOCK R1/E2)`,
					line, col);
			} else {
				// Promote tracker evidence to symbol flag for cross-scope visibility
				markConsumed(sym);
			}
			// Purge this key from the tracker — the binding is about to go out of
			// scope. The key is unique per declaration site so this only removes
			// entries for THIS symbol, leaving any shadowed outer binding intact.
			removeConsumedName(tracker, key);
		}
	}
}

// ===== PARALOCK Phase 1: Loop Reuse Detection =====

// Walks the parent scope chain to collect consume keys of every currently-visible
// affine-Promise binding. Used by loop reuse detection to identify handles declared
// OUTSIDE a loop body — consuming such a handle inside the body would reuse an
// already-awaited value on iteration N+1.
function collectVisibleSpawnKeys(scope: Ptr<Scope>): string[] {
	const result: string[] = [];
	let s = scope;
	while (s !== null) {
		for (const sym of s.symbols.values()) {
			if (sym !== null && sym.symbolType !== null && isAffineAwaitable(sym.symbolType)) {
				result.push(symbolConsumeKey(sym));
			}
		}
		s = s.parent;
	}
	return result;
}

// Extract the name portion of a consume key ("name:line:col" → "name").
function consumeKeyName(key: string): string {
	let i = 0;
	while (i < key.byteLength) {
		if (key.charAt(i) === ":") return key.slice(0, i);
		i = i + 1;
	}
	return key;
}

// After walking a loop body, flag any consumption of a handle declared in an
// outer scope. The body can legitimately consume inner handles (scope-exit
// check catches those), but an outer handle consumed inside a loop body would
// be reused on the next iteration. Reports each offender once.
function detectLoopReuse(ctx: CheckerContext, outerKeys: string[], bodyStartState: number, line: number, col: number): void {
	const newConsumes = collectNewConsumes(ctx.affineTracker, bodyStartState);
	for (const key of newConsumes) {
		for (const outerKey of outerKeys) {
			if (key === outerKey) {
				addError(ctx,
					`affine Promise '${consumeKeyName(key)}' from spawn(...) is consumed inside a loop body; iteration N+1 would reuse an already-awaited handle. Move the spawn inside the loop, or await outside it (PARALOCK R1/E3)`,
					line, col);
				break;
			}
		}
	}
}

// ===== Statement Checker =====

export function checkStmt(ctx: CheckerContext, node: Node): void {
	match (node.kind) {
		NodeKind.VariableDecl => checkVariableDecl(ctx, node),
		NodeKind.FunctionDecl => checkFunctionDecl(ctx, node),
		NodeKind.ClassDecl => checkClassDecl(ctx, node),
		NodeKind.ActorDecl => checkActorDecl(ctx, node),
		NodeKind.InterfaceDecl | NodeKind.StructDecl | NodeKind.EnumDecl | NodeKind.TypeAliasDecl |
		NodeKind.ExternDecl | NodeKind.ImportDecl => {},
		NodeKind.MacroDecl => markMacroUsedSymbols(ctx, node),
		NodeKind.ExportDecl => checkExportDecl(ctx, node),
		NodeKind.IfStmt => checkIfStmt(ctx, node),
		NodeKind.WhileStmt => checkWhileStmt(ctx, node),
		NodeKind.ForStmt => checkForStmt(ctx, node),
		NodeKind.ForOfStmt => checkForOfStmt(ctx, node),
		NodeKind.ForInStmt => checkForInStmt(ctx, node),
		NodeKind.DoWhileStmt => checkDoWhileStmt(ctx, node),
		NodeKind.BlockStmt => checkBlock(ctx, node),
		NodeKind.ReturnStmt => checkReturnStmt(ctx, node),
		NodeKind.BreakStmt => { if (!ctx.inLoop) { addError(ctx, "break outside of loop", node.location.line, node.location.column); } },
		NodeKind.ContinueStmt => { if (!ctx.inLoop) { addError(ctx, "continue outside of loop", node.location.line, node.location.column); } },
		NodeKind.ExprStmt => {
			const d = node.data as ExprStmtData;
			checkExpr(ctx, d.expr, null);
			// PARALOCK Phase 1 R1/E1: a discarded affine Promise (bare spawn(...) expression
			// with no binding and no await) is a compile error. Borrowed captures would
			// dangle and the result would be silently dropped. For fire-and-forget,
			// users should bind and await. For fire-and-forget, use actor SEND.
			// Suppress inside loops: legacy fire-and-forget pattern (to be migrated later).
			if (d.expr.kind === NodeKind.CallExpr && d.expr.resolvedSym !== null
				&& d.expr.resolvedSym.builtinKind === "PromiseSpawn" && !ctx.inLoop) {
				addError(ctx, "spawn result is discarded — every affine Promise must be awaited before its scope exits (PARALOCK R1/E1)", d.expr.location.line, d.expr.location.column);
			}
		},
		NodeKind.ThrowStmt => {
			const d = node.data as ThrowStmtData;
			checkExpr(ctx, d.throwArg, null);
		},
		NodeKind.TryCatchStmt => checkTryCatch(ctx, node),
		NodeKind.SwitchStmt => checkSwitchStmt(ctx, node),
		NodeKind.MatchStmt => checkMatchStmt(ctx, node),
		NodeKind.DeferStmt => {
			const d = node.data as DeferStmtData;
			checkExpr(ctx, d.deferExpr, null);
		},
		NodeKind.DecoratedDecl => {
			const d = node.data as DecoratedDeclData;
			if (d.decoratedNode !== null) checkStmt(ctx, d.decoratedNode);
		},
		NodeKind.DestructuringDecl => checkDestructuringDecl(ctx, node),
		NodeKind.TestDecl => {
			const d = node.data as TestDeclData;
			// Test blocks compile to functions — allow return statements inside
			const savedFunction = ctx.currentFunction;
			const savedInTest = ctx.inTestBlock;
			ctx.currentFunction = makeSymbol("__test__", SymbolKind.Function, unknownType(), false);
			ctx.inTestBlock = true;
			checkBlock(ctx, d.testBody);
			ctx.inTestBlock = savedInTest;
			ctx.currentFunction = savedFunction;
		},
		NodeKind.AssertStmt => {
			const d = node.data as AssertStmtData;
			if (!ctx.inTestBlock) {
				addFatalError(ctx, "'assert' can only be used inside test blocks", node.location.line, node.location.column);
			}
			checkExpr(ctx, d.assertExpr, null);
		},
		_ => {},
	};
}

// ===== Statement Helpers =====

function checkVariableDecl(ctx: CheckerContext, node: Node): void {
	const d = node.data as VariableDeclData;
	// Resolve declared type FIRST so it can flow as expectedType into initializer (Implementation parity)
	let declType: Type | null = null;
	if (d.declType !== "") {
		const typeLoc = node.typeExpr !== null ? node.typeExpr.location : d.nameLocation;
		declType = resolveAnnotation(d.declType, ctx, typeLoc.line, typeLoc.column);
		resolveTypeExpr(node.typeExpr, ctx);
	}
	// Self-recursive closure binding: `const fact: T = n => fact(n-1)`. The
	// arrow body references `fact` before its symbol exists at the normal
	// post-init registration site (line ~273). Pre-register the symbol with
	// its declared type so the body's lookup resolves. Only when:
	//   (1) we have a declared type — without it the symbol's type is unknown
	//   (2) the initializer is an ArrowFunction or FunctionExpr — preserving
	//       TDZ semantics for non-closure initializers like `const x = x + 1`
	let preRegisteredSelfRefSym: Symbol = null as unknown as Symbol;
	if (declType !== null && d.initializer !== null
			&& (d.initializer.kind === NodeKind.ArrowFunction
				|| d.initializer.kind === NodeKind.FunctionExpr)
			&& lookupLocal(ctx.table, d.declName) === null) {
		preRegisteredSelfRefSym = makeSymbol(d.declName, SymbolKind.Variable, declType, d.declKind !== DeclKind.Const);
		defineOrError(ctx, preRegisteredSelfRefSym, node);
	}
	checkExpr(ctx, d.initializer, declType);
	const initType = d.initializer !== null ? d.initializer.nodeType : null;
	// PARALOCK Phase 1: explicit `: Promise<T>` annotation on a affine Promise-producing
	// initializer strips affine tracking. Warn so the opt-out is deliberate, not accidental.
	if (declType !== null && initType !== null
		&& isAwaitable(declType) && !isAffineAwaitable(declType) && isAffineAwaitable(initType)) {
		addWarning(ctx,
			`explicit 'Promise<T>' annotation on a spawn result strips PARALOCK affine tracking — '${d.declName}' will not be lifetime-checked. Remove the annotation to enable affine checking, or keep it as an opt-out`,
			d.nameLocation.line, d.nameLocation.column);
	}
	// TS-aligned (TS2322): `const x: T = expr` where expr's type is `null` and
	// T is non-nullable is a type error at the assignment. Targeted at `null`
	// only — broader assignability checking at var-decl is a separate concern
	// (the codebase historically defers most decl-time mismatches to downstream
	// passes; widening this filter risks surfacing latent legacy mismatches).
	// Catches `const x: int32 = id(null)` where the naked-T `id<T>(x:T):T`
	// returns `null` and we want the error here, not at C compile.
	const dt = declType;
	if (dt !== null && initType !== null
		&& initType.kind === TypeKind.Null
		&& dt.kind !== TypeKind.Unknown
		&& dt.kind !== TypeKind.GenericParam
		&& !isAssignable(initType, dt)) {
		const initLoc = d.initializer !== null ? d.initializer.location : d.nameLocation;
		addError(ctx,
			"Type 'null' is not assignable to type '" + typeDisplayName(dt) + "'",
			initLoc.line, initLoc.column);
	}
	// Parity: standard reference node fitting — insert HiddenStdConv for narrowing integer conversions
	if (declType !== null && d.initializer !== null) {
		d.initializer = fitNode(ctx, d.initializer, declType, initType);
	}
	// Prefer explicit type annotation over inferred type
	let varType = initType;
	if (declType !== null) {
		varType = declType;
	}
	node.nodeType = varType;
	// If already collected in pass 1 (e.g. export const) OR pre-registered above
	// for self-recursive closure binding, update type and re-record.
	const existing = lookupLocal(ctx.table, d.declName);
	if (existing !== null) {
		existing.symbolType = varType;
		if (d.declKind !== DeclKind.Const) {
			setFlag(existing, SymbolFlag.Mutable);
		}
		node.resolvedSym = existing;
		sgRecordSym(ctx, d.nameLocation.line, d.nameLocation.column, d.nameLocation.column + d.declName.length, existing, varType, SymbolKind.Variable, d.declName, "", true);
	} else {
		const newSym = makeSymbol(d.declName, SymbolKind.Variable, varType, d.declKind !== DeclKind.Const);
		defineOrError(ctx, newSym, node);
		node.resolvedSym = newSym;
		sgRecordSym(ctx, d.nameLocation.line, d.nameLocation.column, d.nameLocation.column + d.declName.length, newSym, varType, SymbolKind.Variable, d.declName, "", true);
	}
	// Ref parity: varDecl — record declaration block for nfFirstWrite logic
	varDecl(ctx.initTracker, d.declName);
	// Ref parity: initVar if initializer present (sempass2 lines 1317-1318)
	// Any initializer counts — even `null as unknown as T` (initialized, just null-valued)
	if (d.initializer !== null) {
		node.flags = node.flags | NodeFlag.FirstWrite;
		markInitialized(ctx.initTracker, d.declName);
	}
	// `let x;` with no initializer → NOT marked → will warn on use
}

function checkFunctionDecl(ctx: CheckerContext, node: Node): void {
	const d = node.data as FunctionDeclData;
	// Use resolvedSym set by collectPass (preserves overloadIdx for overloaded functions).
	// Only fall back to lookupSymbol if collector didn't set it (e.g., monomorphized clones).
	let sym = node.resolvedSym;
	if (sym === null) {
		sym = lookupSymbol(ctx.table, d.fnName);
		if (sym === null) return;
		node.resolvedSym = sym;
	}

	// Demand-driven: ensure signature is shaped before checking body
	ensureShaped(sym, ctx);
	sgRecordSym(ctx, d.nameLocation.line, d.nameLocation.column, d.nameLocation.column + d.fnName.length, sym, sym.symbolType, SymbolKind.Function, d.fnName, "", true);

	// Multi-pass parity: avoid re-checking body if already done
	if (sym.state === SymbolState.Checked) return;
	sym.state = SymbolState.Checking;

	const fnType = sym.symbolType;
	node.nodeType = fnType;

	// Mark async functions for return type unwrapping
	if (d.fnFlags === "async" || d.fnFlags === "async_generator" || (d.fnFlags !== "" && d.fnFlags.indexOf("async") >= 0)) {
		setFlag(sym, SymbolFlag.Async);
	}

	// TS-strict: async functions must declare Promise<T> as return type
	// (or leave it unannotated, which infers to void). An explicit bare type T
	// produces a C signature / body type mismatch in codegen — catch it at the
	// declaration site with a clear, actionable error. async_generator is exempt
	// because it returns AsyncIterator<T>, not Promise<T>.
	if (d.fnFlags === "async"
		&& fnType !== null
		&& fnType.kind === TypeKind.Function
		&& fnType.typeReturn !== null
		&& fnType.typeReturn.kind !== TypeKind.Unknown
		&& fnType.typeReturn.kind !== TypeKind.Void
		&& !isAwaitable(fnType.typeReturn)) {
		const got = formatTypeBrief(fnType.typeReturn);
		addError(ctx,
			"async function '" + d.fnName + "' must declare return type as Promise<" + got
				+ ">, not bare '" + got + "'. Change the signature to: async function "
				+ d.fnName + "(...): Promise<" + got + ">",
			d.nameLocation.line, d.nameLocation.column);
	}

	// Reference parity (semProcAux): generic function bodies are NOT checked at declaration time.
	// They're stored as raw AST and only checked when instantiated with concrete types
	// (via instantiateGenericFunction → checkFunctionBody). This prevents creating
	// bad instantiations (push__unknown) from unresolved GenericParam types.
	const isGeneric = isGenericFn(d.fnFlags);
	if (isGeneric) {
		sym.state = SymbolState.Checked;
		return;
	}

	// Save/restore inferredReturn for nested functions
	const savedReturn = ctx.inferredReturn;
	ctx.inferredReturn = fnType.typeReturn;

	checkFunctionBody(ctx, sym, d.params, d.fnBody, node.paramLocations);

	// If return type was unknown (no annotation), use inferred type
	if (sym.symbolType.kind === TypeKind.Function
		&& sym.symbolType.typeReturn !== null
		&& sym.symbolType.typeReturn.kind === TypeKind.Unknown
		&& ctx.inferredReturn.kind !== TypeKind.Unknown) {
		sym.symbolType.typeReturn = ctx.inferredReturn;
	}

	// Async functions: ensure the effective return type is Promise<T>.
	// The TS-strict check above errors on an *explicit* bare `T` return annotation.
	// This block handles the two remaining cases via auto-wrap (TypeScript parity):
	//   - No annotation + body returns T → wrap inferred T into Promise<T>
	//   - No annotation + empty body    → default to Promise<void>
	// Excludes async_generator (returns AsyncIterator<T>).
	if (hasFlag(sym, SymbolFlag.Async)
		&& d.fnFlags !== "async_generator"
		&& sym.symbolType.kind === TypeKind.Function
		&& sym.symbolType.typeReturn !== null
		&& !isAwaitable(sym.symbolType.typeReturn)) {
		let inner = sym.symbolType.typeReturn;
		if (inner.kind === TypeKind.Unknown) inner = voidType();
		sym.symbolType.typeReturn = createPromise(inner);
	}

	// @pure effect check: warn on impure calls inside pure functions
	if (sym.builtinKind === "pure" && d.fnBody !== null) {
		checkPurityViolations(ctx, d.fnBody);
	}

	ctx.inferredReturn = savedReturn;
	sym.state = SymbolState.Checked;
}

function checkClassDecl(ctx: CheckerContext, node: Node): void {
	const d = node.data as ClassDeclData;
	const sym = lookupSymbol(ctx.table, d.className);
	if (sym === null) return;
	node.resolvedSym = sym;

	// Demand-driven: ensure class fields/methods are shaped
	ensureShaped(sym, ctx);
	sgRecordSym(ctx, d.nameLocation.line, d.nameLocation.column, d.nameLocation.column + d.className.length, sym, sym.symbolType, SymbolKind.Class, d.className, "", true);

	if (sym.state === SymbolState.Checked) return;
	sym.state = SymbolState.Checking;

	openScope(ctx.table, ScopeKind.Class);
	// Register the class's generic parameters (e.g. T in `class Set<T>`) so member
	// bodies — notably the constructor — can resolve them. Without this, a body
	// expression like `new Map<T, T>()` inside the constructor fails lookupSymbol("T"),
	// falls back to unknown, and monomorphizes to `Map<unknown, unknown>`.
	// Mirrors resolveClass (resolvePass.ms): opens a separate ScopeKind.Block nested
	// inside the Class scope so generic-param symbols don't pollute the Class scope.
	const genericStr = getGenericDecl(d.className);
	const hasGenerics = genericStr !== "";
	if (hasGenerics) {
		openScope(ctx.table, ScopeKind.Block);
		const genericNames = splitTopLevel(genericStr, ",");
		for (const gp of genericNames) {
			const trimGp = gp.trim();
			if (trimGp !== "") defineGenericParam(ctx, trimGp);
		}
	}
	for (const member of d.classBody) {
		checkClassMember(ctx, member, d.className, sym.symbolType);
	}
	if (hasGenerics) closeScope(ctx.table);
	closeScope(ctx.table);

	sym.state = SymbolState.Checked;
}

function checkActorDecl(ctx: CheckerContext, node: Node): void {
	const d = node.data as ActorDeclData;
	const sym = lookupSymbol(ctx.table, d.actorName);
	if (sym === null) return;
	node.resolvedSym = sym;

	ensureShaped(sym, ctx);
	sgRecordSym(ctx, d.nameLocation.line, d.nameLocation.column, d.nameLocation.column + d.actorName.length, sym, sym.symbolType, SymbolKind.Actor, d.actorName, "", true);

	if (sym.state === SymbolState.Checked) return;
	sym.state = SymbolState.Checking;

	// Validate actor method constraints: no async, no generator (actor methods are inherently async via mailbox)
	for (const member of d.actorBody) {
		let m = member;
		if (m.kind === NodeKind.DecoratedDecl) {
			const dd = m.data as DecoratedDeclData;
			if (dd.decoratedNode !== null) m = dd.decoratedNode;
		}
		if (m.kind === NodeKind.MethodDecl) {
			const md = m.data as MethodDeclData;
			if (md.methodFlags === "async") {
				addError(ctx, `actor methods are inherently async — remove 'async' from '${md.methodName}'`,
					m.location.line, m.location.column);
			}
			if (md.methodFlags === "generator") {
				addError(ctx, `actor methods cannot be generators — '${md.methodName}' uses yield which is incompatible with message passing`,
					m.location.line, m.location.column);
			}
			// Lifecycle hooks: validate signatures
			if (md.methodName === "onTerminate") {
				if (md.methodParams.length !== 2) {
					addError(ctx, `onTerminate must have exactly one parameter (reason: ExitReason)`,
						m.location.line, m.location.column);
				}
				if (md.methodReturnType !== "" && md.methodReturnType !== "void") {
					addError(ctx, `onTerminate must return void`, m.location.line, m.location.column);
				}
			}
			if (md.methodName === "onExit") {
				if (md.methodParams.length !== 3) {
					addError(ctx, `onExit must have two parameters (childPid: int64, reason: ExitReason)`,
						m.location.line, m.location.column);
				}
				if (md.methodReturnType !== "" && md.methodReturnType !== "void") {
					addError(ctx, `onExit must return void`, m.location.line, m.location.column);
				}
			}
			if (md.methodName === "onDown") {
				if (md.methodParams.length !== 4) {
					addError(ctx, `onDown must have three parameters (ref: number, pid: int64, reason: ExitReason)`,
						m.location.line, m.location.column);
				}
				if (md.methodReturnType !== "" && md.methodReturnType !== "void") {
					addError(ctx, `onDown must return void`, m.location.line, m.location.column);
				}
			}
			if (md.methodName === "onIdle") {
				if (md.methodParams.length !== 1) {
					addError(ctx, `onIdle must have no parameters (only implicit this)`,
						m.location.line, m.location.column);
				}
				if (md.methodReturnType !== "" && md.methodReturnType !== "void") {
					addError(ctx, `onIdle must return void`, m.location.line, m.location.column);
				}
			}
		}
	}

	openScope(ctx.table, ScopeKind.Class);
	const prevActorName = ctx.currentActorName;
	ctx.currentActorName = d.actorName;
	for (const member of d.actorBody) {
		checkClassMember(ctx, member, d.actorName, sym.symbolType);
	}
	ctx.currentActorName = prevActorName;
	closeScope(ctx.table);

	sym.state = SymbolState.Checked;
}

function checkClassMember(ctx: CheckerContext, node: Node, className: string, classType: Type): void {
	// DecoratedDecl wrapping a class member — unwrap and check the inner node
	if (node === null) return;
	if (node.kind === NodeKind.DecoratedDecl) {
		const dd = node.data as DecoratedDeclData;
		if (dd.decoratedNode !== null) checkClassMember(ctx, dd.decoratedNode, className, classType);
		return;
	}
	match (node.kind) {
		NodeKind.PropertyDecl => {},
		NodeKind.MethodDecl => {
			const d = node.data as MethodDeclData;
			const methodSym = node.resolvedSym;
			const sym = methodSym !== null ? methodSym : makeSymbol(d.methodName, SymbolKind.Method, unknownType(), false);
			sgRecordSym(ctx, d.nameLocation.line, d.nameLocation.column, d.nameLocation.column + d.methodName.length, sym, sym.symbolType, SymbolKind.Method, d.methodName, className, true);
			// Skip body check for extern methods (no body to check)
			if (d.methodFlags !== "extern") {
				checkFunctionBody(ctx, sym, d.methodParams, d.methodBody, node.paramLocations);
			}
		},
		NodeKind.ConstructorDecl => {
			const d = node.data as ConstructorDeclData;
			// Record constructor DEF for symbol graph
			const ctorSym = node.resolvedSym;
			if (ctorSym !== null) {
				sgRecordSym(ctx, node.location.line, node.location.column, node.location.column + 11, ctorSym, ctorSym.symbolType, SymbolKind.Method, "constructor", className, true);
			}
			// Constructor allocates `this` — prepend to params for checking so this.* resolves,
			// but don't modify AST (codegen handles `this` as a local, not a param).
			const ctorParams: string[] = ["this"];
			for (let cpi = 0; cpi < d.ctorParams.length; cpi += 1) {
				ctorParams.push(d.ctorParams[cpi]);
			}
			// Build constructor type with `this` at index 0
			const ctorType = node.nodeType;
			const ctorChildren: Type[] = [classType];
			if (ctorType !== null && ctorType.typeChildren !== null) {
				for (let cpi = 0; cpi < ctorType.typeChildren.length; cpi += 1) {
					ctorChildren.push(ctorType.typeChildren[cpi]);
				}
			}
			const ctorFnType = createFunction(ctorChildren, ctorParams, voidType());
			// Prepend null location for synthetic "this" param
			const ctorLocs: SourceLocation[] = [null as unknown as SourceLocation];
			if (node.paramLocations !== null) {
				for (const loc of node.paramLocations) { ctorLocs.push(loc); }
			}
			checkFunctionBody(ctx, makeSymbol("constructor", SymbolKind.Method, ctorFnType, false), ctorParams, d.ctorBody, ctorLocs);
		},
		_ => {},
	};
}

function checkExportDecl(ctx: CheckerContext, node: Node): void {
	const d = node.data as ExportDeclData;
	if (d.exportedDecl.kind === NodeKind.VariableDecl) {
		checkVariableDecl(ctx, d.exportedDecl);
		return;
	}
	checkStmt(ctx, d.exportedDecl);
}

// ===== Null Narrowing (Fact-Based Model) =====
// Phase 4: fact-based null narrowing deleted. Narrowing now flows through
// src/binder/ (CFG construction) and src/checker/flow.ms
// (getFlowTypeOfReference). The Identifier handler in checkExprPass.ms
// queries the flow graph per use site — no symbolType mutation, no
// scope-based fact stack. `narrowFacts`, `addFact`, `addFactNeg`,
// `applyNarrowing`, `restoreNarrowing`, `saveFacts`, `restoreFacts`,
// `extractNullCheckedVars`, `collectNullVars`, `removeNullFromType`,
// `checkNarrowedBranch`, `invalidateFacts`, `factReferencesVar` — all
// gone. The `checkNarrowedBranch` callers (checkIfStmt, checkBlock
// guard-clause) now call `checkStmt` directly and rely on the flow graph.

// ===== Effect System (@pure) =====
// Walk function body looking for impure operations: calls to non-pure functions.

function checkPurityViolations(ctx: CheckerContext, body: Node): void {
	if (body === null) return;
	if (body.kind === NodeKind.BlockStmt) {
		const bd = body.data as BlockStmtData;
		let i = 0;
		while (i < bd.statements.length) {
			checkPurityViolations(ctx, bd.statements[i]);
			i = i + 1;
		}
		return;
	}
	if (body.kind === NodeKind.ExprStmt) {
		const ed = body.data as ExprStmtData;
		checkPurityViolations(ctx, ed.expr);
		return;
	}
	if (body.kind === NodeKind.ReturnStmt) {
		const rd = body.data as ReturnStmtData;
		if (rd.argument !== null) checkPurityViolations(ctx, rd.argument);
		return;
	}
	if (body.kind === NodeKind.IfStmt) {
		const id = body.data as IfStmtData;
		checkPurityViolations(ctx, id.condition);
		checkPurityViolations(ctx, id.consequent);
		if (id.alternate !== null) checkPurityViolations(ctx, id.alternate);
		return;
	}
	if (body.kind === NodeKind.VariableDecl) {
		const vd = body.data as VariableDeclData;
		if (vd.initializer !== null) checkPurityViolations(ctx, vd.initializer);
		return;
	}
	if (body.kind === NodeKind.CallExpr) {
		const cd = body.data as CallExprData;
		// Check if callee is a known pure function
		if (cd.callee.kind === NodeKind.Identifier) {
			const callId = cd.callee.data as IdentifierData;
			const calleeSym = lookupSymbol(ctx.table, callId.name);
			if (calleeSym !== null && calleeSym.builtinKind !== "pure") {
				addError(ctx, "@pure function calls impure function '" + callId.name + "'", body.location.line, body.location.column);
			}
		} else if (cd.callee.kind === NodeKind.MemberExpr) {
			// member calls (e.g. console.log) are impure by default
			const me = cd.callee.data as MemberExprData;
			addError(ctx, "@pure function calls impure method '" + me.property + "'", body.location.line, body.location.column);
		}
		// Also check arguments for nested impure calls
		let j = 0;
		while (j < cd.arguments.length) {
			checkPurityViolations(ctx, cd.arguments[j]);
			j = j + 1;
		}
		return;
	}
	if (body.kind === NodeKind.BinaryExpr) {
		const bd = body.data as BinaryExprData;
		checkPurityViolations(ctx, bd.left);
		checkPurityViolations(ctx, bd.right);
		return;
	}
}

// Check if a block/statement always exits (return, throw, break, continue, unreachable)
function isDefiniteExit(node: Node): boolean {
	if (node === null) return false;
	if (node.kind === NodeKind.ReturnStmt) return true;
	if (node.kind === NodeKind.ThrowStmt) return true;
	if (node.kind === NodeKind.BreakStmt) return true;
	if (node.kind === NodeKind.ContinueStmt) return true;
	if (node.kind === NodeKind.BlockStmt) {
		const bd = node.data as BlockStmtData;
		if (bd.statements.length === 0) return false;
		return isDefiniteExit(bd.statements[bd.statements.length - 1]);
	}
	return false;
}

function checkIfStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as IfStmtData;
	checkExpr(ctx, d.condition, null);

	// Ref parity: trackIf — count table + exhaustiveness for init/affine trackers.
	// Phase 4: narrowing flows through the flow graph — no fact stack needed.
	const oldState = saveInitState(ctx.initTracker);
	const oldAffine = saveConsumeState(ctx.affineTracker);
	const branchInits: string[][] = [];
	const branchBreaks: BreakState[] = [];
	const branchConsumes: string[][] = [];

	// Track consequent
	checkStmt(ctx, d.consequent);
	branchInits.push(collectNewInits(ctx.initTracker, oldState));
	branchConsumes.push(collectNewConsumes(ctx.affineTracker, oldAffine));
	branchBreaks.push(breaksBlock(d.consequent));

	// Track alternate (if present)
	const hasElse = d.alternate !== null && d.alternate.kind !== NodeKind.NullLiteral;
	if (hasElse) {
		restoreInitState(ctx.initTracker, oldState);
		restoreConsumeState(ctx.affineTracker, oldAffine);
		checkStmt(ctx, d.alternate);
		branchInits.push(collectNewInits(ctx.initTracker, oldState));
		branchConsumes.push(collectNewConsumes(ctx.affineTracker, oldAffine));
		branchBreaks.push(breaksBlock(d.alternate));
	}

	// Ref parity: merge with exhaustiveness check (init + affine trackers)
	mergeInitBranches(ctx.initTracker, oldState, branchInits, branchBreaks, hasElse);
	mergeConsumeBranches(ctx.affineTracker, oldAffine, branchConsumes, branchBreaks, hasElse);
}

// ===== Loop Statements =====

function checkWhileStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as WhileStmtData;
	checkExpr(ctx, d.whileCondition, null);
	ctx.initTracker.currentBlock = ctx.initTracker.currentBlock + 1;
	// PARALOCK Phase 1: snapshot affine state + outer affine Promise keys before the body
	const affineSnap = saveConsumeState(ctx.affineTracker);
	const outerSpawnKeys = collectVisibleSpawnKeys(ctx.table.current);
	// Ref parity (sempass2 lines 1346-1360): while(true) propagates, others conservative
	if (isAlwaysTrue(d.whileCondition)) {
		const saved = enterLoopScope(ctx);
		checkStmt(ctx, d.whileBody);
		exitLoopScope(ctx, saved);
	} else {
		const oldState = saveInitState(ctx.initTracker);
		const saved = enterLoopScope(ctx);
		checkStmt(ctx, d.whileBody);
		exitLoopScope(ctx, saved);
		restoreInitState(ctx.initTracker, oldState);
	}
	// PARALOCK Phase 1: detect outer-handle consumption (reuse on iteration N+1)
	detectLoopReuse(ctx, outerSpawnKeys, affineSnap, node.location.line, node.location.column);
	restoreConsumeState(ctx.affineTracker, affineSnap);
	ctx.initTracker.currentBlock = ctx.initTracker.currentBlock - 1;
}

function checkForStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as ForStmtData;
	ctx.initTracker.currentBlock = ctx.initTracker.currentBlock + 1;
	// PARALOCK Phase 1: snapshot before entering loop scope
	const affineSnap = saveConsumeState(ctx.affineTracker);
	const outerSpawnKeys = collectVisibleSpawnKeys(ctx.table.current);
	const saved = enterLoopScope(ctx);
	checkStmt(ctx, d.forInit);
	checkExpr(ctx, d.forCondition, null);
	// Ref parity: for loops — conservative, loop may not execute
	const oldState = saveInitState(ctx.initTracker);
	checkExpr(ctx, d.forUpdate, null);
	checkStmt(ctx, d.forBody);
	exitLoopScope(ctx, saved);
	restoreInitState(ctx.initTracker, oldState);
	detectLoopReuse(ctx, outerSpawnKeys, affineSnap, node.location.line, node.location.column);
	restoreConsumeState(ctx.affineTracker, affineSnap);
	ctx.initTracker.currentBlock = ctx.initTracker.currentBlock - 1;
}

function iterableElemType(t: Type): Type {
	if (t === null) return unknownType();
	return match (t.kind) {
		TypeKind.Array | TypeKind.SizedArray | TypeKind.Span =>
			t.typeReturn !== null ? t.typeReturn : unknownType(),
		TypeKind.String => charType(),
		_ => isIterator(t) ? getIteratorYieldType(t) : unknownType(),
	};
}

function checkForOfStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as ForOfStmtData;
	checkExpr(ctx, d.forOfIterable, null);
	let elemType = iterableElemType(d.forOfIterable.nodeType);
	// Implicit iterator: for non-array/string types, resolve .toItems() during checking.
	// The checker creates and type-checks the call — generic instantiation happens naturally.
	// (Reference: semFor → implicitIterator("items", collection) → semExpr)
	if (elemType.kind === TypeKind.Unknown && d.forOfIterable.nodeType !== null
			&& d.forOfIterable.nodeType.kind !== TypeKind.Unknown
			&& d.forOfIterable.nodeType.kind !== TypeKind.Error) {
		const loc = d.forOfIterable.location;
		const memberNode = createNodeAt(NodeKind.MemberExpr,
			{ object: d.forOfIterable, property: "toItems", isOptional: false }, loc);
		const toItemsCall = createNodeAt(NodeKind.CallExpr,
			{ callee: memberNode, arguments: [], isDirectCall: true, resolvedOverloadIdx: -1 }, loc);
		checkExpr(ctx, toItemsCall, null);
		if (toItemsCall.nodeType !== null && toItemsCall.nodeType.kind !== TypeKind.Error) {
			const resolved = iterableElemType(toItemsCall.nodeType);
			if (resolved.kind !== TypeKind.Unknown) {
				elemType = resolved;
				d.forOfIterable = toItemsCall;
			}
		}
	}
	// Ref parity: for loops — conservative, loop may not execute
	const oldInitState = saveInitState(ctx.initTracker);
	// PARALOCK Phase 1: snapshot before entering loop scope
	const affineSnap = saveConsumeState(ctx.affineTracker);
	const outerSpawnKeys = collectVisibleSpawnKeys(ctx.table.current);
	const saved = enterLoopScope(ctx);
	if (d.forOfPattern !== null) {
		// Destructured for-of: define symbols for each pattern element
		defineForOfPatternBindings(ctx, d.forOfPattern, elemType, d.forOfIsConst);
	} else {
		const forSym = makeSymbol(d.forOfBinding, SymbolKind.Variable, elemType, !d.forOfIsConst);
		defineSymbol(ctx.table, forSym);
		node.resolvedSym = forSym;
		// Loop binding is always initialized (iterator provides the value)
		markInitialized(ctx.initTracker, d.forOfBinding);
		sgRecordSym(ctx, d.bindingLocation.line, d.bindingLocation.column, d.bindingLocation.column + d.forOfBinding.length, forSym, elemType, SymbolKind.Variable, d.forOfBinding, "", true);
	}
	checkStmt(ctx, d.forOfBody);
	exitLoopScope(ctx, saved);
	restoreInitState(ctx.initTracker, oldInitState);
	detectLoopReuse(ctx, outerSpawnKeys, affineSnap, node.location.line, node.location.column);
	restoreConsumeState(ctx.affineTracker, affineSnap);
}

function defineForOfPatternBindings(ctx: CheckerContext, pattern: Node, iterType: Type, isConst: boolean): void {
	if (pattern.kind === NodeKind.ArrayPattern) {
		const apd = pattern.data as ArrayPatternData;
		let i = 0;
		while (i < apd.patternElements.length) {
			const elem = apd.patternElements[i];
			if (elem.kind === NodeKind.Identifier) {
				const id = elem.data as IdentifierData;
				if (id.name !== "_") {
					let elemType = unknownType();
					if (iterType !== null && iterType.kind === TypeKind.Tuple && iterType.typeChildren !== null && i < iterType.typeChildren.length) {
						elemType = iterType.typeChildren[i];
					} else if (iterType !== null && (iterType.kind === TypeKind.Array || iterType.kind === TypeKind.SizedArray) && iterType.typeReturn !== null) {
						// Array of tuples: element type from tuple children
						const tupleType = iterType.typeReturn;
						if (tupleType !== null && tupleType.kind === TypeKind.Tuple && tupleType.typeChildren !== null && i < tupleType.typeChildren.length) {
							elemType = tupleType.typeChildren[i];
						}
					}
					defineSymbol(ctx.table, makeSymbol(id.name, SymbolKind.Variable, elemType, !isConst));
					markInitialized(ctx.initTracker, id.name);
				}
			}
			i += 1;
		}
	} else if (pattern.kind === NodeKind.ObjectPattern) {
		const opd = pattern.data as ObjectPatternData;
		for (const prop of opd.patternProps) {
			if (prop.kind !== NodeKind.ObjectPatternProp) continue;
			const p = prop.data as ObjectPatternPropData;
			if (p.propAlias.kind === NodeKind.Identifier) {
				const id = p.propAlias.data as IdentifierData;
				defineSymbol(ctx.table, makeSymbol(id.name, SymbolKind.Variable, unknownType(), !isConst));
				markInitialized(ctx.initTracker, id.name);
			}
		}
	}
}

function checkForInStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as ForInStmtData;
	checkExpr(ctx, d.forInObject, null);
	const oldInitState = saveInitState(ctx.initTracker);
	const affineSnap = saveConsumeState(ctx.affineTracker);
	const outerSpawnKeys = collectVisibleSpawnKeys(ctx.table.current);
	const saved = enterLoopScope(ctx);
	defineSymbol(ctx.table, makeSymbol(d.forInBinding, SymbolKind.Variable, unknownType(), !d.forInIsConst));
	markInitialized(ctx.initTracker, d.forInBinding);
	checkStmt(ctx, d.forInBody);
	exitLoopScope(ctx, saved);
	restoreInitState(ctx.initTracker, oldInitState);
	detectLoopReuse(ctx, outerSpawnKeys, affineSnap, node.location.line, node.location.column);
	restoreConsumeState(ctx.affineTracker, affineSnap);
}

function checkDoWhileStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as DoWhileStmtData;
	// Ref parity: do-while body always executes once — propagate inits (no conservative restore)
	ctx.initTracker.currentBlock = ctx.initTracker.currentBlock + 1;
	// PARALOCK Phase 1: even though do-while runs at least once, iteration 2 would still
	// reuse any outer handle consumed in iteration 1 — so the same check applies.
	const affineSnap = saveConsumeState(ctx.affineTracker);
	const outerSpawnKeys = collectVisibleSpawnKeys(ctx.table.current);
	const saved = enterLoopScope(ctx);
	checkStmt(ctx, d.doBody);
	exitLoopScope(ctx, saved);
	detectLoopReuse(ctx, outerSpawnKeys, affineSnap, node.location.line, node.location.column);
	restoreConsumeState(ctx.affineTracker, affineSnap);
	ctx.initTracker.currentBlock = ctx.initTracker.currentBlock - 1;
	checkExpr(ctx, d.doCondition, null);
}

function checkBlock(ctx: CheckerContext, node: Node): void {
	const d = node.data as BlockStmtData;
	openScope(ctx.table, ScopeKind.Block);
	// Phase 4: guard-clause narrowing (`if (x === null) return; x.foo`) flows
	// automatically through the binder's post-if BranchLabel. The flow graph
	// sees the FalseCondition edge for the fall-through path and narrows
	// subsequent references via getFlowTypeOfReference.
	let i = 0;
	while (i < d.statements.length) {
		if (isCancelled(ctx.cancelCtx, ctx.cancelVersion)) { break; }
		checkStmt(ctx, d.statements[i]);
		i = i + 1;
	}
	// PARALOCK Phase 1: verify every affine Promise declared in this block was consumed
	checkAffineConsumption(ctx, ctx.table.current, ctx.affineTracker);
	closeScope(ctx.table);
}

function checkReturnStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as ReturnStmtData;
	if (ctx.currentFunction === null) {
		addError(ctx, "return outside of function", node.location.line, node.location.column);
	}
	if (d.argument === null) return;

	// `return null`: validate assignability with retType=Null FIRST, then stamp
	// d.argument.nodeType with the declared return type for codegen. The fast-path
	// here used to stamp-and-return, skipping the isAssignable check — that
	// allowed `function f(): Foo { return null; }` to silently compile even when
	// `Foo` is non-nullable. Order matters: stamp BEFORE check would compare
	// the expected type against itself (trivially passes); check BEFORE stamp
	// compares Null against expected, which is the real safety question.
	if (d.argument.kind === NodeKind.NullLiteral) {
		if (ctx.currentFunction !== null
			&& ctx.currentFunction.symbolType.kind === TypeKind.Function
			&& ctx.currentFunction.symbolType.typeReturn !== null) {
			const declared = ctx.currentFunction.symbolType.typeReturn;
			d.argument.nodeType = nullType();
			if (declared.kind !== TypeKind.Unknown && !isAssignable(nullType(), declared)) {
				addError(ctx,
					"Return type mismatch in '" + ctx.currentFunction.name + "': expected " + formatTypeBrief(declared) + ", got null",
					node.location.line, node.location.column);
				return;
			}
			// Stamp expected type for codegen (so value-type returns emit `(T){0}`,
			// pointer returns emit `NULL`, Maybe<T> returns emit a wrapper, etc.)
			d.argument.nodeType = declared;
		}
		return;
	}

	// Compute the effective expected return type once, use everywhere below.
	// Rules:
	//   - Inside a match expression block arm, `return` targets the match result
	//     (not the enclosing function) — no contextual type flows from the function.
	//   - For async functions, declared return is Promise<T> but `return X` returns T.
	//     Unwrap one Awaitable layer so contextual typing (checkExpr), node fitting
	//     (fitNode), and assignability checking all agree on T — without this, an
	//     object literal returned from an async function would be matched against
	//     Promise's fields, not T's.
	let returnExpected: Type | null = null;
	if (ctx.matchExprDepth === 0
		&& ctx.currentFunction !== null
		&& ctx.currentFunction.symbolType.kind === TypeKind.Function
		&& ctx.currentFunction.symbolType.typeReturn !== null
		&& ctx.currentFunction.symbolType.typeReturn.kind !== TypeKind.Unknown) {
		returnExpected = ctx.currentFunction.symbolType.typeReturn;
		if (hasFlag(ctx.currentFunction, SymbolFlag.Async)) {
			const unwrapped = awaitedType(returnExpected);
			if (unwrapped !== null) returnExpected = unwrapped;
		}
	}
	checkExpr(ctx, d.argument, returnExpected);
	const retType = d.argument !== null ? d.argument.nodeType : null;
	// PARALOCK Phase 1 R3/E4: affine Promise<T> cannot escape its creating scope.
	// Returning a affine Promise from a function lets its lifetime leak past the await,
	// which breaks the borrow-safety guarantee that spawn children stay pinned to
	// their parent's frame. Existing callers that need to pass around a promise
	// should explicitly upcast: `return spawn(...) as Promise<T>` (Phase 2+ may forbid).
	if (retType !== null && isAffineAwaitable(retType)) {
		addError(ctx,
			"affine Promise cannot be returned from a function; every spawn result must be awaited in its creating scope (PARALOCK R3/E4)",
			d.argument.location.line, d.argument.location.column);
	}
	// Parity: standard reference node fitting — insert HiddenStdConv for narrowing return,
	// or synthesize `as<TargetType>()` coercion via the protocol.
	if (returnExpected !== null) {
		d.argument = fitNode(ctx, d.argument, returnExpected, retType);
	}
	// Re-read the post-fitNode type so coercion-protocol substitutions
	// (e.g. `expr` → `expr.asNumber()`) are reflected in downstream checks.
	const finalRetType = d.argument !== null ? d.argument.nodeType : retType;
	// Track inferred return type (first return wins)
	if (ctx.matchExprDepth === 0 && ctx.inferredReturn !== null && ctx.inferredReturn.kind === TypeKind.Unknown) {
		ctx.inferredReturn = finalRetType;
	}
	// Assignability check against the (already-unwrapped) expected return type.
	if (returnExpected !== null
		&& finalRetType !== null
		&& finalRetType.kind !== TypeKind.Unknown
		&& finalRetType.kind !== TypeKind.Error
		&& !isAssignable(finalRetType, returnExpected)) {
		const got = formatTypeBrief(finalRetType);
		const expected = formatTypeBrief(returnExpected);
		addError(ctx, "Return type mismatch in '" + ctx.currentFunction.name + "': expected " + expected + ", got " + got, node.location.line, node.location.column);
	}
}

function checkTryCatch(ctx: CheckerContext, node: Node): void {
	const d = node.data as TryCatchStmtData;
	// Ref parity: trackTryStmt (sempass2 lines 524-597) — merge try + except
	const oldState = saveInitState(ctx.initTracker);
	const oldAffine = saveConsumeState(ctx.affineTracker);
	const oldInTry = ctx.inTryExpr;
	if (d.catchBody !== null) ctx.inTryExpr = true;
	checkStmt(ctx, d.tryBody);
	ctx.inTryExpr = oldInTry;
	const branchInits: string[][] = [collectNewInits(ctx.initTracker, oldState)];
	const branchConsumes: string[][] = [collectNewConsumes(ctx.affineTracker, oldAffine)];
	const branchBreaks: BreakState[] = [breaksBlock(d.tryBody)];

	if (d.catchBody !== null) {
		restoreInitState(ctx.initTracker, oldState);
		restoreConsumeState(ctx.affineTracker, oldAffine);
		openScope(ctx.table, ScopeKind.Block);
		if (d.catchName !== "") {
			const catchSym = makeSymbol(d.catchName, SymbolKind.Variable, unknownType(), false);
			defineSymbol(ctx.table, catchSym);
			// Catch param is always initialized (exception runtime provides it)
			markInitialized(ctx.initTracker, d.catchName);
			sgRecordSym(ctx, d.catchBindingLocation.line, d.catchBindingLocation.column, d.catchBindingLocation.column + d.catchName.length, catchSym, unknownType(), SymbolKind.Variable, d.catchName, "", true);
		}
		checkStmt(ctx, d.catchBody);
		branchInits.push(collectNewInits(ctx.initTracker, oldState));
		branchConsumes.push(collectNewConsumes(ctx.affineTracker, oldAffine));
		branchBreaks.push(breaksBlock(d.catchBody));
		// PARALOCK Phase 1: verify affine Promises in the catch binding scope are consumed
		checkAffineConsumption(ctx, ctx.table.current, ctx.affineTracker);
		closeScope(ctx.table);
	}

	// Merge: intersection of try + catch (init + affine trackers)
	mergeInitBranches(ctx.initTracker, oldState, branchInits, branchBreaks, d.catchBody !== null);
	mergeConsumeBranches(ctx.affineTracker, oldAffine, branchConsumes, branchBreaks, d.catchBody !== null);

	if (d.finallyBody !== null) {
		checkStmt(ctx, d.finallyBody);
	}
}

function checkSwitchStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as SwitchStmtData;
	checkExpr(ctx, d.switchDisc, null);
	// Ref parity: trackCase (sempass2 lines 809-845)
	const oldState = saveInitState(ctx.initTracker);
	const oldAffine = saveConsumeState(ctx.affineTracker);
	const branchInits: string[][] = [];
	const branchBreaks: BreakState[] = [];
	const branchConsumes: string[][] = [];
	let hasDefault = false;
	for (const c of d.switchCases) {
		const cd = c.data as SwitchCaseData;
		if (cd.caseTests.length === 0) hasDefault = true;
		restoreInitState(ctx.initTracker, oldState);
		restoreConsumeState(ctx.affineTracker, oldAffine);
		for (const t of cd.caseTests) { checkExpr(ctx, t, null); }
		for (const s of cd.caseStmts) { checkStmt(ctx, s); }
		branchInits.push(collectNewInits(ctx.initTracker, oldState));
		branchConsumes.push(collectNewConsumes(ctx.affineTracker, oldAffine));
		// Build a block from case stmts to check break state
		if (cd.caseStmts.length > 0) {
			branchBreaks.push(breaksBlock(cd.caseStmts[cd.caseStmts.length - 1]));
		} else {
			branchBreaks.push(BreakState.BsNone);
		}
	}
	mergeInitBranches(ctx.initTracker, oldState, branchInits, branchBreaks, hasDefault);
	mergeConsumeBranches(ctx.affineTracker, oldAffine, branchConsumes, branchBreaks, hasDefault);
}

function checkMatchStmt(ctx: CheckerContext, node: Node): void {
	const d = node.data as MatchStmtData;
	checkExpr(ctx, d.matchStmtDisc, null);
	const discType = d.matchStmtDisc.nodeType;
	let hasWildcard = false;
	const coveredMembers: string[] = [];

	// Detect discriminated union narrowing: match (base.discriminantField)
	// Handles both enum-based DUs (isDiscriminatedUnion) and string-literal DUs (Tier 2).
	let narrowBase: Symbol | null = null;
	let narrowUnion: Type | null = null;
	let narrowIsStringDU = false;
	let narrowDiscField = "";
	if (d.matchStmtDisc.kind === NodeKind.MemberExpr) {
		const discMd = d.matchStmtDisc.data as MemberExprData;
		if (discMd.object !== null && discMd.object.kind === NodeKind.Identifier) {
			const baseSym = lookupSymbol(ctx.table, (discMd.object.data as IdentifierData).name);
			if (baseSym !== null && baseSym.symbolType !== null) {
				const di = detectUnionDiscriminant(baseSym.symbolType, discMd.property);
				if (di.discField !== "") {
					narrowBase = baseSym;
					narrowUnion = baseSym.symbolType;
					narrowIsStringDU = di.isStringDU;
					narrowDiscField = di.discField;
				}
			}
		}
	}

	const oldState = saveInitState(ctx.initTracker);
	const oldAffine = saveConsumeState(ctx.affineTracker);
	const branchInits: string[][] = [];
	const branchBreaks: BreakState[] = [];
	const branchConsumes: string[][] = [];
	for (const c of d.matchStmtCases) {
		const cd = c.data as MatchCaseData;
		restoreInitState(ctx.initTracker, oldState);
		restoreConsumeState(ctx.affineTracker, oldAffine);
		const hasGuard = cd.caseGuard !== null;
		for (const p of cd.casePatterns) {
			if (p.kind === NodeKind.Identifier) {
				if (!hasGuard) hasWildcard = true;
				p.nodeType = discType;
			} else {
				if (p.kind === NodeKind.MemberExpr && !hasGuard) {
					const pmd = p.data as MemberExprData;
					coveredMembers.push(pmd.property);
				}
				// Tier 2: collect string literal patterns for exhaustiveness
				if (p.kind === NodeKind.StringLiteral && !hasGuard) {
					const sd = p.data as StringLiteralData;
					coveredMembers.push(sd.value);
				}
				checkExpr(ctx, p, discType);
			}
		}

		// Phase 4: per-arm variant narrowing flows through the binder's
		// synthesizeMatchArmFlow → TrueCondition → getFlowTypeOfReference path.
		// The checker no longer needs to push/pop narrowing state here.

		if (cd.caseGuard !== null) {
			checkExpr(ctx, cd.caseGuard, null);
		}
		checkStmt(ctx, cd.caseBody);

		branchInits.push(collectNewInits(ctx.initTracker, oldState));
		branchConsumes.push(collectNewConsumes(ctx.affineTracker, oldAffine));
		branchBreaks.push(breaksBlock(cd.caseBody));
	}
	checkDuplicatePatterns(ctx, d.matchStmtCases);

	// Match is exhaustive if has wildcard (_) or covers all enum members / string DU variants
	let isExhaustive = hasWildcard;
	if (!isExhaustive && discType.kind === TypeKind.Enum) {
		let allCovered = true;
		for (const member of discType.typeNames) {
			let found = false;
			for (const c of coveredMembers) {
				if (c === member) { found = true; }
			}
			if (!found) { allCovered = false; }
		}
		if (allCovered && discType.typeNames.length > 0) isExhaustive = true;
	}
	// Tier 2: string-literal DU exhaustiveness
	if (!isExhaustive && narrowIsStringDU && narrowUnion !== null) {
		const variantValues = collectStringDiscriminantValues(narrowUnion, narrowDiscField);
		if (variantValues.length > 0) {
			let allCovered = true;
			for (const v of variantValues) {
				let found = false;
				for (const c of coveredMembers) {
					if (c === v) { found = true; break; }
				}
				if (!found) { allCovered = false; break; }
			}
			if (allCovered) isExhaustive = true;
		}
	}
	mergeInitBranches(ctx.initTracker, oldState, branchInits, branchBreaks, isExhaustive);
	mergeConsumeBranches(ctx.affineTracker, oldAffine, branchConsumes, branchBreaks, isExhaustive);
	if (discType.kind === TypeKind.Enum && !hasWildcard) {
		const discEnd = estimateExprEndCol(d.matchStmtDisc) + 1;
		checkEnumExhaustiveness(ctx, discType, coveredMembers, node.location.line, node.location.column, discEnd);
	}
	// Tier 2: report missing string DU variants
	if (narrowIsStringDU && narrowUnion !== null && !hasWildcard) {
		const variantValues = collectStringDiscriminantValues(narrowUnion, narrowDiscField);
		for (const v of variantValues) {
			let found = false;
			for (const c of coveredMembers) {
				if (c === v) { found = true; break; }
			}
			if (!found) {
				addError(ctx, `Non-exhaustive match: missing variant '${v}'`,
					node.location.line, node.location.column);
			}
		}
	}
}

// ===== Function Body Checker =====

// Unified function body checker — works for FunctionDecl (resolved param types),
// MethodDecl, ConstructorDecl.
// paramLocs: per-param source locations for DEF recording (standard parity: semIdentDef → suggestSym)
export function checkFunctionBody(ctx: CheckerContext, sym: Symbol, params: string[], body: Node, paramLocs: SourceLocation[]): void {
	const savedFunction = ctx.currentFunction;
	const savedMatchDepth = ctx.matchExprDepth;
	ctx.currentFunction = sym;
	ctx.matchExprDepth = 0;
	// Ref parity: trackProc (sempass2 lines 1662-1698) — scope + param init
	const savedBlock = ctx.initTracker.currentBlock;
	ctx.initTracker.currentBlock = ctx.initTracker.currentBlock + 1;
	const initSnap = saveInitState(ctx.initTracker);
	// PARALOCK Phase 1: snapshot affine tracker so affine Promise consumption state
	// doesn't leak across function body boundaries.
	const affineSnap = saveConsumeState(ctx.affineTracker);
	openScope(ctx.table, ScopeKind.Function);
	let i = 0;
	for (const param of params) {
		let paramType = unknownType();
		if (sym !== null && sym.symbolType.kind === TypeKind.Function && i < sym.symbolType.typeChildren.length) {
			paramType = sym.symbolType.typeChildren[i];
		}
		// Strip "..." prefix from rest params (parser stores "...name", checker uses "name")
		const paramName = param.length > 3 && param.startsWith("...") ? param.slice(3, param.length) : param;
		const paramSym = makeSymbol(paramName, SymbolKind.Parameter, paramType, false);
		// Set declaration location for go-to-definition
		if (paramLocs !== null && i < paramLocs.length && paramLocs[i] !== null) {
			paramSym.location = paramLocs[i];
		}
		// Receiver is implicitly LENT (borrowed)
		if (param === "this" || (i === 0 && param === "self")) {
			setFlag(paramSym, SymbolFlag.Lent);
		}
		defineSymbol(ctx.table, paramSym);
		// Ref parity: params are implicitly initialized
		markInitialized(ctx.initTracker, paramName);
		// Record param DEF for LSP (standard parity: semIdentDef → suggestSym)
		if (paramLocs !== null && i < paramLocs.length && paramLocs[i] !== null) {
			sgRecordSym(ctx, paramLocs[i].line, paramLocs[i].column,
				paramLocs[i].column + paramName.length,
				paramSym, paramType, SymbolKind.Parameter, paramName, "", true);
		}
		i += 1;
	}
	if (body.kind === NodeKind.BlockStmt) {
		checkStmt(ctx, body);
	} else {
		// Expression body (arrow functions) — infer return type
		checkExpr(ctx, body, null);
		const exprType = body.nodeType;
		if (ctx.inferredReturn.kind === TypeKind.Unknown) {
			ctx.inferredReturn = exprType;
		}
	}
	closeScope(ctx.table);
	// Restore init tracking state
	restoreInitState(ctx.initTracker, initSnap);
	// PARALOCK Phase 1: restore affine tracker (erases this function's consumed set)
	restoreConsumeState(ctx.affineTracker, affineSnap);
	ctx.initTracker.currentBlock = savedBlock;
	ctx.currentFunction = savedFunction;
	ctx.matchExprDepth = savedMatchDepth;
}

function enterLoopScope(ctx: CheckerContext): boolean {
	const saved = ctx.inLoop;
	ctx.inLoop = true;
	openScope(ctx.table, ScopeKind.Loop);
	return saved;
}

function exitLoopScope(ctx: CheckerContext, saved: boolean): void {
	// PARALOCK Phase 1: verify affine Promises in loop scope are consumed
	checkAffineConsumption(ctx, ctx.table.current, ctx.affineTracker);
	closeScope(ctx.table);
	ctx.inLoop = saved;
}

function checkDestructuringDecl(ctx: CheckerContext, node: Node): void {
	const d = node.data as DestructuringDeclData;
	checkExpr(ctx, d.destrInit, null);
}

// ===== Check Program Body =====

export function checkProgramBody(ctx: CheckerContext, program: Node): void {
	const stmts = program.data as ProgramData;
	for (const stmt of stmts.programStmts) {
		if (isCancelled(ctx.cancelCtx, ctx.cancelVersion)) return;
		checkStmt(ctx, stmt);
	}
}

// ===== Main Entry Point =====

// Run all 3 passes on a program node with an existing context
export function runThreePasses(ctx: CheckerContext, program: Node): void {
	collectTopLevel(ctx, program);
	resolveDeclarations(ctx, program);
	bindFlowGraph(program);  // Phase 1: build the CFG (unused by checker yet — Phase 2 will query)
	checkProgramBody(ctx, program);
	if (ctx.modulePath !== "") reportUnusedSymbols(ctx, program);
}

// Mark symbols referenced inside a macro body as used.
// Macro bodies are not type-checked (they run in the Raiser VM), but their
// identifiers (e.g. NodeKind in `NodeKind.BinaryExpr`) come from imports that
// would otherwise be reported as unused.
function markMacroUsedSymbols(ctx: CheckerContext, node: Node): void {
	const d = node.data as MacroDeclData;
	// Mark param type names as used (e.g. `x: Node` → mark Node)
	for (const paramType of d.macroDeclParamTypes) {
		if (paramType !== "") {
			const sym = lookupSymbol(ctx.table, paramType);
			if (sym !== null) markUsed(sym);
		}
	}
	markMacroBodyUsed(ctx, d.macroDeclBody);
}

function markMacroBodyUsed(ctx: CheckerContext, node: Node): void {
	if (node === null) return;
	if (node.kind === NodeKind.Identifier) {
		const id = node.data as IdentifierData;
		const sym = lookupSymbol(ctx.table, id.name);
		if (sym !== null) markUsed(sym);
	}
	forEachChild(node, (child: Node): void => {
		markMacroBodyUsed(ctx, child);
	});
}

// Two-phase unused detection (reference parity).
// Phase A: local symbols → Hint severity ("declared but not used") — uses sym.location
// Phase B: unused imports → Warning severity ("imported but not used") — uses ImportDecl.nameLocations
function reportUnusedSymbols(ctx: CheckerContext, program: Node): void {
	// Phase B: walk ImportDecl nodes for correct source positions
	reportUnusedImports(ctx, program);

	// Phase A: local symbols (non-imported)
	const scope = ctx.table.current;
	for (const sym of scope.symbols.values()) {
		if (hasFlag(sym, SymbolFlag.Used)) continue;
		if (hasFlag(sym, SymbolFlag.Exported)) continue;
		if (sym.name.length === 0) continue;
		if (sym.name.charAt(0) === "_") continue;
		if (sym.builtinKind !== "") continue;
		// Reference parity skip list: for-vars, params, methods, enum fields, generic params
		if (sym.symbolKind === SymbolKind.Parameter) continue;
		if (sym.symbolKind === SymbolKind.Method) continue;
		if (sym.symbolKind === SymbolKind.Function) continue;
		// Skip enum members
		if (sym.symbolType !== null && sym.symbolType.kind === TypeKind.Enum
			&& sym.symbolKind === SymbolKind.Variable) continue;
		// Skip imported symbols — handled by Phase B with correct positions
		if (sym.modulePath !== "" && sym.modulePath !== ctx.modulePath) continue;
		if (hasFlag(sym, SymbolFlag.ImportC)) continue;
		if (hasFlag(sym, SymbolFlag.Global)) continue;
		if (sym.location === null || sym.location.line <= 0) continue;
		const endCol = sym.location.column + sym.name.length;
		addHintRange(ctx, `'${sym.name}' is declared but never used`, sym.location.line, sym.location.column, endCol, 1);
	}
}

// Phase B: report unused imports using ImportDecl.nameLocations for correct positions.
// sym.location points to the original declaration in the source module — wrong for diagnostics.
function reportUnusedImports(ctx: CheckerContext, program: Node): void {
	if (program === null || program.kind !== NodeKind.Program) return;
	const pd = program.data as ProgramData;
	for (const stmt of pd.programStmts) {
		let importNode = stmt;
		// Unwrap ExportDecl (re-exports)
		if (importNode.kind === NodeKind.ExportDecl) {
			const ed = importNode.data as ExportDeclData;
			importNode = ed.exportedDecl;
		}
		if (importNode.kind !== NodeKind.ImportDecl) continue;
		const imp = importNode.data as ImportDeclData;
		if (imp.nameLocations === null) continue;
		for (let ii = 0; ii < imp.importAliases.length; ii += 1) {
			const alias = imp.importAliases[ii];
			if (alias.length === 0) continue;
			if (alias.charAt(0) === "_") continue;
			const sym = lookupSymbol(ctx.table, alias);
			if (sym === null) continue;
			if (hasFlag(sym, SymbolFlag.Used)) continue;
			if (hasFlag(sym, SymbolFlag.Exported)) continue;
			if (ii >= imp.nameLocations.length) continue;
			const nameLoc = imp.nameLocations[ii];
			if (nameLoc === null || nameLoc.line <= 0) continue;
			const name = imp.importNames[ii];
			const endCol = nameLoc.column + name.length;
			addWarningRange(ctx, `'${alias}' is imported but never used`, nameLoc.line, nameLoc.column, endCol, 1);
		}
	}
}

// Process a single MacroInvocation node as a directive (@include/@link/@passC/@passL).
function collectOneDirective(ctx: CheckerContext, mi: Node): void {
	if (mi.kind !== NodeKind.MacroInvocation) return;
	const md = mi.data as MacroInvocationData;
	if (md.macroArgs.length === 0 || md.macroArgs[0].kind !== NodeKind.StringLiteral) return;
	const sd = md.macroArgs[0].data as StringLiteralData;
	const name = md.macroName;
	if (name === "include") {
		if (ctx.includeDirectives !== "") ctx.includeDirectives = ctx.includeDirectives + "\n";
		ctx.includeDirectives = ctx.includeDirectives + sd.value;
		const modDir = getModuleDir(ctx.modulePath);
		if (modDir !== "") ctx.compilerFlags = appendFlag(ctx.compilerFlags, "-iquote" + modDir);
	} else if (name === "compile") {
		if (ctx.compileDirectives !== "") ctx.compileDirectives = ctx.compileDirectives + "\n";
		// Per-file custom flags: @compile("file.c", "-O3") → "file.c\t-O3" (tab-separated)
		let entry = sd.value;
		if (md.macroArgs.length >= 2 && md.macroArgs[1].kind === NodeKind.StringLiteral) {
			const flagsArg = md.macroArgs[1].data as StringLiteralData;
			entry = entry + "\t" + flagsArg.value;
		}
		ctx.compileDirectives = ctx.compileDirectives + entry;
	} else if (name === "passC") {
		ctx.compilerFlags = appendFlag(ctx.compilerFlags, sd.value);
	} else if (name === "link") {
		// Resolve @link paths relative to declaring module's directory (like @compile).
		// Prepend to link list (reference-aligned: linked first, like addExternalFileToLink).
		const modDir = getModuleDir(ctx.modulePath);
		const resolved = modDir !== "" ? modDir + "/" + sd.value : sd.value;
		linkObjects().add(resolved);
	} else if (name === "passL") {
		linkFlags().add(sd.value);
	} else if (name === "import") {
		// @import("module", { name1, name2 }) — JS external module registry.
		// First arg is module path (string), second is ObjectLiteral with keys = import names.
		const names: string[] = [];
		if (md.macroArgs.length >= 2 && md.macroArgs[1].kind === NodeKind.ObjectLiteral) {
			const od = md.macroArgs[1].data as ObjectLiteralData;
			for (const k of od.keys) {
				names.push(k);
			}
		}
		const entry: JsImportEntry = { modulePath: sd.value, names };
		ctx.jsImportRegistry.push(entry);
	}
}

// Extract @include/@link/@passC/@passL directives from program AST into context.
// Handles both standalone directives (@name("x");) and decorators (@name("x") decl).
export function collectDirectives(ctx: CheckerContext, program: Node): void {
	if (program === null) return;
	if (program.kind !== NodeKind.Program) return;
	const pd = program.data as ProgramData;
	for (let i = 0; i < pd.programStmts.length; i += 1) {
		const stmt = pd.programStmts[i];
		if (stmt.kind === NodeKind.ExprStmt) {
			const d = stmt.data as ExprStmtData;
			collectOneDirective(ctx, d.expr);
		} else if (stmt.kind === NodeKind.DecoratedDecl) {
			const dd = stmt.data as DecoratedDeclData;
			for (const dec of dd.decorators) {
				collectOneDirective(ctx, dec);
			}
		}
	}
}

// Stamp @include headers on all ImportC symbols in current scope.
// Called after collectDirectives so ctx.includeDirectives is populated.
export function stampHeaderPaths(ctx: CheckerContext): void {
	if (ctx.includeDirectives === "") return;
	const scope = ctx.table.current;
	for (const sym of scope.symbols.values()) {
		if (hasFlag(sym, SymbolFlag.ImportC) && sym.headerPath === "") {
			sym.headerPath = ctx.includeDirectives;
		}
	}
}

// Stamp @import JS module paths on ImportC symbols whose name matches a registry entry.
// Called after collectDirectives so ctx.jsImportRegistry is populated.
export function stampJsModulePaths(ctx: CheckerContext): void {
	if (ctx.jsImportRegistry.length === 0) return;
	const scope = ctx.table.current;
	for (const sym of scope.symbols.values()) {
		if (hasFlag(sym, SymbolFlag.ImportC) && sym.jsModulePath === "") {
			// Look up the extern's nativeName (or declared name) in the registry
			const lookupName = sym.nativeName !== "" ? sym.nativeName : sym.name;
			for (const entry of ctx.jsImportRegistry) {
				for (const n of entry.names) {
					if (n === lookupName) {
						sym.jsModulePath = entry.modulePath;
						break;
					}
				}
				if (sym.jsModulePath !== "") break;
			}
		}
	}
}

function defineBuiltinConstants(ctx: CheckerContext): void {
	const nanSym = makeSymbol("NaN", SymbolKind.Variable, float64Type(), false);
	nanSym.state = SymbolState.Checked;
	nanSym.builtinKind = "NaN";
	defineSymbol(ctx.table, nanSym);
	const infSym = makeSymbol("Infinity", SymbolKind.Variable, float64Type(), false);
	infSym.state = SymbolState.Checked;
	infSym.builtinKind = "Infinity";
	defineSymbol(ctx.table, infSym);
}

// ===== Unified Prelude Loading (reference parity: single pipeline) =====

// Load a single prelude module into a context. Shared by all paths.
// backendExt: ".cms" for C (default), ".jms" for JS.
// Resolution order: backend extension first, then .ms fallback. Same rule as module resolver.
function loadPreludeOne(ctx: CheckerContext, specifier: string, stdPath: string, backendExt: string): void {
	const base = stdPath.length > 0 ? stdPath + "/" + specifier.slice(4, specifier.length) : specifier;
	// Try direct .ms first (e.g., std/core/struct.ms)
	let src = try readFile(base + ".ms") catch "";
	let resolvedPath = base + ".ms";
	// Backend extension (e.g., index.jms for JS, index.cms for C, index.wms for WASM)
	if (src.length === 0) {
		src = try readFile(base + "/index" + backendExt) catch "";
		resolvedPath = base + "/index" + backendExt;
	}
	// WASM fallback to .cms (WASM is still C backend, .wms overrides .cms)
	if (src.length === 0 && backendExt === ".wms") {
		src = try readFile(base + "/index.cms") catch "";
		resolvedPath = base + "/index.cms";
	}
	// Fallback to .ms
	if (src.length === 0) {
		src = try readFile(base + "/index.ms") catch "";
		resolvedPath = base + "/index.ms";
	}
	if (src.length > 0) {
		// Inline .h imports (e.g., import from "runtime/fs.h") before parsing
		const fsProvider = createFileSystemProvider();
		src = inlineHeaderImports(src, resolvedPath, fsProvider);
		const pr = parseSource(src);
		if (pr.ok) {
			// Set modulePath BEFORE sub-module loading so path resolution is consistent
			const savedPath = ctx.modulePath;
			ctx.modulePath = resolvedPath;

			// Load sub-modules first (dependency-first, recursive compilation)
			// Register sub-module exports in ExportRegistry so index.cms re-exports resolve
			loadPreludeSubModules(ctx, pr.value, resolvedPath, stdPath);
			runThreePasses(ctx, pr.value);
			ctx.modulePath = savedPath;
			collectDirectives(ctx, pr.value);
			stampHeaderPaths(ctx);
			stampJsModulePaths(ctx);
			const scope = ctx.table.current;
			for (const sym of scope.symbols.values()) {
				ensureShaped(sym, ctx);
				for (const ov of sym.overloads) {
					ensureShaped(ov, ctx);
				}
			}
		}
	}
}

// Strip the trailing module extension to recover the bare path. The bare
// form is what `resolveImportSourcePath` and relative-import resolution
// produce, so the registry must accept both. Order matters: longer
// suffixes (`/index.ms`) must precede shorter ones (`.ms`) so the
// `/index` form isn't misread as a bare `.ms`.
function stripModuleExtension(path: string): string {
	for (const suffix of ["/index.ms", "/index.cms", ".ms", ".cms"]) {
		if (path.endsWith(suffix)) return path.slice(0, path.byteLength - suffix.byteLength);
	}
	return path;
}

// Resolve a sub-module specifier to (sourcePath, sourceText). Handles both
// relative (`./sub`, `../sub`) and absolute std paths (`std/serialize/json/decode`).
// Returns ("", "") if the file isn't readable. Centralized so both relative
// re-exports and absolute direct imports share the same resolution rules.
function resolvePreludeSubSource(specifier: string, indexDir: string, stdPath: string): { path: string, source: string } {
	let basePath = "";
	if (specifier.length >= 2 && specifier.charAt(0) === ".") {
		// Relative: resolve against the index file's directory
		let rel = specifier;
		if (rel.length > 2 && rel.slice(0, 2) === "./") {
			rel = rel.slice(2, rel.length);
		}
		basePath = indexDir + "/" + rel;
	} else if (specifier.length > 4 && specifier.slice(0, 4) === "std/" && stdPath !== "") {
		// Absolute std path: stdPath is the std/ root
		basePath = stdPath + "/" + specifier.slice(4, specifier.length);
	} else {
		return { path: "", source: "" };
	}

	for (const ext of [".ms", ".cms", "/index.ms", "/index.cms"]) {
		const path = basePath + ext;
		const src = try readFile(path) catch "";
		if (src.length > 0) return { path, source: src };
	}
	if (basePath.endsWith(".h")) {
		const hSrc = try readFile(basePath) catch "";
		if (hSrc.length > 0) return { path: basePath, source: translateCHeader(hSrc, []) };
	}
	return { path: "", source: "" };
}

// Load prelude sub-modules referenced by:
//   - relative re-exports: `export { X } from "./sub"`
//   - relative direct imports: `import { X } from "./sub"`
//   - absolute direct imports from std/: `import { X } from "std/serialize/json/decode"`
//
// Each sub-module is fully compiled (3 passes) before the parent runs its
// own checking. Exports are registered in ExportRegistry so the parent's
// collectImport resolves macro symbols (kind, body, params) instead of
// falling back to Variable. Reference-aligned: matches the dep-first
// ordering compile.ms's loadPreludeModules uses for the module graph.
//
// Cycle/dedup: skips if subResolved is already in ExportRegistry (compiled
// earlier) — preludes form a DAG, not a tree.
function loadPreludeSubModules(ctx: CheckerContext, program: Node, indexPath: string, stdPath: string): void {
	if (program.kind !== NodeKind.Program) return;
	const pd = program.data as ProgramData;
	const dir = getModuleDir(indexPath);
	if (dir === "") return;

	for (const stmt of pd.programStmts) {
		// Two shapes carry an import specifier we may need to pre-load:
		//   ExportDecl wrapping ImportDecl  →  re-export (`export { X } from`)
		//   ImportDecl directly             →  direct import (`import { X } from`)
		let importDeclNode: Node = null as unknown as Node;
		if (stmt.kind === NodeKind.ExportDecl) {
			const ed = stmt.data as ExportDeclData;
			if (ed.exportedDecl !== null && ed.exportedDecl.kind === NodeKind.ImportDecl) {
				importDeclNode = ed.exportedDecl;
			}
		} else if (stmt.kind === NodeKind.ImportDecl) {
			importDeclNode = stmt;
		}
		if (importDeclNode === null) continue;

		const id = importDeclNode.data as ImportDeclData;
		const resolved = resolvePreludeSubSource(id.importSource, dir, stdPath);
		const subResolved = resolved.path;
		let subSrc = resolved.source;
		if (subSrc.length === 0) continue;

		// Dedup: if already loaded into the shared registry, skip. Preludes
		// can reference the same module via different paths (e.g., one prelude
		// imports std/serialize/json/decode, another re-exports it relatively).
		if (findModuleExports(ctx.exportRegistry, subResolved) !== null) continue;
		// Inline .h imports in sub-module source before parsing
		subSrc = inlineHeaderImports(subSrc, subResolved, createFileSystemProvider());
		const subPr = parseSource(subSrc);
		if (!subPr.ok) continue;
		// Recurse: pre-load THIS sub-module's own prelude-resolvable imports
		// before running its 3 passes. Ensures e.g. std/serialize/json/decode's import
		// of std/meta is loaded before std/serialize/json/decode is checked, so its
		// macro body has the type-meta symbols resolved.
		loadPreludeSubModules(ctx, subPr.value, subResolved, stdPath);

		// Compile sub-module in a temporary context (separate scope, shared cache)
		const subCtx = createContextWithCache(ctx.table.identCache);
		subCtx.extensionRegistry = createExtensionRegistry();
		subCtx.exportRegistry = ctx.exportRegistry;
		// Inject prelude symbols so sub-module can reference them
		for (const sym of ctx.table.current.symbols.values()) {
			addSymbolToScope(subCtx.table.current, sym);
		}
		// Copy parent extensions so sub-module can use string/array methods
		if (ctx.extensionRegistry !== null) {
			for (const ext of ctx.extensionRegistry.methods) {
				registerExtension(subCtx.extensionRegistry, ext);
			}
		}
		openScope(subCtx.table, ScopeKind.Module);
		subCtx.modulePath = subResolved;
		runThreePasses(subCtx, subPr.value);

		// Stamp headerPath on .h-translated symbols so C codegen emits #include
		const subScope = subCtx.table.current;
		if (subResolved.endsWith(".h")) {
			for (const sym of subScope.symbols.values()) {
				if (hasFlag(sym, SymbolFlag.ImportC) && sym.headerPath === "") {
					sym.headerPath = subResolved;
				}
			}
		}

		// Register sub-module's exported symbols in ExportRegistry
		const subExports: ExportedSymInfo[] = [];
		for (const sym of subScope.symbols.values()) {
			if (hasFlag(sym, SymbolFlag.Exported)) {
				subExports.push(buildExportInfo(sym, subCtx.extensionRegistry, subResolved, subCtx));
			}
		}
		registerModuleExports(ctx.exportRegistry, subResolved, subExports);
		// Also register the bare path so collectImport's relative resolution
		// (which strips the extension) hits the same entry.
		const bare = stripModuleExtension(subResolved);
		if (bare !== subResolved) {
			registerModuleExports(ctx.exportRegistry, bare, subExports);
		}

		// Also register sub-module extensions into parent context
		if (subCtx.extensionRegistry !== null && ctx.extensionRegistry !== null) {
			for (const ext of subCtx.extensionRegistry.methods) {
				if (ext.sym !== null && hasFlag(ext.sym, SymbolFlag.Exported)) {
					registerExtension(ctx.extensionRegistry, ext);
				}
			}
		}
	}
}

// Build a prelude context with all globalImports loaded.
// Used by both standalone checkProgram and orchestrator.
// Creates a shared IdentCache (one cache per compilation)
// that must be passed to all module contexts in the same compilation.
export function buildPreludeContext(stdPath: string, backendExt: string = ".cms"): CheckerContext {
	const cache = createIdentCache();
	const ctx = createContextWithCache(cache);
	ctx.extensionRegistry = createExtensionRegistry();
	const imps = globalImports();
	let idx = 0;
	while (idx < imps.length) {
		loadPreludeOne(ctx, imps[idx], stdPath, backendExt);
		idx = idx + 1;
	}
	return ctx;
}

// Get the shared IdentCache from a prelude context.
export function getSharedIdentCache(ctx: CheckerContext): IdentCache {
	return ctx.table.identCache;
}

// Inject exported prelude symbols, extensions, and directives into a module context.
// NOTE: Uses while loops (not for-of) so DRC properly increfs shared symbols.
// for-of creates cursor bindings that skip RC — pushing cursors into another
// container creates dangling pointers when the source is destroyed.
export function injectPrelude(ctx: CheckerContext, preludeCtx: CheckerContext): void {
	// With shared IdentCache, nameIds are already consistent across all contexts
	// in the same compilation. Map iteration preserves insertion order.
	for (const sym of preludeCtx.table.current.symbols.values()) {
		if (hasFlag(sym, SymbolFlag.Exported)) {
			addSymbolToScope(ctx.table.current, sym);
		}
	}
	if (preludeCtx.extensionRegistry !== null && ctx.extensionRegistry !== null) {
		const preludeExts = preludeCtx.extensionRegistry.methods;
		let ei = 0;
		while (ei < preludeExts.length) {
			const ext = preludeExts[ei];
			if (ext.sym !== null && hasFlag(ext.sym, SymbolFlag.Exported)) {
				// Imported extensions get scope depth 0 (other module).
				// Don't mutate ext — preludeCtx may be cached across modules (LSP TransAmDb).
				registerExtension(ctx.extensionRegistry, createExtMethod(ext.methodName, ext.receiverTypeName, ext.sourcePath, ext.fnType, ext.isStatic, ext.sym, 0));
			}
			ei = ei + 1;
		}
	}
	if (preludeCtx.includeDirectives !== "") {
		if (ctx.includeDirectives !== "") ctx.includeDirectives = ctx.includeDirectives + "\n";
		ctx.includeDirectives = ctx.includeDirectives + preludeCtx.includeDirectives;
	}
	// NOTE: compileDirectives are NOT merged per-module. They are processed once
	// from the prelude context in cmdBuildC. Module-level DCE filters dead modules'
	// @compile objects at the compile.ms level.
	if (preludeCtx.compilerFlags !== "") {
		ctx.compilerFlags = appendFlag(ctx.compilerFlags, preludeCtx.compilerFlags);
	}
	// @passL/@link go directly to global linkState — no per-module merge needed
}

// Single internal entry point for all checkProgram variants.
function checkProgramCore(
	program: Node,
	preludeCtx: CheckerContext,
	registry: ExportRegistry,
	graph: ModuleGraph,
	mod: Module,
	cancelCtx: CancelCtx,
	cancelVersion: number,
): CheckerContext {
	// Use shared IdentCache from prelude (one cache per compilation)
	const sharedCache = preludeCtx.table.identCache;
	const ctx = mod !== null ? createModuleContextWithCache(graph, mod, sharedCache) : createContextWithCache(sharedCache);
	ctx.extensionRegistry = createExtensionRegistry();
	if (registry !== null) ctx.exportRegistry = registry;  // override empty default with caller's registry
	if (cancelCtx !== null) { ctx.cancelCtx = cancelCtx; ctx.cancelVersion = cancelVersion; }
	injectPrelude(ctx, preludeCtx);
	ctx.preludeCtx = preludeCtx;  // friend modules — access private prelude symbols during instantiation
	const consoleClass = lookupSymbol(ctx.table, "console");
	if (consoleClass !== null) {
		const consoleGlobal = makeSymbol("console", SymbolKind.Variable, consoleClass.symbolType, false);
		defineSymbol(ctx.table, consoleGlobal);
		consoleGlobal.state = SymbolState.Shaped;
	}
	const promiseClass = lookupSymbol(ctx.table, "Promise");
	if (promiseClass !== null) {
		const promiseGlobal = makeSymbol("Promise", SymbolKind.Variable, promiseClass.symbolType, false);
		defineSymbol(ctx.table, promiseGlobal);
		promiseGlobal.state = SymbolState.Shaped;
	}
	defineBuiltinConstants(ctx);
	openScope(ctx.table, ScopeKind.Module);
	runThreePasses(ctx, program);
	collectDirectives(ctx, program);
	stampHeaderPaths(ctx);
	stampJsModulePaths(ctx);
	inferOwnership(ctx, program);
	analyzeParamMutations(ctx, program);
	sgSortRecords(ctx.symRecords);
	// Register this module's ctx so later cross-module generic instantiation can
	// re-check cloned bodies in THIS module's scope (resolving private consts,
	// helper functions, etc.). Reference parity: Nim's graph.ifaces[module].
	registerModuleCtx(ctx.modulePath, ctx);
	return ctx;
}

// ===== Public API =====

// Convenience wrapper — creates empty registry. For inline tests and CLI tools
// that don't need cross-module resolution.
export function checkProgram(program: Node): CheckerContext {
	// Discover the stdPath from the compiler's install location so prelude
	// (console, print, Result, etc.) loads for `msc check` regardless of cwd.
	const root = resolveRuntimeDir();
	const stdPath = root !== "" ? join(root, "std") : "";
	const preludeCtx = buildPreludeContext(stdPath);
	return checkProgramCore(program, preludeCtx, null as unknown as ExportRegistry, null as unknown as ModuleGraph, null as unknown as Module, null as unknown as CancelCtx, 0);
}

export function checkProgramWithRegistry(program: Node, registry: ExportRegistry, graph: ModuleGraph, mod: Module, preludeCtx: CheckerContext): CheckerContext {
	return checkProgramCore(program, preludeCtx, registry, graph, mod, null as unknown as CancelCtx, 0);
}

export function checkProgramWithRegistryCancellable(
	program: Node, registry: ExportRegistry,
	graph: ModuleGraph, mod: Module,
	preludeCtx: CheckerContext,
	cancelCtx: CancelCtx, cancelVersion: number
): CheckerContext {
	return checkProgramCore(program, preludeCtx, registry, graph, mod, cancelCtx, cancelVersion);
}

// Register callbacks at module load time
registerCheckStmt((ctx: CheckerContext, node: Node): void => { checkStmt(ctx, node); });
registerCheckFunctionBody((ctx: CheckerContext, sym: Symbol, params: string[], body: Node, paramLocs: SourceLocation[]): void => { checkFunctionBody(ctx, sym, params, body, paramLocs); });

// ===== Tests =====

export function checkSource(input: string): CheckerContext {
	const pr = parseSource(input);
	if (!pr.ok) return createContext();
	return checkProgram(pr.value);
}

function checkOk(input: string): boolean {
	const ctx = checkSource(input);
	return !hasErrors(ctx);
}

function checkErrors(input: string): number {
	const ctx = checkSource(input);
	return errorCount(ctx);
}

test "variable decl" {
	assert checkOk("const x = 1;");
	assert checkOk("let y = 2;");
	assert checkOk("var z = 3;");
}

test "variable use" { assert checkOk("const x = 1; const y = x;"); }

test "undefined variable" {
	assert !checkOk("const x = y;");
	assert checkErrors("const x = y;") === 1;
}

test "function scope" { assert checkOk("function foo(a, b) { const x = a; }"); }

test "forward reference" { assert checkOk("const x = foo; function foo() { return 1; }"); }

test "block scope" { assert checkOk("const x = 1; if (true) { const y = x; }"); }

test "nested scope isolation" { assert !checkOk("if (true) { const y = 1; } const z = y;"); }

test "break in loop" { assert checkOk("while (true) { break; }"); }

test "break outside loop" { assert !checkOk("break;"); }

test "continue in loop" { assert checkOk("for (let i = 0; i < 10; i++) { continue; }"); }

test "continue outside loop" { assert !checkOk("continue;"); }

test "for-of binding" { assert checkOk("const items = 1; for (const item of items) { const x = item; }"); }

test "return in function" { assert checkOk("function foo() { return 1; }"); }

test "return outside function" { assert !checkOk("return 1;"); }

test "class method scope" { assert checkOk("class Foo { bar(x) { return x; } }"); }

test "try-catch param" { assert checkOk("try { const x = 1; } catch (e) { const y = e; }"); }

test "arrow function" { assert checkOk("const f = (x) => x;"); }

test "number type" {
	const ctx = checkSource("const x = 42;");
	const sym = lookupSymbol(ctx.table, "x");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Int32;
}

test "string type" {
	const ctx = checkSource("const s = \"hello\";");
	const sym = lookupSymbol(ctx.table, "s");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.String;
}

test "boolean type" {
	const ctx = checkSource("const b = true;");
	const sym = lookupSymbol(ctx.table, "b");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Boolean;
}

test "null type" {
	const ctx = checkSource("const n = null;");
	const sym = lookupSymbol(ctx.table, "n");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Null;
}

test "arithmetic returns number" {
	const ctx = checkSource("const x = 1 + 2;");
	const sym = lookupSymbol(ctx.table, "x");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Int32;
}

test "string concat returns string" {
	const ctx = checkSource("const x = \"a\" + \"b\";");
	const sym = lookupSymbol(ctx.table, "x");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.String;
}

test "comparison returns boolean" {
	const ctx = checkSource("const x = 1 < 2;");
	const sym = lookupSymbol(ctx.table, "x");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Boolean;
}

test "equality returns boolean" {
	const ctx = checkSource("const x = 1 === 2;");
	const sym = lookupSymbol(ctx.table, "x");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Boolean;
}

test "negation returns boolean" {
	const ctx = checkSource("const x = !true;");
	const sym = lookupSymbol(ctx.table, "x");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Boolean;
}

test "unary minus returns number" {
	const ctx = checkSource("const x = -5;");
	const sym = lookupSymbol(ctx.table, "x");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Int32;
}

test "function has Function type after resolve" {
	const ctx = checkSource("function foo(a, b) { return 1; }");
	const sym = lookupSymbol(ctx.table, "foo");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Function;
	assert sym.symbolType.typeChildren.length === 2;
	assert sym.symbolType.typeNames.length === 2;
}

test "call returns function return type" {
	const ctx = checkSource("function foo(a, b) { return 1; } const x = foo(1, 2);");
	const sym = lookupSymbol(ctx.table, "x");
	assert sym !== null;
	// foo's return type inferred as int32 from body (integer literal → int32)
	assert sym.symbolType.kind === TypeKind.Int32;
}

test "forward reference to function is callable" {
	const ctx = checkSource("const x = foo(1); function foo(a) { return 1; }");
	assert !hasErrors(ctx);
}

test "typed function params resolved" {
	const ctx = checkSource("function add(a: number, b: number): number { return a; }");
	const sym = lookupSymbol(ctx.table, "add");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Function;
	assert sym.symbolType.typeChildren[0].kind === TypeKind.Number;
	assert sym.symbolType.typeChildren[1].kind === TypeKind.Number;
	assert sym.symbolType.typeReturn !== null && sym.symbolType.typeReturn.kind === TypeKind.Int32;
}

test "typed function call returns annotated type" {
	const ctx = checkSource("function greet(name: string): string { return name; } const x = greet(\"hi\");");
	const sym = lookupSymbol(ctx.table, "x");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.String;
}

test "array literal infers element type" {
	const ctx = checkSource("const arr = [1, 2, 3];");
	const sym = lookupSymbol(ctx.table, "arr");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Array;
	assert sym.symbolType.typeReturn !== null && sym.symbolType.typeReturn.kind === TypeKind.Int32;
}

test "arrow function has Function type" {
	const ctx = checkSource("const f = (x) => x;");
	const sym = lookupSymbol(ctx.table, "f");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Function;
}

test "inferred return type from body" {
	const ctx = checkSource("function foo() { return 42; }");
	const sym = lookupSymbol(ctx.table, "foo");
	assert sym !== null;
	assert sym.symbolType.typeReturn !== null && sym.symbolType.typeReturn.kind === TypeKind.Int32;
}

test "annotated return type preserved" {
	const ctx = checkSource("function bar(): string { return \"hi\"; }");
	const sym = lookupSymbol(ctx.table, "bar");
	assert sym !== null;
	assert sym.symbolType.typeReturn !== null && sym.symbolType.typeReturn.kind === TypeKind.String;
}

test "arrow infers return type" {
	const ctx = checkSource("const f = (x) => 42;");
	const sym = lookupSymbol(ctx.table, "f");
	assert sym !== null;
	assert sym.symbolType.typeReturn !== null && sym.symbolType.typeReturn.kind === TypeKind.Int32;
}

test "string return inferred" {
	const ctx = checkSource("function greet() { return \"hello\"; }");
	const sym = lookupSymbol(ctx.table, "greet");
	assert sym !== null;
	assert sym.symbolType.typeReturn !== null && sym.symbolType.typeReturn.kind === TypeKind.String;
}

test "boolean return inferred" {
	const ctx = checkSource("function isOk() { return true; }");
	const sym = lookupSymbol(ctx.table, "isOk");
	assert sym !== null;
	assert sym.symbolType.typeReturn !== null && sym.symbolType.typeReturn.kind === TypeKind.Boolean;
}

test "no return stays unknown" {
	const ctx = checkSource("function noop() { const x = 1; }");
	const sym = lookupSymbol(ctx.table, "noop");
	assert sym !== null;
	assert sym.symbolType.typeReturn !== null && sym.symbolType.typeReturn.kind === TypeKind.Unknown;
}

test "return type mismatch detected" { assert !checkOk("function foo(): number { return \"hello\"; }"); }

test "return type match ok" { assert checkOk("function foo(): number { return 42; }"); }

test "return string match ok" { assert checkOk("function bar(): string { return \"hi\"; }"); }

test "arg type mismatch detected" { assert !checkOk("function add(a: number, b: number): number { return a; } const x = add(\"hi\", 2);"); }

test "arg type match ok" { assert checkOk("function add(a: number, b: number): number { return a; } const x = add(1, 2);"); }

test "numeric widening ok" { assert checkOk("function f(n: number): number { return n; } const x = f(42);"); }

test "two overloads no error" { assert checkOk("function add(a: number, b: number): number { return a; } function add(a: string, b: string): string { return a; }"); }

test "overload different arity no error" { assert checkOk("function f(a: number): number { return a; } function f(a: number, b: number): number { return a; }"); }

test "overload call resolves" {
	const ctx = checkSource("function f(a: number): number { return a; } function f(a: string): string { return a; } const x = f(1);");
	assert !hasErrors(ctx);
	const sym = lookupSymbol(ctx.table, "x");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Number;
}

test "overload call picks string version" {
	const ctx = checkSource("function f(a: number): number { return a; } function f(a: string): string { return a; } const y = f(\"hi\");");
	assert !hasErrors(ctx);
	const sym = lookupSymbol(ctx.table, "y");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.String;
}

test "no match reports error" {
	const ctx = checkSource("function add(a: number, b: number): number { return a; } function add(a: string, b: string): string { return a; } const x = add(true);");
	assert hasErrors(ctx);
}

test "ambiguous call reports error" {
	// Same param types, different return types → ambiguous
	const ctx = checkSource("function f(a: number): number { return a; } function f(a: number): string { return \"hi\"; } const x = f(1);");
	assert hasErrors(ctx);
}

test "arity-based overload resolution" {
	const ctx = checkSource("function f(a: number): number { return a; } function f(a: number, b: number): number { return a; } const x = f(1); const y = f(1, 2);");
	assert !hasErrors(ctx);
}

test "two extension overloads no error" { assert checkOk("function trim(this s: string): string { return s; } function trim(this s: string, ch: string): string { return s; }"); }

test "extension overload call resolves by arity" {
	const ctx = checkSource("function double(this n: number): number { return n; } function double(this n: number, scale: number): number { return n; } const x = double(1); const y = double(1, 2);");
	assert !hasErrors(ctx);
}

test "same-name extensions on different types filter by receiver" {
	// Bug repro: indexOf on string vs number[] — must resolve by receiver type, not pick first match
	const ctx = checkSource("function indexOf(this s: string, sub: string, start: number): number { return 0; } function indexOf(this arr: number[], value: number): number { return 0; } const msg: string = \"hello\"; const idx: number = msg.indexOf(\"world\", 0);");
	assert !hasErrors(ctx);
}

test "same-name extensions array receiver resolves correctly" {
	const ctx = checkSource("function indexOf(this s: string, sub: string, start: number): number { return 0; } function indexOf(this arr: number[], value: number): number { return 0; } const a: number[] = [1, 2, 3]; const idx: number = a.indexOf(42);");
	assert !hasErrors(ctx);
}

test "generic extension matches compatible array receiver" {
	// first<T>(this arr: T[]) called as a.first() — T unifies with number
	const ctx = checkSource("function first<T>(this arr: T[]): T { return arr[0]; } const a: number[] = [1, 2]; const x: number = a.first();");
	assert !hasErrors(ctx);
}

test "extension method registered" {
	const ctx = checkSource("function trim(this s: string): string { return s; }");
	assert !hasErrors(ctx);
	const sym = lookupSymbol(ctx.table, "trim");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Function;
}

test "extension method callable as function" {
	const ctx = checkSource("function double(this n: number): number { return n; } const x = double(1);");
	assert !hasErrors(ctx);
}

test "extension on builtin type no error" { assert checkOk("function len(this s: string): number { return 0; }"); }

test "generic function parses ok" { assert checkOk("function wrap<T>(x: T): T { return x; }"); }

test "generic param resolved as GenericParam" {
	const ctx = checkSource("function id<T>(x: T): T { return x; }");
	assert !hasErrors(ctx);
	const sym = lookupSymbol(ctx.table, "id");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Function;
	assert sym.symbolType.typeChildren[0].kind === TypeKind.GenericParam;
	assert sym.symbolType.typeReturn !== null && sym.symbolType.typeReturn.kind === TypeKind.GenericParam;
}

test "generic call infers return type" {
	const ctx = checkSource("function id<T>(x: T): T { return x; } const n = id(42);");
	assert !hasErrors(ctx);
	const sym = lookupSymbol(ctx.table, "n");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Int32;
}

test "two generic params" {
	const ctx = checkSource("function first<T, U>(a: T, b: U): T { return a; } const x = first(1, \"hi\");");
	assert !hasErrors(ctx);
	const sym = lookupSymbol(ctx.table, "x");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Int32;
}

test "generic with annotated return" { assert checkOk("function identity<T>(x: T): T { return x; }"); }

test "wildcard always exhaustive" { assert checkOk("enum Color { Red, Green, Blue } function f(): number { const c = Color.Red; return match (c) { _ => 0 }; }"); }

test "all members covered" { assert checkOk("enum Color { Red, Green, Blue } function f(): number { const c = Color.Red; return match (c) { Color.Red => 1, Color.Green => 2, Color.Blue => 3 }; }"); }

test "missing member errors" { assert !checkOk("enum Color { Red, Green, Blue } function f(): number { const c = Color.Red; return match (c) { Color.Red => 1, Color.Green => 2 }; }"); }

test "binding acts as wildcard" { assert checkOk("enum Color { Red, Green } function f(): number { const c = Color.Red; return match (c) { Color.Red => 1, other => 0 }; }"); }

// ===== Tier 1: Enum Literal Types + Function Overload Signatures =====

test "enum literal type as param accepts match" {
	assert checkOk("enum K { A, B } function f(k: K.A): void {} f(K.A);");
}

test "enum literal type as param rejects other variant" {
	assert !checkOk("enum K { A, B } function f(k: K.A): void {} f(K.B);");
}

test "enum literal type as param accepts general enum arg via subtype" {
	// When the actual arg is a specific literal (K.A), it subtypes to K.A param.
	assert checkOk("enum K { A, B } function expectsA(k: K.A): void {} function g() { expectsA(K.A); }");
}

test "function overload signature with implementation parses" {
	assert checkOk("enum K { A, B } function f(k: K.A): number; function f(k: K.B): number; function f(k: K): number { return 0; } f(K.A); f(K.B);");
}

test "overload resolution prefers enum literal over enum" {
	// Both candidates match; enum literal overload is more specific (Exact vs Subtype).
	// We can't easily observe which won without return-type plumbing, but check doesn't error.
	assert checkOk("enum K { A, B } function f(k: K.A): string; function f(k: K): string { return \"default\"; } f(K.A);");
}

test "phase 5: overload with object literal — matching variant accepted" {
	// The object literal contextually types against the wide impl's union,
	// then scoring picks the specific overload whose param matches exactly.
	assert checkOk(
		"enum K { A, B }\n"
		+ "type Data = { kind: K.A, x: number } | { kind: K.B, y: string };\n"
		+ "function g(k: K.A, d: { x: number }): void;\n"
		+ "function g(k: K.B, d: { y: string }): void;\n"
		+ "function g(k: K, d: { x: number } | { y: string }): void { }\n"
		+ "g(K.A, { x: 42 });\n"
		+ "g(K.B, { y: \"hi\" });\n"
	);
}

test "phase 5: overload with object literal — dispatches to specific when matched" {
	// When the arg pair matches a specific overload, resolvedOverloadIdx
	// should point at that overload, not the wide impl. This is what
	// drives LSP hover / signature help narrowing. (Verification is via
	// successful type-check; the index is observable through LSP tests.)
	assert checkOk(
		"enum K { A, B }\n"
		+ "function g(k: K.A, d: { x: number }): number;\n"
		+ "function g(k: K.B, d: { y: string }): number;\n"
		+ "function g(k: K, d: { x: number } | { y: string }): number { return 0; }\n"
		+ "const r = g(K.A, { x: 42 });\n"
	);
}

test "phase 5: runtime kind falls through to wide impl" {
	// `createNodeAt(node.kind, node.data, loc)`-style callers pass a runtime
	// NodeKind and the wide union data. They should type-check against the
	// wide impl even when specific overloads exist. This is the scenario
	// that broke the previous session's 80-overload attempt.
	assert checkOk(
		"enum K { A, B }\n"
		+ "function g(k: K.A, d: { x: number }): number;\n"
		+ "function g(k: K.B, d: { y: string }): number;\n"
		+ "function g(k: K, d: { x: number } | { y: string }): number { return 0; }\n"
		+ "function caller(k: K, d: { x: number } | { y: string }): number { return g(k, d); }\n"
	);
}

test "overload with wrong enum literal errors" {
	// f is defined to accept only K.A via overload sig, impl takes K but arg K.B must match
	// some signature. Since K.B doesn't match the K.A sig literal, it falls through to K impl.
	assert checkOk("enum K { A, B } function f(k: K.A): string; function f(k: K): string { return \"default\"; } f(K.B);");
}

test "overload sigs without implementation errors" {
	// All-sig-no-impl should fail at the call site with a clear "no implementation" error.
	assert !checkOk("enum K { A, B } function f(k: K.A): string; function f(k: K.B): string; f(K.A);");
}

test "overload sigs with mismatched return types error" {
	// Tier 1 restriction: all sigs must share the impl's return type.
	assert !checkOk("enum K { A, B } function f(k: K.A): number; function f(k: K.B): string; function f(k: K): number { return 0; } f(K.A);");
}

test "overload sig with mismatched arity errors" {
	// Sig arity must match impl arity.
	assert !checkOk("enum K { A, B } function f(k: K.A): void; function f(k: K, extra: number): void { } f(K.A);");
}

test "overload sig with incompatible param type errors" {
	// Sig param type must be assignable to impl param type.
	assert !checkOk("enum K { A, B } function f(k: K.A): void; function f(k: string): void { } f(K.A);");
}

test "enum literal narrows in return position" {
	// Tier 1: function declared to return K.A — `return K.A` narrows to EnumLiteral via expectedType
	assert checkOk("enum K { A, B } function makeA(): K.A { return K.A; }");
}

// ===== Tier 2: String-literal discriminated union narrowing at call sites =====

test "string DU correct variant passes" {
	assert checkOk("type S = { kind: \"a\", x: number } | { kind: \"b\", y: string }; function f(s: S): void {} f({ kind: \"a\", x: 1 });");
}

test "string DU wrong field for variant errors" {
	// kind="a" matches variant 0 which has field 'x', not 'y'
	assert !checkOk("type S = { kind: \"a\", x: number } | { kind: \"b\", y: string }; function f(s: S): void {} f({ kind: \"a\", y: \"wrong\" });");
}

test "string DU unknown discriminant value errors" {
	assert !checkOk("type S = { kind: \"a\", x: number } | { kind: \"b\", y: string }; function f(s: S): void {} f({ kind: \"c\", x: 1 });");
}

test "string DU missing discriminant errors" {
	assert !checkOk("type S = { kind: \"a\", x: number } | { kind: \"b\", y: string }; function f(s: S): void {} f({ x: 1 });");
}

test "string DU narrowing inside if still works" {
	assert checkOk("type S = { kind: \"a\", x: number } | { kind: \"b\", y: string }; function f(s: S): number { if (s.kind === \"a\") { return s.x; } return 0; }");
}

test "string DU if-narrowing rejects wrong variant field" {
	// Inside if (s.kind === "a"), s.y should error because "a" variant has no "y"
	assert !checkOk("type S = { kind: \"a\", x: number } | { kind: \"b\", y: string }; function f(s: S): number { if (s.kind === \"a\") { const v = s.y; return 0; } return 0; }");
}

test "string DU if-narrowing allows correct variant field" {
	assert checkOk("type S = { kind: \"a\", x: number } | { kind: \"b\", y: string }; function f(s: S): string { if (s.kind === \"b\") { return s.y; } return \"\"; }");
}

test "string DU no narrowing outside if" {
	// Outside if-block, s.x is still allowed (getProperty scans all variants — existing behavior)
	assert checkOk("type S = { kind: \"a\", x: number } | { kind: \"b\", y: string }; function f(s: S): number { return s.x; }");
}

test "string DU match narrows correct variant" {
	assert checkOk("type S = { kind: \"a\", x: number } | { kind: \"b\", y: string }; function f(s: S): number { return match (s.kind) { \"a\" => s.x, _ => 0 }; }");
}

test "string DU match rejects wrong variant field" {
	// Inside match arm "a", s.y should error because "a" variant has no "y"
	assert !checkOk("type S = { kind: \"a\", x: number } | { kind: \"b\", y: string }; function f(s: S): number { return match (s.kind) { \"a\" => s.y, _ => 0 }; }");
}

test "string DU match stmt narrows" {
	assert checkOk("type S = { kind: \"a\", x: number } | { kind: \"b\", y: string }; function f(s: S): void { match (s.kind) { \"a\" => { const v = s.x; }, _ => {} }; }");
}

test "string DU match stmt rejects wrong field" {
	assert !checkOk("type S = { kind: \"a\", x: number } | { kind: \"b\", y: string }; function f(s: S): void { match (s.kind) { \"a\" => { const v = s.y; }, _ => {} }; }");
}

// ===== Gap 3: Enum-based DU if-narrowing =====

test "enum DU if-narrowing allows correct field" {
	assert checkOk("enum K { A, B } type V = match (kind: K) { K.A => { x: number }, K.B => { y: string } }; function f(v: V): number { if (v.kind === K.A) { return v.x; } return 0; }");
}

test "enum DU if-narrowing rejects wrong field" {
	assert !checkOk("enum K { A, B } type V = match (kind: K) { K.A => { x: number }, K.B => { y: string } }; function f(v: V): number { if (v.kind === K.A) { const bad = v.y; return 0; } return 0; }");
}

// ===== Gap 2: String-literal DU match exhaustiveness =====

test "string DU match missing variant errors" {
	assert !checkOk("type S = { kind: \"a\", x: number } | { kind: \"b\", y: string }; function f(s: S): number { return match (s.kind) { \"a\" => s.x }; }");
}

test "string DU match all variants exhaustive" {
	assert checkOk("type S = { kind: \"a\", x: number } | { kind: \"b\", y: string }; function f(s: S): number { return match (s.kind) { \"a\" => 1, \"b\" => 2 }; }");
}

test "string DU match wildcard exhaustive" {
	assert checkOk("type S = { kind: \"a\", x: number } | { kind: \"b\", y: string }; function f(s: S): number { return match (s.kind) { \"a\" => 1, _ => 0 }; }");
}

test "string DU match stmt missing variant errors" {
	assert !checkOk("type S = { kind: \"a\", x: number } | { kind: \"b\", y: string }; function f(s: S): void { match (s.kind) { \"a\" => {} }; }");
}

// ===== Tier 3: Generic Type Aliases =====

test "generic type alias simple" {
	assert checkOk("type Box<T> = { value: T }; const b: Box<number> = { value: 42 };");
}

test "generic type alias two params" {
	assert checkOk("type Pair<A, B> = { first: A, second: B }; const p: Pair<number, string> = { first: 1, second: \"hi\" };");
}

test "generic type alias preserves field types" {
	// Verify Box<number> resolves and type-checks the value field
	assert checkOk("type Box<T> = { value: T }; const b: Box<number> = { value: 42 };");
}

test "generic type alias nested" {
	assert checkOk("type Box<T> = { value: T }; type DoubleBox<T> = { inner: Box<T>, extra: number }; const d: DoubleBox<string> = { inner: { value: \"hi\" }, extra: 1 };");
}

test "generic type alias array element" {
	assert checkOk("type Box<T> = { value: T }; const arr: Box<number>[] = [{ value: 1 }, { value: 2 }];");
}

test "non-generic type alias unchanged" {
	// Existing non-generic aliases still work
	assert checkOk("type Num = number; const x: Num = 42;");
}

// ===== Tier 3: Conditional Types =====

test "conditional type true branch" {
	assert checkOk("type IsNum<T> = T extends number ? string : boolean; const a: IsNum<number> = \"yes\";");
}

test "conditional type false branch" {
	assert checkOk("type IsNum<T> = T extends number ? string : boolean; const b: IsNum<string> = true;");
}

test "conditional type nested" {
	assert checkOk("type Check<T> = T extends string ? number : T extends boolean ? string : void; const a: Check<string> = 42;");
}

// ===== Gap 4: infer keyword =====

test "infer extracts array element type" {
	assert checkOk("type Unwrap<T> = T extends Array<infer U> ? U : T; const a: Unwrap<number[]> = 42;");
}

test "infer fallback when no match" {
	// Unwrap<string> → T (string doesn't extend Array<U>), so result is string
	assert checkOk("type Unwrap<T> = T extends Array<infer U> ? U : T; const b: Unwrap<string> = \"hi\";");
}

test "infer with struct field" {
	// Extract value type from Box
	assert checkOk("type Box<T> = { value: T }; type UnboxVal<T> = T extends Box<infer U> ? U : T; const a: UnboxVal<Box<number>> = 42;");
}

// ===== Gap 5: Generic constraint enforcement =====

test "generic constraint violated errors" {
	assert !checkOk("type Box<T extends number> = { value: T }; const b: Box<string> = { value: \"hi\" };");
}

test "generic constraint satisfied passes" {
	assert checkOk("type Box<T extends number> = { value: T }; const b: Box<int32> = { value: 42 };");
}

test "non-enum no exhaustiveness check" { assert checkOk("const x = match (42) { 1 => \"one\", _ => \"other\" };"); }

test "match expr returns arm type" {
	const ctx = checkSource("const x = match (1) { 1 => 42, _ => 0 };");
	assert !hasErrors(ctx);
	const sym = lookupSymbol(ctx.table, "x");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Int32;
}

test "basic not-null check" { assert checkOk("const x = 1; if (x !== null) { const y = x; }"); }

test "reversed null check" { assert checkOk("const x = 1; if (null !== x) { const y = x; }"); }

test "equals null narrows" { assert checkOk("const x = 1; if (x === null) { const y = x; }"); }

test "no narrowing without null check" { assert checkOk("const x = 1; if (x === x) { const y = x; }"); }

test "guard clause narrows after early return" {
	// if (x === null) return; → x should be non-null after
	assert checkOk("function f(x: string): string { if (x === null) return \"\"; const y = x; return y; }");
}

test "guard clause narrows after throw" { assert checkOk("function f(x: string): string { if (x === null) throw \"err\"; return x; }"); }

test "logical AND null check" {
	// x !== null && x > 0 → x is non-null in consequent
	assert checkOk("const x = 1; if (x !== null && x > 0) { const y = x; }");
}

test "pure function with pure ops passes" { assert checkOk("@pure function add(a: number, b: number): number { return a + b; }"); }

test "pure function calling impure warns" {
	const ctx = checkSource("function impure(): void {} @pure function bad(): void { impure(); }");
	assert hasErrors(ctx);
}

test "pure calling pure is ok" { assert checkOk("@pure function helper(x: number): number { return x; } @pure function main(a: number): number { return helper(a); }"); }

// ----- REPROMISE T2 Stage C: @awaitable / @affineAwaitable end-to-end -----

test "@awaitable class parses and type-checks" {
	assert checkOk("@awaitable class Task<T> { value: T; }");
}

test "@affineAwaitable class parses and type-checks" {
	assert checkOk("@affineAwaitable class LocalFlow<T> { value: T; }");
}

test "@awaitable class used as parameter type" {
	// The @awaitable annotation flows through collectPass → registry →
	// createGenericInstance without producing checker errors.
	assert checkOk("@awaitable class Task<T> { value: T; } function takeTask(t: Task<number>): number { return 42; }");
}

test "@awaitable on function emits warning but compiles" {
	// @awaitable is only valid on type declarations. On a function it emits a
	// warning (not an error) and does NOT register the function name as awaitable.
	assert checkOk("@awaitable function foo(): number { return 1; }");
}

test "type alias resolves to type" {
	const ctx = checkSource("type ID = number;");
	assert !hasErrors(ctx);
	const sym = lookupSymbol(ctx.table, "ID");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Number;
}

test "type alias Result resolved" {
	const ctx = checkSource("type MyResult = Result<number, string>;");
	assert !hasErrors(ctx);
	const sym = lookupSymbol(ctx.table, "MyResult");
	assert sym !== null;
	assert isResult(sym.symbolType);
}

test "distinct type creates Distinct wrapper" {
	const ctx = checkSource("distinct type UserId = number;");
	assert !hasErrors(ctx);
	const sym = lookupSymbol(ctx.table, "UserId");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Distinct;
}

test "variable annotation overrides inference" {
	const ctx = checkSource("const x: string = \"hello\";");
	assert !hasErrors(ctx);
	const sym = lookupSymbol(ctx.table, "x");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.String;
}

test "class property type resolved" {
	const ctx = checkSource("class Point { x: number; y: string; getX() { return 1; } }");
	assert !hasErrors(ctx);
	const sym = lookupSymbol(ctx.table, "Point");
	assert sym !== null;
	assert sym.symbolType.kind === TypeKind.Ref;
}

test "decl with default parses ok" { assert checkOk("function f1(x: number, y: number = 5) { return x; }"); }

test "call with all args" { assert checkOk("function f2(x: number, y: number = 5) { return x; } f2(1, 2);"); }

test "call with default fills missing arg" { assert checkOk("function f3(x: number, y: number = 5) { return x; } f3(1);"); }

test "multiple defaults partial fill" { assert checkOk("function f4(a: number, b: number = 1, c: number = 2) { return a; } f4(0);"); }

test "all defaults omitted" { assert checkOk("function f5(x: number = 10) { return x; } f5();"); }

test "string default" { assert checkOk("function f6(x: string = \"hi\") { return x; } f6();"); }

test "boolean default" { assert checkOk("function f7(x: boolean = true) { return x; } f7();"); }

// ===== Index Signature Tests =====
// `{ [key: K]: V }` is syntactic sugar for HashMap<K, V>. The checker should
// normalize both syntaxes to the same internal Type.

test "index signature declaration parses and checks" {
	assert checkOk("let m: { [key: string]: number };");
}

test "index signature with number key" {
	assert checkOk("let m: { [k: number]: string };");
}

test "index signature normalizes to Map type — structural equivalence" {
	// The core property: both syntaxes produce identical resolved types.
	// We don't assert specific TypeKind or typeName values (those can evolve);
	// we assert that `{ [k: K]: V }` and `HashMap<K, V>` produce structurally
	// identical symbol types. This is the whole point of the feature.
	const ctxA = checkSource("let a: { [key: string]: number };");
	const ctxB = checkSource("let b: HashMap<string, number>;");
	const symA = lookupSymbol(ctxA.table, "a");
	const symB = lookupSymbol(ctxB.table, "b");
	assert symA !== null;
	assert symB !== null;
	assert symA.symbolType.kind === symB.symbolType.kind;
	assert symA.symbolType.typeName === symB.symbolType.typeName;
	assert symA.symbolType.typeChildren.length === symB.symbolType.typeChildren.length;
}

test "index signature in function parameter" {
	assert checkOk("function f(m: { [key: string]: number }): void { }");
}

test "index signature as function return" {
	assert checkOk("function f(): { [key: string]: number } { return null as unknown as Map<string, number>; }");
}

test "index signature with trailing semicolon" {
	assert checkOk("let m: { [key: string]: number; };");
}

test "map literal via index signature target" {
	assert checkOk("const m: { [key: string]: number } = { \"foo\": 1, \"bar\": 2 };");
}

test "map literal via HashMap<K,V> target" {
	assert checkOk("const m: HashMap<string, number> = { \"foo\": 1, \"bar\": 2 };");
}

test "map literal rejects wrong value type" {
	assert !checkOk("const m: { [key: string]: number } = { \"foo\": \"wrong\" };");
}

test "empty map literal" {
	assert checkOk("const m: { [key: string]: number } = {};");
}


// --- Additional index signature edge case tests ---

test "map subscript with variable key" {
	assert checkOk("const m: HashMap<string, number> = new HashMap<string, number>(); m.set(\"a\", 1); const k = \"a\"; const v = m[k];");
}

test "map subscript write with variable key" {
	assert checkOk("const m: HashMap<string, number> = new HashMap<string, number>(); const k = \"a\"; m[k] = 42;");
}

test "index sig in function parameter" {
	assert checkOk("function f(deps: { [key: string]: string }): void { const v = deps[\"foo\"]; }");
}

// NOTE: compound assignment on Map subscript (m[k] += 1) is not supported in v1.
// The read mutation checks leftPartOfAsgn === 0 (skips LHS of assignment),
// and the write mutation only handles operator === "=".
// Users must write: m["k"] = m["k"] + 1; explicitly.
// This is documented, not a bug — compound assignment on Map is a v2 feature.

// ===== Phase 2 flow-graph integration tests =====
//
// Verify that getFlowTypeOfReference actually narrows types end-to-end.
// Parse → bind → check, then find a specific reference in the AST and call
// the flow query with the declared type. The returned type must match the
// narrowed variant (not the full declared union).
//
// These run AFTER the checker pass, so Identifier nodes have resolvedSym
// set. We walk the AST to locate a target reference by structural position
// (no name-based guessing), then query its flowNode.

// Walk function body's statements looking for the first Identifier matching
// `targetName` whose `flowNode` is non-null. Skips declaration sites.
function findFlowRef(root: Node, targetName: string): Node {
	if (root === null) return null as unknown as Node;
	// Quick structural check: is this the identifier we want?
	if (root.kind === NodeKind.Identifier) {
		const d = root.data as IdentifierData;
		if (d.name === targetName && root.flowNode !== null) return root;
	}
	// Recurse into children per NodeKind. Only the shapes we use in tests.
	let hit: Node = null as unknown as Node;
	match (root.kind) {
		NodeKind.Program => {
			const d = root.data as ProgramData;
			for (const s of d.programStmts) {
				if (hit === null) hit = findFlowRef(s, targetName);
			}
		},
		NodeKind.BlockStmt => {
			const d = root.data as BlockStmtData;
			for (const s of d.statements) {
				if (hit === null) hit = findFlowRef(s, targetName);
			}
		},
		NodeKind.IfStmt => {
			const d = root.data as IfStmtData;
			if (hit === null) hit = findFlowRef(d.condition, targetName);
			if (hit === null) hit = findFlowRef(d.consequent, targetName);
			if (hit === null) hit = findFlowRef(d.alternate, targetName);
		},
		NodeKind.ExprStmt => {
			const d = root.data as ExprStmtData;
			if (hit === null) hit = findFlowRef(d.expr, targetName);
		},
		NodeKind.ReturnStmt => {
			const d = root.data as ReturnStmtData;
			if (hit === null) hit = findFlowRef(d.argument, targetName);
		},
		NodeKind.MemberExpr => {
			const d = root.data as MemberExprData;
			if (hit === null) hit = findFlowRef(d.object, targetName);
		},
		NodeKind.BinaryExpr => {
			const d = root.data as BinaryExprData;
			if (hit === null) hit = findFlowRef(d.left, targetName);
			if (hit === null) hit = findFlowRef(d.right, targetName);
		},
		NodeKind.UnaryExpr => {
			const d = root.data as UnaryExprData;
			if (hit === null) hit = findFlowRef(d.operand, targetName);
		},
		NodeKind.CallExpr => {
			const d = root.data as CallExprData;
			if (hit === null) hit = findFlowRef(d.callee, targetName);
			for (const a of d.arguments) {
				if (hit === null) hit = findFlowRef(a, targetName);
			}
		},
		NodeKind.FunctionDecl => {
			const d = root.data as FunctionDeclData;
			if (hit === null) hit = findFlowRef(d.fnBody, targetName);
		},
		NodeKind.VariableDecl => {
			const d = root.data as VariableDeclData;
			if (hit === null) hit = findFlowRef(d.initializer, targetName);
		},
		NodeKind.WhileStmt => {
			const d = root.data as WhileStmtData;
			if (hit === null) hit = findFlowRef(d.whileCondition, targetName);
			if (hit === null) hit = findFlowRef(d.whileBody, targetName);
		},
		NodeKind.DoWhileStmt => {
			const d = root.data as DoWhileStmtData;
			if (hit === null) hit = findFlowRef(d.doBody, targetName);
			if (hit === null) hit = findFlowRef(d.doCondition, targetName);
		},
		NodeKind.ForStmt => {
			const d = root.data as ForStmtData;
			if (hit === null) hit = findFlowRef(d.forInit, targetName);
			if (hit === null) hit = findFlowRef(d.forCondition, targetName);
			if (hit === null) hit = findFlowRef(d.forUpdate, targetName);
			if (hit === null) hit = findFlowRef(d.forBody, targetName);
		},
		NodeKind.ForOfStmt => {
			const d = root.data as ForOfStmtData;
			if (hit === null) hit = findFlowRef(d.forOfIterable, targetName);
			if (hit === null) hit = findFlowRef(d.forOfBody, targetName);
		},
		NodeKind.ArrayAccess => {
			const d = root.data as ArrayAccessData;
			if (hit === null) hit = findFlowRef(d.array, targetName);
			if (hit === null) hit = findFlowRef(d.index, targetName);
		},
		_ => {},
	};
	return hit;
}

// Find a reference inside a specific consequent/alternate branch of an if.
function findFnBody(program: Node): Node {
	const pd = program.data as ProgramData;
	for (const s of pd.programStmts) {
		if (s.kind === NodeKind.FunctionDecl) {
			const fd = s.data as FunctionDeclData;
			return fd.fnBody;
		}
	}
	return null as unknown as Node;
}

function findIfConsequent(body: Node): Node {
	if (body === null || body.kind !== NodeKind.BlockStmt) return null as unknown as Node;
	const bd = body.data as BlockStmtData;
	for (const s of bd.statements) {
		if (s.kind === NodeKind.IfStmt) {
			const ifd = s.data as IfStmtData;
			return ifd.consequent;
		}
	}
	return null as unknown as Node;
}

test "flow: string DU narrowing produces correct variant" {
	const src = "type Shape = { kind: \"circle\", radius: number } | { kind: \"square\", side: number };\n"
		+ "function f(s: Shape): number {\n"
		+ "  if (s.kind === \"circle\") { return s.radius; }\n"
		+ "  return 0;\n"
		+ "}\n";
	const pr = parseSource(src);
	assert pr.ok;
	const program = pr.value;
	// checkProgram runs collect + resolve + bindFlowGraph + check
	checkProgram(program);
	// Locate the `s` reference inside `return s.radius;` (the if consequent)
	const fnBody = findFnBody(program);
	assert fnBody !== null;
	const consequent = findIfConsequent(fnBody);
	assert consequent !== null;
	const sRef = findFlowRef(consequent, "s");
	assert sRef !== null;
	assert sRef.flowNode !== null;
	// The checker set resolvedSym + nodeType; declared type = the union
	assert sRef.resolvedSym !== null;
	const declared = sRef.resolvedSym.symbolType;
	assert declared !== null;
	assert declared.kind === TypeKind.Union;
	// Query the flow — should narrow to the "circle" variant (a struct)
	const narrowed = getFlowTypeOfReference(sRef, declared);
	assert narrowed !== null;
	assert narrowed.kind === TypeKind.Struct;
	// The "circle" variant has `kind` and `radius` fields
	assert narrowed.typeNames !== null;
	let hasRadius = false;
	for (const fn of narrowed.typeNames) {
		if (fn === "radius") { hasRadius = true; break; }
	}
	assert hasRadius;
}

test "flow: string DU negative narrowing (else branch)" {
	const src = "type Shape = { kind: \"circle\", radius: number } | { kind: \"square\", side: number };\n"
		+ "function f(s: Shape): number {\n"
		+ "  if (s.kind === \"circle\") { return 1; }\n"
		+ "  return s.side;\n"
		+ "}\n";
	const pr = parseSource(src);
	assert pr.ok;
	const program = pr.value;
	checkProgram(program);
	// Find the `s` inside `return s.side;` (after the if, post-else path)
	const fnBody = findFnBody(program);
	assert fnBody !== null;
	// The `return s.side` is the second statement in the function body
	const bd = fnBody.data as BlockStmtData;
	assert bd.statements.length >= 2;
	const postReturn = bd.statements[1];
	assert postReturn.kind === NodeKind.ReturnStmt;
	const sRef = findFlowRef(postReturn, "s");
	assert sRef !== null;
	assert sRef.flowNode !== null;
	const declared = sRef.resolvedSym.symbolType;
	assert declared.kind === TypeKind.Union;
	const narrowed = getFlowTypeOfReference(sRef, declared);
	// After the if-then returns early, `s` is narrowed to NOT "circle" →
	// the "square" variant (only remaining).
	assert narrowed !== null;
	assert narrowed.kind === TypeKind.Struct;
	assert narrowed.typeNames !== null;
	let hasSide = false;
	for (const fn of narrowed.typeNames) {
		if (fn === "side") { hasSide = true; break; }
	}
	assert hasSide;
}

test "flow: no narrowing returns declared type" {
	// A plain reference with no conditional context should get the declared type back.
	const src = "function f(x: number): number { return x; }\n";
	const pr = parseSource(src);
	assert pr.ok;
	const program = pr.value;
	checkProgram(program);
	const fnBody = findFnBody(program);
	const xRef = findFlowRef(fnBody, "x");
	assert xRef !== null;
	assert xRef.resolvedSym !== null;
	const declared = xRef.resolvedSym.symbolType;
	assert declared !== null;
	const result = getFlowTypeOfReference(xRef, declared);
	assert result === declared;
}

test "flow: while loop preserves narrowing in body" {
	// Inside `while (x !== null) { body }`, references to x in the body
	// should be narrowed to non-null via the LoopLabel → TrueCondition edge.
	const src = "function f(x: string): string {\n"
		+ "  while (x.length > 0) { const y = x; return y; }\n"
		+ "  return \"\";\n"
		+ "}\n";
	const pr = parseSource(src);
	assert pr.ok;
	const program = pr.value;
	checkProgram(program);
	// Ensure the while body's `x` reference has a non-null flowNode — this
	// is the foundational invariant for loop narrowing (pre-loop edge is the
	// first antecedent of the LoopLabel).
	const fnBody = findFnBody(program);
	const bd = fnBody.data as BlockStmtData;
	const whileStmt = bd.statements[0];
	assert whileStmt.kind === NodeKind.WhileStmt;
	const wd = whileStmt.data as WhileStmtData;
	const xRef = findFlowRef(wd.whileBody, "x");
	assert xRef !== null;
	assert xRef.flowNode !== null;
	// Narrowed type should be x's declared type (string) — no union narrowing
	// happens here, but the query must return successfully without infinite
	// recursion. This proves the loop fixed-point terminates.
	const declared = xRef.resolvedSym.symbolType;
	const narrowed = getFlowTypeOfReference(xRef, declared);
	assert narrowed !== null;
	assert narrowed.kind === TypeKind.String;
}

test "flow: narrowing inside loop body via discriminant check" {
	const src = "type Shape = { kind: \"circle\", radius: number } | { kind: \"square\", side: number };\n"
		+ "function f(shapes: Shape[]): number {\n"
		+ "  let total: number = 0;\n"
		+ "  for (const s of shapes) {\n"
		+ "    if (s.kind === \"circle\") { total = total + s.radius; }\n"
		+ "  }\n"
		+ "  return total;\n"
		+ "}\n";
	const pr = parseSource(src);
	assert pr.ok;
	const program = pr.value;
	checkProgram(program);
	// Walk into the for-of body's if-consequent
	const fnBody = findFnBody(program);
	const bd = fnBody.data as BlockStmtData;
	// Statements: [let total, for-of, return]
	const forOf = bd.statements[1];
	assert forOf.kind === NodeKind.ForOfStmt;
	const fd = forOf.data as ForOfStmtData;
	const consequent = findIfConsequent(fd.forOfBody);
	assert consequent !== null;
	const sRef = findFlowRef(consequent, "s");
	assert sRef !== null;
	const declared = sRef.resolvedSym.symbolType;
	assert declared.kind === TypeKind.Union;
	// Narrowing via condition inside loop body — the LoopLabel walk back
	// must traverse the TrueCondition(s.kind === "circle") correctly.
	const narrowed = getFlowTypeOfReference(sRef, declared);
	assert narrowed !== null;
	assert narrowed.kind === TypeKind.Struct;
	let hasRadius = false;
	for (const fn of narrowed.typeNames) {
		if (fn === "radius") { hasRadius = true; break; }
	}
	assert hasRadius;
}

test "flow: nested loops don't infinite-recurse" {
	// The fixed-point must terminate even when two LoopLabels point at each
	// other. This exercises the per-query flowLoopStack re-entry detection.
	const src = "function f(n: number): number {\n"
		+ "  let i: number = 0;\n"
		+ "  while (i < n) {\n"
		+ "    let j: number = 0;\n"
		+ "    while (j < n) { j = j + 1; }\n"
		+ "    i = i + 1;\n"
		+ "  }\n"
		+ "  return i;\n"
		+ "}\n";
	const pr = parseSource(src);
	assert pr.ok;
	const program = pr.value;
	checkProgram(program);
	const fnBody = findFnBody(program);
	// Query the outer `i` inside the outer while body — must terminate.
	const iRef = findFlowRef(fnBody, "i");
	assert iRef !== null;
	assert iRef.flowNode !== null;
	const declared = iRef.resolvedSym.symbolType;
	const narrowed = getFlowTypeOfReference(iRef, declared);
	assert narrowed !== null;  // must not hang
}

test "flow: do-while narrowing inside body" {
	const src = "type Shape = { kind: \"circle\", radius: number } | { kind: \"square\", side: number };\n"
		+ "function f(shapes: Shape[]): number {\n"
		+ "  let i: number = 0;\n"
		+ "  let total: number = 0;\n"
		+ "  do {\n"
		+ "    const s: Shape = shapes[i];\n"
		+ "    if (s.kind === \"circle\") { total = total + s.radius; }\n"
		+ "    i = i + 1;\n"
		+ "  } while (i < shapes.length);\n"
		+ "  return total;\n"
		+ "}\n";
	const pr = parseSource(src);
	assert pr.ok;
	const program = pr.value;
	checkProgram(program);
	// Verify the fixed-point terminates and narrowing works inside do-while body.
	const fnBody = findFnBody(program);
	const bd = fnBody.data as BlockStmtData;
	// Statements: [let i, let total, do-while, return]
	const doW = bd.statements[2];
	assert doW.kind === NodeKind.DoWhileStmt;
	const dwd = doW.data as DoWhileStmtData;
	const consequent = findIfConsequent(dwd.doBody);
	assert consequent !== null;
	const sRef = findFlowRef(consequent, "s");
	assert sRef !== null;
	const declared = sRef.resolvedSym.symbolType;
	assert declared.kind === TypeKind.Union;
	const narrowed = getFlowTypeOfReference(sRef, declared);
	assert narrowed !== null;
	assert narrowed.kind === TypeKind.Struct;
}

test "flow: classic for loop narrowing inside body" {
	const src = "type Shape = { kind: \"circle\", radius: number } | { kind: \"square\", side: number };\n"
		+ "function f(shapes: Shape[]): number {\n"
		+ "  let total: number = 0;\n"
		+ "  for (let i: number = 0; i < shapes.length; i = i + 1) {\n"
		+ "    const s: Shape = shapes[i];\n"
		+ "    if (s.kind === \"square\") { total = total + s.side; }\n"
		+ "  }\n"
		+ "  return total;\n"
		+ "}\n";
	const pr = parseSource(src);
	assert pr.ok;
	const program = pr.value;
	checkProgram(program);
	const fnBody = findFnBody(program);
	const bd = fnBody.data as BlockStmtData;
	// Statements: [let total, for, return]
	const forStmt = bd.statements[1];
	assert forStmt.kind === NodeKind.ForStmt;
	const fsd = forStmt.data as ForStmtData;
	const consequent = findIfConsequent(fsd.forBody);
	assert consequent !== null;
	const sRef = findFlowRef(consequent, "s");
	assert sRef !== null;
	const declared = sRef.resolvedSym.symbolType;
	assert declared.kind === TypeKind.Union;
	const narrowed = getFlowTypeOfReference(sRef, declared);
	assert narrowed !== null;
	assert narrowed.kind === TypeKind.Struct;
	// Narrowed to the "square" variant
	let hasSide = false;
	for (const fn of narrowed.typeNames) {
		if (fn === "side") { hasSide = true; break; }
	}
	assert hasSide;
}

test "flow: narrowing survives across loop back-edge" {
	// x starts as string|number, narrowed in the loop body. The back-edge
	// join must include both the pre-loop type AND the body-narrowed type.
	// On the next iteration (or after the loop), the union should be the
	// declared type (because the back-edge can return any variant).
	const src = "function f(x: string | number): number {\n"
		+ "  let i: number = 0;\n"
		+ "  while (i < 10) {\n"
		+ "    if (typeof x === \"number\") { i = i + 1; }\n"
		+ "    i = i + 1;\n"
		+ "  }\n"
		+ "  return i;\n"
		+ "}\n";
	const pr = parseSource(src);
	assert pr.ok;
	const program = pr.value;
	checkProgram(program);
	// Find the `x` reference inside the typeof condition — it should have a
	// flowNode pointing into the loop body. Query must terminate.
	const fnBody = findFnBody(program);
	const bd = fnBody.data as BlockStmtData;
	const whileStmt = bd.statements[1];
	assert whileStmt.kind === NodeKind.WhileStmt;
	const wd = whileStmt.data as WhileStmtData;
	const xRef = findFlowRef(wd.whileBody, "x");
	assert xRef !== null;
	assert xRef.flowNode !== null;
	const declared = xRef.resolvedSym.symbolType;
	const narrowed = getFlowTypeOfReference(xRef, declared);
	// Must not hang; result should be the declared union (no narrowing from
	// a reference that appears BEFORE its narrowing check — fine for Phase 3).
	assert narrowed !== null;
}

test "flow: break inside loop preserves post-loop flow" {
	// After `break`, control jumps to postLoop. The post-loop narrowing is
	// the union of pre-loop type (if loop never ran) and the break point's
	// type. Primarily a termination test.
	const src = "function f(xs: number[]): number {\n"
		+ "  let i: number = 0;\n"
		+ "  while (i < xs.length) {\n"
		+ "    if (xs[i] === 42) { break; }\n"
		+ "    i = i + 1;\n"
		+ "  }\n"
		+ "  return i;\n"
		+ "}\n";
	const pr = parseSource(src);
	assert pr.ok;
	const program = pr.value;
	checkProgram(program);
	// Query i after the loop — must terminate, must return number.
	const fnBody = findFnBody(program);
	const iRef = findFlowRef(fnBody, "i");
	assert iRef !== null;
	const declared = iRef.resolvedSym.symbolType;
	const narrowed = getFlowTypeOfReference(iRef, declared);
	assert narrowed !== null;
	assert narrowed.kind === TypeKind.Number;
}

test "flow: reassignment inside loop does not hang" {
	// Pathological: narrow x, reassign it, query x after reassignment. The
	// flow walker must not infinite-recurse even if the variable is
	// reassigned inside a loop.
	const src = "function f(x: string | number, n: number): number {\n"
		+ "  let i: number = 0;\n"
		+ "  while (i < n) {\n"
		+ "    if (typeof x === \"number\") { x = x + 1; }\n"
		+ "    i = i + 1;\n"
		+ "  }\n"
		+ "  return i;\n"
		+ "}\n";
	const pr = parseSource(src);
	assert pr.ok;
	const program = pr.value;
	checkProgram(program);
	const fnBody = findFnBody(program);
	const iRef = findFlowRef(fnBody, "i");
	assert iRef !== null;
	const declared = iRef.resolvedSym.symbolType;
	const narrowed = getFlowTypeOfReference(iRef, declared);
	assert narrowed !== null;
}

test "flow: switch clause narrows DU" {
	const src = "type Shape = { kind: \"circle\", radius: number } | { kind: \"square\", side: number };\n"
		+ "function f(s: Shape): number {\n"
		+ "  switch (s.kind) {\n"
		+ "    case \"circle\": { return s.radius; }\n"
		+ "    default: { return 0; }\n"
		+ "  }\n"
		+ "}\n";
	const pr = parseSource(src);
	assert pr.ok;
	const program = pr.value;
	checkProgram(program);
	const fnBody = findFnBody(program);
	assert fnBody !== null;
	// Walk into the switch's "circle" case body
	const bd = fnBody.data as BlockStmtData;
	assert bd.statements.length >= 1;
	const sw = bd.statements[0];
	assert sw.kind === NodeKind.SwitchStmt;
	const swData = sw.data as SwitchStmtData;
	assert swData.switchCases.length >= 1;
	const circleCase = swData.switchCases[0];
	const ccd = circleCase.data as SwitchCaseData;
	assert !ccd.isDefault;
	// Locate `s` inside `return s.radius;`
	const caseBody = ccd.caseStmts[0];
	const sRef = findFlowRef(caseBody, "s");
	assert sRef !== null;
	assert sRef.flowNode !== null;
	const declared = sRef.resolvedSym.symbolType;
	assert declared.kind === TypeKind.Union;
	const narrowed = getFlowTypeOfReference(sRef, declared);
	assert narrowed !== null;
	assert narrowed.kind === TypeKind.Struct;
	let hasRadius = false;
	for (const fn of narrowed.typeNames) {
		if (fn === "radius") { hasRadius = true; break; }
	}
	assert hasRadius;
}

test "flow: typeof narrows union to primitive" {
	const src = "function f(x: string | number): number {\n"
		+ "  if (typeof x === \"number\") { return x; }\n"
		+ "  return 0;\n"
		+ "}\n";
	const pr = parseSource(src);
	assert pr.ok;
	const program = pr.value;
	checkProgram(program);
	const fnBody = findFnBody(program);
	const consequent = findIfConsequent(fnBody);
	assert consequent !== null;
	const xRef = findFlowRef(consequent, "x");
	assert xRef !== null;
	assert xRef.flowNode !== null;
	const declared = xRef.resolvedSym.symbolType;
	assert declared.kind === TypeKind.Union;
	const narrowed = getFlowTypeOfReference(xRef, declared);
	assert narrowed !== null;
	assert narrowed.kind === TypeKind.Number;
}

test "flow: typeof negation in else" {
	const src = "function f(x: string | number): string {\n"
		+ "  if (typeof x === \"number\") { return \"n\"; }\n"
		+ "  return x;\n"
		+ "}\n";
	const pr = parseSource(src);
	assert pr.ok;
	const program = pr.value;
	checkProgram(program);
	const fnBody = findFnBody(program);
	const bd = fnBody.data as BlockStmtData;
	const postReturn = bd.statements[1];
	const xRef = findFlowRef(postReturn, "x");
	assert xRef !== null;
	assert xRef.flowNode !== null;
	const declared = xRef.resolvedSym.symbolType;
	const narrowed = getFlowTypeOfReference(xRef, declared);
	// After `typeof x === "number"` returns, x is narrowed to string (union minus number).
	assert narrowed !== null;
	assert narrowed.kind === TypeKind.String;
}

test "flow: enum DU narrowing via match-syntax discriminated union" {
	// Uses the checker-recognized discriminated-union syntax:
	//   type V = match (kind: K) { K.A => { x }, K.B => { y } }
	// This is the pattern the existing ctx.narrowedDiscriminants path supports
	// and is the shape findVariantByDiscriminant was designed for.
	const src = "enum K { A, B }\n"
		+ "type V = match (kind: K) { K.A => { x: number }, K.B => { y: string } };\n"
		+ "function f(v: V): number {\n"
		+ "  if (v.kind === K.A) { return v.x; }\n"
		+ "  return 0;\n"
		+ "}\n";
	const pr = parseSource(src);
	assert pr.ok;
	const program = pr.value;
	checkProgram(program);
	const fnBody = findFnBody(program);
	const consequent = findIfConsequent(fnBody);
	assert consequent !== null;
	const vRef = findFlowRef(consequent, "v");
	assert vRef !== null;
	assert vRef.flowNode !== null;
	assert vRef.resolvedSym !== null;
	const declared = vRef.resolvedSym.symbolType;
	assert declared !== null;
	assert declared.kind === TypeKind.Union;
	const narrowed = getFlowTypeOfReference(vRef, declared);
	assert narrowed !== null;
	// Narrowed to the A-variant (has `x`)
	assert narrowed.kind === TypeKind.Struct;
	let hasX = false;
	for (const fn of narrowed.typeNames) {
		if (fn === "x") { hasX = true; break; }
	}
	assert hasX;
}

// ===== Phase 5: two-pass overload resolution =====

test "phase 5: overload with object literal picks specific variant" {
	// Specific overload with EnumLiteral arg[0] wins over wide impl. Object
	// literal arg[1] is context-sensitive — skipped in Pass 1, checked in
	// Pass 2 against the winner's param type (the specific struct).
	assert checkOk(
		"enum K { A, B }\n"
		+ "function g(k: K.A, d: { x: number }): number;\n"
		+ "function g(k: K.B, d: { y: string }): number;\n"
		+ "function g(k: K, d: { x: number } | { y: string }): number { return 0; }\n"
		+ "const r1 = g(K.A, { x: 42 });\n"
		+ "const r2 = g(K.B, { y: \"hi\" });\n"
	);
}

test "phase 5: runtime kind falls through to wide impl" {
	// createNodeAt(node.kind, node.data, loc)-style callers pass runtime kinds.
	// Specific overloads all fail the EnumLiteral-vs-Enum check; wide impl wins.
	assert checkOk(
		"enum K { A, B }\n"
		+ "function g(k: K.A, d: { x: number }): number;\n"
		+ "function g(k: K.B, d: { y: string }): number;\n"
		+ "function g(k: K, d: { x: number } | { y: string }): number { return 0; }\n"
		+ "function caller(k: K, d: { x: number } | { y: string }): number { return g(k, d); }\n"
	);
}

test "phase 5: nested overload calls compose" {
	// Bottom-up expression evaluation: the inner call's Pass 2 commit runs
	// before the outer call's Pass 1 sees the arg.
	assert checkOk(
		"enum K { A, B }\n"
		+ "function g(k: K.A, d: { x: number }): number;\n"
		+ "function g(k: K, d: { x: number }): number { return 0; }\n"
		+ "function h(v: number): number { return v; }\n"
		+ "const r = h(g(K.A, { x: 42 }));\n"
	);
}

// ===== Phase 6: Polish — aliased conditions =====

test "phase 6: aliased typeof narrows union" {
	// `const isStr = typeof val === "string"` should narrow `val` in both
	// branches when `isStr` is tested. Flow graph walks the identifier's
	// declNode and recurses narrowType on the stored initializer.
	assert checkOk(
		"function f(val: string | number): number {\n"
		+ "  const isStr = typeof val === \"string\";\n"
		+ "  if (isStr) { return val.length; }\n"
		+ "  return val;\n"
		+ "}\n"
	);
}

test "phase 6: aliased negation narrows union" {
	// `const notStr = typeof val !== "string"` — when true, `val` is number.
	assert checkOk(
		"function f(val: string | number): number {\n"
		+ "  const notStr = typeof val !== \"string\";\n"
		+ "  if (notStr) { return val; }\n"
		+ "  return val.length;\n"
		+ "}\n"
	);
}

test "phase 6: aliased null check narrows" {
	// Nullable narrowing via aliased const.
	assert checkOk(
		"function f(val: string): number {\n"
		+ "  const hasVal = val !== null;\n"
		+ "  if (hasVal) { return val.length; }\n"
		+ "  return 0;\n"
		+ "}\n"
	);
}

test "phase 6: let does NOT alias (reassignable)" {
	// `let` bindings can be reassigned, so their stored initializer is not
	// guaranteed to reflect the current value. Must stay wide.
	assert !checkOk(
		"function f(val: string | number): number {\n"
		+ "  let isStr = typeof val === \"string\";\n"
		+ "  if (isStr) { return val.length; }\n"
		+ "  return 0;\n"
		+ "}\n"
	);
}

test "phase 6: logical && narrows both operands" {
	// `if (a && b)` narrows by `a` then by `b`.
	assert checkOk(
		"function f(val: string | number | null): number {\n"
		+ "  if (val !== null && typeof val === \"string\") {\n"
		+ "    return val.length;\n"
		+ "  }\n"
		+ "  return 0;\n"
		+ "}\n"
	);
}

test "phase 6: assignment narrows union to primitive variant" {
	// `let x: string | number; x = "hello"; x.length` — after the assignment,
	// x is narrowed to string.
	assert checkOk(
		"function f(): number {\n"
		+ "  let x: string | number = 1;\n"
		+ "  x = \"hello\";\n"
		+ "  return x.length;\n"
		+ "}\n"
	);
}

test "phase 6: assignment narrow respects declared upper bound" {
	// After reassigning x = 42, x is number. .length rejected.
	assert !checkOk(
		"function f(): number {\n"
		+ "  let x: string | number = \"hi\";\n"
		+ "  x = 42;\n"
		+ "  return x.length;\n"
		+ "}\n"
	);
}

test "phase 6: type predicate narrows in truthy branch" {
	// `isString(val)` true → val is string → return val is valid.
	assert checkOk(
		"function isString(x: string | number): x is string {\n"
		+ "  return typeof x === \"string\";\n"
		+ "}\n"
		+ "function f(val: string | number): string {\n"
		+ "  if (isString(val)) { return val; }\n"
		+ "  return \"\";\n"
		+ "}\n"
	);
}

test "phase 6: type predicate excludes variant in falsy branch" {
	// `isString(val)` false → val is number → return val is valid as number.
	assert checkOk(
		"function isString(x: string | number): x is string {\n"
		+ "  return typeof x === \"string\";\n"
		+ "}\n"
		+ "function f(val: string | number): number {\n"
		+ "  if (isString(val)) { return 0; }\n"
		+ "  return val;\n"
		+ "}\n"
	);
}

test "phase 6: non-predicate function does not narrow" {
	// A normal boolean-returning function doesn't narrow its argument.
	// val stays `string | number` after the check.
	assert !checkOk(
		"function isTruthy(x: string | number): boolean {\n"
		+ "  return true;\n"
		+ "}\n"
		+ "function f(val: string | number): string {\n"
		+ "  if (isTruthy(val)) { return val; }\n"
		+ "  return \"\";\n"
		+ "}\n"
	);
}

// ===== Truthiness narrowing =====

test "truthiness: if (x) removes null from string | null" {
	assert checkOk(
		"function f(val: string | null): number {\n"
		+ "  if (val) { return val.length; }\n"
		+ "  return 0;\n"
		+ "}\n"
	);
}

test "truthiness: if (!x) narrows to null in falsy branch" {
	// When !x is true, x is falsy → null. The function returns "" (string)
	// from both branches, which is valid.
	assert checkOk(
		"function f(val: string | null): string {\n"
		+ "  if (!val) { return \"\"; }\n"
		+ "  return val;\n"
		+ "}\n"
	);
}

test "truthiness: guard clause pattern" {
	// `if (!val) return ""` → after the guard, val is string (null removed).
	assert checkOk(
		"function f(val: string | null): string {\n"
		+ "  if (!val) return \"\";\n"
		+ "  return val;\n"
		+ "}\n"
	);
}

test "truthiness: non-nullable is a no-op" {
	// `if (x)` where x: number → no narrowing, x stays number. Still valid.
	assert checkOk(
		"function f(val: number): number {\n"
		+ "  if (val) { return val; }\n"
		+ "  return 0;\n"
		+ "}\n"
	);
}

test "truthiness: multi-variant removes only null" {
	// string | number | null → truthy branch: string | number (null removed).
	// .length doesn't exist on string | number → should fail.
	assert !checkOk(
		"function f(val: string | number | null): number {\n"
		+ "  if (val) { return val.length; }\n"
		+ "  return 0;\n"
		+ "}\n"
	);
}

test "truthiness: compound x && x.length works" {
	// First operand narrows x from string|null to string (truthiness),
	// then x.length is valid as the second operand.
	assert checkOk(
		"function f(val: string | null): boolean {\n"
		+ "  if (val && val.length > 0) { return true; }\n"
		+ "  return false;\n"
		+ "}\n"
	);
}

// ===== never as bottom type =====

test "never: exhaustive typeof chain returns never residual" {
	// After handling string and number, x is never. Returning never
	// satisfies any return type (bottom type).
	assert checkOk(
		"function f(x: string | number): string {\n"
		+ "  if (typeof x === \"string\") return x;\n"
		+ "  if (typeof x === \"number\") return x.toString();\n"
		+ "  return x;\n"
		+ "}\n"
	);
}

test "never: assignable to any type" {
	assert checkOk(
		"function f(x: string | number): number {\n"
		+ "  if (typeof x === \"string\") return 0;\n"
		+ "  if (typeof x === \"number\") return x;\n"
		+ "  return x;\n"
		+ "}\n"
	);
}

// ===== instanceof narrowing =====

test "instanceof: narrows to class type in truthy branch" {
	assert checkOk(
		"class Dog { breed: string; }\n"
		+ "class Cat { indoor: boolean; }\n"
		+ "function f(pet: Dog | Cat): string {\n"
		+ "  if (pet instanceof Dog) { return pet.breed; }\n"
		+ "  return \"\";\n"
		+ "}\n"
	);
}

test "instanceof: excludes class type in falsy branch" {
	assert checkOk(
		"class Dog { breed: string; }\n"
		+ "class Cat { indoor: boolean; }\n"
		+ "function f(pet: Dog | Cat): boolean {\n"
		+ "  if (pet instanceof Dog) { return true; }\n"
		+ "  return pet.indoor;\n"
		+ "}\n"
	);
}

test "instanceof: returns boolean type" {
	assert checkOk(
		"class Foo {}\n"
		+ "function f(x: Foo): boolean {\n"
		+ "  return x instanceof Foo;\n"
		+ "}\n"
	);
}

// ===== asserts x is T =====

test "asserts: narrows argument type after call" {
	assert checkOk(
		"function assertString(x: string | number): asserts x is string {\n"
		+ "  if (typeof x !== \"string\") { return; }\n"
		+ "}\n"
		+ "function f(val: string | number): string {\n"
		+ "  assertString(val);\n"
		+ "  return val;\n"
		+ "}\n"
	);
}

test "asserts: returns void" {
	assert checkOk(
		"function assertNum(x: string | number): asserts x is number {\n"
		+ "  if (typeof x !== \"number\") { return; }\n"
		+ "}\n"
		+ "function f(): void {\n"
		+ "  let v: string | number = 42;\n"
		+ "  assertNum(v);\n"
		+ "}\n"
	);
}
