import {
	Node, NodeKind, NodeFlag, Symbol, SymbolKind, Type, TypeKind,
	IdentifierData, VariableDeclData, MemberExprData, ArrayAccessData, BlockStmtData, BinaryExprData, UpdateExprData,
	WhileStmtData, ForStmtData, ForOfStmtData, ForInStmtData, DoWhileStmtData, CallExprData,
	ObjectLiteralData, ArrayLiteralData, NewExprData, MoveExprData, OutExprData, DeferStmtData,
	TypeAssertionData, HiddenStdConvData, ConditionalExprData, FunctionDeclData, MethodDeclData, ConstructorDeclData,
	ArrowFunctionData, FunctionExprData, TestDeclData, ProgramData, ReturnStmtData, AwaitExprData, SpreadExprData,
	MatchExprData, MatchCaseData, ExprStmtData, IfStmtData, TryCatchStmtData, DestructuringDeclData, ObjectPatternData,
	ObjectPatternPropData, ArrayPatternData, createNodeAt,
} from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { receiverOf, returnsView, routineBody, viewCallSources, isViewCall, aliasTarget, boundRoutine } from "./effects";
import { isOwnedRef, ownsNoStorage, typeVisitAdd, viewStructChangesInPlace, isPrimitiveKind, isViewType, isViewStruct, nestedViewType, nestedViewShown, ownedAlternativeOf, holdsViewSkippingClear, TypeVisitSet, isReadonlyView, isStructType, typeDisplayName, isLockedRef, isAtomicRef, typeCarriesRef, withoutReadonlyView, withoutNullMember } from "./types";
import { hasFlag, SymbolFlag, RoutineFlag, routineFlagSet } from "./symbol";
import { CheckerContext, addError, dispatchEntryFor, dispatchOverridesFor } from "./context";
import { isAddressTaking, checkPointerEscapesIn } from "./pointerAddress";
import { isMutatingArrayMethod } from "./paramMutationAnalysis";
import { sameUpToDistinct } from "./checkExprPass";
import { isSpawnCall } from "./freestanding";
import { refuseBorrowingHandleEscapes } from "./sendable";
import { recordBodyRead } from "./bodyReads";

export const MAX_TIME: int32 = 999999;
export const MIN_TIME: int32 = -1;

export const SF_IS_MUTATED: int32 = 1;

export const CK_EMPTY_ROOT: int32 = 0;
export const CK_DEPENDS_ON: int32 = 1;
export const CK_ROOT_OF: int32 = 2;

export interface Connection {
	kind: int32;
	target: int32;
}

export interface VarEntry {
	sym: Symbol;
	con: Connection;
	flags: int32;
	reassignedTo: Symbol | null;
	aliveStart: int32;
	aliveEnd: int32;
	borrowsFrom: int32[];
	borrowPaths: string[];
	borrowHandles: string[];
	scopePath: int32[];
	external: boolean;
	fromTemp: boolean;
}

export interface MutationInfo {
	flags: int32;
	maxMutation: int32;
	minConnection: int32;
	mutations: int32[];
	sites: Node[];
	roots: Symbol[];
	paths: string[];
	keeps: int32[][];
}

export interface Partitions {
	abstractTime: int32;
	vars: VarEntry[];
	graphs: MutationInfo[];
	inConstructor: int32;
	inConditional: int32;
	inLoop: int32;
	inAsgnSource: int32;
	lentTemps: Symbol[];
	lentInits: Node[];
}

export function createPartitions(): Partitions {
	return {
		abstractTime: 0, vars: [], graphs: [],
		inConstructor: 0, inConditional: 0, inLoop: 0, inAsgnSource: 0, lentTemps: [], lentInits: [],
	};
}

export function variableId(p: Partitions, sym: Symbol | null): int32 {
	if (sym == null) return -1;
	for (let i = 0; i < p.vars.length; i += 1) {
		if (p.vars[i].sym == sym) return i;
	}
	return -1;
}

export function registerVariable(p: Partitions, sym: Symbol | null, isParam: boolean, flagsIfParam: int32): void {
	if (sym == null) return;
	if (variableId(p, sym) >= 0) return;
	p.vars.push({
		sym,
		con: { kind: CK_EMPTY_ROOT, target: 0 },
		flags: isParam ? flagsIfParam : (0 as int32),
		reassignedTo: null,
		aliveStart: isParam ? 0 : p.abstractTime,
		aliveEnd: isParam ? MAX_TIME : p.abstractTime,
		borrowsFrom: [],
		borrowPaths: [],
		borrowHandles: [],
		scopePath: [],
		external: isParam,
		fromTemp: false,
	});
}

export function ufRoot(p: Partitions, start: int32): int32 {
	let r = start;
	let depth = 0;
	while (p.vars[r].con.kind == CK_DEPENDS_ON) {
		r = p.vars[r].con.target;
		depth += 1;
	}
	if (depth > 0) {
		let it = start;
		while (p.vars[it].con.kind == CK_DEPENDS_ON) {
			const next = p.vars[it].con.target;
			p.vars[it].con = { kind: CK_DEPENDS_ON, target: r };
			it = next;
		}
	}
	return r;
}

export function ufConnect(p: Partitions, a: Symbol, b: Symbol): void {
	const aid = variableId(p, a);
	if (aid < 0) return;
	const bid = variableId(p, b);
	if (bid < 0) return;

	const ra = ufRoot(p, aid);
	const rb = ufRoot(p, bid);
	if (ra == rb) return;

	let rbFlags: int32 = 0;
	let rbMut: int32 = 0;
	let rbCon: int32 = p.abstractTime;
	let rbMutations: int32[] = [];
	let rbSites: Node[] = [];
	let rbRoots: Symbol[] = [];
	let rbPaths: string[] = [];
	let rbKeeps: int32[][] = [];
	if (p.vars[rb].con.kind == CK_ROOT_OF) {
		const gb = p.graphs[p.vars[rb].con.target];
		rbFlags = gb.flags;
		rbMut = gb.maxMutation;
		if (gb.minConnection < rbCon) rbCon = gb.minConnection;
		rbMutations = gb.mutations;
		rbSites = gb.sites;
		rbRoots = gb.roots;
		rbPaths = gb.paths;
		rbKeeps = gb.keeps;
	}

	p.vars[rb].con = { kind: CK_DEPENDS_ON, target: ra };

	if (p.vars[ra].con.kind == CK_EMPTY_ROOT) {
		p.vars[ra].con = { kind: CK_ROOT_OF, target: p.graphs.length };
		const muts: int32[] = [];
		for (const m of rbMutations) { muts.push(m); }
		const sites: Node[] = [];
		for (const s of rbSites) { sites.push(s); }
		const roots: Symbol[] = [];
		for (const r of rbRoots) { roots.push(r); }
		const paths: string[] = [];
		for (const x of rbPaths) { paths.push(x); }
		const keeps: int32[][] = [];
		for (const k of rbKeeps) { keeps.push(k); }
		p.graphs.push({
			flags: rbFlags, maxMutation: rbMut,
			minConnection: rbCon, mutations: muts, sites, roots, paths, keeps,
		});
	} else if (p.vars[ra].con.kind == CK_ROOT_OF) {
		const ga = p.graphs[p.vars[ra].con.target];
		if (rbCon < ga.minConnection) ga.minConnection = rbCon;
		ga.flags = ga.flags | rbFlags;
		for (const m of rbMutations) { ga.mutations.push(m); }
		for (const s of rbSites) { ga.sites.push(s); }
		for (const r of rbRoots) { ga.roots.push(r); }
		for (const x of rbPaths) { ga.paths.push(x); }
		for (const k of rbKeeps) { ga.keeps.push(k); }
	}
}

export const NO_KEEP: int32[] = [-1];

// A write that changes a value in place without moving storage. Only a Borrow<T>
// local, which reads its source through an address, borrows such a place.
const VALUE_WRITE = "=";
const SUBTREE = "*";

export function potentialMutation(p: Partitions, sym: Symbol, site: Node | null = null, path: string = "", keep: int32[] = NO_KEEP): void {
	const id = variableId(p, sym);
	if (id < 0) return;
	if (p.abstractTime > p.vars[id].aliveEnd) p.vars[id].aliveEnd = p.abstractTime;

	const r = ufRoot(p, id);
	if (p.vars[r].con.kind == CK_EMPTY_ROOT) {
		p.vars[r].con = { kind: CK_ROOT_OF, target: p.graphs.length };
		p.graphs.push({
			flags: SF_IS_MUTATED, maxMutation: p.abstractTime,
			minConnection: MAX_TIME, mutations: [p.abstractTime], sites: [site as Node], roots: [sym], paths: [path], keeps: [keep],
		});
	} else if (p.vars[r].con.kind == CK_ROOT_OF) {
		const g = p.graphs[p.vars[r].con.target];
		if (p.abstractTime > g.maxMutation) g.maxMutation = p.abstractTime;
		g.flags = g.flags | SF_IS_MUTATED;
		g.mutations.push(p.abstractTime);
		g.sites.push(site as Node);
		g.roots.push(sym);
		g.paths.push(path);
		g.keeps.push(keep);
	}
}

export function dangerousMutation(g: MutationInfo, v: VarEntry): boolean {
	if ((g.flags & SF_IS_MUTATED) == 0) return false;
	for (const m of g.mutations) {
		if (m >= v.aliveStart && m <= v.aliveEnd) return true;
	}
	return false;
}

function prefixOf(changed: string, location: string): boolean {
	if (changed.length > location.length || !location.startsWith(changed)) return false;
	if (changed.length == location.length) return true;
	const next = location.charAt(changed.length);
	return next == "." || next == "[";
}

function handlePath(h: string): string {
	const at = h.endsWith(SUBTREE) ? h.slice(0, h.length - 1) : h;
	return at == "@" ? "" : at;
}

function reaches(changed: string, handles: string): boolean {
	for (const h of handles.split("|")) {
		if (h == "") continue;
		if (h.endsWith(SUBTREE)) {
			const base = h.slice(0, h.length - 1);
			if (!changed.startsWith(VALUE_WRITE) && (prefixOf(changed, base) || prefixOf(base, changed))) return true;
			continue;
		}
		if (prefixOf(changed, h == "@" ? "" : h)) return true;
	}
	return false;
}

function firstMutationIn(g: MutationInfo, v: VarEntry, source: Symbol, handles: string): int32 {
	if ((g.flags & SF_IS_MUTATED) == 0) return -1;
	const borrowed = borrowedKeys(source, handles);
	for (let i = 0; i < g.mutations.length; i += 1) {
		const m = g.mutations[i];
		if (m < v.aliveStart || m > v.aliveEnd || g.roots[i] == v.sym) continue;
		const keep = g.keeps[i];
		if (!(keep.length == 1 && keep[0] == -1) && encloses(keep, v.scopePath)) continue;
		if (g.roots[i] != source) {
			if (g.paths[i].startsWith(VALUE_WRITE)) continue;
			if (keysMeet(keysAtPath(g.roots[i], g.paths[i]), borrowed)) return i;
			continue;
		}
		if (reaches(g.paths[i], handles)) return i;
	}
	return -1;
}

export function containsPointer(t: Type | null, depth: int32): boolean {
	if (t == null || depth > 8) return true;
	if (isPrimitiveKind(t.kind)) return false;
	return match (t.kind) {
		TypeKind.String | TypeKind.BigInt => false,
		TypeKind.Struct | TypeKind.Tuple | TypeKind.Union => {
			for (const c of t.typeChildren) {
				if (containsPointer(c, depth + 1)) return true;
			}
			return false;
		},
		TypeKind.SizedArray => containsPointer(t.typeReturn, depth + 1),
		_ => true,
	};
}

interface HandleKey {
	any: boolean;
	text: boolean;
	elem: Type | null;
}

interface ResizeSummary {
	unknown: boolean;
	keys: HandleKey[];
	writes: boolean;
}

let resizeDone = new HashMap<Symbol, ResizeSummary>();
let resizeOpen = new HashMap<Symbol, ResizeSummary>();
let resizeStack: Symbol[] = [];
let resizeCyclic = false;

export function resetResizeSummaries(): void {
	resizeDone = new HashMap<Symbol, ResizeSummary>();
	resizeOpen = new HashMap<Symbol, ResizeSummary>();
	resizeStack = [];
	resizeCyclic = false;
	pendingDone = new HashMap<Node, PendingLend[]>();
	pendingOpen = new HashMap<Node, PendingLend[]>();
	pendingStack = [];
	pendingCyclic = false;
}

function noResize(): ResizeSummary {
	return { unknown: false, keys: [], writes: false };
}

function anyResize(): ResizeSummary {
	return { unknown: true, keys: [], writes: true };
}

function anyKey(): HandleKey {
	return { any: true, text: false, elem: null };
}

function textKey(): HandleKey {
	return { any: false, text: true, elem: null };
}

function arrayKey(elem: Type | null): HandleKey {
	if (elem == null || elem.kind == TypeKind.GenericParam || elem.kind == TypeKind.Unknown) return anyKey();
	return { any: false, text: false, elem };
}

function keyMatches(a: HandleKey, b: HandleKey): boolean {
	if (a.any || b.any) return true;
	if (a.text || b.text) return a.text == b.text;
	return sameUpToDistinct(a.elem!, b.elem!);
}

function matchesAnyKey(k: HandleKey, keys: HandleKey[]): boolean {
	for (const x of keys) {
		if (keyMatches(k, x)) return true;
	}
	return false;
}

function addKey(out: HandleKey[], k: HandleKey): void {
	for (const x of out) {
		if (x.any == k.any && x.text == k.text && (x.elem == k.elem || (x.elem != null && k.elem != null && sameUpToDistinct(x.elem, k.elem)))) return;
	}
	out.push(k);
}

function keysMeet(a: HandleKey[], b: HandleKey[]): boolean {
	for (const k of a) {
		if (matchesAnyKey(k, b)) return true;
	}
	return false;
}

function sharedKeys(t: Type | null, viaRef: boolean, depth: int32, out: HandleKey[]): void {
	if (t == null || depth > 6) {
		addKey(out, anyKey());
		return;
	}
	match (t.kind) {
		TypeKind.Ref | TypeKind.Var => sharedKeys(t.typeReturn, true, depth + 1, out),
		TypeKind.Array => {
			if (viaRef) addKey(out, arrayKey(t.typeReturn));
			sharedKeys(t.typeReturn, viaRef, depth + 1, out);
		},
		TypeKind.String => { if (viaRef) addKey(out, textKey()); },
		TypeKind.Struct | TypeKind.Tuple | TypeKind.Union | TypeKind.Result => {
			for (const c of t.typeChildren) { sharedKeys(c, viaRef, depth + 1, out); }
		},
		TypeKind.GenericInstance => {
			if (t.typeChildren.length == 0 && t.typeReturn != null) {
				sharedKeys(t.typeReturn, viaRef, depth + 1, out);
			} else {
				for (const c of t.typeChildren) { sharedKeys(c, viaRef, depth + 1, out); }
			}
		},
		TypeKind.SizedArray | TypeKind.Alias | TypeKind.Distinct | TypeKind.Sink | TypeKind.Lent => sharedKeys(t.typeReturn, viaRef, depth + 1, out),
		TypeKind.GenericParam | TypeKind.Unknown | TypeKind.TypeReference | TypeKind.Pending => addKey(out, anyKey()),
		_ => {},
	};
}

function keysOf(t: Type | null, viaRef: boolean): HandleKey[] {
	const out: HandleKey[] = [];
	sharedKeys(t, viaRef, 0, out);
	return out;
}

function handlePaths(t: Type | null, keys: HandleKey[], viaRef: boolean, depth: int32, prefix: string, out: string[]): void {
	if (t == null || depth > 6) {
		if (!out.includes(prefix)) out.push(prefix);
		return;
	}
	const whole = (inner: string[]): void => {
		if (inner.length > 0 && !out.includes(prefix)) out.push(prefix);
	};
	match (t.kind) {
		TypeKind.Ref | TypeKind.Var => handlePaths(t.typeReturn, keys, true, depth + 1, prefix, out),
		TypeKind.Array => {
			if (viaRef && matchesAnyKey(arrayKey(t.typeReturn), keys) && !out.includes(prefix)) out.push(prefix);
			handlePaths(t.typeReturn, keys, viaRef, depth + 1, prefix + "[]", out);
		},
		TypeKind.String => { if (viaRef && matchesAnyKey(textKey(), keys) && !out.includes(prefix)) out.push(prefix); },
		TypeKind.Struct => {
			for (let i = 0; i < t.typeChildren.length; i += 1) {
				const name = i < t.typeNames.length ? t.typeNames[i] : "";
				if (name != "") {
					handlePaths(t.typeChildren[i], keys, viaRef, depth + 1, prefix + "." + name, out);
				} else {
					const inner: string[] = [];
					handlePaths(t.typeChildren[i], keys, viaRef, depth + 1, prefix, inner);
					whole(inner);
				}
			}
		},
		TypeKind.SizedArray => handlePaths(t.typeReturn, keys, viaRef, depth + 1, prefix + "[]", out),
		TypeKind.Tuple => {
			for (const c of t.typeChildren) { handlePaths(c, keys, viaRef, depth + 1, prefix + "[]", out); }
		},
		TypeKind.Union | TypeKind.Result | TypeKind.GenericInstance => {
			const inner: string[] = [];
			if (t.kind == TypeKind.GenericInstance && t.typeChildren.length == 0 && t.typeReturn != null) {
				handlePaths(t.typeReturn, keys, viaRef, depth + 1, prefix, inner);
			} else {
				for (const c of t.typeChildren) { handlePaths(c, keys, viaRef, depth + 1, prefix, inner); }
			}
			whole(inner);
		},
		TypeKind.Alias | TypeKind.Distinct | TypeKind.Sink | TypeKind.Lent => handlePaths(t.typeReturn, keys, viaRef, depth + 1, prefix, out),
		TypeKind.GenericParam | TypeKind.Unknown | TypeKind.TypeReference | TypeKind.Pending => { if (keys.length > 0 && !out.includes(prefix)) out.push(prefix); },
		_ => {},
	};
}

