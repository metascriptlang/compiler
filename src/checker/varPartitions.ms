import {
	Node, NodeKind, NodeFlag, Symbol, SymbolKind, Type, TypeKind,
	VariableDeclData, MemberExprData, ArrayAccessData, BlockStmtData, BinaryExprData, UpdateExprData,
	WhileStmtData, ForStmtData, ForOfStmtData, ForInStmtData, DoWhileStmtData, CallExprData,
	ObjectLiteralData, ArrayLiteralData, NewExprData, MoveExprData, OutExprData, DeferStmtData,
	TypeAssertionData, HiddenStdConvData, ConditionalExprData, FunctionDeclData, MethodDeclData, ConstructorDeclData,
	ArrowFunctionData, FunctionExprData, TestDeclData, ProgramData,
} from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { isPrimitiveKind, isViewType, isReadonlyView } from "./types";
import { hasFlag, SymbolFlag } from "./symbol";
import { CheckerContext, addError } from "./context";
import { isAddressTaking } from "./pointerAddress";

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
	borrowWhole: boolean[];
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
		borrowWhole: [],
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
	if (p.vars[rb].con.kind == CK_ROOT_OF) {
		const gb = p.graphs[p.vars[rb].con.target];
		rbFlags = gb.flags;
		rbMut = gb.maxMutation;
		if (gb.minConnection < rbCon) rbCon = gb.minConnection;
		rbMutations = gb.mutations;
		rbSites = gb.sites;
		rbRoots = gb.roots;
		rbPaths = gb.paths;
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
		p.graphs.push({
			flags: rbFlags, maxMutation: rbMut,
			minConnection: rbCon, mutations: muts, sites, roots, paths,
		});
	} else if (p.vars[ra].con.kind == CK_ROOT_OF) {
		const ga = p.graphs[p.vars[ra].con.target];
		if (rbCon < ga.minConnection) ga.minConnection = rbCon;
		ga.flags = ga.flags | rbFlags;
		for (const m of rbMutations) { ga.mutations.push(m); }
		for (const s of rbSites) { ga.sites.push(s); }
		for (const r of rbRoots) { ga.roots.push(r); }
		for (const x of rbPaths) { ga.paths.push(x); }
	}
}

export function potentialMutation(p: Partitions, sym: Symbol, site: Node | null = null, path: string = ""): void {
	const id = variableId(p, sym);
	if (id < 0) return;
	if (p.abstractTime > p.vars[id].aliveEnd) p.vars[id].aliveEnd = p.abstractTime;

	const r = ufRoot(p, id);
	if (p.vars[r].con.kind == CK_EMPTY_ROOT) {
		p.vars[r].con = { kind: CK_ROOT_OF, target: p.graphs.length };
		p.graphs.push({
			flags: SF_IS_MUTATED, maxMutation: p.abstractTime,
			minConnection: MAX_TIME, mutations: [p.abstractTime], sites: [site as Node], roots: [sym], paths: [path],
		});
	} else if (p.vars[r].con.kind == CK_ROOT_OF) {
		const g = p.graphs[p.vars[r].con.target];
		if (p.abstractTime > g.maxMutation) g.maxMutation = p.abstractTime;
		g.flags = g.flags | SF_IS_MUTATED;
		g.mutations.push(p.abstractTime);
		g.sites.push(site as Node);
		g.roots.push(sym);
		g.paths.push(path);
	}
}

export function dangerousMutation(g: MutationInfo, v: VarEntry): boolean {
	if ((g.flags & SF_IS_MUTATED) == 0) return false;
	for (const m of g.mutations) {
		if (m >= v.aliveStart && m <= v.aliveEnd) return true;
	}
	return false;
}

function reaches(changed: string, borrowed: string, whole: boolean): boolean {
	if (changed.length > borrowed.length || !borrowed.startsWith(changed)) return false;
	if (changed.length == borrowed.length) return whole;
	const next = borrowed.charAt(changed.length);
	return next == "." || next == "[";
}

