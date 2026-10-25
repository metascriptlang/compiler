// A parameter or a cursor is a borrow of a location, so a write to that location frees what
// the borrow still reads. A routine's summary names the locations it may write, closed over
// its callees, the overrides it dispatches to and the lifecycle hooks the values it handles
// run; borrowedArgsToCopy picks the arguments the caller must keep alive, and mayWrite tells
// cursor inference which statements end a borrow.

import { Node, NodeKind, NodeFlag, ObjectLiteralData, Symbol, SymbolKind, SourceLocation, Type, TypeFlag, TypeKind, makeLoc, BinaryExprData, CallExprData, ClassDeclData, ConditionalExprData, ConstructorDeclData, DecoratedDeclData, HiddenDerefData, MemberExprData, MoveExprData, NewExprData, OutExprData, PropertyDeclData, ArrayAccessData, IdentifierData, ProgramData, ExportDeclData, ReturnStmtData, VariableDeclData } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { SymbolFlag, findOverloadImpl, hasFlag, makeSymbol, parentClassSymOf } from "../checker/symbol";
import { CheckerContext, LIFECYCLE_HOOK_NAMES, dispatchEntryFor, dispatchOverridesFor, extReceiverSym, findAllExtensionsByName, lifecycleHookOp, nominalTypeSym } from "../checker/context";
import { calledRoutine, isViewCall, routineBody, receiverOf, viewCallSources } from "../checker/effects";
import { lookupInstanceHook, pickBodyCtx } from "../checker/instantiate";
import { isMutatingArrayMethod } from "../checker/paramMutationAnalysis";
import { containsPointer } from "../checker/varPartitions";
import { skipConvDfa } from "./alias";
import { RcInfo, RcKind, noRcInfo } from "./classify";
import { returnsBorrow } from "../codegen/c/types";
import { makeNumber, makeString } from "../checker/literalNodes";
import { classDistance, createArray, createFunction, int32Type, isReadonlyView, isSendableFunction, stringType, withoutReadonlyView } from "../checker/types";
import { isAssignable, sameType } from "../checker/compat";
import { generatedRef, isRuntimeProcSym, makeAssign, makeBlock, makeCall, makeFnDecl, makeIdentResolved, makeReturn } from "../transform/util";
import { cstringSource } from "../transform/native/cstringConvLower";

const ELEMENT_SLOT = "E";
// An append moves the elements a value borrow copied out, so it can only strand a borrow that
// holds an element's address; such a borrow reads APPEND_SLOT besides ELEMENT_SLOT.
export const APPEND_SLOT = "+E";
export const ANY_HEAP_SLOT = "*";

enum SummaryKind {
	Routine,
	Construction,
	Hooks,
	Closure,
	Contract,
}

interface Edge {
	call: Node | null;
	callee: Cursor<WriteSummary>;
}

class WriteSummary {
	kind: SummaryKind;
	sym: Symbol | null;
	literal: Node | null;
	hooks: Symbol[];
	slots: string[];
	slotSet: HashSet<string>;
	refParamWrites: int32;
	returnsFresh: boolean;
	unknown: boolean;
	edges: Edge[];
	forwards: Symbol[];
	linked: HashSet<Cursor<WriteSummary>>;
	index: int32;
	low: int32;
	onStack: boolean;
	done: boolean;
}

export interface RoutineDecls {
	decls: HashMap<Symbol, Node>;
	unitRoutines: HashMap<string, Symbol[]>;
	routineUnits: HashMap<Symbol, string>;
}

export function createRoutineDecls(): RoutineDecls {
	return { decls: new HashMap<Symbol, Node>(), unitRoutines: new HashMap<string, Symbol[]>(), routineUnits: new HashMap<Symbol, string>() };
}

export interface WriteSummaries {
	routineDecls: RoutineDecls;
	reloadableUnits: string[];
	routineSummaries: HashMap<Symbol, WriteSummary>;
	closureSummaries: HashMap<Node, WriteSummary>;
	retainedParams: HashMap<Symbol, int32>;
	constructionSummaries: HashMap<Symbol, WriteSummary>;
	hookSummaries: HashMap<Type, WriteSummary>;
	hookless: HashSet<Type>;
	ownerHookCache: HashMap<Symbol, Symbol[]>;
	viewReturns: HashMap<Symbol, string[]>;
	viewReturnsUnknown: HashSet<Symbol>;
	viewReturnsOpen: Symbol[];
	viewReturnsReach: int32;
	slotHolders: Type[];
	slotHolderIds: HashMap<Type, int32>;
	stack: WriteSummary[];
	nextIndex: int32;
	contracts: HashMap<Symbol, CallbackContract>;
	cloneContracts: HashMap<Symbol, CallbackContract>;
	unitContracts: CallbackContract[];
	reusedClones: HashMap<Symbol, Symbol>;
	lending: Lending;
}

export function createWriteSummaries(routineDecls: RoutineDecls, reloadableUnits: string[]): WriteSummaries {
	return {
		routineDecls, reloadableUnits,
		routineSummaries: new HashMap<Symbol, WriteSummary>(), closureSummaries: new HashMap<Node, WriteSummary>(), retainedParams: new HashMap<Symbol, int32>(), constructionSummaries: new HashMap<Symbol, WriteSummary>(),
		hookSummaries: new HashMap<Type, WriteSummary>(), hookless: new HashSet<Type>(), ownerHookCache: new HashMap<Symbol, Symbol[]>(),
		viewReturns: new HashMap<Symbol, string[]>(), viewReturnsUnknown: new HashSet<Symbol>(), viewReturnsOpen: [], viewReturnsReach: 0,
		slotHolders: [], slotHolderIds: new HashMap<Type, int32>(), stack: [], nextIndex: 0,
		contracts: new HashMap<Symbol, CallbackContract>(), cloneContracts: new HashMap<Symbol, CallbackContract>(), unitContracts: [],
		reusedClones: new HashMap<Symbol, Symbol>(), lending: { callbacks: [], contract: null, held: null },
	};
}

export interface WriteEffects {
	tables: WriteSummaries;
	checker: CheckerContext | null;
	unit: string;
	rcOf: (t: Type | null) => RcInfo;
	aliasMemo: HashMap<Type, HashMap<Type, int32>>;
}

export function noteRoutineDecls(w: WriteEffects, program: Node): void {
	const decls = w.tables.routineDecls;
	const previous = decls.unitRoutines.get(w.unit);
	if (previous != null) {
		for (const sym of previous) {
			decls.decls.delete(sym);
			decls.routineUnits.delete(sym);
		}
	}
	const syms: Symbol[] = [];
	for (const stmt of (program.data as ProgramData).programStmts) {
		let decl = unpackDecl(stmt);
		if (decl != null && decl.kind == NodeKind.ExportDecl) decl = unpackDecl((decl.data as ExportDeclData).exportedDecl);
		if (decl == null || decl.resolvedSym == null || (decl.kind != NodeKind.FunctionDecl && decl.kind != NodeKind.ClassDecl)) continue;
		decls.decls.set(decl.resolvedSym!, decl);
		decls.routineUnits.set(decl.resolvedSym!, w.unit);
		syms.push(decl.resolvedSym!);
	}
	decls.unitRoutines.set(w.unit, syms);
}

function unitOf(w: WriteEffects, s: WriteSummary): string {
	if (s.kind == SummaryKind.Hooks) return "";
	return s.sym != null ? (w.tables.routineDecls.routineUnits.get(s.sym!) ?? w.unit) : w.unit;
}

function reloadsApart(w: WriteEffects, caller: WriteSummary, callee: WriteSummary): boolean {
	if (w.tables.reloadableUnits.length == 0 || callee.sym == null) return false;
	const unit = w.tables.routineDecls.routineUnits.get(callee.sym!);
	return unit != null && w.tables.reloadableUnits.includes(unit) && unit != unitOf(w, caller);
}