function effectKeys(available: HandleKey[], s: ResizeSummary): HandleKey[] {
	if (s.unknown) return available;
	const out: HandleKey[] = [];
	for (const k of available) {
		if (matchesAnyKey(k, s.keys)) addKey(out, k);
	}
	return out;
}

function isDispatched(sym: Symbol): boolean {
	const entry = dispatchEntryFor(sym);
	if (entry == null) return false;
	return !entry.overloaded && dispatchOverridesFor(entry.classSym, entry.methodName).length > 0;
}

function reachesNonText(t: Type | null): boolean {
	for (const k of keysOf(t, false)) {
		if (!k.text) return true;
	}
	return false;
}

function externSummary(sym: Symbol): ResizeSummary {
	const t = sym.symbolType;
	if (t == null || t.kind != TypeKind.Function) return anyResize();
	for (const formal of t.typeChildren) {
		if (reachesNonText(formal)) return anyResize();
	}
	return noResize();
}

function calleeSummary(call: Node): ResizeSummary {
	const sym = call.resolvedSym;
	if (sym == null) return anyResize();
	if (sym.symbolKind != SymbolKind.Function && sym.symbolKind != SymbolKind.Method) return anyResize();
	if (hasFlag(sym, SymbolFlag.GeneratedOp)) return noResize();
	if (isDispatched(sym)) return anyResize();
	if (routineBody(sym.declNode) == null) {
		if (receiverOf(call) != null && !hasFlag(sym, SymbolFlag.ImportC)) return noResize();
		return externSummary(sym);
	}
	return summaryOf(sym);
}

export function calleeMayWrite(call: Node): boolean {
	const s = calleeSummary(call);
	return s.unknown || s.writes || s.keys.length > 0;
}

function constructorOf(newNode: Node): Node | null {
	const sym = newNode.resolvedSym;
	if (sym == null || sym.declNode == null || sym.declNode.kind != NodeKind.ClassDecl) return null;
	for (const m of (sym.declNode.data as { classBody: Node[] }).classBody) {
		if (m.kind == NodeKind.ConstructorDecl) return m;
	}
	return null;
}

function newSummary(node: Node): ResizeSummary {
	const ctor = constructorOf(node);
	if (ctor != null) {
		recordBodyRead(node.resolvedSym!.modulePath);
		const s = noResize();
		const body = routineBody(ctor);
		const fresh: Symbol[] = [];
		if (node.resolvedSym != null) fresh.push(node.resolvedSym);
		freshLocals(body, fresh);
		scanResizes(body, s, fresh);
		return s;
	}
	for (const a of (node.data as NewExprData).newArguments) {
		if (reachesNonText(a.nodeType)) return anyResize();
	}
	return noResize();
}

function joinSummary(s: ResizeSummary, c: ResizeSummary): void {
	if (c.unknown) {
		s.unknown = true;
		return;
	}
	for (const k of c.keys) { addKey(s.keys, k); }
	if (c.writes) s.writes = true;
}

function freshLocals(node: Node | null, out: Symbol[]): void {
	if (node == null) return;
	if (node.kind == NodeKind.VariableDecl && node.resolvedSym != null && !hasFlag(node.resolvedSym, SymbolFlag.Mutable)) {
		const init = peelConv((node.data as VariableDeclData).initializer);
		if (init != null && (init.kind == NodeKind.NewExpr || init.kind == NodeKind.ObjectLiteral || init.kind == NodeKind.ArrayLiteral)) out.push(node.resolvedSym);
	}
	forEachChild(node, (child: Node): void => { freshLocals(child, out); });
}

function writesShared(target: Node | null, fresh: Symbol[]): boolean {
	const t = peelConv(target);
	if (t == null) return false;
	if (t.kind == NodeKind.Identifier) return t.resolvedSym != null && t.resolvedSym.symbolType != null && t.resolvedSym.symbolType.kind == TypeKind.Var;
	const base = peelConv(t.kind == NodeKind.MemberExpr ? (t.data as MemberExprData).object : t.kind == NodeKind.ArrayAccess ? (t.data as ArrayAccessData).array : null);
	return base == null || base.kind != NodeKind.Identifier || base.resolvedSym == null || !fresh.includes(base.resolvedSym);
}

function spawnsInlineThunk(call: Node): boolean {
	const args = (call.data as CallExprData).arguments;
	if (!isSpawnCall(call) || args.length == 0) return false;
	const thunk = peelConv(args[0]);
	return thunk != null && (thunk.kind == NodeKind.ArrowFunction || thunk.kind == NodeKind.FunctionExpr);
}

function scanResizes(node: Node | null, s: ResizeSummary, fresh: Symbol[]): void {
	if (node == null || s.unknown) return;
	match (node.kind) {
		NodeKind.CallExpr => {
			const recv = receiverOf(node);
			if (recv != null && resizesReceiver(node, recv)) {
				const r = peelConv(recv);
				if (r == null || r.kind != NodeKind.Identifier || r.resolvedSym == null || !fresh.includes(r.resolvedSym)) s.writes = true;
				const t = recv.nodeType;
				const held = t != null && t.kind == TypeKind.Ref && t.typeReturn != null ? t.typeReturn : t;
				addKey(s.keys, held != null && held.kind == TypeKind.Array ? arrayKey(held.typeReturn) : textKey());
			} else if (!spawnsInlineThunk(node)) {
				joinSummary(s, calleeSummary(node));
			}
		},
		NodeKind.NewExpr => joinSummary(s, newSummary(node)),
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			if (isAssignOp(d.operator)) {
				replacedKeys(d.left, s);
				if (writesShared(d.left, fresh)) s.writes = true;
			}
		},
		NodeKind.UpdateExpr => { if (writesShared((node.data as UpdateExprData).updateArg, fresh)) s.writes = true; },
		NodeKind.MoveExpr => {
			replacedKeys((node.data as MoveExprData).moveArg, s);
			if (writesShared((node.data as MoveExprData).moveArg, fresh)) s.writes = true;
		},
		_ => {},
	};
	if (s.unknown) return;
	forEachChild(node, (child: Node): void => { scanResizes(child, s, fresh); });
}

function replacedKeys(target: Node | null, s: ResizeSummary): void {
	if (target == null) return;
	const byRef = target.kind == NodeKind.Identifier && target.resolvedSym != null
		&& target.resolvedSym.symbolType != null && target.resolvedSym.symbolType.kind == TypeKind.Var;
	if (target.kind != NodeKind.MemberExpr && target.kind != NodeKind.ArrayAccess && !byRef) return;
	for (const k of keysOf(target.nodeType, true)) { addKey(s.keys, k); }
}

function sameSummary(a: ResizeSummary, b: ResizeSummary): boolean {
	if (a.unknown != b.unknown || a.writes != b.writes || a.keys.length != b.keys.length) return false;
	for (const k of a.keys) {
		if (!matchesAnyKey(k, b.keys)) return false;
	}
	return true;
}

function scanRoutine(sym: Symbol): ResizeSummary {
	recordBodyRead(sym.modulePath);
	const s = noResize();
	resizeStack.push(sym);
	const body = routineBody(sym.declNode);
	const fresh: Symbol[] = [];
	freshLocals(body, fresh);
	scanResizes(body, s, fresh);
	resizeStack.pop();
	return s;
}

function summaryOf(sym: Symbol): ResizeSummary {
	const done = resizeDone.get(sym);
	if (done != null) return done;
	if (resizeStack.includes(sym)) {
		resizeCyclic = true;
		const open = resizeOpen.get(sym);
		return open != null ? open : noResize();
	}
	const seen = resizeOpen.get(sym);
	if (seen != null) return seen;
	const s = scanRoutine(sym);
	resizeOpen.set(sym, s);
	if (resizeStack.length > 0) return s;
	let changed = resizeCyclic;
	while (changed) {
		changed = false;
		const pending: Symbol[] = [];
		for (const k of resizeOpen.keys()) { pending.push(k); }
		for (const k of pending) {
			const next = scanRoutine(k);
			if (!sameSummary(next, resizeOpen.get(k)!)) {
				resizeOpen.set(k, next);
				changed = true;
			}
		}
	}
	for (const k of resizeOpen.keys()) { resizeDone.set(k, resizeOpen.get(k)!); }
	resizeOpen = new HashMap<Symbol, ResizeSummary>();
	resizeCyclic = false;
	return resizeDone.get(sym)!;
}

interface PendingLend {
	input: int32;
	capture: Symbol | null;
	task: Node;
}

const THIS_INPUT: int32 = -1;
const CAPTURE_INPUT: int32 = -2;

let pendingDone = new HashMap<Node, PendingLend[]>();
let pendingOpen = new HashMap<Node, PendingLend[]>();
let pendingStack: Node[] = [];
let pendingCyclic = false;

function routineFlagsOf(decl: Node): string {
	return match (decl.kind) {
		NodeKind.FunctionDecl => (decl.data as FunctionDeclData).fnFlags,
		NodeKind.MethodDecl => (decl.data as MethodDeclData).methodFlags,
		NodeKind.ArrowFunction => (decl.data as ArrowFunctionData).arrowFlags,
		NodeKind.FunctionExpr => (decl.data as FunctionExprData).funcExprFlags,
		_ => "",
	};
}

function isAsyncRoutine(decl: Node): boolean {
	const flags = routineFlagSet(routineFlagsOf(decl));
	return flags.has(RoutineFlag.Async) && !flags.has(RoutineFlag.Generator);
}

function pendingLends(decl: Node): PendingLend[] {
	const done = pendingDone.get(decl);
	if (done != null) return done;
	if (pendingStack.includes(decl)) {
		pendingCyclic = true;
		const open = pendingOpen.get(decl);
		return open != null ? open : [];
	}
	const seen = pendingOpen.get(decl);
	if (seen != null) return seen;
	const s = scanPending(decl);
	pendingOpen.set(decl, s);
	if (pendingStack.length > 0) return s;
	let changed = pendingCyclic;
	while (changed) {
		changed = false;
		const keys: Node[] = [];
		for (const k of pendingOpen.keys()) { keys.push(k); }
		for (const k of keys) {
			const next = scanPending(k);
			if (next.length != pendingOpen.get(k)!.length) {
				pendingOpen.set(k, next);
				changed = true;
			}
		}
	}
	for (const k of pendingOpen.keys()) { pendingDone.set(k, pendingOpen.get(k)!); }
	pendingOpen = new HashMap<Node, PendingLend[]>();
	pendingCyclic = false;
	return pendingDone.get(decl)!;
}

function isNestedRoutineNode(n: Node): boolean {
	return n.kind == NodeKind.FunctionDecl || n.kind == NodeKind.ArrowFunction || n.kind == NodeKind.FunctionExpr
		|| n.kind == NodeKind.ClassDecl || n.kind == NodeKind.MethodDecl || n.kind == NodeKind.ConstructorDecl;
}

function declaredIn(node: Node | null, out: Symbol[]): void {
	if (node == null) return;
	if (node.paramSyms != null) {
		for (const s of node.paramSyms) { out.push(s); }
	}
	if ((node.kind == NodeKind.VariableDecl || node.kind == NodeKind.ForOfStmt || node.kind == NodeKind.TryCatchStmt) && node.resolvedSym != null) out.push(node.resolvedSym);
	if (node.kind == NodeKind.ArrayPattern || node.kind == NodeKind.ObjectPattern) {
		patternSyms(node, out);
		return;
	}
	forEachChild(node, (child: Node): void => { declaredIn(child, out); });
}

function patternSyms(node: Node, out: Symbol[]): void {
	if (node.kind == NodeKind.Identifier && node.resolvedSym != null) out.push(node.resolvedSym);
	forEachChild(node, (child: Node): void => { patternSyms(child, out); });
}

function aliasEdges(node: Node | null, from: Symbol[], to: Node[]): void {
	if (node == null) return;
	if (node.kind == NodeKind.VariableDecl && node.resolvedSym != null) {
		from.push(node.resolvedSym);
		to.push((node.data as VariableDeclData).initializer);
	} else if (node.kind == NodeKind.ForOfStmt && node.resolvedSym != null) {
		from.push(node.resolvedSym);
		to.push((node.data as ForOfStmtData).forOfIterable);
	} else if (node.kind == NodeKind.BinaryExpr && isAssignOp((node.data as BinaryExprData).operator)) {
		const d = node.data as BinaryExprData;
		const target = peelConv(d.left);
		if (target != null && target.kind == NodeKind.Identifier && target.resolvedSym != null) {
			from.push(target.resolvedSym);
			to.push(d.right);
		}
	}
	forEachChild(node, (child: Node): void => { aliasEdges(child, from, to); });
}

interface PendingScan {
	decl: Node;
	params: Symbol[];
	declared: Symbol[];
	from: Symbol[];
	to: Node[];
	out: PendingLend[];
}

function addPending(s: PendingScan, input: int32, capture: Symbol | null, task: Node): void {
	for (const l of s.out) {
		if (l.input == input && l.capture == capture) return;
	}
	s.out.push({ input, capture, task });
}

function lendInput(s: PendingScan, root: Symbol, task: Node, seen: Symbol[]): void {
	if (seen.includes(root)) return;
	seen.push(root);
	const at = s.params.indexOf(root);
	if (at >= 0) {
		addPending(s, at as int32, null, task);
	} else if (root.name == "this" && s.decl.kind == NodeKind.MethodDecl && !s.declared.includes(root)) {
		addPending(s, THIS_INPUT, null, task);
	} else if (s.declared.includes(root)) {
		for (let i = 0; i < s.from.length; i += 1) {
			if (s.from[i] != root || !carriesPointer(root.symbolType)) continue;
			const sources: Symbol[] = [];
			rootsOf(s.to[i], sources);
			for (const src of sources) { lendInput(s, src, task, seen); }
		}
	} else if (lendable(root) && !hasFlag(root, SymbolFlag.Global)) {
		addPending(s, CAPTURE_INPUT, root, task);
	}
}

function scanPendingBody(s: PendingScan, node: Node | null): void {
	if (node == null || isNestedRoutineNode(node)) return;
	if (node.kind == NodeKind.CallExpr) {
		const args = (node.data as CallExprData).arguments;
		if (isSpawnCall(node)) {
			if (!node.flags.has(NodeFlag.Isolated) && args.length > 0) {
				const roots: Symbol[] = [];
				const inner: Symbol[] = [];
				innerParams(args[0], inner);
				lentRoots(null, args[0], inner, roots, []);
				for (const r of roots) { lendInput(s, r, node, []); }
			}
		} else {
			const roots: Symbol[] = [];
			const tasks: Node[] = [];
			callLentRoots(node, roots, tasks);
			for (let i = 0; i < roots.length; i += 1) { lendInput(s, roots[i], tasks[i], []); }
		}
	}
	forEachChild(node, (child: Node): void => { scanPendingBody(s, child); });
}

function scanPending(decl: Node): PendingLend[] {
	const out: PendingLend[] = [];
	const body = routineBody(decl);
	if (body == null || !isAsyncRoutine(decl)) return out;
	pendingStack.push(decl);
	const declared: Symbol[] = [];
	declaredIn(body, declared);
	const s: PendingScan = { decl, params: decl.paramSyms ?? [], declared, from: [], to: [], out };
	aliasEdges(body, s.from, s.to);
	scanPendingBody(s, body);
	pendingStack.pop();
	return out;
}

function isMessageSend(call: Node): boolean {
	const recv = receiverOf(call);
	if (recv == null) return false;
	const r = peelConv(recv);
	if (r != null && r.kind == NodeKind.Identifier && (r.data as IdentifierData).name == "this") return false;
	const t = recv.nodeType;
	return t != null && t.sym != null && t.sym.symbolKind == SymbolKind.Actor;
}

function pendingOfCall(call: Node): PendingLend[] {
	if (isSpawnCall(call) || isMessageSend(call)) return [];
	const callee = peelConv((call.data as CallExprData).callee);
	if (callee != null && (callee.kind == NodeKind.ArrowFunction || callee.kind == NodeKind.FunctionExpr)) return pendingLends(callee);
	return call.resolvedSym != null ? pendingOfRoutine(call.resolvedSym) : [];
}

