// Effects are read from checked bodies, and a callee later in the module is not
// checked yet where its caller is: queue a check with deferEffectCheck.

import { ActorDeclData, ArrayAccessData, ArrayLiteralData, ArrowFunctionData, AwaitExprData, BinaryExprData, CallExprData, ConditionalExprData, HiddenDerefData, HiddenStdConvData, ClassDeclData, ConstructorDeclData, DecoratedDeclData, ExportDeclData, ForOfStmtData, FunctionDeclData, FunctionExprData, IdentifierData, MatchCaseData, MatchExprData, MemberExprData, MethodDeclData, MoveExprData, NewExprData, Node, NodeFlag, NodeKind, ObjectLiteralData, ProgramData, PropertyDeclData, ReturnStmtData, SpreadExprData, Symbol, SymbolKind, Type, TryExprData, TypeAssertionData, TypeKind, UpdateExprData, VariableDeclData, BuiltinKind } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { CheckerContext, ExtensionRegistry, LIFECYCLE_HOOK_NAMES, addError, hasErrors, isGenericFn, dispatchEntryFor, dispatchOverridesFor, extReceiverSym, findAllExtensionsByName, nominalTypeSym } from "./context";
import { isAsyncFunctionNode, isSpawnCall } from "./freestanding";
import { RoutineFlag, SymbolFlag, SymbolTable, findOverloadImpl, hasFlag, lookupSymbol, overloadWinner, parentClassSymOf, routineFlagSet, setFlag } from "./symbol";
import { declaredFieldType, functionSlotOf, hasGenericParams, isAtomicRef, isPrimitiveKind, isReadonlyView, isSendableFunction, isValueOnlyType, typeCarriesRef, typeNameOf } from "./types";
import { constBindingInitializer } from "./constFold";
import { isScalarPrimitive } from "./fit";
import { isFrozenByConst } from "./assignable";
import { ctorRoutineOf } from "./ctorRoutine";
import { DYNAMIC_IMPORT } from "./importCall";
import { lookupModuleProgram } from "./instantiate";
import { ModuleGraph, addModule, createModule, createModuleGraph } from "../module/graph";
import { recordBodyRead } from "./bodyReads";

export enum Effect {
	SideEffect,
	SpawnUnsafe,
	ActorReach,
	Suspends,
	StoresBorrowed,
	StartsTask,
	RunsElsewhere,
}

enum BorrowKind {
	ModuleConst,
	View,
	Unfollowed,
}

interface BorrowSource {
	kind: BorrowKind;
	sym: Symbol | null;
}

function borrowText(b: BorrowSource): string {
	return match (b.kind) {
		BorrowKind.ModuleConst => "the module const '" + b.sym!.name + "'",
		BorrowKind.View => "the view '" + b.sym!.name + "'",
		BorrowKind.Unfollowed => UNFOLLOWED,
	};
}

export interface EffectCause {
	site: Node;
	text: string;
	advice?: string;
}

interface EffectTable {
	impure: HashMap<Symbol, EffectCause>;
	pure: HashMap<Symbol, boolean>;
	pureIfOpenArePure: HashMap<Symbol, boolean>;
	open: Symbol[];
}

function emptyTable(): EffectTable {
	return { impure: new HashMap<Symbol, EffectCause>(), pure: new HashMap<Symbol, boolean>(), pureIfOpenArePure: new HashMap<Symbol, boolean>(), open: [] };
}

let sideTable: EffectTable = emptyTable();
let spawnTable: EffectTable = emptyTable();
let actorReachTable: EffectTable = emptyTable();
let elsewhereTable: EffectTable = emptyTable();
let suspendTable: EffectTable = emptyTable();
let sharedConstTable: EffectTable = emptyTable();
let startTable: EffectTable = emptyTable();
let startsByModule = new HashMap<string, boolean>();
let cycles = new HashMap<string, string[]>();
let freshConsts = new HashMap<Symbol, boolean>();
let pidConsts = new HashMap<Symbol, boolean>();
let checkedModules = new HashSet<string>();
let moduleGraph: ModuleGraph | null = null;
let paramStoreTables: EffectTable[] = [];
let viewSyms: Symbol[] = [];
let viewParams: string[] = [];
let forOfSources = new HashMap<Symbol, Node>();
let assignedSources = new HashMap<Symbol, Node[]>();
let heldSources = new HashMap<Symbol, Node[]>();
let flowScanned: Node[] = [];
let resolving: Symbol[] = [];
const UNFOLLOWED = "a value the checker cannot follow";
let assumedOpen = false;
let uncheckedBodiesReported = false;
let inAsync = false;
let ownParams: string[] = [];
let ownResult: Type | null = null;
interface DeferredCheck {
	site: Node;
	rule: string;
	check: (ctx: CheckerContext) => void;
}

let deferred: DeferredCheck[] = [];
let hookRegistry: ExtensionRegistry | null = null;
const TASK_DROP_HOOKS: string[] = ["onDestroy", "onCopy", "onClone"];
const BUILTINS_WRITING_NOTHING: BuiltinKind[] = [BuiltinKind.PtrBits, BuiltinKind.Float64Bits, BuiltinKind.Float64FromBits, BuiltinKind.HiXorLo, BuiltinKind.MapFatal, BuiltinKind.LoadLE64, BuiltinKind.LoadLE32, BuiltinKind.AsBytes, BuiltinKind.ResultOk, BuiltinKind.ResultErr, BuiltinKind.Swap];

function tableFor(e: Effect): EffectTable {
	return match (e) {
		Effect.SideEffect => sideTable,
		Effect.SpawnUnsafe => spawnTable,
		Effect.ActorReach => actorReachTable,
		Effect.RunsElsewhere => elsewhereTable,
		Effect.Suspends => suspendTable,
		Effect.StoresBorrowed => sharedConstTable,
		Effect.StartsTask => startTable,
	};
}

export function deferEffectCheck(site: Node, rule: string, check: (ctx: CheckerContext) => void): void {
	for (const d of deferred) {
		if (d.site == site && d.rule == rule) return;
	}
	deferred.push({ site, rule, check });
}

export function runDeferredEffectChecks(ctx: CheckerContext): void {
	const checks = deferred;
	deferred = [];
	hookRegistry = ctx.extensionRegistry;
	moduleGraph = ctx.moduleGraph;
	checkedModules.add(ctx.modulePath);
	uncheckedBodiesReported = hasErrors(ctx);
	for (const d of checks) d.check(ctx);
	hookRegistry = null;
	checkHookEffects(ctx);
	sideTable = emptyTable();
	spawnTable = emptyTable();
	actorReachTable = emptyTable();
	elsewhereTable = emptyTable();
	suspendTable = emptyTable();
	sharedConstTable = emptyTable();
	startTable = emptyTable();
	startsByModule = new HashMap<string, boolean>();
	cycles = new HashMap<string, string[]>();
	freshConsts = new HashMap<Symbol, boolean>();
	pidConsts = new HashMap<Symbol, boolean>();
	paramStoreTables = [];
	forOfSources = new HashMap<Symbol, Node>();
	assignedSources = new HashMap<Symbol, Node[]>();
	heldSources = new HashMap<Symbol, Node[]>();
	flowScanned = [];
}

function isUncheckedGeneric(sym: Symbol): boolean {
	const decl = unpackDecl(sym.declNode);
	return decl != null && decl.kind == NodeKind.FunctionDecl && isGenericFn((decl.data as FunctionDeclData).fnFlags);
}

function checkHookEffects(ctx: CheckerContext): void {
	const registry = ctx.extensionRegistry;
	if (registry == null) return;
	for (const hook of LIFECYCLE_HOOK_NAMES) {
		for (const m of findAllExtensionsByName(registry, hook)) {
			if (m.isStatic || m.sym == null || m.sym!.modulePath != ctx.modulePath || isUncheckedGeneric(m.sym!)) continue;
			const c = routineEffect(m.sym!, Effect.Suspends);
			if (c == null) continue;
			const owner = extReceiverSym(m);
			const of = owner != null ? " of '" + owner.name + "'" : "";
			const at = m.sym!.declNode != null ? m.sym!.declNode!.location : c.site.location;
			addError(ctx, "lifecycle hook '" + hook + "'" + of + " must not spawn, await or call a function value, but it " + c.text, at.line, at.column);
		}
	}
}

