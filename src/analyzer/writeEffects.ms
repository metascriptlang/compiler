// A parameter or a cursor is a borrow of a location, so a write to that location frees what
// the borrow still reads. A routine's summary names the locations it may write, closed over
// its callees, the overrides it dispatches to and the lifecycle hooks the values it handles
// run; borrowedArgsToCopy picks the arguments the caller must keep alive, and mayWrite tells
// cursor inference which statements end a borrow.

import { Node, NodeKind, NodeFlag, ObjectLiteralData, Symbol, SymbolKind, SourceLocation, Type, TypeFlag, TypeKind, makeLoc, BinaryExprData, CallExprData, ClassDeclData, ConditionalExprData, ConstructorDeclData, DecoratedDeclData, HiddenDerefData, MemberExprData, MoveExprData, NewExprData, OutExprData, PropertyDeclData, ArrayAccessData, IdentifierData, ProgramData, ExportDeclData, ReturnStmtData, VariableDeclData } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { SymbolFlag, hasFlag, makeSymbol, parentClassSymOf } from "../checker/symbol";
import { CheckerContext, LIFECYCLE_HOOK_NAMES, dispatchEntryFor, dispatchOverridesFor, extReceiverSym, findAllExtensionsByName, nominalTypeSym } from "../checker/context";
import { calledRoutine, isViewCall, routineBody, receiverOf, viewCallSources } from "../checker/effects";
import { lookupInstanceHook, pickBodyCtx } from "../checker/instantiate";
import { isMutatingArrayMethod } from "../checker/paramMutationAnalysis";
import { containsPointer } from "../checker/varPartitions";
import { skipConvDfa } from "./alias";
import { RcInfo, noRcInfo } from "./classify";
import { makeNumber, makeString } from "../checker/literalNodes";
import { classDistance, createArray, createFunction, int32Type, isReadonlyView, stringType, withoutReadonlyView } from "../checker/types";
import { isAssignable, sameType } from "../checker/compat";
import { generatedRef, makeAssign, makeCall, makeIdentResolved } from "../transform/util";
import { cstringSource } from "../transform/native/cstringConvLower";

const ELEMENT_SLOT = "E";
export const ANY_HEAP_SLOT = "*";

enum SummaryKind {
	Routine,
	Construction,
	Hooks,
}

interface Edge {
	call: Node | null;
	callee: WriteSummary;
}

class WriteSummary {
	kind: SummaryKind;
	sym: Symbol | null;
	hooks: Symbol[];
	slots: string[];
	slotSet: HashSet<string>;
	refParamWrites: int32;
	returnsFresh: boolean;
	unknown: boolean;
	edges: Edge[];
	linked: HashSet<WriteSummary>;
	index: int32;
	low: int32;
	onStack: boolean;
	done: boolean;
}

let routineSummaries = new HashMap<Symbol, WriteSummary>();
let viewReturns = new HashMap<Symbol, string[]>();
let viewReturnsUnknown = new HashSet<Symbol>();
let viewReturnsOpen: Symbol[] = [];
let viewReturnsReach: int32 = 0;
let constructionSummaries = new HashMap<Symbol, WriteSummary>();
let hookSummaries = new HashMap<Type, WriteSummary>();
let hookless = new HashSet<Type>();
let ownerHookCache = new HashMap<Symbol, Symbol[]>();
let routineDecls = new HashMap<Symbol, Node>();
let unitRoutines = new HashMap<string, Symbol[]>();
let routineUnits = new HashMap<Symbol, string>();
let reloadableUnits: string[] = [];
let currentUnit = "";
let stack: WriteSummary[] = [];
let nextIndex: int32 = 0;
let checker: CheckerContext | null = null;
let rcOf: (t: Type | null) => RcInfo = (t: Type | null): RcInfo => { throw new Error("internal: write effects read before bindWriteEffects"); };

export function bindWriteEffects(ctx: CheckerContext | null, classify: (t: Type | null) => RcInfo): void {
	checker = ctx;
	rcOf = classify;
}

export function resetWriteEffects(ctx: CheckerContext | null, classify: (t: Type | null) => RcInfo): void {
	clearWriteSummaries();
	bindWriteEffects(ctx, classify);
}

export function noteRoutineDecls(unit: string, program: Node): void {
	currentUnit = unit;
	const previous = unitRoutines.get(unit);
	if (previous != null) {
		for (const sym of previous) {
			routineDecls.delete(sym);
			routineUnits.delete(sym);
		}
	}
	const syms: Symbol[] = [];
	for (const stmt of (program.data as ProgramData).programStmts) {
		let decl = unpackDecl(stmt);
		if (decl != null && decl.kind == NodeKind.ExportDecl) decl = unpackDecl((decl.data as ExportDeclData).exportedDecl);
		if (decl == null || decl.resolvedSym == null || (decl.kind != NodeKind.FunctionDecl && decl.kind != NodeKind.ClassDecl)) continue;
		routineDecls.set(decl.resolvedSym!, decl);
		routineUnits.set(decl.resolvedSym!, unit);
		syms.push(decl.resolvedSym!);
	}
	unitRoutines.set(unit, syms);
}

export function resetRoutineDecls(): void {
	routineDecls = new HashMap<Symbol, Node>();
	unitRoutines = new HashMap<string, Symbol[]>();
	routineUnits = new HashMap<Symbol, string>();
	reloadableUnits = [];
	currentUnit = "";
}

export function noteReloadableUnits(units: string[]): void {
	reloadableUnits = units;
}

function unitOf(s: WriteSummary): string {
	if (s.kind == SummaryKind.Hooks) return "";
	return s.sym != null ? (routineUnits.get(s.sym!) ?? currentUnit) : currentUnit;
}

function reloadsApart(caller: WriteSummary, callee: WriteSummary): boolean {
	if (reloadableUnits.length == 0 || callee.sym == null) return false;
	const unit = routineUnits.get(callee.sym!);
	return unit != null && reloadableUnits.includes(unit) && unit != unitOf(caller);
}