function newSummary(kind: SummaryKind, sym: Symbol | null, hooks: Symbol[]): WriteSummary {
	return {
		kind, sym, literal: null, hooks, slots: [], slotSet: new HashSet<string>(), refParamWrites: 0, returnsFresh: false, unknown: false,
		edges: [], forwards: [], linked: new HashSet<Cursor<WriteSummary>>(), index: -1, low: -1, onStack: false, done: false,
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

function routineDecl(w: WriteEffects, sym: Symbol): Node | null {
	return w.tables.routineDecls.decls.get(sym) ?? unpackDecl(sym.declNode);
}

function summaryDecl(w: WriteEffects, s: WriteSummary): Node | null {
	return s.kind == SummaryKind.Closure ? s.literal : routineDecl(w, s.sym!);
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
		if (cur.kind == TypeKind.GenericInstance && (cur.typeReturn ?? cur.typeExtra) != null) {
			cur = cur.typeReturn ?? cur.typeExtra;
			continue;
		}
		return cur.kind == TypeKind.Struct || cur.kind == TypeKind.Array ? cur : null;
	}
	return null;
}

function heldSlot(w: WriteEffects, slot: string, holder: Type | null): string {
	const t = holderType(holder);
	if (t == null) return slot;
	const known = w.tables.slotHolderIds.get(t);
	if (known != null) return slot + HOLDER_MARK + known;
	const id = w.tables.slotHolders.length as int32;
	w.tables.slotHolders.push(t);
	w.tables.slotHolderIds.set(t, id);
	return slot + HOLDER_MARK + id;
}

function bareSlot(slot: string): string {
	const at = slot.indexOf(HOLDER_MARK);
	return at < 0 ? slot : slot.slice(0, at);
}

function slotHolder(w: WriteEffects, slot: string): Type | null {
	const at = slot.indexOf(HOLDER_MARK);
	return at < 0 ? null : w.tables.slotHolders[parseInt(slot.slice(at + 1)) as int32];
}

function mayBePartOf(a: Type | null, b: Type | null, depth: int32): boolean {
	if (a == null || b == null || a === b || depth > 8) return true;
	if (a.kind == TypeKind.Array && b.kind == TypeKind.Array) return elementsMayAlias(a.typeReturn, b.typeReturn, depth + 1);
	if (a.kind == TypeKind.Struct && b.kind == TypeKind.Struct) {
		if (isClassType(a) && isClassType(b)) return a.sym === b.sym || sameType(a, b) || classDistance(a, b) >= 0 || classDistance(b, a) >= 0;
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

export function canAlias(w: WriteEffects, arg: Type | null, ret: Type | null): boolean {
	if (arg == null || ret == null) return true;
	let byRet = new HashMap<Type, int32>();
	const known = w.aliasMemo.get(arg);
	if (known != null) byRet = known;
	else w.aliasMemo.set(arg, byRet);
	const hit = byRet.get(ret);
	if (hit != null) return hit == 1;
	const result = canAliasIn(arg, ret, new HashSet<Type>());
	byRet.set(ret, result ? 1 : 0);
	return result;
}

function canAliasIn(arg: Type | null, ret: Type | null, seen: HashSet<Type>): boolean {
	if (arg == null || ret == null) return true;
	if (seen.has(ret)) return false;
	seen.add(ret);
	if (ret.kind == TypeKind.Ptr) return false;
	const a = holderType(arg);
	if (a == null) return containsPointer(arg, 0);
	const r = holderType(ret);
	if (r != null && mayBePartOf(a, r, 0)) return true;
	const t = r ?? ret;
	match (t.kind) {
		TypeKind.Struct => {
			if (isExtendedClass(t) || t.typeFlags.has(TypeFlag.HasGenericParam)) return true;
			for (const field of t.typeChildren) {
				if (canAliasIn(arg, field, seen)) return true;
			}
			return t.typeExtra != null && canAliasIn(arg, t.typeExtra, seen);
		},
		TypeKind.Array | TypeKind.SizedArray | TypeKind.Span | TypeKind.Borrow | TypeKind.Cursor => { return canAliasIn(arg, t.typeReturn, seen); },
		TypeKind.Union | TypeKind.Tuple => {
			for (const member of t.typeChildren) {
				if (canAliasIn(arg, member, seen)) return true;
			}
			return false;
		},
		TypeKind.GenericInstance => { return t.typeReturn == null || canAliasIn(arg, t.typeReturn, seen); },
		TypeKind.Function | TypeKind.GenericParam | TypeKind.Unknown | TypeKind.Inferred | TypeKind.TypeReference | TypeKind.Error => { return true; },
		_ => { return false; },
	};
}

function slotMayHit(w: WriteEffects, write: string, read: string): boolean {
	if (bareSlot(write) != bareSlot(read)) return false;
	const writtenHolder = slotHolder(w, write);
	const readHolder = slotHolder(w, read);
	return writtenHolder == null || readHolder == null || mayBePartOf(writtenHolder, readHolder, 0);
}

function paramIndex(params: Symbol[] | null, sym: Symbol): int32 {
	if (params == null) return -1;
	for (let i = 0; i < params.length; i += 1) {
		if (params[i] === sym) return i as int32;
	}
	return -1;
}

function writeTarget(w: WriteEffects, s: WriteSummary, target: Node | null, params: Symbol[] | null, inCtor: boolean, fresh: HashSet<Symbol> | null): boolean {
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
			const field = !freesNothing(w, t.nodeType) && addSlot(s, heldSlot(w, fieldSlot(md.property), md.object.nodeType));
			const elements = md.property == "length" && addSlot(s, heldSlot(w, ELEMENT_SLOT, md.object.nodeType));
			return field || elements;
		},
		NodeKind.ArrayAccess => { return !freshBase((t.data as ArrayAccessData).array, fresh) && !freesNothing(w, t.nodeType) && addSlot(s, heldSlot(w, ELEMENT_SLOT, (t.data as ArrayAccessData).array.nodeType)); },
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => { return writeTarget(w, s, (t.data as HiddenDerefData).expr, params, inCtor, fresh); },
		_ => {
			let changed = isGeneratedProc(t.resolvedSym) && loweredElementWrite(w, s, t);
			forEachChild(t, (child: Node): void => { if (writeTarget(w, s, child, params, inCtor, fresh)) changed = true; });
			return changed;
		},
	};
}

const LOWERED_ELEMENT_READS = ["msArrayAccess", "msArrayAccessUnchecked", "msRefArrayAccess", "msRefArrayAccessUnchecked", "msSizedArrayAccess",
	"msSizedArrayAccessUnchecked", "msSpanAccess", "msSpanAccessUnchecked", "msNumberArrayAccess", "msStringArrayAccess", "msUint8ArrayAccess"];
const LOWERED_INLINE_READS = ["msVariantAccess", "msVariantAccessVal", "msVariantObject", "msVariantObjectVal", "msMaybeVariantObject", "msMaybeAccess", "msMaybeAccessVal"];

function loweredAccessStep(call: Node): string | null {
	const sym = call.resolvedSym;
	if (sym == null || (call.data as CallExprData).arguments.length == 0) return null;
	if (!isGeneratedProc(sym) && !hasFlag(sym, SymbolFlag.CompilerProc)) return null;
	if (LOWERED_ELEMENT_READS.includes(sym.name)) return ELEMENT_SLOT;
	return LOWERED_INLINE_READS.includes(sym.name) ? "" : null;
}

function loweredElementWrite(w: WriteEffects, s: WriteSummary, access: Node): boolean {
	const args = access.kind == NodeKind.CallExpr ? (access.data as CallExprData).arguments : [];
	if (args.length == 0) return addSlot(s, ELEMENT_SLOT);
	return !freesNothing(w, access.nodeType) && addSlot(s, heldSlot(w, ELEMENT_SLOT, args[0].nodeType));
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

function runsNativeOnC(w: WriteEffects, sym: Symbol): boolean {
	return hasFlag(sym, SymbolFlag.ImportC) || routineBody(routineDecl(w, sym)) == null;
}

function elementWrite(w: WriteEffects, s: WriteSummary, base: Node, stores: Node[] | null): void {
	if (freesNothing(w, arrayElementType(base.nodeType))) return;
	if (stores != null) stores.push(base);
	else addSlot(s, heldSlot(w, ELEMENT_SLOT, base.nodeType));
}

function isAppend(name: string): boolean {
	return name == "push" || name == "unshift" || name == "append";
}

// A slot whose value needs no cleanup frees nothing when it is overwritten or removed.
function freesNothing(w: WriteEffects, t: Type | null): boolean {
	if (t == null || t.typeFlags.has(TypeFlag.HasGenericParam)) return false;
	if (t.kind == TypeKind.GenericParam || t.kind == TypeKind.Unknown || t.kind == TypeKind.Inferred || t.kind == TypeKind.TypeReference || t.kind == TypeKind.Error) return false;
	return !w.rcOf(t).needsCleanup;
}

// A slot list read through an element's address: the borrow also reads what an append moves.
export function addressSlots(slots: string[]): string[] {
	const out: string[] = [];
	for (const slot of slots) {
		out.push(slot);
		if (bareSlot(slot) == ELEMENT_SLOT) out.push(APPEND_SLOT + slot.slice(ELEMENT_SLOT.length));
	}
	return out;
}

function arrayElementType(t: Type | null): Type | null {
	let at = t;
	while (at != null && (at.kind == TypeKind.Var || at.kind == TypeKind.Ref || at.kind == TypeKind.Ptr) && at.typeReturn != null) at = at.typeReturn;
	return at != null && at.kind == TypeKind.Array ? at.typeReturn : null;
}

function nativeEffect(w: WriteEffects, s: WriteSummary, call: Node, sym: Symbol, stores: Node[] | null, argsLinked: boolean): void {
	if (isGeneratedProc(sym)) {
		if (!argsLinked && passesFunctionValue(call)) markUnknown(s);
		return;
	}
	const recv = receiverOf(call);
	const args = (call.data as CallExprData).arguments;
	for (let i = 0; i < args.length; i += 1) {
		if (args[i] == null || !isArrayStorage(args[i].nodeType)) continue;
		if (i == 0 && appendsTo(call)) addSlot(s, heldSlot(w, APPEND_SLOT, args[i].nodeType));
		else elementWrite(w, s, args[i], stores);
	}
	if (recv != null && !hasFlag(sym, SymbolFlag.ImportC)) {
		const name = sym.name;
		if (isAppend(name) && isArrayStorage(recv.nodeType)) addSlot(s, heldSlot(w, APPEND_SLOT, recv.nodeType));
		else if (isMutatingArrayMethod(name) || name == "set" || name == "delete" || name == "clear" || name == "add") elementWrite(w, s, recv, stores);
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
function isLifecycleOp(w: WriteEffects, call: Node): boolean {
	const sym = call.resolvedSym;
	if (sym == null) return false;
	if (hasFlag(sym, SymbolFlag.GeneratedOp) || hasFlag(sym, SymbolFlag.DestroyOp) || hasFlag(sym, SymbolFlag.WasMovedOp)) return true;
	const args = (call.data as CallExprData).arguments;
	if (args.length == 0 || args[0] == null) return false;
	const dest = args[0].kind == NodeKind.HiddenAddr ? (args[0].data as HiddenDerefData).expr : args[0];
	const rc = w.rcOf(dest.nodeType);
	return sym === rc.sinkFn || sym === rc.copyFn;
}

function constructionsOf(w: WriteEffects, n: Node): WriteSummary[] {
	const out: WriteSummary[] = [];
	const cls = (n.data as NewExprData).newCallee.resolvedSym;
	if (cls != null && cls.symbolKind == SymbolKind.Class) out.push(constructionSummary(w, cls));
	const init = n.resolvedSym;
	if (init != null && hasFlag(init, SymbolFlag.ClassInit)) out.push(routineSummary(w, init));
	return out;
}

function calleesOf(w: WriteEffects, call: Node, s: WriteSummary, stores: Node[] | null, own: OwnCalls | null, defs: LocalDefs | null): WriteSummary[] {
	const sym = call.resolvedSym;
	if (!isRoutineSym(sym)) {
		const callee = (call.data as CallExprData).callee;
		if (callee != null && callee.kind == NodeKind.Identifier && (callee.data as IdentifierData).name == "super") {
			const cls = sym != null && sym.symbolKind == SymbolKind.Class ? sym : null;
			return cls != null ? [constructionSummary(w, cls)] : [];
		}
		if (own != null && sym != null && paramIndex(own.params, sym) >= 0) {
			own.called.push(sym);
			return [];
		}
		if (own == null && sym != null && w.tables.lending.callbacks.includes(sym)) return [];
		const known: WriteSummary[] = [];
		if (defs != null && callee != null && routinesOf(w, callee, null, null, defs, 0, known)) return known;
		if (callee == null || !sendableWritesNothingHeld(callee.nodeType)) markUnknown(s);
		return [];
	}
	const out: WriteSummary[] = [];
	if (runsNativeOnC(w, sym!)) nativeEffect(w, s, call, sym!, stores, own != null);
	else out.push(routineSummary(w, sym!));
	const entry = dispatchEntryFor(sym!);
	if (entry != null) {
		if (entry.overloaded) markUnknown(s);
		else for (const o of dispatchOverridesFor(entry.classSym, entry.methodName)) out.push(routineSummary(w, o.sym));
	}
	return out;
}

function sendableWritesNothingHeld(t: Type | null): boolean {
	if (!isSendableFunction(t)) return false;
	for (const p of t!.typeChildren) {
		if (!isReadonlyView(p) && containsPointer(p, 0)) return false;
	}
	return true;
}

function addHook(out: Symbol[], hook: Symbol): void {
	if (!out.includes(hook)) out.push(hook);
}

function hookRoutines(w: WriteEffects, t: Type, seen: HashSet<Type>, out: Symbol[]): void {
	if (seen.has(t) || w.tables.hookless.has(t)) return;
	seen.add(t);
	const finished = w.tables.hookSummaries.get(t);
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
		const hook = lookupInstanceHook(t, lifecycleHookOp(name));
		if (hook != null) addHook(out, hook);
	}
	let owner = t.kind == TypeKind.Struct ? nominalTypeSym(t) : null;
	while (owner != null) {
		for (const h of ownerHooks(w, owner)) addHook(out, h);
		owner = owner.symbolKind == SymbolKind.Class ? parentClassSymOf(owner) : null;
	}
	for (const c of t.typeChildren) { if (c != null) hookRoutines(w, c, seen, out); }
	if (t.typeReturn != null) hookRoutines(w, t.typeReturn, seen, out);
	if (t.typeExtra != null) hookRoutines(w, t.typeExtra, seen, out);
}

function ownerHooks(w: WriteEffects, owner: Symbol): Symbol[] {
	const known = w.tables.ownerHookCache.get(owner);
	if (known != null) return known;
	const out: Symbol[] = [];
	const registry = w.checker != null ? pickBodyCtx(owner.modulePath, w.checker!).extensionRegistry : null;
	if (registry != null) {
		for (const name of LIFECYCLE_HOOK_NAMES) {
			for (const ext of findAllExtensionsByName(registry, name)) {
				if (!ext.isStatic && ext.sym != null && extReceiverSym(ext) == owner) out.push(ext.sym);
			}
		}
	}
	w.tables.ownerHookCache.set(owner, out);
	return out;
}

function hookSummary(w: WriteEffects, t: Type): WriteSummary | null {
	if (w.tables.hookless.has(t)) return null;
	const known = w.tables.hookSummaries.get(t);
	if (known != null) return known;
	const hooks: Symbol[] = [];
	hookRoutines(w, t, new HashSet<Type>(), hooks);
	if (hooks.length == 0) {
		w.tables.hookless.add(t);
		return null;
	}
	const s = newSummary(SummaryKind.Hooks, null, hooks);
	w.tables.hookSummaries.set(t, s);
	return s;
}

// A field or element write is resolved after the walk, once the callees' summaries say which
// calls return a new object: a write into an object this call allocated frees nothing a
// caller borrowed before the call.
function walkBody(w: WriteEffects, s: WriteSummary, body: Node | null, params: Symbol[] | null, inCtor: boolean): HashSet<Symbol> | null {
	if (body == null) return null;
	const targets: Node[] = [];
	const stores: Node[] = [];
	const fnArgs: Node[] = [];
	const own: OwnCalls = { params, called: [] };
	const d = localDefs(w, body);
	const passFunctions = (args: Node[]): void => {
		for (const a of args) {
			if (a != null && mayBeFunctionValue(a.nodeType)) fnArgs.push(a);
		}
	};
	const step = (n: Node): void => {
		if (isRoutineNode(n)) return;
		if (n.nodeType != null) {
			const hooks = hookSummary(w, n.nodeType);
			if (hooks != null && hooks !== s && !s.linked.has(hooks)) {
				s.linked.add(hooks);
				link(w, s, null, hooks);
			}
		}
		match (n.kind) {
			NodeKind.BinaryExpr => {
				const bd = n.data as BinaryExprData;
				if (isAssign(bd.operator)) targets.push(bd.left);
			},
			NodeKind.CallExpr => {
				const args = (n.data as CallExprData).arguments;
				if (isLifecycleOp(w, n)) {
					targets.push(args[0]);
				} else {
					for (let i = 0; i < args.length; i += 1) {
						const a = args[i];
						if (a == null || a.kind != NodeKind.HiddenAddr) continue;
						targets.push(a);
						const inner = (a.data as HiddenDerefData).expr;
						if (!isArrayStorage(inner.nodeType)) continue;
						if (i == 0 && appendsTo(n)) addSlot(s, heldSlot(w, APPEND_SLOT, inner.nodeType));
						else stores.push(inner);
					}
					passFunctions(args);
					for (const c of calleesOf(w, n, s, stores, own, d)) link(w, s, n, c);
				}
			},
			NodeKind.NewExpr => {
				passFunctions((n.data as NewExprData).newArguments);
				for (const c of constructionsOf(w, n)) link(w, s, null, c);
			},
			_ => {},
		};
		forEachChild(n, step);
	};
	step(body);
	const assigned = assignedParams(targets, params);
	for (const p of own.called) {
		if (assigned.has(p)) markUnknown(s);
	}
	for (const a of fnArgs) linkFunctionValue(w, s, a, params, assigned, d);
	const fresh = freshLocals(w, s, d);
	for (const t of targets) writeTarget(w, s, t, params, inCtor, fresh);
	for (const b of stores) {
		if (!freshBase(b, fresh) && !freesNothing(w, arrayElementType(b.nodeType))) addSlot(s, heldSlot(w, ELEMENT_SLOT, b.nodeType));
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

function routinesOf(w: WriteEffects, value: Node, params: Symbol[] | null, assigned: HashSet<Symbol> | null, d: LocalDefs | null, depth: int32, out: WriteSummary[]): boolean {
	const t = skipConvDfa(value);
	if (t.kind == NodeKind.NullLiteral) return true;
	const fn = closureRoutine(t);
	if (fn != null) return routinesOf(w, fn, params, assigned, d, depth, out);
	if (t.kind == NodeKind.ArrowFunction || t.kind == NodeKind.FunctionExpr) {
		out.push(closureSummary(w, t));
		return true;
	}
	const sym = t.kind == NodeKind.Identifier ? t.resolvedSym : null;
	if (sym == null) return false;
	if (isRoutineSym(sym) && !runsNativeOnC(w, sym)) {
		out.push(routineSummary(w, sym));
		return true;
	}
	if (assigned != null && paramIndex(params, sym) >= 0 && !assigned.has(sym)) return true;
	if (d == null || depth >= 8 || !isLocal(sym) || d.spoiled.has(sym)) return false;
	const k = d.index.get(sym) ?? -1;
	if (k < 0) return false;
	for (const src of d.sources[k]) {
		if (!routinesOf(w, src, params, assigned, d, depth + 1, out)) return false;
	}
	return true;
}

function linkFunctionValue(w: WriteEffects, s: WriteSummary, value: Node, params: Symbol[] | null, assigned: HashSet<Symbol>, d: LocalDefs): void {
	const out: WriteSummary[] = [];
	if (!routinesOf(w, value, params, assigned, d, 0, out)) {
		markUnknown(s);
		return;
	}
	for (const callee of out) {
		if (callee !== s) link(w, s, null, callee);
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

export class LocalDefs {
	syms: Symbol[];
	index: HashMap<Symbol, int32>;
	sources: Node[][];
	spoiled: HashSet<Symbol>;
}

function addDef(d: LocalDefs, target: Node | null, source: Node): void {
	if (target == null) return;
	const t = skipConvDfa(target);
	const sym = t.kind == NodeKind.Identifier || t.kind == NodeKind.VariableDecl ? t.resolvedSym : null;
	if (!isLocal(sym)) return;
	let k: int32 = d.index.get(sym!) ?? -1;
	if (k < 0) {
		d.syms.push(sym!);
		d.sources.push([]);
		k = (d.syms.length - 1) as int32;
		d.index.set(sym!, k);
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
function collectDefs(w: WriteEffects, d: LocalDefs, n: Node, nested: boolean): void {
	if (nested || isRoutineNode(n)) {
		if (n.kind == NodeKind.Identifier) spoilLocal(d, n);
		forEachChild(n, (c: Node): void => { collectDefs(w, d, c, true); });
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
			if (isLifecycleOp(w, n) && args.length > 0 && args[0] != null && args[0].kind == NodeKind.HiddenAddr) {
				if (args.length > 1 && args[1] != null) addDef(d, (args[0].data as HiddenDerefData).expr, args[1]);
				for (let i = 1; i < args.length; i += 1) {
					if (args[i] != null) collectDefs(w, d, args[i], false);
				}
				return;
			}
		},
		NodeKind.HiddenAddr => spoilLocal(d, n),
		NodeKind.OutExpr => spoilLocal(d, (n.data as OutExprData).outArg),
		_ => {},
	};
	forEachChild(n, (c: Node): void => { collectDefs(w, d, c, false); });
}

function returnsNewObject(w: WriteEffects, s: WriteSummary, call: Node): boolean {
	const sym = call.resolvedSym;
	if (!isRoutineSym(sym) || runsNativeOnC(w, sym!) || dispatchEntryFor(sym!) != null) return false;
	const callee = w.tables.routineSummaries.get(sym!);
	return callee != null && callee.done && callee.returnsFresh && !reloadsApart(w, s, callee);
}

function isFreshExpr(w: WriteEffects, s: WriteSummary, e: Node | null, fresh: HashSet<Symbol>): boolean {
	if (e == null) return false;
	const t = skipConvDfa(e);
	match (t.kind) {
		NodeKind.NewExpr | NodeKind.ObjectLiteral | NodeKind.ArrayLiteral | NodeKind.NullLiteral => { return true; },
		NodeKind.Identifier => { return t.resolvedSym != null && fresh.has(t.resolvedSym!); },
		NodeKind.ConditionalExpr => {
			const cd = t.data as ConditionalExprData;
			return isFreshExpr(w, s, cd.ternaryConsequent, fresh) && isFreshExpr(w, s, cd.ternaryAlternate, fresh);
		},
		NodeKind.MoveExpr => { return isFreshExpr(w, s, (t.data as MoveExprData).moveArg, fresh); },
		NodeKind.CallExpr => { return returnsNewObject(w, s, t); },
		_ => { return false; },
	};
}

// A local is fresh when every value it is given is an object allocated during this call:
// a construction, a literal, a call that returns a new object, or another fresh local.
function localDefs(w: WriteEffects, body: Node): LocalDefs {
	const d: LocalDefs = { syms: [], index: new HashMap<Symbol, int32>(), sources: [], spoiled: new HashSet<Symbol>() };
	collectDefs(w, d, body, false);
	return d;
}

function freshLocals(w: WriteEffects, s: WriteSummary, d: LocalDefs): HashSet<Symbol> {
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
				if (!isFreshExpr(w, s, src, fresh)) {
					fresh.delete(d.syms[k]);
					changed = true;
					break;
				}
			}
		}
	}
	return fresh;
}

function returnsFreshObject(w: WriteEffects, s: WriteSummary, body: Node, fresh: HashSet<Symbol>): boolean {
	let sawFresh = false;
	let allFresh = true;
	const step = (n: Node): void => {
		if (!allFresh || isRoutineNode(n)) return;
		if (n.kind == NodeKind.ReturnStmt) {
			const arg = (n.data as ReturnStmtData).argument;
			if (arg != null && containsPointer(arg.nodeType, 0)) {
				if (isFreshExpr(w, s, arg, fresh)) sawFresh = true;
				else allFresh = false;
			}
		}
		forEachChild(n, step);
	};
	step(body);
	return sawFresh && allFresh;
}

function addressWrites(w: WriteEffects, s: WriteSummary, call: Node, params: Symbol[] | null, inCtor: boolean): void {
	const args = (call.data as CallExprData).arguments;
	for (let i = 0; i < args.length; i += 1) {
		const a = args[i];
		if (a == null || a.kind != NodeKind.HiddenAddr) continue;
		writeTarget(w, s, a, params, inCtor, null);
		const storage = (a.data as HiddenDerefData).expr.nodeType;
		if (isArrayStorage(storage)) addSlot(s, heldSlot(w, i == 0 && appendsTo(call) ? APPEND_SLOT : ELEMENT_SLOT, storage));
	}
}

// The runtime's array push grows the storage in place and leaves every element it held alive.
function appendsTo(call: Node): boolean {
	const sym = call.resolvedSym;
	return sym != null && sym.nativeName.startsWith("&ms") && sym.nativeName.endsWith("ArrayPush");
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

export function isAssign(op: string): boolean {
	if (op == "==" || op == "!=" || op == "===" || op == "!==" || op == "<=" || op == ">=") return false;
	return op.endsWith("=");
}

function link(w: WriteEffects, s: WriteSummary, call: Node | null, callee: WriteSummary): void {
	if (reloadsApart(w, s, callee)) {
		markUnknown(s);
		return;
	}
	s.edges.push({ call, callee });
	if (callee.index < 0) {
		visit(w, callee);
		if (callee.low < s.low) s.low = callee.low;
	} else if (callee.onStack && callee.index < s.low) {
		s.low = callee.index;
	}
}

function walkSummary(w: WriteEffects, s: WriteSummary): void {
	match (s.kind) {
		SummaryKind.Routine | SummaryKind.Closure => {
			const decl = summaryDecl(w, s);
			const body = routineBody(decl);
			const fresh = walkBody(w, s, body, decl != null ? decl.paramSyms : null, (decl != null && decl.kind == NodeKind.ConstructorDecl) || (s.sym != null && hasFlag(s.sym!, SymbolFlag.ClassInit)));
			if (body != null && fresh != null) s.returnsFresh = returnsFreshObject(w, s, body, fresh);
		},
		SummaryKind.Construction => {
			const decl = routineDecl(w, s.sym!);
			if (decl == null || decl.kind != NodeKind.ClassDecl) return;
			for (const m of (decl.data as ClassDeclData).classBody) {
				const member = unpackDecl(m);
				if (member == null) continue;
				if (member.kind == NodeKind.PropertyDecl && !(member.data as PropertyDeclData).propIsStatic) {
					walkBody(w, s, (member.data as PropertyDeclData).propInitializer, null, true);
				} else if (member.kind == NodeKind.ConstructorDecl) {
					walkBody(w, s, (member.data as ConstructorDeclData).ctorBody, member.paramSyms, true);
				}
			}
			const parent = parentClassSymOf(s.sym!);
			if (parent != null) link(w, s, null, constructionSummary(w, parent));
		},
		SummaryKind.Hooks => {
			for (const h of s.hooks) {
				if (routineBody(routineDecl(w, h)) != null) link(w, s, null, routineSummary(w, h));
			}
		},
		SummaryKind.Contract => {
			for (const target of s.forwards) {
				const c = w.tables.contracts.get(target);
				if (c != null && c.reads !== s) link(w, s, null, c.reads);
			}
		},
	};
}

// Tarjan: a routine's summary is final once its strongly connected component is, and the
// members of a recursive component share writes until none changes.
function visit(w: WriteEffects, s: WriteSummary): void {
	s.index = w.tables.nextIndex;
	s.low = w.tables.nextIndex;
	w.tables.nextIndex += 1;
	w.tables.stack.push(s);
	s.onStack = true;
	walkSummary(w, s);
	if (s.low != s.index) return;
	const members: WriteSummary[] = [];
	let m: WriteSummary;
	do {
		m = w.tables.stack.pop()!;
		m.onStack = false;
		members.push(m);
	} while (m !== s);
	let changed = true;
	while (changed) {
		changed = false;
		for (const member of members) {
			for (const e of member.edges) {
				if (absorb(w, member, e)) changed = true;
			}
		}
	}
	for (const member of members) member.done = true;
}

function absorb(w: WriteEffects, s: WriteSummary, e: Edge): boolean {
	const c = e.callee;
	let changed = false;
	if (c.unknown && markUnknown(s)) changed = true;
	for (const slot of c.slots) {
		if (addSlot(s, slot)) changed = true;
	}
	if (e.call != null && c.refParamWrites != 0 && (s.kind == SummaryKind.Routine || s.kind == SummaryKind.Closure)) {
		const decl = summaryDecl(w, s);
		const params = decl != null ? decl.paramSyms : null;
		const args = (e.call.data as CallExprData).arguments;
		for (let i = 0; i < args.length && i < 31; i += 1) {
			if ((c.refParamWrites & (1 << i)) != 0 && writeTarget(w, s, args[i], params, false, null)) changed = true;
		}
	}
	return changed;
}

function routineSummary(w: WriteEffects, sym: Symbol): WriteSummary {
	const known = w.tables.routineSummaries.get(sym);
	if (known != null) return known;
	const s = newSummary(SummaryKind.Routine, sym, []);
	w.tables.routineSummaries.set(sym, s);
	return s;
}

function closureSummary(w: WriteEffects, literal: Node): WriteSummary {
	const known = w.tables.closureSummaries.get(literal);
	if (known != null) return known;
	const s = newSummary(SummaryKind.Closure, null, []);
	s.literal = literal;
	w.tables.closureSummaries.set(literal, s);
	return s;
}

function constructionSummary(w: WriteEffects, cls: Symbol): WriteSummary {
	const known = w.tables.constructionSummaries.get(cls);
	if (known != null) return known;
	const s = newSummary(SummaryKind.Construction, cls, []);
	w.tables.constructionSummaries.set(cls, s);
	return s;
}

function settled(w: WriteEffects, s: WriteSummary): WriteSummary {
	if (s.index < 0) visit(w, s);
	return s;
}

function callWrites(w: WriteEffects, call: Node, defs: LocalDefs | null): WriteSummary {
	const s = newSummary(SummaryKind.Routine, null, []);
	if (call.kind == NodeKind.CallExpr && isLifecycleOp(w, call)) return s;
	if (call.kind == NodeKind.CallExpr) addressWrites(w, s, call, null, false);
	const callees = call.kind == NodeKind.NewExpr ? constructionsOf(w, call) : calleesOf(w, call, s, null, null, defs);
	for (const a of call.kind == NodeKind.NewExpr ? (call.data as NewExprData).newArguments : (call.data as CallExprData).arguments) {
		if (a != null && mayBeFunctionValue(a.nodeType) && !isLentCallback(w, a) && !routinesOf(w, a, null, null, null, 0, callees)) markUnknown(s);
	}
	for (const c of callees) {
		if (reloadsApart(w, s, c)) markUnknown(s);
		else absorb(w, s, { call: null, callee: settled(w, c) });
	}
	return s;
}

const SUBMITS_JOINED_BEFORE_FRAME_EXIT = ["msSpawnSlotSubmit", "msSpawnTaskSubmit", "msSpawnHeldSubmit", "msSpawnIntoHeldSubmit"];

export function retainsArg(w: WriteEffects, call: Node, ai: int32): boolean {
	const called = call.resolvedSym;
	if (!isRoutineSym(called)) return true;
	if (SUBMITS_JOINED_BEFORE_FRAME_EXIT.some((name: string): boolean => isRuntimeProcSym(called, name))) return false;
	const sym = findOverloadImpl(called!) ?? called!;
	const fi = ai + (call.flags.has(NodeFlag.ExtCall) ? 1 : 0);
	const formals = sym.symbolType != null && sym.symbolType.kind == TypeKind.Function ? sym.symbolType.typeChildren : null;
	if (formals == null || fi >= formals.length || formals[fi] == null || formals[fi].kind == TypeKind.Sink) return true;
	return retainsParam(w, sym, fi);
}

export function retainsParam(w: WriteEffects, sym: Symbol, i: int32): boolean {
	if (i < 0 || i >= 31 || runsNativeOnC(w, sym) || dispatchEntryFor(sym) != null) return true;
	const known = w.tables.retainedParams.get(sym);
	if (known != null) return (known & (1 << i)) != 0;
	w.tables.retainedParams.set(sym, -1);
	const decl = routineDecl(w, sym);
	const body = routineBody(decl);
	const bits = body != null && decl!.paramSyms != null ? retainedParams(w, body, decl!.paramSyms!) : -1;
	w.tables.retainedParams.set(sym, bits);
	return (bits & (1 << i)) != 0;
}

function retainedParams(w: WriteEffects, body: Node, params: Symbol[]): int32 {
	let bits: int32 = 0;
	const retain = (n: Node): void => {
		if (n.kind == NodeKind.Identifier && n.resolvedSym != null) {
			const k = paramIndex(params, n.resolvedSym!);
			if (k >= 0) bits = bits | (k < 31 ? 1 << k : -1);
		}
		forEachChild(n, retain);
	};
	const step = (n: Node): void => {
		if (isRoutineNode(n) || n.kind == NodeKind.Identifier) {
			retain(n);
			return;
		}
		if (n.kind != NodeKind.CallExpr) {
			forEachChild(n, step);
			return;
		}
		const cd = n.data as CallExprData;
		const callee = cd.callee != null ? skipConvDfa(cd.callee) : null;
		if (callee != null && !(callee.kind == NodeKind.Identifier && callee.resolvedSym != null && paramIndex(params, callee.resolvedSym!) >= 0)) step(callee);
		for (let ai = 0; ai < cd.arguments.length; ai += 1) {
			const a = cd.arguments[ai];
			if (a == null) continue;
			const t = skipConvDfa(a);
			if (t.kind == NodeKind.Identifier && t.resolvedSym != null && paramIndex(params, t.resolvedSym!) >= 0 && !retainsArg(w, n, ai as int32)) continue;
			step(a);
		}
	};
	step(body);
	return bits;
}

// The slots a view call's result is reached through below its arguments: the steps every
// return of the callee takes from a parameter or a Readonly module constant, closed over the
// view calls it returns through. Null when a return is not such a path or the callee's body
// is unknown, so the caller keeps treating the result as reachable from any heap slot.
export function viewReturnSlots(w: WriteEffects, call: Node): string[] | null {
	const sym = calledRoutine(call);
	if (sym == null || runsNativeOnC(w, sym) || dispatchEntryFor(sym) != null) return null;
	return routineReturnSlots(w, sym);
}

function routineReturnSlots(w: WriteEffects, sym: Symbol): string[] | null {
	const known = w.tables.viewReturns.get(sym);
	if (known != null) return known;
	if (w.tables.viewReturnsUnknown.has(sym)) return null;
	const open = w.tables.viewReturnsOpen.indexOf(sym);
	if (open >= 0) {
		if (open < w.tables.viewReturnsReach) w.tables.viewReturnsReach = open as int32;
		return [];
	}
	const decl = routineDecl(w, sym);
	const body = routineBody(decl);
	if (decl == null || body == null) return null;
	const depth = w.tables.viewReturnsOpen.length as int32;
	const outerReach = w.tables.viewReturnsReach;
	w.tables.viewReturnsReach = depth;
	w.tables.viewReturnsOpen.push(sym);
	const out: string[] = [];
	const ok = returnArmsSlots(w, body, decl.paramSyms, localDefs(w, body), out);
	w.tables.viewReturnsOpen.pop();
	if (w.tables.viewReturnsReach >= depth) {
		if (ok) w.tables.viewReturns.set(sym, out);
		else w.tables.viewReturnsUnknown.add(sym);
	}
	w.tables.viewReturnsReach = w.tables.viewReturnsReach < outerReach ? w.tables.viewReturnsReach : outerReach;
	return ok ? out : null;
}

function returnArmsSlots(w: WriteEffects, n: Node, params: Symbol[] | null, d: LocalDefs, out: string[]): boolean {
	if (isRoutineNode(n)) return true;
	if (n.kind == NodeKind.ReturnStmt) {
		const arg = (n.data as ReturnStmtData).argument;
		return arg == null || pathFromParams(w, arg, params, d, new HashSet<Symbol>(), out);
	}
	let ok = true;
	forEachChild(n, (c: Node): void => { if (ok && !returnArmsSlots(w, c, params, d, out)) ok = false; });
	return ok;
}

function pathFromParams(w: WriteEffects, n: Node, params: Symbol[] | null, d: LocalDefs, seen: HashSet<Symbol>, out: string[]): boolean {
	const t = skipConvDfa(n);
	match (t.kind) {
		NodeKind.NullLiteral => { return true; },
		NodeKind.ConditionalExpr => {
			const cd = t.data as ConditionalExprData;
			return pathFromParams(w, cd.ternaryConsequent, params, d, seen, out) && pathFromParams(w, cd.ternaryAlternate, params, d, seen, out);
		},
		NodeKind.BinaryExpr => {
			const bd = t.data as BinaryExprData;
			return bd.operator == "??" && pathFromParams(w, bd.left, params, d, seen, out) && pathFromParams(w, bd.right, params, d, seen, out);
		},
		NodeKind.MemberExpr => {
			out.push(stepSlot(w, t)!);
			return pathFromParams(w, (t.data as MemberExprData).object, params, d, seen, out);
		},
		NodeKind.ArrayAccess => {
			out.push(stepSlot(w, t)!);
			return pathFromParams(w, (t.data as ArrayAccessData).array, params, d, seen, out);
		},
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => { return pathFromParams(w, (t.data as HiddenDerefData).expr, params, d, seen, out); },
		NodeKind.MoveExpr => { return pathFromParams(w, (t.data as MoveExprData).moveArg, params, d, seen, out); },
		NodeKind.CallExpr => {
			const projected = loweredAccessStep(t);
			if (projected != null) {
				if (projected == ELEMENT_SLOT) out.push(heldSlot(w, ELEMENT_SLOT, (t.data as CallExprData).arguments[0].nodeType));
				return pathFromParams(w, (t.data as CallExprData).arguments[0], params, d, seen, out);
			}
			if (!isViewCall(t)) return false;
			const inner = viewReturnSlots(w, t);
			if (inner == null) return false;
			for (const slot of inner) out.push(slot);
			const sources: Node[] = [];
			viewCallSources(t, sources);
			for (const a of sources) {
				if (containsPointer(a.nodeType, 0) && !pathFromParams(w, a, params, d, seen, out)) return false;
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
			const k = d.index.get(sym) ?? -1;
			if (k < 0) return false;
			for (const src of d.sources[k]) {
				if (!pathFromParams(w, src, params, d, seen, out)) return false;
			}
			return true;
		},
		_ => { return false; },
	};
}

export function stepSlot(w: WriteEffects, n: Node): string | null {
	match (n.kind) {
		NodeKind.Identifier => { return n.resolvedSym != null && isModuleState(n.resolvedSym!) ? globalSlot(n.resolvedSym!) : null; },
		NodeKind.MemberExpr => { return heldSlot(w, fieldSlot((n.data as MemberExprData).property), (n.data as MemberExprData).object.nodeType); },
		NodeKind.ArrayAccess => { return heldSlot(w, ELEMENT_SLOT, (n.data as ArrayAccessData).array.nodeType); },
		_ => { return null; },
	};
}

export function mayWrite(w: WriteEffects, n: Node, slots: string[], defs: LocalDefs | null): boolean {
	if (n.kind != NodeKind.BinaryExpr) return mayWriteAny(w, callWrites(w, n, defs), slots);
	if (!isAssign((n.data as BinaryExprData).operator)) return false;
	const writes = newSummary(SummaryKind.Routine, null, []);
	const target = (n.data as BinaryExprData).left;
	writeTarget(w, writes, target, null, false, null);
	const hooks = target.nodeType != null ? hookSummary(w, target.nodeType!) : null;
	if (hooks != null) absorb(w, writes, { call: null, callee: settled(w, hooks) });
	return mayWriteAny(w, writes, slots);
}

export function callerDefsOf(w: WriteEffects, body: Node): LocalDefs {
	return localDefs(w, body);
}

export function callsPlainRoutine(call: Node): boolean {
	return isRoutineSym(call.resolvedSym);
}

export function reachesModuleState(w: WriteEffects, call: Node, defs: LocalDefs | null): boolean {
	const writes = callWrites(w, call, defs);
	if (writes.unknown) return true;
	for (const slot of writes.slots) {
		if (slot.startsWith("G:")) return true;
	}
	return false;
}

export function runsHooks(w: WriteEffects, target: Node): boolean {
	return target.nodeType != null && hookSummary(w, target.nodeType!) != null;
}

function mayWriteAny(w: WriteEffects, writes: WriteSummary, slots: string[]): boolean {
	if (writes.unknown) return true;
	for (const slot of slots) {
		if (slot == ANY_HEAP_SLOT ? writes.slots.length > 0 : writes.slotSet.has(slot)) return true;
		if (slot == ANY_HEAP_SLOT) continue;
		for (const written of writes.slots) {
			if (slotMayHit(w, written, slot)) return true;
		}
	}
	return false;
}

function pathSlots(w: WriteEffects, n: Node, out: string[]): Symbol | null {
	const t = skipConvDfa(n);
	match (t.kind) {
		NodeKind.Identifier => {
			const sym = t.resolvedSym;
			if (sym != null && isModuleState(sym)) out.push(globalSlot(sym));
			return sym;
		},
		NodeKind.MemberExpr => {
			const md = t.data as MemberExprData;
			const root = pathSlots(w, md.object, out);
			out.push(heldSlot(w, fieldSlot(md.property), md.object.nodeType));
			return root;
		},
		NodeKind.ArrayAccess => {
			const root = pathSlots(w, (t.data as ArrayAccessData).array, out);
			out.push(heldSlot(w, ELEMENT_SLOT, (t.data as ArrayAccessData).array.nodeType));
			return root;
		},
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => { return pathSlots(w, (t.data as HiddenDerefData).expr, out); },
		_ => { return null; },
	};
}

export function borrowedArgsToCopy(w: WriteEffects, call: Node, defs: LocalDefs | null): boolean[] {
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
		roots.push(a != null ? pathSlots(w, source ?? a, s) : null);
		slots.push(s);
		if (source != null) {
			flags.push(s.length > 0);
			continue;
		}
		const borrowed = a != null && !byAddress[byAddress.length - 1] && w.rcOf(a.nodeType).needsCleanup;
		flags.push(borrowed);
		if (borrowed) any = true;
	}
	if (!any) return flags;
	const writes = callWrites(w, call, defs);
	const lends = runsCallbacks(w, call);
	for (let i = 0; i < args.length; i += 1) {
		if (!flags[i] || cstringSource(args[i]) != null) continue;
		let keep = false;
		for (let j = 0; j < args.length && !keep; j += 1) {
			if (j != i && byAddress[j] && roots[i] != null && roots[j] === roots[i]) keep = true;
		}
		const reads = reachesCalleeByValue(w, call, i) ? slots[i] : addressSlots(slots[i]);
		if (!keep && slots[i].length > 0) keep = mayWriteAny(w, writes, reads);
		if (!keep && lends) noteHeldAcrossCallbacks(w, reads);
		flags[i] = keep;
	}
	return flags;
}

function reachesCalleeByValue(w: WriteEffects, call: Node, i: int32): boolean {
	const kind = w.rcOf((call.data as CallExprData).arguments[i].nodeType).rcKind;
	if (kind != RcKind.Ref && kind != RcKind.String) return false;
	const sym = call.resolvedSym;
	const fnType = sym != null && sym.symbolType != null && sym.symbolType.kind == TypeKind.Function ? sym.symbolType : (call.data as CallExprData).callee.nodeType;
	return i > 0 || !returnsBorrow(fnType);
}

class CallbackContract {
	fn: Symbol;
	params: int32[];
	reads: WriteSummary;
	clone: Symbol | null;
}

interface Lending {
	callbacks: Symbol[];
	contract: CallbackContract | null;
	held: string[] | null;
}

export interface ContractClaim {
	fn: Symbol;
	clone: Symbol | null;
	params: int32[];
	slots: string[];
	holders: (Type | null)[];
}

export function callbackParams(w: WriteEffects, decl: Node): int32[] {
	const out: int32[] = [];
	const params = decl.paramSyms;
	const body = routineBody(decl);
	if (params == null || body == null) return out;
	const targets: Node[] = [];
	const step = (n: Node): void => {
		if (n.kind == NodeKind.BinaryExpr && isAssign((n.data as BinaryExprData).operator)) targets.push((n.data as BinaryExprData).left);
		if (n.kind == NodeKind.CallExpr) {
			const args = (n.data as CallExprData).arguments;
			if (isLifecycleOp(w, n)) targets.push(args[0]);
			for (const a of args) { if (a != null && a.kind == NodeKind.HiddenAddr) targets.push(a); }
		}
		forEachChild(n, step);
	};
	step(body);
	const assigned = assignedParams(targets, params);
	for (let i = 0; i < params.length; i += 1) {
		const t = params[i].symbolType;
		if (t != null && t.kind == TypeKind.Function && !assigned.has(params[i])) out.push(i as int32);
	}
	return out;
}

export function lendCallbacks(w: WriteEffects, callbacks: Symbol[], held: string[] | null): Lending {
	const outer = w.tables.lending;
	w.tables.lending = { callbacks, contract: null, held };
	return outer;
}

export function enterRoutineLending(w: WriteEffects, owner: Symbol | null, params: Symbol[] | null): Lending {
	const outer = w.tables.lending;
	const contract = owner != null ? w.tables.cloneContracts.get(owner) : null;
	const callbacks: Symbol[] = [];
	if (contract != null) {
		if (params == null) throw new Error(`internal: callback reader clone '${owner!.name}' has no parameters`);
		for (const i of contract.params) callbacks.push(params[i]);
	}
	w.tables.lending = { callbacks, contract, held: contract != null ? [] : null };
	return outer;
}

export function leaveRoutineLending(w: WriteEffects, outer: Lending): void {
	const inner = w.tables.lending;
	w.tables.lending = outer;
	if (inner.contract == null) return;
	for (const slot of inner.held!) {
		if (!inner.contract.reads.slotSet.has(slot)) throw new Error(`internal: callback reader clone '${inner.contract.clone!.name}' holds ${bareSlot(slot)} across a callback outside its contract`);
	}
}

function isLentCallback(w: WriteEffects, value: Node | null): boolean {
	if (value == null) return false;
	const t = skipConvDfa(value);
	return t.kind == NodeKind.Identifier && t.resolvedSym != null && w.tables.lending.callbacks.includes(t.resolvedSym!);
}

export function runsCallbacks(w: WriteEffects, n: Node): boolean {
	if (w.tables.lending.callbacks.length == 0) return false;
	if (n.kind == NodeKind.NewExpr) {
		for (const a of (n.data as NewExprData).newArguments) { if (isLentCallback(w, a)) return true; }
		return false;
	}
	if (n.kind != NodeKind.CallExpr) return false;
	const sym = n.resolvedSym;
	if (sym != null && w.tables.lending.callbacks.includes(sym)) return true;
	for (const a of (n.data as CallExprData).arguments) { if (isLentCallback(w, a)) return true; }
	return false;
}

export function forwardedTo(w: WriteEffects, call: Node): Symbol | null {
	if (call.kind != NodeKind.CallExpr || !isRoutineSym(call.resolvedSym)) return null;
	for (const a of (call.data as CallExprData).arguments) { if (isLentCallback(w, a)) return call.resolvedSym; }
	return null;
}

export function collectsHeld(w: WriteEffects): boolean {
	return w.tables.lending.held != null && w.tables.lending.callbacks.length > 0;
}

export function noteHeldAcrossCallbacks(w: WriteEffects, slots: string[]): void {
	const held = w.tables.lending.held;
	if (held == null) return;
	for (const slot of slots) { if (!held.includes(slot)) held.push(slot); }
}

export function openContract(w: WriteEffects, fn: Symbol, params: int32[], clone: Symbol, held: string[], forwards: Symbol[]): void {
	const reads = newSummary(SummaryKind.Contract, null, []);
	for (const slot of held) addSlot(reads, slot);
	for (const f of forwards) { if (!reads.forwards.includes(f)) reads.forwards.push(f); }
	const contract: CallbackContract = { fn, params, reads, clone };
	w.tables.contracts.set(fn, contract);
	w.tables.cloneContracts.set(clone, contract);
	w.tables.unitContracts.push(contract);
}

export function settleContract(w: WriteEffects, fn: Symbol): Symbol | null {
	const contract = w.tables.contracts.get(fn);
	if (contract == null) throw new Error(`internal: '${fn.name}' has no callback contract to settle`);
	const reads = settled(w, contract.reads);
	if (reads.unknown || reads.slots.length == 0) {
		if (contract.clone != null) w.tables.cloneContracts.delete(contract.clone!);
		contract.clone = null;
	}
	return contract.clone;
}

export function bindingKeepsContract(w: WriteEffects, fn: Symbol, binding: Node | null, defs: LocalDefs | null): boolean {
	const contract = w.tables.contracts.get(fn);
	if (contract == null || contract.clone == null || binding == null) return false;
	const inner = w.tables.lending.contract;
	if (isLentCallback(w, binding)) {
		if (inner == null) return false;
		for (const slot of contract.reads.slots) { if (!inner.reads.slotSet.has(slot)) return false; }
		return true;
	}
	const callees: WriteSummary[] = [];
	if (!routinesOf(w, binding, null, null, defs, 0, callees)) return false;
	const writes = newSummary(SummaryKind.Routine, null, []);
	for (const c of callees) {
		if (reloadsApart(w, writes, c)) return false;
		absorb(w, writes, { call: null, callee: settled(w, c) });
	}
	return !mayWriteAny(w, writes, contract.reads.slots);
}

export function cloneForCall(w: WriteEffects, call: Node, defs: LocalDefs | null): Symbol | null {
	const sym = call.resolvedSym;
	if (sym == null || call.kind != NodeKind.CallExpr) return null;
	const contract = w.tables.contracts.get(sym);
	if (contract == null || contract.clone == null) return null;
	if (w.tables.reloadableUnits.length > 0) {
		const unit = w.tables.routineDecls.routineUnits.get(sym);
		if (unit == null || (w.tables.reloadableUnits.includes(unit) && unit != w.unit)) return null;
	}
	const args = (call.data as CallExprData).arguments;
	for (const i of contract.params) {
		if (i >= args.length || !bindingKeepsContract(w, sym, args[i], defs)) return null;
	}
	return contract.clone;
}

function onTables(tables: WriteSummaries): WriteEffects {
	return { tables, checker: null, unit: "", rcOf: (t: Type | null): RcInfo => noRcInfo(), aliasMemo: new HashMap<Type, HashMap<Type, int32>>() };
}

export function contractClaims(tables: WriteSummaries): ContractClaim[] {
	const w = onTables(tables);
	const out: ContractClaim[] = [];
	for (const c of tables.unitContracts) {
		const slots: string[] = [];
		const holders: (Type | null)[] = [];
		for (const slot of c.reads.slots) {
			slots.push(bareSlot(slot));
			holders.push(slotHolder(w, slot));
		}
		out.push({ fn: c.fn, clone: c.clone, params: c.params, slots, holders });
	}
	return out;
}

export function reuseClones(tables: WriteSummaries, claims: ContractClaim[]): void {
	for (const claim of claims) {
		if (claim.clone != null) tables.reusedClones.set(claim.fn, claim.clone!);
	}
}

export function restoreContracts(tables: WriteSummaries, claims: ContractClaim[]): void {
	const w = onTables(tables);
	for (const claim of claims) {
		const reads = newSummary(SummaryKind.Contract, null, []);
		for (let i = 0; i < claim.slots.length; i += 1) addSlot(reads, heldSlot(w, claim.slots[i], claim.holders[i]));
		settled(w, reads);
		const contract: CallbackContract = { fn: claim.fn, params: claim.params, reads, clone: claim.clone };
		tables.contracts.set(claim.fn, contract);
		if (claim.clone != null) tables.cloneContracts.set(claim.clone!, contract);
	}
}

function writeProbe(): WriteEffects {
	return { tables: createWriteSummaries(createRoutineDecls(), []), checker: null, unit: "", rcOf: (t: Type | null): RcInfo => noRcInfo(), aliasMemo: new HashMap<Type, HashMap<Type, int32>>() };
}

function localOf(name: string, t: Type, loc: SourceLocation): Node {
	return makeIdentResolved(makeSymbol(name, SymbolKind.Variable, t, false), loc);
}

function elementRead(loc: SourceLocation): Node {
	return makeCall(generatedRef("msArrayAccess", loc), [localOf("arr", createArray(stringType()), loc), makeNumber(0, loc)], loc);
}

test "an element read through a generated access macro writes nothing" {
	const w = writeProbe();
	const loc = makeLoc(0, 0);
	assert !mayWrite(w, elementRead(loc), [ELEMENT_SLOT], null);
}

test "a store through a generated access macro writes the elements" {
	const w = writeProbe();
	const loc = makeLoc(0, 0);
	assert mayWrite(w, makeAssign(elementRead(loc), makeString("s", loc), loc), [ELEMENT_SLOT], null);
}

test "a union projection through a generated macro writes nothing" {
	const w = writeProbe();
	const loc = makeLoc(0, 0);
	const read = makeCall(generatedRef("msVariantAccessVal", loc), [localOf("u", int32Type(), loc), makeNumber(0, loc), makeString("a", loc), makeString("a|b", loc)], loc);
	assert !mayWrite(w, read, [ELEMENT_SLOT, fieldSlot("a")], null);
}

test "a generated macro handed a function value may write anything" {
	const w = writeProbe();
	const loc = makeLoc(0, 0);
	const callback = localOf("cb", createFunction([], [], int32Type()), loc);
	assert mayWrite(w, makeCall(generatedRef("msSpanAccess", loc), [callback, makeNumber(0, loc)], loc), [fieldSlot("a")], null);
}

test "a store through a generated access macro writes only elements of its array's type" {
	const w = writeProbe();
	const loc = makeLoc(0, 0);
	const store = makeAssign(elementRead(loc), makeString("s", loc), loc);
	assert mayWrite(w, store, [heldSlot(w, ELEMENT_SLOT, createArray(stringType()))], null);
	assert !mayWrite(w, store, [heldSlot(w, ELEMENT_SLOT, createArray(createArray(int32Type())))], null);
}

function loweredViewCall(returned: (param: Node, loc: SourceLocation) => Node, paramType: Type, loc: SourceLocation): Node {
	const param = makeSymbol("xs", SymbolKind.Parameter, paramType, false);
	const fn = makeSymbol("lowered", SymbolKind.Function, createFunction([paramType], ["xs"], paramType), false);
	fn.declNode = makeFnDecl("lowered", [param], [""], makeBlock([makeReturn(returned(makeIdentResolved(param, loc), loc), loc)], loc), "", "", loc);
	return makeCall(makeIdentResolved(fn, loc), [localOf("ys", paramType, loc)], loc);
}

test "a view call's result is reached through the lowered accessor its callee returns" {
	const w = writeProbe();
	const loc = makeLoc(0, 0);
	const arrType = createArray(createArray(int32Type()));
	const element = loweredViewCall((xs: Node, at: SourceLocation): Node => makeCall(generatedRef("msRefArrayAccess", at), [xs, makeNumber(0, at)], at), arrType, loc);
	const elementSlots = (viewReturnSlots(w, element) ?? ["unknown"]).join(",");
	assert elementSlots == heldSlot(w, ELEMENT_SLOT, arrType), elementSlots;
	const variant = loweredViewCall((u: Node, at: SourceLocation): Node => makeCall(generatedRef("msVariantAccess", at), [u, makeNumber(0, at), makeString("a", at), makeString("a|b", at)], at), arrType, loc);
	const variantSlots = (viewReturnSlots(w, variant) ?? ["unknown"]).join(",");
	assert variantSlots == "", variantSlots;
}
