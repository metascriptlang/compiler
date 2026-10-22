// Effects are read from checked bodies, and a callee later in the module is not
// checked yet where its caller is: queue a check with deferEffectCheck.

import { ArrayLiteralData, ArrowFunctionData, CallExprData, HiddenDerefData, HiddenStdConvData, ClassDeclData, ConstructorDeclData, DecoratedDeclData, FunctionDeclData, FunctionExprData, IdentifierData, MemberExprData, MethodDeclData, NewExprData, Node, NodeFlag, NodeKind, ObjectLiteralData, PropertyDeclData, Symbol, SymbolKind, Type, TypeAssertionData, TypeKind } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { CheckerContext, ExtensionRegistry, LIFECYCLE_HOOK_NAMES, addError, isGenericFn, dispatchEntryFor, dispatchOverridesFor, extReceiverSym, findAllExtensionsByName, nominalTypeSym } from "./context";
import { isAsyncFunctionNode, isSpawnCall } from "./freestanding";
import { SymbolFlag, findOverloadImpl, hasFlag, overloadWinner, parentClassSymOf } from "./symbol";
import { functionSlotOf, hasGenericParams, isAtomicRef, isReadonlyView, isSendableFunction, typeCarriesRef } from "./types";
import { constBindingInitializer } from "./constFold";
import { DYNAMIC_IMPORT } from "./importCall";

export enum Effect {
	SideEffect,
	SpawnUnsafe,
	Suspends,
}

