import {
	Node, NodeKind, Symbol, SymbolKind, Type, TypeKind,
	MemberExprData, ArrayAccessData, ConditionalExprData, ArrayLiteralData, ObjectLiteralData,
	SpreadExprData, NewExprData, CallExprData, HiddenStdConvData, TypeAssertionData,
	ProgramData, BlockStmtData, VariableDeclData, BinaryExprData, UpdateExprData, MoveExprData,
	WhileStmtData, DoWhileStmtData, ForStmtData, ForOfStmtData, ForInStmtData,
	FunctionDeclData, ArrowFunctionData, FunctionExprData, MethodDeclData, ConstructorDeclData, TestDeclData,
	DestructuringDeclData, ArrayPatternData, ObjectPatternData, ObjectPatternPropData,
} from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { isPrimitiveKind, isViewKind, isReadonlyView } from "./types";
import { isMutatingArrayMethod } from "./paramMutationAnalysis";
import { CheckerContext, addError } from "./context";
import { hasFlag, SymbolFlag } from "./symbol";

// ===== Constants =====

export const MAX_TIME: int32 = 999999;
export const MIN_TIME: int32 = -1;

// ===== VarFlag (per-variable analysis flags) =====

export const VF_OWNS_DATA: int32 = 1;
export const VF_PREVENT_CURSOR: int32 = 2;
export const VF_IS_REASSIGNED: int32 = 4;
export const VF_IS_COND_REASSIGNED: int32 = 8;
export const VF_IS_PARAM: int32 = 16;

// ===== SubgraphFlag =====

export const SF_IS_MUTATED: int32 = 1;

// ===== Connection Kind =====

export const CK_EMPTY_ROOT: int32 = 0;
export const CK_DEPENDS_ON: int32 = 1;
export const CK_ROOT_OF: int32 = 2;

// ===== Data Structures =====

export interface Connection {
	kind: int32;
	target: int32; // parent index for DependsOn, graph index for RootOf
}

export interface VarEntry {
	sym: Symbol;
	con: Connection;
	flags: int32;
	reassignedTo: Symbol | null;
	aliveStart: int32;
	aliveEnd: int32;
}

export interface MutationInfo {
	flags: int32;
	maxMutation: int32;
	minConnection: int32;
	mutations: int32[];
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

// ===== Variable Lookup =====

export function variableId(p: Partitions, sym: Symbol | null): int32 {
	if (sym == null) return -1;
	for (let i = 0; i < p.vars.length; i += 1) {
		if (p.vars[i].sym == sym) return i;
	}
	return -1;
}

export function registerVariable(p: Partitions, sym: Symbol | null, isParam: boolean): void {
	if (sym == null) return;
	if (variableId(p, sym) >= 0) return;
	p.vars.push({
		sym,
		con: { kind: CK_EMPTY_ROOT, target: 0 },
		flags: isParam ? VF_IS_PARAM : (0 as int32),
		reassignedTo: null,
		// Params: alive for full function. Locals: start at declaration time.
		aliveStart: isParam ? 0 : p.abstractTime,
		aliveEnd: isParam ? MAX_TIME : p.abstractTime,
	});
}

// ===== Union-Find with Path Compression =====

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

	// Collect rb's graph info before merging
	let rbFlags: int32 = 0;
	let rbMut: int32 = 0;
	let rbCon: int32 = p.abstractTime;
	let rbMutations: int32[] = [];
	if (p.vars[rb].con.kind == CK_ROOT_OF) {
		const gb = p.graphs[p.vars[rb].con.target];
		rbFlags = gb.flags;
		rbMut = gb.maxMutation;
		if (gb.minConnection < rbCon) rbCon = gb.minConnection;
		rbMutations = gb.mutations;
	}

	// Make rb depend on ra
	p.vars[rb].con = { kind: CK_DEPENDS_ON, target: ra };

	if (p.vars[ra].con.kind == CK_EMPTY_ROOT) {
		// ra becomes root of a new graph
		p.vars[ra].con = { kind: CK_ROOT_OF, target: p.graphs.length };
		const muts: int32[] = [];
		for (const m of rbMutations) { muts.push(m); }
		p.graphs.push({
			flags: rbFlags, maxMutation: rbMut,
			minConnection: rbCon, mutations: muts,
		});
	} else if (p.vars[ra].con.kind == CK_ROOT_OF) {
		// Merge rb's info into ra's graph
		const ga = p.graphs[p.vars[ra].con.target];
		if (rbCon < ga.minConnection) ga.minConnection = rbCon;
		ga.flags = ga.flags | rbFlags;
		for (const m of rbMutations) { ga.mutations.push(m); }
	}
}

// ===== Mutation Tracking =====

export function potentialMutation(p: Partitions, sym: Symbol): void {
	const id = variableId(p, sym);
	if (id < 0) return;
	if (p.abstractTime > p.vars[id].aliveEnd) p.vars[id].aliveEnd = p.abstractTime;

	const r = ufRoot(p, id);
	if (p.vars[r].con.kind == CK_EMPTY_ROOT) {
		p.vars[r].con = { kind: CK_ROOT_OF, target: p.graphs.length };
		p.graphs.push({
			flags: SF_IS_MUTATED, maxMutation: p.abstractTime,
			minConnection: MAX_TIME, mutations: [p.abstractTime],
		});
	} else if (p.vars[r].con.kind == CK_ROOT_OF) {
		const g = p.graphs[p.vars[r].con.target];
		if (p.abstractTime > g.maxMutation) g.maxMutation = p.abstractTime;
		g.flags = g.flags | SF_IS_MUTATED;
		g.mutations.push(p.abstractTime);
	}
}

export function dangerousMutation(g: MutationInfo, v: VarEntry): boolean {
	if ((g.flags & SF_IS_MUTATED) == 0) return false;
	for (const m of g.mutations) {
		if (m >= v.aliveStart && m <= v.aliveEnd) return true;
	}
	return false;
}

// ===== Helpers =====

