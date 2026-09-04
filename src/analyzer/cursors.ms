// Cursor Inference — Steensgaard's union-find algorithm (reference parity)
//
// Two-pass analysis before DRC injection:
//   Pass 1 (computeLiveRanges): collect variables, track alive ranges, mark reassigned
//   Pass 2 (traverse): build variable graphs via union-find, track mutations
//
// A "cursor" is a variable that:
//   - Does not own data (initialized from borrow, not constructor/call)
//   - Is not explicitly prevented (not addr-taken, not passed to mutable param)
//   - Is not conditionally reassigned in a loop
//   - Its graph is not mutated during its lifetime (dangerousMutation check)
//
// Safety: conservative — false negatives are fine (treated as owned),
// false positives would be unsound (dangling pointer).

import {
	Node, NodeKind,
	VariableDeclData, IdentifierData, MemberExprData, ArrayAccessData,
	BlockStmtData, ExprStmtData, ReturnStmtData, IfStmtData,
	WhileStmtData, ForStmtData, DoWhileStmtData,
	TryCatchStmtData, CallExprData, BinaryExprData,
	ObjectLiteralData, ArrayLiteralData, ConditionalExprData,
	ThrowStmtData, SwitchStmtData, SwitchCaseData,
	FunctionDeclData,
	MoveExprData, SpreadExprData, NewExprData,
	ExportDeclData, ProgramData,
	TypeAssertionData, HiddenStdConvData,
} from "../ast/node";
import { forEachChild } from "../ast/visitor";
import { parseInput } from "../transform/testUtil";

// ===== Constants =====

const MAX_TIME: int32 = 999999;
const MIN_TIME: int32 = -1;

// ===== VarFlag (per-variable analysis flags) =====

const VF_OWNS_DATA: int32 = 1;
const VF_PREVENT_CURSOR: int32 = 2;
const VF_IS_REASSIGNED: int32 = 4;
const VF_IS_COND_REASSIGNED: int32 = 8;
const VF_IS_PARAM: int32 = 16;

// ===== SubgraphFlag =====

const SF_IS_MUTATED: int32 = 1;

// ===== Connection Kind =====

const CK_EMPTY_ROOT: int32 = 0;
const CK_DEPENDS_ON: int32 = 1;
const CK_ROOT_OF: int32 = 2;

// ===== Data Structures =====

interface Connection {
	kind: int32;
	target: int32; // parent index for DependsOn, graph index for RootOf
}

interface VarEntry {
	name: string;
	con: Connection;
	flags: int32;
	reassignedTo: string; // single source name ("" = none or multiple)
	aliveStart: int32;
	aliveEnd: int32;
}

interface MutationInfo {
	flags: int32;
	maxMutation: int32;
	minConnection: int32;
	mutations: int32[];
}

interface Partitions {
	abstractTime: int32;
	vars: VarEntry[];
	graphs: MutationInfo[];
	inConstructor: int32;
	inConditional: int32;
	inLoop: int32;
	inAsgnSource: int32;
}

function createPartitions(): Partitions {
	return {
		abstractTime: 0, vars: [], graphs: [],
		inConstructor: 0, inConditional: 0, inLoop: 0, inAsgnSource: 0,
	};
}

// ===== Variable Lookup =====

function variableId(p: Partitions, name: string): int32 {
	let i = 0;
	while (i < p.vars.length) {
		if (p.vars[i].name === name) return i;
		i += 1;
	}
	return -1;
}

function registerVariable(p: Partitions, name: string, isParam: boolean): void {
	if (variableId(p, name) >= 0) return;
	p.vars.push({
		name,
		con: { kind: CK_EMPTY_ROOT, target: 0 },
		flags: isParam ? VF_IS_PARAM : (0 as int32),
		reassignedTo: "",
		// Params: alive for full function. Locals: start at declaration time.
		aliveStart: isParam ? 0 : p.abstractTime,
		aliveEnd: isParam ? MAX_TIME : p.abstractTime,
	});
}

// ===== Union-Find with Path Compression =====

function ufRoot(p: Partitions, start: int32): int32 {
	let r = start;
	let depth = 0;
	while (p.vars[r].con.kind === CK_DEPENDS_ON) {
		r = p.vars[r].con.target;
		depth += 1;
	}
	if (depth > 0) {
		let it = start;
		while (p.vars[it].con.kind === CK_DEPENDS_ON) {
			const next = p.vars[it].con.target;
			p.vars[it].con = { kind: CK_DEPENDS_ON, target: r };
			it = next;
		}
	}
	return r;
}