export function checkActorHookEffects(hook: Node, hookName: string, actorName: string): void {
	deferEffectCheck(hook, "actorHook", (ctx: CheckerContext): void => {
		const c = walkRoutine(hook, Effect.Suspends);
		if (c == null) return;
		addError(ctx, "lifecycle hook '" + hookName + "' of '" + actorName + "' must not spawn, await or call a function value, but it " + c.text, hook.location.line, hook.location.column);
	});
}

function cause(site: Node, what: string): EffectCause {
	return { site, text: what + " at " + site.location.line + ":" + site.location.column };
}

export function routineBody(decl: Node | null): Node | null {
	if (decl == null) return null;
	return match (decl.kind) {
		NodeKind.FunctionDecl => (decl.data as FunctionDeclData).fnBody,
		NodeKind.MethodDecl => declaredExtern((decl.data as MethodDeclData).methodFlags) ? null : (decl.data as MethodDeclData).methodBody,
		NodeKind.ConstructorDecl => (decl.data as ConstructorDeclData).ctorBody,
		NodeKind.ArrowFunction => (decl.data as ArrowFunctionData).arrowBody,
		NodeKind.FunctionExpr => (decl.data as FunctionExprData).funcExprBody,
		_ => null,
	};
}

function declaredExtern(flags: string): boolean {
	return routineFlagSet(flags).has(RoutineFlag.Extern);
}

function routineResult(decl: Node): Type | null {
	const t = decl.resolvedSym != null && decl.resolvedSym!.symbolType != null ? decl.resolvedSym!.symbolType : decl.nodeType;
	return t != null && t.kind == TypeKind.Function ? t.typeReturn : null;
}

function expressionResultStore(decl: Node): EffectCause | null {
	if (decl.kind != NodeKind.ArrowFunction) return null;
	const body = (decl.data as ArrowFunctionData).arrowBody;
	return body.kind == NodeKind.BlockStmt ? null : resultStoreOf(body);
}

function resultStoreOf(value: Node | null): EffectCause | null {
	if (value == null || ownResult == null || returnsView(ownResult) || holdsNoCount(ownResult) || ownResult!.kind == TypeKind.Lent) return null;
	const what = borrowedOf(value);
	return what != null && what.kind == BorrowKind.ModuleConst ? storeCause(value, what, "into the owned result it returns") : null;
}

function routineParams(decl: Node): string[] {
	return match (decl.kind) {
		NodeKind.FunctionDecl => (decl.data as FunctionDeclData).params,
		NodeKind.MethodDecl => (decl.data as MethodDeclData).methodParams,
		NodeKind.ConstructorDecl => (decl.data as ConstructorDeclData).ctorParams,
		NodeKind.ArrowFunction => (decl.data as ArrowFunctionData).arrowParams,
		NodeKind.FunctionExpr => (decl.data as FunctionExprData).funcExprParams,
		_ => [],
	};
}

function isRoutineNode(n: Node): boolean {
	return n.kind == NodeKind.FunctionDecl || n.kind == NodeKind.MethodDecl || n.kind == NodeKind.ConstructorDecl
		|| n.kind == NodeKind.ArrowFunction || n.kind == NodeKind.FunctionExpr;
}

function walkRoutine(decl: Node | null, e: Effect, views: string[] = []): EffectCause | null {
	if (decl == null) return null;
	const outer = ownParams;
	const outerAsync = inAsync;
	const outerSyms = viewSyms;
	const outerParams = viewParams;
	const outerResult = ownResult;
	ownParams = routineParams(decl);
	ownResult = routineResult(decl);
	inAsync = isAsyncFunctionNode(decl);
	viewSyms = [];
	viewParams = views;
	if (e == Effect.StoresBorrowed) scanFlows(routineBody(decl));
	const c = (e == Effect.StoresBorrowed ? expressionResultStore(decl) : null) ?? walkEffect(routineBody(decl), e);
	ownParams = outer;
	ownResult = outerResult;
	inAsync = outerAsync;
	viewSyms = outerSyms;
	viewParams = outerParams;
	return c;
}

export function walkWithViews(node: Node, e: Effect, views: Symbol[]): EffectCause | null {
	const outerSyms = viewSyms;
	const outerParams = viewParams;
	viewSyms = views;
	viewParams = [];
	if (e == Effect.StoresBorrowed) scanFlows(node);
	const c = walkEffect(node, e);
	viewSyms = outerSyms;
	viewParams = outerParams;
	return c;
}

function walkNestedRoutine(decl: Node, e: Effect): EffectCause | null {
	const outer = ownParams;
	const outerAsync = inAsync;
	const outerParams = viewParams;
	const outerResult = ownResult;
	ownParams = routineParams(decl);
	ownResult = routineResult(decl);
	inAsync = isAsyncFunctionNode(decl);
	viewParams = viewParams.filter((p: string): boolean => !ownParams.includes(p));
	const c = (e == Effect.StoresBorrowed ? expressionResultStore(decl) : null) ?? walkChildren(decl, e);
	ownParams = outer;
	ownResult = outerResult;
	inAsync = outerAsync;
	viewParams = outerParams;
	return c;
}

function isOwnParam(n: Node | null): boolean {
	if (n == null || n.kind != NodeKind.Identifier) return false;
	const sym = n.resolvedSym;
	return sym != null && sym.symbolKind == SymbolKind.Parameter && ownParams.includes(sym.name);
}

function isOwnParamField(n: Node | null, e: Effect): boolean {
	if (n == null || !reachesModuleState(e)) return false;
	let cur = peelConv(n);
	if (cur.kind != NodeKind.MemberExpr) return false;
	while (cur.kind == NodeKind.MemberExpr) cur = peelConv((cur.data as MemberExprData).object);
	return isOwnParam(cur);
}

function peelConv(n: Node): Node {
	let cur = n;
	while (cur.kind == NodeKind.HiddenStdConv || cur.kind == NodeKind.HiddenDeref) {
		cur = cur.kind == NodeKind.HiddenStdConv ? (cur.data as HiddenStdConvData).convExpr : (cur.data as HiddenDerefData).expr;
	}
	return cur;
}

export function aliasTarget(sym: Symbol | null): Symbol | null {
	const seen: Symbol[] = [];
	let cur = sym;
	while (cur != null && !seen.includes(cur)) {
		seen.push(cur);
		const init = constBindingInitializer(cur);
		const next = init != null ? peelConv(init) : null;
		if (next == null || next.kind != NodeKind.Identifier || next.resolvedSym == null || (next.resolvedSym.symbolKind != SymbolKind.Function && constBindingInitializer(next.resolvedSym) == null)) return cur;
		cur = next.resolvedSym;
	}
	return cur;
}

export function boundRoutine(sym: Symbol | null): Node | null {
	const bound = constBindingInitializer(aliasTarget(sym));
	return bound != null && isRoutineNode(peelConv(bound)) ? peelConv(bound) : null;
}

function boundRoutineEffect(sym: Symbol, e: Effect): EffectCause | null {
	return memo(sym, e, (): EffectCause | null => walkEffect(boundRoutine(sym), e));
}

function argumentEffect(arg: Node, e: Effect): EffectCause | null {
	if (functionSlotOf(arg.nodeType) == null) return null;
	if (reachesModuleState(e) && isSendableFunction(arg.nodeType)) return null;
	const a = peelConv(arg);
	if (isRoutineNode(a) || isOwnParam(a) || isOwnParamField(a, e)) return null;
	if (a.kind == NodeKind.Identifier && a.resolvedSym != null) {
		if (isRoutine(a.resolvedSym)) return null;
		if (boundRoutine(a.resolvedSym) != null) return boundRoutineEffect(a.resolvedSym!, e);
	}
	return e == Effect.StoresBorrowed || e == Effect.ActorReach ? null : cause(arg, "passes a function value");
}

export function returnsView(t: Readonly<Type | null>): boolean {
	if (t == null) return false;
	if (t.kind == TypeKind.Borrow) return true;
	if (t.kind == TypeKind.Union && !isReadonlyView(t)) {
		let views = 0;
		for (const m of t.typeChildren) {
			if (m != null && m.kind == TypeKind.Null) continue;
			if (!returnsView(m)) return false;
			views += 1;
		}
		return views > 0;
	}
	return isReadonlyView(t) && t.kind != TypeKind.Span && t.kind != TypeKind.Ptr && typeCarriesRef(t);
}