export function getIdentSym(node: Node): Symbol | null {
	if (node == null) return null;
	if (node.kind == NodeKind.Identifier) return node.resolvedSym;
	return null;
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

export function allRoots(node: Node, result: Symbol[]): void {
	if (node == null) return;
	match (node.kind) {
		NodeKind.Identifier => { if (node.resolvedSym != null) result.push(node.resolvedSym); },
		NodeKind.MemberExpr => allRoots((node.data as MemberExprData).object, result),
		NodeKind.ArrayAccess => allRoots((node.data as ArrayAccessData).array, result),
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => allRoots((node.data as { expr: Node }).expr, result),
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => allRoots((node.data as HiddenStdConvData).convExpr, result),
		NodeKind.TypeAssertion => allRoots((node.data as TypeAssertionData).asExpr, result),
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			allRoots(d.ternaryConsequent, result);
			allRoots(d.ternaryAlternate, result);
		},
		NodeKind.ArrayLiteral => { for (const e of (node.data as ArrayLiteralData).elements) { allRoots(e, result); } },
		NodeKind.ObjectLiteral => { for (const e of (node.data as ObjectLiteralData).properties) { allRoots(e, result); } },
		NodeKind.SpreadExpr => allRoots((node.data as SpreadExprData).spreadArg, result),
		NodeKind.NewExpr => { for (const a of (node.data as NewExprData).newArguments) { allRoots(a, result); } },
		NodeKind.CallExpr => {
			if (containsPointer(node.nodeType, 0)) {
				for (const a of (node.data as CallExprData).arguments) { allRoots(a, result); }
			}
		},
		_ => {},
	};
}

export function connectStore(p: Partitions, targets: Symbol[], destType: Type | null, src: Node): void {
	if (!containsPointer(destType, 0)) return;
	const sources: Symbol[] = [];
	allRoots(src, sources);
	for (const t of targets) {
		for (const s of sources) { ufConnect(p, t, s); }
	}
}

export function potentialMutationViaArg(p: Partitions, arg: Node): void {
	if (arg == null || arg.kind == NodeKind.HiddenAddr) return;
	if (!containsPointer(arg.nodeType, 0)) return;
	const roots: Symbol[] = [];
	allRoots(arg, roots);
	for (const r of roots) { potentialMutation(p, r); }
}


interface BorrowVar {
	scope: int32;
	owned: boolean;
	movable: boolean;
	isView: boolean;
	escaped: boolean;
	borrowsFrom: int32[];
	origins: Symbol[];
	declLine: int32;
	declCol: int32;
	lastUseLine: int32;
	reported: boolean;
}

interface MutationSite {
	time: int32;
	line: int32;
}

interface LoopFrame {
	name: string;
	roots: Symbol[];
}

interface BorrowCheck {
	ctx: CheckerContext;
	p: Partitions;
	params: string[];
	vars: BorrowVar[];
	sites: MutationSite[];
	suspends: MutationSite[];
	calls: MutationSite[];
	scopeNodes: Node[];
	scopeParents: int32[];
	scope: int32;
	loops: LoopFrame[];
}

export function checkViewBorrows(ctx: CheckerContext, program: Node): void {
	if (program == null || program.kind != NodeKind.Program) return;
	const stmts = (program.data as ProgramData).programStmts;
	if (bindsViewIn(stmts)) borrowCheckUnit(ctx, [], program, stmts);
	findBorrowUnits(ctx, program);
}

function findBorrowUnits(ctx: CheckerContext, node: Node | null): void {
	if (node == null) return;
	const k = node.kind;
	if (k == NodeKind.FunctionDecl) {
		const d = node.data as FunctionDeclData;
		borrowCheckBody(ctx, d.params, d.fnBody);
	} else if (k == NodeKind.ArrowFunction) {
		const d = node.data as ArrowFunctionData;
		borrowCheckBody(ctx, d.arrowParams, d.arrowBody);
	} else if (k == NodeKind.FunctionExpr) {
		const d = node.data as FunctionExprData;
		borrowCheckBody(ctx, d.funcExprParams, d.funcExprBody);
	} else if (k == NodeKind.MethodDecl) {
		const d = node.data as MethodDeclData;
		borrowCheckBody(ctx, d.methodParams, d.methodBody);
	} else if (k == NodeKind.ConstructorDecl) {
		const d = node.data as ConstructorDeclData;
		borrowCheckBody(ctx, d.ctorParams, d.ctorBody);
	} else if (k == NodeKind.TestDecl) {
		borrowCheckBody(ctx, [], (node.data as TestDeclData).testBody);
	}
	forEachChild(node, (c: Node): void => { findBorrowUnits(ctx, c); });
}

function borrowCheckBody(ctx: CheckerContext, params: string[], body: Node | null): void {
	if (body == null) return;
	const stmts: Node[] = body.kind == NodeKind.BlockStmt ? (body.data as BlockStmtData).statements : [body];
	if (bindsViewIn(stmts)) borrowCheckUnit(ctx, params, body, stmts);
}

function borrowCheckUnit(ctx: CheckerContext, params: string[], root: Node, stmts: Node[]): void {
	const b: BorrowCheck = {
		ctx, p: createPartitions(), params, vars: [], sites: [], suspends: [], calls: [],
		scopeNodes: [root], scopeParents: [-1], scope: 0, loops: [],
	};
	for (const s of stmts) { borrowLiveRanges(b, s); }
	b.p.abstractTime = 0;
	b.scope = 0;
	for (const s of stmts) { borrowTraverse(b, s); }
	checkBorrowedLocations(b);
}

function isUnitBoundary(k: NodeKind): boolean {
	return k == NodeKind.FunctionDecl || k == NodeKind.ArrowFunction || k == NodeKind.FunctionExpr
		|| k == NodeKind.MethodDecl || k == NodeKind.ConstructorDecl || k == NodeKind.TestDecl
		|| k == NodeKind.ClassDecl || k == NodeKind.ActorDecl || k == NodeKind.StructDecl
		|| k == NodeKind.InterfaceDecl;
}

function viewTypeOf(t: Type | null): Type | null {
	if (t == null) return null;
	if (isViewKind(t)) return t;
	if (t.kind == TypeKind.Union && t.typeChildren.length == 2) {
		const a = t.typeChildren[0];
		const c = t.typeChildren[1];
		if (a != null && a.kind == TypeKind.Null && isViewKind(c)) return c;
		if (c != null && c.kind == TypeKind.Null && isViewKind(a)) return a;
	}
	return null;
}