export function clearWriteSummaries(): void {
	ownerHookCache = new HashMap<Symbol, Symbol[]>();
	routineSummaries = new HashMap<Symbol, WriteSummary>();
	viewReturns = new HashMap<Symbol, string[]>();
	viewReturnsUnknown = new HashSet<Symbol>();
	constructionSummaries = new HashMap<Symbol, WriteSummary>();
	hookSummaries = new HashMap<Type, WriteSummary>();
	hookless = new HashSet<Type>();
	stack = [];
	nextIndex = 0;
}

function newSummary(kind: SummaryKind, sym: Symbol | null, hooks: Symbol[]): WriteSummary {
	return {
		kind, sym, hooks, slots: [], slotSet: new HashSet<string>(), refParamWrites: 0, returnsFresh: false, unknown: false,
		edges: [], linked: new HashSet<WriteSummary>(), index: -1, low: -1, onStack: false, done: false,
	};
}

function addSlot(s: WriteSummary, slot: string): boolean {
	if (s.slotSet.has(slot)) return false;
	s.slotSet.add(slot);
	s.slots.push(slot);
	return true;
}

function markUnknown(s: WriteSummary): boolean {
	if (s.unknown) return false;
	s.unknown = true;
	return true;
}

function unpackDecl(decl: Node | null): Node | null {
	if (decl != null && decl.kind == NodeKind.DecoratedDecl) return (decl.data as DecoratedDeclData).decoratedNode;
	return decl;
}

function routineDecl(sym: Symbol): Node | null {
	return routineDecls.get(sym) ?? unpackDecl(sym.declNode);
}

function isRoutineNode(n: Node): boolean {
	return n.kind == NodeKind.FunctionDecl || n.kind == NodeKind.MethodDecl || n.kind == NodeKind.ConstructorDecl
		|| n.kind == NodeKind.ArrowFunction || n.kind == NodeKind.FunctionExpr || n.kind == NodeKind.ClassDecl;
}

function isModuleState(sym: Symbol): boolean {
	return hasFlag(sym, SymbolFlag.Global) || hasFlag(sym, SymbolFlag.StaticLocal);
}

function globalSlot(sym: Symbol): string {
	return `G:${sym.modulePath}|${sym.name}|${sym.disamb}`;
}

function fieldSlot(property: string): string {
	return "F:" + property;
}

// A field or element slot names the type of the object that holds it, because a location can be
// part of another only when its holder's type can be the other's: the same type, a class and its
// ancestor, or arrays whose elements can be. A holder of unknown or generic type keeps the bare
// slot, which every write to that field or element may hit.
const HOLDER_MARK = "@";
const slotHolders: Type[] = [];
const slotHolderIds = new HashMap<Type, int32>();

function holderType(t: Type | null): Type | null {
	let cur = t;
	for (let depth = 0; cur != null && depth < 16; depth += 1) {
		if ((cur.kind == TypeKind.Ref || cur.kind == TypeKind.Var || cur.kind == TypeKind.Sink || cur.kind == TypeKind.Lent
				|| cur.kind == TypeKind.Alias || cur.kind == TypeKind.Distinct) && cur.typeReturn != null) {
			cur = cur.typeReturn;
			continue;
		}
		if (isReadonlyView(cur)) {
			cur = withoutReadonlyView(cur);
			continue;
		}
		return cur.kind == TypeKind.Struct || cur.kind == TypeKind.Array ? cur : null;
	}
	return null;
}

function heldSlot(slot: string, holder: Type | null): string {
	const t = holderType(holder);
	if (t == null) return slot;
	const known = slotHolderIds.get(t);
	if (known != null) return slot + HOLDER_MARK + known;
	const id = slotHolders.length as int32;
	slotHolders.push(t);
	slotHolderIds.set(t, id);
	return slot + HOLDER_MARK + id;
}

function bareSlot(slot: string): string {
	const at = slot.indexOf(HOLDER_MARK);
	return at < 0 ? slot : slot.slice(0, at);
}

function slotHolder(slot: string): Type | null {
	const at = slot.indexOf(HOLDER_MARK);
	return at < 0 ? null : slotHolders[parseInt(slot.slice(at + 1)) as int32];
}

function mayBePartOf(a: Type | null, b: Type | null, depth: int32): boolean {
	if (a == null || b == null || a === b || depth > 8) return true;
	if (a.kind == TypeKind.Array && b.kind == TypeKind.Array) return elementsMayAlias(a.typeReturn, b.typeReturn, depth + 1);
	if (a.kind == TypeKind.Struct && b.kind == TypeKind.Struct) {
		if (isClassType(a) && isClassType(b)) return sameType(a, b) || classDistance(a, b) >= 0 || classDistance(b, a) >= 0;
		return mayHoldEither(a, b);
	}
	return false;
}

// A structural holder can be an object of the other type exactly when one is assignable to the
// other; a class that is extended may hide a subclass that is, and an open type may be anything.
function mayHoldEither(a: Type, b: Type): boolean {
	if (isExtendedClass(a) || isExtendedClass(b) || a.typeFlags.has(TypeFlag.HasGenericParam) || b.typeFlags.has(TypeFlag.HasGenericParam)) return true;
	return isAssignable(a, b) || isAssignable(b, a);
}

function isExtendedClass(t: Type): boolean {
	return isClassType(t) && t.typeFlags.has(TypeFlag.OpenClass);
}

function isClassType(t: Type): boolean {
	return t.sym != null && t.sym.symbolKind == SymbolKind.Class;
}

function elementsMayAlias(a: Type | null, b: Type | null, depth: int32): boolean {
	if (a == null || b == null || a === b) return true;
	if (a.kind == TypeKind.Cursor || b.kind == TypeKind.Cursor) return a.kind == b.kind && elementsMayAlias(a.typeReturn, b.typeReturn, depth + 1);
	const ha = holderType(a);
	const hb = holderType(b);
	if (ha != null && hb != null) return mayBePartOf(ha, hb, depth);
	if (ha != null || hb != null) return isOpenType(ha != null ? b : a);
	return isOpenType(a) || isOpenType(b) || sameType(a, b);
}

function isOpenType(t: Type): boolean {
	return t.kind == TypeKind.GenericParam || t.kind == TypeKind.GenericInstance || t.kind == TypeKind.Unknown || t.kind == TypeKind.Inferred
		|| t.kind == TypeKind.Union || t.kind == TypeKind.TypeReference || t.kind == TypeKind.Error;
}