// The routine type a call runs: the body the matched overload calls, because signatures share
// their implementation's body, so a matched signature's result type does not decide.
export function calledRoutineType(call: Node): Type | null {
	const sym = call.resolvedSym;
	if (sym != null && sym.symbolType != null && sym.symbolType.kind == TypeKind.Function) {
		const impl = calledRoutine(call);
		return impl != null && impl.symbolType != null ? impl.symbolType : sym.symbolType;
	}
	const callee = (call.data as CallExprData).callee;
	return callee != null && callee.nodeType != null && callee.nodeType.kind == TypeKind.Function ? callee.nodeType : null;
}

export function calledRoutine(call: Node): Symbol | null {
	const sym = call.resolvedSym;
	if (sym == null || sym.symbolType == null || sym.symbolType.kind != TypeKind.Function) return null;
	const winner = overloadWinner(sym, (call.data as CallExprData).resolvedOverloadIdx);
	return hasFlag(winner, SymbolFlag.OverloadSig) ? findOverloadImpl(sym) : winner;
}

export function isViewCall(call: Node): boolean {
	if (call.kind != NodeKind.CallExpr) return false;
	if (call.nodeType != null && call.nodeType.kind == TypeKind.Borrow) return true;
	const t = calledRoutineType(call);
	if (t == null || !returnsView(t.typeReturn)) return false;
	return !hasGenericParams(t.typeReturn) || returnsView(call.nodeType);
}

export function viewCallSources(call: Node, out: Node[]): void {
	const args = (call.data as CallExprData).arguments;
	const t = calledRoutineType(call);
	const formals = t != null ? t.typeChildren : null;
	const shift = call.flags.has(NodeFlag.ExtCall) ? 1 : 0;
	const recv = receiverOf(call);
	const recvSink = shift == 1 && formals != null && formals.length > 0 && formals[0] != null && formals[0].kind == TypeKind.Sink;
	if (recv != null && !recvSink) out.push(recv);
	for (let i = 0; i < args.length; i += 1) {
		const f = formals != null && i + shift < formals.length ? formals[i + shift] : null;
		if (f != null && f.kind == TypeKind.Sink) continue;
		if (args[i] != null) out.push(args[i]);
	}
}

export function receiverOf(call: Node): Node | null {
	const d = call.data as CallExprData;
	if (d.callee == null || d.callee.kind != NodeKind.MemberExpr) return null;
	if (call.flags.has(NodeFlag.ExtStatic)) return null;
	const sym = call.resolvedSym;
	if (call.flags.has(NodeFlag.ExtCall)) return (d.callee.data as MemberExprData).object;
	if (sym != null && (sym.symbolKind == SymbolKind.Method || hasFlag(sym, SymbolFlag.NativeMethod))) {
		return (d.callee.data as MemberExprData).object;
	}
	return null;
}

function isModuleState(sym: Symbol): boolean {
	if (sym.symbolKind != SymbolKind.Variable && sym.symbolKind != SymbolKind.Property) return false;
	return hasFlag(sym, SymbolFlag.Global) || hasFlag(sym, SymbolFlag.StaticLocal) || hasFlag(sym, SymbolFlag.Static) || sym.staticOwner != null;
}

// A module const that is deep Readonly and built in its own initializer, or whose type the const
// rule keeps unwritable through every path, is never written and lives as long as the program, so a
// borrow of it cannot outlive or race a write.
export function isImmutableModuleConst(sym: Symbol): boolean {
	if (!hasFlag(sym, SymbolFlag.Global) || hasFlag(sym, SymbolFlag.StaticLocal) || hasFlag(sym, SymbolFlag.Mutable)) return false;
	const t = sym.symbolType;
	return sym.symbolKind == SymbolKind.Variable && t != null && t.kind != TypeKind.Ptr && immutableConstValue(sym, t);
}

function immutableConstValue(sym: Symbol, t: Type): boolean {
	if (hasFlag(sym, SymbolFlag.ImmutableModuleConst)) return true;
	const immutable = isReadonlyView(t) ? builtFresh(sym)
		: sym.symbolKind == SymbolKind.Variable && !hasFlag(sym, SymbolFlag.Mutable) && isFrozenByConst(t) && noTaskStartsBefore(sym, Effect.StartsTask);
	if (immutable) setFlag(sym, SymbolFlag.ImmutableModuleConst);
	return immutable;
}

function reachesModuleState(e: Effect): boolean {
	return e == Effect.SpawnUnsafe || e == Effect.ActorReach;
}

function isReadonlyStatic(sym: Symbol): boolean {
	const decl = unpackDecl(sym.declNode);
	if (decl == null || decl.kind != NodeKind.PropertyDecl) return false;
	const d = decl.data as PropertyDeclData;
	return d.propIsStatic && d.propIsReadonly;
}

function isConstantValue(sym: Symbol, e: Effect): boolean {
	const t = sym.symbolType;
	if (hasFlag(sym, SymbolFlag.Mutable) && !isReadonlyStatic(sym)) return false;
	if (typeCarriesRef(t)) {
		if (t != null && t.kind == TypeKind.Ptr) return pointsAtConstantState(sym, e);
		return reachesModuleState(e) && immutableConstValue(sym, t);
	}
	return reachesModuleState(e) || !isAtomicRef(t);
}

function holdsOnlyPids(t: Type | null): boolean {
	if (t == null) return false;
	const u = t.kind == TypeKind.Ref && t.typeReturn != null ? t.typeReturn : t;
	if (u.kind == TypeKind.Array) return isReadonlyView(t) && holdsOnlyPids(u.typeReturn);
	return u.sym != null && u.sym.symbolKind == SymbolKind.Actor;
}

function isPidConst(sym: Symbol): boolean {
	if (sym.symbolKind != SymbolKind.Variable || !hasFlag(sym, SymbolFlag.Global) || hasFlag(sym, SymbolFlag.StaticLocal) || hasFlag(sym, SymbolFlag.Mutable)) return false;
	if (!holdsOnlyPids(sym.symbolType)) return false;
	const known = pidConsts.get(sym);
	if (known != null) return known;
	const init = constBindingInitializer(sym);
	const ok = init != null && isFreshValue(init, CONST_INIT_SCOPE) && noTaskStartsBefore(sym, Effect.RunsElsewhere);
	pidConsts.set(sym, ok);
	return ok;
}

function builtFresh(sym: Symbol): boolean {
	const known = freshConsts.get(sym);
	if (known != null) return known;
	const init = constBindingInitializer(sym);
	const values = init != null ? [init] : staticReadonlyValues(sym);
	const fresh = values != null && values.length > 0 && allFresh(values, CONST_INIT_SCOPE) && noTaskStartsBefore(sym, Effect.StartsTask);
	freshConsts.set(sym, fresh);
	return fresh;
}

function staticReadonlyValues(sym: Symbol): Node[] | null {
	const decl = unpackDecl(sym.declNode);
	if (!isReadonlyStatic(sym) || decl == null) return null;
	const values: Node[] = [];
	const init = (decl.data as PropertyDeclData).propInitializer;
	if (init != null) values.push(init);
	const cls = declaringClass(sym, decl);
	if (cls == null) return null;
	const writes: StaticWrites = { values, other: false };
	for (const m of (cls.data as ClassDeclData).classBody) {
		if (m.kind == NodeKind.BlockStmt) collectStaticWrites(m, sym, writes);
	}
	return writes.other ? null : values;
}

interface StaticWrites { values: Node[]; other: boolean; }

function collectStaticWrites(node: Node, sym: Symbol, w: StaticWrites): void {
	if (node.kind == NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		if (d.left.resolvedSym == sym && d.operator == "=") w.values.push(d.right);
		else if (d.left.resolvedSym == sym && isAssignOperator(d.operator)) w.other = true;
	}
	if (node.kind == NodeKind.UpdateExpr && (node.data as UpdateExprData).updateArg.resolvedSym == sym) w.other = true;
	forEachChild(node, (child: Node): void => { collectStaticWrites(child, sym, w); });
}

function isAssignOperator(op: string): boolean {
	return op.length >= 2 && op.endsWith("=") && op != "==" && op != "!=" && op != "<=" && op != ">=" && op != "===" && op != "!==";
}

function moduleStatements(modulePath: string): Node[] | null {
	recordBodyRead(modulePath);
	const program = lookupModuleProgram(modulePath);
	return program != null ? (program.data as ProgramData).programStmts : null;
}

