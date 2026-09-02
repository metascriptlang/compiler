// src/checker/flow.ms
//
// Flow graph query layer. Consumes the FlowNode graph built by src/binder/
// and computes narrowed types for reference expressions at each program point.
//
// Phase 2 scope: non-loop cases. Loop narrowing (LoopLabel fixed-point,
// incomplete types, flowTypeCache save/restore) ships in Phase 3. Assignment
// narrowing for let-variables ships in Phase 6.

import {
	Node, NodeKind, DeclKind,
	FlowNode, FlowFlags, FlowList,
	Type, TypeKind,
	IdentifierData, BinaryExprData, UnaryExprData, MemberExprData,
	StringLiteralData, HiddenStdConvData,
	SwitchStmtData, SwitchCaseData, VariableDeclData, CallExprData,
} from "../ast/node";
import {
	createUnion, inferredType, nullType, neverType,
	detectUnionDiscriminant, findVariantByDiscriminant,
	findVariantByStringDiscriminant, findFieldInVariant,
	isMaybeType, unwrapMaybeType, isNumeric, isDiscriminatedUnion,
} from "./types";
import { typeRelation, TypeRelation, sameType } from "./compat";

// ===== FlowType =====
//
// The result of walking a flow graph branch. `incomplete = true` means the
// fixed-point for a loop back-edge hasn't converged yet. Phase 2 always
// produces complete types; Phase 3 will introduce proper incompleteness.

export interface FlowType {
	t: Type | null;
	incomplete: boolean;
}

function flowType(t: Type | null, incomplete: boolean): FlowType {
	return { t, incomplete };
}

// ===== FlowState =====
//
// Per-query state. One state per top-level getFlowTypeOfReference call.
// Nested recursion reuses the same state. Holds the reference being queried,
// its declared type, the recursion depth cap, and the per-query caches for
// shared-flow and loop-label memoization.

// Shared-flow cache entry: memoize computed types for FlowNodes tagged
// `Shared` within one query. A linear scan is fine because per-query N is
// small (typically under ~20 entries per query).
interface SharedFlowEntry {
	flow: FlowNode;
	ft: FlowType;
}

// Loop label re-entry record. When a query recurses into its own loop label
// back-edge, we detect the re-entry by scanning `flowLoopStack` and return
// an incomplete union of types accumulated so far — this is what makes the
// fixed-point terminate.
interface FlowLoopInfo {
	loopNode: FlowNode;
	refKey: string;
	types: Type[];
}

export interface FlowState {
	reference: Node;                 // the reference expression whose type we're computing
	declaredType: Type;              // the declared (pre-narrowing) type of the reference
	depth: int32;                    // recursion guard; TypeScript caps at 2000
	refKey: string;                  // cached getFlowCacheKey(reference); "" means not yet computed; "@nondotted" means unnarrowable
	sharedFlows: SharedFlowEntry[];  // per-query Shared-flow cache
	flowLoopStack: FlowLoopInfo[];   // in-progress loop analyses (re-entry detection)
	// Phase 6 deferred fields (not yet used):
	//   - initialType: Type — distinguish declaredType (widened) from
	//     initialType (usually equal, but differs for parameters with init
	//     expressions). Needed when let-variable narrowing lands in Phase 6.
	//   - flowContainer: Node — owning function/container, used by the Start
	//     handler to implement the cross-container narrowing rule (`this.foo`
	//     narrows across arrow boundaries; local identifiers do not). Phase 6.
}

function createFlowState(refNode: Node, declaredType: Type): FlowState {
	return {
		reference: refNode,
		declaredType: declaredType,
		depth: 0,
		refKey: "",
		sharedFlows: [],
		flowLoopStack: [],
	};
}

// Reference cache key. Used to distinguish loop analyses for different
// references that share the same loop label. Returns the sentinel
// "@nondotted" when the reference isn't a simple identifier or dotted
// member-chain — non-dotted references bypass the loop cache entirely
// (matches the reference `writeFlowCacheKey`).
function getFlowCacheKey(refNode: Node): string {
	if (refNode === null) return "@nondotted";
	return writeFlowCacheKey(refNode);
}

function writeFlowCacheKey(node: Node): string {
	if (node === null) return "@nondotted";
	match (node.kind) {
		NodeKind.Identifier => {
			const d = node.data as IdentifierData;
			// Prefer symbol identity via a stable string form — the symbol
			// pointer address isn't accessible in MetaScript, but the symbol's
			// name + modulePath is unique enough for query-scoped caching.
			if (node.resolvedSym !== null) {
				return "sym:" + node.resolvedSym.name + "@" + node.resolvedSym.modulePath;
			}
			return "name:" + d.name;
		},
		NodeKind.MemberExpr => {
			const d = node.data as MemberExprData;
			const base = writeFlowCacheKey(d.object);
			if (base === "@nondotted") return "@nondotted";
			return base + "." + d.property;
		},
		_ => { return "@nondotted"; },
	};
	return "@nondotted";
}

// Check if any FlowLoopInfo in the stack matches this (loopNode, refKey) pair.
// Used to detect re-entry during back-edge recursion.
function findLoopInfo(stack: FlowLoopInfo[], loopNode: FlowNode, refKey: string): FlowLoopInfo {
	let i = 0;
	while (i < stack.length) {
		const info = stack[i];
		if (info.loopNode === loopNode && info.refKey === refKey) return info;
		i = i + 1;
	}
	return null as unknown as FlowLoopInfo;
}

// Append a type to a list only if it's not already present (structural dedup).
// Used to keep the per-loop antecedent set bounded.
function appendIfUnique(types: Type[], t: Type | null): void {
	if (t === null) return;
	for (const u of types) {
		if (u === t) return;
	}
	types.push(t);
}

// ===== Reference matching =====
//
// A condition like `x.kind === "circle"` narrows the `x` reference. To
// decide whether a condition affects the reference we're computing, we walk
// both sides structurally. Identifier matching requires resolvedSym identity
// on BOTH sides — name comparison is unsafe under shadowing (`function f(s)
// { if (s.kind === "a") { const s = 42; s } }` would false-match the inner
// `s` to the outer `s`). When getFlowTypeOfReference is called by the
// checker, both sides always have resolvedSym populated.

function isMatchingReference(source: Node, target: Node): boolean {
	if (source === null || target === null) return false;
	// Unwrap checker-inserted hidden conversions. The condition expression is
	// stored at bind time (no HiddenDeref); the access in the body has been
	// rewritten by the checker to wrap reference-typed reads in HiddenDeref
	// so codegen knows to deref the pointer. Without unwrapping, the structural
	// comparison fails between the bind-time condition and check-time access.
	while (source.kind === NodeKind.HiddenDeref || source.kind === NodeKind.HiddenAddr) {
		const hd = source.data as { expr: Node };
		source = hd.expr;
	}
	while (target.kind === NodeKind.HiddenDeref || target.kind === NodeKind.HiddenAddr) {
		const hd = target.data as { expr: Node };
		target = hd.expr;
	}
	if (source === target) return true;
	if (source.kind !== target.kind) return false;
	match (source.kind) {
		NodeKind.Identifier => {
			// Symbol identity is required. If either side lacks resolvedSym
			// (e.g., the reference wasn't visited by the checker yet, or it's
			// synthetic) we conservatively return false — this means we
			// might miss a narrowing, but we'll never apply the wrong one.
			if (source.resolvedSym === null || target.resolvedSym === null) {
				return false;
			}
			return source.resolvedSym === target.resolvedSym;
		},
		NodeKind.MemberExpr => {
			const sd = source.data as MemberExprData;
			const td = target.data as MemberExprData;
			if (sd.property !== td.property) return false;
			return isMatchingReference(sd.object, td.object);
		},
		_ => { return false; },
	};
	return false;
}