function slotMayHit(write: string, read: string): boolean {
	if (bareSlot(write) != bareSlot(read)) return false;
	const w = slotHolder(write);
	const r = slotHolder(read);
	return w == null || r == null || mayBePartOf(w, r, 0);
}

function paramIndex(params: Symbol[] | null, sym: Symbol): int32 {
	if (params == null) return -1;
	for (let i = 0; i < params.length; i += 1) {
		if (params[i] === sym) return i as int32;
	}
	return -1;
}

function writeTarget(s: WriteSummary, target: Node | null, params: Symbol[] | null, inCtor: boolean, fresh: HashSet<Symbol> | null): boolean {
	if (target == null) return false;
	const t = skipConvDfa(target);
	match (t.kind) {
		NodeKind.Identifier => {
			const sym = t.resolvedSym;
			if (sym == null) return false;
			if (isModuleState(sym)) return addSlot(s, globalSlot(sym));
			const k = paramIndex(params, sym);
			if (sym.symbolType == null || sym.symbolType.kind != TypeKind.Var) return false;
			if (k < 0) return false;
			if (k >= 31) return markUnknown(s);
			if ((s.refParamWrites & (1 << k)) != 0) return false;
			s.refParamWrites = s.refParamWrites | (1 << k);
			return true;
		},
		NodeKind.MemberExpr => {
			const md = t.data as MemberExprData;
			if ((inCtor && isThis(md.object)) || freshBase(md.object, fresh)) return false;
			const field = addSlot(s, heldSlot(fieldSlot(md.property), md.object.nodeType));
			const elements = md.property == "length" && addSlot(s, heldSlot(ELEMENT_SLOT, md.object.nodeType));
			return field || elements;
		},
		NodeKind.ArrayAccess => { return !freshBase((t.data as ArrayAccessData).array, fresh) && addSlot(s, heldSlot(ELEMENT_SLOT, (t.data as ArrayAccessData).array.nodeType)); },
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => { return writeTarget(s, (t.data as HiddenDerefData).expr, params, inCtor, fresh); },
		_ => {
			let changed = isGeneratedProc(t.resolvedSym) && addSlot(s, ELEMENT_SLOT);
			forEachChild(t, (child: Node): void => { if (writeTarget(s, child, params, inCtor, fresh)) changed = true; });
			return changed;
		},
	};
}

function isRoutineSym(sym: Symbol | null): boolean {
	return sym != null && (sym.symbolKind == SymbolKind.Function || sym.symbolKind == SymbolKind.Method);
}

function mayBeFunctionValue(t: Type | null): boolean {
	return t != null && (t.kind == TypeKind.Function || t.kind == TypeKind.Unknown || t.kind == TypeKind.GenericParam);
}

function passesFunctionValue(call: Node): boolean {
	for (const a of (call.data as CallExprData).arguments) {
		if (a != null && mayBeFunctionValue(a.nodeType)) return true;
	}
	return false;
}

function hasKnownSignature(sym: Symbol): boolean {
	const t = sym.symbolType;
	return t != null && t.kind == TypeKind.Function;
}

function isGeneratedProc(sym: Symbol | null): boolean {
	return sym != null && sym.symbolType == null && sym.declNode == null && hasFlag(sym, SymbolFlag.ImportC);
}

function runsNativeOnC(sym: Symbol): boolean {
	return hasFlag(sym, SymbolFlag.ImportC) || routineBody(routineDecl(sym)) == null;
}

function elementWrite(s: WriteSummary, base: Node, stores: Node[] | null): void {
	if (stores != null) stores.push(base);
	else addSlot(s, heldSlot(ELEMENT_SLOT, base.nodeType));
}

function nativeEffect(s: WriteSummary, call: Node, sym: Symbol, stores: Node[] | null, argsLinked: boolean): void {
	if (isGeneratedProc(sym)) {
		if (!argsLinked && passesFunctionValue(call)) markUnknown(s);
		return;
	}
	const recv = receiverOf(call);
	for (const a of (call.data as CallExprData).arguments) {
		if (a != null && isArrayStorage(a.nodeType)) elementWrite(s, a, stores);
	}
	if (recv != null && !hasFlag(sym, SymbolFlag.ImportC)) {
		const name = sym.name;
		if (isMutatingArrayMethod(name) || name == "set" || name == "delete" || name == "clear" || name == "add") elementWrite(s, recv, stores);
		return;
	}
	if (sym.symbolKind == SymbolKind.Method && !hasFlag(sym, SymbolFlag.NativeMethod)) {
		markUnknown(s);
		return;
	}
	if (!hasKnownSignature(sym) || (!argsLinked && passesFunctionValue(call))) markUnknown(s);
}

// A lifecycle op the analyzer inserted writes its first argument: the destination of a copy
// or a sink, the value a destroy frees or a move leaves empty.
function isLifecycleOp(call: Node): boolean {
	const sym = call.resolvedSym;
	if (sym == null) return false;
	if (hasFlag(sym, SymbolFlag.GeneratedOp) || hasFlag(sym, SymbolFlag.DestroyOp) || hasFlag(sym, SymbolFlag.WasMovedOp)) return true;
	const args = (call.data as CallExprData).arguments;
	if (args.length == 0 || args[0] == null) return false;
	const dest = args[0].kind == NodeKind.HiddenAddr ? (args[0].data as HiddenDerefData).expr : args[0];
	const rc = rcOf(dest.nodeType);
	return sym === rc.sinkFn || sym === rc.copyFn;
}

function constructionsOf(n: Node): WriteSummary[] {
	const out: WriteSummary[] = [];
	const cls = (n.data as NewExprData).newCallee.resolvedSym;
	if (cls != null && cls.symbolKind == SymbolKind.Class) out.push(constructionSummary(cls));
	const init = n.resolvedSym;
	if (init != null && hasFlag(init, SymbolFlag.ClassInit)) out.push(routineSummary(init));
	return out;
}