function declaringClass(sym: Symbol, decl: Node): Node | null {
	const stmts = moduleStatements(sym.modulePath);
	if (stmts == null) return null;
	for (const stmt of stmts) {
		const c = unpackDecl(stmt.kind == NodeKind.ExportDecl ? (stmt.data as ExportDeclData).exportedDecl : stmt);
		if (c != null && c.kind == NodeKind.ClassDecl && declares(stmt, decl)) return c;
	}
	return null;
}

function noTaskStartsBefore(sym: Symbol, starts: Effect): boolean {
	const stmts = moduleStatements(sym.modulePath);
	const decl = sym.declNode;
	if (stmts == null || decl == null || !checkedModules.has(sym.modulePath)) return false;
	for (const stmt of stmts) {
		if (topLevelHas(stmt, starts)) return false;
		if (declares(stmt, decl)) return cycleStartsNoTask(sym.modulePath);
	}
	return false;
}

function declares(stmt: Node, decl: Node): boolean {
	const s = stmt.kind == NodeKind.ExportDecl ? (stmt.data as ExportDeclData).exportedDecl : stmt;
	if (s == decl || unpackDecl(s) == decl) return true;
	const c = unpackDecl(s);
	if (c == null || c.kind != NodeKind.ClassDecl) return false;
	for (const m of (c.data as ClassDeclData).classBody) {
		if (m == decl || unpackDecl(m) == decl) return true;
	}
	return false;
}

function topLevelStartsTask(stmt: Node): boolean {
	return topLevelHas(stmt, Effect.StartsTask);
}

function topLevelHas(stmt: Node, e: Effect): boolean {
	const s = unpackDecl(stmt.kind == NodeKind.ExportDecl ? (stmt.data as ExportDeclData).exportedDecl : stmt);
	if (s == null || isRoutineNode(s) || s.kind == NodeKind.TestDecl) return false;
	const members = s.kind == NodeKind.ClassDecl ? (s.data as ClassDeclData).classBody
		: s.kind == NodeKind.ActorDecl ? (s.data as ActorDeclData).actorBody : null;
	if (members == null) return walkEffect(s, e) != null;
	for (const m of members) {
		const member = unpackDecl(m);
		if (member == null || isRoutineNode(member)) continue;
		if (member.kind == NodeKind.PropertyDecl && !(member.data as PropertyDeclData).propIsStatic) continue;
		if (walkEffect(member, e) != null) return true;
	}
	return false;
}

function cycleStartsNoTask(path: string): boolean {
	if (moduleGraph == null) return false;
	for (const member of importCycleOf(moduleGraph!, path)) {
		if (member == path) continue;
		const known = startsByModule.get(member);
		if (known != null) {
			if (known) return false;
			continue;
		}
		recordBodyRead(member);
		const program = lookupModuleProgram(member);
		if (program == null || !checkedModules.has(member)) return false;
		let starts = false;
		for (const stmt of (program.data as ProgramData).programStmts) {
			if (topLevelStartsTask(stmt)) {
				starts = true;
				break;
			}
		}
		startsByModule.set(member, starts);
		if (starts) return false;
	}
	return true;
}

function importCycleOf(graph: ModuleGraph, path: string): string[] {
	const known = cycles.get(path);
	if (known != null) return known;
	const reached = reachableFrom(graph, path, false);
	const back = reachableFrom(graph, path, true);
	const cycle = reached.filter((p: string): boolean => back.includes(p));
	cycles.set(path, cycle);
	return cycle;
}

function reachableFrom(graph: ModuleGraph, start: string, reverse: boolean): string[] {
	const seen: string[] = [start];
	for (let i = 0; i < seen.length; i += 1) {
		for (const m of graph.modules) {
			for (const imp of m.imports) {
				if (imp.typeOnly) continue;
				if (reverse) {
					if (imp.sourcePath == seen[i] && !seen.includes(m.path)) seen.push(m.path);
				} else if (m.path == seen[i] && !seen.includes(imp.sourcePath)) {
					seen.push(imp.sourcePath);
				}
			}
		}
	}
	return seen;
}

const CONST_INIT_SCOPE: FreshScope = {
	moveNames: [],
	table: null,
	buildsAlone: (site: Node): boolean => (site.kind == NodeKind.NewExpr ? newEffect(site, Effect.SideEffect) : callEffect(site, Effect.SideEffect)) == null,
};

export interface FreshScope {
	moveNames: string[];
	table: SymbolTable | null;
	buildsAlone: (site: Node) => boolean;
}

export function peelView(n: Node): Node {
	let cur = peelConv(n);
	while (cur.kind == NodeKind.TypeAssertion || cur.kind == NodeKind.HiddenSubConv) {
		cur = peelConv(cur.kind == NodeKind.TypeAssertion ? (cur.data as TypeAssertionData).asExpr : (cur.data as HiddenStdConvData).convExpr);
	}
	return cur;
}

export function isFreshValue(n: Node | null, s: FreshScope): boolean {
	if (n == null) return true;
	if (n.nodeType != null && !typeCarriesRef(n.nodeType)) return true;
	const p = peelView(n);
	if (p != n) return isFreshValue(p, s);
	return match (p.kind) {
		NodeKind.NumberLiteral | NodeKind.StringLiteral | NodeKind.BooleanLiteral | NodeKind.NullLiteral
			| NodeKind.BigIntLiteral | NodeKind.RegexLiteral | NodeKind.MoveExpr | NodeKind.UnaryExpr
			| NodeKind.UpdateExpr | NodeKind.SizeofExpr => true,
		NodeKind.Identifier => {
			const name = (p.data as IdentifierData).name;
			if (s.moveNames.includes(name)) return true;
			const sym = p.resolvedSym != null ? p.resolvedSym : s.table != null ? lookupSymbol(s.table!, name) : null;
			if (sym == null) return true;
			if (sym.symbolKind != SymbolKind.Variable && sym.symbolKind != SymbolKind.Temp && sym.symbolKind != SymbolKind.Parameter) return true;
			return !typeCarriesRef(sym.symbolType);
		},
		NodeKind.ObjectLiteral => allStoredFresh((p.data as ObjectLiteralData).properties, s),
		NodeKind.ArrayLiteral => allStoredFresh((p.data as ArrayLiteralData).elements, s),
		NodeKind.SpreadExpr => isFreshValue((p.data as SpreadExprData).spreadArg, s),
		NodeKind.NewExpr => allFresh((p.data as NewExprData).newArguments, s) && s.buildsAlone(p),
		NodeKind.ArrowFunction | NodeKind.FunctionExpr => p.flags.has(NodeFlag.SendableClosure),
		NodeKind.CallExpr => {
			const d = p.data as CallExprData;
			if (isValueOnlyType(p.nodeType)) return true;
			const callee = d.callee != null ? peelView(d.callee) : null;
			if (callee != null && callee.kind == NodeKind.MemberExpr && !isFreshValue((callee.data as MemberExprData).object, s)) return false;
			return allFresh(d.arguments, s) && s.buildsAlone(p);
		},
		NodeKind.AwaitExpr => isFreshValue((p.data as AwaitExprData).awaitArg, s),
		NodeKind.ConditionalExpr => isFreshValue((p.data as ConditionalExprData).ternaryConsequent, s) && isFreshValue((p.data as ConditionalExprData).ternaryAlternate, s),
		NodeKind.MatchExpr => {
			for (const c of (p.data as MatchExprData).matchCases) {
				const b = (c.data as MatchCaseData).caseBody;
				if (b.kind == NodeKind.BlockStmt || !isFreshValue(b, s)) return false;
			}
			return true;
		},
		NodeKind.TryExpr => isFreshValue((p.data as TryExprData).tryArg, s) && (!(p.data as TryExprData).hasCatch || isFreshValue((p.data as TryExprData).catchVal, s)),
		NodeKind.BinaryExpr => {
			const d = p.data as BinaryExprData;
			if (d.operator == "??" || d.operator == "||" || d.operator == "&&") return isFreshValue(d.left, s) && isFreshValue(d.right, s);
			return true;
		},
		_ => false,
	};
}

function storedFresh(n: Node, s: FreshScope): boolean {
	if (isFreshValue(n, s)) return true;
	const p = peelView(n);
	if (p.kind != NodeKind.SpreadExpr) return n.nodeType != null && isValueOnlyType(n.nodeType);
	const t = (p.data as SpreadExprData).spreadArg.nodeType;
	return t != null && (t.kind == TypeKind.Array || t.kind == TypeKind.Span || t.kind == TypeKind.SizedArray) && isValueOnlyType(t.typeReturn);
}

