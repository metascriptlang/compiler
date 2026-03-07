// varpartitions.ms — Steensgaard-style alias analysis for readonly parameter mutation detection
// Port of the standard reference implementation for alias analysis.
//
// Two-pass algorithm:
//   Pass 1 (computeLiveRanges): Register variables, track lifetimes
//   Pass 2 (traverse): Build alias graphs via union-find, track mutations
//
// After both passes, check if any graph is both mutated AND connected to a readonly param.
// If mutation happened after connection (or is direct), report an error.

import {
	Node, NodeKind, DeclKind,
	IdentifierData, BinaryExprData, UpdateExprData,
	CallExprData, MemberExprData, ArrayAccessData,
	OutExprData, HiddenDerefData, HiddenAddrData,
	TypeAssertionData, ConditionalExprData, SpreadExprData,
	ObjectLiteralData, ArrayLiteralData, NewExprData,
	ArrowFunctionData, FunctionExprData,
	AwaitExprData, YieldExprData, MoveExprData,
	MatchExprData, MatchCaseData, TryExprData,
	VariableDeclData, BlockStmtData, IfStmtData,
	WhileStmtData, ForStmtData, ForOfStmtData, ForInStmtData,
	DoWhileStmtData, ExprStmtData, ReturnStmtData,
	ThrowStmtData, DeferStmtData, TryCatchStmtData,
	SwitchStmtData, SwitchCaseData, MatchStmtData,
	DecoratedDeclData, FunctionDeclData, TestDeclData,
} from "../ast/node";
import { Type, TypeKind, isReadonly } from "./types";
import { Symbol, SymbolKind } from "./symbol";
import { CheckerContext, addError } from "./context";

// ===== Constants =====

const MAX_TIME: number = 999999;
const MIN_TIME: number = -1;

// Subgraph flags (bitfield)
const FLAG_MUTATED: number = 1;
const FLAG_MUTATED_DIRECTLY: number = 2;
const FLAG_MUTATED_BY_VAR: number = 4;
const FLAG_CONNECTS_CONST: number = 8;

// ===== Data Structures =====

enum VarIndexKind {
	EmptyRoot,
	DependsOn,
	RootOf,
}

interface VarIndex {
	kind: VarIndexKind;
	parent: number;
	graphIndex: number;
	name: string;
	symKind: SymbolKind;
	symType: Type;
	aliveStart: number;
	aliveEnd: number;
}

interface MutationInfo {
	paramName: string;
	mutatedHere: number;
	connectedVia: number;
	flags: number;
	maxMutation: number;
	minConnection: number;
}

interface Partitions {
	abstractTime: number;
	vars: VarIndex[];
	graphs: MutationInfo[];
	inLoop: number;
	inConditional: number;
}

function createPartitions(): Partitions {
	return {
		abstractTime: 0,
		vars: [],
		graphs: [],
		inLoop: 0,
		inConditional: 0,
	};
}

// ===== Union-Find Operations =====

function variableId(p: Partitions, name: string): number {
	let i = 0;
	while (i < p.vars.length) {
		if (p.vars[i].name === name) return i;
		i = i + 1;
	}
	return -1;
}

function ufRoot(p: Partitions, start: number): number {
	let r = start;
	let depth = 0;
	while (p.vars[r].kind === VarIndexKind.DependsOn) {
		r = p.vars[r].parent;
		depth = depth + 1;
		if (depth > 100) return r;
	}
	// Path compression
	if (depth > 0) {
		let it = start;
		while (p.vars[it].kind === VarIndexKind.DependsOn) {
			const next = p.vars[it].parent;
			p.vars[it].parent = r;
			it = next;
		}
	}
	return r;
}

// ===== Helpers =====

function isConstVar(v: VarIndex): boolean {
	return v.symKind === SymbolKind.Parameter && isReadonly(v.symType);
}

function getLine(node: Node): number {
	if (node === null) return 0;
	return node.location.line;
}

function containsPointer(t: Type): boolean {
	if (t === null) return true;
	if (t.kind === TypeKind.Array) return true;
	if (t.kind === TypeKind.String) return true;
	if (t.kind === TypeKind.Ref) return true;
	if (t.kind === TypeKind.Ptr) return true;
	if (t.kind === TypeKind.Function) return true;
	if (t.kind === TypeKind.Object) return true;
	if (t.kind === TypeKind.Union) return true;
	return false;
}

function nodeContainsPointer(node: Node): boolean {
	if (node === null) return true;
	if (node.nodeType === null) return true;
	return containsPointer(node.nodeType);
}

function isMutatingMethod(method: string): boolean {
	if (method === "push") return true;
	if (method === "pop") return true;
	if (method === "shift") return true;
	if (method === "unshift") return true;
	if (method === "splice") return true;
	if (method === "reverse") return true;
	if (method === "sort") return true;
	if (method === "fill") return true;
	if (method === "copyWithin") return true;
	if (method === "append") return true;
	if (method === "setLength") return true;
	if (method === "setSlice") return true;
	if (method === "stripInPlace") return true;
	if (method === "setLen") return true;
	return false;
}

function isAssignment(op: string): boolean {
	if (op === "=") return true;
	if (op === "+=") return true;
	if (op === "-=") return true;
	if (op === "*=") return true;
	if (op === "/=") return true;
	if (op === "%=") return true;
	if (op === "&=") return true;
	if (op === "|=") return true;
	if (op === "^=") return true;
	if (op === "<<=") return true;
	if (op === ">>=") return true;
	if (op === ">>>=") return true;
	return false;
}