function holdsBorrow(t: Type | null): boolean {
	const v = viewTypeOf(t);
	return v != null && v.kind != TypeKind.Var;
}

function bindsViewIn(stmts: Node[]): boolean {
	const hits: int32[] = [];
	for (const s of stmts) { collectViewBinding(s, hits); }
	return hits.length > 0;
}

function collectViewBinding(node: Node | null, hits: int32[]): void {
	if (node == null || hits.length > 0 || isUnitBoundary(node.kind)) return;
	if (node.kind == NodeKind.VariableDecl && node.resolvedSym != null && holdsBorrow(node.resolvedSym.symbolType)) {
		hits.push(1);
		return;
	}
	if (node.kind == NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		if (d.operator == "=" && d.left != null && d.left.kind == NodeKind.Identifier && d.left.resolvedSym != null
				&& holdsBorrow(d.left.resolvedSym.symbolType)) {
			hits.push(1);
			return;
		}
	}
	forEachChild(node, (c: Node): void => { collectViewBinding(c, hits); });
}

function isValueSymbol(sym: Symbol): boolean {
	return sym.symbolKind == SymbolKind.Variable || sym.symbolKind == SymbolKind.Parameter
		|| sym.symbolKind == SymbolKind.Temp;
}

function isOwnParam(b: BorrowCheck, sym: Symbol): boolean {
	return sym.name == "this" || (sym.symbolKind == SymbolKind.Parameter && b.params.includes(sym.name));
}

function isImmutableGlobal(sym: Symbol): boolean {
	if (hasFlag(sym, SymbolFlag.Mutable)) return false;
	const t = sym.symbolType;
	if (t == null) return false;
	return t.kind == TypeKind.String || t.kind == TypeKind.StringLiteral || t.kind == TypeKind.SizedArray || isReadonlyView(t);
}

function isCompoundAssign(op: string): boolean {
	return op == "+=" || op == "-=" || op == "*=" || op == "/=" || op == "%=" || op == "<<=" || op == ">>="
		|| op == "&=" || op == "|=" || op == "^=" || op == "**=" || op == "&&=" || op == "||=" || op == "??=";
}


function enterBorrowScope(b: BorrowCheck, node: Node): int32 {
	const saved = b.scope;
	for (let i = 0; i < b.scopeNodes.length; i += 1) {
		if (b.scopeNodes[i] == node) {
			b.scope = i as int32;
			return saved;
		}
	}
	b.scopeNodes.push(node);
	b.scopeParents.push(saved);
	b.scope = (b.scopeNodes.length - 1) as int32;
	return saved;
}

function scopeEncloses(b: BorrowCheck, outer: int32, inner: int32): boolean {
	let s = inner;
	while (s >= 0) {
		if (s == outer) return true;
		s = b.scopeParents[s];
	}
	return false;
}

function registerBorrowVar(b: BorrowCheck, sym: Symbol, isParam: boolean, owned: boolean, movable: boolean, line: int32, col: int32): int32 {
	const existing = variableId(b.p, sym);
	if (existing >= 0) return existing;
	registerVariable(b.p, sym, isParam);
	let scope: int32 = b.scope;
	if (isParam) scope = 0;
	b.vars.push({
		scope, owned, movable, isView: holdsBorrow(sym.symbolType), escaped: false,
		borrowsFrom: [], origins: [], declLine: line, declCol: col, lastUseLine: line, reported: false,
	});
	return (b.vars.length - 1) as int32;
}

function loopRoots(node: Node | null): Symbol[] {
	const roots: Symbol[] = [];
	if (node != null) borrowRoots(node, roots);
	return roots;
}

function declareLoopVar(b: BorrowCheck, sym: Symbol, roots: Symbol[], line: int32, col: int32): void {
	const id = registerBorrowVar(b, sym, false, true, false, line, col);
	for (const r of roots) { b.vars[id].origins.push(r); }
}

function declareBorrowPattern(b: BorrowCheck, node: Node | null, roots: Symbol[], movable: boolean): void {
	if (node == null) return;
	const k = node.kind;
	if (k == NodeKind.Identifier) {
		const sym = node.resolvedSym;
		if (sym == null || !isValueSymbol(sym) || hasFlag(sym, SymbolFlag.Global)) return;
		const id = registerBorrowVar(b, sym, false, true, movable, node.location.line, node.location.column);
		for (const r of roots) { b.vars[id].origins.push(r); }
		return;
	}
	if (k == NodeKind.ArrayPattern) {
		for (const e of (node.data as ArrayPatternData).patternElements) { declareBorrowPattern(b, e, roots, movable); }
		return;
	}
	if (k == NodeKind.ObjectPattern) {
		for (const pr of (node.data as ObjectPatternData).patternProps) { declareBorrowPattern(b, pr, roots, movable); }
		return;
	}
	if (k == NodeKind.ObjectPatternProp) declareBorrowPattern(b, (node.data as ObjectPatternPropData).propAlias, roots, movable);
}

function loopFrameFor(b: BorrowCheck, name: string): LoopFrame | null {
	let i = b.loops.length - 1;
	while (i >= 0) {
		if (b.loops[i].name == name) return b.loops[i];
		i -= 1;
	}
	return null;
}

function noteBorrowUse(b: BorrowCheck, node: Node): void {
	const sym = node.resolvedSym;
	if (sym == null || !isValueSymbol(sym) || hasFlag(sym, SymbolFlag.Global)) return;
	let id = variableId(b.p, sym);
	if (id < 0) {
		if (hasFlag(sym, SymbolFlag.ForVar)) {
			id = registerBorrowVar(b, sym, false, true, false, node.location.line, node.location.column);
			const frame = loopFrameFor(b, sym.name);
			if (frame != null) {
				for (const r of frame.roots) { b.vars[id].origins.push(r); }
			}
		} else {
			id = registerBorrowVar(b, sym, true, isOwnParam(b, sym), false, node.location.line, node.location.column);
		}
	}
	if (b.p.abstractTime > b.p.vars[id].aliveEnd) {
		b.p.vars[id].aliveEnd = b.p.abstractTime;
		b.vars[id].lastUseLine = node.location.line;
	}
	if (b.p.abstractTime < b.p.vars[id].aliveStart) b.p.vars[id].aliveStart = b.p.abstractTime;
}