function pendingOfRoutine(sym: Symbol): PendingLend[] {
	if (sym.declNode == null || (sym.symbolKind != SymbolKind.Function && sym.symbolKind != SymbolKind.Method)) return [];
	recordBodyRead(sym.modulePath);
	const own = pendingLends(sym.declNode);
	const entry = dispatchEntryFor(sym);
	if (entry == null || entry.overloaded) return own;
	const all: PendingLend[] = [];
	for (const l of own) { all.push(l); }
	for (const o of dispatchOverridesFor(entry.classSym, entry.methodName)) {
		if (o.sym.declNode == null) continue;
		recordBodyRead(o.sym.modulePath);
		for (const l of pendingLends(o.sym.declNode)) { all.push(l); }
	}
	return all;
}

function lentArgument(call: Node, input: int32): Node | null {
	const args = (call.data as CallExprData).arguments;
	if (input == THIS_INPUT) return call.flags.has(NodeFlag.ExtCall) ? null : receiverOf(call);
	if (call.flags.has(NodeFlag.ExtCall)) return input == 0 ? receiverOf(call) : (input - 1 < args.length ? args[input - 1] : null);
	return input < args.length ? args[input] : null;
}

function callLentRoots(call: Node, roots: Symbol[], tasks: Node[]): void {
	for (const l of pendingOfCall(call)) {
		const found: Symbol[] = [];
		if (l.input == CAPTURE_INPUT) {
			found.push(l.capture!);
		} else {
			const arg = lentArgument(call, l.input);
			if (arg != null && carriesPointer(arg.nodeType)) rootsOf(arg, found);
		}
		for (const r of found) {
			if (roots.includes(r) || !lendable(r)) continue;
			roots.push(r);
			tasks.push(l.task);
		}
	}
}

function lendsPastCall(call: Node, atModule: boolean): boolean {
	const roots: Symbol[] = [];
	callLentRoots(call, roots, []);
	for (const r of roots) {
		if (atModule || !hasFlag(r, SymbolFlag.Global)) return true;
	}
	return false;
}

interface BorrowUnit {
	p: Partitions;
	pass: int32;
	scope: int32[];
	defers: Node[];
	ctx: CheckerContext;
	pointers: Symbol[];
	blocks: Node[];
	captured: Symbol[];
	routines: Node[];
	suspends: int32[];
	suspendSites: Node[];
	escaped: Symbol[];
	lends: Lend[];
	closerSites: Node[];
	closerAwaits: Node[];
	thunks: Node[];
	writers: Symbol[];
	callWrites: CallWrite[];
	worker: boolean;
}

interface CallWrite {
	time: int32;
	roots: Symbol[];
	site: Node;
}

interface Lend {
	site: Node;
	handle: Symbol | null;
	roots: Symbol[];
	start: int32;
	end: int32;
	closer: Node | null;
	scope: int32[];
	bounds: Symbol[];
	tasks: Node[];
	callee: string;
}

function isBorrower(u: BorrowUnit, sym: Symbol): boolean {
	if (isViewType(sym.symbolType)) return true;
	for (const p of u.pointers) { if (p == sym) return true; }
	return false;
}

function takesAddress(node: Node | null): boolean {
	let n = node;
	while (n != null && (n.kind == NodeKind.HiddenStdConv || n.kind == NodeKind.HiddenSubConv)) {
		n = (n.data as HiddenStdConvData).convExpr;
	}
	return n != null && isAddressTaking(n);
}


export function carriesPointer(t: Type | null, depth: int32 = 0): boolean {
	if (t == null || depth > 8) return true;
	if (isPrimitiveKind(t.kind)) return false;
	return match (t.kind) {
		TypeKind.String | TypeKind.BigInt | TypeKind.Enum | TypeKind.EnumLiteral | TypeKind.StringLiteral
			| TypeKind.BooleanLiteral | TypeKind.Function => false,
		TypeKind.Struct | TypeKind.Tuple | TypeKind.Union | TypeKind.Result => {
			for (const c of t.typeChildren) {
				if (carriesPointer(c, depth + 1)) return true;
			}
			return false;
		},
		TypeKind.GenericInstance => t.typeReturn != null ? carriesPointer(t.typeReturn, depth + 1) : anyChildCarries(t, depth),
		TypeKind.Array | TypeKind.Span | TypeKind.SizedArray | TypeKind.Sink | TypeKind.Lent | TypeKind.Alias
			| TypeKind.Distinct => carriesPointer(t.typeReturn != null ? t.typeReturn : (t.typeChildren.length > 0 ? t.typeChildren[0] : null), depth + 1),
		_ => true,
	};
}

function anyChildCarries(t: Type, depth: int32): boolean {
	for (const c of t.typeChildren) {
		if (carriesPointer(c, depth + 1)) return true;
	}
	return false;
}

function ownsStorage(t: Type | null, depth: int32 = 0): boolean {
	if (t == null || depth > 8) return false;
	return match (t.kind) {
		TypeKind.String | TypeKind.Array | TypeKind.Ref | TypeKind.BigInt => true,
		TypeKind.Struct | TypeKind.Tuple | TypeKind.Union | TypeKind.Result => {
			for (const c of t.typeChildren) {
				if (ownsStorage(c, depth + 1)) return true;
			}
			return false;
		},
		TypeKind.SizedArray | TypeKind.Alias | TypeKind.Distinct | TypeKind.Sink => ownsStorage(t.typeReturn, depth + 1),
		TypeKind.GenericInstance => t.typeReturn != null ? ownsStorage(t.typeReturn, depth + 1) : true,
		TypeKind.GenericParam | TypeKind.Unknown => true,
		_ => false,
	};
}

function isAssignOp(op: string): boolean {
	return match (op) {
		"=" | "+=" | "-=" | "*=" | "/=" | "%=" | "**=" | "<<=" | ">>=" | ">>>=" | "&=" | "|=" | "^=" | "&&=" | "||=" | "??=" => true,
		_ => false,
	};
}

function rootsOf(node: Node | null, out: Symbol[]): void {
	if (node == null) return;
	match (node.kind) {
		NodeKind.Identifier => { if (node.resolvedSym != null) out.push(node.resolvedSym); },
		NodeKind.MemberExpr => rootsOf((node.data as MemberExprData).object, out),
		NodeKind.ArrayAccess => rootsOf((node.data as ArrayAccessData).array, out),
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => rootsOf((node.data as { expr: Node }).expr, out),
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => rootsOf((node.data as HiddenStdConvData).convExpr, out),
		NodeKind.TypeAssertion => rootsOf((node.data as TypeAssertionData).asExpr, out),
		NodeKind.MoveExpr => rootsOf((node.data as MoveExprData).moveArg, out),
		NodeKind.OutExpr => rootsOf((node.data as OutExprData).outArg, out),
		NodeKind.ConditionalExpr => {
			const d = node.data as { ternaryCondition: Node, ternaryConsequent: Node, ternaryAlternate: Node };
			rootsOf(d.ternaryConsequent, out);
			rootsOf(d.ternaryAlternate, out);
		},
		NodeKind.ArrayLiteral => { for (const e of (node.data as ArrayLiteralData).elements) { if (carriesPointer(e.nodeType)) rootsOf(e, out); } },
		NodeKind.ObjectLiteral => { for (const e of (node.data as ObjectLiteralData).properties) { if (carriesPointer(e.nodeType)) rootsOf(e, out); } },
		NodeKind.NewExpr => {
			if (carriesPointer(node.nodeType)) {
				for (const a of (node.data as NewExprData).newArguments) {
					if (carriesPointer(a.nodeType)) rootsOf(a, out);
				}
			}
		},
		NodeKind.CallExpr => {
			if (carriesPointer(node.nodeType)) {
				const d = node.data as CallExprData;
				const recv = receiverOf(node);
				if (recv != null && carriesPointer(recv.nodeType)) rootsOf(recv, out);
				for (const a of d.arguments) {
					if (carriesPointer(a.nodeType)) rootsOf(a, out);
				}
			}
		},
		_ => {},
	};
}

function supplies(t: Type | null): boolean {
	if (t == null) return true;
	return isViewType(t) || t.kind == TypeKind.String || t.kind == TypeKind.SizedArray || ownsStorage(t);
}

function isSlice(n: Node): boolean {
	return n.kind == NodeKind.ArrayAccess && isViewType(n.nodeType);
}

const TEMP_PATH = "#";
const TEMP_OWNED = "#owned";
const TEMP_ARM = "#arm";

function isTempPath(p: string): boolean {
	return p.startsWith(TEMP_PATH);
}

function markArmTemps(out: Node[], paths: string[], from: int32, arms: Node[]): void {
	for (let k = from; k < paths.length; k += 1) {
		if (paths[k] == TEMP_PATH && !arms.includes(out[k])) paths[k] = TEMP_ARM;
	}
}

function armValue(n: Node | null): Node | null {
	let v = n;
	while (v != null && (v.kind == NodeKind.HiddenStdConv || v.kind == NodeKind.HiddenSubConv)) v = (v.data as HiddenStdConvData).convExpr;
	return v;
}

function isNamedPlace(node: Node): boolean {
	let n: Node | null = node;
	while (n != null) {
		match (n.kind) {
			NodeKind.Identifier => { return true; },
			NodeKind.MemberExpr => { n = (n.data as MemberExprData).object; },
			NodeKind.ArrayAccess => { n = (n.data as ArrayAccessData).array; },
			NodeKind.HiddenDeref | NodeKind.HiddenAddr => { n = (n.data as { expr: Node }).expr; },
			NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => { n = (n.data as HiddenStdConvData).convExpr; },
			_ => { return false; },
		};
	}
	return false;
}

function isBufferHandle(t: Type | null): boolean {
	if (t == null) return true;
	return match (t.kind) {
		TypeKind.String | TypeKind.Array | TypeKind.Ref | TypeKind.GenericParam | TypeKind.Unknown => true,
		TypeKind.Alias | TypeKind.Distinct => isBufferHandle(t.typeReturn),
		TypeKind.GenericInstance => t.typeReturn == null || isBufferHandle(t.typeReturn),
		_ => false,
	};
}

function relocate(handles: string, prefix: string): string {
	let out = "";
	for (const h of handles.split("|")) {
		if (h == "") continue;
		const at = h == "@" ? prefix : prefix + h;
		out = out + "|" + (at == "" ? "@" : at);
	}
	return out;
}

function pathSources(node: Node | null, out: Node[], paths: string[], handles: string[], suffix: string = ""): void {
	let n = node;
	let path = suffix;
	const handleAt: int32[] = [];
	while (n != null) {
		if (n.kind != NodeKind.HiddenStdConv && n.kind != NodeKind.HiddenSubConv && n.kind != NodeKind.TypeAssertion
			&& !isSlice(n) && isBufferHandle(n.nodeType) && n.kind != NodeKind.StringLiteral) {
			handleAt.push(path.length as int32);
		}
		match (n.kind) {
			NodeKind.Identifier => {
				out.push(n);
				paths.push(path);
				let found = "";
				for (const cut of handleAt) {
					const h = path.substring(0, path.length - cut);
					found = found + "|" + (h == "" ? "@" : h);
				}
				handles.push(found);
				return;
			},
			NodeKind.MemberExpr => {
				path = "." + (n.data as MemberExprData).property + path;
				n = (n.data as MemberExprData).object;
			},
			NodeKind.ArrayAccess => {
				if (!isSlice(n)) path = "[]" + path;
				n = (n.data as ArrayAccessData).array;
			},
			NodeKind.HiddenDeref | NodeKind.HiddenAddr => { n = (n.data as { expr: Node }).expr; },
			NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => { n = (n.data as HiddenStdConvData).convExpr; },
			NodeKind.TypeAssertion => {
				const inner = (n.data as TypeAssertionData).asExpr;
				if (isAddressTaking(n) && inner != null && inner.nodeType != null && inner.nodeType.kind == TypeKind.Span) {
					path = "[]" + path;
				}
				n = inner;
			},
			NodeKind.ConditionalExpr => {
				const d = n.data as ConditionalExprData;
				const from = paths.length;
				pathSources(d.ternaryConsequent, out, paths, handles, path);
				pathSources(d.ternaryAlternate, out, paths, handles, path);
				markArmTemps(out, paths, from, [armValue(d.ternaryConsequent)!, armValue(d.ternaryAlternate)!]);
				return;
			},
			NodeKind.MatchExpr => {
				const values: Node[] = [];
				for (const c of (n.data as MatchExprData).matchCases) { armValues((c.data as MatchCaseData).caseBody, values); }
				const from = paths.length;
				for (const v of values) { pathSources(v, out, paths, handles, path); }
				const armNodes: Node[] = [];
				for (const v of values) { const a = armValue(v); if (a != null) armNodes.push(a); }
				markArmTemps(out, paths, from, armNodes);
				return;
			},
			NodeKind.BinaryExpr => {
				const d = n.data as BinaryExprData;
				if (d.operator != "??" && d.operator != "||" && d.operator != "&&") {
					addTemp(n, out, paths, handles);
					return;
				}
				const from = paths.length;
				pathSources(d.left, out, paths, handles, path);
				pathSources(d.right, out, paths, handles, path);
				markArmTemps(out, paths, from, [armValue(d.left)!, armValue(d.right)!]);
				return;
			},
			NodeKind.CallExpr => {
				const recv = receiverOf(n);
				const args = (n.data as CallExprData).arguments;
				if (isViewType(n.nodeType)) {
					const first = recv != null ? recv : (args.length > 0 ? args[0] : null);
					const from = out.length;
					if (first != null) pathSources(first, out, paths, handles, "");
					if (first != null && !isNamedPlace(first) && !ownsNoStorage(first.nodeType)) {
						let marked = false;
						for (let k = from; k < out.length; k += 1) {
							if (isTempPath(paths[k])) {
								paths[k] = TEMP_OWNED;
								marked = true;
							}
						}
						if (!marked) {
							out.push(first);
							paths.push(TEMP_OWNED);
							handles.push("");
						}
					}
					if (first != null && reachesClass(first.nodeType, new TypeVisitSet())) {
						for (let k = from; k < out.length; k += 1) {
							if (!isTempPath(paths[k])) handles[k] = handles[k] + "|" + paths[k] + SUBTREE;
						}
					}
					return;
				}
				if (recv != null && supplies(recv.nodeType)) pathSources(recv, out, paths, handles, "");
				for (const a of args) {
					if (supplies(a.nodeType)) pathSources(a, out, paths, handles, "");
				}
				addTemp(n, out, paths, handles);
				return;
			},
			NodeKind.ObjectLiteral | NodeKind.ArrayLiteral => {
				const members = n.kind == NodeKind.ObjectLiteral ? (n.data as ObjectLiteralData).properties : (n.data as ArrayLiteralData).elements;
				for (let mi = 0; mi < members.length; mi += 1) {
					const m = members[mi];
					if (m.kind == NodeKind.SpreadExpr) {
						pathSources((m.data as SpreadExprData).spreadArg, out, paths, handles, "");
						continue;
					}
					const field = n.kind == NodeKind.ObjectLiteral ? literalFieldType(n, mi) : null;
					const known = field != null && field.kind != TypeKind.GenericParam && field.kind != TypeKind.Unknown;
					if (known ? isViewType(field) : supplies(m.nodeType)) pathSources(m, out, paths, handles, "");
				}
				addTemp(n, out, paths, handles);
				return;
			},
			_ => {
				addTemp(n, out, paths, handles);
				return;
			},
		};
	}
}

function armValues(body: Node | null, out: Node[]): void {
	if (body == null) return;
	match (body.kind) {
		NodeKind.BlockStmt => {
			const stmts = (body.data as BlockStmtData).statements;
			if (stmts.length > 0) armValues(stmts[stmts.length - 1], out);
		},
		NodeKind.ExprStmt => { out.push((body.data as ExprStmtData).expr); },
		NodeKind.IfStmt => {
			armValues((body.data as IfStmtData).consequent, out);
			armValues((body.data as IfStmtData).alternate, out);
		},
		NodeKind.ReturnStmt | NodeKind.ThrowStmt | NodeKind.BreakStmt | NodeKind.ContinueStmt | NodeKind.UnreachableStmt => {},
		_ => { out.push(body); },
	};
}

function reachesClass(t: Type | null, seen: TypeVisitSet): boolean {
	if (t == null || !typeVisitAdd(seen, t)) return false;
	if (isClassInstance(t)) return true;
	if (t.kind == TypeKind.Alias || t.kind == TypeKind.Distinct || t.kind == TypeKind.Var || t.kind == TypeKind.Array || t.kind == TypeKind.SizedArray) return reachesClass(t.typeReturn, seen);
	if (t.kind == TypeKind.GenericInstance) return reachesClass(t.typeReturn != null ? t.typeReturn : t.typeExtra, seen);
	if (t.kind == TypeKind.Struct || t.kind == TypeKind.Tuple || t.kind == TypeKind.Union) {
		for (const c of t.typeChildren) { if (reachesClass(c, seen)) return true; }
	}
	return false;
}

function isClassInstance(t: Type | null): boolean {
	const held = t != null && t.kind == TypeKind.Ref ? t.typeReturn : null;
	if (held == null || held.kind != TypeKind.Struct || held.sym == null) return false;
	const k = held.sym.symbolKind;
	return k == SymbolKind.Class || k == SymbolKind.Interface || k == SymbolKind.Actor;
}