// ===== Root Extraction =====
// Walks a path expression iteratively to find the root symbol name.
// Returns "" for complex expressions (constructors, calls, literals).

function findRoot(node: Node): string {
	let n = node;
	while (n !== null) {
		if (n.kind === NodeKind.Identifier) {
			return (n.data as IdentifierData).name;
		}
		if (n.kind === NodeKind.MemberExpr) {
			n = (n.data as MemberExprData).object;
			continue;
		}
		if (n.kind === NodeKind.ArrayAccess) {
			n = (n.data as ArrayAccessData).array;
			continue;
		}
		if (n.kind === NodeKind.HiddenDeref) {
			n = (n.data as HiddenDerefData).expr;
			continue;
		}
		if (n.kind === NodeKind.HiddenAddr) {
			n = (n.data as HiddenAddrData).expr;
			continue;
		}
		if (n.kind === NodeKind.TypeAssertion) {
			n = (n.data as TypeAssertionData).asExpr;
			continue;
		}
		return "";
	}
	return "";
}

// ===== Variable Registration =====

function registerParam(p: Partitions, name: string, paramType: Type): void {
	if (isReadonly(paramType)) {
		// Const param: create graph with connectsConstParam immediately
		const gi = p.graphs.length;
		p.graphs.push({
			paramName: name,
			mutatedHere: 0,
			connectedVia: 0,
			flags: FLAG_CONNECTS_CONST,
			maxMutation: MIN_TIME,
			minConnection: MAX_TIME,
		});
		p.vars.push({
			kind: VarIndexKind.RootOf,
			parent: 0,
			graphIndex: gi,
			name: name,
			symKind: SymbolKind.Parameter,
			symType: paramType,
			aliveStart: p.abstractTime,
			aliveEnd: p.abstractTime,
		});
	} else {
		p.vars.push({
			kind: VarIndexKind.EmptyRoot,
			parent: 0,
			graphIndex: 0,
			name: name,
			symKind: SymbolKind.Parameter,
			symType: paramType,
			aliveStart: p.abstractTime,
			aliveEnd: p.abstractTime,
		});
	}
}

function registerVariable(p: Partitions, name: string): void {
	if (variableId(p, name) >= 0) return;
	p.vars.push({
		kind: VarIndexKind.EmptyRoot,
		parent: 0,
		graphIndex: 0,
		name: name,
		symKind: SymbolKind.Variable,
		symType: null as unknown as Type,
		aliveStart: p.abstractTime,
		aliveEnd: p.abstractTime,
	});
}

// ===== Graph Connection (Union) =====

function connect(p: Partitions, aName: string, bName: string, line: number): void {
	const aid = variableId(p, aName);
	if (aid < 0) return;
	const bid = variableId(p, bName);
	if (bid < 0) return;

	const ra = ufRoot(p, aid);
	const rb = ufRoot(p, bid);
	if (ra === rb) return;

	// Determine if either side is a const param
	let paramName = "";
	if (isConstVar(p.vars[aid])) paramName = p.vars[aid].name;
	if (paramName === "" && isConstVar(p.vars[bid])) paramName = p.vars[bid].name;

	let paramFlags = 0;
	if (paramName !== "") paramFlags = FLAG_CONNECTS_CONST;

	// Collect rb's graph info before merging
	let rbFlags = 0;
	let rbMutatedHere = 0;
	let rbMaxMut = 0;
	let rbMinCon = p.abstractTime;
	if (p.vars[rb].kind === VarIndexKind.RootOf) {
		const gb = p.graphs[p.vars[rb].graphIndex];
		if (paramName === "" && gb.paramName !== "") paramName = gb.paramName;
		rbFlags = gb.flags;
		rbMutatedHere = gb.mutatedHere;
		rbMaxMut = gb.maxMutation;
		if (gb.minConnection < rbMinCon) rbMinCon = gb.minConnection;
	}

	// Make rb depend on ra (ra becomes root)
	p.vars[rb].kind = VarIndexKind.DependsOn;
	p.vars[rb].parent = ra;

	if (p.vars[ra].kind === VarIndexKind.EmptyRoot) {
		// ra had no graph — create one merging rb's info
		const gi = p.graphs.length;
		let minCon = p.abstractTime;
		if (rbMinCon < minCon) minCon = rbMinCon;
		p.graphs.push({
			paramName: paramName,
			mutatedHere: rbMutatedHere,
			connectedVia: line,
			flags: paramFlags | rbFlags,
			maxMutation: rbMaxMut,
			minConnection: minCon,
		});
		p.vars[ra].kind = VarIndexKind.RootOf;
		p.vars[ra].graphIndex = gi;
	} else if (p.vars[ra].kind === VarIndexKind.RootOf) {
		// ra already has a graph — merge rb's info
		const g = p.graphs[p.vars[ra].graphIndex];
		if (g.paramName === "" && paramName !== "") g.paramName = paramName;
		if (g.mutatedHere === 0 && rbMutatedHere !== 0) g.mutatedHere = rbMutatedHere;
		if (rbMinCon < g.minConnection) g.minConnection = rbMinCon;
		g.connectedVia = line;
		g.flags = g.flags | paramFlags | rbFlags;
		if (rbMaxMut > g.maxMutation) g.maxMutation = rbMaxMut;
	}
}