function borrowLiveRanges(b: BorrowCheck, node: Node | null): void {
	if (node == null || isUnitBoundary(node.kind)) return;
	b.p.abstractTime += 1;
	const k = node.kind;
	if (k == NodeKind.Identifier) {
		b.p.abstractTime -= 1;
		noteBorrowUse(b, node);
		return;
	}
	if (k == NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		borrowLiveRanges(b, d.initializer);
		const sym = node.resolvedSym;
		if (sym != null && isValueSymbol(sym) && !hasFlag(sym, SymbolFlag.Global)) {
			registerBorrowVar(b, sym, false, true, true, d.nameLocation.line, d.nameLocation.column);
		}
		return;
	}
	if (k == NodeKind.DestructuringDecl) {
		const d = node.data as DestructuringDeclData;
		borrowLiveRanges(b, d.destrInit);
		declareBorrowPattern(b, d.destrPattern, [], true);
		return;
	}
	if (k == NodeKind.BlockStmt) {
		const saved = enterBorrowScope(b, node);
		for (const s of (node.data as BlockStmtData).statements) { borrowLiveRanges(b, s); }
		b.scope = saved;
		return;
	}
	if (k == NodeKind.WhileStmt) {
		const d = node.data as WhileStmtData;
		borrowLiveRanges(b, d.whileCondition);
		borrowLiveRanges(b, d.whileBody);
		borrowLiveRanges(b, d.whileCondition);
		borrowLiveRanges(b, d.whileBody);
		borrowLiveRanges(b, d.whileCondition);
		return;
	}
	if (k == NodeKind.DoWhileStmt) {
		const d = node.data as DoWhileStmtData;
		borrowLiveRanges(b, d.doBody);
		borrowLiveRanges(b, d.doCondition);
		borrowLiveRanges(b, d.doBody);
		borrowLiveRanges(b, d.doCondition);
		return;
	}
	if (k == NodeKind.ForStmt) {
		const d = node.data as ForStmtData;
		const saved = enterBorrowScope(b, node);
		for (let round = 0; round < 2; round += 1) {
			borrowLiveRanges(b, d.forInit);
			borrowLiveRanges(b, d.forCondition);
			borrowLiveRanges(b, d.forUpdate);
			borrowLiveRanges(b, d.forBody);
		}
		b.scope = saved;
		return;
	}
	if (k == NodeKind.ForOfStmt) {
		const d = node.data as ForOfStmtData;
		borrowLiveRanges(b, d.forOfIterable);
		const saved = enterBorrowScope(b, node);
		const roots = loopRoots(d.forOfIterable);
		if (d.forOfPattern != null) {
			declareBorrowPattern(b, d.forOfPattern, roots, false);
		} else if (node.resolvedSym != null) {
			declareLoopVar(b, node.resolvedSym, roots, d.bindingLocation.line, d.bindingLocation.column);
		}
		borrowLiveRanges(b, d.forOfBody);
		borrowLiveRanges(b, d.forOfBody);
		b.scope = saved;
		return;
	}
	if (k == NodeKind.ForInStmt) {
		const d = node.data as ForInStmtData;
		borrowLiveRanges(b, d.forInObject);
		const saved = enterBorrowScope(b, node);
		b.loops.push({ name: d.forInBinding, roots: loopRoots(d.forInObject) });
		borrowLiveRanges(b, d.forInBody);
		borrowLiveRanges(b, d.forInBody);
		b.loops.pop();
		b.scope = saved;
		return;
	}
	if (k == NodeKind.CallExpr) {
		const d = node.data as CallExprData;
		borrowLiveRanges(b, d.callee);
		for (const a of d.arguments) { borrowLiveRanges(b, a); }
		return;
	}
	if (k == NodeKind.NewExpr) {
		const d = node.data as NewExprData;
		borrowLiveRanges(b, d.newCallee);
		for (const a of d.newArguments) { borrowLiveRanges(b, a); }
		return;
	}
	if (k == NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		borrowLiveRanges(b, d.left);
		borrowLiveRanges(b, d.right);
		return;
	}
	if (k == NodeKind.UpdateExpr) {
		borrowLiveRanges(b, (node.data as UpdateExprData).updateArg);
		return;
	}
	if (k == NodeKind.MoveExpr) {
		borrowLiveRanges(b, (node.data as MoveExprData).moveArg);
		return;
	}
	if (k == NodeKind.ArrayLiteral) {
		for (const e of (node.data as ArrayLiteralData).elements) { borrowLiveRanges(b, e); }
		return;
	}
	if (k == NodeKind.ObjectLiteral) {
		for (const pr of (node.data as ObjectLiteralData).properties) { borrowLiveRanges(b, pr); }
		return;
	}
	forEachChild(node, (c: Node): void => { borrowLiveRanges(b, c); });
}