function ufConnect(p: Partitions, aName: string, bName: string): void {
	const aid = variableId(p, aName);
	if (aid < 0) return;
	const bid = variableId(p, bName);
	if (bid < 0) return;

	const ra = ufRoot(p, aid);
	const rb = ufRoot(p, bid);
	if (ra === rb) return;

	// Collect rb's graph info before merging
	let rbFlags: int32 = 0;
	let rbMut: int32 = 0;
	let rbCon: int32 = p.abstractTime;
	let rbMutations: int32[] = [];
	if (p.vars[rb].con.kind === CK_ROOT_OF) {
		const gb = p.graphs[p.vars[rb].con.target];
		rbFlags = gb.flags;
		rbMut = gb.maxMutation;
		if (gb.minConnection < rbCon) rbCon = gb.minConnection;
		rbMutations = gb.mutations;
	}

	// Make rb depend on ra
	p.vars[rb].con = { kind: CK_DEPENDS_ON, target: ra };

	if (p.vars[ra].con.kind === CK_EMPTY_ROOT) {
		// ra becomes root of a new graph
		p.vars[ra].con = { kind: CK_ROOT_OF, target: p.graphs.length };
		const muts: int32[] = [];
		for (const m of rbMutations) { muts.push(m); }
		p.graphs.push({
			flags: rbFlags, maxMutation: rbMut,
			minConnection: rbCon, mutations: muts,
		});
	} else if (p.vars[ra].con.kind === CK_ROOT_OF) {
		// Merge rb's info into ra's graph
		const ga = p.graphs[p.vars[ra].con.target];
		if (rbCon < ga.minConnection) ga.minConnection = rbCon;
		ga.flags = ga.flags | rbFlags;
		for (const m of rbMutations) { ga.mutations.push(m); }
	}
}

// ===== Mutation Tracking =====

function potentialMutation(p: Partitions, name: string): void {
	const id = variableId(p, name);
	if (id < 0) return;
	if (p.abstractTime > p.vars[id].aliveEnd) p.vars[id].aliveEnd = p.abstractTime;

	const r = ufRoot(p, id);
	if (p.vars[r].con.kind === CK_EMPTY_ROOT) {
		p.vars[r].con = { kind: CK_ROOT_OF, target: p.graphs.length };
		p.graphs.push({
			flags: SF_IS_MUTATED, maxMutation: p.abstractTime,
			minConnection: MAX_TIME, mutations: [p.abstractTime],
		});
	} else if (p.vars[r].con.kind === CK_ROOT_OF) {
		const g = p.graphs[p.vars[r].con.target];
		if (p.abstractTime > g.maxMutation) g.maxMutation = p.abstractTime;
		g.flags = g.flags | SF_IS_MUTATED;
		g.mutations.push(p.abstractTime);
	}
}

function dangerousMutation(g: MutationInfo, v: VarEntry): boolean {
	if ((g.flags & SF_IS_MUTATED) === 0) return false;
	for (const m of g.mutations) {
		if (m >= v.aliveStart && m <= v.aliveEnd) return true;
	}
	return false;
}

// ===== Helpers =====

function getIdentName(node: Node): string {
	if (node === null) return "";
	if (node.kind === NodeKind.Identifier) return (node.data as IdentifierData).name;
	return "";
}

// Find root identifiers in a path expression (e.g., obj.field → "obj")
function collectPathRoots(node: Node, result: string[]): void {
	if (node === null) return;
	match (node.kind) {
		NodeKind.Identifier => { result.push((node.data as IdentifierData).name); },
		NodeKind.MemberExpr => collectPathRoots((node.data as MemberExprData).object, result),
		NodeKind.ArrayAccess => collectPathRoots((node.data as ArrayAccessData).array, result),
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => collectPathRoots((node.data as { expr: Node }).expr, result),
		_ => {},
	};
}

// ===== destMightOwn — determines if dest OWNS data from src =====
// If dest owns → marked ownsData → cannot be cursor.
// If dest borrows → connected via union-find → cursor candidate.