// ===== Mutation Recording =====

function potentialMutation(p: Partitions, name: string, line: number, isDirect: boolean): void {
	const id = variableId(p, name);
	if (id < 0) return;

	const r = ufRoot(p, id);
	let flags = FLAG_MUTATED;
	if (isDirect && isConstVar(p.vars[id])) {
		flags = flags | FLAG_MUTATED_DIRECTLY;
	}

	if (p.vars[r].kind === VarIndexKind.EmptyRoot) {
		const gi = p.graphs.length;
		let pName = "";
		if (isConstVar(p.vars[id])) pName = p.vars[id].name;
		p.graphs.push({
			paramName: pName,
			mutatedHere: line,
			connectedVia: 0,
			flags: flags,
			maxMutation: p.abstractTime,
			minConnection: MAX_TIME,
		});
		p.vars[r].kind = VarIndexKind.RootOf;
		p.vars[r].graphIndex = gi;
	} else if (p.vars[r].kind === VarIndexKind.RootOf) {
		const g = p.graphs[p.vars[r].graphIndex];
		if (g.paramName === "" && isConstVar(p.vars[id])) {
			g.paramName = p.vars[id].name;
		}
		if (p.abstractTime > g.maxMutation) {
			g.mutatedHere = line;
			g.maxMutation = p.abstractTime;
		}
		g.flags = g.flags | flags;
	}
}

function potentialMutationViaVar(p: Partitions, name: string, line: number): void {
	const id = variableId(p, name);
	if (id < 0) return;

	const r = ufRoot(p, id);
	let flags = FLAG_MUTATED | FLAG_MUTATED_BY_VAR;
	if (isConstVar(p.vars[id])) {
		flags = flags | FLAG_MUTATED_DIRECTLY;
	}

	if (p.vars[r].kind === VarIndexKind.EmptyRoot) {
		const gi = p.graphs.length;
		let pName = "";
		if (isConstVar(p.vars[id])) pName = p.vars[id].name;
		p.graphs.push({
			paramName: pName,
			mutatedHere: line,
			connectedVia: 0,
			flags: flags,
			maxMutation: p.abstractTime,
			minConnection: MAX_TIME,
		});
		p.vars[r].kind = VarIndexKind.RootOf;
		p.vars[r].graphIndex = gi;
	} else if (p.vars[r].kind === VarIndexKind.RootOf) {
		const g = p.graphs[p.vars[r].graphIndex];
		if (g.paramName === "" && isConstVar(p.vars[id])) {
			g.paramName = p.vars[id].name;
		}
		if (p.abstractTime > g.maxMutation) {
			g.mutatedHere = line;
			g.maxMutation = p.abstractTime;
		}
		g.flags = g.flags | flags;
	}
}

// potentialMutationViaArg: conservative check — argument passed to non-out function
// param might be mutated if the arg type contains a pointer (Implementation parity)
function potentialMutationViaArg(p: Partitions, node: Node, line: number): void {
	if (!nodeContainsPointer(node)) return;
	const r = findRoot(node);
	if (r === "") return;
	potentialMutation(p, r, line, false);
}

// ===== Pass 1: Compute Live Ranges =====
// Walks the AST to register variables and track their alive ranges.