export interface EffectCause {
	site: Node;
	text: string;
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
let suspendTable: EffectTable = emptyTable();
let assumedOpen = false;
let inAsync = false;
let ownParams: string[] = [];
interface DeferredCheck {
	site: Node;
	rule: string;
	check: (ctx: CheckerContext) => void;
}

let deferred: DeferredCheck[] = [];
let hookRegistry: ExtensionRegistry | null = null;
const TASK_DROP_HOOKS: string[] = ["onDestroy", "onCopy", "onClone"];

function tableFor(e: Effect): EffectTable {
	return match (e) {
		Effect.SideEffect => sideTable,
		Effect.SpawnUnsafe => spawnTable,
		Effect.Suspends => suspendTable,
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
	for (const d of checks) d.check(ctx);
	hookRegistry = null;
	checkHookEffects(ctx);
	sideTable = emptyTable();
	spawnTable = emptyTable();
	suspendTable = emptyTable();
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

function cause(site: Node, what: string): EffectCause {
	return { site, text: what + " at " + site.location.line + ":" + site.location.column };
}

export function routineBody(decl: Node | null): Node | null {
	if (decl == null) return null;
	return match (decl.kind) {
		NodeKind.FunctionDecl => (decl.data as FunctionDeclData).fnBody,
		NodeKind.MethodDecl => (decl.data as MethodDeclData).methodBody,
		NodeKind.ConstructorDecl => (decl.data as ConstructorDeclData).ctorBody,
		NodeKind.ArrowFunction => (decl.data as ArrowFunctionData).arrowBody,
		NodeKind.FunctionExpr => (decl.data as FunctionExprData).funcExprBody,
		_ => null,
	};
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

function walkRoutine(decl: Node | null, e: Effect): EffectCause | null {
	if (decl == null) return null;
	const outer = ownParams;
	const outerAsync = inAsync;
	ownParams = routineParams(decl);
	inAsync = isAsyncFunctionNode(decl);
	const c = walkEffect(routineBody(decl), e);
	ownParams = outer;
	inAsync = outerAsync;
	return c;
}

function walkNestedRoutine(decl: Node, e: Effect): EffectCause | null {
	const outer = ownParams;
	const outerAsync = inAsync;
	ownParams = routineParams(decl);
	inAsync = isAsyncFunctionNode(decl);
	const c = walkChildren(decl, e);
	ownParams = outer;
	inAsync = outerAsync;
	return c;
}

function isOwnParam(n: Node | null): boolean {
	if (n == null || n.kind != NodeKind.Identifier) return false;
	const sym = n.resolvedSym;
	return sym != null && sym.symbolKind == SymbolKind.Parameter && ownParams.includes(sym.name);
}

function peelConv(n: Node): Node {
	let cur = n;
	while (cur.kind == NodeKind.HiddenStdConv || cur.kind == NodeKind.HiddenDeref) {
		cur = cur.kind == NodeKind.HiddenStdConv ? (cur.data as HiddenStdConvData).convExpr : (cur.data as HiddenDerefData).expr;
	}
	return cur;
}

function boundRoutine(sym: Symbol | null): Node | null {
	const bound = constBindingInitializer(sym);
	return bound != null && isRoutineNode(peelConv(bound)) ? peelConv(bound) : null;
}

function boundRoutineEffect(sym: Symbol, e: Effect): EffectCause | null {
	return memo(sym, e, (): EffectCause | null => walkEffect(boundRoutine(sym), e));
}

function argumentEffect(arg: Node, e: Effect): EffectCause | null {
	if (functionSlotOf(arg.nodeType) == null) return null;
	if (e == Effect.SpawnUnsafe && isSendableFunction(arg.nodeType)) return null;
	const a = peelConv(arg);
	if (isRoutineNode(a) || isOwnParam(a)) return null;
	if (a.kind == NodeKind.Identifier && a.resolvedSym != null) {
		if (isRoutine(a.resolvedSym)) return null;
		if (boundRoutine(a.resolvedSym) != null) return boundRoutineEffect(a.resolvedSym!, e);
	}
	return cause(arg, "passes a function value");
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
		const winner = overloadWinner(sym, (call.data as CallExprData).resolvedOverloadIdx);
		const impl = hasFlag(winner, SymbolFlag.OverloadSig) ? findOverloadImpl(sym) : winner;
		return impl != null && impl.symbolType != null ? impl.symbolType : sym.symbolType;
	}
	const callee = (call.data as CallExprData).callee;
	return callee != null && callee.nodeType != null && callee.nodeType.kind == TypeKind.Function ? callee.nodeType : null;
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
	return hasFlag(sym, SymbolFlag.Global) || hasFlag(sym, SymbolFlag.StaticLocal) || sym.staticOwner != null;
}

// A deep Readonly module const built in its own initializer is never written and lives as long as
// the program, so a borrow of it cannot outlive or race a write.
export function isImmutableModuleConst(sym: Symbol): boolean {
	if (!hasFlag(sym, SymbolFlag.Global) || hasFlag(sym, SymbolFlag.StaticLocal) || hasFlag(sym, SymbolFlag.Mutable)) return false;
	const t = sym.symbolType;
	return sym.symbolKind == SymbolKind.Variable && t != null && t.kind != TypeKind.Ptr && isReadonlyView(t) && builtInPlace(constBindingInitializer(sym));
}

function isConstantValue(sym: Symbol, e: Effect): boolean {
	const t = sym.symbolType;
	if (hasFlag(sym, SymbolFlag.Mutable)) return false;
	if (typeCarriesRef(t)) {
		if (t != null && t.kind == TypeKind.Ptr) return pointsAtConstantState(sym, e);
		return e == Effect.SpawnUnsafe && isReadonlyView(t) && builtInPlace(constBindingInitializer(sym));
	}
	return e == Effect.SpawnUnsafe || !isAtomicRef(t);
}

// No other binding holds a part of a value built from literals, `new` and calls of routines that
// reach no module state, over arguments built the same way; a deep Readonly binding of it is then
// never written.
function builtInPlace(node: Node | null): boolean {
	if (node == null) return false;
	const n = peelConv(node);
	if (n.kind == NodeKind.StringLiteral || !typeCarriesRef(n.nodeType)) return true;
	if (n.kind == NodeKind.ObjectLiteral) return !n.flags.has(NodeFlag.Closure) && allBuiltInPlace((n.data as ObjectLiteralData).properties);
	if (n.kind == NodeKind.ArrayLiteral) return allBuiltInPlace((n.data as ArrayLiteralData).elements);
	if (n.kind == NodeKind.NewExpr) return reachesNoState(n.resolvedSym) && allBuiltInPlace((n.data as NewExprData).newArguments);
	if (n.kind == NodeKind.CallExpr) return reachesNoState(n.resolvedSym) && allBuiltInPlace((n.data as CallExprData).arguments);
	return false;
}

function allBuiltInPlace(nodes: Node[]): boolean {
	for (const n of nodes) {
		if (!builtInPlace(n)) return false;
	}
	return true;
}

function reachesNoState(sym: Symbol | null): boolean {
	return isRoutine(sym) && routineEffect(sym!, Effect.SpawnUnsafe) == null;
}

function pointsAtConstantState(sym: Symbol, e: Effect): boolean {
	const init = constBindingInitializer(sym);
	if (init == null || init.kind != NodeKind.TypeAssertion) return false;
	const target = peelConv((init.data as TypeAssertionData).asExpr);
	const pointee = target.kind == NodeKind.Identifier ? target.resolvedSym : null;
	return pointee != null && pointee != sym && isModuleState(pointee) && isConstantValue(pointee, e);
}

function stateName(sym: Symbol): string {
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
	return { site, text: c.text + ", which " + inner.text };
}

function memo(sym: Symbol, e: Effect, compute: () => EffectCause | null): EffectCause | null {
	const t = tableFor(e);
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
	return memo(sym, e, (): EffectCause | null => walkRoutine(unpackDecl(sym.declNode), e));
}

export function constructionEffect(classSym: Symbol, e: Effect): EffectCause | null {
	return memo(classSym, e, (): EffectCause | null => {
		const decl = unpackDecl(classSym.declNode);
		if (decl == null || decl.kind != NodeKind.ClassDecl) return null;
		for (const m of (decl.data as ClassDeclData).classBody) {
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
		const parent = parentClassSymOf(classSym);
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
	if (e == Effect.Suspends && isSpawnCall(call)) return cause(call, "spawns");
	if (callee != null && callee.resolvedSym != null && callee.resolvedSym.builtinKind == DYNAMIC_IMPORT) {
		return e == Effect.SideEffect ? cause(call, "imports '" + callee.resolvedSym.modulePath + "'") : null;
	}
	const sym = call.resolvedSym;
	if (!isRoutine(sym)) {
		if (isOwnParam(callee)) return null;
		const valueType: Type | null = callee != null ? callee.nodeType : null;
		if (e == Effect.SpawnUnsafe && isSendableFunction(valueType)) return null;
		if (callee != null && callee.kind == NodeKind.Identifier && boundRoutine(callee.resolvedSym) != null) {
			return through(call, "calls '" + (callee.data as IdentifierData).name + "'", boundRoutineEffect(callee.resolvedSym!, e));
		}
		return cause(call, "calls a function value");
	}
	if (hasFlag(sym!, SymbolFlag.GeneratedOp)) return null;
	if (routineBody(unpackDecl(sym!.declNode)) == null) {
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

export function newEffect(newNode: Node, e: Effect): EffectCause | null {
	const classSym = (newNode.data as NewExprData).newCallee.resolvedSym;
	if (classSym == null || classSym.symbolKind != SymbolKind.Class) return null;
	const built = through(newNode, "constructs '" + classSym.name + "'", constructionEffect(classSym, e));
	return built != null ? built : ownedValueHookEffect(newNode, e);
}

function ownedValueHookEffect(site: Node, e: Effect): EffectCause | null {
	if (e != Effect.SpawnUnsafe || hookRegistry == null || site.nodeType == null) return null;
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
	if (e == Effect.Suspends && sym.symbolKind != SymbolKind.Function) return null;
	if (isModuleState(sym)) return isConstantValue(sym, e) ? null : cause(node, "uses " + stateName(sym));
	if (sym.symbolKind == SymbolKind.Function) return through(node, "refers to '" + sym.name + "'", routineEffect(sym, e));
	return null;
}

export function walkEffect(node: Node | null, e: Effect): EffectCause | null {
	if (node == null) return null;
	if (isRoutineNode(node)) return walkNestedRoutine(node, e);
	const here: EffectCause | null = match (node.kind) {
		NodeKind.Identifier | NodeKind.MemberExpr => useEffect(node, e),
		NodeKind.CallExpr => callEffect(node, e),
		NodeKind.NewExpr => newEffect(node, e),
		NodeKind.AwaitExpr => e == Effect.Suspends && !inAsync ? cause(node, "awaits") : null,
		_ => null,
	};
	if (here != null) return here;
	return walkChildren(node, e);
}

function walkChildren(node: Node, e: Effect): EffectCause | null {
	const found: (EffectCause | null)[] = [null];
	forEachChild(node, (child: Node): void => {
		if (found[0] == null) found[0] = walkEffect(child, e);
	});
	return found[0];
}
