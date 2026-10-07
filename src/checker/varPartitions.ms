import {
	Node, NodeKind, NodeFlag, Symbol, SymbolKind, Type, TypeKind,
	VariableDeclData, MemberExprData, ArrayAccessData, BlockStmtData, BinaryExprData, UpdateExprData,
	WhileStmtData, ForStmtData, ForOfStmtData, ForInStmtData, DoWhileStmtData, CallExprData,
	ObjectLiteralData, ArrayLiteralData, NewExprData, MoveExprData, OutExprData, DeferStmtData,
	TypeAssertionData, HiddenStdConvData, ConditionalExprData, FunctionDeclData, MethodDeclData, ConstructorDeclData,
	ArrowFunctionData, FunctionExprData, TestDeclData, ProgramData,
} from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { isPrimitiveKind, isViewType, isReadonlyView, typeDisplayName } from "./types";
import { hasFlag, SymbolFlag } from "./symbol";
import { CheckerContext, addError, dispatchEntryFor, dispatchOverridesFor } from "./context";
import { isAddressTaking, checkPointerEscapesIn } from "./pointerAddress";
import { isMutatingArrayMethod } from "./paramMutationAnalysis";

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
}

export function createPartitions(): Partitions {
	return {
		abstractTime: 0, vars: [], graphs: [],
		inConstructor: 0, inConditional: 0, inLoop: 0, inAsgnSource: 0,
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

function reaches(changed: string, handles: string): boolean {
	for (const h of handles.split("|")) {
		if (h != "" && prefixOf(changed, h == "@" ? "" : h)) return true;
	}
	return false;
}

function firstMutationIn(g: MutationInfo, v: VarEntry, source: Symbol, handles: string): int32 {
	if ((g.flags & SF_IS_MUTATED) == 0) return -1;
	for (let i = 0; i < g.mutations.length; i += 1) {
		const m = g.mutations[i];
		if (m < v.aliveStart || m > v.aliveEnd || g.roots[i] == v.sym) continue;
		const keep = g.keeps[i];
		if (!(keep.length == 1 && keep[0] == -1) && encloses(keep, v.scopePath)) continue;
		if (g.roots[i] != source || reaches(g.paths[i], handles)) return i;
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

interface ResizeSummary {
	unknown: boolean;
	keys: string[];
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
}

function noResize(): ResizeSummary {
	return { unknown: false, keys: [] };
}

function anyResize(): ResizeSummary {
	return { unknown: true, keys: [] };
}

function addKey(out: string[], k: string): void {
	if (!out.includes(k)) out.push(k);
}

function keyMatches(a: string, b: string): boolean {
	return a == "*" || b == "*" || a == b;
}

function matchesAnyKey(k: string, keys: string[]): boolean {
	for (const x of keys) {
		if (keyMatches(k, x)) return true;
	}
	return false;
}

function arrayKey(elem: Type | null): string {
	if (elem == null || elem.kind == TypeKind.GenericParam || elem.kind == TypeKind.Unknown) return "*";
	return "array:" + typeDisplayName(elem);
}

function sharedKeys(t: Type | null, viaRef: boolean, depth: int32, out: string[]): void {
	if (t == null || depth > 6) {
		addKey(out, "*");
		return;
	}
	match (t.kind) {
		TypeKind.Ref => sharedKeys(t.typeReturn, true, depth + 1, out),
		TypeKind.Var => sharedKeys(t.typeReturn, true, depth + 1, out),
		TypeKind.Array => {
			if (viaRef) addKey(out, arrayKey(t.typeReturn));
			sharedKeys(t.typeReturn, viaRef, depth + 1, out);
		},
		TypeKind.String => { if (viaRef) addKey(out, "string"); },
		TypeKind.Struct | TypeKind.Tuple | TypeKind.Union | TypeKind.Result => {
			for (const c of t.typeChildren) { sharedKeys(c, viaRef, depth + 1, out); }
		},
		TypeKind.GenericInstance => {
			if (t.typeReturn != null) {
				sharedKeys(t.typeReturn, viaRef, depth + 1, out);
			} else {
				for (const c of t.typeChildren) { sharedKeys(c, viaRef, depth + 1, out); }
			}
		},
		TypeKind.SizedArray | TypeKind.Alias | TypeKind.Distinct | TypeKind.Sink | TypeKind.Lent => sharedKeys(t.typeReturn, viaRef, depth + 1, out),
		TypeKind.GenericParam | TypeKind.Unknown | TypeKind.TypeReference | TypeKind.Pending => addKey(out, "*"),
		_ => {},
	};
}

function keysOf(t: Type | null, viaRef: boolean): string[] {
	const out: string[] = [];
	sharedKeys(t, viaRef, 0, out);
	return out;
}

function handlePaths(t: Type | null, keys: string[], viaRef: boolean, depth: int32, prefix: string, out: string[]): void {
	if (t == null || depth > 6) {
		addKey(out, prefix);
		return;
	}
	match (t.kind) {
		TypeKind.Ref | TypeKind.Var => handlePaths(t.typeReturn, keys, true, depth + 1, prefix, out),
		TypeKind.Array => {
			if (viaRef && matchesAnyKey(arrayKey(t.typeReturn), keys)) addKey(out, prefix);
			handlePaths(t.typeReturn, keys, viaRef, depth + 1, prefix + "[]", out);
		},
		TypeKind.String => { if (viaRef && matchesAnyKey("string", keys)) addKey(out, prefix); },
		TypeKind.Struct => {
			for (let i = 0; i < t.typeChildren.length; i += 1) {
				const name = i < t.typeNames.length ? t.typeNames[i] : "";
				if (name == "") {
					const inner: string[] = [];
					handlePaths(t.typeChildren[i], keys, viaRef, depth + 1, prefix, inner);
					if (inner.length > 0) addKey(out, prefix);
				} else {
					handlePaths(t.typeChildren[i], keys, viaRef, depth + 1, prefix + "." + name, out);
				}
			}
		},
		TypeKind.Tuple | TypeKind.SizedArray => {
			if (t.kind == TypeKind.SizedArray) {
				handlePaths(t.typeReturn, keys, viaRef, depth + 1, prefix + "[]", out);
			} else {
				for (const c of t.typeChildren) { handlePaths(c, keys, viaRef, depth + 1, prefix + "[]", out); }
			}
		},
		TypeKind.Union | TypeKind.Result => {
			const inner: string[] = [];
			for (const c of t.typeChildren) { handlePaths(c, keys, viaRef, depth + 1, prefix, inner); }
			if (inner.length > 0) addKey(out, prefix);
		},
		TypeKind.GenericInstance => {
			if (t.typeReturn != null) {
				handlePaths(t.typeReturn, keys, viaRef, depth + 1, prefix, out);
			} else {
				const inner: string[] = [];
				for (const c of t.typeChildren) { handlePaths(c, keys, viaRef, depth + 1, prefix, inner); }
				if (inner.length > 0) addKey(out, prefix);
			}
		},
		TypeKind.Alias | TypeKind.Distinct | TypeKind.Sink | TypeKind.Lent => handlePaths(t.typeReturn, keys, viaRef, depth + 1, prefix, out),
		TypeKind.GenericParam | TypeKind.Unknown | TypeKind.TypeReference | TypeKind.Pending => { if (keys.length > 0) addKey(out, prefix); },
		_ => {},
	};
}

function effectKeys(available: string[], s: ResizeSummary): string[] {
	if (s.unknown) return available;
	const out: string[] = [];
	for (const k of available) {
		if (matchesAnyKey(k, s.keys)) addKey(out, k);
	}
	return out;
}

function routineBody(decl: Node | null): Node | null {
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

function isDispatched(sym: Symbol): boolean {
	const entry = dispatchEntryFor(sym);
	if (entry == null) return false;
	return !entry.overloaded && dispatchOverridesFor(entry.classSym, entry.methodName).length > 0;
}

function externSummary(sym: Symbol): ResizeSummary {
	const t = sym.symbolType;
	if (t == null || t.kind != TypeKind.Function) return anyResize();
	for (const formal of t.typeChildren) {
		for (const k of keysOf(formal, false)) {
			if (k != "string") return anyResize();
		}
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
		const s = noResize();
		scanResizes(routineBody(ctor), s);
		return s;
	}
	for (const a of (node.data as NewExprData).newArguments) {
		for (const k of keysOf(a.nodeType, false)) {
			if (k != "string") return anyResize();
		}
	}
	return noResize();
}

function scanResizes(node: Node | null, s: ResizeSummary): void {
	if (node == null || s.unknown) return;
	match (node.kind) {
		NodeKind.CallExpr => {
			const recv = receiverOf(node);
			if (recv != null && resizesReceiver(node, recv)) {
				const t = recv.nodeType;
				const held = t != null && t.kind == TypeKind.Ref && t.typeReturn != null ? t.typeReturn : t;
				addKey(s.keys, held != null && held.kind == TypeKind.Array ? arrayKey(held.typeReturn) : "string");
			} else {
				const c = calleeSummary(node);
				if (c.unknown) {
					s.unknown = true;
					return;
				}
				for (const k of c.keys) { addKey(s.keys, k); }
			}
		},
		NodeKind.NewExpr => {
			const c = newSummary(node);
			if (c.unknown) {
				s.unknown = true;
				return;
			}
			for (const k of c.keys) { addKey(s.keys, k); }
		},
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			if (isAssignOp(d.operator)) replacedKeys(d.left, s);
		},
		NodeKind.MoveExpr => replacedKeys((node.data as MoveExprData).moveArg, s),
		_ => {},
	};
	if (s.unknown) return;
	forEachChild(node, (child: Node): void => { scanResizes(child, s); });
}

function replacedKeys(target: Node | null, s: ResizeSummary): void {
	if (target == null) return;
	const byRef = target.kind == NodeKind.Identifier && target.resolvedSym != null
		&& target.resolvedSym.symbolType != null && target.resolvedSym.symbolType.kind == TypeKind.Var;
	if (target.kind != NodeKind.MemberExpr && target.kind != NodeKind.ArrayAccess && !byRef) return;
	for (const k of keysOf(target.nodeType, true)) { addKey(s.keys, k); }
}

function sameSummary(a: ResizeSummary, b: ResizeSummary): boolean {
	if (a.unknown != b.unknown || a.keys.length != b.keys.length) return false;
	for (const k of a.keys) {
		if (!b.keys.includes(k)) return false;
	}
	return true;
}

function scanRoutine(sym: Symbol): ResizeSummary {
	const s = noResize();
	resizeStack.push(sym);
	scanResizes(routineBody(sym.declNode), s);
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

interface ClosureEffect {
	node: Node;
	captured: Symbol[];
	summary: ResizeSummary;
}

interface BorrowUnit {
	p: Partitions;
	pass: int32;
	scope: int32[];
	defers: Node[];
	ctx: CheckerContext;
	pointers: Symbol[];
	blocks: Node[];
	closures: ClosureEffect[];
	suspends: int32[];
	suspendSites: Node[];
	escaped: Symbol[];
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

function collectPointers(node: Node | null, out: Symbol[]): void {
	if (node == null) return;
	if (node.kind == NodeKind.FunctionDecl || node.kind == NodeKind.ArrowFunction || node.kind == NodeKind.FunctionExpr
		|| node.kind == NodeKind.ClassDecl || node.kind == NodeKind.MethodDecl || node.kind == NodeKind.ConstructorDecl) return;
	if (node.kind == NodeKind.VariableDecl && node.resolvedSym != null && takesAddress((node.data as VariableDeclData).initializer)) {
		out.push(node.resolvedSym);
	}
	if (node.kind == NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		if (d.operator == "=" && d.left.kind == NodeKind.Identifier && d.left.resolvedSym != null && takesAddress(d.right)) {
			out.push(d.left.resolvedSym);
		}
	}
	forEachChild(node, (child: Node): void => { collectPointers(child, out); });
}

function carriesPointer(t: Type | null, depth: int32 = 0): boolean {
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
		NodeKind.ArrayLiteral => { for (const e of (node.data as ArrayLiteralData).elements) { rootsOf(e, out); } },
		NodeKind.ObjectLiteral => { for (const e of (node.data as ObjectLiteralData).properties) { rootsOf(e, out); } },
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

function receiverOf(call: Node): Node | null {
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

function supplies(t: Type | null): boolean {
	if (t == null) return true;
	return isViewType(t) || t.kind == TypeKind.String || t.kind == TypeKind.SizedArray || ownsStorage(t);
}

function isSlice(n: Node): boolean {
	return n.kind == NodeKind.ArrayAccess && isViewType(n.nodeType);
}

const TEMP_PATH = "#";

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
				pathSources(d.ternaryConsequent, out, paths, handles, path);
				pathSources(d.ternaryAlternate, out, paths, handles, path);
				return;
			},
			NodeKind.CallExpr => {
				const recv = receiverOf(n);
				if (recv != null && supplies(recv.nodeType)) pathSources(recv, out, paths, handles, "");
				for (const a of (n.data as CallExprData).arguments) {
					if (supplies(a.nodeType)) pathSources(a, out, paths, handles, "");
				}
				if (!isViewType(n.nodeType)) addTemp(n, out, paths, handles);
				return;
			},
			NodeKind.ObjectLiteral | NodeKind.ArrayLiteral => {
				const members = n.kind == NodeKind.ObjectLiteral ? (n.data as ObjectLiteralData).properties : (n.data as ArrayLiteralData).elements;
				for (const m of members) {
					if (supplies(m.nodeType)) pathSources(m, out, paths, handles, "");
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

function addTemp(n: Node, out: Node[], paths: string[], handles: string[]): void {
	out.push(n);
	paths.push(TEMP_PATH);
	handles.push("");
}

function pathOf(node: Node | null): string {
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

function mutateRoots(u: BorrowUnit, node: Node | null, site: Node, suffix: string = ""): void {
	const roots: Symbol[] = [];
	rootsOf(node, roots);
	const path = roots.length == 1 ? pathOf(node) + suffix : "";
	for (const r of roots) {
		const id = variableId(u.p, r);
		if (id >= 0 && !u.p.vars[id].external && isBorrower(u, r) && u.p.vars[id].borrowsFrom.length > 0) {
			const v = u.p.vars[id];
			for (let b = 0; b < v.borrowsFrom.length; b += 1) {
				potentialMutation(u.p, u.p.vars[v.borrowsFrom[b]].sym, site, v.borrowPaths[b] + path);
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
	for (let k = 0; k < sources.length; k += 1) {
		const s = sources[k];
		if (pointer) handles[k] = withoutHandle(handles[k], paths[k]);
		if (paths[k] == TEMP_PATH) {
			if (!encloses(u.scope, u.p.vars[vid].scopePath)) {
				addError(u.ctx, `'${dest.name}' borrows from a temporary that ends with its block, which does not live long enough`, src.location.line, src.location.column);
				return;
			}
			continue;
		}
		const sym = s.resolvedSym;
		if (sym == null) continue;
		if (hasFlag(sym, SymbolFlag.Global)) {
			if (!hasFlag(sym, SymbolFlag.Mutable) && keysOf(sym.symbolType, false).length == 0) continue;
			addError(u.ctx, `cannot borrow '${dest.name}' from module-level '${sym.name}': a call can change it unseen; pass it as a parameter`, src.location.line, src.location.column);
			return;
		}
		const sid = variableId(u.p, sym);
		if (sid < 0) continue;
		const from = u.p.vars[sid];
		if (!from.external && from.sym != dest && isBorrower(u, from.sym)) {
			for (let b = 0; b < from.borrowsFrom.length; b += 1) {
				const base = from.borrowPaths[b];
				addBorrow(u.p.vars[vid], from.borrowsFrom[b], base + paths[k], from.borrowHandles[b] + relocate(handles[k], base));
			}
			continue;
		}
		addBorrow(u.p.vars[vid], sid, paths[k], handles[k]);
	}
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
	if (left.kind == NodeKind.Identifier && left.resolvedSym != null) {
		const sym = left.resolvedSym;
		if (d.operator == "=" && isBorrower(u, sym)) {
			borrowFrom(u, sym, d.right);
			return;
		}
		if (ownsStorage(sym.symbolType)) potentialMutation(u.p, sym, d.left);
		if (d.operator == "=") {
			deps(u, sym, d.right);
			if (reachableByCalls(u, sym, "")) escape(u, d.right);
		}
		return;
	}
	if (ownsStorage(left.nodeType)) mutateRoots(u, left, d.left);
	if (d.operator != "=") return;
	const targets0: Symbol[] = [];
	rootsOf(left, targets0);
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

function escape(u: BorrowUnit, src: Node | null): void {
	const sources: Symbol[] = [];
	rootsOf(src, sources);
	for (const s of sources) {
		if (variableId(u.p, s) >= 0 && keysOf(s.symbolType, false).length > 0 && !u.escaped.includes(s)) u.escaped.push(s);
	}
}

function holdsKeys(t: Type | null): string[] {
	if (t == null) return ["*"];
	const inner = t.kind == TypeKind.Ref || t.kind == TypeKind.Var ? t.typeReturn : t;
	if (inner == null) return ["*"];
	const out: string[] = [];
	if (inner.kind == TypeKind.Array || inner.kind == TypeKind.SizedArray) {
		sharedKeys(inner.typeReturn, true, 1, out);
	} else if (inner.kind == TypeKind.Struct || inner.kind == TypeKind.Tuple) {
		for (const c of inner.typeChildren) { sharedKeys(c, t.kind == TypeKind.Ref || t.kind == TypeKind.Var, 1, out); }
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
			if (j == i) continue;
			const room = holdsKeys(args[j].nodeType);
			let fits = false;
			for (const k of own) {
				if (matchesAnyKey(k, room)) fits = true;
			}
			if (fits) {
				escape(u, args[i]);
				break;
			}
		}
	}
}

function changeEscaped(u: BorrowUnit, site: Node, summary: ResizeSummary): void {
	for (const sym of u.escaped) {
		const keys = effectKeys(keysOf(sym.symbolType, false), summary);
		if (keys.length == 0) continue;
		const paths: string[] = [];
		handlePaths(sym.symbolType, keys, false, 0, "", paths);
		for (const p of paths) { potentialMutation(u.p, sym, site, p); }
	}
}

function formalAt(fnType: Type | null, i: int32): Type | null {
	if (fnType == null || fnType.kind != TypeKind.Function) return null;
	const n = fnType.typeChildren.length;
	if (n == 0) return null;
	if (i < n - 1) return fnType.typeChildren[i];
	const last = fnType.typeChildren[n - 1];
	if (last != null && last.kind == TypeKind.Varargs) return null;
	return i < n ? fnType.typeChildren[i] : null;
}

function changeReachable(u: BorrowUnit, arg: Node, t: Type | null, viaRef: boolean, summary: ResizeSummary): void {
	const keys = effectKeys(keysOf(t, viaRef), summary);
	if (keys.length == 0) return;
	const paths: string[] = [];
	handlePaths(t, keys, viaRef, 0, "", paths);
	for (const p of paths) { mutateRoots(u, arg, arg, p); }
}

function argEffect(u: BorrowUnit, arg: Node, formal: Type | null, resizes: boolean, summary: ResizeSummary): void {
	if (formal != null && formal.kind == TypeKind.Var) {
		if (summary.unknown) {
			mutateRoots(u, arg, arg);
		} else {
			changeReachable(u, arg, formal.typeReturn, true, summary);
		}
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
	for (let i = 0; i < d.arguments.length; i += 1) {
		const a = d.arguments[i];
		argEffect(u, a, formalAt(fnType, i + offset), false, summary);
		if (a.nodeType != null && a.nodeType.kind == TypeKind.Function) passesRoutine = true;
	}
	runClosures(u, node, summary.unknown || passesRoutine);
	const all: Node[] = [];
	if (recv != null) all.push(recv);
	for (const a of d.arguments) { all.push(a); }
	storedIntoOther(u, all, summary);
	changeEscaped(u, node, summary);
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
	for (const c of u.closures) {
		if (c.node == node) return;
	}
	const body = routineBody(node);
	const s = noResize();
	scanResizes(body, s);
	if (!s.unknown) capturedWrites(u, body, s);
	if (!s.unknown && s.keys.length == 0) return;
	const captured: Symbol[] = [];
	capturedBy(u, body, captured);
	if (captured.length > 0) u.closures.push({ node, captured, summary: s });
}

function runClosure(u: BorrowUnit, c: ClosureEffect, site: Node): void {
	for (const sym of c.captured) {
		if (isBorrower(u, sym)) continue;
		const keys = effectKeys(keysOf(sym.symbolType, true), c.summary);
		if (keys.length == 0) continue;
		const paths: string[] = [];
		handlePaths(sym.symbolType, keys, true, 0, "", paths);
		for (const p of paths) { potentialMutation(u.p, sym, site, p); }
	}
}

function runClosures(u: BorrowUnit, call: Node, any: boolean): void {
	const target = call.resolvedSym != null ? call.resolvedSym.declNode : null;
	for (const c of u.closures) {
		if (any || c.node == target) runClosure(u, c, call);
	}
}

function crossesRef(t0: Type | null, path: string): boolean {
	let t = t0;
	let rest = path;
	while (true) {
		if (t == null) return true;
		match (t.kind) {
			TypeKind.Ref | TypeKind.Var | TypeKind.GenericParam | TypeKind.Unknown | TypeKind.TypeReference | TypeKind.Pending => { return true; },
			TypeKind.Alias | TypeKind.Distinct | TypeKind.Sink | TypeKind.Lent => {
				t = t.typeReturn;
				continue;
			},
			TypeKind.GenericInstance => {
				if (t.typeReturn == null) return true;
				t = t.typeReturn;
				continue;
			},
			_ => {},
		};
		if (rest == "") return false;
		if (rest.startsWith("[]")) {
			rest = rest.slice(2, rest.length);
			if (t.kind != TypeKind.Array && t.kind != TypeKind.SizedArray) return true;
			t = t.typeReturn;
			continue;
		}
		if (!rest.startsWith(".") || t.kind != TypeKind.Struct) return true;
		let end = 1;
		while (end < rest.length && rest.charAt(end) != "." && rest.charAt(end) != "[") end += 1;
		const name = rest.slice(1, end);
		rest = rest.slice(end, rest.length);
		const at = t.typeNames.indexOf(name);
		if (at < 0 || at >= t.typeChildren.length) return true;
		t = t.typeChildren[at];
	}
}

function typeAtPath(t0: Type | null, path: string): Type | null {
	let t = t0;
	let rest = path;
	while (t != null) {
		if (t.kind == TypeKind.Ref || t.kind == TypeKind.Var || t.kind == TypeKind.Alias || t.kind == TypeKind.Distinct
			|| t.kind == TypeKind.Sink || t.kind == TypeKind.Lent || (t.kind == TypeKind.GenericInstance && t.typeReturn != null)) {
			if (rest == "") return t;
			t = t.typeReturn;
			continue;
		}
		if (rest == "") return t;
		if (rest.startsWith("[]")) {
			rest = rest.slice(2, rest.length);
			t = t.kind == TypeKind.Array || t.kind == TypeKind.SizedArray ? t.typeReturn : null;
			continue;
		}
		if (!rest.startsWith(".") || t.kind != TypeKind.Struct) return null;
		let end = 1;
		while (end < rest.length && rest.charAt(end) != "." && rest.charAt(end) != "[") end += 1;
		const at = t.typeNames.indexOf(rest.slice(1, end));
		rest = rest.slice(end, rest.length);
		t = at >= 0 && at < t.typeChildren.length ? t.typeChildren[at] : null;
	}
	return null;
}

function keysAtPath(sym: Symbol, path: string): string[] {
	const t = typeAtPath(sym.symbolType, path);
	return t == null ? ["*"] : keysOf(t, true);
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
	const borrowed: string[] = [];
	for (const h of handles.split("|")) {
		if (h == "" || !crossesRef(src.sym.symbolType, h == "@" ? "" : h)) continue;
		for (const k of keysAtPath(src.sym, h == "@" ? "" : h)) { addKey(borrowed, k); }
	}
	if (borrowed.length == 0) return [];
	for (let gi = 0; gi < u.p.graphs.length; gi += 1) {
		const g = u.p.graphs[gi];
		for (let i = 0; i < g.mutations.length; i += 1) {
			const m = g.mutations[i];
			if (m < v.aliveStart || m > v.aliveEnd) continue;
			const r = g.roots[i];
			if (r == src.sym || r == v.sym) continue;
			const rid = variableId(u.p, r);
			if (rid < 0 || ufRoot(u.p, rid) == ufRoot(u.p, variableId(u.p, src.sym)) || !inExternalGroup(u, rid)) continue;
			for (const k of keysAtPath(r, g.paths[i])) {
				if (matchesAnyKey(k, borrowed)) return [gi, i];
			}
		}
	}
	return [];
}

function sharedSource(u: BorrowUnit, src: VarEntry, handles: string): boolean {
	if (hasFlag(src.sym, SymbolFlag.Global)) return true;
	for (const c of u.closures) {
		if (c.captured.includes(src.sym)) return true;
	}
	for (const h of handles.split("|")) {
		if (h != "" && crossesRef(src.sym.symbolType, h == "@" ? "" : h)) return true;
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
			if (u.pass == 2) deps(u, node.resolvedSym, d.initializer);
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
		},
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			walk(u, d.callee);
			for (const a of d.arguments) { walk(u, a); }
			if (u.pass == 2) callEffects(u, node);
		},
		NodeKind.NewExpr => {
			const d = node.data as NewExprData;
			walk(u, d.newCallee);
			for (const a of d.newArguments) { walk(u, a); }
			if (u.pass == 2) {
				const summary = newSummary(node);
				for (const a of d.newArguments) { argEffect(u, a, null, false, summary); }
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
			for (const s of (node.data as BlockStmtData).statements) { walk(u, s); }
			u.scope.pop();
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
			forEachChild(node, (child: Node): void => { walk(u, child); });
			if (u.pass == 2) {
				u.suspends.push(u.p.abstractTime);
				u.suspendSites.push(node);
			}
		},
		_ => { forEachChild(node, (child: Node): void => { walk(u, child); }); },
	};
}

function declaresView(node: Node | null): boolean {
	if (node == null) return false;
	if (node.kind == NodeKind.FunctionDecl || node.kind == NodeKind.ArrowFunction || node.kind == NodeKind.FunctionExpr
		|| node.kind == NodeKind.ClassDecl || node.kind == NodeKind.MethodDecl || node.kind == NodeKind.ConstructorDecl) return false;
	if (node.kind == NodeKind.VariableDecl && node.resolvedSym != null && isViewType(node.resolvedSym.symbolType)) return true;
	if (node.kind == NodeKind.ForOfStmt && node.resolvedSym != null && isViewType(node.resolvedSym.symbolType)) return true;
	let found = false;
	forEachChild(node, (child: Node): void => { if (!found && declaresView(child)) found = true; });
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

function checkUnit(ctx: CheckerContext, body: Node | null): void {
	if (body == null || body.kind != NodeKind.BlockStmt) return;
	const pointers: Symbol[] = [];
	collectPointers(body, pointers);
	if (pointers.length == 0 && !declaresView(body)) return;
	const u: BorrowUnit = { p: createPartitions(), pass: 1, scope: [], defers: [], ctx, pointers, blocks: [], closures: [], suspends: [], suspendSites: [], escaped: [] };
	runPass(u, body, 1);
	runPass(u, body, 2);
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

function scanUnits(ctx: CheckerContext, node: Node | null): void {
	if (node == null) return;
	match (node.kind) {
		NodeKind.FunctionDecl => checkUnit(ctx, (node.data as FunctionDeclData).fnBody),
		NodeKind.MethodDecl => checkUnit(ctx, (node.data as MethodDeclData).methodBody),
		NodeKind.ConstructorDecl => checkUnit(ctx, (node.data as ConstructorDeclData).ctorBody),
		NodeKind.ArrowFunction => checkUnit(ctx, (node.data as ArrowFunctionData).arrowBody),
		NodeKind.FunctionExpr => checkUnit(ctx, (node.data as FunctionExprData).funcExprBody),
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
	for (const stmt of (program.data as ProgramData).programStmts) { scanUnits(ctx, stmt); }
}