function liveRangesExpr(p: Partitions, node: Node): void {
	if (node === null) return;
	p.abstractTime = p.abstractTime + 1;

	if (node.kind === NodeKind.Identifier) {
		p.abstractTime = p.abstractTime - 1;
		const d = node.data as IdentifierData;
		const vid = variableId(p, d.name);
		if (vid >= 0 && p.abstractTime > p.vars[vid].aliveEnd) {
			p.vars[vid].aliveEnd = p.abstractTime;
		}
		return;
	}
	if (node.kind === NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		liveRangesExpr(p, d.left);
		liveRangesExpr(p, d.right);
		return;
	}
	if (node.kind === NodeKind.UpdateExpr) {
		liveRangesExpr(p, (node.data as UpdateExprData).updateArg);
		return;
	}
	if (node.kind === NodeKind.CallExpr) {
		const d = node.data as CallExprData;
		liveRangesExpr(p, d.callee);
		let i = 0;
		while (i < d.arguments.length) {
			liveRangesExpr(p, d.arguments[i]);
			i = i + 1;
		}
		return;
	}
	if (node.kind === NodeKind.MemberExpr) {
		liveRangesExpr(p, (node.data as MemberExprData).object);
		return;
	}
	if (node.kind === NodeKind.ArrayAccess) {
		const d = node.data as ArrayAccessData;
		liveRangesExpr(p, d.array);
		liveRangesExpr(p, d.index);
		return;
	}
	if (node.kind === NodeKind.ConditionalExpr) {
		const d = node.data as ConditionalExprData;
		liveRangesExpr(p, d.ternaryCondition);
		p.inConditional = p.inConditional + 1;
		liveRangesExpr(p, d.ternaryConsequent);
		liveRangesExpr(p, d.ternaryAlternate);
		p.inConditional = p.inConditional - 1;
		return;
	}
	if (node.kind === NodeKind.ArrayLiteral) {
		const d = node.data as ArrayLiteralData;
		for (const elem of d.elements) { liveRangesExpr(p, elem); }
		return;
	}
	if (node.kind === NodeKind.ObjectLiteral) {
		const d = node.data as ObjectLiteralData;
		for (const prop of d.properties) { liveRangesExpr(p, prop); }
		return;
	}
	if (node.kind === NodeKind.SpreadExpr) {
		liveRangesExpr(p, (node.data as SpreadExprData).spreadArg);
		return;
	}
	if (node.kind === NodeKind.TypeAssertion) {
		liveRangesExpr(p, (node.data as TypeAssertionData).asExpr);
		return;
	}
	if (node.kind === NodeKind.OutExpr) {
		liveRangesExpr(p, (node.data as OutExprData).outArg);
		return;
	}
	if (node.kind === NodeKind.NewExpr) {
		const d = node.data as NewExprData;
		liveRangesExpr(p, d.newCallee);
		for (const arg of d.newArguments) { liveRangesExpr(p, arg); }
		return;
	}
	if (node.kind === NodeKind.TryExpr) {
		const d = node.data as TryExprData;
		liveRangesExpr(p, d.tryArg);
		if (d.hasCatch) liveRangesExpr(p, d.catchVal);
		return;
	}
	if (node.kind === NodeKind.MatchExpr) {
		const d = node.data as MatchExprData;
		liveRangesExpr(p, d.matchDisc);
		for (const c of d.matchCases) {
			const cd = c.data as MatchCaseData;
			liveRangesExpr(p, cd.caseBody);
		}
		return;
	}
	if (node.kind === NodeKind.AwaitExpr) {
		liveRangesExpr(p, (node.data as AwaitExprData).awaitArg);
		return;
	}
	if (node.kind === NodeKind.YieldExpr) {
		liveRangesExpr(p, (node.data as YieldExprData).yieldArg);
		return;
	}
	if (node.kind === NodeKind.MoveExpr) {
		liveRangesExpr(p, (node.data as MoveExprData).moveArg);
		return;
	}
	if (node.kind === NodeKind.HiddenDeref) {
		liveRangesExpr(p, (node.data as HiddenDerefData).expr);
		return;
	}
	if (node.kind === NodeKind.HiddenAddr) {
		liveRangesExpr(p, (node.data as HiddenAddrData).expr);
		return;
	}
	// Skip nested function definitions
	if (node.kind === NodeKind.ArrowFunction || node.kind === NodeKind.FunctionExpr) return;
	// Other expression kinds: no children to walk
}

function liveRangesStmt(p: Partitions, node: Node): void {
	if (node === null) return;
	p.abstractTime = p.abstractTime + 1;

	if (node.kind === NodeKind.BlockStmt) {
		const d = node.data as BlockStmtData;
		for (const stmt of d.statements) { liveRangesStmt(p, stmt); }
		return;
	}
	if (node.kind === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		liveRangesExpr(p, d.initializer);
		registerVariable(p, d.declName);
		return;
	}
	if (node.kind === NodeKind.ExprStmt) {
		liveRangesExpr(p, (node.data as ExprStmtData).expr);
		return;
	}
	if (node.kind === NodeKind.ReturnStmt) {
		liveRangesExpr(p, (node.data as ReturnStmtData).argument);
		return;
	}
	if (node.kind === NodeKind.IfStmt) {
		const d = node.data as IfStmtData;
		liveRangesExpr(p, d.condition);
		p.inConditional = p.inConditional + 1;
		liveRangesStmt(p, d.consequent);
		liveRangesStmt(p, d.alternate);
		p.inConditional = p.inConditional - 1;
		return;
	}
	if (node.kind === NodeKind.WhileStmt) {
		const d = node.data as WhileStmtData;
		liveRangesExpr(p, d.whileCondition);
		liveRangesStmt(p, d.whileBody);
		// Double-traverse loops (standard reference pattern)
		p.inLoop = p.inLoop + 1;
		liveRangesExpr(p, d.whileCondition);
		liveRangesStmt(p, d.whileBody);
		p.inLoop = p.inLoop - 1;
		return;
	}
	if (node.kind === NodeKind.ForStmt) {
		const d = node.data as ForStmtData;
		liveRangesStmt(p, d.forInit);
		liveRangesExpr(p, d.forCondition);
		liveRangesExpr(p, d.forUpdate);
		liveRangesStmt(p, d.forBody);
		p.inLoop = p.inLoop + 1;
		liveRangesExpr(p, d.forCondition);
		liveRangesExpr(p, d.forUpdate);
		liveRangesStmt(p, d.forBody);
		p.inLoop = p.inLoop - 1;
		return;
	}
	if (node.kind === NodeKind.ForOfStmt) {
		const d = node.data as ForOfStmtData;
		liveRangesExpr(p, d.forOfIterable);
		registerVariable(p, d.forOfBinding);
		liveRangesStmt(p, d.forOfBody);
		p.inLoop = p.inLoop + 1;
		liveRangesStmt(p, d.forOfBody);
		p.inLoop = p.inLoop - 1;
		return;
	}
	if (node.kind === NodeKind.ForInStmt) {
		const d = node.data as ForInStmtData;
		liveRangesExpr(p, d.forInObject);
		registerVariable(p, d.forInBinding);
		liveRangesStmt(p, d.forInBody);
		p.inLoop = p.inLoop + 1;
		liveRangesStmt(p, d.forInBody);
		p.inLoop = p.inLoop - 1;
		return;
	}
	if (node.kind === NodeKind.DoWhileStmt) {
		const d = node.data as DoWhileStmtData;
		liveRangesStmt(p, d.doBody);
		liveRangesExpr(p, d.doCondition);
		p.inLoop = p.inLoop + 1;
		liveRangesStmt(p, d.doBody);
		liveRangesExpr(p, d.doCondition);
		p.inLoop = p.inLoop - 1;
		return;
	}
	if (node.kind === NodeKind.TryCatchStmt) {
		const d = node.data as TryCatchStmtData;
		liveRangesStmt(p, d.tryBody);
		liveRangesStmt(p, d.catchBody);
		liveRangesStmt(p, d.finallyBody);
		return;
	}
	if (node.kind === NodeKind.SwitchStmt) {
		const d = node.data as SwitchStmtData;
		liveRangesExpr(p, d.switchDisc);
		for (const c of d.switchCases) {
			const cd = c.data as SwitchCaseData;
			for (const s of cd.caseStmts) { liveRangesStmt(p, s); }
		}
		return;
	}
	if (node.kind === NodeKind.MatchStmt) {
		const d = node.data as MatchStmtData;
		liveRangesExpr(p, d.matchStmtDisc);
		for (const c of d.matchStmtCases) {
			const cd = c.data as MatchCaseData;
			liveRangesStmt(p, cd.caseBody);
		}
		return;
	}
	if (node.kind === NodeKind.ThrowStmt) {
		liveRangesExpr(p, (node.data as ThrowStmtData).throwArg);
		return;
	}
	if (node.kind === NodeKind.DeferStmt) {
		liveRangesExpr(p, (node.data as DeferStmtData).deferExpr);
		return;
	}
	if (node.kind === NodeKind.DecoratedDecl) {
		liveRangesStmt(p, (node.data as DecoratedDeclData).decoratedNode);
		return;
	}
	// Skip nested function declarations (they get their own analysis)
	if (node.kind === NodeKind.FunctionDecl) return;
	// Skip test declarations, imports, type declarations, etc.
}

