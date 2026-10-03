import {
	Node, NodeKind, Symbol, Type, TypeKind,
	MemberExprData, ArrayAccessData, ConditionalExprData, ArrayLiteralData, ObjectLiteralData,
	SpreadExprData, NewExprData, CallExprData, HiddenStdConvData, TypeAssertionData,
} from "../ast/node";
import { isPrimitiveKind } from "./types";

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