function firstMutationIn(g: MutationInfo, v: VarEntry, source: Symbol, path: string, whole: boolean): int32 {
	if ((g.flags & SF_IS_MUTATED) == 0) return -1;
	for (let i = 0; i < g.mutations.length; i += 1) {
		const m = g.mutations[i];
		if (m < v.aliveStart || m > v.aliveEnd || g.roots[i] == v.sym) continue;
		if (g.roots[i] != source || reaches(g.paths[i], path, whole)) return i;
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

interface BorrowUnit {
	p: Partitions;
	pass: int32;
	scope: int32[];
	nextScope: int32;
	defers: Node[];
	ctx: CheckerContext;
	pointers: Symbol[];
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

function ownsStorage(t: Type | null): boolean {
	if (t == null) return false;
	if (t.kind == TypeKind.String || t.kind == TypeKind.Array) return true;
	if (isViewType(t)) return false;
	return carriesPointer(t);
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
		NodeKind.CallExpr => {
			if (carriesPointer(node.nodeType)) {
				const d = node.data as CallExprData;
				const recv = receiverOf(node);
				if (recv != null) rootsOf(recv, out);
				for (const a of d.arguments) { rootsOf(a, out); }
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

function pathSources(node: Node | null, out: Node[], paths: string[], wholes: boolean[], suffix: string = ""): boolean {
	let n = node;
	let path = suffix;
	let terminal: Node | null = null;
	while (n != null) {
		match (n.kind) {
			NodeKind.Identifier | NodeKind.StringLiteral => {
				const at: Node = terminal != null ? terminal : n;
				out.push(n);
				paths.push(path);
				wholes.push(ownsStorage(at.nodeType));
				return true;
			},
			NodeKind.MemberExpr => {
				if (terminal == null) terminal = n;
				path = "." + (n.data as MemberExprData).property + path;
				n = (n.data as MemberExprData).object;
			},
			NodeKind.ArrayAccess => {
				if (!isSlice(n)) {
					if (terminal == null) terminal = n;
					path = "[]" + path;
				}
				n = (n.data as ArrayAccessData).array;
			},
			NodeKind.HiddenDeref | NodeKind.HiddenAddr => { n = (n.data as { expr: Node }).expr; },
			NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => { n = (n.data as HiddenStdConvData).convExpr; },
			NodeKind.TypeAssertion => {
				const inner = (n.data as TypeAssertionData).asExpr;
				if (isAddressTaking(n) && inner != null && inner.nodeType != null && inner.nodeType.kind == TypeKind.Span) {
					if (terminal == null) terminal = n;
					path = "[]" + path;
				}
				n = inner;
			},
			NodeKind.ConditionalExpr => {
				const d = n.data as ConditionalExprData;
				return pathSources(d.ternaryConsequent, out, paths, wholes, path) && pathSources(d.ternaryAlternate, out, paths, wholes, path);
			},
			NodeKind.CallExpr => {
				if (!isViewType(n.nodeType)) return false;
				const recv = receiverOf(n);
				if (recv != null && supplies(recv.nodeType) && !pathSources(recv, out, paths, wholes, "")) return false;
				for (const a of (n.data as CallExprData).arguments) {
					if (supplies(a.nodeType) && !pathSources(a, out, paths, wholes, "")) return false;
				}
				return true;
			},
			_ => { return false; },
		};
	}
	return false;
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

function mutateRoots(u: BorrowUnit, node: Node | null, site: Node): void {
	const roots: Symbol[] = [];
	rootsOf(node, roots);
	const path = roots.length == 1 ? pathOf(node) : "";
	for (const r of roots) { potentialMutation(u.p, r, site, path); }
}

function handOff(u: BorrowUnit, src: Node | null): void {
	let n = src;
	while (n != null && (n.kind == NodeKind.HiddenStdConv || n.kind == NodeKind.HiddenSubConv)) {
		n = (n.data as HiddenStdConvData).convExpr;
	}
	if (n == null || n.kind != NodeKind.Identifier || n.resolvedSym == null) return;
	if (!ownsStorage(n.resolvedSym.symbolType)) return;
	potentialMutation(u.p, n.resolvedSym, n);
}

function borrowFrom(u: BorrowUnit, dest: Symbol, src: Node): void {
	const vid = variableId(u.p, dest);
	if (vid < 0) return;
	const sources: Node[] = [];
	const paths: string[] = [];
	const wholes: boolean[] = [];
	if (!pathSources(src, sources, paths, wholes)) {
		addError(u.ctx, `cannot borrow '${dest.name}' from an expression that is not a variable, field or element path; bind the value to a local first`, src.location.line, src.location.column);
		return;
	}
	const pointer = !isViewType(dest.symbolType);
	for (let k = 0; k < sources.length; k += 1) {
		const s = sources[k];
		const sym = s.resolvedSym;
		if (s.kind == NodeKind.StringLiteral || sym == null) continue;
		if (hasFlag(sym, SymbolFlag.Global)) {
			addError(u.ctx, `cannot borrow '${dest.name}' from module-level '${sym.name}': a call can change it unseen; pass it as a parameter`, src.location.line, src.location.column);
			return;
		}
		const sid = variableId(u.p, sym);
		if (sid < 0) continue;
		const from = u.p.vars[sid];
		if (!from.external && from.sym != dest && isBorrower(u, from.sym)) {
			for (let b = 0; b < from.borrowsFrom.length; b += 1) {
				const deeper = paths[k] != "";
				addBorrow(u.p.vars[vid], from.borrowsFrom[b], from.borrowPaths[b] + paths[k], !pointer && !deeper && from.borrowWhole[b]);
			}
			continue;
		}
		addBorrow(u.p.vars[vid], sid, paths[k], !pointer && wholes[k]);
	}
}

function addBorrow(v: VarEntry, sid: int32, path: string, whole: boolean): void {
	for (let i = 0; i < v.borrowsFrom.length; i += 1) {
		if (v.borrowsFrom[i] == sid && v.borrowPaths[i] == path) {
			if (whole) v.borrowWhole[i] = true;
			return;
		}
	}
	v.borrowsFrom.push(sid);
	v.borrowPaths.push(path);
	v.borrowWhole.push(whole);
}

function deps(u: BorrowUnit, dest: Symbol | null, src: Node | null): void {
	if (dest == null || src == null) return;
	const view = isBorrower(u, dest);
	if (view) borrowFrom(u, dest, src);
	else handOff(u, src);
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
		if (d.operator == "=") deps(u, sym, d.right);
		return;
	}
	if (ownsStorage(left.nodeType)) mutateRoots(u, left, d.left);
	if (d.operator != "=") return;
	handOff(u, d.right);
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

function formalAt(fnType: Type | null, i: int32): Type | null {
	if (fnType == null || fnType.kind != TypeKind.Function) return null;
	const n = fnType.typeChildren.length;
	if (n == 0) return null;
	if (i < n - 1) return fnType.typeChildren[i];
	const last = fnType.typeChildren[n - 1];
	if (last != null && last.kind == TypeKind.Varargs) return null;
	return i < n ? fnType.typeChildren[i] : null;
}

function argEffect(u: BorrowUnit, arg: Node, formal: Type | null, magic: boolean): void {
	if (formal != null && formal.kind == TypeKind.Var) { mutateRoots(u, arg, arg); return; }
	if (formal != null && formal.kind == TypeKind.Sink) {
		handOff(u, arg);
		if (carriesPointer(formal.typeReturn)) mutateRoots(u, arg, arg);
		return;
	}
	if (arg.kind == NodeKind.MoveExpr || arg.kind == NodeKind.OutExpr || arg.kind == NodeKind.HiddenAddr) {
		mutateRoots(u, arg, arg);
		return;
	}
	if (magic) return;
	if (!isHandle(formal != null ? formal : arg.nodeType)) return;
	mutateRoots(u, arg, arg);
}

function isHandle(t: Type | null): boolean {
	if (t == null || isReadonlyView(t)) return false;
	return match (t.kind) {
		TypeKind.Ref => true,
		TypeKind.Sink | TypeKind.Alias => isHandle(t.typeReturn),
		TypeKind.Union => {
			for (const c of t.typeChildren) {
				if (isHandle(c)) return true;
			}
			return false;
		},
		_ => false,
	};
}

function callEffects(u: BorrowUnit, node: Node): void {
	const d = node.data as CallExprData;
	const sym = node.resolvedSym;
	const magic = sym != null && sym.builtinKind != "";
	const fnType = sym != null && sym.symbolType != null && sym.symbolType.kind == TypeKind.Function
		? sym.symbolType
		: (d.callee != null ? d.callee.nodeType : null);
	const recv = receiverOf(node);
	let offset: int32 = 0;
	if (recv != null) {
		if (node.flags.has(NodeFlag.ExtCall)) {
			argEffect(u, recv, formalAt(fnType, 0), magic);
			offset = 1;
		} else {
			argEffect(u, recv, null, magic);
		}
	}
	for (let i = 0; i < d.arguments.length; i += 1) {
		argEffect(u, d.arguments[i], formalAt(fnType, i + offset), magic);
	}
}

function openScope(u: BorrowUnit): void {
	u.nextScope += 1;
	u.scope.push(u.nextScope);
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
				for (const a of d.newArguments) { argEffect(u, a, null, false); }
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
				for (const e of d.elements) { handOff(u, e); }
			}
		},
		NodeKind.ObjectLiteral => {
			const d = node.data as ObjectLiteralData;
			for (const e of d.properties) { walk(u, e); }
			if (u.pass == 2) {
				for (const e of d.properties) { handOff(u, e); }
			}
		},
		NodeKind.BlockStmt => {
			openScope(u);
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
			openScope(u);
			walk(u, d.forInit);
			walkLoop(u, [d.forCondition, d.forBody, d.forUpdate]);
			u.scope.pop();
		},
		NodeKind.ForOfStmt => {
			const d = node.data as ForOfStmtData;
			walk(u, d.forOfIterable);
			openScope(u);
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
			openScope(u);
			walkLoop(u, [d.forInBody]);
			u.scope.pop();
		},
		NodeKind.DeferStmt => {
			u.p.abstractTime -= 1;
			if (u.pass == 1) u.defers.push((node.data as DeferStmtData).deferExpr);
		},
		NodeKind.FunctionDecl | NodeKind.ArrowFunction | NodeKind.FunctionExpr | NodeKind.ClassDecl
			| NodeKind.MethodDecl | NodeKind.ConstructorDecl | NodeKind.TestDecl => {
			u.p.abstractTime -= 1;
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
	u.nextScope = 0;
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
	const u: BorrowUnit = { p: createPartitions(), pass: 1, scope: [], nextScope: 0, defers: [], ctx, pointers };
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
				const at = firstMutationIn(g, v, src.sym, v.borrowPaths[bi], v.borrowWhole[bi]);
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
		}
	}
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

export function checkViewBorrows(ctx: CheckerContext, program: Node): void {
	if (program == null || program.kind != NodeKind.Program) return;
	for (const stmt of (program.data as ProgramData).programStmts) { scanUnits(ctx, stmt); }
}