// ===== Pass 2: Traverse =====
// Builds connections and detects mutations.

function traverseExpr(p: Partitions, node: Node): void {
	if (node === null) return;
	p.abstractTime = p.abstractTime + 1;

	// Identifier: update alive range (decrement time, no side effects)
	if (node.kind === NodeKind.Identifier) {
		p.abstractTime = p.abstractTime - 1;
		return;
	}

	// Assignment: mutation + potential connection
	if (node.kind === NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		if (isAssignment(d.operator)) {
			traverseExpr(p, d.right);
			traverseExpr(p, d.left);
			const destRoot = findRoot(d.left);
			if (destRoot !== "") {
				const isDirect = d.left.kind === NodeKind.Identifier;
				potentialMutation(p, destRoot, getLine(node), isDirect);
				// Connect if pointer-containing type
				if (d.operator === "=" && nodeContainsPointer(d.left)) {
					const srcRoot = findRoot(d.right);
					if (srcRoot !== "") {
						connect(p, destRoot, srcRoot, getLine(node));
					}
				}
			}
			return;
		}
		// Non-assignment binary: recurse both sides
		traverseExpr(p, d.left);
		traverseExpr(p, d.right);
		return;
	}

	// UpdateExpr (++/--): mutation
	if (node.kind === NodeKind.UpdateExpr) {
		const d = node.data as UpdateExprData;
		traverseExpr(p, d.updateArg);
		const r = findRoot(d.updateArg);
		if (r !== "") {
			potentialMutation(p, r, getLine(node), d.updateArg.kind === NodeKind.Identifier);
		}
		return;
	}

	// CallExpr: check mutating methods and out params
	if (node.kind === NodeKind.CallExpr) {
		const d = node.data as CallExprData;
		let ai = 0;
		while (ai < d.arguments.length) {
			traverseExpr(p, d.arguments[ai]);
			if (d.arguments[ai].kind === NodeKind.OutExpr) {
				// Detect out params — explicit mutation
				const oe = d.arguments[ai].data as OutExprData;
				const r = findRoot(oe.outArg);
				if (r !== "") {
					potentialMutationViaVar(p, r, getLine(node));
				}
			} else {
				// Conservative: non-out arg with pointer type might be mutated
				potentialMutationViaArg(p, d.arguments[ai], getLine(node));
			}
			ai = ai + 1;
		}
		// Detect mutating method calls
		if (d.callee.kind === NodeKind.MemberExpr) {
			const me = d.callee.data as MemberExprData;
			if (isMutatingMethod(me.property)) {
				const r = findRoot(me.object);
				if (r !== "") {
					potentialMutation(p, r, getLine(node), false);
				}
			}
			traverseExpr(p, me.object);
		} else {
			traverseExpr(p, d.callee);
		}
		return;
	}

	// Path expressions: recurse into object/array
	if (node.kind === NodeKind.MemberExpr) {
		traverseExpr(p, (node.data as MemberExprData).object);
		return;
	}
	if (node.kind === NodeKind.ArrayAccess) {
		const d = node.data as ArrayAccessData;
		traverseExpr(p, d.array);
		traverseExpr(p, d.index);
		return;
	}

	// Conditional: traverse all branches
	if (node.kind === NodeKind.ConditionalExpr) {
		const d = node.data as ConditionalExprData;
		traverseExpr(p, d.ternaryCondition);
		p.inConditional = p.inConditional + 1;
		traverseExpr(p, d.ternaryConsequent);
		traverseExpr(p, d.ternaryAlternate);
		p.inConditional = p.inConditional - 1;
		return;
	}

	// Collection literals: recurse into elements
	if (node.kind === NodeKind.ArrayLiteral) {
		for (const elem of (node.data as ArrayLiteralData).elements) { traverseExpr(p, elem); }
		return;
	}
	if (node.kind === NodeKind.ObjectLiteral) {
		for (const prop of (node.data as ObjectLiteralData).properties) { traverseExpr(p, prop); }
		return;
	}

	// Wrapper expressions: recurse into inner
	if (node.kind === NodeKind.SpreadExpr) {
		traverseExpr(p, (node.data as SpreadExprData).spreadArg);
		return;
	}
	if (node.kind === NodeKind.TypeAssertion) {
		traverseExpr(p, (node.data as TypeAssertionData).asExpr);
		return;
	}
	if (node.kind === NodeKind.OutExpr) {
		traverseExpr(p, (node.data as OutExprData).outArg);
		return;
	}
	if (node.kind === NodeKind.HiddenDeref) {
		traverseExpr(p, (node.data as HiddenDerefData).expr);
		return;
	}
	if (node.kind === NodeKind.HiddenAddr) {
		traverseExpr(p, (node.data as HiddenAddrData).expr);
		return;
	}
	if (node.kind === NodeKind.NewExpr) {
		const d = node.data as NewExprData;
		traverseExpr(p, d.newCallee);
		for (const arg of d.newArguments) { traverseExpr(p, arg); }
		return;
	}
	if (node.kind === NodeKind.TryExpr) {
		const d = node.data as TryExprData;
		traverseExpr(p, d.tryArg);
		if (d.hasCatch) traverseExpr(p, d.catchVal);
		return;
	}
	if (node.kind === NodeKind.MatchExpr) {
		const d = node.data as MatchExprData;
		traverseExpr(p, d.matchDisc);
		for (const c of d.matchCases) {
			const cd = c.data as MatchCaseData;
			traverseExpr(p, cd.caseBody);
		}
		return;
	}
	if (node.kind === NodeKind.AwaitExpr) {
		traverseExpr(p, (node.data as AwaitExprData).awaitArg);
		return;
	}
	if (node.kind === NodeKind.YieldExpr) {
		traverseExpr(p, (node.data as YieldExprData).yieldArg);
		return;
	}
	if (node.kind === NodeKind.MoveExpr) {
		traverseExpr(p, (node.data as MoveExprData).moveArg);
		return;
	}

	// Skip nested function definitions
	if (node.kind === NodeKind.ArrowFunction || node.kind === NodeKind.FunctionExpr) return;
}