function literalFieldType(lit: Node, index: int32): Type | null {
	let t = lit.nodeType;
	while (t != null && (t.kind == TypeKind.Alias || t.kind == TypeKind.Distinct || t.kind == TypeKind.Var || (t.kind == TypeKind.GenericInstance && t.typeReturn != null))) t = t.typeReturn;
	if (t == null || t.kind != TypeKind.Struct) return null;
	const d = lit.data as ObjectLiteralData;
	if (index >= d.keys.length) return null;
	const at = t.typeNames.indexOf(d.keys[index]);
	return at >= 0 && at < t.typeChildren.length ? t.typeChildren[at] : null;
}

function addTemp(n: Node, out: Node[], paths: string[], handles: string[]): void {
	out.push(n);
	paths.push(TEMP_PATH);
	handles.push("");
}

export function pathOf(node: Node | null): string {
	let n = node;
	let path = "";
	while (n != null) {
		match (n.kind) {
			NodeKind.MemberExpr => {
				path = "." + (n.data as MemberExprData).property + path;
				n = (n.data as MemberExprData).object;
			},
			NodeKind.ArrayAccess => {
				if (!isSlice(n)) path = "[]" + path;
				n = (n.data as ArrayAccessData).array;
			},
			NodeKind.HiddenDeref | NodeKind.HiddenAddr => { n = (n.data as { expr: Node }).expr; },
			NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => { n = (n.data as HiddenStdConvData).convExpr; },
			NodeKind.TypeAssertion => { n = (n.data as TypeAssertionData).asExpr; },
			NodeKind.MoveExpr => { n = (n.data as MoveExprData).moveArg; },
			NodeKind.OutExpr => { n = (n.data as OutExprData).outArg; },
			NodeKind.Identifier => { return path; },
			_ => { return ""; },
		};
	}
	return "";
}

function mutateRoots(u: BorrowUnit, node: Node | null, site: Node, suffix: string = "", mark: string = ""): void {
	const roots: Symbol[] = [];
	rootsOf(node, roots);
	const path = mark + (roots.length == 1 ? pathOf(node) + suffix : "");
	for (const r of roots) {
		const id = variableId(u.p, r);
		if (id >= 0 && !u.p.vars[id].external && isBorrower(u, r) && u.p.vars[id].borrowsFrom.length > 0) {
			const v = u.p.vars[id];
			for (let b = 0; b < v.borrowsFrom.length; b += 1) {
				potentialMutation(u.p, u.p.vars[v.borrowsFrom[b]].sym, site, mark + v.borrowPaths[b] + path.substring(mark.length, path.length));
			}
			continue;
		}
		potentialMutation(u.p, r, site, path);
	}
}

function withoutHandle(handles: string, at: string): string {
	const exact = at == "" ? "@" : at;
	let out = "";
	for (const h of handles.split("|")) {
		if (h != "" && h != exact) out = out + "|" + h;
	}
	return out;
}

function handOff(u: BorrowUnit, src: Node | null, keep: int32[]): void {
	let n = src;
	while (n != null && (n.kind == NodeKind.HiddenStdConv || n.kind == NodeKind.HiddenSubConv)) {
		n = (n.data as HiddenStdConvData).convExpr;
	}
	if (n == null || n.kind != NodeKind.Identifier || n.resolvedSym == null) return;
	if (!ownsStorage(n.resolvedSym.symbolType)) return;
	potentialMutation(u.p, n.resolvedSym, n, "", keep);
}

function scopeOf(u: BorrowUnit, sym: Symbol | null): int32[] {
	const id = variableId(u.p, sym);
	if (id < 0 || u.p.vars[id].external) return [];
	return u.p.vars[id].scopePath;
}

function currentScope(u: BorrowUnit): int32[] {
	const out: int32[] = [];
	for (const s of u.scope) { out.push(s); }
	return out;
}

function borrowFrom(u: BorrowUnit, dest: Symbol, src: Node): void {
	const vid = variableId(u.p, dest);
	if (vid < 0) return;
	const sources: Node[] = [];
	const paths: string[] = [];
	const handles: string[] = [];
	pathSources(src, sources, paths, handles);
	const pointer = !isViewType(dest.symbolType);
	const byAddress = dest.symbolType != null && dest.symbolType.kind == TypeKind.Borrow;
	for (let k = 0; k < sources.length; k += 1) {
		const s = sources[k];
		if (pointer) handles[k] = withoutHandle(handles[k], paths[k]);
		if (isTempPath(paths[k])) {
			if (holdsNoStorage(s) || (paths[k] != TEMP_OWNED && s.kind == NodeKind.ObjectLiteral && holdsLiteralByValue(dest.symbolType))) continue;
			if (paths[k] == TEMP_ARM) {
				addError(u.ctx, `'${dest.name}' borrows from a temporary made in a branch, which ends with its statement and does not live long enough`, src.location.line, src.location.column);
				return;
			}
			if (!encloses(u.scope, u.p.vars[vid].scopePath)) {
				addError(u.ctx, `'${dest.name}' borrows from a temporary that ends with its block, which does not live long enough`, src.location.line, src.location.column);
				return;
			}
			u.p.vars[vid].fromTemp = true;
			continue;
		}
		const sym = s.resolvedSym;
		if (sym == null) continue;
		if (hasFlag(sym, SymbolFlag.Global)) {
			const fixed = !hasFlag(sym, SymbolFlag.Mutable);
			if ((pointer || (byAddress && fixed)) && staysPut(sym, withoutHandle(handles[k], paths[k]))) continue;
			if (!pointer && !byAddress && fixed && keysOf(sym.symbolType, false).length == 0) continue;
			addError(u.ctx, `cannot borrow '${dest.name}' from module-level '${sym.name}': a call can change it unseen; pass it as a parameter`, src.location.line, src.location.column);
			return;
		}
		const sid = variableId(u.p, sym);
		if (sid < 0) continue;
		const from = u.p.vars[sid];
		if (!from.external && from.sym != dest && isBorrower(u, from.sym)) {
			if (from.fromTemp) u.p.vars[vid].fromTemp = true;
			for (let b = 0; b < from.borrowsFrom.length; b += 1) {
				const base = from.borrowPaths[b];
				const at = base + paths[k];
				addBorrow(u.p.vars[vid], from.borrowsFrom[b], at, from.borrowHandles[b] + relocate(handles[k], base) + (byAddress ? placeHandles(at) : ""));
			}
			continue;
		}
		addBorrow(u.p.vars[vid], sid, paths[k], handles[k] + (byAddress ? placeHandles(paths[k]) : ""));
	}
}

function holdsNoStorage(n: Node): boolean {
	return isNullArm(n) || (n.kind == NodeKind.ArrayLiteral && (n.data as ArrayLiteralData).elements.length == 0) || n.kind == NodeKind.NumberLiteral || n.kind == NodeKind.BooleanLiteral || n.kind == NodeKind.StringLiteral;
}

function holdsLiteralByValue(t: Type | null): boolean {
	const held = t != null && t.kind == TypeKind.Var ? t.typeReturn : t;
	return isViewStruct(withoutNullMember(held!));
}

function placeHandles(path: string): string {
	return "|" + VALUE_WRITE + path + "|" + (path == "" ? "@" : path);
}

function addBorrow(v: VarEntry, sid: int32, path: string, handles: string): void {
	for (let i = 0; i < v.borrowsFrom.length; i += 1) {
		if (v.borrowsFrom[i] == sid && v.borrowPaths[i] == path) {
			v.borrowHandles[i] = v.borrowHandles[i] + handles;
			return;
		}
	}
	v.borrowsFrom.push(sid);
	v.borrowPaths.push(path);
	v.borrowHandles.push(handles);
}

function deps(u: BorrowUnit, dest: Symbol | null, src: Node | null): void {
	if (dest == null || src == null) return;
	const view = isBorrower(u, dest);
	if (view) borrowFrom(u, dest, src);
	else handOff(u, src, scopeOf(u, dest));
	if (carriesPointer(dest.symbolType)) {
		const sources: Symbol[] = [];
		rootsOf(src, sources);
		for (const s of sources) { ufConnect(u.p, dest, s); }
	}
}

function assign(u: BorrowUnit, node: Node, d: BinaryExprData): void {
	const left = d.left;
	refuseViewWriteThroughRefParam(u, d);
	if (left.kind == NodeKind.Identifier && left.resolvedSym != null) {
		const sym = left.resolvedSym;
		if (d.operator == "=" && isBorrower(u, sym)) {
			borrowFrom(u, sym, d.right);
			return;
		}
		potentialMutation(u.p, sym, d.left, ownsStorage(sym.symbolType) ? "" : VALUE_WRITE);
		if (d.operator == "=") {
			deps(u, sym, d.right);
			if (reachableByCalls(u, sym, "")) escape(u, d.right);
		}
		return;
	}
	if (d.operator == "=" && (left.kind == NodeKind.ArrayLiteral || left.kind == NodeKind.ObjectLiteral)) assignPattern(u, left, d.right);
	mutateRoots(u, left, d.left, "", ownsStorage(left.nodeType) ? "" : VALUE_WRITE);
	if (d.operator != "=") return;
	const targets0: Symbol[] = [];
	rootsOf(left, targets0);
	if (targets0.length == 1 && isViewType(left.nodeType) && isBorrower(u, targets0[0])) borrowFrom(u, targets0[0], d.right);
	if (targets0.length != 1 || reachableByCalls(u, targets0[0], pathOf(left))) escape(u, d.right);
	handOff(u, d.right, targets0.length == 1 ? scopeOf(u, targets0[0]) : NO_KEEP);
	if (carriesPointer(left.nodeType)) {
		const targets: Symbol[] = [];
		rootsOf(left, targets);
		const sources: Symbol[] = [];
		rootsOf(d.right, sources);
		for (const t of targets) {
			for (const s of sources) { ufConnect(u.p, t, s); }
		}
	}
}

function reachableByCalls(u: BorrowUnit, root: Symbol, path: string): boolean {
	if (hasFlag(root, SymbolFlag.Global)) return true;
	const id = variableId(u.p, root);
	if (id < 0 || u.p.vars[id].external) return true;
	return path != "" && crossesRef(root.symbolType, path);
}

function escapeSym(u: BorrowUnit, sym: Symbol, captured: boolean): void {
	const list = captured ? u.captured : u.escaped;
	if (variableId(u.p, sym) >= 0 && keysOf(sym.symbolType, captured).length > 0 && !list.includes(sym)) list.push(sym);
}

function escape(u: BorrowUnit, src: Node | null): void {
	const sources: Symbol[] = [];
	rootsOf(src, sources);
	for (const s of sources) { escapeSym(u, s, false); }
}

function holdsKeys(t: Type | null): HandleKey[] {
	if (t == null) return [anyKey()];
	const viaRef = t.kind == TypeKind.Ref || t.kind == TypeKind.Var;
	const inner = viaRef ? t.typeReturn : t;
	if (inner == null) return [anyKey()];
	const out: HandleKey[] = [];
	if (inner.kind == TypeKind.Array || inner.kind == TypeKind.SizedArray) {
		sharedKeys(inner.typeReturn, true, 1, out);
	} else if (inner.kind == TypeKind.Struct || inner.kind == TypeKind.Tuple) {
		for (const c of inner.typeChildren) { sharedKeys(c, viaRef, 1, out); }
	} else {
		sharedKeys(inner, true, 1, out);
	}
	return out;
}

function storedIntoOther(u: BorrowUnit, args: Node[], summary: ResizeSummary): void {
	if (args.length < 2 || (!summary.unknown && summary.keys.length == 0)) return;
	for (let i = 0; i < args.length; i += 1) {
		const own = keysOf(args[i].nodeType, false);
		if (own.length == 0) continue;
		for (let j = 0; j < args.length; j += 1) {
			if (j != i && keysMeet(own, holdsKeys(args[j].nodeType))) {
				escape(u, args[i]);
				break;
			}
		}
	}
}

function changeSym(u: BorrowUnit, sym: Symbol, viaRef: boolean, summary: ResizeSummary, site: Node): void {
	if (isBorrower(u, sym)) return;
	const keys = effectKeys(keysOf(sym.symbolType, viaRef), summary);
	if (keys.length == 0) return;
	const paths: string[] = [];
	handlePaths(sym.symbolType, keys, viaRef, 0, "", paths);
	for (const p of paths) { potentialMutation(u.p, sym, site, p); }
}

function changeEscaped(u: BorrowUnit, site: Node, summary: ResizeSummary, runsClosures: boolean): void {
	for (const sym of u.escaped) { changeSym(u, sym, false, summary, site); }
	if (!runsClosures) return;
	for (const sym of u.captured) { changeSym(u, sym, true, summary, site); }
}

export function formalAt(fnType: Type | null, i: int32): Type | null {
	if (fnType == null || fnType.kind != TypeKind.Function) return null;
	const n = fnType.typeChildren.length;
	if (n == 0) return null;
	if (i < n - 1) return fnType.typeChildren[i];
	const last = fnType.typeChildren[n - 1];
	if (last != null && last.kind == TypeKind.Varargs) return null;
	return i < n ? fnType.typeChildren[i] : null;
}

function reachesBorrowed(u: BorrowUnit, v: VarEntry, keys: HandleKey[]): boolean {
	for (let b = 0; b < v.borrowsFrom.length; b += 1) {
		if (keysMeet(borrowedKeys(u.p.vars[v.borrowsFrom[b]].sym, v.borrowHandles[b]), keys)) return true;
	}
	return false;
}

function changeReachable(u: BorrowUnit, arg: Node, t: Type | null, viaRef: boolean, summary: ResizeSummary): void {
	const keys = effectKeys(keysOf(t, viaRef), summary);
	if (keys.length == 0) return;
	const roots: Symbol[] = [];
	rootsOf(arg, roots);
	if (roots.length == 1) {
		const id = variableId(u.p, roots[0]);
		if (id >= 0 && !u.p.vars[id].external && isBorrower(u, roots[0]) && u.p.vars[id].borrowsFrom.length > 0) {
			const v = u.p.vars[id];
			if (!reachesBorrowed(u, v, keys)) return;
			for (let b = 0; b < v.borrowsFrom.length; b += 1) {
				potentialMutation(u.p, u.p.vars[v.borrowsFrom[b]].sym, arg, v.borrowPaths[b]);
			}
			return;
		}
	}
	const paths: string[] = [];
	handlePaths(t, keys, viaRef, 0, "", paths);
	for (const p of paths) { mutateRoots(u, arg, arg, p); }
}

function argEffect(u: BorrowUnit, arg: Node, formal: Type | null, resizes: boolean, summary: ResizeSummary): void {
	if (formal != null && formal.kind == TypeKind.Var) {
		mutateRoots(u, arg, arg, "", viewStructChangesInPlace(formal.typeReturn) ? VALUE_WRITE : "");
		return;
	}
	if (formal != null && formal.kind == TypeKind.Sink) {
		handOff(u, arg, NO_KEEP);
		if (carriesPointer(formal.typeReturn)) mutateRoots(u, arg, arg);
		return;
	}
	if (arg.kind == NodeKind.MoveExpr || arg.kind == NodeKind.OutExpr || arg.kind == NodeKind.HiddenAddr) {
		mutateRoots(u, arg, arg);
		return;
	}
	if (resizes) {
		mutateRoots(u, arg, arg);
		return;
	}
	changeReachable(u, arg, formal != null ? formal : arg.nodeType, false, summary);
}

function resizesReceiver(node: Node, recv: Node): boolean {
	const callee = (node.data as CallExprData).callee;
	if (callee == null || callee.kind != NodeKind.MemberExpr) return false;
	if (!isMutatingArrayMethod((callee.data as MemberExprData).property)) return false;
	const t = recv.nodeType;
	if (t == null || isReadonlyView(t)) return false;
	const held = t.kind == TypeKind.Ref && t.typeReturn != null ? t.typeReturn : t;
	return held.kind == TypeKind.Array || held.kind == TypeKind.String;
}

function callEffects(u: BorrowUnit, node: Node): void {
	const d = node.data as CallExprData;
	const sym = node.resolvedSym;
	const fnType = sym != null && sym.symbolType != null && sym.symbolType.kind == TypeKind.Function
		? sym.symbolType
		: (d.callee != null ? d.callee.nodeType : null);
	const recv = receiverOf(node);
	const summary = calleeSummary(node);
	let offset: int32 = 0;
	if (recv != null) {
		const resizes = resizesReceiver(node, recv);
		if (node.flags.has(NodeFlag.ExtCall)) {
			argEffect(u, recv, formalAt(fnType, 0), resizes, summary);
			offset = 1;
		} else {
			argEffect(u, recv, null, resizes, summary);
		}
	}
	let passesRoutine = false;
	const all: Node[] = [];
	if (recv != null) all.push(recv);
	for (let i = 0; i < d.arguments.length; i += 1) {
		const a = d.arguments[i];
		argEffect(u, a, formalAt(fnType, i + offset), false, summary);
		if (a.nodeType != null && a.nodeType.kind == TypeKind.Function) passesRoutine = true;
		all.push(a);
	}
	storedIntoOther(u, all, summary);
	const local = sym != null && sym.declNode != null && u.routines.includes(sym.declNode);
	const runsClosures = summary.unknown || passesRoutine || local;
	changeEscaped(u, node, passesRoutine ? anyResize() : summary, runsClosures);
	if (summary.writes || runsClosures) noteCallWrite(u, node, all, fnType, recv != null && !node.flags.has(NodeFlag.ExtCall) ? -1 : 0, runsClosures);
}