function allStoredFresh(nodes: Node[], s: FreshScope): boolean {
	for (const n of nodes) {
		if (!storedFresh(n, s)) return false;
	}
	return true;
}

function allFresh(nodes: Node[], s: FreshScope): boolean {
	for (const n of nodes) {
		if (!isFreshValue(n, s)) return false;
	}
	return true;
}

function pointsAtConstantState(sym: Symbol, e: Effect): boolean {
	const init = constBindingInitializer(sym);
	if (init == null || init.kind != NodeKind.TypeAssertion) return false;
	const target = peelConv((init.data as TypeAssertionData).asExpr);
	const pointee = target.kind == NodeKind.Identifier ? target.resolvedSym : null;
	return pointee != null && pointee != sym && isModuleState(pointee) && isConstantValue(pointee, e);
}

function stateName(sym: Symbol): string {
	if (hasFlag(sym, SymbolFlag.Static)) return "static '" + sym.name + "'";
	if (sym.staticOwner != null) return "static '" + sym.staticOwner.name + "." + sym.name + "'";
	return "module-level '" + sym.name + "'";
}

function unpackDecl(decl: Node | null): Node | null {
	if (decl != null && decl.kind == NodeKind.DecoratedDecl) return (decl.data as DecoratedDeclData).decoratedNode;
	return decl;
}

function isRoutine(sym: Symbol | null): boolean {
	return sym != null && (sym.symbolKind == SymbolKind.Function || sym.symbolKind == SymbolKind.Method);
}

function through(site: Node, what: string, inner: EffectCause | null): EffectCause | null {
	if (inner == null) return null;
	const c = cause(site, what);
	return { site, text: c.text + ", which " + inner.text, advice: inner.advice };
}

function memo(sym: Symbol, e: Effect, compute: () => EffectCause | null): EffectCause | null {
	return memoIn(tableFor(e), sym, compute);
}

function memoIn(t: EffectTable, sym: Symbol, compute: () => EffectCause | null): EffectCause | null {
	const known = t.impure.get(sym);
	if (known != null) return known;
	if (t.pure.get(sym) != null) return null;
	if (t.open.includes(sym) || t.pureIfOpenArePure.get(sym) != null) {
		assumedOpen = true;
		return null;
	}
	const outer = assumedOpen;
	assumedOpen = false;
	t.open.push(sym);
	const c = compute();
	t.open.pop();
	if (c != null) t.impure.set(sym, c);
	else if (!assumedOpen) t.pure.set(sym, true);
	else t.pureIfOpenArePure.set(sym, true);
	if (t.open.length == 0) settleOpenRegion(t, c == null);
	assumedOpen = outer || assumedOpen;
	return c;
}

function settleOpenRegion(t: EffectTable, pure: boolean): void {
	if (pure) {
		for (const sym of t.pureIfOpenArePure.keys()) t.pure.set(sym, true);
	}
	t.pureIfOpenArePure = new HashMap<Symbol, boolean>();
}

export function routineEffect(sym: Symbol, e: Effect): EffectCause | null {
	recordBodyRead(sym.modulePath);
	return memo(sym, e, (): EffectCause | null => walkRoutine(unpackDecl(sym.declNode), e));
}

export function constructionEffect(classSym: Symbol, e: Effect): EffectCause | null {
	recordBodyRead(classSym.modulePath);
	return memo(classSym, e, (): EffectCause | null => {
		const decl = unpackDecl(classSym.declNode);
		if (decl == null || (decl.kind != NodeKind.ClassDecl && decl.kind != NodeKind.ActorDecl)) return null;
		const members = decl.kind == NodeKind.ClassDecl ? (decl.data as ClassDeclData).classBody : (decl.data as ActorDeclData).actorBody;
		for (const m of members) {
			const member = unpackDecl(m);
			if (member == null) continue;
			let c: EffectCause | null = null;
			if (member.kind == NodeKind.PropertyDecl && !(member.data as PropertyDeclData).propIsStatic) {
				c = walkEffect((member.data as PropertyDeclData).propInitializer, e);
			} else if (member.kind == NodeKind.ConstructorDecl) {
				c = walkRoutine(member, e);
			}
			if (c != null) return c;
		}
		const parent = decl.kind == NodeKind.ClassDecl ? parentClassSymOf(classSym) : null;
		if (parent == null) return null;
		return through(decl, "extends '" + parent.name + "'", constructionEffect(parent, e));
	});
}

function dispatchedEffect(call: Node, sym: Symbol, e: Effect): EffectCause | null {
	const entry = dispatchEntryFor(sym);
	if (entry == null || entry.overloaded) return null;
	for (const o of dispatchOverridesFor(entry.classSym, entry.methodName)) {
		const what = "calls '" + entry.methodName + "' as overridden in '" + o.classSym.name + "'";
		const c = through(call, what, routineEffect(o.sym, e));
		if (c != null) return c;
	}
	return null;
}

function isSuperCall(callee: Node | null): boolean {
	return callee != null && callee.kind == NodeKind.Identifier && (callee.data as IdentifierData).name == "super";
}

export function callEffect(call: Node, e: Effect): EffectCause | null {
	const callee = (call.data as CallExprData).callee;
	if (isSuperCall(callee)) return null;
	if ((e == Effect.Suspends || e == Effect.StartsTask || e == Effect.RunsElsewhere) && isSpawnCall(call)) return cause(call, "spawns");
	if (callee != null && callee.resolvedSym != null && callee.resolvedSym.builtinKind == BuiltinKind.DynamicImport) {
		return e == Effect.SideEffect ? cause(call, "imports '" + callee.resolvedSym.modulePath + "'") : null;
	}
	const sym = call.resolvedSym;
	if (!isRoutine(sym)) {
		if (call.nodeType == null && (callee == null || callee.nodeType == null)) {
			if (uncheckedBodiesReported) return null;
			throw new Error(`internal: the effect walk reached a call at ${call.location.line}:${call.location.column} whose routine body was never checked`);
		}
		if (isOwnParam(callee) || isOwnParamField(callee, e)) return null;
		const valueType: Type | null = callee != null ? callee.nodeType : null;
		if (reachesModuleState(e) && isSendableFunction(valueType)) return null;
		if (callee != null && callee.kind == NodeKind.Identifier && boundRoutine(callee.resolvedSym) != null) {
			return through(call, "calls '" + (callee.data as IdentifierData).name + "'", boundRoutineEffect(callee.resolvedSym!, e));
		}
		return e == Effect.StoresBorrowed || e == Effect.ActorReach ? null : cause(call, "calls a function value");
	}
	if (hasFlag(sym!, SymbolFlag.GeneratedOp) || isStdBuiltinWritingNothing(sym!) || isScalarToString(call, sym!)) return null;
	const external = isExternalRoutine(sym!);
	if (external) {
		if (e != Effect.SideEffect || receiverOf(call) != null) return null;
		return cause(call, "calls the external '" + sym!.name + "'");
	}
	const name = callee != null && callee.kind == NodeKind.Identifier ? (callee.data as IdentifierData).name
		: callee != null && callee.kind == NodeKind.MemberExpr ? (callee.data as MemberExprData).property : sym!.name;
	for (const arg of (call.data as CallExprData).arguments) {
		const passed = argumentEffect(arg, e);
		if (passed != null) return through(call, "calls '" + name + "'", passed);
	}
	const own = through(call, "calls '" + name + "'", routineEffect(sym!, e));
	if (own != null) return own;
	const dispatched = dispatchedEffect(call, sym!, e);
	return dispatched != null ? dispatched : ownedValueHookEffect(call, e);
}

function isMessageToAnotherActor(call: Node): boolean {
	const recv = receiverOf(call);
	if (recv == null || (recv.kind == NodeKind.Identifier && (recv.data as IdentifierData).name == "this")) return false;
	const t = recv.nodeType;
	return t != null && t.sym != null && t.sym.symbolKind == SymbolKind.Actor;
}

function receiverEffect(recv: Node | null, e: Effect): EffectCause | null {
	if (recv == null || !reachesModuleState(e)) return walkEffect(recv, e);
	const p = peelView(recv);
	if (p.kind == NodeKind.ArrayAccess) {
		const d = p.data as ArrayAccessData;
		return walkEffect(d.index, e) ?? receiverEffect(d.array, e);
	}
	if (p.kind == NodeKind.Identifier && p.resolvedSym != null && isPidConst(p.resolvedSym!)) return null;
	return walkEffect(recv, e);
}