function destMightOwn(p: Partitions, destIdx: int32, src: Node): void {
	if (src === null) return;

	match (src.kind) {
		// Literals: harmless, no ownership
		NodeKind.NumberLiteral | NodeKind.StringLiteral | NodeKind.BooleanLiteral
		| NodeKind.NullLiteral | NodeKind.BigIntLiteral | NodeKind.RegexLiteral => {},

		// Conversions: recurse into inner expression
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => {
			destMightOwn(p, destIdx, (src.data as HiddenStdConvData).convExpr);
		},
		NodeKind.TypeAssertion => {
			destMightOwn(p, destIdx, (src.data as TypeAssertionData).asExpr);
		},

		// Identifier: just a dependency (connect), unless in constructor context
		NodeKind.Identifier => {
			const name = (src.data as IdentifierData).name;
			const srcId = variableId(p, name);
			if (srcId < 0) {
				// Unknown variable (module-level, imported) — unsafe to alias
				p.vars[destIdx].flags = p.vars[destIdx].flags | VF_OWNS_DATA;
			} else {
				ufConnect(p, p.vars[destIdx].name, name);
				// [x] or {field: x} context — container owns a copy
				if (p.inConstructor > 0) {
					p.vars[destIdx].flags = p.vars[destIdx].flags | VF_OWNS_DATA;
				}
			}
		},

		// Field/array/deref access: recurse into base (borrowing)
		NodeKind.MemberExpr => destMightOwn(p, destIdx, (src.data as MemberExprData).object),
		NodeKind.ArrayAccess => destMightOwn(p, destIdx, (src.data as ArrayAccessData).array),
		NodeKind.HiddenDeref => destMightOwn(p, destIdx, (src.data as { expr: Node }).expr),
		NodeKind.HiddenAddr => destMightOwn(p, destIdx, (src.data as { expr: Node }).expr),

		// Conditional branches: recurse with inConditional flag
		NodeKind.ConditionalExpr => {
			const d = src.data as ConditionalExprData;
			p.inConditional += 1;
			destMightOwn(p, destIdx, d.ternaryConsequent);
			destMightOwn(p, destIdx, d.ternaryAlternate);
			p.inConditional -= 1;
		},

		// Object/array constructors: dest owns data
		NodeKind.ObjectLiteral => {
			const d = src.data as ObjectLiteralData;
			p.inConstructor += 1;
			for (const prop of d.properties) { destMightOwn(p, destIdx, prop); }
			p.inConstructor -= 1;
			p.vars[destIdx].flags = p.vars[destIdx].flags | VF_OWNS_DATA;
		},
		NodeKind.ArrayLiteral => {
			const d = src.data as ArrayLiteralData;
			p.inConstructor += 1;
			for (const elem of d.elements) { destMightOwn(p, destIdx, elem); }
			p.inConstructor -= 1;
			p.vars[destIdx].flags = p.vars[destIdx].flags | VF_OWNS_DATA;
		},

		// Closures: dest owns data
		NodeKind.ArrowFunction | NodeKind.FunctionExpr => {
			p.vars[destIdx].flags = p.vars[destIdx].flags | VF_OWNS_DATA;
		},

		// Calls: return value is constructed → dest owns data
		NodeKind.CallExpr | NodeKind.NewExpr => {
			p.vars[destIdx].flags = p.vars[destIdx].flags | VF_OWNS_DATA;
		},

		// Move: explicit ownership transfer
		NodeKind.MoveExpr => {
			p.vars[destIdx].flags = p.vars[destIdx].flags | VF_OWNS_DATA;
		},

		// Spread: dest owns
		NodeKind.SpreadExpr => {
			p.vars[destIdx].flags = p.vars[destIdx].flags | VF_OWNS_DATA;
		},

		// Anything else: conservative — prevent cursor
		_ => {
			p.vars[destIdx].flags = p.vars[destIdx].flags | VF_PREVENT_CURSOR;
		},
	};
}

// ===== Pass 1: computeLiveRanges =====
// Walk AST to register variables and compute alive ranges.
// Must traverse in the same order as pass 2 for consistent abstractTime.

function markReassigned(p: Partitions, vid: int32): void {
	p.vars[vid].flags = p.vars[vid].flags | VF_IS_REASSIGNED;
	if (p.inConditional > 0 && p.inLoop > 0) {
		p.vars[vid].flags = p.vars[vid].flags | VF_IS_COND_REASSIGNED;
	}
}