function noteCallWrite(u: BorrowUnit, site: Node, parts: Node[], fnType: Type | null, offset: int32, runsClosures: boolean): void {
	if (u.lends.length == 0 && !u.worker) return;
	const roots: Symbol[] = [];
	for (let i = 0; i < parts.length; i += 1) {
		const formal = i + offset >= 0 ? formalAt(fnType, i + offset) : null;
		if (!carriesPointer(parts[i].nodeType) || (formal != null && isReadonlyView(formal))) continue;
		rootsOf(parts[i], roots);
	}
	if (runsClosures) {
		for (const w of u.writers) { roots.push(w); }
	}
	if (roots.length > 0) u.callWrites.push({ time: u.p.abstractTime, roots, site });
}

function thunkOf(arg: Node): Node {
	const a = peelConv(arg)!;
	if (a.kind != NodeKind.CallExpr) return a;
	const callee = peelConv((a.data as CallExprData).callee);
	return callee != null && callee.kind == NodeKind.ArrowFunction ? callee : a;
}

function capturedBy(u: BorrowUnit, node: Node | null, out: Symbol[]): void {
	if (node == null) return;
	if (node.kind == NodeKind.Identifier && node.resolvedSym != null && variableId(u.p, node.resolvedSym) >= 0
		&& !out.includes(node.resolvedSym)) out.push(node.resolvedSym);
	forEachChild(node, (child: Node): void => { capturedBy(u, child, out); });
}

function capturedWrites(u: BorrowUnit, node: Node | null, s: ResizeSummary): void {
	if (node == null) return;
	if (node.kind == NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		if (isAssignOp(d.operator) && d.left.kind == NodeKind.Identifier && d.left.resolvedSym != null
			&& variableId(u.p, d.left.resolvedSym) >= 0) {
			for (const k of keysOf(d.left.resolvedSym.symbolType, true)) { addKey(s.keys, k); }
		}
	}
	forEachChild(node, (child: Node): void => { capturedWrites(u, child, s); });
}

function recordClosure(u: BorrowUnit, node: Node): void {
	if (u.routines.includes(node)) return;
	u.routines.push(node);
	if (u.thunks.includes(node)) return;
	const body = routineBody(node);
	const s = noResize();
	const fresh: Symbol[] = [];
	freshLocals(body, fresh);
	scanResizes(body, s, fresh);
	if (!s.unknown) capturedWrites(u, body, s);
	const captured: Symbol[] = [];
	capturedBy(u, body, captured);
	if (s.writes) {
		for (const sym of captured) {
			if (!u.writers.includes(sym)) u.writers.push(sym);
		}
	}
	if (!s.unknown && s.keys.length == 0) return;
	for (const sym of captured) { escapeSym(u, sym, true); }
}

interface PathEnd {
	t: Type | null;
	crossed: boolean;
}

function followPath(t0: Type | null, path: string): PathEnd {
	let t = t0;
	let rest = path;
	let crossed = false;
	while (t != null) {
		match (t.kind) {
			TypeKind.GenericParam | TypeKind.Unknown | TypeKind.TypeReference | TypeKind.Pending => { return { t, crossed: true }; },
			TypeKind.Ref | TypeKind.Var => {
				crossed = true;
				if (rest == "") return { t, crossed };
				t = t.typeReturn;
				continue;
			},
			TypeKind.Alias | TypeKind.Distinct | TypeKind.Sink | TypeKind.Lent => {
				if (rest == "") return { t, crossed };
				t = t.typeReturn;
				continue;
			},
			TypeKind.GenericInstance => {
				if (t.typeReturn == null) return { t, crossed: true };
				if (rest == "") return { t, crossed };
				t = t.typeReturn;
				continue;
			},
			TypeKind.Span | TypeKind.Borrow => { crossed = true; },
			_ => {},
		};
		if (rest == "") return { t, crossed };
		if (rest.startsWith("[]")) {
			rest = rest.slice(2, rest.length);
			const indexable = t.kind == TypeKind.Array || t.kind == TypeKind.SizedArray || t.kind == TypeKind.Span;
			t = indexable ? t.typeReturn : null;
			continue;
		}
		if (!rest.startsWith(".") || t.kind != TypeKind.Struct) return { t: null, crossed: true };
		let end = 1;
		while (end < rest.length && rest.charAt(end) != "." && rest.charAt(end) != "[") end += 1;
		const at = t.typeNames.indexOf(rest.slice(1, end));
		rest = rest.slice(end, rest.length);
		t = at >= 0 && at < t.typeChildren.length ? t.typeChildren[at] : null;
	}
	return { t: null, crossed: true };
}

function crossesRef(t: Type | null, path: string): boolean {
	return followPath(t, path).crossed;
}

function keysAtPath(sym: Symbol, path: string): HandleKey[] {
	const end = followPath(sym.symbolType, path).t;
	return end == null ? [anyKey()] : keysOf(end, true);
}

function ownKeys(t0: Type | null): HandleKey[] {
	let t = t0;
	while (t != null && (t.kind == TypeKind.Ref || t.kind == TypeKind.Var || t.kind == TypeKind.Alias || t.kind == TypeKind.Distinct
		|| t.kind == TypeKind.Sink || t.kind == TypeKind.Lent)) t = t.typeReturn;
	if (t == null) return [anyKey()];
	return match (t.kind) {
		TypeKind.Array | TypeKind.Span | TypeKind.Borrow => [arrayKey(t.typeReturn)],
		TypeKind.String => [textKey()],
		_ => keysOf(t, true),
	};
}

function borrowedKeys(sym: Symbol, handles: string): HandleKey[] {
	const out: HandleKey[] = [];
	let named = false;
	for (const h of handles.split("|")) {
		if (h == "" || h.startsWith(VALUE_WRITE)) continue;
		named = true;
		for (const k of ownKeys(followPath(sym.symbolType, handlePath(h)).t)) { addKey(out, k); }
	}
	if (!named) out.push(anyKey());
	return out;
}

function staysPut(sym: Symbol, handles: string): boolean {
	for (const h of handles.split("|")) {
		if (h != "" && !h.startsWith(VALUE_WRITE)) return borrowedKeys(sym, handles).length == 0;
	}
	return true;
}

function inExternalGroup(u: BorrowUnit, id: int32): boolean {
	if (u.p.vars[id].external) return true;
	const root = ufRoot(u.p, id);
	for (let j = 0; j < u.p.vars.length; j += 1) {
		if (u.p.vars[j].external && ufRoot(u.p, j) == root) return true;
	}
	return false;
}

function aliasedChange(u: BorrowUnit, v: VarEntry, src: VarEntry, handles: string): int32[] {
	if (!src.external) return [];
	let shared = false;
	for (const h of handles.split("|")) {
		if (h != "" && crossesRef(src.sym.symbolType, handlePath(h))) shared = true;
	}
	if (!shared) return [];
	const borrowed = borrowedKeys(src.sym, handles);
	const srcRoot = ufRoot(u.p, variableId(u.p, src.sym));
	for (let gi = 0; gi < u.p.graphs.length; gi += 1) {
		const g = u.p.graphs[gi];
		for (let i = 0; i < g.mutations.length; i += 1) {
			const m = g.mutations[i];
			if (m < v.aliveStart || m > v.aliveEnd) continue;
			const r = g.roots[i];
			if (r == src.sym || r == v.sym || g.paths[i].startsWith(VALUE_WRITE)) continue;
			const rid = variableId(u.p, r);
			if (rid < 0 || ufRoot(u.p, rid) == srcRoot || !inExternalGroup(u, rid)) continue;
			if (keysMeet(keysAtPath(r, g.paths[i]), borrowed)) return [gi, i];
		}
	}
	return [];
}

function sharedSource(u: BorrowUnit, src: VarEntry, handles: string): boolean {
	if (hasFlag(src.sym, SymbolFlag.Global) || u.escaped.includes(src.sym) || u.captured.includes(src.sym)) return true;
	for (const h of handles.split("|")) {
		if (h != "" && crossesRef(src.sym.symbolType, handlePath(h))) return true;
	}
	return false;
}

function openScope(u: BorrowUnit, block: Node): void {
	let id = u.blocks.indexOf(block);
	if (id < 0) {
		id = u.blocks.length;
		u.blocks.push(block);
	}
	u.scope.push(id as int32);
}

function declare(u: BorrowUnit, sym: Symbol | null, redeclared: boolean): void {
	if (sym == null || u.pass != 1) return;
	const existing = variableId(u.p, sym);
	if (existing >= 0) {
		if (redeclared && !u.p.vars[existing].external) {
			u.p.vars[existing].aliveStart = u.p.abstractTime;
			u.p.vars[existing].aliveEnd = u.p.abstractTime;
		}
		return;
	}
	registerVariable(u.p, sym, false, 0);
	const id = variableId(u.p, sym);
	const path: int32[] = [];
	for (const s of u.scope) { path.push(s); }
	u.p.vars[id].scopePath = path;
}

function useSym(u: BorrowUnit, sym: Symbol | null): void {
	if (sym == null || u.pass != 1) return;
	if (hasFlag(sym, SymbolFlag.Global)) return;
	registerVariable(u.p, sym, true, 0);
	const id = variableId(u.p, sym);
	if (u.p.abstractTime > u.p.vars[id].aliveEnd) u.p.vars[id].aliveEnd = u.p.abstractTime;
}

function walkLoop(u: BorrowUnit, parts: (Node | null)[]): void {
	for (const n of parts) { walk(u, n); }
	u.p.inLoop += 1;
	for (const n of parts) { walk(u, n); }
	u.p.inLoop -= 1;
}

function walk(u: BorrowUnit, node: Node | null): void {
	if (node == null) return;
	u.p.abstractTime += 1;
	if (u.pass == 2 && isAddressTaking(node)) refuseViewRefParamAddress(u, node);
	match (node.kind) {
		NodeKind.Identifier => {
			u.p.abstractTime -= 1;
			useSym(u, node.resolvedSym);
		},
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			walk(u, d.initializer);
			u.p.abstractTime += 1;
			declare(u, node.resolvedSym, u.p.inLoop > 0);
			if (u.pass == 1) nameLend(u, node.resolvedSym, d.initializer);
			if (u.pass == 2) deps(u, node.resolvedSym, d.initializer);
		},
		NodeKind.DestructuringDecl => {
			const d = node.data as DestructuringDeclData;
			walk(u, d.destrInit);
			u.p.abstractTime += 1;
			bindPattern(u, d.destrPattern, d.destrInit, null);
		},
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			walk(u, d.left);
			walk(u, d.right);
			if (u.pass == 2 && isAssignOp(d.operator)) assign(u, node, d);
		},
		NodeKind.UpdateExpr => {
			const d = node.data as UpdateExprData;
			walk(u, d.updateArg);
			if (u.pass == 2) mutateRoots(u, d.updateArg, node, "", VALUE_WRITE);
		},
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			walk(u, d.callee);
			if (u.pass == 2 && isSpawnCall(node) && d.arguments.length > 0) u.thunks.push(thunkOf(d.arguments[0]));
			for (const a of d.arguments) { walk(u, a); }
			if (u.pass == 1 && isSpawnCall(node) && d.arguments.length > 0) openLend(u, node, d.arguments[0]);
			if (u.pass == 1 && node.flags.has(NodeFlag.LendsPastCall)) openCallLend(u, node);
			if (u.pass == 2 && !isSpawnCall(node)) callEffects(u, node);
		},
		NodeKind.NewExpr => {
			const d = node.data as NewExprData;
			walk(u, d.newCallee);
			for (const a of d.newArguments) { walk(u, a); }
			if (u.pass == 2) {
				const summary = newSummary(node);
				for (const a of d.newArguments) { argEffect(u, a, null, false, summary); }
				if (summary.writes) noteCallWrite(u, node, d.newArguments, null, 0, false);
			}
		},
		NodeKind.MoveExpr => {
			const d = node.data as MoveExprData;
			walk(u, d.moveArg);
			if (u.pass == 2) mutateRoots(u, d.moveArg, node);
		},
		NodeKind.ArrayLiteral => {
			const d = node.data as ArrayLiteralData;
			for (const e of d.elements) { walk(u, e); }
			if (u.pass == 2) {
				for (const e of d.elements) { handOff(u, e, currentScope(u)); }
			}
		},
		NodeKind.ObjectLiteral => {
			const d = node.data as ObjectLiteralData;
			for (const e of d.properties) { walk(u, e); }
			if (u.pass == 2) {
				for (const e of d.properties) { handOff(u, e, currentScope(u)); }
			}
		},
		NodeKind.BlockStmt => {
			openScope(u, node);
			walkStatements(u, (node.data as BlockStmtData).statements);
			u.scope.pop();
		},
		NodeKind.Program => {
			walkStatements(u, (node.data as ProgramData).programStmts);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			walkLoop(u, [d.whileCondition, d.whileBody]);
			walk(u, d.whileCondition);
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			walkLoop(u, [d.doBody, d.doCondition]);
		},
		NodeKind.ForStmt => {
			const d = node.data as ForStmtData;
			openScope(u, node);
			walk(u, d.forInit);
			walkLoop(u, [d.forCondition, d.forBody, d.forUpdate]);
			u.scope.pop();
		},
		NodeKind.ForOfStmt => {
			const d = node.data as ForOfStmtData;
			walk(u, d.forOfIterable);
			openScope(u, node);
			for (let round = 0; round < 2; round += 1) {
				if (round == 1) u.p.inLoop += 1;
				u.p.abstractTime += 1;
				declare(u, node.resolvedSym, true);
				const binding = node.resolvedSym;
				if (u.pass == 2 && binding != null && carriesPointer(binding.symbolType)) {
					const sources: Symbol[] = [];
					rootsOf(d.forOfIterable, sources);
					for (const s of sources) { ufConnect(u.p, binding, s); }
				}
				walk(u, d.forOfPattern);
				walk(u, d.forOfBody);
				if (round == 1) u.p.inLoop -= 1;
			}
			u.scope.pop();
		},
		NodeKind.ForInStmt => {
			const d = node.data as ForInStmtData;
			walk(u, d.forInObject);
			openScope(u, node);
			walkLoop(u, [d.forInBody]);
			u.scope.pop();
		},
		NodeKind.DeferStmt => {
			u.p.abstractTime -= 1;
			if (u.pass == 1) u.defers.push((node.data as DeferStmtData).deferExpr);
		},
		NodeKind.FunctionDecl | NodeKind.ArrowFunction | NodeKind.FunctionExpr => {
			u.p.abstractTime -= 1;
			if (u.pass == 2) recordClosure(u, node);
		},
		NodeKind.ClassDecl | NodeKind.MethodDecl | NodeKind.ConstructorDecl | NodeKind.TestDecl => {
			u.p.abstractTime -= 1;
		},
		NodeKind.AwaitExpr | NodeKind.YieldExpr => {
			if (u.pass == 1 && node.kind == NodeKind.AwaitExpr) markJoins(u, node);
			forEachChild(node, (child: Node): void => { walk(u, child); });
			if (u.pass == 1) endLends(u, node);
			u.p.abstractTime += 1;
			if (u.pass == 2) {
				u.suspends.push(u.p.abstractTime);
				u.suspendSites.push(node);
			}
		},
		_ => { forEachChild(node, (child: Node): void => { walk(u, child); }); },
	};
}

function bindPattern(u: BorrowUnit, pattern: Node | null, source: Node, fallback: Node | null): void {
	if (pattern == null) return;
	walk(u, fallback);
	match (pattern.kind) {
		NodeKind.Identifier => {
			const sym = pattern.resolvedSym;
			declare(u, sym, u.p.inLoop > 0);
			if (u.pass != 2 || sym == null || !isBorrower(u, sym)) return;
			borrowFrom(u, sym, source);
			if (fallback != null) borrowFrom(u, sym, fallback);
		},
		NodeKind.SpreadExpr => { bindPattern(u, (pattern.data as SpreadExprData).spreadArg, source, fallback); },
		NodeKind.ObjectPattern => {
			for (const prop of (pattern.data as ObjectPatternData).patternProps) {
				if (prop.kind != NodeKind.ObjectPatternProp) {
					bindPattern(u, prop, source, null);
					continue;
				}
				const pd = prop.data as ObjectPatternPropData;
				const read = createNodeAt(NodeKind.MemberExpr, { object: source, property: pd.propKey, isOptional: false } as MemberExprData, prop.location);
				read.nodeType = pd.propAlias.nodeType;
				bindPattern(u, pd.propAlias, read, pd.propDefault);
			}
		},
		NodeKind.ArrayPattern => {
			const d = pattern.data as ArrayPatternData;
			for (let i = 0; i < d.patternElements.length; i += 1) {
				const e = d.patternElements[i];
				if (e.kind == NodeKind.SpreadExpr) {
					bindPattern(u, e, source, null);
					continue;
				}
				const read = createNodeAt(NodeKind.ArrayAccess, { array: source, index: e } as ArrayAccessData, e.location);
				read.nodeType = e.nodeType;
				bindPattern(u, e, read, i < d.patternDefaults.length ? d.patternDefaults[i] : null);
			}
		},
		_ => {},
	};
}