function messageOperandsEffect(call: Node, e: Effect): EffectCause | null {
	const c = receiverEffect(receiverOf(call), e);
	if (c != null) return c;
	for (const arg of (call.data as CallExprData).arguments) {
		const a = walkEffect(arg, e);
		if (a != null) return a;
	}
	return null;
}

function isStdBuiltinWritingNothing(sym: Symbol): boolean {
	return BUILTINS_WRITING_NOTHING.includes(sym.builtinKind);
}

function isScalarToString(call: Node, sym: Symbol): boolean {
	const args = (call.data as CallExprData).arguments;
	return sym.builtinKind == BuiltinKind.ToString && args.length == 1 && isScalarPrimitive(args[0].nodeType);
}

export function newEffect(newNode: Node, e: Effect): EffectCause | null {
	const classSym = (newNode.data as NewExprData).newCallee.resolvedSym;
	if (e == Effect.StartsTask && classSym != null && classSym.symbolKind == SymbolKind.Actor) return cause(newNode, "starts the actor '" + classSym.name + "'");
	if (classSym != null && classSym.symbolKind == SymbolKind.Actor && (reachesModuleState(e) || e == Effect.RunsElsewhere)) {
		return through(newNode, "constructs the actor '" + classSym.name + "'", constructionEffect(classSym, e));
	}
	if (classSym == null || classSym.symbolKind != SymbolKind.Class) return null;
	const built = through(newNode, "constructs '" + classSym.name + "'", constructionEffect(classSym, e));
	return built != null ? built : ownedValueHookEffect(newNode, e);
}

function ownedValueHookEffect(site: Node, e: Effect): EffectCause | null {
	if (!reachesModuleState(e) || hookRegistry == null || site.nodeType == null) return null;
	const typeSym = nominalTypeSym(site.nodeType!);
	if (typeSym == null) return null;
	for (const name of TASK_DROP_HOOKS) {
		for (const m of findAllExtensionsByName(hookRegistry!, name)) {
			if (m.isStatic || m.sym == null || extReceiverSym(m) != typeSym) continue;
			const c = through(site, "owns a '" + typeSym.name + "' whose '" + name + "' runs here", routineEffect(m.sym!, e));
			if (c != null) return c;
		}
	}
	return null;
}

function useEffect(node: Node, e: Effect): EffectCause | null {
	const sym = node.resolvedSym;
	if (sym == null) return null;
	if ((e == Effect.Suspends || e == Effect.StoresBorrowed || e == Effect.StartsTask || e == Effect.RunsElsewhere) && sym.symbolKind != SymbolKind.Function) return null;
	if (isModuleState(sym)) return isConstantValue(sym, e) ? null : cause(node, "uses " + stateName(sym));
	if (sym.symbolKind == SymbolKind.Function) return through(node, "refers to '" + sym.name + "'", routineEffect(sym, e));
	return null;
}

function isExternalRoutine(sym: Symbol): boolean {
	return hasFlag(sym, SymbolFlag.ImportC) || routineBody(unpackDecl(sym.declNode)) == null;
}

function userOperatorEffect(node: Node, e: Effect): EffectCause | null {
	const sym = node.resolvedSym;
	if (e == Effect.StoresBorrowed || !node.flags.has(NodeFlag.UserOp) || !isRoutine(sym)) return null;
	if (hasFlag(sym!, SymbolFlag.GeneratedOp) || isStdBuiltinWritingNothing(sym!)) return null;
	if (isExternalRoutine(sym!)) return null;
	return through(node, "calls the operator '" + sym!.name + "'", routineEffect(sym!, e));
}

export function walkEffect(node: Node | null, e: Effect): EffectCause | null {
	if (node == null) return null;
	if (isRoutineNode(node)) return walkNestedRoutine(node, e);
	if (e == Effect.RunsElsewhere && node.kind == NodeKind.CallExpr && isMessageToAnotherActor(node)) return cause(node, "messages an actor");
	if ((e == Effect.Suspends || reachesModuleState(e)) && node.kind == NodeKind.CallExpr && isMessageToAnotherActor(node)) return messageOperandsEffect(node, e);
	const here: EffectCause | null = match (node.kind) {
		NodeKind.Identifier | NodeKind.MemberExpr => useEffect(node, e),
		NodeKind.CallExpr => e == Effect.StoresBorrowed ? sinkStoreOf(node) ?? viewArgEffect(node) ?? callEffect(node, e) : callEffect(node, e),
		NodeKind.NewExpr => e == Effect.StoresBorrowed ? newViewArgEffect(node) ?? newEffect(node, e) : newEffect(node, e),
		NodeKind.AwaitExpr => e == Effect.Suspends && !inAsync ? cause(node, "awaits") : null,
		NodeKind.BinaryExpr | NodeKind.ArrayLiteral | NodeKind.ObjectLiteral => e == Effect.StoresBorrowed ? slotStoreOf(node) : null,
		NodeKind.ReturnStmt => e == Effect.StoresBorrowed ? resultStoreOf((node.data as ReturnStmtData).argument) : null,
		_ => null,
	};
	if (here != null) return here;
	const op = userOperatorEffect(node, e);
	if (op != null) return op;
	if ((e == Effect.StoresBorrowed || reachesModuleState(e)) && node.kind == NodeKind.ForOfStmt && node.resolvedSym != null) forOfSources.set(node.resolvedSym!, (node.data as ForOfStmtData).forOfIterable);
	return walkChildren(node, e);
}

// What a stored value borrows, seen through conversions, both arms of a choice, field and element
// reads, a view call's sources and a local const or for-of binding: a module const every thread
// shares, or a view of what the task borrows. Storing it into an owning slot takes a count on it.
function borrowedOf(value: Node | null): BorrowSource | null {
	if (value == null) return null;
	const n = peelConv(value);
	if (!typeCarriesRef(n.nodeType) || isAtomicRef(n.nodeType)) return null;
	return match (n.kind) {
		NodeKind.ConditionalExpr => borrowedOf((n.data as ConditionalExprData).ternaryConsequent) ?? borrowedOf((n.data as ConditionalExprData).ternaryAlternate),
		NodeKind.BinaryExpr => binaryBorrow(n),
		NodeKind.TypeAssertion => borrowedOf((n.data as TypeAssertionData).asExpr),
		NodeKind.HiddenSubConv => borrowedOf((n.data as HiddenStdConvData).convExpr),
		NodeKind.HiddenAddr => borrowedOf((n.data as HiddenDerefData).expr),
		NodeKind.MoveExpr => borrowedOf((n.data as MoveExprData).moveArg),
		NodeKind.TryExpr => borrowedOf((n.data as TryExprData).tryArg),
		NodeKind.MatchExpr => matchBorrow(n),
		NodeKind.MemberExpr => borrowedOf((n.data as MemberExprData).object) ?? heldBorrow((n.data as MemberExprData).object),
		NodeKind.ArrayAccess => borrowedOf((n.data as ArrayAccessData).array) ?? heldBorrow((n.data as ArrayAccessData).array),
		NodeKind.SpreadExpr => spreadBorrow(n),
		NodeKind.CallExpr => callBorrow(n),
		NodeKind.Identifier => bindingBorrow(n, value),
		NodeKind.ArrowFunction | NodeKind.FunctionExpr => capturedBorrow(n),
		NodeKind.NewExpr | NodeKind.ArrayLiteral | NodeKind.ObjectLiteral | NodeKind.AwaitExpr | NodeKind.StringLiteral | NodeKind.NullLiteral
			| NodeKind.NumberLiteral | NodeKind.BooleanLiteral | NodeKind.BigIntLiteral | NodeKind.RegexLiteral | NodeKind.UnaryExpr | NodeKind.UpdateExpr | NodeKind.SizeofExpr => null,
		_ => unfollowed(),
	};
}

function spreadBorrow(n: Node): BorrowSource | null {
	const arg = (n.data as SpreadExprData).spreadArg;
	let t = arg.nodeType;
	while (t != null && (t.kind == TypeKind.Ref || t.kind == TypeKind.Var) && t.typeReturn != null) t = t.typeReturn;
	return t != null && t.kind == TypeKind.Array && !typeCarriesRef(t.typeReturn) ? null : borrowedOf(arg);
}