// ===== Literal value extraction =====
//
// To compare `x.kind === "circle"` against union variants, we pull the
// literal value out of the AST. Supports string literals, enum-member
// references (both the original `K.Member` form and the post-checker
// mangled `K_Member` identifier form), and null.

function extractLiteralString(node: Node): string {
	if (node === null) return "";
	match (node.kind) {
		NodeKind.StringLiteral => {
			const d = node.data as StringLiteralData;
			return d.value;
		},
		NodeKind.Identifier => {
			// Enum member after checker rewrite: MemberExpr `K.A` becomes
			// Identifier `K_A`. We return the raw name; findVariantByDiscriminant
			// uses bareAfterDelim("_") to strip the enum prefix.
			const d = node.data as IdentifierData;
			return d.name;
		},
		NodeKind.MemberExpr => {
			// Enum member before checker rewrite: `K.A`
			const d = node.data as MemberExprData;
			return d.property;
		},
		_ => { return ""; },
	};
	return "";
}

function isNullLiteral(node: Node): boolean {
	if (node === null) return false;
	return node.kind === NodeKind.NullLiteral;
}

// ===== Entry point =====

export function getFlowTypeOfReference(refNode: Node, declaredType: Type): Type {
	if (refNode === null) return declaredType;
	if (declaredType === null) return declaredType;
	const flow = refNode.flowNode;
	if (flow === null) return declaredType;
	const state = createFlowState(refNode, declaredType);
	const ft = getTypeAtFlowNode(state, flow);
	const t = ft.t;
	if (t === null) return declaredType;
	return t;
}

// Phase 4: Ref<T> nullability query for --strict-nil. Walks the flow graph
// looking for a dominating TrueCondition `ref !== null` (or FalseCondition
// `ref === null`). Returns true if at least one such check exists on every
// path to this reference. Conservative: returns false on loops or unknown
// flow kinds — matches the old `impliesNotNull` query semantics (0 = unknown).
//
// Unlike getFlowTypeOfReference, this doesn't construct a refined Type —
// it returns a boolean answer. Used by checkMemberExpr:strictNullChecks.
export function isDefinitelyNonNullAt(refNode: Node): boolean {
	if (refNode === null || refNode.flowNode === null) return false;
	const state = createFlowState(refNode, nullType());
	return walkForNonNullCheck(state, refNode.flowNode, refNode);
}

// Walks back from `flow` looking for a dominating `ref !== null` TrueCondition
// (or equivalent). Returns true iff such a condition exists on the path.
function walkForNonNullCheck(state: FlowState, flow: FlowNode | null, refNode: Node): boolean {
	if (state.depth === 2000) return false;
	state.depth = state.depth + 1;
	let current: FlowNode | null = flow;
	let result = false;
	while (true) {
		if (current === null) { result = false; break; }
		const flags = current.flags;
		if ((flags & FlowFlags.Unreachable) !== 0) { result = false; break; }
		if ((flags & FlowFlags.Start) !== 0) { result = false; break; }
		if ((flags & (FlowFlags.TrueCondition | FlowFlags.FalseCondition)) !== 0) {
			const assumeTrue = (flags & FlowFlags.TrueCondition) !== 0;
			if (isNonNullCheckForRef(current.node, refNode, assumeTrue)) {
				result = true;
				break;
			}
			current = current.antecedent;
			continue;
		}
		if ((flags & FlowFlags.BranchLabel) !== 0) {
			// All antecedents must prove non-null for the join to be non-null.
			let list: FlowList | null = current.antecedents;
			let allNonNull = list !== null;
			while (list !== null) {
				if (!walkForNonNullCheck(state, list.flow, refNode)) {
					allNonNull = false;
					break;
				}
				list = list.next;
			}
			result = allNonNull;
			break;
		}
		if ((flags & FlowFlags.LoopLabel) !== 0) {
			// Conservative: loop narrowing for Ref null is Phase 6+.
			result = false;
			break;
		}
		// Assignment / ArrayMutation / Call / ReduceLabel / SwitchClause /
		// Shared — walk up.
		current = current.antecedent;
	}
	state.depth = state.depth - 1;
	return result;
}

// Check whether `expr` is `ref !== null` (when assumeTrue) or `ref === null`
// (when !assumeTrue). Handles symmetric left/right orderings. Recognizes
// `!` negation and `&&` decomposition.
function isNonNullCheckForRef(expr: Node | null, refNode: Node, assumeTrue: boolean): boolean {
	if (expr === null) return false;
	if (expr.kind === NodeKind.UnaryExpr) {
		const d = expr.data as UnaryExprData;
		if (d.unaryOp === "!") return isNonNullCheckForRef(d.operand, refNode, !assumeTrue);
	}
	if (expr.kind !== NodeKind.BinaryExpr) return false;
	const d = expr.data as BinaryExprData;
	// && in a TrueCondition: both sides must be true
	if (d.operator === "&&" && assumeTrue) {
		return isNonNullCheckForRef(d.left, refNode, true)
			|| isNonNullCheckForRef(d.right, refNode, true);
	}
	// Equality comparisons with null
	if (d.operator === "!==" || d.operator === "===" || d.operator === "!=" || d.operator === "==") {
		const wantNotNull = ((d.operator === "!==" || d.operator === "!=") && assumeTrue)
			|| ((d.operator === "===" || d.operator === "==") && !assumeTrue);
		if (!wantNotNull) return false;
		if (d.left !== null && d.right !== null && d.left.kind === NodeKind.NullLiteral) {
			return isMatchingReference(d.right, refNode);
		}
		if (d.left !== null && d.right !== null && d.right.kind === NodeKind.NullLiteral) {
			return isMatchingReference(d.left, refNode);
		}
	}
	return false;
}

// ===== Core query loop =====
//
// Walks the flow graph backward from `flow`, applying narrowing at each
// Condition / SwitchClause / BranchLabel node. Tail-recursive for mutations
// that don't affect the reference (walks straight up the antecedent chain).
//
// Depth cap matches the reference: pathological inputs stop
// analysis and fall back to the declared type rather than stack-overflow.