function calleesOf(call: Node, s: WriteSummary, stores: Node[] | null, own: OwnCalls | null): WriteSummary[] {
	const sym = call.resolvedSym;
	if (!isRoutineSym(sym)) {
		const callee = (call.data as CallExprData).callee;
		if (callee != null && callee.kind == NodeKind.Identifier && (callee.data as IdentifierData).name == "super") {
			const cls = sym != null && sym.symbolKind == SymbolKind.Class ? sym : null;
			return cls != null ? [constructionSummary(cls)] : [];
		}
		if (own != null && sym != null && paramIndex(own.params, sym) >= 0) {
			own.called.push(sym);
			return [];
		}
		markUnknown(s);
		return [];
	}
	const out: WriteSummary[] = [];
	if (runsNativeOnC(sym!)) nativeEffect(s, call, sym!, stores, own != null);
	else out.push(routineSummary(sym!));
	const entry = dispatchEntryFor(sym!);
	if (entry != null) {
		if (entry.overloaded) markUnknown(s);
		else for (const o of dispatchOverridesFor(entry.classSym, entry.methodName)) out.push(routineSummary(o.sym));
	}
	return out;
}

function addHook(out: Symbol[], hook: Symbol): void {
	if (!out.includes(hook)) out.push(hook);
}

function hookRoutines(t: Type, seen: HashSet<Type>, out: Symbol[]): void {
	if (seen.has(t) || hookless.has(t)) return;
	seen.add(t);
	const finished = hookSummaries.get(t);
	if (finished != null) {
		for (const h of finished.hooks) addHook(out, h);
		return;
	}
	match (t.kind) {
		TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64 | TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Uint64
			| TypeKind.Float32 | TypeKind.Float64 | TypeKind.Boolean | TypeKind.String | TypeKind.Void | TypeKind.Function => { return; },
		_ => {},
	};
	for (const name of LIFECYCLE_HOOK_NAMES) {
		const hook = lookupInstanceHook(t, name);
		if (hook != null) addHook(out, hook);
	}
	let owner = t.kind == TypeKind.Struct ? nominalTypeSym(t) : null;
	while (owner != null) {
		for (const h of ownerHooks(owner)) addHook(out, h);
		owner = owner.symbolKind == SymbolKind.Class ? parentClassSymOf(owner) : null;
	}
	for (const c of t.typeChildren) { if (c != null) hookRoutines(c, seen, out); }
	if (t.typeReturn != null) hookRoutines(t.typeReturn, seen, out);
	if (t.typeExtra != null) hookRoutines(t.typeExtra, seen, out);
}

function ownerHooks(owner: Symbol): Symbol[] {
	const known = ownerHookCache.get(owner);
	if (known != null) return known;
	const out: Symbol[] = [];
	const registry = checker != null ? pickBodyCtx(owner.modulePath, checker!).extensionRegistry : null;
	if (registry != null) {
		for (const name of LIFECYCLE_HOOK_NAMES) {
			for (const ext of findAllExtensionsByName(registry, name)) {
				if (!ext.isStatic && ext.sym != null && extReceiverSym(ext) == owner) out.push(ext.sym);
			}
		}
	}
	ownerHookCache.set(owner, out);
	return out;
}

function hookSummary(t: Type): WriteSummary | null {
	if (hookless.has(t)) return null;
	const known = hookSummaries.get(t);
	if (known != null) return known;
	const hooks: Symbol[] = [];
	hookRoutines(t, new HashSet<Type>(), hooks);
	if (hooks.length == 0) {
		hookless.add(t);
		return null;
	}
	const s = newSummary(SummaryKind.Hooks, null, hooks);
	hookSummaries.set(t, s);
	return s;
}

// A field or element write is resolved after the walk, once the callees' summaries say which
// calls return a new object: a write into an object this call allocated frees nothing a
// caller borrowed before the call.
function walkBody(s: WriteSummary, body: Node | null, params: Symbol[] | null, inCtor: boolean): HashSet<Symbol> | null {
	if (body == null) return null;
	const targets: Node[] = [];
	const stores: Node[] = [];
	const fnArgs: Node[] = [];
	const own: OwnCalls = { params, called: [] };
	const passFunctions = (args: Node[]): void => {
		for (const a of args) {
			if (a != null && mayBeFunctionValue(a.nodeType)) fnArgs.push(a);
		}
	};
	const step = (n: Node): void => {
		if (isRoutineNode(n)) return;
		if (n.nodeType != null) {
			const hooks = hookSummary(n.nodeType);
			if (hooks != null && hooks !== s && !s.linked.has(hooks)) {
				s.linked.add(hooks);
				link(s, null, hooks);
			}
		}
		match (n.kind) {
			NodeKind.BinaryExpr => {
				const bd = n.data as BinaryExprData;
				if (isAssign(bd.operator)) targets.push(bd.left);
			},
			NodeKind.CallExpr => {
				const args = (n.data as CallExprData).arguments;
				if (isLifecycleOp(n)) {
					targets.push(args[0]);
				} else {
					for (const a of args) {
						if (a == null || a.kind != NodeKind.HiddenAddr) continue;
						targets.push(a);
						const inner = (a.data as HiddenDerefData).expr;
						if (isArrayStorage(inner.nodeType)) stores.push(inner);
					}
					passFunctions(args);
					for (const c of calleesOf(n, s, stores, own)) link(s, n, c);
				}
			},
			NodeKind.NewExpr => {
				passFunctions((n.data as NewExprData).newArguments);
				for (const c of constructionsOf(n)) link(s, null, c);
			},
			_ => {},
		};
		forEachChild(n, step);
	};
	step(body);
	const d = localDefs(body);
	const assigned = assignedParams(targets, params);
	for (const p of own.called) {
		if (assigned.has(p)) markUnknown(s);
	}
	for (const a of fnArgs) linkFunctionValue(s, a, params, assigned, d);
	const fresh = freshLocals(s, d);
	for (const t of targets) writeTarget(s, t, params, inCtor, fresh);
	for (const b of stores) {
		if (!freshBase(b, fresh)) addSlot(s, heldSlot(ELEMENT_SLOT, b.nodeType));
	}
	return fresh;
}

class OwnCalls {
	params: Symbol[] | null;
	called: Symbol[];
}