function borrowTraverse(b: BorrowCheck, node: Node | null): void {
	if (node == null) return;
	if (isUnitBoundary(node.kind)) {
		captureHandOff(b, node, node.location.line);
		return;
	}
	b.p.abstractTime += 1;
	const k = node.kind;
	const line = node.location.line;
	if (k == NodeKind.Identifier) {
		b.p.abstractTime -= 1;
		return;
	}
	if (k == NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		borrowTraverse(b, d.initializer);
		if (node.resolvedSym != null && d.initializer != null) {
			bindBorrowLocal(b, node.resolvedSym, d.initializer, d.nameLocation.line, d.nameLocation.column);
		}
		return;
	}
	if (k == NodeKind.DestructuringDecl) {
		const d = node.data as DestructuringDeclData;
		borrowTraverse(b, d.destrInit);
		const targets: Symbol[] = [];
		collectPatternSyms(d.destrPattern, targets);
		for (const t of targets) { borrowConnectStore(b, [t], t.symbolType, d.destrInit); }
		return;
	}
	if (k == NodeKind.BlockStmt) {
		const saved = enterBorrowScope(b, node);
		for (const s of (node.data as BlockStmtData).statements) { borrowTraverse(b, s); }
		b.scope = saved;
		return;
	}
	if (k == NodeKind.WhileStmt) {
		const d = node.data as WhileStmtData;
		borrowTraverse(b, d.whileCondition);
		borrowTraverse(b, d.whileBody);
		borrowTraverse(b, d.whileCondition);
		borrowTraverse(b, d.whileBody);
		borrowTraverse(b, d.whileCondition);
		return;
	}
	if (k == NodeKind.DoWhileStmt) {
		const d = node.data as DoWhileStmtData;
		borrowTraverse(b, d.doBody);
		borrowTraverse(b, d.doCondition);
		borrowTraverse(b, d.doBody);
		borrowTraverse(b, d.doCondition);
		return;
	}
	if (k == NodeKind.ForStmt) {
		const d = node.data as ForStmtData;
		const saved = enterBorrowScope(b, node);
		for (let round = 0; round < 2; round += 1) {
			borrowTraverse(b, d.forInit);
			borrowTraverse(b, d.forCondition);
			borrowTraverse(b, d.forUpdate);
			borrowTraverse(b, d.forBody);
		}
		b.scope = saved;
		return;
	}
	if (k == NodeKind.ForOfStmt) {
		const d = node.data as ForOfStmtData;
		borrowTraverse(b, d.forOfIterable);
		const saved = enterBorrowScope(b, node);
		borrowTraverse(b, d.forOfBody);
		borrowTraverse(b, d.forOfBody);
		b.scope = saved;
		return;
	}
	if (k == NodeKind.ForInStmt) {
		const d = node.data as ForInStmtData;
		borrowTraverse(b, d.forInObject);
		const saved = enterBorrowScope(b, node);
		borrowTraverse(b, d.forInBody);
		borrowTraverse(b, d.forInBody);
		b.scope = saved;
		return;
	}
	if (k == NodeKind.CallExpr) {
		const d = node.data as CallExprData;
		borrowTraverse(b, d.callee);
		for (const a of d.arguments) { borrowTraverse(b, a); }
		callBorrowEffects(b, node, line);
		return;
	}
	if (k == NodeKind.NewExpr) {
		const d = node.data as NewExprData;
		borrowTraverse(b, d.newCallee);
		for (const a of d.newArguments) { borrowTraverse(b, a); }
		for (const a of d.newArguments) { argBorrowEffect(b, a, null, false, line); }
		return;
	}
	if (k == NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		borrowTraverse(b, d.left);
		borrowTraverse(b, d.right);
		if (d.operator == "=") assignBorrow(b, d.left, d.right, line);
		else if (isCompoundAssign(d.operator)) mutateBorrowRoots(b, d.left, line);
		return;
	}
	if (k == NodeKind.UpdateExpr) {
		const arg = (node.data as UpdateExprData).updateArg;
		borrowTraverse(b, arg);
		mutateBorrowRoots(b, arg, line);
		return;
	}
	if (k == NodeKind.MoveExpr) {
		const arg = (node.data as MoveExprData).moveArg;
		borrowTraverse(b, arg);
		mutateBorrowRoots(b, arg, line);
		return;
	}
	if (k == NodeKind.AwaitExpr || k == NodeKind.YieldExpr) {
		const here = b.p.abstractTime;
		forEachChild(node, (c: Node): void => { borrowTraverse(b, c); });
		b.suspends.push({ time: here, line });
		return;
	}
	if (k == NodeKind.ArrayLiteral) {
		const elems = (node.data as ArrayLiteralData).elements;
		for (const e of elems) { borrowTraverse(b, e); }
		for (const e of elems) { handOffBorrow(b, e, line, true); }
		return;
	}
	if (k == NodeKind.ObjectLiteral) {
		const props = (node.data as ObjectLiteralData).properties;
		for (const pr of props) { borrowTraverse(b, pr); }
		for (const pr of props) { handOffBorrow(b, pr, line, true); }
		return;
	}
	forEachChild(node, (c: Node): void => { borrowTraverse(b, c); });
}

function collectPatternSyms(node: Node | null, out: Symbol[]): void {
	if (node == null) return;
	const k = node.kind;
	if (k == NodeKind.Identifier) {
		if (node.resolvedSym != null && isValueSymbol(node.resolvedSym)) out.push(node.resolvedSym);
	} else if (k == NodeKind.ArrayPattern) {
		for (const e of (node.data as ArrayPatternData).patternElements) { collectPatternSyms(e, out); }
	} else if (k == NodeKind.ObjectPattern) {
		for (const pr of (node.data as ObjectPatternData).patternProps) { collectPatternSyms(pr, out); }
	} else if (k == NodeKind.ObjectPatternProp) {
		collectPatternSyms((node.data as ObjectPatternPropData).propAlias, out);
	}
}

function mutateBorrow(b: BorrowCheck, sym: Symbol, line: int32): void {
	if (variableId(b.p, sym) < 0) return;
	potentialMutation(b.p, sym);
	b.sites.push({ time: b.p.abstractTime, line });
}

function mutateBorrowRoots(b: BorrowCheck, node: Node | null, line: int32): void {
	if (node == null) return;
	const roots: Symbol[] = [];
	borrowRoots(node, roots);
	for (const r of roots) { mutateBorrow(b, r, line); }
}

function borrowRoots(node: Node | null, out: Symbol[]): void {
	if (node == null) return;
	const k = node.kind;
	if (k == NodeKind.Identifier) {
		if (node.resolvedSym != null) out.push(node.resolvedSym);
		return;
	}
	if (k == NodeKind.MemberExpr) {
		borrowRoots((node.data as MemberExprData).object, out);
		return;
	}
	if (k == NodeKind.ArrayAccess) {
		borrowRoots((node.data as ArrayAccessData).array, out);
		return;
	}
	if (k == NodeKind.HiddenDeref || k == NodeKind.HiddenAddr) {
		borrowRoots((node.data as { expr: Node }).expr, out);
		return;
	}
	if (k == NodeKind.HiddenStdConv || k == NodeKind.HiddenSubConv) {
		borrowRoots((node.data as HiddenStdConvData).convExpr, out);
		return;
	}
	if (k == NodeKind.TypeAssertion) {
		borrowRoots((node.data as TypeAssertionData).asExpr, out);
		return;
	}
	if (k == NodeKind.ConditionalExpr) {
		const d = node.data as ConditionalExprData;
		borrowRoots(d.ternaryConsequent, out);
		borrowRoots(d.ternaryAlternate, out);
		return;
	}
	if (k == NodeKind.ArrayLiteral) {
		for (const e of (node.data as ArrayLiteralData).elements) { borrowRoots(e, out); }
		return;
	}
	if (k == NodeKind.ObjectLiteral) {
		for (const pr of (node.data as ObjectLiteralData).properties) { borrowRoots(pr, out); }
		return;
	}
	if (k == NodeKind.SpreadExpr) {
		borrowRoots((node.data as SpreadExprData).spreadArg, out);
		return;
	}
	if (k == NodeKind.NewExpr) {
		for (const a of (node.data as NewExprData).newArguments) { borrowRoots(a, out); }
		return;
	}
	if (k == NodeKind.CallExpr) callRoots(node, out);
}