function getTypeAtFlowNode(state: FlowState, flow: FlowNode | null): FlowType {
	if (state.depth === 2000) return flowType(state.declaredType, false);
	state.depth = state.depth + 1;
	let current: FlowNode | null = flow;
	let result: FlowType = flowType(state.declaredType, false);
	// Track a pending Shared-flow node: if we detect one on entry, cache the
	// final result under its key on exit. This memoizes expensive sub-walks
	// within a single query.
	let sharedFlow: FlowNode | null = null;
	// Linear condition narrowings collected while walking the antecedent chain,
	// applied post-order after the loop. Converts a deep if/else/&&/|| spine from
	// O(n) call-stack (the old getTypeAtFlowCondition recursion) to O(n) heap.
	const pending: FlowNode[] = [];
	while (true) {
		if (current === null) {
			result = flowType(state.declaredType, false);
			break;
		}
		const flags = current.flags;
		// Per-query Shared-flow cache check. Only the FIRST shared flow we
		// encounter on this walk becomes the cache key; nested shared flows
		// within the same walk fall through to normal processing.
		if ((flags & FlowFlags.Shared) !== 0 && sharedFlow === null) {
			const cached = lookupSharedFlow(state, current);
			if (cached !== null) {
				result = cached;
				break;
			}
			// Only stake a cache claim on a clean walk (no pending narrowings
			// above this node) — otherwise the committed type would wrongly
			// include narrowings that belong above the shared node.
			if (pending.length === 0) sharedFlow = current;
		}
		if ((flags & FlowFlags.Unreachable) !== 0) {
			// Dead code — no narrowing, return declared type.
			result = flowType(state.declaredType, false);
			break;
		}
		if ((flags & FlowFlags.Start) !== 0) {
			result = flowType(state.declaredType, false);
			break;
		}
		if ((flags & FlowFlags.Assignment) !== 0) {
			// Phase 6: narrow to the RHS type when the assignment's target
			// matches our reference. Variable declarations with initializers
			// count (the declNode IS the assignment source).
			const narrowed = narrowByAssignment(current.node, state.reference, state.declaredType);
			if (narrowed !== null) {
				const parent = getTypeAtFlowNode(state, current.antecedent);
				result = flowType(narrowed, parent.incomplete);
				break;
			}
			current = current.antecedent;
			continue;
		}
		if ((flags & FlowFlags.ArrayMutation) !== 0) {
			// Evolving arrays (Phase 6+). Phase 2: tail-recurse.
			current = current.antecedent;
			continue;
		}
		if ((flags & FlowFlags.Call) !== 0) {
			// Assertion functions (Phase 6+). Phase 2: tail-recurse.
			current = current.antecedent;
			continue;
		}
		if ((flags & (FlowFlags.TrueCondition | FlowFlags.FalseCondition)) !== 0) {
			// Linear (single-antecedent) narrowing — collect and keep walking
			// iteratively instead of recursing, so deep condition chains don't
			// grow the call stack. Drained post-loop below.
			pending.push(current);
			current = current.antecedent;
			continue;
		}
		if ((flags & FlowFlags.SwitchClause) !== 0) {
			result = getTypeAtSwitchClause(state, current);
			break;
		}
		if ((flags & FlowFlags.BranchLabel) !== 0) {
			// Single-antecedent branch label is not a real merge — walk through
			// it iteratively (mirrors TS getTypeAtFlowNode) so a long chain of
			// sequential `if`s doesn't grow the call stack. Real merges (2+
			// antecedents) still recurse into getTypeAtBranchLabel.
			const ants = current.antecedents;
			if (ants !== null && ants.next === null) {
				current = ants.flow;
				continue;
			}
			// Per-query memo: without it, a query at the end of N sequential
			// narrowing `if`s re-walks BOTH antecedents at every label —
			// 2^N recursion (a 50-statement chain never finished). getTypeAtFlowNode
			// is a pure function of (state, node), so the first result per label
			// is final. Same cache list as the Shared-flow memo.
			const cachedLabel = lookupSharedFlow(state, current);
			if (cachedLabel !== null) {
				result = cachedLabel;
				break;
			}
			result = getTypeAtBranchLabel(state, current);
			cacheSharedFlow(state, current, result);
			break;
		}
		if ((flags & FlowFlags.LoopLabel) !== 0) {
			// Single-antecedent loop label (no back-edge) is likewise a
			// pass-through — iterate instead of entering the fixed-point.
			const ants = current.antecedents;
			if (ants !== null && ants.next === null) {
				current = ants.flow;
				continue;
			}
			// Phase 3: fixed-point via per-query loop stack.
			result = getTypeAtFlowLoopLabel(state, current);
			break;
		}
		if ((flags & FlowFlags.ReduceLabel) !== 0) {
			// Try/finally ReduceLabel (Phase 6). Phase 2: pass through.
			current = current.antecedent;
			continue;
		}
		// Unknown flow kind — walk up to avoid getting stuck.
		current = current.antecedent;
	}
	// Drain collected condition narrowings post-order (outermost applied first,
	// innermost last) — the exact unwind order of the former
	// getTypeAtFlowCondition recursion, but on the heap.
	let pi = pending.length - 1;
	while (pi >= 0) {
		const cnode = pending[pi];
		const assumeTrue = (cnode.flags & FlowFlags.TrueCondition) !== 0;
		const narrowed = narrowType(result.t, cnode.node, state.reference, assumeTrue);
		result = flowType(narrowed, result.incomplete);
		pi = pi - 1;
	}
	// Commit shared-flow cache entry if we staked a claim on entry.
	if (sharedFlow !== null) {
		cacheSharedFlow(state, sharedFlow, result);
	}
	state.depth = state.depth - 1;
	return result;
}

// Shared-flow cache lookup: linear scan by FlowNode identity — per-query N is typically < 20.
function lookupSharedFlow(state: FlowState, flow: FlowNode): FlowType {
	for (const entry of state.sharedFlows) {
		if (entry.flow === flow) return entry.ft;
	}
	return null as unknown as FlowType;
}

function cacheSharedFlow(state: FlowState, flow: FlowNode, ft: FlowType): void {
	// Overwrite any existing entry for this flow (the result may improve
	// after back-edge fixed-point analysis completes).
	for (const entry of state.sharedFlows) {
		if (entry.flow === flow) {
			entry.ft = ft;
			return;
		}
	}
	state.sharedFlows.push({ flow: flow, ft: ft });
}

// ===== Switch clause narrowing =====
//
// `switch (s.kind) { case "circle": ...; case "square": ... }` — when the
// discriminant is a MemberExpr on our reference, each case narrows the union
// to the matching variant(s). The binder records the half-open clause range
// [clauseStart, clauseEnd) on `flow.switchClauseData`; this function reads
// the SwitchStmt, extracts the case tests in that range, and filters the
// union.
//
// Phase 2 handles the discriminant-property case. Default clauses fall back
// to the parent type (no exclusion narrowing — Phase 6 adds that).