function assignedParams(targets: Node[], params: Symbol[] | null): HashSet<Symbol> {
	const out = new HashSet<Symbol>();
	for (const t of targets) {
		const b = baseLocal(t);
		if (b.kind == NodeKind.Identifier && b.resolvedSym != null && paramIndex(params, b.resolvedSym!) >= 0) out.add(b.resolvedSym!);
	}
	return out;
}

function closureRoutine(n: Node): Node | null {
	if (n.kind != NodeKind.ObjectLiteral || !n.flags.has(NodeFlag.Closure)) return null;
	const od = n.data as ObjectLiteralData;
	const k = od.keys.indexOf("fn");
	return k >= 0 ? od.properties[k] : null;
}

function routinesOf(value: Node, params: Symbol[] | null, assigned: HashSet<Symbol> | null, d: LocalDefs | null, depth: int32, out: WriteSummary[]): boolean {
	const t = skipConvDfa(value);
	if (t.kind == NodeKind.NullLiteral) return true;
	const fn = closureRoutine(t);
	if (fn != null) return routinesOf(fn, params, assigned, d, depth, out);
	const sym = t.kind == NodeKind.Identifier ? t.resolvedSym : null;
	if (sym == null) return false;
	if (isRoutineSym(sym) && !runsNativeOnC(sym)) {
		out.push(routineSummary(sym));
		return true;
	}
	if (assigned != null && paramIndex(params, sym) >= 0 && !assigned.has(sym)) return true;
	if (d == null || depth >= 8 || !isLocal(sym) || d.spoiled.has(sym)) return false;
	const k = d.syms.indexOf(sym);
	if (k < 0) return false;
	for (const src of d.sources[k]) {
		if (!routinesOf(src, params, assigned, d, depth + 1, out)) return false;
	}
	return true;
}

function linkFunctionValue(s: WriteSummary, value: Node, params: Symbol[] | null, assigned: HashSet<Symbol>, d: LocalDefs): void {
	const out: WriteSummary[] = [];
	if (!routinesOf(value, params, assigned, d, 0, out)) {
		markUnknown(s);
		return;
	}
	for (const callee of out) {
		if (callee !== s) link(s, null, callee);
	}
}

function isLocal(sym: Symbol | null): boolean {
	return sym != null && (sym.symbolKind == SymbolKind.Variable || sym.symbolKind == SymbolKind.Temp) && !isModuleState(sym);
}

function baseLocal(n: Node): Node {
	let t = skipConvDfa(n);
	while (t.kind == NodeKind.HiddenDeref || t.kind == NodeKind.HiddenAddr) t = skipConvDfa((t.data as HiddenDerefData).expr);
	return t;
}

function freshBase(n: Node, fresh: HashSet<Symbol> | null): boolean {
	if (fresh == null) return false;
	const t = baseLocal(n);
	return t.kind == NodeKind.Identifier && t.resolvedSym != null && fresh.has(t.resolvedSym!);
}

class LocalDefs {
	syms: Symbol[];
	sources: Node[][];
	spoiled: HashSet<Symbol>;
}

function addDef(d: LocalDefs, target: Node | null, source: Node): void {
	if (target == null) return;
	const t = skipConvDfa(target);
	const sym = t.kind == NodeKind.Identifier || t.kind == NodeKind.VariableDecl ? t.resolvedSym : null;
	if (!isLocal(sym)) return;
	let k = d.syms.indexOf(sym!);
	if (k < 0) {
		d.syms.push(sym!);
		d.sources.push([]);
		k = d.syms.length - 1;
	}
	d.sources[k].push(source);
}

function spoilLocal(d: LocalDefs, n: Node | null): void {
	if (n == null) return;
	const t = baseLocal(n);
	if (t.kind == NodeKind.Identifier && isLocal(t.resolvedSym)) d.spoiled.add(t.resolvedSym!);
}

// A local a nested routine names, a local passed by address and a local given a compound
// assignment can change behind the definitions this walk sees, so none of them is fresh.
function collectDefs(d: LocalDefs, n: Node, nested: boolean): void {
	if (nested || isRoutineNode(n)) {
		if (n.kind == NodeKind.Identifier) spoilLocal(d, n);
		forEachChild(n, (c: Node): void => { collectDefs(d, c, true); });
		return;
	}
	match (n.kind) {
		NodeKind.VariableDecl => {
			const init = (n.data as VariableDeclData).initializer;
			if (init != null) addDef(d, n, init);
		},
		NodeKind.BinaryExpr => {
			const bd = n.data as BinaryExprData;
			if (bd.operator == "=") addDef(d, bd.left, bd.right);
			else if (isAssign(bd.operator)) spoilLocal(d, bd.left);
		},
		NodeKind.CallExpr => {
			const args = (n.data as CallExprData).arguments;
			if (isLifecycleOp(n) && args.length > 0 && args[0] != null && args[0].kind == NodeKind.HiddenAddr) {
				if (args.length > 1 && args[1] != null) addDef(d, (args[0].data as HiddenDerefData).expr, args[1]);
				for (let i = 1; i < args.length; i += 1) {
					if (args[i] != null) collectDefs(d, args[i], false);
				}
				return;
			}
		},
		NodeKind.HiddenAddr => spoilLocal(d, n),
		NodeKind.OutExpr => spoilLocal(d, (n.data as OutExprData).outArg),
		_ => {},
	};
	forEachChild(n, (c: Node): void => { collectDefs(d, c, false); });
}

function returnsNewObject(s: WriteSummary, call: Node): boolean {
	const sym = call.resolvedSym;
	if (!isRoutineSym(sym) || runsNativeOnC(sym!) || dispatchEntryFor(sym!) != null) return false;
	const callee = routineSummaries.get(sym!);
	return callee != null && callee.done && callee.returnsFresh && !reloadsApart(s, callee);
}