function callRoots(node: Node, out: Symbol[]): void {
	const d = node.data as CallExprData;
	const callee = d.callee;
	const recv = callee != null && callee.kind == NodeKind.MemberExpr ? (callee.data as MemberExprData).object : null;
	if (viewTypeOf(node.nodeType) != null) {
		if (recv != null) borrowRoots(recv, out);
		else if (d.arguments.length > 0) borrowRoots(d.arguments[0], out);
		return;
	}
	let calleeSym = node.resolvedSym;
	if (calleeSym == null && callee != null) calleeSym = callee.resolvedSym;
	if (calleeSym != null && calleeSym.builtinKind != "") return;
	const fnType = callee != null ? callee.nodeType : null;
	const formals: Type[] = fnType != null && fnType.kind == TypeKind.Function ? fnType.typeChildren : [];
	const ret = node.nodeType;
	let offset: int32 = 0;
	if (recv != null) {
		if (formals.length == d.arguments.length + 1) {
			offset = 1;
			if (canAliasResult(formals[0], ret)) borrowRoots(recv, out);
		} else if (canAliasResult(recv.nodeType, ret)) {
			borrowRoots(recv, out);
		}
	}
	for (let i = 0; i < d.arguments.length; i += 1) {
		const fi = i + offset;
		const arg = d.arguments[i];
		if (arg == null) continue;
		const formal = fi < formals.length && formals[fi].kind != TypeKind.Varargs ? formals[fi] : arg.nodeType;
		if (canAliasResult(formal, ret)) borrowRoots(arg, out);
	}
}

function canAliasResult(param: Type | null, ret: Type | null): boolean {
	if (param == null || ret == null) return true;
	return containsPointer(param, 0) && containsPointer(ret, 0);
}

function borrowConnectStore(b: BorrowCheck, targets: Symbol[], destType: Type | null, src: Node | null): void {
	if (src == null || !containsPointer(destType, 0)) return;
	const sources: Symbol[] = [];
	borrowRoots(src, sources);
	for (const t of targets) {
		for (const s of sources) { ufConnect(b.p, t, s); }
	}
}

function handOffBorrow(b: BorrowCheck, node: Node | null, line: int32, escapes: boolean): void {
	if (node == null) return;
	const k = node.kind;
	if (k == NodeKind.HiddenStdConv || k == NodeKind.HiddenSubConv) {
		handOffBorrow(b, (node.data as HiddenStdConvData).convExpr, line, escapes);
		return;
	}
	if (k == NodeKind.TypeAssertion) {
		handOffBorrow(b, (node.data as TypeAssertionData).asExpr, line, escapes);
		return;
	}
	if (k == NodeKind.ConditionalExpr) {
		const d = node.data as ConditionalExprData;
		handOffBorrow(b, d.ternaryConsequent, line, escapes);
		handOffBorrow(b, d.ternaryAlternate, line, escapes);
		return;
	}
	const sym = k == NodeKind.Identifier ? node.resolvedSym : null;
	if (sym == null) return;
	handOffSym(b, sym, line, escapes);
}

function handOffSym(b: BorrowCheck, sym: Symbol, line: int32, escapes: boolean): void {
	const id = variableId(b.p, sym);
	if (id < 0 || !b.vars[id].movable || b.vars[id].isView || !ownsMemory(sym.symbolType, 0)) return;
	mutateBorrow(b, sym, line);
	if (escapes) b.vars[id].escaped = true;
}

function captureHandOff(b: BorrowCheck, node: Node | null, line: int32): void {
	if (node == null) return;
	if (node.kind == NodeKind.Identifier) {
		if (node.resolvedSym != null) handOffSym(b, node.resolvedSym!, line, true);
		return;
	}
	forEachChild(node, (c: Node): void => { captureHandOff(b, c, line); });
}

function ownsMemory(t: Type | null, depth: int32): boolean {
	if (t == null || depth > 8 || isPrimitiveKind(t.kind) || isViewKind(t)) return false;
	return match (t.kind) {
		TypeKind.String => true,
		TypeKind.StringLiteral | TypeKind.CString | TypeKind.Ptr | TypeKind.Null | TypeKind.Void
			| TypeKind.Enum | TypeKind.EnumLiteral | TypeKind.BooleanLiteral => false,
		TypeKind.Struct | TypeKind.Tuple | TypeKind.Union => {
			for (const c of t.typeChildren) {
				if (ownsMemory(c, depth + 1)) return true;
			}
			return false;
		},
		TypeKind.SizedArray | TypeKind.Distinct | TypeKind.Alias => ownsMemory(t.typeReturn, depth + 1),
		_ => true,
	};
}

function bindBorrowLocal(b: BorrowCheck, sym: Symbol, init: Node, line: int32, col: int32): void {
	const id = variableId(b.p, sym);
	if (id < 0) return;
	if (b.vars[id].isView) {
		borrowFromPath(b, id, init, line, col);
		return;
	}
	borrowConnectStore(b, [sym], sym.symbolType, init);
	handOffBorrow(b, init, line, false);
}