function getTypeAtSwitchClause(state: FlowState, flow: FlowNode): FlowType {
	const parent = getTypeAtFlowNode(state, flow.antecedent);
	const clauseData = flow.switchClauseData;
	if (clauseData === null) return parent;
	const switchStmt = clauseData.switchStatement;
	if (switchStmt === null) return parent;
	const sd = switchStmt.data as SwitchStmtData;
	const disc = sd.switchDisc;
	if (disc === null) return parent;
	// We only narrow if the discriminant is a MemberExpr on our reference.
	// Simple `switch (x)` on an identifier (not a MemberExpr) could still
	// narrow `x` itself, but that's the truthiness/literal-equality case —
	// Phase 6 territory.
	if (disc.kind !== NodeKind.MemberExpr) return parent;
	const md = disc.data as MemberExprData;
	if (!isMatchingReference(md.object, state.reference)) return parent;
	// Collect the case-test values in the clause range. Each SwitchCaseData
	// may contain multiple caseTests (fall-through `case "a": case "b":`) —
	// all those tests produce the same narrowed body.
	let narrowed: Type | null = null;
	let anyDefault = false;
	const lo: int32 = clauseData.clauseStart;
	const hi: int32 = clauseData.clauseEnd;
	if (sd.switchCases === null) return parent;
	let ci: int32 = lo;
	while (ci < hi && ci < sd.switchCases.length) {
		const caseNode = sd.switchCases[ci];
		if (caseNode === null) { ci = ci + 1; continue; }
		const cd = caseNode.data as SwitchCaseData;
		if (cd.isDefault) {
			anyDefault = true;
			ci = ci + 1;
			continue;
		}
		// Filter the parent union by each test value. Narrow to a specific
		// variant via the same discriminant-property machinery.
		let ti = 0;
		while (ti < cd.caseTests.length) {
			const testVal = cd.caseTests[ti];
			const filtered = narrowTypeByDiscriminantProperty(parent.t, md.property, testVal, true);
			if (filtered !== null && filtered !== parent.t) {
				// Union accumulated narrowed types.
				if (narrowed === null) {
					narrowed = filtered;
				} else if (narrowed !== filtered) {
					narrowed = createUnion([narrowed, filtered]);
				}
			}
			ti = ti + 1;
		}
		ci = ci + 1;
	}
	// Default clause: no positive narrowing in Phase 2. Return parent unchanged.
	// Phase 6 will negate the covered cases to produce the correct remainder.
	if (anyDefault || narrowed === null) return parent;
	return flowType(narrowed, parent.incomplete);
}

// ===== Branch label joining =====
//
// Union the flow types produced by each antecedent. Fast path: if any
// antecedent's type matches the declared type, the join is just the
// declared type (the narrowing from other branches is irrelevant because a
// superset dominates).

function getTypeAtBranchLabel(state: FlowState, flow: FlowNode): FlowType {
	const antecedents: Type[] = [];
	let anyIncomplete = false;
	let list: FlowList | null = flow.antecedents;
	while (list !== null) {
		// Skip Unreachable antecedents — they represent dead-code paths
		// (e.g. the then-branch of `if (x === null) return;`) and contribute
		// no information to the join. Including them broke the fast-path below:
		// Unreachable returns declaredType, which short-circuited the join and
		// erased real narrowing from sibling branches.
		if ((list.flow.flags & FlowFlags.Unreachable) !== 0) {
			list = list.next;
			continue;
		}
		const ft = getTypeAtFlowNode(state, list.flow);
		if (ft.incomplete) anyIncomplete = true;
		// Fast path: declared type in antecedents = declared type result.
		if (ft.t === state.declaredType) {
			return flowType(state.declaredType, anyIncomplete);
		}
		antecedents.push(ft.t);
		list = list.next;
	}
	if (antecedents.length === 0) {
		return flowType(state.declaredType, false);
	}
	if (antecedents.length === 1) {
		return flowType(antecedents[0], anyIncomplete);
	}
	// Dedup types before building the union. Pointer equality misses Union
	// instances built at different sites with the same shape (e.g. Type | null
	// constructed twice produces two different Union objects), which leaks into
	// hover/error messages as `Type | null | Type` when reassignment chains
	// merge at a BranchLabel. Dedup by type IDENTITY (sameType) — assignability
	// would collapse distinct union variants and drop one of them.
	// Filter Never — it's the empty/unreachable type and contributes nothing.
	const uniq: Type[] = [];
	for (const a of antecedents) {
		if (a === null) continue;
		if (a.kind === TypeKind.Never) continue;
		let seen = false;
		for (const u of uniq) {
			if (u === a) { seen = true; break; }
			if (sameType(u, a)) { seen = true; break; }
		}
		if (!seen) uniq.push(a);
	}
	if (uniq.length === 0) return flowType(state.declaredType, anyIncomplete);
	if (uniq.length === 1) return flowType(uniq[0], anyIncomplete);
	return flowType(joinNarrowedTypes(state.declaredType, uniq), anyIncomplete);
}

// ===== Loop label fixed-point =====
//
// `while (x.kind === "circle") { ... }` requires a fixed-point over the
// back-edges. The binder guarantees the FIRST antecedent of a LoopLabel is
// the pre-loop flow (non-looping path); subsequent antecedents are the loop
// back-edges (e.g., the end of the body, `continue` jumps).
//
// Algorithm:
//   1. If we're already analyzing this (loopNode, refKey) pair — i.e., the
//      current call recursed into the same loop via a back-edge — return a
//      union of the types accumulated so far, marked incomplete. This breaks
//      the infinite recursion while producing a conservative result.
//   2. Otherwise, push a new FlowLoopInfo on the stack, walk antecedents in
//      order, union their types. Dedup via appendIfUnique. Short-circuit
//      when any antecedent widens back to declaredType.
//   3. On completion, pop the stack entry and return the union. The result
//      is incomplete iff the first (pre-loop) antecedent was incomplete.
//
// Termination: the type lattice for a single reference is finite (bounded
// by the union's variant count + their sub-narrowings), so appendIfUnique
// stabilizes within finitely many back-edge visits.

function getTypeAtFlowLoopLabel(state: FlowState, flow: FlowNode): FlowType {
	// Compute the reference cache key on first use.
	if (state.refKey === "") {
		state.refKey = getFlowCacheKey(state.reference);
	}
	// Non-dotted references can't be meaningfully narrowed across loops —
	// conservatively return declared type.
	if (state.refKey === "@nondotted") {
		return flowType(state.declaredType, false);
	}
	// Re-entry detection: if this (loopNode, refKey) is already on the
	// stack, return the current accumulated union.
	const existing = findLoopInfo(state.flowLoopStack, flow, state.refKey);
	if (existing !== null) {
		// Re-entry: return accumulated types if any, otherwise declared type.
		// The types.length===0 case means the first antecedent cycled back
		// before producing any narrowing — conservatively return declared type.
		if (existing.types.length > 0) {
			return flowType(unionOfTypes(existing.types, state.declaredType), true);
		}
		return flowType(state.declaredType, true);
	}
	// First visit: walk antecedents in REVERSE order. The binder prepends
	// antecedents (addAntecedent puts new entries at the list head), so the
	// pre-loop edge — added first by `addAntecedent` BEFORE the body — ends
	// up at the LIST TAIL, while the back-edge sits at the head. To establish
	// baseline narrowing without re-entering the loop label, we must walk
	// pre-loop FIRST. Collect into an array and reverse.
	const info: FlowLoopInfo = { loopNode: flow, refKey: state.refKey, types: [] };
	let firstAnteType: FlowType = null as unknown as FlowType;
	let widened = false;
	const reversed: FlowNode[] = [];
	let cursor: FlowList | null = flow.antecedents;
	while (cursor !== null) {
		reversed.push(cursor.flow);
		cursor = cursor.next;
	}
	// Push BEFORE recursing so nested re-entries find us. The pre-loop walk
	// is acyclic relative to this loop and won't trigger re-entry; the
	// back-edge walk DOES re-enter and must see info.types populated already.
	state.flowLoopStack.push(info);
	for (let ri = reversed.length - 1; ri >= 0; ri = ri - 1) {
		const ft = getTypeAtFlowNode(state, reversed[ri]);
		if (firstAnteType === null) {
			firstAnteType = ft;
		}
		appendIfUnique(info.types, ft.t);
		if (ft.t === state.declaredType) {
			widened = true;
			break;
		}
	}
	// Pop our frame.
	state.flowLoopStack.pop();
	// If we widened to declaredType, that's the result.
	if (widened) {
		return flowType(state.declaredType, firstAnteType !== null ? firstAnteType.incomplete : false);
	}
	if (info.types.length === 0) {
		return flowType(state.declaredType, false);
	}
	const joined = unionOfTypes(info.types, state.declaredType);
	// Incomplete iff the first (non-looping) antecedent was itself incomplete.
	const incomplete = firstAnteType !== null && firstAnteType.incomplete;
	return flowType(joined, incomplete);
}

