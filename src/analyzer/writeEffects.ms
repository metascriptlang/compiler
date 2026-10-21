// A parameter or a cursor is a borrow of a location, so a write to that location frees what
// the borrow still reads. A routine's summary names the locations it may write, closed over
// its callees, the overrides it dispatches to and the lifecycle hooks the values it handles
// run; borrowedArgsToCopy picks the arguments the caller must keep alive, and mayWrite tells
// cursor inference which statements end a borrow.

import { Node, NodeKind, Symbol, SymbolKind, SourceLocation, Type, TypeKind, makeLoc, BinaryExprData, CallExprData, ClassDeclData, ConstructorDeclData, DecoratedDeclData, HiddenDerefData, MemberExprData, NewExprData, PropertyDeclData, ArrayAccessData, IdentifierData, ProgramData, ExportDeclData } from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { SymbolFlag, hasFlag, makeSymbol, parentClassSymOf } from "../checker/symbol";
import { CheckerContext, LIFECYCLE_HOOK_NAMES, dispatchEntryFor, dispatchOverridesFor, extReceiverSym, findAllExtensionsByName, nominalTypeSym } from "../checker/context";
import { routineBody, receiverOf } from "../checker/effects";
import { lookupInstanceHook, pickBodyCtx } from "../checker/instantiate";
import { isMutatingArrayMethod } from "../checker/paramMutationAnalysis";
import { skipConvDfa } from "./alias";
import { RcInfo, noRcInfo } from "./classify";
import { makeNumber, makeString } from "../checker/literalNodes";
import { createArray, createFunction, int32Type, stringType } from "../checker/types";
import { generatedRef, isRuntimeProcSym, makeAssign, makeCall, makeIdentResolved } from "../transform/util";

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
	unknown: boolean;
	edges: Edge[];
	linked: HashSet<WriteSummary>;
	index: int32;
	low: int32;
	onStack: boolean;
	done: boolean;
}

let routineSummaries = new HashMap<Symbol, WriteSummary>();
let constructionSummaries = new HashMap<Symbol, WriteSummary>();
let hookSummaries = new HashMap<Type, WriteSummary>();
let hookless = new HashSet<Type>();
let ownerHookCache = new HashMap<Symbol, Symbol[]>();
let routineDecls = new HashMap<Symbol, Node>();
let unitRoutines = new HashMap<string, Symbol[]>();
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
	const previous = unitRoutines.get(unit);
	if (previous != null) {
		for (const sym of previous) routineDecls.delete(sym);
	}
	const syms: Symbol[] = [];
	for (const stmt of (program.data as ProgramData).programStmts) {
		let decl = unpackDecl(stmt);
		if (decl != null && decl.kind == NodeKind.ExportDecl) decl = unpackDecl((decl.data as ExportDeclData).exportedDecl);
		if (decl == null || decl.resolvedSym == null || (decl.kind != NodeKind.FunctionDecl && decl.kind != NodeKind.ClassDecl)) continue;
		routineDecls.set(decl.resolvedSym!, decl);
		syms.push(decl.resolvedSym!);
	}
	unitRoutines.set(unit, syms);
}

export function resetRoutineDecls(): void {
	routineDecls = new HashMap<Symbol, Node>();
	unitRoutines = new HashMap<string, Symbol[]>();
}

export function clearWriteSummaries(): void {
	ownerHookCache = new HashMap<Symbol, Symbol[]>();
	routineSummaries = new HashMap<Symbol, WriteSummary>();
	constructionSummaries = new HashMap<Symbol, WriteSummary>();
	hookSummaries = new HashMap<Type, WriteSummary>();
	hookless = new HashSet<Type>();
	stack = [];
	nextIndex = 0;
}