function isFreshExpr(s: WriteSummary, e: Node | null, fresh: HashSet<Symbol>): boolean {
	if (e == null) return false;
	const t = skipConvDfa(e);
	match (t.kind) {
		NodeKind.NewExpr | NodeKind.ObjectLiteral | NodeKind.ArrayLiteral | NodeKind.NullLiteral => { return true; },
		NodeKind.Identifier => { return t.resolvedSym != null && fresh.has(t.resolvedSym!); },
		NodeKind.ConditionalExpr => {
			const cd = t.data as ConditionalExprData;
			return isFreshExpr(s, cd.ternaryConsequent, fresh) && isFreshExpr(s, cd.ternaryAlternate, fresh);
		},
		NodeKind.MoveExpr => { return isFreshExpr(s, (t.data as MoveExprData).moveArg, fresh); },
		NodeKind.CallExpr => { return returnsNewObject(s, t); },
		_ => { return false; },
	};
}

// A local is fresh when every value it is given is an object allocated during this call:
// a construction, a literal, a call that returns a new object, or another fresh local.
function localDefs(body: Node): LocalDefs {
	const d: LocalDefs = { syms: [], sources: [], spoiled: new HashSet<Symbol>() };
	collectDefs(d, body, false);
	return d;
}

function freshLocals(s: WriteSummary, d: LocalDefs): HashSet<Symbol> {
	const fresh = new HashSet<Symbol>();
	for (const sym of d.syms) {
		if (!d.spoiled.has(sym)) fresh.add(sym);
	}
	let changed = true;
	while (changed) {
		changed = false;
		for (let k = 0; k < d.syms.length; k += 1) {
			if (!fresh.has(d.syms[k])) continue;
			for (const src of d.sources[k]) {
				if (!isFreshExpr(s, src, fresh)) {
					fresh.delete(d.syms[k]);
					changed = true;
					break;
				}
			}
		}
	}
	return fresh;
}

function returnsFreshObject(s: WriteSummary, body: Node, fresh: HashSet<Symbol>): boolean {
	let sawFresh = false;
	let allFresh = true;
	const step = (n: Node): void => {
		if (!allFresh || isRoutineNode(n)) return;
		if (n.kind == NodeKind.ReturnStmt) {
			const arg = (n.data as ReturnStmtData).argument;
			if (arg != null && containsPointer(arg.nodeType, 0)) {
				if (isFreshExpr(s, arg, fresh)) sawFresh = true;
				else allFresh = false;
			}
		}
		forEachChild(n, step);
	};
	step(body);
	return sawFresh && allFresh;
}

function addressWrites(s: WriteSummary, args: Node[], params: Symbol[] | null, inCtor: boolean): void {
	for (const a of args) {
		if (a == null || a.kind != NodeKind.HiddenAddr) continue;
		writeTarget(s, a, params, inCtor, null);
		if (isArrayStorage((a.data as HiddenDerefData).expr.nodeType)) addSlot(s, heldSlot(ELEMENT_SLOT, (a.data as HiddenDerefData).expr.nodeType));
	}
}

function isThis(n: Node): boolean {
	let t = skipConvDfa(n);
	if (t.kind == NodeKind.HiddenDeref) t = skipConvDfa((t.data as HiddenDerefData).expr);
	return t.kind == NodeKind.Identifier && (t.data as IdentifierData).name == "this";
}

function isArrayStorage(t: Type | null): boolean {
	let at = t;
	while (at != null && (at.kind == TypeKind.Var || at.kind == TypeKind.Ref || at.kind == TypeKind.Ptr) && at.typeReturn != null) at = at.typeReturn;
	return at != null && at.kind == TypeKind.Array;
}

function isAssign(op: string): boolean {
	if (op == "==" || op == "!=" || op == "===" || op == "!==" || op == "<=" || op == ">=") return false;
	return op.endsWith("=");
}

function link(s: WriteSummary, call: Node | null, callee: WriteSummary): void {
	if (reloadsApart(s, callee)) {
		markUnknown(s);
		return;
	}
	s.edges.push({ call, callee });
	if (callee.index < 0) {
		visit(callee);
		if (callee.low < s.low) s.low = callee.low;
	} else if (callee.onStack && callee.index < s.low) {
		s.low = callee.index;
	}
}

function walkSummary(s: WriteSummary): void {
	match (s.kind) {
		SummaryKind.Routine => {
			const decl = routineDecl(s.sym!);
			const body = routineBody(decl);
			const fresh = walkBody(s, body, decl != null ? decl.paramSyms : null, (decl != null && decl.kind == NodeKind.ConstructorDecl) || hasFlag(s.sym!, SymbolFlag.ClassInit));
			if (body != null && fresh != null) s.returnsFresh = returnsFreshObject(s, body, fresh);
		},
		SummaryKind.Construction => {
			const decl = routineDecl(s.sym!);
			if (decl == null || decl.kind != NodeKind.ClassDecl) return;
			for (const m of (decl.data as ClassDeclData).classBody) {
				const member = unpackDecl(m);
				if (member == null) continue;
				if (member.kind == NodeKind.PropertyDecl && !(member.data as PropertyDeclData).propIsStatic) {
					walkBody(s, (member.data as PropertyDeclData).propInitializer, null, true);
				} else if (member.kind == NodeKind.ConstructorDecl) {
					walkBody(s, (member.data as ConstructorDeclData).ctorBody, member.paramSyms, true);
				}
			}
			const parent = parentClassSymOf(s.sym!);
			if (parent != null) link(s, null, constructionSummary(parent));
		},
		SummaryKind.Hooks => {
			for (const h of s.hooks) {
				if (routineBody(routineDecl(h)) != null) link(s, null, routineSummary(h));
			}
		},
	};
}

// Tarjan: a routine's summary is final once its strongly connected component is, and the
// members of a recursive component share writes until none changes.
function visit(s: WriteSummary): void {
	s.index = nextIndex;
	s.low = nextIndex;
	nextIndex += 1;
	stack.push(s);
	s.onStack = true;
	walkSummary(s);
	if (s.low != s.index) return;
	const members: WriteSummary[] = [];
	let m: WriteSummary;
	do {
		m = stack.pop()!;
		m.onStack = false;
		members.push(m);
	} while (m !== s);
	let changed = true;
	while (changed) {
		changed = false;
		for (const member of members) {
			for (const e of member.edges) {
				if (absorb(member, e)) changed = true;
			}
		}
	}
	for (const member of members) member.done = true;
}