// Union a list of types with structural dedup. Single-element list returns
// the element directly (no unnecessary union wrapper).
//
// Phase 3 gap: the reference tracks a `subtypeReduction` flag — set when any
// antecedent type is not a subset of `initialType`. When true, it uses
// UnionReductionSubtype (tighter collapse); otherwise UnionReductionLiteral
// (looser). Our implementation always uses structural dedup, producing a
// potentially coarser union. This is SOUND (supertype) but less precise.
// Phase 6 can tighten once we add `initialType` and an `isSubsetOf` helper.
function joinNarrowedTypes(parent: Type | null, members: Type[]): Type {
	if (parent !== null && parent.kind === TypeKind.Union) {
		return unionPreservingDiscriminant(parent, members);
	}
	// Maybe-carried `T | null`: the halves a null-check produced (`T` on the
	// true edge, `null` on the false edge) re-join to the DECLARED carrier, the
	// way re-joining a union's constituents yields the interned union. A fresh
	// `T | null` Union here would be a second spelling of the same type that
	// no consumer recognises — the read keeps its carrier layout downstream
	// (Maybe read materialization, operator lowering both key on the carrier).
	if (parent !== null && isMaybeType(parent)) {
		let hasNull = false;
		let nonNull: Type | null = null;
		let nonNullCount: int32 = 0;
		for (const m of members) {
			if (m.kind === TypeKind.Null) { hasNull = true; continue; }
			nonNull = m;
			nonNullCount = nonNullCount + 1;
		}
		if (hasNull && nonNullCount === 1 && nonNull !== null && sameType(nonNull, unwrapMaybeType(parent))) {
			return parent;
		}
	}
	return createUnion(members);
}

export function unionOfTypes(types: Type[], parent: Type | null): Type {
	if (types.length === 0) return inferredType();
	if (types.length === 1) return types[0];
	const uniq: Type[] = [];
	for (const t of types) {
		if (t === null) continue;
		// Never is the empty/unreachable type — contributes nothing to a union.
		if (t.kind === TypeKind.Never) continue;
		let seen = false;
		for (const u of uniq) {
			if (u === t) { seen = true; break; }
		}
		if (!seen) uniq.push(t);
	}
	if (uniq.length === 0) return inferredType();
	if (uniq.length === 1) return uniq[0];
	return joinNarrowedTypes(parent, uniq);
}

// ===== narrowType dispatch =====
//
// Given the parent type `t` and the predicate expression `expr`, return `t`
// narrowed by the predicate for the reference. `assumeTrue` is flipped by
// FalseCondition edges and by unary `!`.

// Recursion depth for narrowType — bounds aliased-condition unwinding and
// mutual `&&`/`||` descent. Pathological chains stop narrowing; the caller
// keeps the parent type (sound, just imprecise).
let _narrowDepth: int32 = 0;
const NARROW_DEPTH_LIMIT: int32 = 20;

export function narrowType(t: Type | null, expr: Node | null, refNode: Node, assumeTrue: boolean): Type | null {
	if (t === null || expr === null || refNode === null) return t;
	if (_narrowDepth >= NARROW_DEPTH_LIMIT) return t;
	_narrowDepth = _narrowDepth + 1;
	const result = narrowTypeInner(t, expr, refNode, assumeTrue);
	_narrowDepth = _narrowDepth - 1;
	return result;
}

function narrowTypeInner(t: Type | null, expr: Node, refNode: Node, assumeTrue: boolean): Type | null {
	if (expr.kind === NodeKind.UnaryExpr) {
		const d = expr.data as UnaryExprData;
		if (d.unaryOp === "!") {
			return narrowType(t, d.operand, refNode, !assumeTrue);
		}
	}
	if (expr.kind === NodeKind.BinaryExpr) {
		const d = expr.data as BinaryExprData;
		if (d.operator === "===" || d.operator === "!=="
			|| d.operator === "==" || d.operator === "!=") {
			return narrowTypeByEquality(t, d.left, d.right, d.operator, refNode, assumeTrue);
		}
		// instanceof narrowing: `x instanceof Foo` narrows x to Foo (or
		// excludes Foo from a union in the falsy branch).
		if (d.operator === "instanceof") {
			return narrowTypeByInstanceof(t, d.left, d.right, refNode, assumeTrue);
		}
		// Logical && / || narrowing — full DeMorgan coverage:
		//
		// `if (a && b)`:
		//   true  → both hold: narrow by a, then by b (intersection)
		//   false → at least one fails: union of (narrow !a, narrow !b)
		//
		// `if (a || b)`:
		//   true  → at least one holds: union of (narrow a, narrow b)
		//   false → both fail: narrow by !a, then by !b (intersection)
		if (d.operator === "&&") {
			if (assumeTrue) {
				const afterLeft = narrowType(t, d.left, refNode, true);
				return narrowType(afterLeft, d.right, refNode, true);
			}
			// false branch: !(a && b) = !a || !b → union of negations.
			const withoutLeft = narrowType(t, d.left, refNode, false);
			const withoutRight = narrowType(t, d.right, refNode, false);
			if (withoutLeft === t || withoutRight === t) return t;
			if (withoutLeft === withoutRight) return withoutLeft;
			return createUnion([withoutLeft, withoutRight]);
		}
		if (d.operator === "||") {
			if (!assumeTrue) {
				const afterLeft = narrowType(t, d.left, refNode, false);
				return narrowType(afterLeft, d.right, refNode, false);
			}
			// true branch: a || b → union of positives.
			const withLeft = narrowType(t, d.left, refNode, true);
			const withRight = narrowType(t, d.right, refNode, true);
			if (withLeft === t || withRight === t) return t;
			if (withLeft === withRight) return withLeft;
			return createUnion([withLeft, withRight]);
		}
	}
	// Aliased condition: `const isX = <predicate>; if (isX) { ... }` — look up
	// the identifier's declaration. If it's a const binding initialized to a
	// condition expression, recursively narrow using that expression. Matches
	// (matches the reference's getTypeOfDottedName + narrowTypeByAliasedCondition).
	if (expr.kind === NodeKind.Identifier) {
		const aliased = getAliasedCondition(expr);
		if (aliased !== null) {
			return narrowType(t, aliased, refNode, assumeTrue);
		}
	}
	// Type predicate call: `if (isString(val)) { ... }` — if the callee is a
	// function whose resolved symbolType carries a predicate sentinel in
	// `typeExtra`, and the argument at the predicate position matches our
	// reference, narrow to (or exclude) the predicate's target type.
	if (expr.kind === NodeKind.CallExpr) {
		return narrowTypeByPredicate(t, expr, refNode, assumeTrue);
	}
	// Truthiness narrowing: bare expression used as a condition.
	// `if (x)` where x: T | null → truthy: T (null removed), falsy: null.
	// Handles both Identifier and MemberExpr via isMatchingReference.
	// Positioned as the last-resort case — aliased conditions, type
	// predicates, and equality checks all get priority above.
	if (isMatchingReference(expr, refNode)) {
		if (assumeTrue) {
			return removeNullFromType(t);
		}
		return extractNullFromType(t);
	}
	// Boolean-discriminator DU narrowing: `if (r.ok)` where r is
	// `{ ok: true, ... } | { ok: false, ... }` narrows r to the matching variant.
	// The discriminator field carries a BooleanLiteral type per variant.
	if (expr.kind === NodeKind.MemberExpr) {
		const md = expr.data as MemberExprData;
		if (isMatchingReference(md.object, refNode)) {
			return narrowTypeByBooleanDiscriminant(t, md.property, assumeTrue);
		}
	}
	return t;
}