function assignBorrow(b: BorrowCheck, left: Node | null, right: Node | null, line: int32): void {
	if (left == null || right == null) return;
	if (left.kind == NodeKind.Identifier && left.resolvedSym != null) {
		const id = variableId(b.p, left.resolvedSym);
		if (id >= 0 && b.vars[id].isView) {
			borrowFromPath(b, id, right, left.location.line, left.location.column);
			return;
		}
	}
	const roots: Symbol[] = [];
	borrowRoots(left, roots);
	for (const r of roots) { mutateBorrow(b, r, line); }
	borrowConnectStore(b, roots, left.nodeType, right);
	let outward = left.kind != NodeKind.Identifier;
	for (const r of roots) { if (hasFlag(r, SymbolFlag.Global)) outward = true; }
	handOffBorrow(b, right, line, outward);
}

function callBorrowEffects(b: BorrowCheck, node: Node, line: int32): void {
	const d = node.data as CallExprData;
	const callee = d.callee;
	const fnType = callee != null ? callee.nodeType : null;
	const formals: Type[] = fnType != null && fnType.kind == TypeKind.Function ? fnType.typeChildren : [];
	let calleeSym = node.resolvedSym;
	if (calleeSym == null && callee != null) calleeSym = callee.resolvedSym;
	const magic = calleeSym != null && calleeSym.builtinKind != "";
	if (!magic) b.calls.push({ time: b.p.abstractTime, line });
	let offset: int32 = 0;
	if (callee != null && callee.kind == NodeKind.MemberExpr) {
		const recv = (callee.data as MemberExprData).object;
		if (isMutatingArrayMethod((callee.data as MemberExprData).property)) mutateBorrowRoots(b, recv, line);
		if (formals.length == d.arguments.length + 1) {
			offset = 1;
			argBorrowEffect(b, recv, formals[0], magic, line);
		} else if (!magic && recv.nodeType != null && recv.nodeType.kind != TypeKind.String) {
			mutateBorrowRoots(b, recv, line);
		}
	}
	for (let i = 0; i < d.arguments.length; i += 1) {
		const fi = i + offset;
		argBorrowEffect(b, d.arguments[i], fi < formals.length ? formals[fi] : null, magic, line);
	}
}

function argBorrowEffect(b: BorrowCheck, arg: Node | null, formal: Type | null, magic: boolean, line: int32): void {
	if (arg == null) return;
	if (formal != null && (formal.kind == TypeKind.Var || formal.kind == TypeKind.Sink
			|| (formal.kind == TypeKind.Span && !isReadonlyView(formal)))) {
		mutateBorrowRoots(b, arg, line);
		if (formal.kind == TypeKind.Sink) escapeBorrowRoots(b, arg);
		return;
	}
	if (magic || (formal != null && isReadonlyView(formal))) return;
	const t = formal != null && formal.kind != TypeKind.Varargs ? formal : arg.nodeType;
	if (containsPointer(t, 0)) mutateBorrowRoots(b, arg, line);
}

function escapeBorrowRoots(b: BorrowCheck, arg: Node | null): void {
	const roots: Symbol[] = [];
	borrowRoots(arg, roots);
	for (const r of roots) {
		const id = variableId(b.p, r);
		if (id >= 0) b.vars[id].escaped = true;
	}
}


function pathRoots(node: Node | null, roots: Symbol[], literals: int32[]): boolean {
	if (node == null) return false;
	const k = node.kind;
	if (k == NodeKind.Identifier) {
		const sym = node.resolvedSym;
		if (sym == null || !isValueSymbol(sym)) return false;
		roots.push(sym);
		return true;
	}
	if (k == NodeKind.MemberExpr) return pathRoots((node.data as MemberExprData).object, roots, literals);
	if (k == NodeKind.ArrayAccess) return pathRoots((node.data as ArrayAccessData).array, roots, literals);
	if (k == NodeKind.HiddenStdConv || k == NodeKind.HiddenSubConv) return pathRoots((node.data as HiddenStdConvData).convExpr, roots, literals);
	if (k == NodeKind.HiddenDeref || k == NodeKind.HiddenAddr) return pathRoots((node.data as { expr: Node }).expr, roots, literals);
	if (k == NodeKind.ConditionalExpr) {
		const d = node.data as ConditionalExprData;
		return pathRoots(d.ternaryConsequent, roots, literals) && pathRoots(d.ternaryAlternate, roots, literals);
	}
	if (k == NodeKind.CallExpr && viewTypeOf(node.nodeType) != null) {
		const d = node.data as CallExprData;
		if (d.callee != null && d.callee.kind == NodeKind.MemberExpr) return pathRoots((d.callee.data as MemberExprData).object, roots, literals);
		if (d.arguments.length > 0) return pathRoots(d.arguments[0], roots, literals);
		return false;
	}
	if (isConstantExpr(node)) {
		literals.push(1);
		return true;
	}
	if (k == NodeKind.TypeAssertion) return pathRoots((node.data as TypeAssertionData).asExpr, roots, literals);
	return false;
}

function isConstantExpr(node: Node | null): boolean {
	if (node == null) return false;
	const k = node.kind;
	if (k == NodeKind.StringLiteral || k == NodeKind.NumberLiteral || k == NodeKind.BooleanLiteral) return true;
	if (k == NodeKind.TypeAssertion) return isConstantExpr((node.data as TypeAssertionData).asExpr);
	if (k == NodeKind.ArrayLiteral) {
		for (const e of (node.data as ArrayLiteralData).elements) {
			if (!isConstantExpr(e)) return false;
		}
		return true;
	}
	return false;
}

function reportBorrow(b: BorrowCheck, viewId: int32, msg: string, line: int32, col: int32): void {
	if (b.vars[viewId].reported) return;
	b.vars[viewId].reported = true;
	addError(b.ctx, msg, line, col);
}

function borrowFromPath(b: BorrowCheck, viewId: int32, src: Node, line: int32, col: int32): void {
	const name = b.p.vars[viewId].sym.name;
	const roots: Symbol[] = [];
	const literals: int32[] = [];
	if (!pathRoots(src, roots, literals)) {
		reportBorrow(b, viewId, "'" + name + "' cannot borrow from a temporary: the value is destroyed at the end of this statement while '"
			+ name + "' still views it — bind the value to a local first (const s = …; const " + name + " = s…), or copy it with [...x]", line, col);
		return;
	}
	if (literals.length > 0 && !scopeEncloses(b, b.scope, b.vars[viewId].scope)) {
		reportBorrow(b, viewId, "'" + name + "' outlives the literal it views: the literal ends with its block — declare '" + name + "' inside that block", line, col);
	}
	for (const r of roots) { addBorrowRoot(b, viewId, r, line, col, 0); }
}