function liveRanges(p: Partitions, node: Node | null): void {
	if (node === null) return;
	p.abstractTime += 1;

	match (node.kind) {
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			liveRanges(p, d.initializer);
			registerVariable(p, d.declName, false);
			// Declared in loop body → effectively reassigned each iteration
			if (p.inLoop > 0 && d.initializer !== null) {
				const vid = variableId(p, d.declName);
				if (vid >= 0) markReassigned(p, vid);
			}
		},

		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			liveRanges(p, d.left);
			liveRanges(p, d.right);
			if (d.operator === "=") {
				const lhs = getIdentName(d.left);
				if (lhs !== "") {
					const vid = variableId(p, lhs);
					if (vid >= 0) {
						// Track single reassignment source (for it = it.next pattern)
						const rhs = getIdentName(d.right);
						if (rhs !== "" && (p.vars[vid].reassignedTo === "" || p.vars[vid].reassignedTo === rhs)) {
							p.vars[vid].reassignedTo = rhs;
							if (p.inConditional > 0 && p.inLoop > 0) {
								p.vars[vid].flags = p.vars[vid].flags | VF_IS_COND_REASSIGNED;
							}
						} else {
							markReassigned(p, vid);
						}
					}
				}
			}
		},

		NodeKind.Identifier => {
			p.abstractTime -= 1; // Symbols don't advance time
			const name = (node.data as IdentifierData).name;
			// Auto-register referenced variables not yet seen (params, outer scope).
			// Treat as "external" — alive for the full function, never a cursor candidate.
			if (variableId(p, name) < 0) {
				registerVariable(p, name, true);
			}
			const id = variableId(p, name);
			if (id >= 0) {
				if (p.abstractTime > p.vars[id].aliveEnd) p.vars[id].aliveEnd = p.abstractTime;
				if (p.abstractTime < p.vars[id].aliveStart) p.vars[id].aliveStart = p.abstractTime;
			}
		},

		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			liveRanges(p, d.callee);
			for (const arg of d.arguments) { liveRanges(p, arg); }
		},

		// Loops: traverse twice for soundness (mutation after borrow in same loop iteration)
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			liveRanges(p, d.whileCondition);
			liveRanges(p, d.whileBody);
			p.inLoop += 1;
			liveRanges(p, d.whileCondition);
			liveRanges(p, d.whileBody);
			p.inLoop -= 1;
			liveRanges(p, d.whileCondition); // condition alive longer than body
		},
		NodeKind.ForStmt => {
			const d = node.data as ForStmtData;
			liveRanges(p, d.forInit);
			liveRanges(p, d.forCondition);
			liveRanges(p, d.forUpdate);
			liveRanges(p, d.forBody);
			p.inLoop += 1;
			liveRanges(p, d.forInit);
			liveRanges(p, d.forCondition);
			liveRanges(p, d.forUpdate);
			liveRanges(p, d.forBody);
			p.inLoop -= 1;
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			liveRanges(p, d.doBody);
			liveRanges(p, d.doCondition);
			p.inLoop += 1;
			liveRanges(p, d.doBody);
			liveRanges(p, d.doCondition);
			p.inLoop -= 1;
		},

		// Conditionals
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			liveRanges(p, d.condition);
			p.inConditional += 1;
			liveRanges(p, d.consequent);
			liveRanges(p, d.alternate);
			p.inConditional -= 1;
		},
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			liveRanges(p, d.switchDisc);
			p.inConditional += 1;
			for (const c of d.switchCases) { liveRanges(p, c); }
			p.inConditional -= 1;
		},
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			liveRanges(p, d.ternaryCondition);
			p.inConditional += 1;
			liveRanges(p, d.ternaryConsequent);
			liveRanges(p, d.ternaryAlternate);
			p.inConditional -= 1;
		},

		// Inner functions: skip (different scope)
		NodeKind.FunctionDecl | NodeKind.ArrowFunction | NodeKind.FunctionExpr => {
			p.abstractTime -= 1;
		},

		// Compound traversal
		NodeKind.BlockStmt => {
			for (const s of (node.data as BlockStmtData).statements) { liveRanges(p, s); }
		},
		NodeKind.ExprStmt => liveRanges(p, (node.data as ExprStmtData).expr),
		NodeKind.ReturnStmt => liveRanges(p, (node.data as ReturnStmtData).argument),
		NodeKind.ThrowStmt => liveRanges(p, (node.data as ThrowStmtData).throwArg),
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			liveRanges(p, d.tryBody);
			liveRanges(p, d.catchBody);
			liveRanges(p, d.finallyBody);
		},
		NodeKind.SwitchCase => {
			const d = node.data as SwitchCaseData;
			for (const t of d.caseTests) { liveRanges(p, t); }
			for (const s of d.caseStmts) { liveRanges(p, s); }
		},
		NodeKind.MemberExpr => liveRanges(p, (node.data as MemberExprData).object),
		NodeKind.ArrayAccess => {
			const d = node.data as ArrayAccessData;
			liveRanges(p, d.array);
			liveRanges(p, d.index);
		},
		NodeKind.ObjectLiteral => {
			for (const prop of (node.data as ObjectLiteralData).properties) { liveRanges(p, prop); }
		},
		NodeKind.ArrayLiteral => {
			for (const elem of (node.data as ArrayLiteralData).elements) { liveRanges(p, elem); }
		},
		NodeKind.UnaryExpr => liveRanges(p, (node.data as { unaryOp: string, operand: Node }).operand),
		NodeKind.SpreadExpr => liveRanges(p, (node.data as SpreadExprData).spreadArg),
		NodeKind.MoveExpr => liveRanges(p, (node.data as MoveExprData).moveArg),
		NodeKind.NewExpr => {
			const d = node.data as NewExprData;
			liveRanges(p, d.newCallee);
			for (const a of d.newArguments) { liveRanges(p, a); }
		},
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => {
			liveRanges(p, (node.data as HiddenStdConvData).convExpr);
		},
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => {
			liveRanges(p, (node.data as { expr: Node }).expr);
		},
		NodeKind.TypeAssertion => {
			liveRanges(p, (node.data as TypeAssertionData).asExpr);
		},
		NodeKind.ExportDecl => {
			liveRanges(p, (node.data as ExportDeclData).exportedDecl);
		},
		// Default: descend via canonical walker so live ranges of variables
		// referenced inside unknown kinds (future expr/stmt forms) are still
		// tracked. Inner function bodies are explicitly handled above and
		// terminate recursion — forEachChild will still hand them to us, but
		// the match routes them to the skip branch on re-entry.
		_ => { forEachChild(node, (child: Node): void => { liveRanges(p, child); }); },
	};
}

