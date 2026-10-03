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
	Node, NodeKind, Symbol,
	VariableDeclData, MemberExprData, ArrayAccessData,
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
import {
	VF_OWNS_DATA, VF_PREVENT_CURSOR, VF_IS_REASSIGNED, VF_IS_COND_REASSIGNED, VF_IS_PARAM, CK_ROOT_OF,
	Partitions, createPartitions, variableId, registerVariable, ufRoot, ufConnect,
	potentialMutation, dangerousMutation, getIdentSym, allRoots, connectStore, potentialMutationViaArg,
} from "../checker/varPartitions";
import { setFlag, hasFlag, isCursorSym, SymbolFlag } from "../checker/symbol";
import { parseSource } from "../parser/statements/validation";
import { checkProgram } from "../checker/checkPass";

// ===== destMightOwn — determines if dest OWNS data from src =====
// If dest owns → marked ownsData → cannot be cursor.
// If dest borrows → connected via union-find → cursor candidate.

function destMightOwn(p: Partitions, destIdx: int32, src: Node): void {
	if (src == null) return;

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
			const srcId = variableId(p, src.resolvedSym);
			if (srcId < 0) {
				// Unknown variable (module-level, imported) — unsafe to alias
				p.vars[destIdx].flags = p.vars[destIdx].flags | VF_OWNS_DATA;
			} else {
				ufConnect(p, p.vars[destIdx].sym, p.vars[srcId].sym);
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
	if (node == null) return;
	p.abstractTime += 1;

	match (node.kind) {
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			liveRanges(p, d.initializer);
			registerVariable(p, node.resolvedSym, false);
			// Declared in loop body → effectively reassigned each iteration
			if (p.inLoop > 0 && d.initializer != null) {
				const vid = variableId(p, node.resolvedSym);
				if (vid >= 0) markReassigned(p, vid);
			}
		},

		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			liveRanges(p, d.left);
			liveRanges(p, d.right);
			if (d.operator == "=") {
				const lhs = getIdentSym(d.left);
				if (lhs != null) {
					const vid = variableId(p, lhs);
					if (vid >= 0) {
						// Track single reassignment source (for it = it.next pattern)
						const rhs = getIdentSym(d.right);
						if (rhs != null && (p.vars[vid].reassignedTo == null || p.vars[vid].reassignedTo == rhs)) {
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
			// Auto-register referenced variables not yet seen (params, outer scope).
			// Treat as "external" — alive for the full function, never a cursor candidate.
			if (node.resolvedSym != null && !hasFlag(node.resolvedSym, SymbolFlag.Global)) {
				registerVariable(p, node.resolvedSym, true);
			}
			const id = variableId(p, node.resolvedSym);
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

function deps(p: Partitions, dest: Symbol | null, src: Node): void {
	const destId = variableId(p, dest);
	if (destId < 0) return;
	if (src == null) return;

	// Classify: does dest own data or borrow?
	destMightOwn(p, destId, src);

	// Source checks: prevent cursor when borrowing from unsafe sources
	const srcRoots: Symbol[] = [];
	allRoots(src, srcRoots);
	for (const srcSym of srcRoots) {
		if (srcSym == dest) continue; // self-assign ok (it = it.next)
		if (hasFlag(srcSym, SymbolFlag.Global)) {
			p.vars[destId].flags = p.vars[destId].flags | VF_PREVENT_CURSOR;
			continue;
		}
		const srcId = variableId(p, srcSym);
		if (srcId >= 0) {
			// Source lives shorter than dest → can't borrow
			if ((p.vars[srcId].flags & VF_IS_PARAM) == 0 &&
				p.vars[srcId].aliveEnd < p.vars[destId].aliveEnd) {
				p.vars[destId].flags = p.vars[destId].flags | VF_PREVENT_CURSOR;
			}
			// Source is reassigned or prevented → can't borrow
			if ((p.vars[srcId].flags & (VF_IS_REASSIGNED | VF_PREVENT_CURSOR)) != 0) {
				p.vars[destId].flags = p.vars[destId].flags | VF_PREVENT_CURSOR;
			}
			// Source reassigned to different target → can't borrow
			if (p.vars[srcId].reassignedTo != null && p.vars[srcId].reassignedTo != dest) {
				p.vars[destId].flags = p.vars[destId].flags | VF_PREVENT_CURSOR;
			}
		}
	}
}

function trav(p: Partitions, node: Node | null): void {
	if (node == null) return;
	p.abstractTime += 1;

	match (node.kind) {
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			// Initializer is an assignment source (for pretendOwnsData on [x], {x})
			p.inAsgnSource += 1;
			trav(p, d.initializer);
			p.inAsgnSource -= 1;
			if (node.resolvedSym != null && d.initializer != null) {
				connectStore(p, [node.resolvedSym], node.resolvedSym.symbolType, d.initializer);
			}
			deps(p, node.resolvedSym, d.initializer);
		},

		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			trav(p, d.left);
			if (d.operator == "=") {
				p.inAsgnSource += 1;
				trav(p, d.right);
				p.inAsgnSource -= 1;

				// Assignment to variable → mutation on LHS graph
				const lhsRoots: Symbol[] = [];
				allRoots(d.left, lhsRoots);
				for (const r of lhsRoots) { potentialMutation(p, r); }
				connectStore(p, lhsRoots, d.left.nodeType, d.right);

				// Cursor deps for assignment
				const lhs = getIdentSym(d.left);
				if (lhs != null) deps(p, lhs, d.right);
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
			if (d.callee != null && d.callee.kind == NodeKind.MemberExpr) {
				const objRoots: Symbol[] = [];
				allRoots((d.callee.data as MemberExprData).object, objRoots);
				for (const r of objRoots) { potentialMutation(p, r); }
			}

			// HiddenAddr arguments → callee receives mutable pointer (var param)
			for (const arg of d.arguments) {
				if (arg != null && arg.kind == NodeKind.HiddenAddr) {
					const addrRoots: Symbol[] = [];
					allRoots((arg.data as { expr: Node }).expr, addrRoots);
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
			for (const arg of d.arguments) { potentialMutationViaArg(p, arg); }
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
					const eid = variableId(p, getIdentSym(elem));
					if (eid >= 0) p.vars[eid].flags = p.vars[eid].flags | VF_OWNS_DATA;
				}
			}
		},
		NodeKind.ObjectLiteral => {
			const d = node.data as ObjectLiteralData;
			for (const prop of d.properties) { trav(p, prop); }
			if (p.inAsgnSource > 0) {
				for (const prop of d.properties) {
					const pid = variableId(p, getIdentSym(prop));
					if (pid >= 0) p.vars[pid].flags = p.vars[pid].flags | VF_OWNS_DATA;
				}
			}
		},

		// Move prevents cursoring of source
		NodeKind.MoveExpr => {
			trav(p, (node.data as MoveExprData).moveArg);
			const mid = variableId(p, getIdentSym((node.data as MoveExprData).moveArg));
			if (mid >= 0) p.vars[mid].flags = p.vars[mid].flags | VF_PREVENT_CURSOR;
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
			for (const a of d.newArguments) { potentialMutationViaArg(p, a); }
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

function computeCursorDecisions(p: Partitions): Symbol[] {
	const result: Symbol[] = [];
	let i = 0;
	while (i < p.vars.length) {
		const v = p.vars[i];
		// Skip params (handled separately in inject.ms)
		if ((v.flags & VF_IS_PARAM) != 0) { i += 1; continue; }
		// Must not own data, be prevented, or be conditionally reassigned
		if ((v.flags & (VF_OWNS_DATA | VF_PREVENT_CURSOR | VF_IS_COND_REASSIGNED)) != 0) {
			i += 1; continue;
		}

		// Check graph for dangerous mutation during cursor's lifetime
		const r = ufRoot(p, i);
		if (p.vars[r].con.kind == CK_ROOT_OF) {
			const g = p.graphs[p.vars[r].con.target];
			if (dangerousMutation(g, v)) { i += 1; continue; }
		}

		result.push(v.sym);
		i += 1;
	}
	return result;
}

// ===== Public API =====

// Main entry point — called once per function body, before DRC injection.
export function inferCursors(body: Node): void {
	if (body == null) return;
	if (body.kind != NodeKind.BlockStmt) return;

	const p = createPartitions();

	// Pass 1: compute live ranges and register variables
	liveRanges(p, body);

	// Reset time for pass 2 (consistent abstractTime required)
	p.abstractTime = 0;

	// Pass 2: build union-find graphs and track mutations
	trav(p, body);

	// Decision: which variables can safely be cursors?
	for (const sym of computeCursorDecisions(p)) { setFlag(sym, SymbolFlag.Cursor); }
}

// ===== Tests =====

function getStmts(input: string): Node[] {
	const result = parseSource(input);
	if (!result.ok) return [];
	const prog = result.value;
	checkProgram(prog);
	const d = prog.data as ProgramData;
	return d.programStmts;
}

function getFuncBody(input: string): Node {
	const stmts = getStmts(input);
	if (stmts.length == 0) return null as unknown as Node;
	const stmt = stmts[0];
	if (stmt.kind == NodeKind.FunctionDecl) return (stmt.data as FunctionDeclData).fnBody;
	return null as unknown as Node;
}

function getFuncNamed(input: string, name: string): Node {
	for (const stmt of getStmts(input)) {
		let decl = stmt;
		if (decl.kind == NodeKind.ExportDecl) decl = (decl.data as ExportDeclData).exportedDecl;
		if (decl.kind == NodeKind.FunctionDecl && (decl.data as FunctionDeclData).fnName == name) {
			return (decl.data as FunctionDeclData).fnBody;
		}
	}
	return null as unknown as Node;
}

const BOXES = "class Box { v: string; constructor(v: string) { this.v = v; } }\n"
	+ "class Holder { child: Box; constructor(s: string) { this.child = new Box(s); } }\n"
	+ "class Top { mid: Holder; mids: Holder[]; constructor() { this.mid = new Holder(\"i\"); this.mids = []; } }\n"
	+ "function replaceChild(h: Holder): void { h.child = new Box(\"n\"); }\n"
	+ "function replaceFirst(arr: Box[]): void { arr[0] = new Box(\"n\"); }\n"
	+ "function show(s: string): void { console.log(s); }\n";

function isCursorNamed(node: Node | null, name: string): boolean {
	if (node == null) return false;
	if (node.kind == NodeKind.VariableDecl && (node.data as VariableDeclData).declName == name) {
		return isCursorSym(node.resolvedSym);
	}
	let found = false;
	forEachChild(node, (child: Node): void => { if (!found && isCursorNamed(child, name)) found = true; });
	return found;
}

// --- Retained tests (adapted for union-find) ---

test "local read-only borrow is cursor" {
	const body = getFuncBody("function f(arr: string[]) { const x = arr.length; }");
	inferCursors(body);
	assert isCursorNamed(body, "x");
}

test "returned variable is cursor (return copies, safe)" {
	// With union-find: x borrows from arr, no ownership, no mutation.
	// DRC handles return via copy (isLastReadSafe returns false for cursors).
	const body = getFuncBody("function f(arr: string[]) { const x = arr[0]; return x; }");
	inferCursors(body);
	assert isCursorNamed(body, "x");
}

test "call argument is cursor (call copies, safe)" {
	// x borrows from arr[0]. Passing to call: inject.ms copies (incref).
	// No mutation on arr's graph → cursor is safe.
	const body = getFuncBody("function f(arr: string[]) { const x = arr[0]; process(x); }");
	inferCursors(body);
	assert isCursorNamed(body, "x");
}

test "assigned to another var: source is cursor, dest connects" {
	// x borrows from arr[0]. y = x → y connects to x's graph.
	// Both can be cursors if neither owns data.
	const body = getFuncBody("function f(arr: string[]) { const x = arr[0]; const y = x; }");
	inferCursors(body);
	assert isCursorNamed(body, "x");
	assert isCursorNamed(body, "y");
}

test "let variable without reassignment is cursor" {
	// let is fine if never reassigned — union-find tracks reassignment, not declKind.
	const body = getFuncBody("function f(arr: string[]) { let x = arr[0]; }");
	inferCursors(body);
	assert isCursorNamed(body, "x");
}

test "index-write through alias is not cursor even when alias is never read" {
	const body = getFuncBody("function f() { const vn: Vec<number> = [1, 2]; const cn = vn; cn[0] = 7; console.log(vn[0]); }");
	inferCursors(body);
	assert !isCursorNamed(body, "cn");
}

test "call result is NOT cursor (owns data)" {
	const body = getFuncBody("function f() { const x = getValue(); }");
	inferCursors(body);
	assert !isCursorNamed(body, "x");
}

test "member access with only read use is cursor" {
	const body = getFuncBody("function f(obj: { name: string }) { const name = obj.name; if (name) {} }");
	inferCursors(body);
	assert isCursorNamed(body, "name");
}

test "thrown variable is cursor (throw copies, safe)" {
	const body = getFuncBody("function f(arr: string[]) { const x = arr[0]; throw x; }");
	inferCursors(body);
	assert isCursorNamed(body, "x");
}

test "stored in object is NOT cursor (constructor context)" {
	const body = getFuncBody("function f(arr: string[]) { const x = arr[0]; const obj = { val: x }; }");
	inferCursors(body);
	// x appears in ObjectLiteral — pretendOwnsData in inAsgnSource context
	// obj owns data (ObjectLiteral constructor), x gets ownsData via constructor context
	assert !isCursorNamed(body, "x");
}

test "DRC temp is inferred like any local" {
	const body = getFuncBody("function f(arr: string[]) { const $tmp = arr[0]; }");
	inferCursors(body);
	assert isCursorNamed(body, "$tmp");
}

test "nested block cursor" {
	const body = getFuncBody("function f(obj: { name: string }) { if (true) { const x = obj.name; } }");
	inferCursors(body);
	assert isCursorNamed(body, "x");
}

// --- New tests for union-find-specific features ---

test "source mutated during cursor lifetime: NOT cursor" {
	// x borrows from arr[0]. arr.push() mutates arr while x is alive → dangerousMutation.
	const body = getFuncBody("function f(arr: string[]) { const x = arr[0]; arr.push(\"new\"); process(x); }");
	inferCursors(body);
	assert !isCursorNamed(body, "x");
}

test "source mutated BEFORE cursor: IS cursor" {
	// arr.push() happens before x borrows → mutation not in cursor lifetime.
	const body = getFuncBody("function f(arr: string[]) { arr.push(\"new\"); const x = arr[0]; process(x); }");
	inferCursors(body);
	assert isCursorNamed(body, "x");
}

test "let reassigned variable is NOT cursor" {
	const body = getFuncBody("function f(arr: string[]) { let x = arr[0]; x = arr[1]; }");
	inferCursors(body);
	assert !isCursorNamed(body, "x");
}

test "new expression result is NOT cursor" {
	const body = getFuncBody("function f() { const x = new Foo(); }");
	inferCursors(body);
	assert !isCursorNamed(body, "x");
}

test "object literal result is NOT cursor" {
	const body = getFuncBody("function f() { const x = { a: 1, b: 2 }; }");
	inferCursors(body);
	assert !isCursorNamed(body, "x");
}

test "array literal result is NOT cursor" {
	const body = getFuncBody("function f() { const x = [1, 2, 3]; }");
	inferCursors(body);
	assert !isCursorNamed(body, "x");
}

test "move expression prevents cursor" {
	const body = getFuncBody("function f(arr: string[]) { const x = arr[0]; const y = move x; }");
	inferCursors(body);
	assert !isCursorNamed(body, "x");
}

test "connected variables share mutation graph" {
	// a borrows from arr. b borrows from a (connected).
	// arr.push mutates arr's graph → both a and b see it while they're alive.
	const body = getFuncBody("function f(arr: string[]) { const a = arr[0]; const b = a; arr.push(\"x\"); process(a); process(b); }");
	inferCursors(body);
	assert !isCursorNamed(body, "a");
	assert !isCursorNamed(body, "b");
}

test "same-named declarations in sibling scopes are separate variables" {
	const body = getFuncBody("function f(arr: string[]) { if (true) { const x = arr[0]; process(x); } else { const x = getValue(); } }");
	inferCursors(body);
	assert isCursorNamed(body, "x");
}

test "borrow from a module global is NOT cursor" {
	const body = getFuncNamed(BOXES + "let g = new Holder(\"a\");\nfunction f(): void { const c = g.child; show(c.v); }", "f");
	inferCursors(body);
	assert !isCursorNamed(body, "c");
}

test "borrow from an exported module global is NOT cursor" {
	const body = getFuncNamed(BOXES + "export let g = new Holder(\"a\");\nfunction f(): void { const c = g.child; show(c.v); }", "f");
	inferCursors(body);
	assert !isCursorNamed(body, "c");
}

test "passing the borrowed-from object to a function mutates its graph" {
	const body = getFuncNamed(BOXES + "function f(h: Holder): void { const c = h.child; replaceChild(h); show(c.v); }", "f");
	inferCursors(body);
	assert !isCursorNamed(body, "c");
}

test "passing the array an element was borrowed from mutates its graph" {
	const body = getFuncNamed(BOXES + "function f(boxes: Box[]): void { const b = boxes[0]; replaceFirst(boxes); show(b.v); }", "f");
	inferCursors(body);
	assert !isCursorNamed(body, "b");
}

test "passing a value without references keeps the borrow a cursor" {
	const body = getFuncNamed(BOXES + "function f(h: Holder): void { const c = h.child; show(\"x\"); show(c.v); }", "f");
	inferCursors(body);
	assert isCursorNamed(body, "c");
}

test "a field store joins the stored object to the target's graph" {
	const body = getFuncNamed(BOXES + "function f(t: Top): void { const m = new Holder(\"o\"); t.mid = m; const z = m.child; t.mid.child = new Box(\"n\"); show(z.v); show(m.child.v); }", "f");
	inferCursors(body);
	assert !isCursorNamed(body, "z");
}

test "an element store joins the stored object to the array's graph" {
	const body = getFuncNamed(BOXES + "function f(arr: Holder[]): void { const m = new Holder(\"o\"); arr[0] = m; const z = m.child; arr[0].child = new Box(\"n\"); show(z.v); show(m.child.v); }", "f");
	inferCursors(body);
	assert !isCursorNamed(body, "z");
}

test "a declaration holding a local joins the local to its graph" {
	const body = getFuncNamed(BOXES + "class Wrap { h: Holder; constructor(h: Holder) { this.h = h; } }\nfunction f(): void { const m = new Holder(\"o\"); const w = new Wrap(m); const z = m.child; w.h.child = new Box(\"n\"); show(z.v); show(m.child.v); }", "f");
	inferCursors(body);
	assert !isCursorNamed(body, "z");
}

test "storing an array literal joins its elements to the target's graph" {
	const body = getFuncNamed(BOXES + "function f(t: Top): void { const m = new Holder(\"o\"); t.mids = [m]; const z = m.child; t.mids[0].child = new Box(\"n\"); show(z.v); show(m.child.v); }", "f");
	inferCursors(body);
	assert !isCursorNamed(body, "z");
}

test "loop binding over an array written in the loop is NOT cursor" {
	const body = getFuncNamed(BOXES + "function f(boxes: Box[]): void { let i = 0; while (i < 2) { const b = boxes[i]; i = i + 1; boxes[0] = new Box(\"n\"); show(b.v); } }", "f");
	inferCursors(body);
	assert !isCursorNamed(body, "b");
}

test "loop binding over an array nobody writes is cursor" {
	const body = getFuncNamed(BOXES + "function f(boxes: Box[]): void { let i = 0; while (i < 2) { const b = boxes[i]; i = i + 1; show(b.v); } }", "f");
	inferCursors(body);
	assert isCursorNamed(body, "b");
}