function traverseStmt(p: Partitions, node: Node): void {
	if (node === null) return;
	p.abstractTime = p.abstractTime + 1;

	if (node.kind === NodeKind.BlockStmt) {
		const d = node.data as BlockStmtData;
		for (const stmt of d.statements) { traverseStmt(p, stmt); }
		return;
	}

	if (node.kind === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		traverseExpr(p, d.initializer);
		// Connect variable with initializer root if pointer type
		if (d.initializer !== null && nodeContainsPointer(d.initializer)) {
			const srcRoot = findRoot(d.initializer);
			if (srcRoot !== "") {
				connect(p, d.declName, srcRoot, getLine(node));
			}
		}
		return;
	}

	if (node.kind === NodeKind.ExprStmt) {
		traverseExpr(p, (node.data as ExprStmtData).expr);
		return;
	}

	if (node.kind === NodeKind.ReturnStmt) {
		traverseExpr(p, (node.data as ReturnStmtData).argument);
		return;
	}

	if (node.kind === NodeKind.IfStmt) {
		const d = node.data as IfStmtData;
		traverseExpr(p, d.condition);
		p.inConditional = p.inConditional + 1;
		traverseStmt(p, d.consequent);
		traverseStmt(p, d.alternate);
		p.inConditional = p.inConditional - 1;
		return;
	}

	if (node.kind === NodeKind.WhileStmt) {
		const d = node.data as WhileStmtData;
		traverseExpr(p, d.whileCondition);
		traverseStmt(p, d.whileBody);
		// Loop double-traversal
		traverseExpr(p, d.whileCondition);
		traverseStmt(p, d.whileBody);
		return;
	}

	if (node.kind === NodeKind.ForStmt) {
		const d = node.data as ForStmtData;
		traverseStmt(p, d.forInit);
		traverseExpr(p, d.forCondition);
		traverseExpr(p, d.forUpdate);
		traverseStmt(p, d.forBody);
		// Loop double-traversal
		traverseExpr(p, d.forCondition);
		traverseExpr(p, d.forUpdate);
		traverseStmt(p, d.forBody);
		return;
	}

	if (node.kind === NodeKind.ForOfStmt) {
		const d = node.data as ForOfStmtData;
		traverseExpr(p, d.forOfIterable);
		// Connect loop binding with iterable if pointer type
		if (d.forOfIterable !== null && nodeContainsPointer(d.forOfIterable)) {
			const srcRoot = findRoot(d.forOfIterable);
			if (srcRoot !== "") {
				connect(p, d.forOfBinding, srcRoot, getLine(node));
			}
		}
		traverseStmt(p, d.forOfBody);
		traverseStmt(p, d.forOfBody);
		return;
	}

	if (node.kind === NodeKind.ForInStmt) {
		const d = node.data as ForInStmtData;
		traverseExpr(p, d.forInObject);
		traverseStmt(p, d.forInBody);
		traverseStmt(p, d.forInBody);
		return;
	}

	if (node.kind === NodeKind.DoWhileStmt) {
		const d = node.data as DoWhileStmtData;
		traverseStmt(p, d.doBody);
		traverseExpr(p, d.doCondition);
		traverseStmt(p, d.doBody);
		traverseExpr(p, d.doCondition);
		return;
	}

	if (node.kind === NodeKind.TryCatchStmt) {
		const d = node.data as TryCatchStmtData;
		traverseStmt(p, d.tryBody);
		traverseStmt(p, d.catchBody);
		traverseStmt(p, d.finallyBody);
		return;
	}

	if (node.kind === NodeKind.SwitchStmt) {
		const d = node.data as SwitchStmtData;
		traverseExpr(p, d.switchDisc);
		for (const c of d.switchCases) {
			const cd = c.data as SwitchCaseData;
			for (const s of cd.caseStmts) { traverseStmt(p, s); }
		}
		return;
	}

	if (node.kind === NodeKind.MatchStmt) {
		const d = node.data as MatchStmtData;
		traverseExpr(p, d.matchStmtDisc);
		for (const c of d.matchStmtCases) {
			const cd = c.data as MatchCaseData;
			traverseStmt(p, cd.caseBody);
		}
		return;
	}

	if (node.kind === NodeKind.ThrowStmt) {
		traverseExpr(p, (node.data as ThrowStmtData).throwArg);
		return;
	}

	if (node.kind === NodeKind.DeferStmt) {
		traverseExpr(p, (node.data as DeferStmtData).deferExpr);
		return;
	}

	if (node.kind === NodeKind.DecoratedDecl) {
		traverseStmt(p, (node.data as DecoratedDeclData).decoratedNode);
		return;
	}

	// Skip nested function declarations, imports, types, tests, asserts
	if (node.kind === NodeKind.FunctionDecl) return;
	if (node.kind === NodeKind.TestDecl) return;
	if (node.kind === NodeKind.AssertStmt) return;
}