function viewsInScope(): boolean {
	return viewSyms.length > 0 || viewParams.length > 0;
}

function unfollowed(): BorrowSource | null {
	return viewsInScope() ? { kind: BorrowKind.Unfollowed, sym: null } : null;
}

function binaryBorrow(n: Node): BorrowSource | null {
	const d = n.data as BinaryExprData;
	if (d.operator == "??" || d.operator == "||" || d.operator == "&&") return borrowedOf(d.left) ?? borrowedOf(d.right);
	return d.operator == "=" ? borrowedOf(d.right) : unfollowed();
}

function matchBorrow(n: Node): BorrowSource | null {
	for (const c of (n.data as MatchExprData).matchCases) {
		const b = borrowedOf((c.data as MatchCaseData).caseBody);
		if (b != null) return b;
	}
	return null;
}

// A call returns what the task borrows when it is a view call over a borrowed source, or when its
// result does not own and a receiver, a local container it reads or an argument is borrowed; an
// owning result is a fresh value whatever the call reads.
function callBorrow(call: Node): BorrowSource | null {
	if (isViewCall(call)) {
		const sources: Node[] = [];
		viewCallSources(call, sources);
		return firstBorrow(sources);
	}
	if (!isReadonlyView(call.nodeType) && !holdsNoCountResult(call.nodeType)) return null;
	const recv = receiverOf(call);
	const viewed = recv != null ? borrowedOf(recv) ?? heldBorrow(recv) : null;
	return viewed ?? firstBorrow((call.data as CallExprData).arguments);
}

function holdsNoCountResult(t: Type | null): boolean {
	if (t == null) return false;
	if (holdsNoCount(t)) return true;
	if (t.kind != TypeKind.Union) return false;
	for (const m of t.typeChildren) {
		if (holdsNoCount(m)) return true;
	}
	return false;
}

function capturedBorrow(fn: Node): BorrowSource | null {
	const hit: (BorrowSource | null)[] = [null];
	const visit = (node: Node): void => {
		if (hit[0] != null) return;
		if (node.kind == NodeKind.Identifier && node.resolvedSym != null && isViewRoot(node.resolvedSym!)) hit[0] = { kind: BorrowKind.View, sym: node.resolvedSym };
		forEachChild(node, visit);
	};
	forEachChild(fn, visit);
	return hit[0];
}

function isViewRoot(sym: Symbol): boolean {
	return viewSyms.includes(sym) || (viewParams.includes(sym.name) && (sym.symbolKind == SymbolKind.Parameter || sym.name == "this"));
}

function isLocalBinding(sym: Symbol | null): boolean {
	return sym != null && (sym.symbolKind == SymbolKind.Variable || sym.symbolKind == SymbolKind.Parameter) && !hasFlag(sym, SymbolFlag.Global);
}

function bindingBorrow(n: Node, value: Node): BorrowSource | null {
	const sym = n.resolvedSym;
	if (sym == null) return null;
	if (isImmutableModuleConst(sym)) return { kind: BorrowKind.ModuleConst, sym };
	if (isViewRoot(sym)) return { kind: BorrowKind.View, sym };
	if (!isLocalBinding(sym) || resolving.includes(sym)) return null;
	resolving.push(sym);
	const b = localBorrow(sym, value);
	resolving.pop();
	return b;
}

function localBorrow(sym: Symbol, value: Node): BorrowSource | null {
	const iterated = forOfSources.get(sym);
	if (iterated != null) {
		const b = borrowedOf(iterated) ?? heldBorrow(iterated);
		if (b != null) return b;
	}
	const decl = sym.declNode;
	const bound = decl != null && decl.kind == NodeKind.VariableDecl ? (decl.data as VariableDeclData).initializer : null;
	if (bound != null && bound != value) {
		const b = borrowedOf(bound);
		if (b != null) return b;
	}
	return firstBorrow(assignedSources.get(sym));
}

// What a local container holds: every element store and every argument of a call on it.
function heldBorrow(container: Node | null): BorrowSource | null {
	const root = container != null ? pathRoot(container) : null;
	if (root == null || !isLocalBinding(root) || resolving.includes(root)) return null;
	resolving.push(root);
	const b = firstBorrow(heldSources.get(root));
	resolving.pop();
	return b;
}

function firstBorrow(sources: Node[] | null): BorrowSource | null {
	if (sources == null) return null;
	for (const v of sources) {
		const b = borrowedOf(v);
		if (b != null) return b;
	}
	return null;
}

function pathRoot(n: Node): Symbol | null {
	let cur = peelConv(n);
	while (cur.kind == NodeKind.MemberExpr || cur.kind == NodeKind.ArrayAccess) {
		cur = peelConv(cur.kind == NodeKind.MemberExpr ? (cur.data as MemberExprData).object : (cur.data as ArrayAccessData).array);
	}
	return cur.kind == NodeKind.Identifier ? cur.resolvedSym : null;
}

function addSource(table: HashMap<Symbol, Node[]>, sym: Symbol, value: Node): void {
	const known = table.get(sym);
	if (known != null) known.push(value);
	else table.set(sym, [value]);
}

function scanFlows(node: Node | null): void {
	if (node == null || flowScanned.includes(node)) return;
	flowScanned.push(node);
	const visit = (n: Node): void => {
		if (n.kind == NodeKind.BinaryExpr && (n.data as BinaryExprData).operator == "=" && (n.data as BinaryExprData).left != null) {
			const d = n.data as BinaryExprData;
			const left = peelConv(d.left);
			if (left.kind == NodeKind.Identifier && isLocalBinding(left.resolvedSym)) addSource(assignedSources, left.resolvedSym!, d.right);
			else if (left.kind == NodeKind.ArrayAccess) {
				const root = pathRoot(left);
				if (isLocalBinding(root)) addSource(heldSources, root!, peelConv(d.right));
			}
		}
		if (n.kind == NodeKind.CallExpr) {
			const recv = receiverOf(n);
			const root = recv != null ? pathRoot(recv) : null;
			if (isLocalBinding(root) && mayStoreIntoReceiver(n)) {
				for (const a of (n.data as CallExprData).arguments) addSource(heldSources, root!, peelConv(a));
			}
		}
		forEachChild(n, visit);
	};
	visit(node);
}

function mayStoreIntoReceiver(call: Node): boolean {
	if (!call.flags.has(NodeFlag.ExtCall)) return true;
	const sig = calledRoutineType(call);
	const formal = sig != null && sig.typeChildren.length > 0 ? sig.typeChildren[0] : null;
	return formal == null || formal.kind == TypeKind.Var || formal.kind == TypeKind.Sink || holdsPointerByValue(formal, 0);
}

function holdsPointerByValue(t: Type | null, depth: int32): boolean {
	if (t == null || depth > 8) return true;
	if (isPrimitiveKind(t.kind)) return false;
	return match (t.kind) {
		TypeKind.String | TypeKind.BigInt | TypeKind.Function => false,
		TypeKind.Struct | TypeKind.Tuple | TypeKind.Union => t.typeChildren.some((c: Type): boolean => holdsPointerByValue(c, depth + 1)),
		TypeKind.SizedArray => holdsPointerByValue(t.typeReturn, depth + 1),
		_ => true,
	};
}

function storeCause(site: Node, what: BorrowSource, into: string): EffectCause {
	return cause(site, "stores " + borrowText(what) + " " + into);
}

function holdsNoCount(slot: Readonly<Type | null>): boolean {
	return slot != null && slot.kind == TypeKind.Cursor;
}

function isCursorToReference(slot: Readonly<Type | null>): boolean {
	return holdsNoCount(slot) && slot!.typeReturn != null && slot!.typeReturn.kind == TypeKind.Ref;
}

function elementHoldsNoCount(container: Type | null): boolean {
	let t = container;
	while (t != null && (t.kind == TypeKind.Ref || t.kind == TypeKind.Var) && t.typeReturn != null) t = t.typeReturn;
	return t != null && t.kind == TypeKind.Array && holdsNoCount(t.typeReturn);
}