// ===== Pass 2: traverse (build graphs) =====

function deps(p: Partitions, destName: string, src: Node): void {
	const destId = variableId(p, destName);
	if (destId < 0) return;
	if (src === null) return;

	// Classify: does dest own data or borrow?
	destMightOwn(p, destId, src);

	// Source checks: prevent cursor when borrowing from unsafe sources
	const srcRoots: string[] = [];
	collectPathRoots(src, srcRoots);
	for (const srcName of srcRoots) {
		if (srcName === destName) continue; // self-assign ok (it = it.next)
		const srcId = variableId(p, srcName);
		if (srcId >= 0) {
			// Source lives shorter than dest → can't borrow
			if ((p.vars[srcId].flags & VF_IS_PARAM) === 0 &&
				p.vars[srcId].aliveEnd < p.vars[destId].aliveEnd) {
				p.vars[destId].flags = p.vars[destId].flags | VF_PREVENT_CURSOR;
			}
			// Source is reassigned or prevented → can't borrow
			if ((p.vars[srcId].flags & (VF_IS_REASSIGNED | VF_PREVENT_CURSOR)) !== 0) {
				p.vars[destId].flags = p.vars[destId].flags | VF_PREVENT_CURSOR;
			}
			// Source reassigned to different target → can't borrow
			if (p.vars[srcId].reassignedTo !== "" && p.vars[srcId].reassignedTo !== destName) {
				p.vars[destId].flags = p.vars[destId].flags | VF_PREVENT_CURSOR;
			}
		}
	}
}