function peelConv(node: Node | null): Node | null {
	let n = node;
	while (n != null && (n.kind == NodeKind.HiddenStdConv || n.kind == NodeKind.HiddenSubConv)) n = (n.data as HiddenStdConvData).convExpr;
	return n;
}

function walkStatements(u: BorrowUnit, statements: Node[]): void {
	for (const s of statements) {
		if (u.pass == 1) findJoin(u, s);
		walk(u, s);
	}
}

function innerParams(node: Node | null, out: Symbol[]): void {
	if (node == null) return;
	if (node.paramSyms != null) {
		for (const s of node.paramSyms) { out.push(s); }
	}
	forEachChild(node, (child: Node): void => { innerParams(child, out); });
}

function lendable(sym: Symbol): boolean {
	if (sym.symbolKind != SymbolKind.Variable && sym.symbolKind != SymbolKind.Parameter) return false;
	return !isLockedRef(sym.symbolType) && !isAtomicRef(sym.symbolType);
}

function lentRoots(p: Partitions | null, node: Node | null, inner: Symbol[], out: Symbol[], via: Symbol[]): void {
	if (node == null || node.kind == NodeKind.MoveExpr) return;
	const sym = node.kind == NodeKind.Identifier ? node.resolvedSym : null;
	if (sym != null && lendable(sym) && !out.includes(sym) && !inner.includes(sym)
		&& ((p != null && variableId(p, sym) >= 0) || !hasFlag(sym, SymbolFlag.Global))) out.push(sym);
	const bound = boundRoutine(sym);
	if (bound != null && !via.includes(sym!)) {
		via.push(sym!);
		innerParams(bound, inner);
		lentRoots(p, bound, inner, out, via);
	}
	forEachChild(node, (child: Node): void => { lentRoots(p, child, inner, out, via); });
}

function joinedBy(node: Node): Node[] {
	const out: Node[] = [];
	const arg = peelConv((node.data as AwaitExprData).awaitArg);
	if (arg == null) return out;
	out.push(arg);
	const kind = arg.kind == NodeKind.CallExpr && arg.resolvedSym != null ? arg.resolvedSym.builtinKind : "";
	if (kind != "PromiseAll" && kind != "PromiseAllSettled") return out;
	const args = (arg.data as CallExprData).arguments;
	const list = args.length > 0 ? peelConv(args[0]) : null;
	if (list == null || list.kind != NodeKind.ArrayLiteral) return out;
	for (const e of (list.data as ArrayLiteralData).elements) {
		const p = peelConv(e);
		if (p != null) out.push(p);
	}
	return out;
}

function joinOf(node: Node | null, handle: Symbol): Node | null {
	if (node == null) return null;
	match (node.kind) {
		NodeKind.AwaitExpr => {
			for (const op of joinedBy(node)) {
				if (op.kind == NodeKind.Identifier && op.resolvedSym == handle) return node;
			}
		},
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			if (d.operator == "&&" || d.operator == "||" || d.operator == "??") return joinOf(d.left, handle);
		},
		NodeKind.MemberExpr => { if ((node.data as MemberExprData).isOptional) return null; },
		NodeKind.ExprStmt | NodeKind.ReturnStmt | NodeKind.VariableDecl | NodeKind.UnaryExpr | NodeKind.CallExpr | NodeKind.NewExpr
			| NodeKind.ArrayAccess | NodeKind.ArrayLiteral | NodeKind.ObjectLiteral | NodeKind.TypeAssertion
			| NodeKind.HiddenStdConv | NodeKind.HiddenSubConv | NodeKind.HiddenDeref | NodeKind.SpreadExpr => {},
		_ => { return null; },
	};
	let found: Node | null = null;
	forEachChild(node, (child: Node): void => { if (found == null) found = joinOf(child, handle); });
	return found;
}

function findJoin(u: BorrowUnit, stmt: Node): void {
	for (const l of u.lends) {
		if (l.handle != null && l.closer == null && l.scope.length == u.scope.length && encloses(l.scope, u.scope)) l.closer = joinOf(stmt, l.handle);
	}
}

function markJoins(u: BorrowUnit, node: Node): void {
	for (const op of joinedBy(node)) {
		if (isSpawnCall(op) || op.flags.has(NodeFlag.LendsPastCall)) {
			u.closerSites.push(op);
			u.closerAwaits.push(node);
		}
	}
}

function endLends(u: BorrowUnit, node: Node): void {
	for (const l of u.lends) {
		if (l.closer == node) l.end = u.p.abstractTime;
	}
}

function reopenLend(u: BorrowUnit, site: Node): boolean {
	for (const l of u.lends) {
		if (l.site != site) continue;
		if (l.closer != null) {
			l.start = u.p.abstractTime + 1;
			l.end = -1;
		}
		return true;
	}
	return false;
}

function pushLend(u: BorrowUnit, site: Node, roots: Symbol[], bounds: Symbol[], tasks: Node[], callee: string): void {
	for (const r of roots) { registerVariable(u.p, r, true, 0); }
	const at = u.closerSites.indexOf(site);
	const closer = at >= 0 ? u.closerAwaits[at] : null;
	u.lends.push({ site, handle: null, roots, start: u.p.abstractTime + 1, end: -1, closer, scope: closer != null ? currentScope(u) : [], bounds, tasks, callee });
}

function openLend(u: BorrowUnit, site: Node, thunk: Node): void {
	if (reopenLend(u, site)) return;
	const inner: Symbol[] = [];
	innerParams(thunk, inner);
	const roots: Symbol[] = [];
	const reached: Symbol[] = [];
	lentRoots(u.p, thunk, inner, roots, reached);
	const bounds = reached.filter((b: Symbol): boolean => !containsNode(thunk, boundRoutine(b)!));
	pushLend(u, site, roots, bounds, roots.map((r: Symbol): Node => site), "");
}

function openCallLend(u: BorrowUnit, site: Node): void {
	if (reopenLend(u, site)) return;
	const found: Symbol[] = [];
	const tasks: Node[] = [];
	callLentRoots(site, found, tasks);
	const roots: Symbol[] = [];
	const kept: Node[] = [];
	for (let i = 0; i < found.length; i += 1) {
		if (variableId(u.p, found[i]) < 0 && hasFlag(found[i], SymbolFlag.Global)) continue;
		roots.push(found[i]);
		kept.push(tasks[i]);
	}
	pushLend(u, site, roots, [], kept, calleeName(site));
}

function calleeName(call: Node): string {
	const callee = peelConv((call.data as CallExprData).callee);
	if (callee != null && callee.kind == NodeKind.MemberExpr) return (callee.data as MemberExprData).property;
	return call.resolvedSym != null ? call.resolvedSym.name : "function value";
}

function nameLend(u: BorrowUnit, sym: Symbol | null, init: Node | null): void {
	const site = peelConv(init);
	if (sym == null || site == null) return;
	for (const l of u.lends) {
		if (l.site == site && l.handle == null) {
			l.handle = sym;
			l.scope = currentScope(u);
		}
	}
}

function lendMutation(g: MutationInfo, l: Lend): int32 {
	if ((g.flags & SF_IS_MUTATED) == 0) return -1;
	for (let i = 0; i < g.mutations.length; i += 1) {
		const m = g.mutations[i];
		if (m < l.start || m > l.end) continue;
		const keep = g.keeps[i];
		if (!(keep.length == 1 && keep[0] == -1) && encloses(keep, l.scope)) continue;
		return i;
	}
	return -1;
}

function checkLends(u: BorrowUnit, unitEnd: string): void {
	for (const l of u.lends) {
		const until = l.closer != null ? `its await at ${l.closer.location.line}:${l.closer.location.column}` : unitEnd;
		for (let ri = 0; ri < l.roots.length; ri += 1) {
			const r = l.roots[ri];
			const task = l.tasks[ri];
			const via = l.callee != "" ? `, which the call of '${l.callee}' at ${l.site.location.line}:${l.site.location.column} starts,` : "";
			const spawnAt = `${task.location.line}:${task.location.column}${via}`;
			const id = variableId(u.p, r);
			if (id < 0) continue;
			const root = ufRoot(u.p, id);
			const call = callWriteIn(u, l, root);
			if (call != null) {
				addError(u.ctx, `'${r.name}' is lent to the spawn at ${spawnAt} until ${until}, and the call at ${call.location.line}:${call.location.column} can change it while the task reads it; make the call after the await, or declare the parameter that receives it Readonly<...> if the callee only reads it`, l.site.location.line, l.site.location.column);
				break;
			}
			if (u.p.vars[root].con.kind != CK_ROOT_OF) continue;
			const g = u.p.graphs[u.p.vars[root].con.target];
			const i = lendMutation(g, l);
			if (i < 0) continue;
			const site = g.sites[i];
			const change = site != null ? `the change at ${site.location.line}:${site.location.column}` : "a change";
			addError(u.ctx, `'${r.name}' is lent to the spawn at ${spawnAt} until ${until}, and ${change} changes it while the task reads it; make the change after the await, or give the task its own copy`, l.site.location.line, l.site.location.column);
			break;
		}
	}
}

function callWriteIn(u: BorrowUnit, l: Lend, root: int32): Node | null {
	for (const w of u.callWrites) {
		if (w.time < l.start || w.time > l.end) continue;
		for (const s of w.roots) {
			const id = variableId(u.p, s);
			if (id >= 0 && ufRoot(u.p, id) == root) return w.site;
		}
	}
	return null;
}

interface UnitScan {
	pointers: Symbol[];
	view: boolean;
	spawn: boolean;
	clear: TypeVisitSet;
	module: boolean;
}

function scanUnitBody(node: Node | null, scan: UnitScan): void {
	if (node == null) return;
	if (node.kind == NodeKind.FunctionDecl || node.kind == NodeKind.ArrowFunction || node.kind == NodeKind.FunctionExpr
		|| node.kind == NodeKind.ClassDecl || node.kind == NodeKind.MethodDecl || node.kind == NodeKind.ConstructorDecl) return;
	if (!scan.spawn && isSpawnCall(node)) scan.spawn = true;
	if (node.kind == NodeKind.CallExpr && lendsPastCall(node, scan.module)) {
		node.flags = node.flags.incl(NodeFlag.LendsPastCall);
		scan.spawn = true;
	}
	if (!scan.view && node.resolvedSym != null && (node.kind == NodeKind.VariableDecl || node.kind == NodeKind.ForOfStmt)
		&& holdsViewSkippingClear(node.resolvedSym.symbolType, scan.clear)) scan.view = true;
	if (!scan.view && node.kind == NodeKind.DestructuringDecl && bindsView((node.data as DestructuringDeclData).destrPattern, scan.clear)) scan.view = true;
	if (node.kind == NodeKind.VariableDecl && node.resolvedSym != null && takesAddress((node.data as VariableDeclData).initializer)) {
		scan.pointers.push(node.resolvedSym);
	}
	if (node.kind == NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		if (d.operator == "=" && d.left.kind == NodeKind.Identifier && d.left.resolvedSym != null && takesAddress(d.right)) {
			scan.pointers.push(d.left.resolvedSym);
		}
	}
	forEachChild(node, (child: Node): void => { scanUnitBody(child, scan); });
}

function bindsView(pattern: Node, clear: TypeVisitSet): boolean {
	if (pattern.kind == NodeKind.Identifier) return pattern.resolvedSym != null && holdsViewSkippingClear(pattern.resolvedSym.symbolType, clear);
	let found = false;
	forEachChild(pattern, (child: Node): void => { if (!found && bindsView(child, clear)) found = true; });
	return found;
}

function encloses(outer: int32[], inner: int32[]): boolean {
	if (outer.length > inner.length) return false;
	for (let i = 0; i < outer.length; i += 1) {
		if (outer[i] != inner[i]) return false;
	}
	return true;
}

function runPass(u: BorrowUnit, body: Node, pass: int32): void {
	u.pass = pass;
	u.p.abstractTime = 0;
	u.scope = [];
	walk(u, body);
	const defers: Node[] = [];
	for (const d of u.defers) { defers.push(d); }
	for (let i = defers.length - 1; i >= 0; i -= 1) { walk(u, defers[i]); }
}

function newUnit(ctx: CheckerContext, pointers: Symbol[], worker: boolean): BorrowUnit {
	return {
		p: createPartitions(), pass: 1, scope: [], defers: [], ctx, pointers, blocks: [], captured: [], routines: [], suspends: [], suspendSites: [], escaped: [],
		lends: [], closerSites: [], closerAwaits: [], thunks: [], writers: [], callWrites: [], worker,
	};
}

function routineBodies(node: Node | null, out: Node[]): void {
	if (node == null) return;
	if (node.kind == NodeKind.FunctionDecl || node.kind == NodeKind.ArrowFunction || node.kind == NodeKind.FunctionExpr) {
		const body = routineBody(node);
		if (body != null && !out.includes(body)) out.push(body);
	}
	forEachChild(node, (child: Node): void => { routineBodies(child, out); });
}

function containsNode(root: Node | null, target: Node): boolean {
	if (root == null) return false;
	if (root == target) return true;
	let found = false;
	forEachChild(root, (child: Node): void => { if (!found && containsNode(child, target)) found = true; });
	return found;
}

function writeSite(u: BorrowUnit, id: int32): Node | null {
	const root = ufRoot(u.p, id);
	if (u.p.vars[root].con.kind == CK_ROOT_OF) {
		const g = u.p.graphs[u.p.vars[root].con.target];
		for (let i = 0; i < g.mutations.length; i += 1) {
			if (g.keeps[i].length == 1 && g.keeps[i][0] == -1) return g.sites[i];
		}
	}
	for (const w of u.callWrites) {
		for (const s of w.roots) {
			const sid = variableId(u.p, s);
			if (sid >= 0 && ufRoot(u.p, sid) == root) return w.site;
		}
	}
	return null;
}

function refuseWorkerWrites(parent: BorrowUnit, l: Lend): void {
	const bodies: Node[] = [];
	const own: Symbol[] = [];
	for (const b of l.bounds) {
		const routine = boundRoutine(b);
		routineBodies(routine, bodies);
		innerParams(routine, own);
	}
	const pointers: Symbol[] = [];
	const scan: UnitScan = { pointers, view: true, spawn: true, clear: new TypeVisitSet(), module: false };
	for (const b of bodies) { scanUnitBody(b, scan); }
	const u = newUnit(parent.ctx, pointers, true);
	for (let pass = 1; pass <= 2; pass += 1) {
		for (const b of bodies) { runPass(u, b, pass); }
	}
	const named: int32[] = [];
	for (let id = 0; id < u.p.vars.length; id += 1) {
		const v = u.p.vars[id];
		if (!v.external || own.includes(v.sym) || !lendable(v.sym) || !carriesPointer(v.sym.symbolType)) continue;
		const root = ufRoot(u.p, id);
		if (named.includes(root)) continue;
		const site = writeSite(u, id);
		if (site == null) continue;
		named.push(root);
		let found: Symbol | null = null;
		for (let i = l.bounds.length - 1; i >= 0; i -= 1) { if (containsNode(boundRoutine(l.bounds[i]), site)) found = l.bounds[i]; }
		if (found == null) throw new Error(`internal: the write to '${v.sym.name}' at ${site.location.line}:${site.location.column} lies in no closure bound by the spawn at ${l.site.location.line}:${l.site.location.column}`);
		const bound = aliasTarget(found)!;
		addError(parent.ctx, `cannot write through Readonly<${typeDisplayName(v.sym.symbolType)}> — a read-only view never converts back to the mutable type (PARALOCK E24)\n'${v.sym.name}' is captured by '${bound.name}', bound at ${bound.location.line}:${bound.location.column}, which the spawn at ${l.site.location.line}:${l.site.location.column} runs on another thread; the write is here`,
			site.location.line, site.location.column);
	}
}

function lentInputName(decl: Node, l: PendingLend): string {
	if (l.input == THIS_INPUT) return "'this'";
	if (l.input == CAPTURE_INPUT) return `the captured '${l.capture!.name}'`;
	const params = decl.paramSyms ?? [];
	return l.input < params.length ? `its parameter '${params[l.input].name}'` : "a parameter";
}

function refuseLendingValue(ctx: CheckerContext, site: Node, what: string, decl: Node, pending: PendingLend[]): void {
	const l = pending[0];
	addError(ctx, `${what}: the spawn at ${l.task.location.line}:${l.task.location.column} that it starts reads ${lentInputName(decl, l)} after the call returns, and a call through a function value cannot hold what the caller lends it until its promise is awaited; call the routine by name and await it, or let the task capture only copies, moved values, Arc<T> or Locked<T>`,
		site.location.line, site.location.column);
}

function isPromiseJoin(node: Node | null): boolean {
	if (node == null || node.kind != NodeKind.CallExpr || node.resolvedSym == null) return false;
	return node.resolvedSym.builtinKind == "PromiseAll" || node.resolvedSym.builtinKind == "PromiseAllSettled";
}