function slotStoreOf(node: Node): EffectCause | null {
	if (node.kind == NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		if (d.operator != "=" || d.left == null || d.left.kind == NodeKind.Identifier || holdsNoCount(d.left.nodeType)) return null;
		const what = borrowedOf(d.right);
		return what != null ? storeCause(node, what, d.left.kind == NodeKind.ArrayAccess ? "into an array element" : "into a field") : null;
	}
	if (node.kind == NodeKind.ArrayLiteral && elementHoldsNoCount(node.nodeType)) return null;
	const items = node.kind == NodeKind.ArrayLiteral ? (node.data as ArrayLiteralData).elements : (node.data as ObjectLiteralData).properties;
	for (let i = 0; i < items.length; i += 1) {
		const keys = node.kind == NodeKind.ObjectLiteral ? (node.data as ObjectLiteralData).keys : [];
		if (i < keys.length && keys[i] != "" && isCursorToReference(declaredFieldType(node.nodeType, keys[i]))) continue;
		const what = borrowedOf(items[i]);
		if (what == null) continue;
		const into = node.kind == NodeKind.ArrayLiteral ? "into an array literal" : i < keys.length && keys[i] != "" ? "into the field '" + keys[i] + "' of an object literal" : "into an object literal";
		return storeCause(items[i], what, into);
	}
	return null;
}

function sinkStoreOf(call: Node): EffectCause | null {
	const sig = calledRoutineType(call);
	if (sig == null) return null;
	const shift = call.flags.has(NodeFlag.ExtCall) ? 1 : 0;
	const args = (call.data as CallExprData).arguments;
	const receiver = shift == 1 ? receiverOf(call) : null;
	if (receiver != null && sig.typeChildren.length > 0 && sig.typeChildren[0] != null && sig.typeChildren[0].kind == TypeKind.Sink) {
		const what = borrowedOf(receiver);
		if (what != null) return storeCause(receiver, what, "into a sink parameter");
	}
	const into = receiver != null ? receiver : receiverOf(call);
	if (into != null && elementHoldsNoCount(into.nodeType)) return null;
	for (let i = 0; i < args.length; i += 1) {
		const f = i + shift < sig.typeChildren.length ? sig.typeChildren[i + shift] : null;
		if (f == null || f.kind != TypeKind.Sink || holdsNoCount(f.typeReturn)) continue;
		const what = borrowedOf(args[i]);
		if (what != null) return storeCause(args[i], what, "into a sink parameter");
	}
	return null;
}

// A callee reached with a borrowed argument stores it when its body, or the body of an override
// the call may dispatch to, stores that parameter, as the task would store the argument itself.
function viewArgEffect(call: Node): EffectCause | null {
	const callee = (call.data as CallExprData).callee;
	const sym = isSuperCall(callee) ? callee!.resolvedSym : call.resolvedSym;
	if (!isRoutine(sym)) return null;
	const shift = call.flags.has(NodeFlag.ExtCall) ? 1 : 0;
	const actorPidNotView = isMessageToAnotherActor(call);
	const passed: (Node | null)[] = shift == 1 ? [actorPidNotView ? null : receiverOf(call)] : [];
	for (const a of (call.data as CallExprData).arguments) passed.push(a);
	const name = callee != null && callee.kind == NodeKind.MemberExpr ? (callee.data as MemberExprData).property : isSuperCall(callee) ? "super" : sym!.name;
	if (shift == 0 && !actorPidNotView && isExternalRoutine(sym!) && unpackDecl(sym!.declNode) != null && unpackDecl(sym!.declNode)!.kind == NodeKind.MethodDecl) {
		const recv = receiverOf(call);
		const what = recv != null ? borrowedOf(recv) ?? heldBorrow(recv) : null;
		if (what != null) return lentToForeign(call, what, name, "as its receiver");
	}
	const targets: Symbol[] = [sym!];
	const entry = dispatchEntryFor(sym!);
	if (entry != null && !entry.overloaded) {
		for (const o of dispatchOverridesFor(entry.classSym, entry.methodName)) targets.push(o.sym);
	}
	return passedViewEffect(call, passed, targets, name);
}

function newViewArgEffect(newNode: Node): EffectCause | null {
	const d = newNode.data as NewExprData;
	const classSym = d.newCallee.resolvedSym;
	const ctor = ctorRoutineOf(classSym);
	if (ctor == null) return null;
	const passed: (Node | null)[] = [];
	for (const a of d.newArguments) passed.push(a);
	const written = d.newCallee.kind == NodeKind.Identifier ? (d.newCallee.data as IdentifierData).name : classSym!.name;
	return passedViewEffect(newNode, passed, [ctor], "new " + written);
}

function passedViewEffect(call: Node, passed: (Node | null)[], targets: Symbol[], name: string): EffectCause | null {
	for (let i = 0; i < passed.length; i += 1) {
		const what = borrowedOf(passed[i]);
		if (what == null) continue;
		for (const t of targets) {
			if (isExternalRoutine(t)) {
				const sig = call.kind == NodeKind.CallExpr && t == targets[0] ? calledRoutineType(call) : t.symbolType;
				const formal = sig != null && i < sig.typeChildren.length ? sig.typeChildren[i] : null;
				if (!foreignSlotTakesNothing(formal, passed[i]!.nodeType)) return lentToForeign(call, what, name, "through a parameter of type '" + typeNameOf(formal) + "'");
				continue;
			}
			const decl = unpackDecl(t.declNode);
			const params = decl != null && routineBody(decl) != null ? routineParams(decl) : [];
			const c = i < params.length ? paramStoreEffect(t, decl!, i, params[i]) : null;
			if (c != null) return through(call, "passes " + borrowText(what) + " to '" + name + "'", c);
		}
	}
	return null;
}

const FOREIGN_ADVICE = "C may count or write what it receives there while another thread reads the same value, so pass an explicit copy (clone or spread), or declare that parameter Readonly over value-only data when C only reads it";

function lentToForeign(call: Node, what: BorrowSource, name: string, how: string): EffectCause {
	const c = cause(call, "passes " + borrowText(what) + " to the external '" + name + "' " + how);
	return { site: c.site, text: c.text, advice: FOREIGN_ADVICE };
}

function foreignSlotTakesNothing(formal: Type | null, actual: Type | null): boolean {
	if (formal == null || formal.kind == TypeKind.Var || formal.kind == TypeKind.Sink) return false;
	if (!holdsPointerByValue(formal, 0)) return true;
	if (!isReadonlyView(formal)) return false;
	if (formal.kind == TypeKind.Array || formal.kind == TypeKind.Span || formal.kind == TypeKind.Ptr) {
		let passed = actual;
		while (passed != null && (passed.kind == TypeKind.Ref || passed.kind == TypeKind.Var) && passed.typeReturn != null) passed = passed.typeReturn;
		const elem = formal.typeReturn != null && hasGenericParams(formal.typeReturn) && passed != null ? passed.typeReturn : formal.typeReturn;
		return elem != null && elem.kind != TypeKind.Void && isValueOnlyType(elem);
	}
	return formal.kind == TypeKind.Struct && formal.typeChildren.every((f: Type): boolean => isValueOnlyType(f));
}

function paramStoreEffect(sym: Symbol, decl: Node, index: int32, name: string): EffectCause | null {
	recordBodyRead(sym.modulePath);
	while (paramStoreTables.length <= index) paramStoreTables.push(emptyTable());
	return memoIn(paramStoreTables[index], sym, (): EffectCause | null => walkRoutine(decl, Effect.StoresBorrowed, [name]));
}

function walkChildren(node: Node, e: Effect): EffectCause | null {
	const found: (EffectCause | null)[] = [null];
	forEachChild(node, (child: Node): void => {
		if (found[0] == null) found[0] = walkEffect(child, e);
	});
	return found[0];
}

function linkedGraph(edges: string[][], typeOnly: boolean): ModuleGraph {
	const graph = createModuleGraph();
	for (const e of edges) {
		const mod = createModule(e[0]);
		mod.imports.push({ names: [], aliases: [], sourcePath: e[1], sourceSpecifier: e[1], dynamic: false, typeOnly });
		addModule(graph, mod);
	}
	return graph;
}

test "reachableFrom follows imports forward and backward in discovery order" {
	const graph = linkedGraph([["a", "b"], ["b", "c"], ["c", "b"], ["d", "a"]], false);
	assert(reachableFrom(graph, "a", false).join(",") == "a,b,c");
	assert(reachableFrom(graph, "a", true).join(",") == "a,d");
	assert(importCycleOf(graph, "b").join(",") == "b,c");
}

test "reachableFrom skips type-only imports" {
	const graph = linkedGraph([["a", "b"], ["b", "c"]], true);
	assert(reachableFrom(graph, "a", false).join(",") == "a");
	assert(reachableFrom(graph, "c", true).join(",") == "c");
}