function trav(p: Partitions, node: Node | null): void {
	if (node === null) return;
	p.abstractTime += 1;

	match (node.kind) {
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			// Initializer is an assignment source (for pretendOwnsData on [x], {x})
			p.inAsgnSource += 1;
			trav(p, d.initializer);
			p.inAsgnSource -= 1;
			deps(p, d.declName, d.initializer);
		},

		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			trav(p, d.left);
			if (d.operator === "=") {
				p.inAsgnSource += 1;
				trav(p, d.right);
				p.inAsgnSource -= 1;

				// Assignment to variable → mutation on LHS graph
				const lhsRoots: string[] = [];
				collectPathRoots(d.left, lhsRoots);
				for (const r of lhsRoots) { potentialMutation(p, r); }

				// Cursor deps for assignment
				const lhs = getIdentName(d.left);
				if (lhs !== "") deps(p, lhs, d.right);
			} else {
				trav(p, d.right);
			}
		},

		NodeKind.Identifier => {
			p.abstractTime -= 1;
		},

		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			trav(p, d.callee);
			for (const arg of d.arguments) { trav(p, arg); }

			// Method call (obj.method(...)) → obj is potentially mutated
			if (d.callee !== null && d.callee.kind === NodeKind.MemberExpr) {
				const objRoots: string[] = [];
				collectPathRoots((d.callee.data as MemberExprData).object, objRoots);
				for (const r of objRoots) { potentialMutation(p, r); }
			}

			// HiddenAddr arguments → callee receives mutable pointer (var param)
			for (const arg of d.arguments) {
				if (arg !== null && arg.kind === NodeKind.HiddenAddr) {
					const addrRoots: string[] = [];
					collectPathRoots((arg.data as { expr: Node }).expr, addrRoots);
					for (const r of addrRoots) {
						potentialMutation(p, r);
						// Also prevent cursor on the variable itself
						const vid = variableId(p, r);
						if (vid >= 0) {
							p.vars[vid].flags = p.vars[vid].flags | VF_PREVENT_CURSOR;
						}
					}
				}
			}
		},

		// Loops: double traverse for soundness
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			trav(p, d.whileCondition);
			trav(p, d.whileBody);
			trav(p, d.whileCondition);
			trav(p, d.whileBody);
			trav(p, d.whileCondition);
		},
		NodeKind.ForStmt => {
			const d = node.data as ForStmtData;
			trav(p, d.forInit);
			trav(p, d.forCondition);
			trav(p, d.forUpdate);
			trav(p, d.forBody);
			trav(p, d.forInit);
			trav(p, d.forCondition);
			trav(p, d.forUpdate);
			trav(p, d.forBody);
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			trav(p, d.doBody);
			trav(p, d.doCondition);
			trav(p, d.doBody);
			trav(p, d.doCondition);
		},

		// Object/array in assignment source → elements pretend to own data
		NodeKind.ArrayLiteral => {
			const d = node.data as ArrayLiteralData;
			for (const elem of d.elements) { trav(p, elem); }
			if (p.inAsgnSource > 0) {
				for (const elem of d.elements) {
					const eName = getIdentName(elem);
					if (eName !== "") {
						const eid = variableId(p, eName);
						if (eid >= 0) p.vars[eid].flags = p.vars[eid].flags | VF_OWNS_DATA;
					}
				}
			}
		},
		NodeKind.ObjectLiteral => {
			const d = node.data as ObjectLiteralData;
			for (const prop of d.properties) { trav(p, prop); }
			if (p.inAsgnSource > 0) {
				for (const prop of d.properties) {
					const pName = getIdentName(prop);
					if (pName !== "") {
						const pid = variableId(p, pName);
						if (pid >= 0) p.vars[pid].flags = p.vars[pid].flags | VF_OWNS_DATA;
					}
				}
			}
		},

		// Move prevents cursoring of source
		NodeKind.MoveExpr => {
			trav(p, (node.data as MoveExprData).moveArg);
			const moveName = getIdentName((node.data as MoveExprData).moveArg);
			if (moveName !== "") {
				const mid = variableId(p, moveName);
				if (mid >= 0) p.vars[mid].flags = p.vars[mid].flags | VF_PREVENT_CURSOR;
			}
		},

		// Inner functions: skip
		NodeKind.FunctionDecl | NodeKind.ArrowFunction | NodeKind.FunctionExpr => {
			p.abstractTime -= 1;
		},

		// Compound traversal (must match liveRanges order exactly)
		NodeKind.BlockStmt => {
			for (const s of (node.data as BlockStmtData).statements) { trav(p, s); }
		},
		NodeKind.ExprStmt => trav(p, (node.data as ExprStmtData).expr),
		NodeKind.ReturnStmt => trav(p, (node.data as ReturnStmtData).argument),
		NodeKind.ThrowStmt => trav(p, (node.data as ThrowStmtData).throwArg),
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			trav(p, d.tryBody);
			trav(p, d.catchBody);
			trav(p, d.finallyBody);
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			trav(p, d.condition);
			trav(p, d.consequent);
			trav(p, d.alternate);
		},
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			trav(p, d.switchDisc);
			for (const c of d.switchCases) { trav(p, c); }
		},
		NodeKind.SwitchCase => {
			const d = node.data as SwitchCaseData;
			for (const t of d.caseTests) { trav(p, t); }
			for (const s of d.caseStmts) { trav(p, s); }
		},
		NodeKind.MemberExpr => trav(p, (node.data as MemberExprData).object),
		NodeKind.ArrayAccess => {
			const d = node.data as ArrayAccessData;
			trav(p, d.array);
			trav(p, d.index);
		},
		NodeKind.UnaryExpr => trav(p, (node.data as { unaryOp: string, operand: Node }).operand),
		NodeKind.SpreadExpr => trav(p, (node.data as SpreadExprData).spreadArg),
		NodeKind.NewExpr => {
			const d = node.data as NewExprData;
			trav(p, d.newCallee);
			for (const a of d.newArguments) { trav(p, a); }
		},
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => {
			trav(p, (node.data as HiddenStdConvData).convExpr);
		},
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => {
			trav(p, (node.data as { expr: Node }).expr);
		},
		NodeKind.TypeAssertion => {
			trav(p, (node.data as TypeAssertionData).asExpr);
		},
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			trav(p, d.ternaryCondition);
			trav(p, d.ternaryConsequent);
			trav(p, d.ternaryAlternate);
		},
		NodeKind.ExportDecl => {
			trav(p, (node.data as ExportDeclData).exportedDecl);
		},
		// Default: descend via canonical walker so graph edges are built for
		// variables referenced inside unknown kinds. Keeps cursor inference
		// conservative: any use we miss defaults to "not a cursor" (owned),
		// which is always safe. Inner functions re-enter the match above and
		// hit the explicit skip branch.
		_ => { forEachChild(node, (child: Node): void => { trav(p, child); }); },
	};
}