function absorb(s: WriteSummary, e: Edge): boolean {
	const c = e.callee;
	let changed = false;
	if (c.unknown && markUnknown(s)) changed = true;
	for (const slot of c.slots) {
		if (addSlot(s, slot)) changed = true;
	}
	if (e.call != null && c.refParamWrites != 0 && s.kind == SummaryKind.Routine) {
		const decl = routineDecl(s.sym!);
		const params = decl != null ? decl.paramSyms : null;
		const args = (e.call.data as CallExprData).arguments;
		for (let i = 0; i < args.length && i < 31; i += 1) {
			if ((c.refParamWrites & (1 << i)) != 0 && writeTarget(s, args[i], params, false, null)) changed = true;
		}
	}
	return changed;
}

function routineSummary(sym: Symbol): WriteSummary {
	const known = routineSummaries.get(sym);
	if (known != null) return known;
	const s = newSummary(SummaryKind.Routine, sym, []);
	routineSummaries.set(sym, s);
	return s;
}

function constructionSummary(cls: Symbol): WriteSummary {
	const known = constructionSummaries.get(cls);
	if (known != null) return known;
	const s = newSummary(SummaryKind.Construction, cls, []);
	constructionSummaries.set(cls, s);
	return s;
}

function settled(s: WriteSummary): WriteSummary {
	if (s.index < 0) visit(s);
	return s;
}

function callWrites(call: Node): WriteSummary {
	const s = newSummary(SummaryKind.Routine, null, []);
	if (call.kind == NodeKind.CallExpr && isLifecycleOp(call)) return s;
	if (call.kind == NodeKind.CallExpr) addressWrites(s, (call.data as CallExprData).arguments, null, false);
	const callees = call.kind == NodeKind.NewExpr ? constructionsOf(call) : calleesOf(call, s, null, null);
	for (const a of call.kind == NodeKind.NewExpr ? (call.data as NewExprData).newArguments : (call.data as CallExprData).arguments) {
		if (a != null && mayBeFunctionValue(a.nodeType) && !routinesOf(a, null, null, null, 0, callees)) markUnknown(s);
	}
	for (const c of callees) {
		if (reloadsApart(s, c)) markUnknown(s);
		else absorb(s, { call: null, callee: settled(c) });
	}
	return s;
}

// The slots a view call's result is reached through below its arguments: the steps every
// return of the callee takes from a parameter or a Readonly module constant, closed over the
// view calls it returns through. Null when a return is not such a path or the callee's body
// is unknown, so the caller keeps treating the result as reachable from any heap slot.
export function viewReturnSlots(call: Node): string[] | null {
	const sym = calledRoutine(call);
	if (sym == null || runsNativeOnC(sym) || dispatchEntryFor(sym) != null) return null;
	return routineReturnSlots(sym);
}

function routineReturnSlots(sym: Symbol): string[] | null {
	const known = viewReturns.get(sym);
	if (known != null) return known;
	if (viewReturnsUnknown.has(sym)) return null;
	const open = viewReturnsOpen.indexOf(sym);
	if (open >= 0) {
		if (open < viewReturnsReach) viewReturnsReach = open as int32;
		return [];
	}
	const decl = routineDecl(sym);
	const body = routineBody(decl);
	if (decl == null || body == null) return null;
	const depth = viewReturnsOpen.length as int32;
	const outerReach = viewReturnsReach;
	viewReturnsReach = depth;
	viewReturnsOpen.push(sym);
	const out: string[] = [];
	const ok = returnArmsSlots(body, decl.paramSyms, localDefs(body), out);
	viewReturnsOpen.pop();
	if (viewReturnsReach >= depth) {
		if (ok) viewReturns.set(sym, out);
		else viewReturnsUnknown.add(sym);
	}
	viewReturnsReach = viewReturnsReach < outerReach ? viewReturnsReach : outerReach;
	return ok ? out : null;
}

function returnArmsSlots(n: Node, params: Symbol[] | null, d: LocalDefs, out: string[]): boolean {
	if (isRoutineNode(n)) return true;
	if (n.kind == NodeKind.ReturnStmt) {
		const arg = (n.data as ReturnStmtData).argument;
		return arg == null || pathFromParams(arg, params, d, new HashSet<Symbol>(), out);
	}
	let ok = true;
	forEachChild(n, (c: Node): void => { if (ok && !returnArmsSlots(c, params, d, out)) ok = false; });
	return ok;
}

function pathFromParams(n: Node, params: Symbol[] | null, d: LocalDefs, seen: HashSet<Symbol>, out: string[]): boolean {
	const t = skipConvDfa(n);
	match (t.kind) {
		NodeKind.NullLiteral => { return true; },
		NodeKind.ConditionalExpr => {
			const cd = t.data as ConditionalExprData;
			return pathFromParams(cd.ternaryConsequent, params, d, seen, out) && pathFromParams(cd.ternaryAlternate, params, d, seen, out);
		},
		NodeKind.BinaryExpr => {
			const bd = t.data as BinaryExprData;
			return bd.operator == "??" && pathFromParams(bd.left, params, d, seen, out) && pathFromParams(bd.right, params, d, seen, out);
		},
		NodeKind.MemberExpr => {
			out.push(stepSlot(t)!);
			return pathFromParams((t.data as MemberExprData).object, params, d, seen, out);
		},
		NodeKind.ArrayAccess => {
			out.push(stepSlot(t)!);
			return pathFromParams((t.data as ArrayAccessData).array, params, d, seen, out);
		},
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => { return pathFromParams((t.data as HiddenDerefData).expr, params, d, seen, out); },
		NodeKind.MoveExpr => { return pathFromParams((t.data as MoveExprData).moveArg, params, d, seen, out); },
		NodeKind.CallExpr => {
			if (!isViewCall(t)) return false;
			const inner = viewReturnSlots(t);
			if (inner == null) return false;
			for (const slot of inner) out.push(slot);
			const sources: Node[] = [];
			viewCallSources(t, sources);
			for (const a of sources) {
				if (containsPointer(a.nodeType, 0) && !pathFromParams(a, params, d, seen, out)) return false;
			}
			return true;
		},
		NodeKind.Identifier => {
			const sym = t.resolvedSym;
			if (sym == null) return (t.data as IdentifierData).name == "this";
			if (paramIndex(params, sym) >= 0 || (t.data as IdentifierData).name == "this") return true;
			if (isModuleState(sym)) {
				out.push(globalSlot(sym));
				return true;
			}
			if (!isLocal(sym) || d.spoiled.has(sym)) return false;
			if (seen.has(sym)) return true;
			seen.add(sym);
			const k = d.syms.indexOf(sym);
			if (k < 0) return false;
			for (const src of d.sources[k]) {
				if (!pathFromParams(src, params, d, seen, out)) return false;
			}
			return true;
		},
		_ => { return false; },
	};
}