function newSummary(kind: SummaryKind, sym: Symbol | null, hooks: Symbol[]): WriteSummary {
	return {
		kind, sym, hooks, slots: [], slotSet: new HashSet<string>(), refParamWrites: 0, unknown: false,
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

function paramIndex(params: Symbol[] | null, sym: Symbol): int32 {
	if (params == null) return -1;
	for (let i = 0; i < params.length; i += 1) {
		if (params[i] === sym) return i as int32;
	}
	return -1;
}

function writeTarget(s: WriteSummary, target: Node | null, params: Symbol[] | null, inCtor: boolean): boolean {
	if (target == null) return false;
	const t = skipConvDfa(target);
	match (t.kind) {
		NodeKind.Identifier => {
			const sym = t.resolvedSym;
			if (sym == null) return false;
			if (isModuleState(sym)) return addSlot(s, globalSlot(sym));
			const k = paramIndex(params, sym);
			if (sym.symbolType == null || sym.symbolType.kind != TypeKind.Var) return false;
			if (k < 0 || k >= 31 || (s.refParamWrites & (1 << k)) != 0) return false;
			s.refParamWrites = s.refParamWrites | (1 << k);
			return true;
		},
		NodeKind.MemberExpr => {
			const md = t.data as MemberExprData;
			if (inCtor && isThis(md.object)) return false;
			const field = addSlot(s, fieldSlot(md.property));
			const elements = md.property == "length" && addSlot(s, ELEMENT_SLOT);
			return field || elements;
		},
		NodeKind.ArrayAccess => { return addSlot(s, ELEMENT_SLOT); },
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => { return writeTarget(s, (t.data as HiddenDerefData).expr, params, inCtor); },
		_ => {
			let changed = isGeneratedProc(t.resolvedSym) && addSlot(s, ELEMENT_SLOT);
			forEachChild(t, (child: Node): void => { if (writeTarget(s, child, params, inCtor)) changed = true; });
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

function takesFunctionValue(sym: Symbol): boolean {
	const t = sym.symbolType;
	if (t == null || t.kind != TypeKind.Function) return true;
	for (const formal of t.typeChildren) {
		if (mayBeFunctionValue(formal)) return true;
	}
	return false;
}

function isGeneratedProc(sym: Symbol | null): boolean {
	return sym != null && sym.symbolType == null && sym.declNode == null && hasFlag(sym, SymbolFlag.ImportC);
}

function runsNativeOnC(sym: Symbol): boolean {
	return hasFlag(sym, SymbolFlag.ImportC) || routineBody(routineDecl(sym)) == null;
}

function nativeEffect(s: WriteSummary, call: Node, sym: Symbol): void {
	if (isGeneratedProc(sym)) {
		if (passesFunctionValue(call)) markUnknown(s);
		return;
	}
	const recv = receiverOf(call);
	for (const a of (call.data as CallExprData).arguments) {
		if (a != null && isArrayStorage(a.nodeType)) addSlot(s, ELEMENT_SLOT);
	}
	if (recv != null && !hasFlag(sym, SymbolFlag.ImportC)) {
		const name = sym.name;
		if (isMutatingArrayMethod(name) || name == "set" || name == "delete" || name == "clear" || name == "add") addSlot(s, ELEMENT_SLOT);
		return;
	}
	if (sym.symbolKind == SymbolKind.Method && !hasFlag(sym, SymbolFlag.NativeMethod)) {
		markUnknown(s);
		return;
	}
	if (takesFunctionValue(sym)) markUnknown(s);
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

function calleesOf(call: Node, s: WriteSummary): WriteSummary[] {
	const sym = call.resolvedSym;
	if (!isRoutineSym(sym)) {
		const callee = (call.data as CallExprData).callee;
		if (callee != null && callee.kind == NodeKind.Identifier && (callee.data as IdentifierData).name == "super") {
			const cls = sym != null && sym.symbolKind == SymbolKind.Class ? sym : null;
			return cls != null ? [constructionSummary(cls)] : [];
		}
		markUnknown(s);
		return [];
	}
	const out: WriteSummary[] = [];
	if (runsNativeOnC(sym!)) nativeEffect(s, call, sym!);
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

function walkBody(s: WriteSummary, body: Node | null, params: Symbol[] | null, inCtor: boolean): void {
	if (body == null) return;
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
				if (isAssign(bd.operator)) writeTarget(s, bd.left, params, inCtor);
			},
			NodeKind.CallExpr => {
				const args = (n.data as CallExprData).arguments;
				if (isLifecycleOp(n)) {
					writeTarget(s, args[0], params, inCtor);
				} else {
					addressWrites(s, args, params, inCtor);
					for (const c of calleesOf(n, s)) link(s, n, c);
				}
			},
			NodeKind.NewExpr => {
				for (const c of constructionsOf(n)) link(s, null, c);
			},
			_ => {},
		};
		forEachChild(n, step);
	};
	step(body);
}

function addressWrites(s: WriteSummary, args: Node[], params: Symbol[] | null, inCtor: boolean): void {
	for (const a of args) {
		if (a == null || a.kind != NodeKind.HiddenAddr) continue;
		writeTarget(s, a, params, inCtor);
		if (isArrayStorage((a.data as HiddenDerefData).expr.nodeType)) addSlot(s, ELEMENT_SLOT);
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
			walkBody(s, routineBody(decl), decl != null ? decl.paramSyms : null, (decl != null && decl.kind == NodeKind.ConstructorDecl) || hasFlag(s.sym!, SymbolFlag.ClassInit));
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
			if ((c.refParamWrites & (1 << i)) != 0 && writeTarget(s, args[i], params, false)) changed = true;
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
	for (const c of call.kind == NodeKind.NewExpr ? constructionsOf(call) : calleesOf(call, s)) {
		absorb(s, { call: null, callee: settled(c) });
	}
	return s;
}

export function stepSlot(n: Node): string | null {
	match (n.kind) {
		NodeKind.Identifier => { return n.resolvedSym != null && isModuleState(n.resolvedSym!) ? globalSlot(n.resolvedSym!) : null; },
		NodeKind.MemberExpr => { return fieldSlot((n.data as MemberExprData).property); },
		NodeKind.ArrayAccess => { return ELEMENT_SLOT; },
		_ => { return null; },
	};
}

export function mayWrite(n: Node, slots: string[]): boolean {
	if (n.kind != NodeKind.BinaryExpr) return mayWriteAny(callWrites(n), slots);
	if (!isAssign((n.data as BinaryExprData).operator)) return false;
	const writes = newSummary(SummaryKind.Routine, null, []);
	const target = (n.data as BinaryExprData).left;
	writeTarget(writes, target, null, false);
	const hooks = target.nodeType != null ? hookSummary(target.nodeType!) : null;
	if (hooks != null) absorb(writes, { call: null, callee: settled(hooks) });
	return mayWriteAny(writes, slots);
}

function mayWriteAny(writes: WriteSummary, slots: string[]): boolean {
	if (writes.unknown) return true;
	for (const slot of slots) {
		if (slot == ANY_HEAP_SLOT ? writes.slots.length > 0 : writes.slotSet.has(slot)) return true;
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
			out.push(fieldSlot(md.property));
			return root;
		},
		NodeKind.ArrayAccess => {
			const root = pathSlots((t.data as ArrayAccessData).array, out);
			out.push(ELEMENT_SLOT);
			return root;
		},
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => { return pathSlots((t.data as HiddenDerefData).expr, out); },
		_ => { return null; },
	};
}

export function cstringSource(a: Node | null): Node | null {
	if (a == null || a.kind != NodeKind.CallExpr) return null;
	const cd = a.data as CallExprData;
	return cd.arguments.length == 1 && isRuntimeProcSym(cd.callee.resolvedSym, "msStringToCString") ? cd.arguments[0] : null;
}

export function borrowedArgsToCopy(call: Node): boolean[] {
	const args = (call.data as CallExprData).arguments;
	const flags: boolean[] = [];
	const roots: (Symbol | null)[] = [];
	const slots: string[][] = [];
	let any = false;
	for (const a of args) {
		const s: string[] = [];
		const source = cstringSource(a);
		roots.push(a != null ? pathSlots(source ?? a, s) : null);
		slots.push(s);
		if (source != null) {
			flags.push(s.length > 0);
			continue;
		}
		const borrowed = a != null && a.kind != NodeKind.HiddenAddr && rcOf(a.nodeType).needsCleanup;
		flags.push(borrowed);
		if (borrowed) any = true;
	}
	if (!any) return flags;
	const writes = callWrites(call);
	for (let i = 0; i < args.length; i += 1) {
		if (!flags[i] || cstringSource(args[i]) != null) continue;
		let keep = false;
		for (let j = 0; j < args.length && !keep; j += 1) {
			if (j != i && args[j] != null && args[j].kind == NodeKind.HiddenAddr && roots[i] != null && roots[j] === roots[i]) keep = true;
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