function heldWhere(up: Node[], call: Node): boolean {
	const n = up.length;
	const p = up[n - 1];
	if (p.kind == NodeKind.VariableDecl || p.kind == NodeKind.AwaitExpr) return true;
	if (p.kind == NodeKind.BinaryExpr) {
		const d = p.data as BinaryExprData;
		const target = peelConv(d.left);
		return d.operator == "=" && peelConv(d.right) == call && target != null && target.kind == NodeKind.Identifier && n >= 2 && up[n - 2].kind == NodeKind.ExprStmt;
	}
	if (p.kind != NodeKind.ArrayLiteral || n < 4 || !isPromiseJoin(up[n - 2]) || up[n - 3].kind != NodeKind.AwaitExpr) return false;
	const top = up[n - 4].kind;
	return top == NodeKind.VariableDecl || top == NodeKind.ExprStmt || top == NodeKind.ReturnStmt;
}

function escapeReported(up: Node[], call: Node): boolean {
	const p = up[up.length - 1];
	return match (p.kind) {
		NodeKind.ReturnStmt | NodeKind.ObjectLiteral | NodeKind.NewExpr | NodeKind.ThrowStmt | NodeKind.YieldExpr => true,
		NodeKind.BinaryExpr => {
			const d = p.data as BinaryExprData;
			const target = peelConv(d.left);
			return isAssignOp(d.operator) && (target == null || target.kind != NodeKind.Identifier);
		},
		NodeKind.CallExpr => {
			if (isPromiseJoin(p) || receiverOf(p) != null) return false;
			const args = (p.data as CallExprData).arguments;
			const callee = peelConv((p.data as CallExprData).callee);
			const at = args.indexOf(call);
			const formal = at >= 0 && callee != null ? formalAt(callee.nodeType, at as int32) : null;
			return formal == null || !isReadonlyView(formal);
		},
		_ => false,
	};
}

function refuseLeavingLends(ctx: CheckerContext, node: Node | null, up: Node[]): void {
	if (node == null || node.kind == NodeKind.ImportDecl || node.kind == NodeKind.ExportDecl) return;
	const parent = up.length > 0 ? up[up.length - 1] : null;
	const asCallee = parent != null && parent.kind == NodeKind.CallExpr && peelConv((parent.data as CallExprData).callee) == node;
	if (node.kind == NodeKind.ArrowFunction || node.kind == NodeKind.FunctionExpr) {
		const pending = asCallee ? [] : pendingLends(node);
		if (pending.length > 0) refuseLendingValue(ctx, node, "this async function value cannot be made", node, pending);
		return;
	}
	if (isNestedRoutineNode(node)) return;
	if ((node.kind == NodeKind.Identifier || node.kind == NodeKind.MemberExpr) && !asCallee && node.resolvedSym != null) {
		const sym = node.resolvedSym;
		const pending = pendingOfRoutine(sym);
		if (pending.length > 0) refuseLendingValue(ctx, node, `'${sym.name}' cannot become a function value`, sym.declNode!, pending);
	}
	if (node.kind == NodeKind.CallExpr && node.flags.has(NodeFlag.LendsPastCall) && parent != null) {
		const roots: Symbol[] = [];
		const tasks: Node[] = [];
		callLentRoots(node, roots, tasks);
		const lent = roots.length > 0 ? `'${roots[0].name}'` : "what it is passed";
		const spawnAt = tasks.length > 0 ? `${tasks[0].location.line}:${tasks[0].location.column}` : "?";
		if (parent.kind == NodeKind.ExprStmt) {
			addError(ctx, `the promise of '${calleeName(node)}' is discarded, but the spawn at ${spawnAt} that the call starts still reads ${lent} after the call returns, so the promise has to be awaited before this scope changes or leaves it; bind it and await it`, node.location.line, node.location.column);
		} else if (!heldWhere(up, node) && !escapeReported(up, node)) {
			addError(ctx, `the promise of '${calleeName(node)}' is kept where this scope's exit cannot join it, while the spawn at ${spawnAt} that the call starts reads ${lent}; bind it to a local with const or let, or await it where it is written`, node.location.line, node.location.column);
		}
	}
	const transparent = node.kind == NodeKind.HiddenStdConv || node.kind == NodeKind.HiddenSubConv;
	if (!transparent) up.push(node);
	forEachChild(node, (child: Node): void => { refuseLeavingLends(ctx, child, up); });
	if (!transparent) up.pop();
}

function checkUnit(ctx: CheckerContext, body: Node | null, routine: Node | null = null, name: string = ""): void {
	if (body == null) return;
	const scan: UnitScan = { pointers: [], view: false, spawn: false, clear: new TypeVisitSet(), module: body.kind == NodeKind.Program };
	scanUnitBody(body, scan);
	refuseLeavingLends(ctx, body, []);
	if (scan.spawn) refuseBorrowingHandleEscapes(ctx, body);
	const viewChannel = viewStructResult(routine) != null || hasViewRefParam(routine);
	if ((body.kind != NodeKind.BlockStmt && body.kind != NodeKind.Program) || (scan.pointers.length == 0 && !scan.view && !scan.spawn && !viewChannel)) {
		refuseViewStructReturns(ctx, null, routine, name, body);
		return;
	}
	const u = newUnit(ctx, scan.pointers, false);
	runPass(u, body, 1);
	for (const l of u.lends) {
		if (l.end < 0) l.end = u.p.abstractTime;
	}
	runPass(u, body, 2);
	checkLends(u, body.kind == NodeKind.Program ? "the end of the module" : "the end of the function");
	for (const l of u.lends) { refuseWorkerWrites(u, l); }
	for (const v of u.p.vars) {
		if (v.external || !isBorrower(u, v.sym)) continue;
		for (let bi = 0; bi < v.borrowsFrom.length; bi += 1) {
			const b = v.borrowsFrom[bi];
			const src = u.p.vars[b];
			const sid = ufRoot(u.p, b);
			if (u.p.vars[sid].con.kind == CK_ROOT_OF) {
				const g = u.p.graphs[u.p.vars[sid].con.target];
				const at = firstMutationIn(g, v, src.sym, v.borrowHandles[bi]);
				if (at >= 0) {
					const site = g.sites[at];
					const where = site != null ? ` at ${site.location.line}:${site.location.column}` : "";
					const message = isViewType(v.sym.symbolType)
						? `cannot borrow '${v.sym.name}': what it borrows from ('${src.sym.name}') is potentially changed${where} while '${v.sym.name}' is in use; take the view after the change, or copy what it reads`
						: `pointer '${v.sym.name}' addresses storage of '${src.sym.name}', which is potentially changed${where} while '${v.sym.name}' is in use; take the address after the change`;
					addError(ctx, message, v.sym.location.line, v.sym.location.column);
					break;
				}
			}
			if (!src.external && !encloses(src.scopePath, v.scopePath)) {
				addError(ctx, `'${v.sym.name}' borrows from '${src.sym.name}', which does not live long enough`, v.sym.location.line, v.sym.location.column);
				break;
			}
			if (isViewType(v.sym.symbolType) && sharedSource(u, src, v.borrowHandles[bi]) && suspendsWhileUsed(u, v, ctx, src)) break;
			const alias = aliasedChange(u, v, src, v.borrowHandles[bi]);
			if (alias.length == 2) {
				const g = u.p.graphs[alias[0]];
				const site = g.sites[alias[1]];
				const where = site != null ? ` at ${site.location.line}:${site.location.column}` : "";
				addError(ctx, `cannot borrow '${v.sym.name}': what it borrows from ('${src.sym.name}') may be the same array as '${g.roots[alias[1]].name}', which is changed${where} while '${v.sym.name}' is in use (a caller can pass one array for both); take the view after the change, or copy what it reads`, v.sym.location.line, v.sym.location.column);
				break;
			}
		}
	}
	refuseViewStructReturns(ctx, u, routine, name, body);
}

function assignPattern(u: BorrowUnit, target: Node | null, src: Node | null): void {
	if (target == null || src == null) return;
	match (target.kind) {
		NodeKind.ArrayLiteral => {
			const els = (target.data as ArrayLiteralData).elements;
			const given = src.kind == NodeKind.ArrayLiteral ? (src.data as ArrayLiteralData).elements : null;
			for (let i = 0; i < els.length; i += 1) {
				assignPattern(u, els[i], given != null && given.length == els.length && els[i].kind != NodeKind.SpreadExpr ? given[i] : src);
			}
		},
		NodeKind.ObjectLiteral => {
			for (const prop of (target.data as ObjectLiteralData).properties) { assignPattern(u, prop, src); }
		},
		NodeKind.SpreadExpr => { assignPattern(u, (target.data as SpreadExprData).spreadArg, src); },
		NodeKind.BinaryExpr => {
			const d = target.data as BinaryExprData;
			assignPattern(u, d.left, src);
			assignPattern(u, d.left, d.right);
		},
		_ => {
			const roots: Symbol[] = [];
			rootsOf(target, roots);
			if (roots.length == 1 && isViewType(target.nodeType) && isBorrower(u, roots[0])) borrowFrom(u, roots[0], src);
		},
	};
}

function refuseViewWriteThroughRefParam(u: BorrowUnit, d: BinaryExprData): void {
	if (d.operator == "=" && isNullArm(d.right)) return;
	refuseViewTargetThroughRefParam(u, d.left);
}

function refuseViewTargetThroughRefParam(u: BorrowUnit, target: Node | null): boolean {
	if (target == null) return false;
	if (target.kind == NodeKind.ArrayLiteral || target.kind == NodeKind.ObjectLiteral) {
		const parts = target.kind == NodeKind.ArrayLiteral ? (target.data as ArrayLiteralData).elements : (target.data as ObjectLiteralData).properties;
		for (const part of parts) {
			if (refuseViewTargetThroughRefParam(u, part)) return true;
		}
		return false;
	}
	if (target.kind == NodeKind.SpreadExpr) return refuseViewTargetThroughRefParam(u, (target.data as SpreadExprData).spreadArg);
	if (target.kind == NodeKind.BinaryExpr) return refuseViewTargetThroughRefParam(u, (target.data as BinaryExprData).left);
	const written = target.nodeType != null && target.nodeType.kind == TypeKind.Var ? target.nodeType.typeReturn : target.nodeType;
	if (!isViewType(written)) return false;
	const roots: Symbol[] = [];
	rootsOf(target, roots);
	for (const r of roots) {
		const t = r.symbolType;
		if (r.symbolKind != SymbolKind.Parameter || t == null || t.kind != TypeKind.Var) continue;
		addError(u.ctx, `'${r.name}' is a ref or out parameter, so a view cannot be written through it: its caller cannot see what the view borrows from — return the view, or write the offsets it is built from`, target.location.line, target.location.column);
		return true;
	}
	return false;
}

function refuseViewRefParamAddress(u: BorrowUnit, node: Node): void {
	const taken = (node.data as TypeAssertionData).asExpr;
	const held = taken.nodeType != null && taken.nodeType.kind == TypeKind.Var ? taken.nodeType.typeReturn : taken.nodeType;
	if (!isViewType(held)) return;
	const roots: Symbol[] = [];
	rootsOf(taken, roots);
	for (const r of roots) {
		const t = r.symbolType;
		if (r.symbolKind != SymbolKind.Parameter || t == null || t.kind != TypeKind.Var) continue;
		addError(u.ctx, `'${r.name}' is a ref or out parameter that holds a view, so its address cannot be taken: a write through the pointer would hide the view from its caller`, node.location.line, node.location.column);
		return;
	}
}

function hasViewRefParam(routine: Node | null): boolean {
	if (routine == null || routine.paramSyms == null) return false;
	for (const p of routine.paramSyms) {
		const t = p.symbolType;
		if (t != null && t.kind == TypeKind.Var && isViewType(t.typeReturn)) return true;
	}
	return false;
}

function refuseInferredViewResult(ctx: CheckerContext, routine: Node, declared: string): void {
	if (declared != "") return;
	const sig = routine.nodeType;
	if (sig == null || sig.kind != TypeKind.Function || sig.typeReturn == null) return;
	const view = nestedViewType(sig.typeReturn);
	if (view == null) return;
	addError(ctx, `a return value of type ${typeDisplayName(sig.typeReturn)} cannot hold ${nestedViewShown(sig.typeReturn, view)} inside it: a view borrows memory its source can free while the container still holds it — use ${ownedAlternativeOf(view)}`, routine.location.line, routine.location.column);
}

function viewStructResult(routine: Node | null): Type | null {
	const sig = routine != null ? routine.nodeType : null;
	if (sig == null || sig.kind != TypeKind.Function || sig.typeReturn == null) return null;
	return isViewStruct(withoutNullMember(sig.typeReturn)) ? sig.typeReturn : null;
}

function refuseViewStructReturns(ctx: CheckerContext, u: BorrowUnit | null, routine: Node | null, name: string, body: Node): void {
	const result = viewStructResult(routine);
	if (result == null || routine == null) return;
	const arms: Node[] = [];
	if (body.kind == NodeKind.BlockStmt) collectReturnArms(body, arms);
	else splitArms(body, arms);
	const first = routine.paramSyms != null && routine.paramSyms.length > 0 ? routine.paramSyms[0] : null;
	const what = `'${name}' returns ${typeDisplayName(result)}, a struct that holds a view, so what it views must come from its first parameter`;
	for (const arm of arms) {
		if (isNullArm(arm)) continue;
		const sources: Node[] = [];
		const paths: string[] = [];
		const handles: string[] = [];
		pathSources(arm, sources, paths, handles);
		let why = "";
		for (let k = 0; k < sources.length && why == ""; k += 1) {
			why = isTempPath(paths[k])
				? ((paths[k] != TEMP_OWNED && sources[k].kind == NodeKind.ObjectLiteral) || holdsNoStorage(sources[k]) ? "" : "cannot borrow from a temporary")
				: viewStructRootFault(u, routine, first, sources[k].resolvedSym, paths[k], []);
		}
		if (why == "" && u != null) why = changedAfterReturn(u, body, arm, sources, paths);
		if (why != "") addError(ctx, `${why}: ${what}`, arm.location.line, arm.location.column);
	}
}

function changedAfterReturn(u: BorrowUnit, body: Node, arm: Node, sources: Node[], paths: string[]): string {
	const late: Node[] = [];
	lateRegions(body, arm, late);
	if (late.length == 0) return "";
	const roots: Symbol[] = [];
	for (let k = 0; k < sources.length; k += 1) {
		if (!isTempPath(paths[k])) viewRoots(u, sources[k].resolvedSym, roots);
	}
	for (const r of roots) {
		const id = variableId(u.p, r);
		const root = id >= 0 ? ufRoot(u.p, id) : -1;
		if (root < 0 || u.p.vars[root].con.kind != CK_ROOT_OF) continue;
		const g = u.p.graphs[u.p.vars[root].con.target];
		for (const site of g.sites) {
			if (site == null) continue;
			for (const region of late) {
				if (containsNode(region, site)) return `'${r.name}' is changed at ${site.location.line}:${site.location.column} by a finally or defer that runs after the return`;
			}
		}
	}
	return "";
}

function lateRegions(node: Node | null, arm: Node, out: Node[]): void {
	if (node == null || !containsNode(node, arm)) return;
	if (node.kind == NodeKind.BlockStmt) {
		for (const st of (node.data as BlockStmtData).statements) {
			if (st.kind == NodeKind.DeferStmt) out.push((st.data as DeferStmtData).deferExpr);
		}
	}
	if (node.kind == NodeKind.TryCatchStmt) {
		const fin = (node.data as TryCatchStmtData).finallyBody;
		if (fin != null && !containsNode(fin, arm)) out.push(fin);
	}
	forEachChild(node, (child: Node): void => { lateRegions(child, arm, out); });
}

function viewRoots(u: BorrowUnit, sym: Symbol | null, out: Symbol[]): void {
	if (sym == null || out.includes(sym)) return;
	out.push(sym);
	const id = variableId(u.p, sym);
	if (id < 0 || u.p.vars[id].external || !isBorrower(u, sym)) return;
	for (const b of u.p.vars[id].borrowsFrom) { viewRoots(u, u.p.vars[b].sym, out); }
}

function viewStructRootFault(u: BorrowUnit | null, routine: Node, first: Symbol | null, sym: Symbol | null, path: string, seen: Symbol[]): string {
	if (sym != null && sym == first && (hasFlag(sym, SymbolFlag.Sink) || ownedByTheCall(sym.symbolType) || inlineInTheCall(sym.symbolType, path))) return `'${sym.name}' is owned by the call, so it is freed at the return`;
	if (sym == null || sym == first || seen.includes(sym)) return "";
	seen.push(sym);
	if (sym.name == "this" && routine.kind == NodeKind.MethodDecl) return "";
	if (sym.symbolKind == SymbolKind.Parameter) return `'${sym.name}' is not the first parameter`;
	if (hasFlag(sym, SymbolFlag.Global)) {
		if (!hasFlag(sym, SymbolFlag.Mutable) && keysOf(sym.symbolType, false).length == 0) return "";
		if (!hasFlag(sym, SymbolFlag.Mutable) && sym.symbolKind == SymbolKind.Variable && isReadonlyView(sym.symbolType) && path == "") return "";
		return `'${sym.name}' must borrow from the first parameter`;
	}
	const id = u != null ? variableId(u.p, sym) : -1;
	if (id < 0 || u == null) return `'${sym.name}' escapes its stack frame`;
	const v = u.p.vars[id];
	if (v.external) return `'${sym.name}' must borrow from the first parameter`;
	if (!isBorrower(u, sym)) return `'${sym.name}' escapes its stack frame`;
	if (v.fromTemp) return `'${sym.name}' borrows from a temporary`;
	for (let b = 0; b < v.borrowsFrom.length; b += 1) {
		const why = viewStructRootFault(u, routine, first, u.p.vars[v.borrowsFrom[b]].sym, v.borrowPaths[b], seen);
		if (why != "") return why;
	}
	return "";
}