// ===== Cursor Decision =====

function computeCursorDecisions(p: Partitions): CursorSet {
	const result: string[] = [];
	let i = 0;
	while (i < p.vars.length) {
		const v = p.vars[i];
		// Skip params (handled separately in inject.ms)
		if ((v.flags & VF_IS_PARAM) !== 0) { i += 1; continue; }
		// Skip DRC-generated temps
		if (v.name.startsWith("$")) { i += 1; continue; }
		// Must not own data, be prevented, or be conditionally reassigned
		if ((v.flags & (VF_OWNS_DATA | VF_PREVENT_CURSOR | VF_IS_COND_REASSIGNED)) !== 0) {
			i += 1; continue;
		}
		// Reassigned variables can't be cursors
		if ((v.flags & VF_IS_REASSIGNED) !== 0) { i += 1; continue; }

		// Check graph for dangerous mutation during cursor's lifetime
		const r = ufRoot(p, i);
		if (p.vars[r].con.kind === CK_ROOT_OF) {
			const g = p.graphs[p.vars[r].con.target];
			if (dangerousMutation(g, v)) { i += 1; continue; }
		}

		result.push(v.name);
		i += 1;
	}
	return result;
}

// ===== Public API =====

export type CursorSet = string[];

export function createCursorSet(): CursorSet {
	return [];
}

export function isCursorVar(cs: CursorSet, varName: string): boolean {
	for (const n of cs) {
		if (n === varName) return true;
	}
	return false;
}

// Main entry point — called once per function body, before DRC injection.
export function inferCursors(body: Node): CursorSet {
	if (body === null) return createCursorSet();
	if (body.kind !== NodeKind.BlockStmt) return createCursorSet();

	const p = createPartitions();

	// Pass 1: compute live ranges and register variables
	liveRanges(p, body);

	// Reset time for pass 2 (consistent abstractTime required)
	p.abstractTime = 0;

	// Pass 2: build union-find graphs and track mutations
	trav(p, body);

	// Decision: which variables can safely be cursors?
	return computeCursorDecisions(p);
}

// ===== Tests =====

function getStmts(input: string): Node[] {
	const result = parseInput(input);
	if (!result.ok) return [];
	const prog = result.value;
	const d = prog.data as ProgramData;
	return d.programStmts;
}

function getFuncBody(input: string): Node {
	const stmts = getStmts(input);
	if (stmts.length === 0) return null as unknown as Node;
	const stmt = stmts[0];
	if (stmt.kind === NodeKind.FunctionDecl) {
		return (stmt.data as FunctionDeclData).fnBody;
	}
	return null as unknown as Node;
}

// --- Retained tests (adapted for union-find) ---

test "local read-only borrow is cursor" {
	const body = getFuncBody("function f(arr: string[]) { const x = arr.length; }");
	const cs = inferCursors(body);
	assert isCursorVar(cs, "x");
}

test "returned variable is cursor (return copies, safe)" {
	// With union-find: x borrows from arr, no ownership, no mutation.
	// DRC handles return via copy (isLastReadSafe returns false for cursors).
	const body = getFuncBody("function f(arr: string[]) { const x = arr[0]; return x; }");
	const cs = inferCursors(body);
	assert isCursorVar(cs, "x");
}

test "call argument is cursor (call copies, safe)" {
	// x borrows from arr[0]. Passing to call: inject.ms copies (incref).
	// No mutation on arr's graph → cursor is safe.
	const body = getFuncBody("function f(arr: string[]) { const x = arr[0]; process(x); }");
	const cs = inferCursors(body);
	assert isCursorVar(cs, "x");
}