// Narrow a discriminated union by a boolean-discriminator field's truthy/falsy state.
// `assumeTrue=true` keeps variants whose discriminator field is `true`;
// `assumeTrue=false` keeps the `false` variants. Falls through to original type
// if the union doesn't have a boolean-literal discriminant on this property.
//
// When multiple variants share the same discriminator value, returns a Union of
// all matching variants (TypeScript-parity narrowing). Single match returns the
// variant directly to avoid pointless wrapping.
function narrowTypeByBooleanDiscriminant(t: Type | null, propName: string, assumeTrue: boolean): Type | null {
	if (t === null || t.kind !== TypeKind.Union) return t;
	if (t.typeChildren === null) return t;
	const matched: Type[] = [];
	for (let i = 0; i < t.typeChildren.length; i += 1) {
		const variant = t.typeChildren[i];
		if (variant === null) return t;
		const ft = findFieldInVariant(variant, propName);
		if (ft === null) return t;
		if (ft.kind !== TypeKind.BooleanLiteral) return t;
		const variantValue = ft.typeName === "true";
		if (variantValue === assumeTrue) matched.push(variant);
	}
	if (matched.length === 0) return t;
	if (matched.length === 1) return matched[0];
	return createUnion(matched);
}

// Narrow by a type-predicate call. Reads the predicate sentinel off the
// callee's Function type (`typeExtra`): `typeName` is the predicate parameter
// name, `typeReturn` is the narrowing target type. Looks up the parameter's
// positional index in the callee type's `typeNames`, matches the argument at
// that index against `refNode`, and returns the narrowed type.
function narrowTypeByPredicate(t: Type | null, callExpr: Node, refNode: Node, assumeTrue: boolean): Type | null {
	if (t === null) return t;
	const cd = callExpr.data as CallExprData;
	const callee = cd.callee;
	if (callee === null) return t;
	const sym = callee.resolvedSym;
	if (sym === null || sym.symbolType === null) return t;
	const fnType = sym.symbolType;
	if (fnType.kind !== TypeKind.Function) return t;
	const sentinel = fnType.typeExtra;
	if (sentinel === null || sentinel.kind !== TypeKind.None) return t;
	const predicateTarget = sentinel.typeReturn;
	if (predicateTarget === null) return t;
	const paramName = sentinel.typeName;
	if (paramName === "") return t;
	// Find the positional index of the predicate parameter.
	let paramIdx: int32 = -1;
	if (fnType.typeNames !== null) {
		let pi: int32 = 0;
		while (pi < fnType.typeNames.length) {
			if (fnType.typeNames[pi] === paramName) { paramIdx = pi; break; }
			pi = pi + 1;
		}
	}
	if (paramIdx < 0 || paramIdx >= cd.arguments.length) return t;
	const predicateArg = cd.arguments[paramIdx];
	if (predicateArg === null || !isMatchingReference(predicateArg, refNode)) return t;
	// TrueCondition: narrow to the predicate target, but only if it's
	// compatible with the current type `t` (intersection semantics).
	// Returning predicateTarget for a type outside `t` would widen past
	// the declared union. Uses `typeRelation` for cross-module resilience
	// (no pointer-identity or string-key assumptions).
	if (assumeTrue) {
		if (t.kind === TypeKind.Union && t.typeChildren !== null) {
			for (const v of t.typeChildren) {
				const rel = typeRelation(predicateTarget, v);
				if (rel !== TypeRelation.None) return predicateTarget;
			}
			return t;
		}
		return predicateTarget;
	}
	// FalseCondition: remove variants assignable to the predicate target.
	if (t.kind === TypeKind.Union && t.typeChildren !== null) {
		const remaining: Type[] = [];
		for (const v of t.typeChildren) {
			const rel = typeRelation(predicateTarget, v);
			if (rel === TypeRelation.None) {
				remaining.push(v);
			}
		}
		if (remaining.length === 0) return t;
		if (remaining.length === 1) return remaining[0];
		return createUnion(remaining);
	}
	return t;
}

// ===== instanceof narrowing =====

// Narrow by `x instanceof Foo`. `left` is the tested value, `right` is the
// class/type identifier. If `left` matches our reference, resolve the RHS to
// a type and narrow accordingly: truthy → intersect with target, falsy →
// exclude target from the union.
function narrowTypeByInstanceof(t: Type | null, left: Node, right: Node, refNode: Node, assumeTrue: boolean): Type | null {
	if (t === null) return t;
	if (left === null || right === null) return t;
	if (!isMatchingReference(left, refNode)) return t;
	// Resolve the RHS to a type. The RHS is typically an Identifier referencing
	// a class — its resolvedSym.symbolType is the class/struct type.
	if (right.resolvedSym === null || right.resolvedSym.symbolType === null) return t;
	const target = right.resolvedSym.symbolType;
	if (assumeTrue) {
		// Truthy: narrow to the target type. For unions, verify target is a
		// member; for non-unions, trust the user's instanceof check.
		if (t.kind === TypeKind.Union && t.typeChildren !== null) {
			for (const v of t.typeChildren) {
				const rel = typeRelation(target, v);
				if (rel !== TypeRelation.None) return target;
			}
			return t;
		}
		return target;
	}
	// Falsy: remove the target from the union.
	if (t.kind === TypeKind.Union && t.typeChildren !== null) {
		const remaining: Type[] = [];
		for (const v of t.typeChildren) {
			const rel = typeRelation(target, v);
			if (rel === TypeRelation.None) remaining.push(v);
		}
		if (remaining.length === 0) return t;
		if (remaining.length === 1) return remaining[0];
		return createUnion(remaining);
	}
	return t;
}

// ===== Truthiness helpers =====