function inlineInTheCall(t0: Type | null, path: string): boolean {
	const t = withoutNullMember(t0!);
	if (t0 == null || t == null || t.kind == TypeKind.Var || path == "") return false;
	const end = followPath(t, path);
	let e = end.t;
	while (e != null && (e.kind == TypeKind.Alias || e.kind == TypeKind.Distinct)) e = e.typeReturn;
	return !end.crossed && e != null && e.kind == TypeKind.SizedArray;
}

function ownedByTheCall(t0: Type | null): boolean {
	let t = t0;
	while (t != null && (t.kind == TypeKind.Alias || t.kind == TypeKind.Distinct)) t = t.typeReturn;
	return t != null && (t.kind == TypeKind.Sink || isOwnedRef(t) || t.kind == TypeKind.SizedArray);
}

function suspendsWhileUsed(u: BorrowUnit, v: VarEntry, ctx: CheckerContext, src: VarEntry): boolean {
	for (let i = 0; i < u.suspends.length; i += 1) {
		const t = u.suspends[i];
		if (t <= v.aliveStart || t >= v.aliveEnd) continue;
		const site = u.suspendSites[i];
		const what = site.kind == NodeKind.YieldExpr ? "yield" : "await";
		addError(ctx, `cannot borrow '${v.sym.name}': what it borrows from ('${src.sym.name}') is shared and is read after the ${what} at line ${site.location.line}, where another task can change it; take the view after the ${what}, or copy what it reads`, v.sym.location.line, v.sym.location.column);
		return true;
	}
	return false;
}

function borrowedRoot(node: Node | null): Node | null {
	let n = node;
	while (n != null) {
		match (n.kind) {
			NodeKind.Identifier => { return n; },
			NodeKind.MemberExpr => { n = (n.data as MemberExprData).object; },
			NodeKind.ArrayAccess => { n = (n.data as ArrayAccessData).array; },
			NodeKind.HiddenDeref | NodeKind.HiddenAddr => { n = (n.data as { expr: Node }).expr; },
			NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => { n = (n.data as HiddenStdConvData).convExpr; },
			NodeKind.TypeAssertion => { n = (n.data as TypeAssertionData).asExpr; },
			NodeKind.CallExpr => {
				if (n.nodeType == null || n.nodeType.kind != TypeKind.Borrow) return null;
				const args = (n.data as CallExprData).arguments;
				const recv = receiverOf(n);
				n = recv != null ? recv : (args.length > 0 ? args[0] : null);
			},
			_ => { return null; },
		};
	}
	return null;
}

export function passedByValue(t: Readonly<Type | null>): boolean {
	if (t == null) return false;
	if (t.kind == TypeKind.Alias || t.kind == TypeKind.Distinct) return passedByValue(t.typeReturn);
	if (isPrimitiveKind(t.kind) || isStructType(t)) return true;
	return match (t.kind) {
		TypeKind.String | TypeKind.StringLiteral | TypeKind.BigInt | TypeKind.Enum | TypeKind.EnumLiteral | TypeKind.BooleanLiteral
			| TypeKind.Tuple | TypeKind.Union | TypeKind.Result | TypeKind.SizedArray | TypeKind.Function => true,
		_ => false,
	};
}

function checkBorrowReturns(ctx: CheckerContext, routine: Node, name: string, body: Node | null): void {
	const sig = routine.nodeType;
	if (body != null && sig != null && sig.kind == TypeKind.Function && sig.typeReturn != null && sig.typeReturn.kind != TypeKind.Borrow && returnsView(sig.typeReturn)) {
		const arms: Node[] = [];
		collectReturnArms(body, arms);
		refuseViewReturns(ctx, arms, routine, name, sig.typeReturn);
		return;
	}
	if (body == null || sig == null || sig.kind != TypeKind.Function || sig.typeReturn == null || sig.typeReturn.kind != TypeKind.Borrow) return;
	const shown = typeDisplayName(sig.typeReturn);
	const first = routine.paramSyms != null && routine.paramSyms.length > 0 ? routine.paramSyms[0] : null;
	refuseBorrowedReturns(ctx, body, first, name, shown);
}

function refuseBorrowedReturns(ctx: CheckerContext, node: Node | null, first: Symbol | null, name: string, shown: string): void {
	if (node == null) return;
	if (node.kind == NodeKind.FunctionDecl || node.kind == NodeKind.ArrowFunction || node.kind == NodeKind.FunctionExpr
		|| node.kind == NodeKind.ClassDecl || node.kind == NodeKind.MethodDecl || node.kind == NodeKind.ConstructorDecl) return;
	if (node.kind == NodeKind.ReturnStmt) {
		const arg = (node.data as ReturnStmtData).argument;
		if (arg == null) return;
		const root = borrowedRoot(arg);
		const sym = root != null ? root.resolvedSym : null;
		const what = `'${name}' returns ${shown}, a view into its first parameter`;
		if (root == null) {
			addError(ctx, `cannot borrow from this expression, it is not a path expression: ${what}, so a return must name a variable, field or element reached from it`, arg.location.line, arg.location.column);
		} else if (sym != null && sym != first) {
			const why = sym.symbolKind == SymbolKind.Parameter ? "is not the first parameter" : hasFlag(sym, SymbolFlag.Global) ? "must borrow from the first parameter" : "escapes its stack frame";
			addError(ctx, `'${sym.name}' ${why}: ${what}`, arg.location.line, arg.location.column);
		}
		return;
	}
	forEachChild(node, (child: Node): void => { refuseBorrowedReturns(ctx, child, first, name, shown); });
}

function collectReturnArms(node: Node | null, out: Node[]): void {
	if (node == null) return;
	if (node.kind == NodeKind.FunctionDecl || node.kind == NodeKind.ArrowFunction || node.kind == NodeKind.FunctionExpr
		|| node.kind == NodeKind.ClassDecl || node.kind == NodeKind.MethodDecl || node.kind == NodeKind.ConstructorDecl) return;
	if (node.kind == NodeKind.ReturnStmt) {
		splitArms((node.data as ReturnStmtData).argument, out);
		return;
	}
	forEachChild(node, (child: Node): void => { collectReturnArms(child, out); });
}

function splitArms(node: Node | null, out: Node[]): void {
	if (node == null) return;
	if (node.kind == NodeKind.ConditionalExpr) {
		splitArms((node.data as ConditionalExprData).ternaryConsequent, out);
		splitArms((node.data as ConditionalExprData).ternaryAlternate, out);
	} else if (node.kind == NodeKind.BinaryExpr && (node.data as BinaryExprData).operator == "??") {
		splitArms((node.data as BinaryExprData).left, out);
		splitArms((node.data as BinaryExprData).right, out);
	} else {
		out.push(node);
	}
}

function isNullArm(node: Node): boolean {
	if (node.kind == NodeKind.TypeAssertion) return isNullArm((node.data as TypeAssertionData).asExpr);
	if (node.kind == NodeKind.HiddenStdConv || node.kind == NodeKind.HiddenSubConv) return isNullArm((node.data as HiddenStdConvData).convExpr);
	return node.kind == NodeKind.NullLiteral;
}

function checkClosureViewReturns(ctx: CheckerContext, routine: Node, body: Node | null): void {
	const sig = routine.nodeType;
	if (body == null || sig == null || sig.kind != TypeKind.Function || sig.typeReturn == null || sig.typeReturn.kind == TypeKind.Borrow || !returnsView(sig.typeReturn)) return;
	const arms: Node[] = [];
	if (body.kind == NodeKind.BlockStmt) collectReturnArms(body, arms);
	else splitArms(body, arms);
	refuseViewReturns(ctx, arms, routine, "function value", sig.typeReturn);
}

function refuseViewReturns(ctx: CheckerContext, arms: Node[], routine: Node, name: string, result: Type): void {
	let view: Node | null = null;
	for (const arm of arms) {
		if (!isNullArm(arm) && viewReturnFault(arm, routine, false) == "") { view = arm; break; }
	}
	const shown = typeDisplayName(result);
	const owning = owningResult(result);
	for (const arm of arms) {
		const why = viewReturnFault(arm, routine, false);
		if (why == "") continue;
		const at = `${arm.location.line}:${arm.location.column}`;
		if (view == null) {
			addError(ctx, `${why}: '${name}' returns ${shown}, a borrow of a view parameter or of a Readonly module constant, so this return must be a path from one; declare the owning result type '${owning}' to return it`, arm.location.line, arm.location.column);
		} else {
			addError(ctx, `${why}: '${name}' returns ${shown}, a borrow, but mixes the return at ${at}, which is not a path from a view parameter, with the view return at ${view.location.line}:${view.location.column}; split '${name}' into a view routine and an owning one, or return an explicit structural copy of the view (clone or spread) under the owning result type '${owning}'`, arm.location.line, arm.location.column);
		}
	}
}

function owningResult(t: Type): string {
	if (t.kind != TypeKind.Union || isReadonlyView(t)) return typeDisplayName(withoutReadonlyView(t));
	const parts: string[] = [];
	for (const m of t.typeChildren) { parts.push(typeDisplayName(withoutReadonlyView(m))); }
	return parts.join(" | ");
}

function viewReturnFault(node: Node, routine: Node, stepped: boolean): string {
	match (node.kind) {
		NodeKind.NullLiteral => { return ""; },
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			const a = viewReturnFault(d.ternaryConsequent, routine, stepped);
			return a != "" ? a : viewReturnFault(d.ternaryAlternate, routine, stepped);
		},
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			if (d.operator != "??") return "cannot borrow from this expression, it is not a path expression";
			const a = viewReturnFault(d.left, routine, stepped);
			return a != "" ? a : viewReturnFault(d.right, routine, stepped);
		},
		NodeKind.MemberExpr => { return viewReturnFault((node.data as MemberExprData).object, routine, true); },
		NodeKind.ArrayAccess => { return viewReturnFault((node.data as ArrayAccessData).array, routine, true); },
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => { return viewReturnFault((node.data as { expr: Node }).expr, routine, stepped); },
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => { return viewReturnFault((node.data as HiddenStdConvData).convExpr, routine, stepped); },
		NodeKind.TypeAssertion => { return viewReturnFault((node.data as TypeAssertionData).asExpr, routine, stepped); },
		NodeKind.CallExpr => {
			if (!isViewCall(node)) return "cannot borrow from this expression, it is not a path expression";
			const sources: Node[] = [];
			viewCallSources(node, sources);
			for (const a of sources) {
				if (!carriesBorrow(a)) continue;
				const why = viewReturnFault(a, routine, true);
				if (why != "") return why;
			}
			return "";
		},
		NodeKind.Identifier => { return viewRootFault(node, routine, stepped); },
		_ => { return "cannot borrow from this expression, it is not a path expression"; },
	};
}

function carriesBorrow(arg: Node): boolean {
	return arg.nodeType == null || typeCarriesRef(arg.nodeType);
}

function viewRootFault(id: Node, routine: Node, stepped: boolean): string {
	const sym = id.resolvedSym;
	if (sym == null) return signatureParamFault(routine, (id.data as IdentifierData).name) ?? "cannot borrow from this expression, it is not a path expression";
	if (sym.symbolKind == SymbolKind.Parameter) {
		if (!isOwnParam(routine, sym)) return `'${sym.name}' is not a parameter of this routine`;
		return signatureParamFault(routine, sym.name) ?? "";
	}
	if (hasFlag(sym, SymbolFlag.Global) && !hasFlag(sym, SymbolFlag.StaticLocal)) {
		if (hasFlag(sym, SymbolFlag.Mutable) || sym.symbolKind != SymbolKind.Variable || !isReadonlyView(sym.symbolType)) return `'${sym.name}' is not a Readonly module constant`;
		if (stepped) return `a path below the module constant '${sym.name}' can be released while borrowed`;
		return "";
	}
	const bound = constRefAlias(sym);
	if (bound != null && viewReturnFault(bound, routine, stepped) == "") return "";
	if (hasFlag(sym, SymbolFlag.ForVar) && !hasFlag(sym, SymbolFlag.Mutable) && sym.symbolType != null && holdsReference(sym)) {
		const iterated: Node[] = [];
		collectForOfIterable(routine, sym, iterated);
		if (iterated.length == 1 && viewReturnFault(iterated[0], routine, true) == "") return "";
	}
	return `'${sym.name}' escapes its stack frame`;
}

function holdsReference(sym: Symbol): boolean {
	return withoutReadonlyView(withoutNullMember(withoutReadonlyView(sym.symbolType))).kind == TypeKind.Ref;
}

function collectForOfIterable(node: Node | null, sym: Symbol, out: Node[]): void {
	if (node == null || out.length > 0) return;
	if (node.kind == NodeKind.ForOfStmt && node.resolvedSym == sym) {
		out.push((node.data as ForOfStmtData).forOfIterable);
		return;
	}
	forEachChild(node, (child: Node): void => { collectForOfIterable(child, sym, out); });
}

function constRefAlias(sym: Symbol): Node | null {
	if (sym.symbolKind != SymbolKind.Variable || hasFlag(sym, SymbolFlag.Mutable) || hasFlag(sym, SymbolFlag.Global) || sym.symbolType == null) return null;
	if (!holdsReference(sym)) return null;
	const decl = sym.declNode;
	if (decl == null || decl.kind != NodeKind.VariableDecl || decl.resolvedSym != sym) return null;
	return (decl.data as VariableDeclData).initializer;
}

// The signature carries a parameter's sink mode, and still names a parameter a generic body leaves
// unbound until it is instantiated.
function signatureParamFault(routine: Node, name: string): string | null {
	const sig = routine.nodeType;
	if (sig == null || sig.kind != TypeKind.Function || sig.typeNames == null) return null;
	for (let i = 0; i < sig.typeNames.length; i += 1) {
		if (sig.typeNames[i] != name) continue;
		const t = i < sig.typeChildren.length ? sig.typeChildren[i] : null;
		return t != null && t.kind == TypeKind.Sink ? `'${name}' is a sink parameter, owned by the routine` : "";
	}
	return null;
}

function isOwnParam(routine: Node, sym: Symbol): boolean {
	if (routine.paramSyms != null) {
		for (const p of routine.paramSyms) { if (p == sym) return true; }
	}
	return sym.name == "this";
}

function scanUnits(ctx: CheckerContext, node: Node | null): void {
	if (node == null) return;
	match (node.kind) {
		NodeKind.FunctionDecl => {
			checkBorrowReturns(ctx, node, (node.data as FunctionDeclData).fnName, (node.data as FunctionDeclData).fnBody);
			refuseInferredViewResult(ctx, node, (node.data as FunctionDeclData).fnReturnType);
			checkUnit(ctx, (node.data as FunctionDeclData).fnBody, node, (node.data as FunctionDeclData).fnName);
		},
		NodeKind.MethodDecl => {
			checkBorrowReturns(ctx, node, (node.data as MethodDeclData).methodName, (node.data as MethodDeclData).methodBody);
			refuseInferredViewResult(ctx, node, (node.data as MethodDeclData).methodReturnType);
			checkUnit(ctx, (node.data as MethodDeclData).methodBody, node, (node.data as MethodDeclData).methodName);
		},
		NodeKind.ConstructorDecl => checkUnit(ctx, (node.data as ConstructorDeclData).ctorBody),
		NodeKind.ArrowFunction => {
			checkClosureViewReturns(ctx, node, (node.data as ArrowFunctionData).arrowBody);
			refuseInferredViewResult(ctx, node, (node.data as ArrowFunctionData).arrowReturnType);
			checkUnit(ctx, (node.data as ArrowFunctionData).arrowBody, node, "function value");
		},
		NodeKind.FunctionExpr => {
			checkClosureViewReturns(ctx, node, (node.data as FunctionExprData).funcExprBody);
			refuseInferredViewResult(ctx, node, (node.data as FunctionExprData).funcExprReturnType);
			checkUnit(ctx, (node.data as FunctionExprData).funcExprBody, node, "function value");
		},
		NodeKind.TestDecl => checkUnit(ctx, (node.data as TestDeclData).testBody),
		_ => {},
	};
	forEachChild(node, (child: Node): void => { scanUnits(ctx, child); });
}

export function checkRoutineBorrows(ctx: CheckerContext, routine: Node): void {
	scanUnits(ctx, routine);
	checkPointerEscapesIn(ctx, routine);
}

export function checkViewBorrows(ctx: CheckerContext, program: Node): void {
	if (program == null || program.kind != NodeKind.Program) return;
	checkUnit(ctx, program);
	for (const stmt of (program.data as ProgramData).programStmts) { scanUnits(ctx, stmt); }
}