test "assigned to another var: source is cursor, dest connects" {
	// x borrows from arr[0]. y = x → y connects to x's graph.
	// Both can be cursors if neither owns data.
	const body = getFuncBody("function f(arr: string[]) { const x = arr[0]; const y = x; }");
	const cs = inferCursors(body);
	assert isCursorVar(cs, "x");
	assert isCursorVar(cs, "y");
}

test "let variable without reassignment is cursor" {
	// let is fine if never reassigned — union-find tracks reassignment, not declKind.
	const body = getFuncBody("function f(arr: string[]) { let x = arr[0]; }");
	const cs = inferCursors(body);
	assert isCursorVar(cs, "x");
}

test "index-write through alias is not cursor even when alias is never read" {
	const body = getFuncBody("function f() { const vn: Vec<number> = [1, 2]; const cn = vn; cn[0] = 7; console.log(vn[0]); }");
	const cs = inferCursors(body);
	assert !isCursorVar(cs, "cn");
}

test "call result is NOT cursor (owns data)" {
	const body = getFuncBody("function f() { const x = getValue(); }");
	const cs = inferCursors(body);
	assert !isCursorVar(cs, "x");
}

test "member access with only read use is cursor" {
	const body = getFuncBody("function f(obj: { name: string }) { const name = obj.name; if (name) {} }");
	const cs = inferCursors(body);
	assert isCursorVar(cs, "name");
}

test "thrown variable is cursor (throw copies, safe)" {
	const body = getFuncBody("function f(arr: string[]) { const x = arr[0]; throw x; }");
	const cs = inferCursors(body);
	assert isCursorVar(cs, "x");
}

test "stored in object is NOT cursor (constructor context)" {
	const body = getFuncBody("function f(arr: string[]) { const x = arr[0]; const obj = { val: x }; }");
	const cs = inferCursors(body);
	// x appears in ObjectLiteral — pretendOwnsData in inAsgnSource context
	// obj owns data (ObjectLiteral constructor), x gets ownsData via constructor context
	assert !isCursorVar(cs, "x");
}

test "DRC temp is not cursor" {
	const body = getFuncBody("function f(arr: string[]) { const $result = arr[0]; }");
	const cs = inferCursors(body);
	assert !isCursorVar(cs, "$result");
}

test "nested block cursor" {
	const body = getFuncBody("function f(obj: { name: string }) { if (true) { const x = obj.name; } }");
	const cs = inferCursors(body);
	assert isCursorVar(cs, "x");
}

// --- New tests for union-find-specific features ---

test "source mutated during cursor lifetime: NOT cursor" {
	// x borrows from arr[0]. arr.push() mutates arr while x is alive → dangerousMutation.
	const body = getFuncBody("function f(arr: string[]) { const x = arr[0]; arr.push(\"new\"); process(x); }");
	const cs = inferCursors(body);
	assert !isCursorVar(cs, "x");
}

test "source mutated BEFORE cursor: IS cursor" {
	// arr.push() happens before x borrows → mutation not in cursor lifetime.
	const body = getFuncBody("function f(arr: string[]) { arr.push(\"new\"); const x = arr[0]; process(x); }");
	const cs = inferCursors(body);
	assert isCursorVar(cs, "x");
}

test "let reassigned variable is NOT cursor" {
	const body = getFuncBody("function f(arr: string[]) { let x = arr[0]; x = arr[1]; }");
	const cs = inferCursors(body);
	assert !isCursorVar(cs, "x");
}

test "new expression result is NOT cursor" {
	const body = getFuncBody("function f() { const x = new Foo(); }");
	const cs = inferCursors(body);
	assert !isCursorVar(cs, "x");
}

test "object literal result is NOT cursor" {
	const body = getFuncBody("function f() { const x = { a: 1, b: 2 }; }");
	const cs = inferCursors(body);
	assert !isCursorVar(cs, "x");
}

test "array literal result is NOT cursor" {
	const body = getFuncBody("function f() { const x = [1, 2, 3]; }");
	const cs = inferCursors(body);
	assert !isCursorVar(cs, "x");
}

test "move expression prevents cursor" {
	const body = getFuncBody("function f(arr: string[]) { const x = arr[0]; const y = move x; }");
	const cs = inferCursors(body);
	assert !isCursorVar(cs, "x");
}

test "connected variables share mutation graph" {
	// a borrows from arr. b borrows from a (connected).
	// arr.push mutates arr's graph → both a and b see it while they're alive.
	const body = getFuncBody("function f(arr: string[]) { const a = arr[0]; const b = a; arr.push(\"x\"); process(a); process(b); }");
	const cs = inferCursors(body);
	assert !isCursorVar(cs, "a");
	assert !isCursorVar(cs, "b");
}