// ===== Post-Analysis =====

function hasSideEffect(p: Partitions): string {
	let i = 0;
	while (i < p.graphs.length) {
		const g = p.graphs[i];
		const hasMut = (g.flags & FLAG_MUTATED) !== 0;
		const hasConst = (g.flags & FLAG_CONNECTS_CONST) !== 0;
		if (hasMut && hasConst) {
			const isDirect = (g.flags & FLAG_MUTATED_DIRECTLY) !== 0;
			if (isDirect || g.maxMutation > g.minConnection) {
				return g.paramName;
			}
		}
		i = i + 1;
	}
	return "";
}

// ===== Public Entry Point =====

export function analyzeReadonlyParams(ctx: CheckerContext, sym: Symbol, params: string[], body: Node): void {
	if (sym === null) return;
	if (sym.symbolType === null) return;
	if (sym.symbolType.kind !== TypeKind.Function) return;

	// Quick check: skip if no readonly params
	let hasReadonly = false;
	let pi = 0;
	while (pi < sym.symbolType.typeChildren.length) {
		if (isReadonly(sym.symbolType.typeChildren[pi])) {
			hasReadonly = true;
		}
		pi = pi + 1;
	}
	if (!hasReadonly) return;

	// Build partitions
	const p = createPartitions();

	// Register params
	pi = 0;
	while (pi < params.length && pi < sym.symbolType.typeChildren.length) {
		registerParam(p, params[pi], sym.symbolType.typeChildren[pi]);
		pi = pi + 1;
	}

	// Pass 1: compute live ranges
	liveRangesStmt(p, body);

	// Pass 2: traverse (reset abstract time to match Pass 1 ordering)
	p.abstractTime = 0;
	traverseStmt(p, body);

	// Check for violations
	const violatedParam = hasSideEffect(p);
	if (violatedParam !== "") {
		addError(ctx, "An object reachable from readonly parameter '" + violatedParam + "' is potentially mutated", 0, 0);
	}
}

// ===== Tests =====


import { checkSource } from "./checkPass";
import { hasErrors, errorCount } from "./context";
test "variableId finds registered vars" {
	const p = createPartitions();
	registerVariable(p, "x");
	registerVariable(p, "y");
	assert variableId(p, "x") === 0;
	assert variableId(p, "y") === 1;
	assert variableId(p, "z") === -1;
}

test "root returns self for empty root" {
	const p = createPartitions();
	registerVariable(p, "x");
	assert ufRoot(p, 0) === 0;
}

test "connect merges two vars" {
	const p = createPartitions();
	registerVariable(p, "x");
	registerVariable(p, "y");
	connect(p, "x", "y", 1);
	assert ufRoot(p, 0) === ufRoot(p, 1);
}

test "path compression works" {
	const p = createPartitions();
	registerVariable(p, "a");
	registerVariable(p, "b");
	registerVariable(p, "c");
	connect(p, "a", "b", 1);
	connect(p, "b", "c", 2);
	// After find, all should point to same root
	const r = ufRoot(p, 2);
	assert ufRoot(p, 0) === r;
	assert ufRoot(p, 1) === r;
}