function addBorrowRoot(b: BorrowCheck, viewId: int32, sym: Symbol, line: int32, col: int32, depth: int32): void {
	if (depth > 8) return;
	const name = b.p.vars[viewId].sym.name;
	if (hasFlag(sym, SymbolFlag.Global)) {
		if (!isImmutableGlobal(sym)) {
			reportBorrow(b, viewId, "'" + name + "' cannot borrow from module-level '" + sym.name + "': any call can change it while '"
				+ name + "' is read — pass it in as a parameter, or copy it with [...x]", line, col);
		}
		return;
	}
	const sid = variableId(b.p, sym);
	if (sid < 0) return;
	if (!b.vars[sid].owned) {
		reportBorrow(b, viewId, "'" + name + "' cannot borrow from '" + sym.name
			+ "', which belongs to the enclosing function: this function cannot keep it from changing — copy it into a local first", line, col);
		return;
	}
	if (!scopeEncloses(b, b.vars[sid].scope, b.vars[viewId].scope)) {
		reportBorrow(b, viewId, "'" + name + "' borrows from '" + sym.name + "', which is destroyed at the end of its block while '"
			+ name + "' still exists — declare '" + name + "' inside that block, or copy it with [...x]", line, col);
	}
	if (!b.vars[viewId].borrowsFrom.includes(sid)) b.vars[viewId].borrowsFrom.push(sid);
	if (sid == viewId) return;
	for (const inner of b.vars[sid].borrowsFrom) {
		if (!b.vars[viewId].borrowsFrom.includes(inner)) b.vars[viewId].borrowsFrom.push(inner);
	}
	for (const o of b.vars[sid].origins) { addBorrowRoot(b, viewId, o, line, col, depth + 1); }
}


function firstDangerousMutation(g: MutationInfo, v: VarEntry): int32 {
	if ((g.flags & SF_IS_MUTATED) == 0) return -1;
	let first: int32 = -1;
	for (const m of g.mutations) {
		if (m >= v.aliveStart && m <= v.aliveEnd && (first < 0 || m < first)) first = m;
	}
	return first;
}

function mutationLine(b: BorrowCheck, time: int32): int32 {
	for (const s of b.sites) {
		if (s.time == time) return s.line;
	}
	return 0;
}

function checkBorrowedLocations(b: BorrowCheck): void {
	for (let i = 0; i < b.vars.length; i += 1) {
		const bv = b.vars[i];
		if (!bv.isView || bv.reported || (b.p.vars[i].flags & VF_IS_PARAM) != 0) continue;
		const name = b.p.vars[i].sym.name;
		let suspended = false;
		for (const sp of b.suspends) {
			if (sp.time >= b.p.vars[i].aliveStart && sp.time <= b.p.vars[i].aliveEnd) {
				addError(b.ctx, "'" + name + "' is read at line " + bv.lastUseLine + " across an await or yield at line " + sp.line
					+ ": the view is captured into the frame the function suspends in, and its source can change or die while it runs — copy it with [...x] before the await, or take the view again after",
					bv.declLine, bv.declCol);
				b.vars[i].reported = true;
				suspended = true;
				break;
			}
		}
		if (suspended) continue;
		for (const sid of bv.borrowsFrom) {
			const r = ufRoot(b.p, sid);
			if (b.p.vars[r].con.kind != CK_ROOT_OF) continue;
			const m = firstDangerousMutation(b.p.graphs[b.p.vars[r].con.target], b.p.vars[i]);
			if (m < 0) continue;
			addError(b.ctx, "'" + name + "' is read at line " + bv.lastUseLine + " after '" + b.p.vars[sid].sym.name
				+ "', the source it borrows from, changes at line " + mutationLine(b, m)
				+ ": a view does not survive a change to its source — take the view again after the change, or copy it first with [...x]",
				bv.declLine, bv.declCol);
			b.vars[i].reported = true;
			break;
		}
		if (!b.vars[i].reported) checkFragileSource(b, i);
	}
}

function checkFragileSource(b: BorrowCheck, viewId: int32): void {
	const bv = b.vars[viewId];
	let fragileName: string = "";
	let escaped = false;
	for (const sid of bv.borrowsFrom) {
		if ((b.p.vars[sid].flags & VF_IS_PARAM) != 0 && containsPointer(b.p.vars[sid].sym.symbolType, 0)) {
			fragileName = b.p.vars[sid].sym.name;
			break;
		}
		if (b.vars[sid].escaped) {
			fragileName = b.p.vars[sid].sym.name;
			escaped = true;
			break;
		}
	}
	if (fragileName == "") {
		for (const o of bv.origins) {
			const oid = variableId(b.p, o);
			if (oid < 0) continue;
			if ((b.p.vars[oid].flags & VF_IS_PARAM) != 0 && containsPointer(o.symbolType, 0)) {
				fragileName = o.name;
				break;
			}
			if (b.vars[oid].escaped) {
				fragileName = o.name;
				escaped = true;
				break;
			}
		}
	}
	if (fragileName == "") return;
	const name = b.p.vars[viewId].sym.name;
	for (const s of b.sites) {
		if (s.time >= b.p.vars[viewId].aliveStart && s.time <= b.p.vars[viewId].aliveEnd) {
			addError(b.ctx, "'" + name + "' borrows from '" + fragileName
				+ "', which a call can change through an alias the checker cannot see (a parameter the caller may alias, or a source handed to a global, field or closure), and the change is at line " + s.line
				+ ": take the view again after the call, or copy it first with [...x]",
				bv.declLine, bv.declCol);
			b.vars[viewId].reported = true;
			return;
		}
	}
	if (!escaped) return;
	for (const c of b.calls) {
		if (c.time >= b.p.vars[viewId].aliveStart && c.time <= b.p.vars[viewId].aliveEnd) {
			addError(b.ctx, "'" + name + "' borrows from '" + fragileName
				+ "', which escaped to memory a call can reach, and the call is at line " + c.line
				+ ": take the view again after the call, or copy it first with [...x]",
				bv.declLine, bv.declCol);
			b.vars[viewId].reported = true;
			return;
		}
	}
}