// Remove Null variants from a type. For unions, filters out TypeKind.Null
// members and reconstructs. For Maybe<T> wrappers (resolver collapses
// non-pointer T|null into Maybe<T>), peels to inner T. Non-union, non-null,
// non-maybe types pass through unchanged (non-nullable values aren't affected
// by truthiness narrowing).
function removeNullFromType(t: Type | null): Type | null {
	if (t === null) return t;
	if (t.kind === TypeKind.Null) return neverType();
	if (isMaybeType(t)) return unwrapMaybeType(t);
	if (t.kind !== TypeKind.Union || t.typeChildren === null) return t;
	const remaining: Type[] = [];
	for (const v of t.typeChildren) {
		if (v.kind !== TypeKind.Null) remaining.push(v);
	}
	if (remaining.length === t.typeChildren.length) return t;
	if (remaining.length === 0) return neverType();
	if (remaining.length === 1) return remaining[0];
	return createUnion(remaining);
}

// Extract the Null variant from a type. For unions, returns the Null member
// if present. For Maybe<T> wrappers, returns Null (the falsy branch in
// `if (!x)` narrows the Maybe to its absent state). Non-union/non-maybe types
// or unions without Null return t unchanged.
function extractNullFromType(t: Type | null): Type | null {
	if (t === null) return t;
	if (t.kind === TypeKind.Null) return t;
	if (isMaybeType(t)) return nullType();
	if (t.kind !== TypeKind.Union || t.typeChildren === null) return t;
	for (const v of t.typeChildren) {
		if (v.kind === TypeKind.Null) return v;
	}
	return t;
}

// narrowByAssignment — called when walking a FlowFlags.Assignment node.
// Returns the RHS type if the assignment's target matches `refNode`, else
// null. Constrains the result to a subtype of `declared` (assignment
// narrowing is always bounded by the declared type). Handles:
//   1. BinaryExpr with `=`            — `x = rhs`
//   2. VariableDecl with initializer  — `let x = rhs` / `const x = rhs`
// Compound assignments (`+=`, `-=`), UpdateExpr (`x++`, `--x`), and
// destructuring assignments fall through to `null` — the caller widens to
// `declared` by tail-recursing to the antecedent, which is the safe default.
// Hidden conversions are repr plumbing (fitNode's variant↔union wrap/project);
// the flow fact lives on the expression underneath.
function skipHiddenConv(n: Node): Node {
	let walk: Node = n;
	while (walk !== null
			&& (walk.kind === NodeKind.HiddenSubConv || walk.kind === NodeKind.HiddenStdConv)) {
		walk = (walk.data as HiddenStdConvData).convExpr;
	}
	return walk;
}

function narrowByAssignment(node: Node | null, refNode: Node, declared: Type): Type | null {
	if (node === null) return null;
	if (node.kind === NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		if (d.operator !== "=") return null;
		if (d.left === null || !isMatchingReference(d.left, refNode)) {
			return null;
		}
		const rhs = skipHiddenConv(d.right);
		if (rhs === null || rhs.nodeType === null) return null;
		return constrainToDeclared(rhs.nodeType, declared);
	}
	if (node.kind === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		const init = skipHiddenConv(d.initializer);
		if (init === null || init.nodeType === null) {
			return null;
		}
		// The reference must be an Identifier whose resolvedSym is this decl.
		if (refNode.kind !== NodeKind.Identifier) return null;
		const sym = refNode.resolvedSym;
		if (sym === null || sym.declNode !== node) return null;
		return constrainToDeclared(init.nodeType, declared);
	}
	return null;
}

// Constrain an assigned value's type to remain within the variable's declared
// bounds. Only union-declared variables get narrowed: if `rhs` is a specific
// variant of `declared`, return that variant; otherwise return `declared`
// (no narrowing). Non-union declared types fall through unchanged — we never
// tighten e.g. `Node[]` to `BinaryExpr[]` across an assignment, because
// structurally-similar arrays join to an ugly union at control flow merges.
function constrainToDeclared(rhs: Type, declared: Type): Type {
	if (rhs === null) return declared;
	if (declared === null) return rhs;
	if (declared.kind !== TypeKind.Union || declared.typeChildren === null) {
		return declared;
	}
	// Find the best-matching variant in the declared union using typeRelation.
	// This handles identity matches, named-type matches, primitive kind
	// matches, AND structural compatibility for anonymous structs — all in
	// one pass via the established comparison infrastructure.
	for (const v of declared.typeChildren) {
		if (v === rhs) return rhs;
		const rel = typeRelation(v, rhs);
		if (rel !== TypeRelation.None) return rhs;
	}
	return declared;
}

// If `idNode` resolves to a `const` declaration whose initializer is a boolean
// condition expression, return that initializer. Only `const` qualifies —
// `let`/`var` can be reassigned, so their stored initializer isn't guaranteed
// to still reflect the current value. Returns null if no alias applies.
//
// Guards against self-reference recursion via a per-reference depth counter
// in the caller (narrowType walks the alias in a stack-bounded manner;
// pathological `const a = b; const b = a` never type-checks at Pass 1).
function getAliasedCondition(idNode: Node): Node {
	const sym = idNode.resolvedSym;
	if (sym === null) return null as unknown as Node;
	const decl = sym.declNode;
	if (decl === null || decl.kind !== NodeKind.VariableDecl) {
		return null as unknown as Node;
	}
	const d = decl.data as VariableDeclData;
	if (d.declKind !== DeclKind.Const) return null as unknown as Node;
	const init = d.initializer;
	if (init === null) return null as unknown as Node;
	// Alias condition-shaped initializers:
	//   BinaryExpr: comparison (===, !==), logical (&&, ||)
	//   UnaryExpr:  negation (!)
	//   CallExpr:   type-predicate calls (`const isX = isString(val)`)
	// Bare identifiers are excluded — they'd chain (a → b → a) without
	// adding narrowing information. The depth guard in narrowType bounds
	// any residual recursion from chained aliases.
	if (init.kind === NodeKind.BinaryExpr
			|| init.kind === NodeKind.UnaryExpr
			|| init.kind === NodeKind.CallExpr) {
		return init;
	}
	return null as unknown as Node;
}

function narrowTypeByEquality(
	t: Type | null, left: Node, right: Node, op: string, refNode: Node, assumeTrue: boolean
): Type | null {
	// !== and != invert the sense
	const eff = (op === "!==" || op === "!=") ? !assumeTrue : assumeTrue;
	// Case 0: typeof narrowing. `typeof x === "string"` or `"string" === typeof x`.
	// Handled first so it doesn't fall through to discriminant matching.
	if (left !== null && isTypeofOperand(left)) {
		const inner = (left.data as UnaryExprData).operand;
		if (isMatchingReference(inner, refNode)) {
			return narrowTypeByTypeof(t, right, eff);
		}
	}
	if (right !== null && isTypeofOperand(right)) {
		const inner = (right.data as UnaryExprData).operand;
		if (isMatchingReference(inner, refNode)) {
			return narrowTypeByTypeof(t, left, eff);
		}
	}
	// Case 1: left side is a discriminant-property access on our reference.
	//   `s.kind === "circle"` — narrow s to the "circle" variant
	if (left !== null && left.kind === NodeKind.MemberExpr) {
		const md = left.data as MemberExprData;
		if (isMatchingReference(md.object, refNode)) {
			return narrowTypeByDiscriminantProperty(t, md.property, right, eff);
		}
	}
	// Case 2: symmetric (literal on left, member on right)
	if (right !== null && right.kind === NodeKind.MemberExpr) {
		const md = right.data as MemberExprData;
		if (isMatchingReference(md.object, refNode)) {
			return narrowTypeByDiscriminantProperty(t, md.property, left, eff);
		}
	}
	// Case 3: direct identifier equality
	//   `x === null` — narrow x to non-null (or null if eff = true)
	//   `x === "literal"` — narrow x to the literal type (no-op if already)
	if (left !== null && isMatchingReference(left, refNode)) {
		return narrowByLiteralEquality(t, right, eff);
	}
	if (right !== null && isMatchingReference(right, refNode)) {
		return narrowByLiteralEquality(t, left, eff);
	}
	return t;
}