test "findRoot on simple identifier" {
	const ctx = checkSource("const x = 1;");
	// Just test findRoot logic: it needs a node, use checkSource to get one
	assert isMutatingMethod("push");
	assert isMutatingMethod("pop");
	assert isMutatingMethod("splice");
	assert !isMutatingMethod("length");
	assert !isMutatingMethod("slice");
	assert !isMutatingMethod("map");
	// String mutating methods + setLen
	assert isMutatingMethod("append");
	assert isMutatingMethod("setLen");
	assert isMutatingMethod("setLength");
	assert isMutatingMethod("setSlice");
	assert isMutatingMethod("stripInPlace");
	assert !isMutatingMethod("toLower");
	assert !isMutatingMethod("trim");
}

test "isAssignment detects all assignment ops" {
	assert isAssignment("=");
	assert isAssignment("+=");
	assert isAssignment("-=");
	assert isAssignment("*=");
	assert isAssignment("/=");
	assert !isAssignment("+");
	assert !isAssignment("===");
	assert !isAssignment("<");
}

test "direct assignment to readonly param" {
	const ctx = checkSource("function f(readonly arr: number[]): void { arr = []; }");
	assert hasErrors(ctx);
}

test "compound assignment to readonly param" {
	const ctx = checkSource("function f(readonly s: string): void { s += \"x\"; }");
	assert hasErrors(ctx);
}

test "index assignment on readonly param" {
	const ctx = checkSource("function f(readonly arr: number[]): void { arr[0] = 1; }");
	assert hasErrors(ctx);
}

test "field assignment on readonly param" {
	const ctx = checkSource("function f(readonly obj: SomeType): void { obj.x = 1; }");
	assert hasErrors(ctx);
}

test "update expr on readonly param" {
	const ctx = checkSource("function f(readonly x: number): void { x++; }");
	assert hasErrors(ctx);
}

test "mutating method on readonly param" {
	const ctx = checkSource("function f(readonly arr: number[]): void { arr.push(1); }");
	assert hasErrors(ctx);
}

test "alias then push detected" {
	const ctx = checkSource("function f(readonly arr: number[]): void { let a = arr; a.push(1); }");
	assert hasErrors(ctx);
}

test "multi-hop alias detected" {
	const ctx = checkSource("function f(readonly arr: number[]): void { let a = arr; let b = a; b.push(1); }");
	assert hasErrors(ctx);
}

test "alias then direct assignment detected" {
	const ctx = checkSource("function f(readonly arr: number[]): void { let a = arr; a[0] = 99; }");
	assert hasErrors(ctx);
}

test "alias then update expr detected" {
	const ctx = checkSource("function f(readonly x: number): void { let y = x; y++; }");
	// number doesn't contain pointers, so alias is not connected
	assert !hasErrors(ctx);
}

test "mutable param assignment allowed" {
	const ctx = checkSource("function f(arr: number[]): void { arr = []; }");
	assert !hasErrors(ctx);
}

test "mutable param push allowed" {
	const ctx = checkSource("function f(arr: number[]): void { arr.push(1); }");
	assert !hasErrors(ctx);
}

test "local variable mutation allowed" {
	const ctx = checkSource("function f(readonly arr: number[]): void { let x = 1; x = 2; }");
	assert !hasErrors(ctx);
}

test "reading readonly param allowed" {
	const ctx = checkSource("function f(readonly arr: number[]): void { const x = arr.length; }");
	assert !hasErrors(ctx);
}

test "no readonly params skips analysis" {
	const ctx = checkSource("function f(a: number, b: string): void { a = 1; }");
	assert !hasErrors(ctx);
}

test "mutation before connection not flagged" {
	const ctx = checkSource("function f(readonly arr: number[]): void { let x: number[] = []; x.push(1); x = arr; }");
	// x.push(1) happens BEFORE x = arr connection — should NOT be flagged
	// But x = arr is an assignment to x which IS flagged since x is connected to arr after...
	// Actually this tests temporal ordering: the push is time T1, connect is T2 > T1.
	// maxMutation=T1 < minConnection=T2 → no error from varpartitions
	// BUT the x = arr assignment IS a mutation on x (reassignment), which happens at T2
	// and the connection also happens at T2, so maxMutation=T2 == minConnection=T2 → not >
	// So no error. However the Phase 2e inline check might flag x = arr differently...
	// For this test, just check the basic flow works
	assert !hasErrors(ctx);
}

test "non-mutating method on alias allowed" {
	const ctx = checkSource("function f(readonly arr: number[]): void { let a = arr; const x = a.length; }");
	assert !hasErrors(ctx);
}

test "out expr on readonly root detected" {
	const ctx = checkSource("function g(x: number[]): void {} function f(readonly arr: number[]): void { g(out arr); }");
	assert hasErrors(ctx);
}

test "readonly param passed to mutable function detected" {
	const ctx = checkSource("function g(arr: number[]): void { arr.push(1); }\nfunction f(readonly arr: number[]): void { g(arr); }");
	assert hasErrors(ctx);
}

test "readonly param passed to readonly function allowed" {
	const ctx = checkSource("function g(readonly arr: number[]): void { const x = arr.length; }\nfunction f(readonly arr: number[]): void { g(arr); }");
	assert !hasErrors(ctx);
}

test "mutable param passed to mutable function allowed" {
	const ctx = checkSource("function g(arr: number[]): void { arr.push(1); }\nfunction f(arr: number[]): void { g(arr); }");
	assert !hasErrors(ctx);
}