export function stepSlot(n: Node): string | null {
	match (n.kind) {
		NodeKind.Identifier => { return n.resolvedSym != null && isModuleState(n.resolvedSym!) ? globalSlot(n.resolvedSym!) : null; },
		NodeKind.MemberExpr => { return heldSlot(fieldSlot((n.data as MemberExprData).property), (n.data as MemberExprData).object.nodeType); },
		NodeKind.ArrayAccess => { return heldSlot(ELEMENT_SLOT, (n.data as ArrayAccessData).array.nodeType); },
		_ => { return null; },
	};
}

export function mayWrite(n: Node, slots: string[]): boolean {
	if (n.kind != NodeKind.BinaryExpr) return mayWriteAny(callWrites(n), slots);
	if (!isAssign((n.data as BinaryExprData).operator)) return false;
	const writes = newSummary(SummaryKind.Routine, null, []);
	const target = (n.data as BinaryExprData).left;
	writeTarget(writes, target, null, false, null);
	const hooks = target.nodeType != null ? hookSummary(target.nodeType!) : null;
	if (hooks != null) absorb(writes, { call: null, callee: settled(hooks) });
	return mayWriteAny(writes, slots);
}

function mayWriteAny(writes: WriteSummary, slots: string[]): boolean {
	if (writes.unknown) return true;
	for (const slot of slots) {
		if (slot == ANY_HEAP_SLOT ? writes.slots.length > 0 : writes.slotSet.has(slot)) return true;
		if (slot == ANY_HEAP_SLOT) continue;
		for (const w of writes.slots) {
			if (slotMayHit(w, slot)) return true;
		}
	}
	return false;
}

function pathSlots(n: Node, out: string[]): Symbol | null {
	const t = skipConvDfa(n);
	match (t.kind) {
		NodeKind.Identifier => {
			const sym = t.resolvedSym;
			if (sym != null && isModuleState(sym)) out.push(globalSlot(sym));
			return sym;
		},
		NodeKind.MemberExpr => {
			const md = t.data as MemberExprData;
			const root = pathSlots(md.object, out);
			out.push(heldSlot(fieldSlot(md.property), md.object.nodeType));
			return root;
		},
		NodeKind.ArrayAccess => {
			const root = pathSlots((t.data as ArrayAccessData).array, out);
			out.push(heldSlot(ELEMENT_SLOT, (t.data as ArrayAccessData).array.nodeType));
			return root;
		},
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => { return pathSlots((t.data as HiddenDerefData).expr, out); },
		_ => { return null; },
	};
}

export function borrowedArgsToCopy(call: Node): boolean[] {
	const args = (call.data as CallExprData).arguments;
	const flags: boolean[] = [];
	const roots: (Symbol | null)[] = [];
	const slots: string[][] = [];
	const byAddress: boolean[] = [];
	const receiverByAddress = call.resolvedSym != null && call.resolvedSym!.nativeName.startsWith("&");
	let any = false;
	for (const a of args) {
		byAddress.push(a != null && (a.kind == NodeKind.HiddenAddr || (byAddress.length == 0 && receiverByAddress)));
		const s: string[] = [];
		const source = cstringSource(a);
		roots.push(a != null ? pathSlots(source ?? a, s) : null);
		slots.push(s);
		if (source != null) {
			flags.push(s.length > 0);
			continue;
		}
		const borrowed = a != null && !byAddress[byAddress.length - 1] && rcOf(a.nodeType).needsCleanup;
		flags.push(borrowed);
		if (borrowed) any = true;
	}
	if (!any) return flags;
	const writes = callWrites(call);
	for (let i = 0; i < args.length; i += 1) {
		if (!flags[i] || cstringSource(args[i]) != null) continue;
		let keep = false;
		for (let j = 0; j < args.length && !keep; j += 1) {
			if (j != i && byAddress[j] && roots[i] != null && roots[j] === roots[i]) keep = true;
		}
		if (!keep && slots[i].length > 0) keep = mayWriteAny(writes, slots[i]);
		flags[i] = keep;
	}
	return flags;
}

function writeProbe(): SourceLocation {
	resetWriteEffects(null, (t: Type | null): RcInfo => noRcInfo());
	return makeLoc(0, 0);
}

function localOf(name: string, t: Type, loc: SourceLocation): Node {
	return makeIdentResolved(makeSymbol(name, SymbolKind.Variable, t, false), loc);
}

function elementRead(loc: SourceLocation): Node {
	return makeCall(generatedRef("msArrayAccess", loc), [localOf("arr", createArray(stringType()), loc), makeNumber(0, loc)], loc);
}

test "an element read through a generated access macro writes nothing" {
	const loc = writeProbe();
	assert !mayWrite(elementRead(loc), [ELEMENT_SLOT]);
}

test "a store through a generated access macro writes the elements" {
	const loc = writeProbe();
	assert mayWrite(makeAssign(elementRead(loc), makeString("s", loc), loc), [ELEMENT_SLOT]);
}

test "a union projection through a generated macro writes nothing" {
	const loc = writeProbe();
	const read = makeCall(generatedRef("msVariantAccessVal", loc), [localOf("u", int32Type(), loc), makeNumber(0, loc), makeString("a", loc), makeString("a|b", loc)], loc);
	assert !mayWrite(read, [ELEMENT_SLOT, fieldSlot("a")]);
}

test "a generated macro handed a function value may write anything" {
	const loc = writeProbe();
	const callback = localOf("cb", createFunction([], [], int32Type()), loc);
	assert mayWrite(makeCall(generatedRef("msSpanAccess", loc), [callback, makeNumber(0, loc)], loc), [fieldSlot("a")]);
}