// Check if a node is `typeof <something>`.
function isTypeofOperand(node: Node): boolean {
	if (node === null || node.kind !== NodeKind.UnaryExpr) return false;
	const d = node.data as UnaryExprData;
	return d.unaryOp === "typeof";
}

// Narrow a type by `typeof x === "literal"` comparison.
// `literalExpr` is the RHS (or LHS) string literal naming the type.
// `assumeTrue` is the effective sense: true → keep the matching type,
// false → exclude it (for `typeof x !== "literal"`).
function narrowTypeByTypeof(t: Type | null, literalExpr: Node, assumeTrue: boolean): Type | null {
	if (t === null || literalExpr === null) return t;
	if (literalExpr.kind !== NodeKind.StringLiteral) return t;
	const d = literalExpr.data as StringLiteralData;
	const targetKind = typeKindOfTypeofString(d.value);
	if (targetKind === TypeKind.None) return t;  // unknown typeof string, no narrow
	// For union types, filter variants by whether their kind matches.
	if (t.kind === TypeKind.Union) {
		const remaining: Type[] = [];
		let matchVariant: Type | null = null;
		if (t.typeChildren !== null) {
			for (const v of t.typeChildren) {
				if (v === null) continue;
				const isMatch = typeofStringMatches(v, d.value);
				if (isMatch) matchVariant = v;
				if (isMatch === assumeTrue) remaining.push(v);
			}
		}
		if (remaining.length === 0) return t;  // no narrowing possible
		if (remaining.length === 1) return remaining[0];
		return createUnion(remaining);
	}
	// For non-union types: if the kind matches, keep/drop based on assumeTrue.
	const matches = typeofStringMatches(t, d.value);
	if (assumeTrue) {
		return matches ? t : inferredType();
	}
	return matches ? inferredType() : t;
}

// Family match for `typeof` narrowing: "number" covers every numeric kind —
// float32/int32/... are all "number" at runtime; same for string/boolean literals.
function typeofStringMatches(v: Type, s: string): boolean {
	if (s === "string") return v.kind === TypeKind.String || v.kind === TypeKind.StringLiteral;
	if (s === "number") return isNumeric(v);
	if (s === "boolean") return v.kind === TypeKind.Boolean || v.kind === TypeKind.BooleanLiteral;
	return false;
}

// Map a `typeof` result string to the corresponding TypeKind. Phase 2 handles
// primitives; Phase 6 will add "object"/"function".
function typeKindOfTypeofString(s: string): TypeKind {
	if (s === "string") return TypeKind.String;
	if (s === "number") return TypeKind.Number;
	if (s === "boolean") return TypeKind.Boolean;
	return TypeKind.None;
}

// Narrow a discriminated-union type by a discriminant property equality.
// `propName` is the field name (e.g. "kind"); `valueExpr` is the compared
// literal; `assumeTrue` picks the matching variant (true) or excludes it.
export function narrowTypeByDiscriminantProperty(
	t: Type | null, propName: string, valueExpr: Node, assumeTrue: boolean
): Type | null {
	if (t === null || t.kind !== TypeKind.Union) return t;
	const info = detectUnionDiscriminant(t, propName);
	if (info.discField === "") return t;
	const litValue = extractLiteralString(valueExpr);
	if (litValue === "") return t;
	let variantIdx = -1;
	if (info.isStringDU) {
		variantIdx = findVariantByStringDiscriminant(t, info.discField, litValue);
	} else {
		variantIdx = findVariantByDiscriminant(t, litValue);
	}
	if (variantIdx < 0) return t;
	if (t.typeChildren === null || variantIdx >= t.typeChildren.length) return t;
	const variant = t.typeChildren[variantIdx];
	if (variant === null) return t;
	if (assumeTrue) {
		// Keep only the matching variant — narrow to that struct.
		return variant;
	}
	// assumeTrue=false: exclude this variant, keep the rest.
	const remaining: Type[] = [];
	let i = 0;
	while (i < t.typeChildren.length) {
		if (i !== variantIdx) {
			const v = t.typeChildren[i];
			if (v !== null) remaining.push(v);
		}
		i = i + 1;
	}
	if (remaining.length === 0) return t;
	if (isDiscriminatedUnion(t)) return unionPreservingDiscriminant(t, remaining);
	if (remaining.length === 1) return remaining[0];
	return createUnion(remaining);
}

// Residual union after excluding variants from a metadata-carrying DU.
// Copies the discriminant contract (`typeExtra` = disc type, `typeNames` =
// [discName, variantKey...]) so disc re-reads keep resolving and codegen's
// `_tag` route keeps firing. Match-type variants don't physically carry the
// disc field, so a bare createUnion residual would reject `n.kind` — and a
// single-variant residual must stay a 1-child union for the same reason.
function unionPreservingDiscriminant(parent: Type, remaining: Type[]): Type {
	const u = createUnion(remaining);
	if (u.kind !== TypeKind.Union) return u;
	if (parent.typeExtra === null || parent.typeNames === null
		|| parent.typeNames.length === 0 || parent.typeChildren === null) return u;
	u.typeExtra = parent.typeExtra;
	u.typeNames.push(parent.typeNames[0]);
	for (const rv of remaining) {
		for (let pi = 0; pi < parent.typeChildren.length; pi += 1) {
			if (parent.typeChildren[pi] === rv) {
				if (pi + 1 < parent.typeNames.length) u.typeNames.push(parent.typeNames[pi + 1]);
				break;
			}
		}
	}
	return u;
}

// Narrow a union type by equality to a literal. Handles:
//   - null literal: remove/keep Null member
//   - future: string, number, boolean literals
function narrowByLiteralEquality(t: Type | null, literal: Node, assumeTrue: boolean): Type | null {
	if (t === null) return t;
	if (isNullLiteral(literal)) {
		// Delegate to the shared helpers — they uniformly handle Union(T,null),
		// Maybe<T> wrappers, bare Null, and inert non-nullable types.
		// assumeTrue (=== null) keeps the null branch via extractNullFromType;
		// !assumeTrue (!== null) removes it via removeNullFromType.
		return assumeTrue ? extractNullFromType(t) : removeNullFromType(t);
	}
	// Other literal kinds: no narrowing in Phase 2 (Phase 6 adds string/number literal narrowing)
	return t;
}
