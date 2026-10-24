// src/checker/flow.ms
//
// Flow graph query layer. Consumes the FlowNode graph built by src/binder/
// and computes narrowed types for reference expressions at each program point.
//
// Phase 2 scope: non-loop cases. Loop narrowing (LoopLabel fixed-point,
// incomplete types, flowTypeCache save/restore) ships in Phase 3. Assignment
// narrowing for let-variables ships in Phase 6.

import {
	Node, NodeKind, NodeFlag, DeclKind,
	FlowNode, FlowFlag, FlowList, FlowReduceLabelData,
	Type, TypeKind,
	IdentifierData, BinaryExprData, UnaryExprData, MemberExprData, ArrayAccessData,
	StringLiteralData, NumberLiteralData, BooleanLiteralData, HiddenStdConvData,
	SwitchStmtData, SwitchCaseData, VariableDeclData, CallExprData,
	UpdateExprData, NewExprData, OutExprData, HiddenDerefData,
	ArrayLiteralData, ObjectLiteralData, SpreadExprData, SymbolFlag,
	Symbol, SymbolKind, DestructuringDeclData, MoveExprData,
	FunctionDeclData, ArrowFunctionData, FunctionExprData, MethodDeclData, ConstructorDeclData,
} from "../ast/node";
import { forEachChild } from "../ast/visitor";
import {
	createUnion, createUnionInOrder, inferredType, nullType, neverType,
	createStringLiteral, createNumberLiteral, integerLiteralName, fractionLiteralName, numberLiteralBase, isFloatType, float64Type, int32Type,
	detectUnionDiscriminant, enumMemberLiteralOf,
	findVariantByStringDiscriminant, findFieldInVariant,
	isMaybeType, unwrapMaybeType, isDiscriminatedUnion, peelTransparentInstance, holdsFalsyValue,
	nullableUnionOf, hasGenericParams, isNullableShape, symGenericParams, genericInstanceMembers,
	isAtomicRef, peelToStructOrUnion, matchUnionBehindInstance, isTypeofTag, isNumeric, isPrimitiveKindName, typeofNameMatches,
	classAncestorInstance,
} from "./types";
import { typeRelation, TypeRelation, sameType, findVariantByEnumMember } from "./compat";
import { parseNumberLiteral } from "../utils/string";
import { isMutatingArrayMethod } from "./paramMutationAnalysis";

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
	types: Type[];
}

export interface FlowState {
	reference: Node;                 // the reference expression whose type we're computing
	declaredType: Type;              // the declared (pre-narrowing) type of the reference
	depth: int32;                    // recursion guard; TypeScript caps at 2000
	sharedFlows: SharedFlowEntry[];  // per-query Shared-flow cache
	flowLoopStack: FlowLoopInfo[];   // in-progress loop analyses (re-entry detection)
	reduceLabels: FlowReduceLabelData[];
	// Phase 6 deferred fields (not yet used):
	//   - initialType: Type — distinguish declaredType (widened) from
	//     initialType (usually equal, but differs for parameters with init
	//     expressions). Needed when let-variable narrowing lands in Phase 6.
}

function createFlowState(refNode: Node, declaredType: Type): FlowState {
	return {
		reference: refNode,
		declaredType: declaredType,
		depth: 0,
		sharedFlows: [],
		flowLoopStack: [],
		reduceLabels: [],
	};
}

function isDottedReference(node: Node | null): boolean {
	if (node == null) return false;
	if (node.kind == NodeKind.Identifier) return true;
	if (node.kind == NodeKind.MemberExpr) return isDottedReference((node.data as MemberExprData).object);
	return false;
}

// The FlowLoopInfo on the stack for this loopNode that already holds a type.
// Used to detect re-entry during back-edge recursion.
function findPopulatedLoopInfo(stack: FlowLoopInfo[], loopNode: FlowNode): FlowLoopInfo {
	let i = 0;
	while (i < stack.length) {
		const info = stack[i];
		if (info.loopNode == loopNode && info.types.length > 0) return info;
		i = i + 1;
	}
	return null as unknown as FlowLoopInfo;
}

// Append a type to a list only if it's not already present (structural dedup).
// Used to keep the per-loop antecedent set bounded.
function appendIfUnique(types: Type[], t: Type | null): void {
	if (t == null) return;
	for (const u of types) {
		if (u == t) return;
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

function skipReferenceHidden(n: Node): Node {
	let walk: Node = n;
	while (walk.kind == NodeKind.HiddenDeref || walk.kind == NodeKind.HiddenAddr || walk.kind == NodeKind.HiddenSubConv) {
		walk = walk.kind == NodeKind.HiddenSubConv ? (walk.data as HiddenStdConvData).convExpr : (walk.data as { expr: Node }).expr;
	}
	return walk;
}

function isMatchingReference(source: Node, target: Node): boolean {
	if (source == null || target == null) return false;
	// Unwrap checker-inserted hidden conversions. The condition expression is
	// stored at bind time (no HiddenDeref); the access in the body has been
	// rewritten by the checker to wrap reference-typed reads in HiddenDeref
	// so codegen knows to deref the pointer. Without unwrapping, the structural
	// comparison fails between the bind-time condition and check-time access.
	source = skipReferenceHidden(source);
	target = skipReferenceHidden(target);
	if (source == target) return true;
	if (source.kind != target.kind) return false;
	match (source.kind) {
		NodeKind.Identifier => {
			if (source.resolvedSym == null || target.resolvedSym == null) {
				return false;
			}
			return source.resolvedSym == target.resolvedSym;
		},
		NodeKind.MemberExpr => {
			const sd = source.data as MemberExprData;
			const td = target.data as MemberExprData;
			if (sd.property != td.property) return false;
			return isMatchingReference(sd.object, td.object);
		},
		NodeKind.ArrayAccess => {
			// `xs[0].ok` narrowing `xs[0]`: same base reference AND a
			// structurally-identical index (equal literal, or the same symbol).
			// Anything less conservative (computed indexes) would need effect
			// analysis between the condition and the read — refuse instead.
			const sd = source.data as ArrayAccessData;
			const td = target.data as ArrayAccessData;
			if (!isMatchingIndex(sd.index, td.index)) return false;
			return isMatchingReference(sd.array, td.array);
		},
		_ => { return false; },
	};
	return false;
}

// Index equality for ArrayAccess reference matching. Only provably-stable
// indexes qualify: identical number/string literals, or the same symbol on
// both sides (its re-assignment invalidates the narrowing through the normal
// Assignment mutation path).
function isMatchingIndex(a: Node | null, b: Node | null): boolean {
	if (a == null || b == null) return false;
	if (a.kind != b.kind) return false;
	match (a.kind) {
		NodeKind.NumberLiteral => {
			const ad = a.data as NumberLiteralData;
			const bd = b.data as NumberLiteralData;
			return ad.value == bd.value;
		},
		NodeKind.StringLiteral => {
			const ad = a.data as StringLiteralData;
			const bd = b.data as StringLiteralData;
			return ad.value == bd.value;
		},
		NodeKind.Identifier => {
			if (a.resolvedSym == null || b.resolvedSym == null) return false;
			return a.resolvedSym == b.resolvedSym;
		},
		_ => { return false; },
	};
	return false;
}

// ===== Literal value extraction =====
//
// To compare `x.kind === "circle"` against union variants, read the literal
// value the compared expression denotes: a string literal, or a string-literal
// type the checker gave it.

function stringLiteralValueOf(node: Node): string | null {
	if (node == null) return null;
	if (node.kind == NodeKind.StringLiteral) return (node.data as StringLiteralData).value;
	return node.nodeType != null && node.nodeType.kind == TypeKind.StringLiteral ? node.nodeType.typeName : null;
}

function isNullLiteral(node: Node): boolean {
	if (node == null) return false;
	return node.kind == NodeKind.NullLiteral;
}

// ===== Entry point =====

export function getFlowTypeOfReference(refNode: Node, declaredType: Type): Type {
	if (refNode == null) return declaredType;
	if (declaredType == null) return declaredType;
	const flow = refNode.flowNode;
	if (flow == null) return declaredType;
	const base = matchUnionBehindInstance(declaredType);
	const state = createFlowState(refNode, base);
	if (endsInNeverCall(flow)) return declaredType;
	const ft = getTypeAtFlowNode(state, flow);
	const t = ft.t;
	if (t == null || t == base || (base != declaredType && holdsEveryMember(t, base))) return declaredType;
	return t;
}

function holdsEveryMember(t: Type, whole: Type): boolean {
	if (t.kind != TypeKind.Union || t.typeChildren == null || t.typeChildren.length != whole.typeChildren.length) return false;
	for (const member of whole.typeChildren) {
		if (!t.typeChildren.includes(member)) return false;
	}
	return true;
}

function endsInNeverCall(flow: FlowNode | null): boolean {
	let current = flow;
	while (current != null) {
		const flags = current.flags;
		if (flags.has(FlowFlag.Unreachable)) return false;
		if (flags.has(FlowFlag.Call) && callNeverReturns(current.node)) return true;
		if (flags.has(FlowFlag.Start) || flags.has(FlowFlag.BranchLabel) || flags.has(FlowFlag.LoopLabel)
				|| flags.has(FlowFlag.SwitchClause) || flags.has(FlowFlag.ReduceLabel)) return false;
		current = current.antecedent;
	}
	return false;
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
	if (refNode == null || refNode.flowNode == null) return false;
	const state = createFlowState(refNode, nullType());
	return walkForNonNullCheck(state, refNode.flowNode, refNode);
}

// Walks back from `flow` looking for a dominating `ref !== null` TrueCondition
// (or equivalent). Returns true iff such a condition exists on the path.
function walkForNonNullCheck(state: FlowState, flow: FlowNode | null, refNode: Node): boolean {
	if (state.depth == 2000) return false;
	state.depth = state.depth + 1;
	let current: FlowNode | null = flow;
	let result = false;
	while (true) {
		if (current == null) { result = false; break; }
		const flags = current.flags;
		if (flags.has(FlowFlag.Unreachable)) { result = false; break; }
		if (flags.has(FlowFlag.Start)) { result = false; break; }
		if ((flags.has(FlowFlag.TrueCondition) || flags.has(FlowFlag.FalseCondition))) {
			const assumeTrue = flags.has(FlowFlag.TrueCondition);
			if (isNonNullCheckForRef(current.node, refNode, assumeTrue)) {
				result = true;
				break;
			}
			current = current.antecedent;
			continue;
		}
		if (flags.has(FlowFlag.ReduceLabel)) {
			state.reduceLabels.push(current.reduceLabelData!);
			result = walkForNonNullCheck(state, current.antecedent, refNode);
			state.reduceLabels.pop();
			break;
		}
		if (flags.has(FlowFlag.BranchLabel)) {
			// All antecedents must prove non-null for the join to be non-null.
			let list: FlowList | null = branchLabelAntecedents(state.reduceLabels, current);
			let allNonNull = list != null;
			while (list != null) {
				if (!walkForNonNullCheck(state, list.flow, refNode)) {
					allNonNull = false;
					break;
				}
				list = list.next;
			}
			result = allNonNull;
			break;
		}
		if (flags.has(FlowFlag.LoopLabel)) {
			// Conservative: loop narrowing for Ref null is Phase 6+.
			result = false;
			break;
		}
		// Assignment / ArrayMutation / Call / SwitchClause /
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
	if (expr == null) return false;
	if (expr.kind == NodeKind.UnaryExpr) {
		const d = expr.data as UnaryExprData;
		if (d.unaryOp == "!") return isNonNullCheckForRef(d.operand, refNode, !assumeTrue);
	}
	if (expr.kind != NodeKind.BinaryExpr) return false;
	const d = expr.data as BinaryExprData;
	// && in a TrueCondition: both sides must be true
	if (d.operator == "&&" && assumeTrue) {
		return isNonNullCheckForRef(d.left, refNode, true)
			|| isNonNullCheckForRef(d.right, refNode, true);
	}
	// Equality comparisons with null
	if (d.operator == "!==" || d.operator == "===" || d.operator == "!=" || d.operator == "==") {
		const wantNotNull = ((d.operator == "!==" || d.operator == "!=") && assumeTrue)
			|| ((d.operator == "===" || d.operator == "==") && !assumeTrue);
		if (!wantNotNull) return false;
		if (d.left != null && d.right != null && d.left.kind == NodeKind.NullLiteral) {
			return isMatchingReference(d.right, refNode);
		}
		if (d.left != null && d.right != null && d.right.kind == NodeKind.NullLiteral) {
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
	if (state.depth == 2000) return flowType(state.declaredType, false);
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
		if (current == null) {
			result = flowType(state.declaredType, false);
			break;
		}
		const flags = current.flags;
		// Per-query Shared-flow cache check. Only the FIRST shared flow we
		// encounter on this walk becomes the cache key; nested shared flows
		// within the same walk fall through to normal processing.
		if (flags.has(FlowFlag.Shared) && sharedFlow == null) {
			const cached = lookupSharedFlow(state, current);
			if (cached != null) {
				result = cached;
				break;
			}
			// Only stake a cache claim on a clean walk (no pending narrowings
			// above this node) — otherwise the committed type would wrongly
			// include narrowings that belong above the shared node.
			if (pending.length == 0) sharedFlow = current;
		}
		if (flags.has(FlowFlag.Unreachable)) {
			// Dead code — no narrowing, return declared type.
			result = flowType(state.declaredType, false);
			break;
		}
		if (flags.has(FlowFlag.Start)) {
			const created = capturedFlowAt(state.reference, current.node);
			if (created != null) {
				current = created;
				continue;
			}
			result = flowType(state.declaredType, false);
			break;
		}
		if (flags.has(FlowFlag.Assignment)) {
			// Phase 6: narrow to the RHS type when the assignment's target
			// matches our reference. Variable declarations with initializers
			// count (the declNode IS the assignment source).
			const narrowed = narrowByAssignment(current.node, state.reference, state.declaredType);
			if (narrowed != null) {
				const parent = getTypeAtFlowNode(state, current.antecedent);
				result = flowType(narrowed, parent.incomplete);
				break;
			}
			current = current.antecedent;
			continue;
		}
		if (flags.has(FlowFlag.ArrayMutation)) {
			// Evolving arrays (Phase 6+). Phase 2: tail-recurse.
			current = current.antecedent;
			continue;
		}
		if (flags.has(FlowFlag.Call)) {
			if (callWritesInto(current.node, state.reference)) {
				result = flowType(state.declaredType, false);
				break;
			}
			current = current.antecedent;
			continue;
		}
		if ((flags.has(FlowFlag.TrueCondition) || flags.has(FlowFlag.FalseCondition))) {
			// Linear (single-antecedent) narrowing — collect and keep walking
			// iteratively instead of recursing, so deep condition chains don't
			// grow the call stack. Drained post-loop below.
			pending.push(current);
			current = current.antecedent;
			continue;
		}
		if (flags.has(FlowFlag.SwitchClause)) {
			result = getTypeAtSwitchClause(state, current);
			break;
		}
		if (flags.has(FlowFlag.BranchLabel)) {
			// Single-antecedent branch label is not a real merge — walk through
			// it iteratively (mirrors TS getTypeAtFlowNode) so a long chain of
			// sequential `if`s doesn't grow the call stack. Real merges (2+
			// antecedents) still recurse into getTypeAtBranchLabel.
			const ants = branchLabelAntecedents(state.reduceLabels, current);
			if (ants != null && ants.next == null) {
				current = ants.flow;
				continue;
			}
			// Per-query memo: without it, a query at the end of N sequential
			// narrowing `if`s re-walks BOTH antecedents at every label —
			// 2^N recursion (a 50-statement chain never finished). getTypeAtFlowNode
			// is a pure function of (state, node), so the first result per label
			// is final. Same cache list as the Shared-flow memo.
			const cachedLabel = lookupSharedFlow(state, current);
			if (cachedLabel != null) {
				result = cachedLabel;
				break;
			}
			result = getTypeAtBranchLabel(state, ants);
			cacheSharedFlow(state, current, result);
			break;
		}
		if (flags.has(FlowFlag.LoopLabel)) {
			// Single-antecedent loop label (no back-edge) is likewise a
			// pass-through — iterate instead of entering the fixed-point.
			const ants = current.antecedents;
			if (ants != null && ants.next == null) {
				current = ants.flow;
				continue;
			}
			// Phase 3: fixed-point via per-query loop stack.
			result = getTypeAtFlowLoopLabel(state, current);
			break;
		}
		if (flags.has(FlowFlag.ReduceLabel)) {
			const outerMemo = state.sharedFlows;
			state.sharedFlows = [];
			state.reduceLabels.push(current.reduceLabelData!);
			result = getTypeAtFlowNode(state, current.antecedent);
			state.reduceLabels.pop();
			state.sharedFlows = outerMemo;
			break;
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
		const assumeTrue = cnode.flags.has(FlowFlag.TrueCondition);
		const narrowed = narrowType(result.t, cnode.node, state.reference, assumeTrue);
		result = flowType(narrowed, result.incomplete);
		pi = pi - 1;
	}
	// Commit shared-flow cache entry if we staked a claim on entry.
	if (sharedFlow != null) {
		cacheSharedFlow(state, sharedFlow, result);
	}
	state.depth = state.depth - 1;
	return result;
}

// Shared-flow cache lookup: linear scan by FlowNode identity — per-query N is typically < 20.
function lookupSharedFlow(state: FlowState, flow: FlowNode): FlowType {
	for (const entry of state.sharedFlows) {
		if (entry.flow == flow) return entry.ft;
	}
	return null as unknown as FlowType;
}

function cacheSharedFlow(state: FlowState, flow: FlowNode, ft: FlowType): void {
	// Overwrite any existing entry for this flow (the result may improve
	// after back-edge fixed-point analysis completes).
	for (const entry of state.sharedFlows) {
		if (entry.flow == flow) {
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
	if (clauseData == null) return parent;
	const switchStmt = clauseData.switchStatement;
	if (switchStmt == null) return parent;
	const sd = switchStmt.data as SwitchStmtData;
	const disc = sd.switchDisc;
	if (disc == null) return parent;
	// We only narrow if the discriminant is a MemberExpr on our reference.
	// Simple `switch (x)` on an identifier (not a MemberExpr) could still
	// narrow `x` itself, but that's the truthiness/literal-equality case —
	// Phase 6 territory.
	if (isTypeofOperand(disc)) {
		if (!isMatchingReference((disc.data as UnaryExprData).operand, state.reference) || parent.t == null) return parent;
		return flowType(narrowTypeBySwitchOnTypeof(parent.t, sd, clauseData.clauseStart, clauseData.clauseEnd), parent.incomplete);
	}
	if (disc.kind != NodeKind.MemberExpr) return parent;
	const md = disc.data as MemberExprData;
	if (!isMatchingReference(md.object, state.reference)) return parent;
	// Collect the case-test values in the clause range. Each SwitchCaseData
	// may contain multiple caseTests (fall-through `case "a": case "b":`) —
	// all those tests produce the same narrowed body.
	let narrowed: Type | null = null;
	let anyDefault = false;
	const lo: int32 = clauseData.clauseStart;
	const hi: int32 = clauseData.clauseEnd;
	if (sd.switchCases == null) return parent;
	let ci: int32 = lo;
	while (ci < hi && ci < sd.switchCases.length) {
		const caseNode = sd.switchCases[ci];
		if (caseNode == null) { ci = ci + 1; continue; }
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
			if (filtered != null && filtered != parent.t) {
				// Union accumulated narrowed types.
				if (narrowed == null) {
					narrowed = filtered;
				} else if (narrowed != filtered) {
					narrowed = createUnion([narrowed, filtered]);
				}
			}
			ti = ti + 1;
		}
		ci = ci + 1;
	}
	// Default clause: no positive narrowing in Phase 2. Return parent unchanged.
	// Phase 6 will negate the covered cases to produce the correct remainder.
	if (anyDefault || narrowed == null) return parent;
	return flowType(narrowed, parent.incomplete);
}

// A case narrows by its own tests; a default narrows by excluding every other case.
function narrowTypeBySwitchOnTypeof(t: Type, sd: SwitchStmtData, clauseStart: int32, clauseEnd: int32): Type {
	let hasDefault = false;
	for (let ci = clauseStart; ci < clauseEnd && ci < sd.switchCases.length; ci += 1) {
		if ((sd.switchCases[ci].data as SwitchCaseData).isDefault) hasDefault = true;
	}
	if (hasDefault) {
		let rest: Type = t;
		for (let ci = 0; ci < sd.switchCases.length; ci += 1) {
			if (ci >= clauseStart && ci < clauseEnd) continue;
			for (const test of (sd.switchCases[ci].data as SwitchCaseData).caseTests) {
				const narrowed = narrowTypeByTypeof(rest, test, false);
				if (narrowed != null) rest = narrowed;
			}
		}
		return rest;
	}
	const kept: Type[] = [];
	for (let ci = clauseStart; ci < clauseEnd && ci < sd.switchCases.length; ci += 1) {
		for (const test of (sd.switchCases[ci].data as SwitchCaseData).caseTests) {
			const narrowed = narrowTypeByTypeof(t, test, true);
			if (narrowed != null && narrowed.kind != TypeKind.Never) kept.push(narrowed);
		}
	}
	if (kept.length == 0) return t;
	return unionOfTypes(kept, t);
}

// ===== Branch label joining =====
//
// Union the flow types produced by each antecedent. Fast path: if any
// antecedent's type matches the declared type, the join is just the
// declared type (the narrowing from other branches is irrelevant because a
// superset dominates).

function branchLabelAntecedents(reduceLabels: FlowReduceLabelData[], flow: FlowNode): FlowList | null {
	for (let i = reduceLabels.length - 1; i >= 0; i -= 1) {
		if (reduceLabels[i].target == flow) return reduceLabels[i].antecedents;
	}
	return flow.antecedents;
}

function getTypeAtBranchLabel(state: FlowState, antecedentList: FlowList | null): FlowType {
	const antecedents: Type[] = [];
	let anyIncomplete = false;
	let subtypeReduction = false;
	let list: FlowList | null = antecedentList;
	while (list != null) {
		// Skip Unreachable antecedents — they represent dead-code paths
		// (e.g. the then-branch of `if (x === null) return;`) and contribute
		// no information to the join. Including them broke the fast-path below:
		// Unreachable returns declaredType, which short-circuited the join and
		// erased real narrowing from sibling branches.
		if (list.flow.flags.has(FlowFlag.Unreachable) || endsInNeverCall(list.flow)) {
			list = list.next;
			continue;
		}
		const ft = getTypeAtFlowNode(state, list.flow);
		if (ft.incomplete) anyIncomplete = true;
		// Fast path: declared type in antecedents = declared type result.
		if (ft.t == state.declaredType) {
			return flowType(state.declaredType, anyIncomplete);
		}
		const at = ft.t;
		antecedents.push(at!);
		if (!isSubsetOfDeclared(at!, state.declaredType)) subtypeReduction = true;
		list = list.next;
	}
	if (antecedents.length == 0) {
		return flowType(state.declaredType, false);
	}
	if (antecedents.length == 1) {
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
		if (a == null) continue;
		if (a.kind == TypeKind.Never) continue;
		let seen = false;
		for (const u of uniq) {
			if (u == a) { seen = true; break; }
			if (sameType(u, a)) { seen = true; break; }
		}
		if (!seen) uniq.push(a);
	}
	const joined = subtypeReduction ? withoutSubclasses(uniq) : uniq;
	if (joined.length == 0) return flowType(state.declaredType, anyIncomplete);
	if (joined.length == 1) return flowType(joined[0], anyIncomplete);
	return flowType(joinNarrowedTypes(state.declaredType, joined), anyIncomplete);
}

function declaredMembers(declared: Type): Type[] {
	if (declared.kind == TypeKind.Union) return declared.typeChildren;
	if (isMaybeType(declared) && declared.typeReturn != null) return [declared.typeReturn!, nullType()];
	return [declared];
}

function isSubsetOfDeclared(t: Type, declared: Type | null): boolean {
	if (declared == null || t == declared || sameType(t, declared)) return true;
	const members = declaredMembers(declared);
	for (const part of declaredMembers(t)) {
		let found = false;
		for (const m of members) {
			if (m == part || sameType(m, part)) { found = true; break; }
		}
		if (!found) return false;
	}
	return true;
}

function withoutSubclasses(types: Type[]): Type[] {
	const flat: Type[] = [];
	for (const t of types) {
		for (const m of declaredMembers(t)) appendIfUnique(flat, m);
	}
	const kept: Type[] = [];
	for (const t of flat) {
		let covered = false;
		for (const other of flat) {
			if (other != t && classAncestorInstance(t, other) != null) { covered = true; break; }
		}
		if (!covered) kept.push(t);
	}
	return kept.length == flat.length ? types : kept;
}

// ===== Loop label fixed-point =====
//
// `while (x.kind === "circle") { ... }` requires a fixed-point over the
// back-edges. The binder guarantees the FIRST antecedent of a LoopLabel is
// the pre-loop flow (non-looping path); subsequent antecedents are the loop
// back-edges (e.g., the end of the body, `continue` jumps).
//
// Algorithm:
//   1. If we're already analyzing this loopNode — i.e., the
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
	// Non-dotted references can't be meaningfully narrowed across loops —
	// conservatively return declared type.
	if (!isDottedReference(state.reference)) {
		return flowType(state.declaredType, false);
	}
	// Re-entry detection: if this loopNode is already on the
	// stack, return the current accumulated union.
	const existing = findPopulatedLoopInfo(state.flowLoopStack, flow);
	if (existing != null) {
		return flowType(unionOfTypes(existing.types, state.declaredType), true);
	}
	// First visit: walk antecedents in REVERSE order. The binder prepends
	// antecedents (addAntecedent puts new entries at the list head), so the
	// pre-loop edge — added first by `addAntecedent` BEFORE the body — ends
	// up at the LIST TAIL, while the back-edge sits at the head. To establish
	// baseline narrowing without re-entering the loop label, we must walk
	// pre-loop FIRST. Collect into an array and reverse.
	const info: FlowLoopInfo = { loopNode: flow, types: [] };
	let firstAnteType: FlowType = null as unknown as FlowType;
	let widened = false;
	let subtypeReduction = false;
	const reversed: FlowNode[] = [];
	let cursor: FlowList | null = flow.antecedents;
	while (cursor != null) {
		reversed.push(cursor.flow);
		cursor = cursor.next;
	}
	// Push BEFORE recursing so nested re-entries find us. The pre-loop walk
	// is acyclic relative to this loop and won't trigger re-entry; the
	// back-edge walk DOES re-enter and must see info.types populated already.
	state.flowLoopStack.push(info);
	for (let ri = reversed.length - 1; ri >= 0; ri = ri - 1) {
		if (reversed[ri].flags.has(FlowFlag.Unreachable) || endsInNeverCall(reversed[ri])) continue;
		const ft = getTypeAtFlowNode(state, reversed[ri]);
		if (firstAnteType == null) {
			firstAnteType = ft;
		}
		appendIfUnique(info.types, ft.t);
		if (ft.t != null && !isSubsetOfDeclared(ft.t, state.declaredType)) subtypeReduction = true;
		if (ft.t == state.declaredType) {
			widened = true;
			break;
		}
	}
	// Pop our frame.
	state.flowLoopStack.pop();
	// If we widened to declaredType, that's the result.
	if (widened) {
		return flowType(state.declaredType, firstAnteType != null ? firstAnteType.incomplete : false);
	}
	if (info.types.length == 0) {
		return flowType(state.declaredType, false);
	}
	const joined = unionOfTypes(subtypeReduction ? withoutSubclasses(info.types) : info.types, state.declaredType);
	// Incomplete iff the first (non-looping) antecedent was itself incomplete.
	const incomplete = firstAnteType != null && firstAnteType.incomplete;
	return flowType(joined, incomplete);
}

// Union a list of types with structural dedup. Single-element list returns
// the element directly (no unnecessary union wrapper).

// ===== Nullable join canonicalization =====
//
// THE single oracle for "a join whose members include null". Both join paths
// use it — `joinBranchTypes` (fit.ms, expression branches) and
// `joinNarrowedTypes` below (flow merges) — so a nullable produced by either
// route lands on the SAME canonical type object. Two dedup loops with their own
// rules is exactly what guard/ptrFirstRefJoinNullUnion.ms exists to forbid.
//
// Canonical means a value-typed `T | null` re-enters `createMaybeType`, whose
// cache hands back the interned carrier the declaration already uses. A bare
// `createUnion([T, null])` would be a second spelling of the declared type that
// no consumer recognises (Maybe read materialization and operator lowering both
// key on the carrier).

function isNonOwningPointerKind(k: TypeKind): boolean {
	return k == TypeKind.Ptr || k == TypeKind.Cursor;
}

export function isPointerKindJoinPair(a: Type, b: Type): boolean {
	if (a == null || b == null) return false;
	const cross = (a.kind == TypeKind.Ref && isNonOwningPointerKind(b.kind))
		|| (isNonOwningPointerKind(a.kind) && b.kind == TypeKind.Ref)
		|| (isNonOwningPointerKind(a.kind) && isNonOwningPointerKind(b.kind) && a.kind != b.kind);
	if (!cross) return false;
	if (isAtomicRef(a) || isAtomicRef(b)) return false;
	if (a.typeReturn == null || b.typeReturn == null) return false;
	const pa = peelToStructOrUnion(a);
	const pb = peelToStructOrUnion(b);
	if (pa == null || pb == null) return false;
	if (pa.kind != TypeKind.Struct && pa.kind != TypeKind.Union) return false;
	return pa == pb || sameType(pa, pb);
}

export function joinedPointerMember(existing: Type, incoming: Type): Type {
	return isNonOwningPointerKind(existing.kind) && incoming.kind == TypeKind.Ref ? incoming : existing;
}

export function canonicalizeBranchJoin(t: Type): Type {
	if (t == null || t.kind != TypeKind.Union) return t;
	let sawNull = false;
	const nonNull: Type[] = [];
	for (const m of t.typeChildren) {
		if (m == null) continue;
		if (m.kind == TypeKind.Null) { sawNull = true; continue; }
		let member = m;
		if (isMaybeType(m) && m.typeReturn != null) {
			sawNull = true;
			member = m.typeReturn;
		}
		let dup = false;
		for (let pi = 0; pi < nonNull.length; pi++) {
			const p = nonNull[pi];
			if (p == member || sameType(p, member)) { dup = true; break; }
			if (isPointerKindJoinPair(p, member)) {
				nonNull[pi] = joinedPointerMember(p, member);
				dup = true;
				break;
			}
		}
		if (!dup) nonNull.push(member);
	}
	if (!sawNull) return t;
	const rebuilt: Type[] = [];
	let generic = false;
	for (const m of nonNull) {
		rebuilt.push(m);
		if (hasGenericParams(m)) generic = true;
	}
	rebuilt.push(nullType());
	if (generic) return createUnion(rebuilt);
	return nullableUnionOf(rebuilt);
}

function joinNarrowedTypes(parent: Type | null, members: Type[]): Type {
	if (parent != null && parent.kind == TypeKind.Union) {
		return unionPreservingDiscriminant(parent, members);
	}
	// A merge of a nullable's narrowed halves (`T` on the true edge, `null` on
	// the false edge) rebuilds the DECLARED type, not a fresh spelling of it.
	return canonicalizeBranchJoin(createUnion(members));
}

export function unionOfTypes(types: Type[], parent: Type | null): Type {
	if (types.length == 0) return inferredType();
	if (types.length == 1) return types[0];
	const uniq: Type[] = [];
	for (const t of types) {
		if (t == null) continue;
		// Never is the empty/unreachable type — contributes nothing to a union.
		if (t.kind == TypeKind.Never) continue;
		let seen = false;
		for (const u of uniq) {
			if (u == t) { seen = true; break; }
		}
		if (!seen) uniq.push(t);
	}
	if (uniq.length == 0) return inferredType();
	if (uniq.length == 1) return uniq[0];
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
	if (t == null || expr == null || refNode == null) return t;
	if (_narrowDepth >= NARROW_DEPTH_LIMIT) return t;
	_narrowDepth = _narrowDepth + 1;
	const peeled = peelTransparentInstance(t);
	const result = narrowTypeInner(peeled, expr, refNode, assumeTrue);
	_narrowDepth = _narrowDepth - 1;
	return result == peeled ? t : result;
}

function narrowTypeInner(t: Type | null, expr: Node, refNode: Node, assumeTrue: boolean): Type | null {
	if (expr.kind == NodeKind.UnaryExpr) {
		const d = expr.data as UnaryExprData;
		if (d.unaryOp == "!") {
			return narrowType(t, d.operand, refNode, !assumeTrue);
		}
	}
	if (expr.kind == NodeKind.BinaryExpr) {
		const d = expr.data as BinaryExprData;
		if (d.operator == "===" || d.operator == "!=="
			|| d.operator == "==" || d.operator == "!=") {
			return narrowTypeByEquality(t, d.left, d.right, d.operator, refNode, assumeTrue);
		}
		// instanceof narrowing: `x instanceof Foo` narrows x to Foo (or
		// excludes Foo from a union in the falsy branch).
		if (d.operator == "instanceof") {
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
		if (d.operator == "&&") {
			if (assumeTrue) {
				const afterLeft = narrowType(t, d.left, refNode, true);
				return narrowType(afterLeft, d.right, refNode, true);
			}
			// false branch: !(a && b) = !a || !b → union of negations.
			const withoutLeft = narrowType(t, d.left, refNode, false);
			const withoutRight = narrowType(t, d.right, refNode, false);
			if (withoutLeft == null || withoutRight == null || withoutLeft == t || withoutRight == t) return t;
			if (withoutLeft == withoutRight) return withoutLeft;
			return createUnion([withoutLeft, withoutRight]);
		}
		if (d.operator == "||") {
			if (!assumeTrue) {
				const afterLeft = narrowType(t, d.left, refNode, false);
				return narrowType(afterLeft, d.right, refNode, false);
			}
			// true branch: a || b → union of positives.
			const withLeft = narrowType(t, d.left, refNode, true);
			const withRight = narrowType(t, d.right, refNode, true);
			if (withLeft == null || withRight == null || withLeft == t || withRight == t) return t;
			if (withLeft == withRight) return withLeft;
			return createUnion([withLeft, withRight]);
		}
	}
	// Aliased condition: `const isX = <predicate>; if (isX) { ... }` — look up
	// the identifier's declaration. If it's a const binding initialized to a
	// condition expression, recursively narrow using that expression. Matches
	// (matches the reference's getTypeOfDottedName + narrowTypeByAliasedCondition).
	if (expr.kind == NodeKind.Identifier && !isMatchingReference(expr, refNode)) {
		const aliased = getAliasedCondition(expr);
		if (aliased != null && aliasStillHolds(expr, refNode)) {
			return narrowType(t, aliased, refNode, assumeTrue);
		}
	}
	// Type predicate call: `if (isString(val)) { ... }` — if the callee is a
	// function whose resolved symbolType carries a predicate sentinel in
	// `typeExtra`, and the argument at the predicate position matches our
	// reference, narrow to (or exclude) the predicate's target type.
	if (expr.kind == NodeKind.CallExpr) {
		const cd = expr.data as CallExprData;
		if (isSynthesizedNullableEquality(cd)) {
			return narrowTypeByEquality(t, skipHiddenConv(cd.arguments[0]), skipHiddenConv(cd.arguments[1]), "===", refNode, assumeTrue);
		}
		return narrowTypeByPredicate(t, expr, refNode, assumeTrue);
	}
	// Truthiness narrowing: bare expression used as a condition.
	// `if (x)` where x: T | null → truthy: T (null removed), falsy: null plus
	// every member that has a falsy value (0, NaN, "", false, 0n).
	// Handles both Identifier and MemberExpr via isMatchingReference.
	// Positioned as the last-resort case — aliased conditions, type
	// predicates, and equality checks all get priority above.
	if (isMatchingReference(expr, refNode)) {
		if (assumeTrue) {
			return removeNullFromType(t);
		}
		return narrowToFalsy(t);
	}
	// Boolean-discriminator DU narrowing: `if (r.ok)` where r is
	// `{ ok: true, ... } | { ok: false, ... }` narrows r to the matching variant.
	// The discriminator field carries a BooleanLiteral type per variant.
	if (expr.kind == NodeKind.MemberExpr) {
		const md = expr.data as MemberExprData;
		if (isMatchingReference(md.object, refNode)) {
			return narrowTypeByBooleanDiscriminant(t, md.property, assumeTrue);
		}
	}
	return t;
}

function isSynthesizedNullableEquality(cd: CallExprData): boolean {
	const callee = cd.callee;
	return callee.kind == NodeKind.Identifier && callee.flags.has(NodeFlag.BoundSym)
		&& (callee.data as IdentifierData).name == "nullableEquals" && cd.arguments.length == 2;
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
	if (t == null || t.kind != TypeKind.Union) return t;
	if (t.typeChildren == null) return t;
	const matched: Type[] = [];
	for (let i = 0; i < t.typeChildren.length; i += 1) {
		const variant = t.typeChildren[i];
		if (variant == null) return t;
		const ft = findFieldInVariant(variant, propName);
		if (ft == null) return t;
		if (ft.kind != TypeKind.BooleanLiteral) return t;
		const variantValue = ft.typeName == "true";
		if (variantValue == assumeTrue) matched.push(variant);
	}
	if (matched.length == 0) return t;
	if (matched.length == 1) return matched[0];
	return createUnion(matched);
}

// Narrow by a type-predicate call. Reads the predicate sentinel off the
// callee's Function type (`typeExtra`): `typeName` is the predicate parameter
// name, `typeReturn` is the narrowing target type. Looks up the parameter's
// positional index in the callee type's `typeNames`, matches the argument at
// that index against `refNode`, and returns the narrowed type.
function narrowTypeByPredicate(t: Type | null, callExpr: Node, refNode: Node, assumeTrue: boolean): Type | null {
	if (t == null) return t;
	const cd = callExpr.data as CallExprData;
	const callee = cd.callee;
	if (callee == null) return t;
	const sym = callee.resolvedSym;
	if (sym == null || sym.symbolType == null) return t;
	const fnType = sym.symbolType;
	if (fnType.kind != TypeKind.Function) return t;
	const sentinel = fnType.typeExtra;
	if (sentinel == null || sentinel.kind != TypeKind.None) return t;
	const predicateTarget = sentinel.typeReturn;
	if (predicateTarget == null) return t;
	const paramName = sentinel.typeName;
	if (paramName == "") return t;
	// Find the positional index of the predicate parameter.
	let paramIdx: int32 = -1;
	if (fnType.typeNames != null) {
		let pi: int32 = 0;
		while (pi < fnType.typeNames.length) {
			if (fnType.typeNames[pi] == paramName) { paramIdx = pi; break; }
			pi = pi + 1;
		}
	}
	if (paramIdx < 0 || paramIdx >= cd.arguments.length) return t;
	const predicateArg = cd.arguments[paramIdx];
	if (predicateArg == null || !isMatchingReference(predicateArg, refNode)) return t;
	// TrueCondition: narrow to the predicate target, but only if it's
	// compatible with the current type `t` (intersection semantics).
	// Returning predicateTarget for a type outside `t` would widen past
	// the declared union. Uses `typeRelation` for cross-module resilience
	// (no pointer-identity or string-key assumptions).
	if (assumeTrue) {
		if (t.kind == TypeKind.Union && t.typeChildren != null) {
			for (const v of t.typeChildren) {
				const rel = typeRelation(predicateTarget, v);
				if (rel != TypeRelation.None) return predicateTarget;
			}
			return t;
		}
		return predicateTarget;
	}
	// FalseCondition: remove variants assignable to the predicate target.
	if (t.kind == TypeKind.Union && t.typeChildren != null) {
		const remaining: Type[] = [];
		for (const v of t.typeChildren) {
			const rel = typeRelation(predicateTarget, v);
			if (rel == TypeRelation.None) {
				remaining.push(v);
			}
		}
		if (remaining.length == 0) return t;
		if (remaining.length == 1) return remaining[0];
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
	if (t == null) return t;
	if (left == null || right == null) return t;
	if (!isMatchingReference(left, refNode)) return t;
	// Resolve the RHS to a type. The RHS is typically an Identifier referencing
	// a class — its resolvedSym.symbolType is the class/struct type.
	if (right.resolvedSym == null || right.resolvedSym.symbolType == null) return t;
	const target = right.resolvedSym.symbolType;
	if (symGenericParams(right.resolvedSym) != "") {
		const selected = genericInstanceMembers(t, right.resolvedSym);
		if (selected == null) return t;
		const kept: Type[] = [];
		for (const v of t.typeChildren) if ((selected.indexOf(v) >= 0) == assumeTrue) kept.push(v);
		if (kept.length == 0) return neverType();
		return kept.length == 1 ? kept[0] : createUnion(kept);
	}
	const members = declaredMembers(t);
	const kept: Type[] = [];
	for (const m of members) {
		if (!assumeTrue) {
			if (!isDerivedFrom(m, target)) kept.push(m);
		} else if (isDerivedFrom(m, target)) {
			kept.push(m);
		} else if (isDerivedFrom(target, m)) {
			appendIfUnique(kept, target);
		}
	}
	if (kept.length == 0) return assumeTrue ? target : t;
	if (sameMembers(kept, members)) return t;
	if (kept.length == 1) return kept[0];
	return isNullableShape(kept) ? nullableUnionOf(kept) : createUnion(kept);
}

function sameMembers(a: Type[], b: Type[]): boolean {
	if (a.length != b.length) return false;
	for (let i = 0; i < a.length; i += 1) {
		if (a[i] != b[i]) return false;
	}
	return true;
}

function isDerivedFrom(source: Type, target: Type): boolean {
	if (source.kind == TypeKind.Null) return false;
	return source == target || sameType(source, target) || classAncestorInstance(source, target) != null;
}

// ===== Truthiness helpers =====

// Remove Null variants from a type. For unions, filters out TypeKind.Null
// members and reconstructs. For Maybe<T> wrappers (resolver collapses
// non-pointer T|null into Maybe<T>), peels to inner T. Non-union, non-null,
// non-maybe types pass through unchanged (non-nullable values aren't affected
// by truthiness narrowing).
function removeNullFromType(t: Type | null): Type | null {
	if (t == null) return t;
	if (t.kind == TypeKind.Null) return neverType();
	if (isMaybeType(t)) return unwrapMaybeType(t);
	if (t.kind != TypeKind.Union || t.typeChildren == null) return t;
	const remaining: Type[] = [];
	for (const v of t.typeChildren) {
		if (v.kind != TypeKind.Null) remaining.push(v);
	}
	if (remaining.length == t.typeChildren.length) return t;
	if (remaining.length == 0) return neverType();
	if (remaining.length == 1) return remaining[0];
	return createUnion(remaining);
}

// Extract the Null variant from a type. For unions, returns the Null member
// if present. For Maybe<T> wrappers, returns Null (the falsy branch in
// `if (!x)` narrows the Maybe to its absent state). Non-union/non-maybe types
// or unions without Null return t unchanged.
function extractNullFromType(t: Type | null): Type | null {
	if (t == null) return t;
	if (t.kind == TypeKind.Null) return t;
	if (isMaybeType(t)) return nullType();
	if (t.kind != TypeKind.Union || t.typeChildren == null) return t;
	for (const v of t.typeChildren) {
		if (v.kind == TypeKind.Null) return v;
	}
	return t;
}

function narrowToFalsy(t: Type | null): Type | null {
	if (t == null) return t;
	if (isMaybeType(t)) return holdsFalsyValue(unwrapMaybeType(t)) ? t : nullType();
	if (t.kind != TypeKind.Union || t.typeChildren == null) return t;
	const kept: Type[] = [];
	for (const v of t.typeChildren) {
		if (v.kind == TypeKind.Null || holdsFalsyValue(v)) kept.push(v);
	}
	if (kept.length == 0 || kept.length == t.typeChildren.length) return t;
	return kept.length == 1 ? kept[0] : createUnion(kept);
}

// Hidden conversions are repr plumbing (fitNode's variant↔union wrap/project);
// the flow fact lives on the expression underneath.
function skipHiddenConv(n: Node): Node {
	let walk: Node = n;
	while (walk != null
			&& (walk.kind == NodeKind.HiddenSubConv || walk.kind == NodeKind.HiddenStdConv)) {
		const inner = (walk.data as HiddenStdConvData).convExpr;
		if (walk.kind == NodeKind.HiddenStdConv && convertsNumber(walk, inner)) return walk;
		walk = inner;
	}
	return walk;
}

function convertsNumber(conv: Node, inner: Node): boolean {
	return conv.nodeType != null && isNumeric(conv.nodeType) && inner != null && inner.nodeType != null
		&& isNumeric(inner.nodeType) && inner.nodeType.kind != conv.nodeType.kind;
}

function narrowByAssignment(node: Node | null, refNode: Node, declared: Type): Type | null {
	if (node == null) return null;
	if (node.kind == NodeKind.UpdateExpr) {
		const target = (node.data as UpdateExprData).updateArg;
		return target != null && holdsBelowTop(refNode, target) ? declared : null;
	}
	if (node.kind == NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		if (d.left == null) return null;
		if (patternWritesInto(d.left, refNode)) return declared;
		if (d.operator != "=") return null;
		if (d.left.kind == NodeKind.Identifier && d.left.resolvedSym == null) {
			throw new Error(`internal: assignment to '${(d.left.data as IdentifierData).name}' at ${d.left.location.line}:${d.left.location.column} reached flow narrowing with no symbol bound by position`);
		}
		if (!isMatchingReference(d.left, refNode)) return null;
		const rhs = skipHiddenConv(d.right);
		if (rhs == null || rhs.nodeType == null) return declared;
		return constrainToDeclared(assignedValueType(rhs), declared);
	}
	if (node.kind == NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		const init = skipHiddenConv(d.initializer);
		if (init == null || init.nodeType == null) {
			return null;
		}
		// The reference must be an Identifier whose resolvedSym is this decl.
		if (refNode.kind != NodeKind.Identifier) return null;
		const sym = refNode.resolvedSym;
		if (sym == null || sym.declNode != node) return null;
		return constrainToDeclared(assignedValueType(init), declared);
	}
	return null;
}

function assignedValueType(value: Node): Type {
	const t = value.nodeType!;
	return value.kind == NodeKind.NullLiteral && !value.flags.has(NodeFlag.AssertedNull) && isNullableShape([t]) ? nullType() : t;
}

function stripHidden(n: Node | null): Node | null {
	let walk = n;
	while (walk != null) {
		if (walk.kind == NodeKind.HiddenDeref || walk.kind == NodeKind.HiddenAddr) {
			walk = (walk.data as HiddenDerefData).expr;
		} else if (walk.kind == NodeKind.HiddenStdConv || walk.kind == NodeKind.HiddenSubConv) {
			walk = (walk.data as HiddenStdConvData).convExpr;
		} else {
			return walk;
		}
	}
	return walk;
}

function sameLocation(part: Node | null, target: Node): boolean {
	const p = stripHidden(part);
	const t = stripHidden(target);
	if (p == null || t == null) return false;
	if (isMatchingReference(p, t)) return true;
	if (p.kind != t.kind) return false;
	if (t.kind == NodeKind.MemberExpr) {
		const pd = p.data as MemberExprData;
		const td = t.data as MemberExprData;
		return pd.property == td.property && sameLocation(pd.object, td.object);
	}
	return false;
}

function holdsBelowTop(refNode: Node, target: Node): boolean {
	const top = stripHidden(refNode);
	if (top == null) return false;
	if (top.kind == NodeKind.MemberExpr) {
		const obj = (top.data as MemberExprData).object;
		return sameLocation(obj, target) || holdsBelowTop(obj, target);
	}
	if (top.kind == NodeKind.ArrayAccess) {
		const ad = top.data as ArrayAccessData;
		return sameLocation(ad.array, target) || sameLocation(ad.index, target)
			|| holdsBelowTop(ad.array, target);
	}
	return false;
}

function patternWritesInto(target: Node, refNode: Node): boolean {
	const t = stripHidden(target);
	if (t == null) return false;
	if (t.kind == NodeKind.ArrayLiteral) {
		for (const el of (t.data as ArrayLiteralData).elements) {
			const inner = el.kind == NodeKind.SpreadExpr ? (el.data as SpreadExprData).spreadArg : el;
			if (inner != null && (sameLocation(refNode, inner) || patternWritesInto(inner, refNode))) return true;
		}
		return false;
	}
	if (t.kind == NodeKind.ObjectLiteral) {
		for (const prop of (t.data as ObjectLiteralData).properties) {
			if (prop != null && (sameLocation(refNode, prop) || patternWritesInto(prop, refNode))) return true;
		}
		return false;
	}
	return holdsBelowTop(refNode, t);
}

function calleeType(callee: Node | null): Type | null {
	if (callee == null) return null;
	let fnType = callee.nodeType;
	if ((fnType == null || fnType.kind != TypeKind.Function)
			&& callee.kind == NodeKind.Identifier && callee.resolvedSym != null) {
		fnType = callee.resolvedSym.symbolType;
	}
	return fnType != null && fnType.kind == TypeKind.Function ? fnType : null;
}

function callNeverReturns(call: Node | null): boolean {
	if (call == null || call.kind != NodeKind.CallExpr) return false;
	const callee = (call.data as CallExprData).callee;
	if (callee == null) return false;
	const sym = callee.resolvedSym;
	if (sym != null && sym.symFlags.has(SymbolFlag.NoReturn)) return true;
	let fnType = callee.nodeType;
	if ((fnType == null || fnType.kind != TypeKind.Function) && sym != null) fnType = sym.symbolType;
	return fnType != null && fnType.kind == TypeKind.Function && fnType.typeReturn != null && fnType.typeReturn.kind == TypeKind.Never;
}

export function isEndOfBodyReachable(body: Node): boolean {
	if (body.flowNode == null) return false;
	return reachesStart(body.flowNode, []);
}

function reachesStart(from: FlowNode, reduceLabels: FlowReduceLabelData[]): boolean {
	const seen = new HashSet<FlowNode>();
	const todo: FlowNode[] = [from];
	while (todo.length > 0) {
		const flow = todo.pop();
		if (flow == null || flow.flags.has(FlowFlag.Unreachable) || seen.has(flow)) continue;
		seen.add(flow);
		if (flow.flags.has(FlowFlag.Start)) return true;
		if (flow.flags.has(FlowFlag.Call) && callNeverReturns(flow.node)) continue;
		if (flow.flags.has(FlowFlag.ReduceLabel)) {
			if (flow.antecedent == null) continue;
			reduceLabels.push(flow.reduceLabelData!);
			const reached = reachesStart(flow.antecedent, reduceLabels);
			reduceLabels.pop();
			if (reached) return true;
			continue;
		}
		if (flow.flags.has(FlowFlag.LoopLabel) || flow.flags.has(FlowFlag.BranchLabel)) {
			let list: FlowList | null = flow.flags.has(FlowFlag.BranchLabel) ? branchLabelAntecedents(reduceLabels, flow) : flow.antecedents;
			while (list != null) {
				todo.push(list.flow);
				list = list.next;
			}
			continue;
		}
		if (flow.antecedent != null) todo.push(flow.antecedent);
	}
	return false;
}

function callWritesInto(call: Node | null, refNode: Node): boolean {
	if (call == null) return false;
	let args: Node[] = [];
	let callee: Node | null = null;
	if (call.kind == NodeKind.CallExpr) {
		const cd = call.data as CallExprData;
		args = cd.arguments;
		callee = cd.callee;
	} else if (call.kind == NodeKind.NewExpr) {
		args = (call.data as NewExprData).newArguments;
	} else {
		return false;
	}
	let fnType: Type | null = null;
	let fnTypeKnown = false;
	let i = 0;
	for (const arg of args) {
		const at = i;
		i = i + 1;
		let passed = stripHidden(arg);
		if (passed != null && passed.kind == NodeKind.OutExpr) {
			passed = (passed.data as OutExprData).outArg;
		} else if (passed != null) {
			if (!fnTypeKnown) {
				fnType = calleeType(callee);
				fnTypeKnown = true;
			}
			const param = fnType != null && at < fnType.typeChildren.length ? fnType.typeChildren[at] : null as unknown as Type;
			if (param == null || param.kind != TypeKind.Var) passed = null;
		}
		if (passed != null && writesThrough(passed, refNode)) return true;
	}
	const top = stripHidden(callee);
	if (top != null && top.kind == NodeKind.MemberExpr) {
		const md = top.data as MemberExprData;
		if (isMutatingArrayMethod(md.property) && holdsBelowTop(refNode, md.object)) return true;
	}
	return false;
}

function writesThrough(byAddress: Node, refNode: Node): boolean {
	return sameLocation(refNode, byAddress) || holdsBelowTop(refNode, byAddress);
}

// Constrain an assigned value's type to remain within the variable's declared
// bounds. Only union-declared variables get narrowed: if `rhs` is a specific
// variant of `declared`, return that variant; otherwise return `declared`
// (no narrowing). Non-union declared types fall through unchanged — we never
// tighten e.g. `Node[]` to `BinaryExpr[]` across an assignment, because
// structurally-similar arrays join to an ugly union at control flow merges.
function constrainToDeclared(rhs: Type, declared: Type): Type {
	if (rhs == null) return declared;
	if (declared == null) return rhs;
	const union = peelTransparentInstance(declared);
	if (union.kind != TypeKind.Union || union.typeChildren == null) {
		return declared;
	}
	// Find the best-matching variant in the declared union using typeRelation.
	// This handles identity matches, named-type matches, primitive kind
	// matches, AND structural compatibility for anonymous structs — all in
	// one pass via the established comparison infrastructure.
	for (const v of union.typeChildren) {
		if (v == rhs) return rhs;
		const rel = typeRelation(v, rhs);
		if (rel != TypeRelation.None) return rhs;
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
	if (sym == null) return null as unknown as Node;
	const decl = sym.declNode;
	if (decl == null || decl.kind != NodeKind.VariableDecl) {
		return null as unknown as Node;
	}
	const d = decl.data as VariableDeclData;
	if (d.declKind != DeclKind.Const) return null as unknown as Node;
	const init = d.initializer;
	if (init == null) return null as unknown as Node;
	// Alias condition-shaped initializers:
	//   BinaryExpr: comparison (===, !==), logical (&&, ||)
	//   UnaryExpr:  negation (!)
	//   CallExpr:   type-predicate calls (`const isX = isString(val)`)
	// Bare identifiers are excluded — they'd chain (a → b → a) without
	// adding narrowing information. The depth guard in narrowType bounds
	// any residual recursion from chained aliases.
	if (init.kind == NodeKind.BinaryExpr
			|| init.kind == NodeKind.UnaryExpr
			|| init.kind == NodeKind.CallExpr) {
		return init;
	}
	return null as unknown as Node;
}

function isConstBinding(refNode: Node): boolean {
	const top = stripHidden(refNode);
	if (top == null || top.kind != NodeKind.Identifier || top.resolvedSym == null) return false;
	const decl = top.resolvedSym.declNode;
	return decl != null && decl.kind == NodeKind.VariableDecl
		&& (decl.data as VariableDeclData).declKind == DeclKind.Const;
}

// ===== Captured bindings =====

function capturedFlowAt(reference: Node, closure: Node | null): FlowNode | null {
	if (closure == null || closure.flowNode == null) return null;
	if (closure.kind != NodeKind.ArrowFunction && closure.kind != NodeKind.FunctionExpr) return null;
	const top = stripHidden(reference);
	if (top == null || top.kind != NodeKind.Identifier || top.resolvedSym == null) return null;
	const sym = top.resolvedSym!;
	if (declaresParam(closure, sym)) return null;
	if (isConstantSymbol(sym)) return closure.flowNode;
	if (isParameterOrMutableLocal(sym) && isPastLastAssignment(sym, closure)) return closure.flowNode;
	return null;
}

function isConstantSymbol(sym: Symbol): boolean {
	const decl = sym.declNode;
	if (decl == null) return false;
	if (decl.kind == NodeKind.VariableDecl) return (decl.data as VariableDeclData).declKind == DeclKind.Const;
	return decl.kind == NodeKind.DestructuringDecl && (decl.data as DestructuringDeclData).destrIsConst;
}

function isParameterOrMutableLocal(sym: Symbol): boolean {
	if (sym.symbolType != null && sym.symbolType.kind == TypeKind.Var) return false;
	if (sym.symbolKind == SymbolKind.Parameter) return true;
	const decl = sym.declNode;
	if (decl == null || sym.symFlags.has(SymbolFlag.Exported)) return false;
	if (decl.kind == NodeKind.VariableDecl) return (decl.data as VariableDeclData).declKind == DeclKind.Let;
	return decl.kind == NodeKind.DestructuringDecl && !(decl.data as DestructuringDeclData).destrIsConst;
}

function declaresParam(container: Node, sym: Symbol): boolean {
	if (sym.symbolKind != SymbolKind.Parameter) return false;
	if (container.paramSyms != null && container.paramSyms!.includes(sym)) return true;
	return paramNamesOf(container).includes(sym.name);
}

function paramNamesOf(container: Node): string[] {
	if (container.kind == NodeKind.FunctionDecl) return (container.data as FunctionDeclData).params;
	if (container.kind == NodeKind.ArrowFunction) return (container.data as ArrowFunctionData).arrowParams;
	if (container.kind == NodeKind.FunctionExpr) return (container.data as FunctionExprData).funcExprParams;
	if (container.kind == NodeKind.MethodDecl) return (container.data as MethodDeclData).methodParams;
	if (container.kind == NodeKind.ConstructorDecl) return (container.data as ConstructorDeclData).ctorParams;
	return [];
}

function isPastLastAssignment(sym: Symbol, closure: Node): boolean {
	const [container, created] = declaringContainerOf(sym, closure);
	if (container == null) return false;
	const scan = assignmentsIn(container!);
	return scan.ordinals.has(created) && lastAssignmentOf(sym, scan) < scan.ordinals.get(created)!;
}

function declaringContainerOf(sym: Symbol, closure: Node): [Node | null, Node] {
	let inner = closure;
	while (true) {
		const container = enclosingContainer(inner);
		if (container == null) break;
		if (declaresParam(container!, sym) || (sym.declNode != null && assignmentsIn(container!).ordinals.has(sym.declNode))) return [container, inner];
		if (container!.kind != NodeKind.ArrowFunction && container!.kind != NodeKind.FunctionExpr) break;
		inner = container!;
	}
	return [null, inner];
}

function enclosingContainer(closure: Node): Node | null {
	if (closureContainers.has(closure)) return closureContainers.get(closure)!;
	if (closure.flowNode == null) return null;
	const seen = new HashSet<FlowNode>();
	const todo: FlowNode[] = [closure.flowNode!];
	while (todo.length > 0) {
		const flow = todo.pop();
		if (flow == null || flow.flags.has(FlowFlag.Unreachable) || seen.has(flow)) continue;
		seen.add(flow);
		if (flow.flags.has(FlowFlag.Start)) {
			if (flow.node == null) return null;
			closureContainers.set(closure, flow.node!);
			return flow.node;
		}
		if (flow.antecedent != null) todo.push(flow.antecedent);
		let list: FlowList | null = flow.antecedents;
		while (list != null) {
			todo.push(list.flow);
			list = list.next;
		}
	}
	return null;
}

const WRITTEN_LATER: int32 = 2147483647;

class AssignmentWrite {
	name: string;
	sym: Symbol | null;
	at: int32;
	nested: boolean;
	open: int32[];

	constructor(name: string, sym: Symbol | null, at: int32, nested: boolean, open: int32[]) {
		this.name = name;
		this.sym = sym;
		this.at = at;
		this.nested = nested;
		this.open = open;
	}
}

class ContainerAssignments {
	ordinal: int32 = 0;
	ordinals: HashMap<Node, int32> = new HashMap<Node, int32>();
	writes: AssignmentWrite[] = [];
	statementStart: int32[] = [];
	statementEnd: int32[] = [];
	open: int32[] = [];
}

let containerAssignments = new HashMap<Node, ContainerAssignments>();
let lastAssignments = new HashMap<Symbol, int32>();
let closureContainers = new HashMap<Node, Node>();

export function resetCapturedAssignments(): void {
	containerAssignments = new HashMap<Node, ContainerAssignments>();
	lastAssignments = new HashMap<Symbol, int32>();
	closureContainers = new HashMap<Node, Node>();
	aliasPaths = new HashMap<Node, AliasPath>();
}

function assignmentsIn(container: Node): ContainerAssignments {
	const known = containerAssignments.get(container);
	if (known != null) return known;
	const scan = new ContainerAssignments();
	forEachChild(container, (child: Node): void => { scanAssignments(scan, child, false); });
	containerAssignments.set(container, scan);
	return scan;
}

function lastAssignmentOf(sym: Symbol, scan: ContainerAssignments): int32 {
	if (lastAssignments.has(sym)) return lastAssignments.get(sym)!;
	const declAt = sym.declNode != null && scan.ordinals.has(sym.declNode) ? scan.ordinals.get(sym.declNode)! : 0;
	let last = 0;
	for (const write of scan.writes) {
		if (write.name != sym.name || (write.sym != null && write.sym != sym)) continue;
		if (write.nested) {
			last = WRITTEN_LATER;
			break;
		}
		let at = write.at;
		for (const i of write.open) {
			if (scan.statementStart[i] > declAt) {
				at = scan.statementEnd[i];
				break;
			}
		}
		if (at > last) last = at;
	}
	lastAssignments.set(sym, last);
	return last;
}

function scanAssignments(scan: ContainerAssignments, node: Node, nested: boolean): void {
	scan.ordinal += 1;
	const at = scan.ordinal;
	const k = node.kind;
	if (!nested && (k == NodeKind.VariableDecl || k == NodeKind.DestructuringDecl || k == NodeKind.ArrowFunction || k == NodeKind.FunctionExpr)) {
		scan.ordinals.set(node, at);
	}
	const written: Node[] = [];
	writtenNames(node, written);
	for (const n of written) {
		scan.writes.push(new AssignmentWrite((n.data as IdentifierData).name, nested ? null : n.resolvedSym, at, nested, scan.open.slice(0)));
	}
	const later = nested || runsLater(node);
	const extending = !later && extendsAssignment(node);
	if (extending) {
		scan.open.push(scan.statementStart.length);
		scan.statementStart.push(at);
		scan.statementEnd.push(0);
	}
	forEachChild(node, (child: Node): void => { scanAssignments(scan, child, later); });
	if (extending) scan.statementEnd[scan.open.pop()] = scan.ordinal;
}

function runsLater(node: Node): boolean {
	const k = node.kind;
	return k == NodeKind.FunctionDecl || k == NodeKind.ArrowFunction || k == NodeKind.FunctionExpr
		|| k == NodeKind.MethodDecl || k == NodeKind.ConstructorDecl || k == NodeKind.ClassDecl
		|| k == NodeKind.ActorDecl || k == NodeKind.TestDecl || k == NodeKind.DeferStmt
		|| k == NodeKind.MacroDecl || k == NodeKind.QuoteExpr || k == NodeKind.ComptimeBlock;
}

function extendsAssignment(node: Node): boolean {
	const k = node.kind;
	return k == NodeKind.VariableDecl || k == NodeKind.DestructuringDecl || k == NodeKind.ExprStmt
		|| k == NodeKind.IfStmt || k == NodeKind.DoWhileStmt || k == NodeKind.WhileStmt
		|| k == NodeKind.ForStmt || k == NodeKind.ForInStmt || k == NodeKind.ForOfStmt
		|| k == NodeKind.SwitchStmt || k == NodeKind.MatchStmt || k == NodeKind.TryCatchStmt;
}

function writtenNames(node: Node, out: Node[]): void {
	if (node.kind == NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		if (isAssignmentOperator(d.operator)) collectTargets(d.left, out);
	} else if (node.kind == NodeKind.UpdateExpr) {
		collectName((node.data as UpdateExprData).updateArg, out);
	} else if (node.kind == NodeKind.OutExpr) {
		collectName((node.data as OutExprData).outArg, out);
	} else if (node.kind == NodeKind.MoveExpr) {
		collectName((node.data as MoveExprData).moveArg, out);
	} else if (node.kind == NodeKind.CallExpr) {
		const cd = node.data as CallExprData;
		const fnType = calleeType(cd.callee);
		for (let i = 0; i < cd.arguments.length; i += 1) {
			if (argumentMayBeRef(fnType, i)) collectName(cd.arguments[i], out);
		}
	}
}

function argumentMayBeRef(fnType: Type | null, i: int32): boolean {
	if (fnType == null) return true;
	return i < fnType.typeChildren.length && fnType.typeChildren[i] != null && fnType.typeChildren[i].kind == TypeKind.Var;
}

function isAssignmentOperator(op: string): boolean {
	return op.endsWith("=") && op != "==" && op != "===" && op != "!=" && op != "!==" && op != "<=" && op != ">=";
}

function collectTargets(target: Node | null, out: Node[]): void {
	const t = stripHidden(target);
	if (t == null) return;
	if (t.kind == NodeKind.ArrayLiteral || t.kind == NodeKind.ObjectLiteral) {
		forEachChild(t, (part: Node): void => { collectTargets(part, out); });
	} else if (t.kind == NodeKind.SpreadExpr) {
		collectTargets((t.data as SpreadExprData).spreadArg, out);
	} else {
		collectName(t, out);
	}
}

function collectName(node: Node | null, out: Node[]): void {
	const n = stripHidden(node);
	if (n != null && n.kind == NodeKind.Identifier) out.push(n);
}

function writesReference(node: Node | null, refNode: Node): boolean {
	if (node == null) return false;
	if (node.kind == NodeKind.BinaryExpr) {
		const left = (node.data as BinaryExprData).left;
		return left != null && (sameLocation(refNode, left) || patternWritesInto(left, refNode));
	}
	if (node.kind == NodeKind.UpdateExpr) {
		const target = (node.data as UpdateExprData).updateArg;
		return target != null && (sameLocation(refNode, target) || holdsBelowTop(refNode, target));
	}
	return false;
}

class AliasPath {
	from: FlowNode;
	reachesStart: boolean = false;
	writers: FlowNode[] = [];
	constructor(from: FlowNode) { this.from = from; }
}

let aliasPaths = new HashMap<Node, AliasPath>();

function aliasPathOf(aliasId: Node, from: FlowNode, decl: Node | null): AliasPath {
	const known = aliasPaths.get(aliasId);
	if (known != null && known.from == from) return known;
	const path = new AliasPath(from);
	const seen = new HashSet<FlowNode>();
	const todo: FlowNode[] = [from];
	while (todo.length > 0) {
		const flow = todo.pop();
		if (flow == null || flow.flags.has(FlowFlag.Unreachable) || seen.has(flow)) continue;
		seen.add(flow);
		if (flow.flags.has(FlowFlag.Start)) {
			path.reachesStart = true;
			break;
		}
		if (flow.flags.has(FlowFlag.Assignment)) {
			if (flow.node == decl) continue;
			path.writers.push(flow);
		} else if (flow.flags.has(FlowFlag.Call)) {
			path.writers.push(flow);
		}
		if (flow.antecedent != null) todo.push(flow.antecedent);
		let list: FlowList | null = flow.antecedents;
		while (list != null) {
			todo.push(list.flow);
			list = list.next;
		}
	}
	aliasPaths.set(aliasId, path);
	return path;
}

function aliasStillHolds(aliasId: Node, refNode: Node): boolean {
	if (isConstBinding(refNode)) return true;
	if (aliasId.flowNode == null || aliasId.resolvedSym == null) return false;
	const path = aliasPathOf(aliasId, aliasId.flowNode, aliasId.resolvedSym.declNode);
	if (path.reachesStart) return false;
	for (const flow of path.writers) {
		if (flow.flags.has(FlowFlag.Assignment) ? writesReference(flow.node, refNode) : callWritesInto(flow.node, refNode)) return false;
	}
	return true;
}

function narrowTypeByEquality(
	t: Type | null, left: Node, right: Node, op: string, refNode: Node, assumeTrue: boolean
): Type | null {
	// !== and != invert the sense
	const eff = (op == "!==" || op == "!=") ? !assumeTrue : assumeTrue;
	// Case 0: typeof narrowing. `typeof x === "string"` or `"string" === typeof x`.
	// Handled first so it doesn't fall through to discriminant matching.
	if (left != null && isTypeofOperand(left)) {
		const inner = (left.data as UnaryExprData).operand;
		if (isMatchingReference(inner, refNode)) {
			return narrowTypeByTypeof(t, right, eff);
		}
	}
	if (right != null && isTypeofOperand(right)) {
		const inner = (right.data as UnaryExprData).operand;
		if (isMatchingReference(inner, refNode)) {
			return narrowTypeByTypeof(t, left, eff);
		}
	}
	// Case 1: left side is a discriminant-property access on our reference.
	//   `s.kind === "circle"` — narrow s to the "circle" variant
	if (left != null && left.kind == NodeKind.MemberExpr) {
		const md = left.data as MemberExprData;
		if (isMatchingReference(md.object, refNode)) {
			return narrowTypeByDiscriminantProperty(t, md.property, right, eff);
		}
	}
	// Case 2: symmetric (literal on left, member on right)
	if (right != null && right.kind == NodeKind.MemberExpr) {
		const md = right.data as MemberExprData;
		if (isMatchingReference(md.object, refNode)) {
			return narrowTypeByDiscriminantProperty(t, md.property, left, eff);
		}
	}
	// Case 3: direct identifier equality
	//   `x === null` — narrow x to non-null (or null if eff = true)
	//   `x === "literal"` — narrow x to the literal type (no-op if already)
	if (left != null && isMatchingReference(left, refNode)) {
		return narrowByLiteralEquality(t, right, eff);
	}
	if (right != null && isMatchingReference(right, refNode)) {
		return narrowByLiteralEquality(t, left, eff);
	}
	return t;
}

// Check if a node is `typeof <something>`.
function isTypeofOperand(node: Node): boolean {
	if (node == null || node.kind != NodeKind.UnaryExpr) return false;
	const d = node.data as UnaryExprData;
	return d.unaryOp == "typeof";
}

// Narrow a type by `typeof x === "literal"` comparison.
// `literalExpr` is the RHS (or LHS) string literal naming the type.
// `assumeTrue` is the effective sense: true → keep the matching type,
// false → exclude it (for `typeof x !== "literal"`).
function narrowTypeByTypeof(t: Type | null, literalExpr: Node, assumeTrue: boolean): Type | null {
	if (t == null || literalExpr == null) return t;
	if (literalExpr.kind != NodeKind.StringLiteral) return t;
	const d = literalExpr.data as StringLiteralData;
	if (!isTypeofTag(d.value) && !isPrimitiveKindName(d.value)) return t;
	if (isMaybeType(t) && t.typeReturn != null) {
		const members: Type[] = [];
		const payload = t.typeReturn;
		if (payload.kind == TypeKind.Union && payload.typeChildren != null) {
			for (const c of payload.typeChildren) { if (c != null) members.push(c); }
		} else {
			members.push(payload);
		}
		members.push(nullType());
		const kept: Type[] = [];
		for (const m of members) {
			if (typeofStringMatches(m, d.value) == assumeTrue) kept.push(m);
		}
		if (kept.length == 0) return noValueLeft(t, t);
		if (kept.length == members.length) return t;
		if (kept.length == 1) return kept[0];
		return nullableUnionOf(kept);
	}
	// For union types, filter variants by whether their kind matches.
	if (t.kind == TypeKind.Union) {
		const remaining: Type[] = [];
		let matchVariant: Type | null = null;
		if (t.typeChildren != null) {
			for (const v of t.typeChildren) {
				if (v == null) continue;
				const isMatch = typeofStringMatches(v, d.value);
				if (isMatch) matchVariant = v;
				if (isMatch == assumeTrue) remaining.push(v);
			}
		}
		if (remaining.length == 0) return noValueLeft(t, t);
		if (remaining.length == t.typeChildren.length) return t;
		if (remaining.length == 1) return remaining[0];
		return createUnion(remaining);
	}
	// For non-union types: if the kind matches, keep/drop based on assumeTrue.
	const matches = typeofStringMatches(t, d.value);
	if (assumeTrue) {
		return matches ? t : noValueLeft(t, inferredType());
	}
	return matches ? noValueLeft(t, inferredType()) : t;
}

function noValueLeft(t: Type, unresolved: Type): Type {
	if (hasGenericParams(t) || t.kind == TypeKind.GenericParam || t.kind == TypeKind.Unknown
			|| t.kind == TypeKind.Inferred || t.kind == TypeKind.Error) {
		return unresolved;
	}
	return neverType();
}

function typeofStringMatches(v: Type, s: string): boolean {
	return typeofNameMatches(v, s);
}

// Narrow a discriminated-union type by a discriminant property equality.
// `propName` is the field name (e.g. "kind"); `valueExpr` is the compared
// literal; `assumeTrue` picks the matching variant (true) or excludes it.
export function narrowTypeByDiscriminantProperty(
	t: Type | null, propName: string, valueExpr: Node, assumeTrue: boolean
): Type | null {
	if (t == null || t.kind != TypeKind.Union) return t;
	if (valueExpr != null && valueExpr.kind == NodeKind.BooleanLiteral) {
		const wanted = (valueExpr.data as BooleanLiteralData).boolValue;
		return narrowTypeByBooleanDiscriminant(t, propName, wanted == assumeTrue);
	}
	const info = detectUnionDiscriminant(t, propName);
	if (info.discField == "") return t;
	let variantIdx = -1;
	if (info.isStringDU) {
		const litValue = stringLiteralValueOf(valueExpr);
		if (litValue == null) return t;
		variantIdx = findVariantByStringDiscriminant(t, info.discField, litValue);
	} else {
		const lit = enumMemberLiteralOf(valueExpr);
		if (lit == null) return t;
		variantIdx = findVariantByEnumMember(t, lit);
	}
	if (variantIdx < 0) return t;
	if (t.typeChildren == null || variantIdx >= t.typeChildren.length) return t;
	const variant = t.typeChildren[variantIdx];
	if (variant == null) return t;
	if (assumeTrue) {
		// Keep only the matching variant — narrow to that struct.
		return variant;
	}
	// assumeTrue=false: exclude this variant, keep the rest.
	const remaining: Type[] = [];
	let i = 0;
	while (i < t.typeChildren.length) {
		if (i != variantIdx) {
			const v = t.typeChildren[i];
			if (v != null) remaining.push(v);
		}
		i = i + 1;
	}
	if (remaining.length == 0) return t;
	if (remaining.length == 1) return remaining[0];
	if (isDiscriminatedUnion(t)) return unionPreservingDiscriminant(t, remaining);
	return createUnion(remaining);
}

// Residual union after excluding variants from a metadata-carrying DU.
// Copies the discriminant contract (`typeExtra` = disc type, `typeNames` =
// [discName, variantKey...]) so disc re-reads keep resolving and codegen's
// `_tag` route keeps firing.
function unionPreservingDiscriminant(parent: Type, remaining: Type[]): Type {
	const u = createUnionInOrder(remaining);
	if (u.kind != TypeKind.Union) return u;
	if (parent.typeExtra == null || parent.typeNames == null
		|| parent.typeNames.length == 0 || parent.typeChildren == null) return u;
	u.typeExtra = parent.typeExtra;
	u.typeNames.push(parent.typeNames[0]);
	for (const rv of remaining) {
		for (let pi = 0; pi < parent.typeChildren.length; pi += 1) {
			if (parent.typeChildren[pi] == rv) {
				if (pi + 1 < parent.typeNames.length) u.typeNames.push(parent.typeNames[pi + 1]);
				break;
			}
		}
	}
	return u;
}

// Narrow by equality to a literal. `=== null` keeps or drops the null member;
// `=== "a"` and `=== 2` filter a union's members: the true branch drops every
// scalar member of another base and every literal of the same base with
// another value, the false branch drops the literal itself.
function narrowByLiteralEquality(t: Type | null, literal: Node, assumeTrue: boolean): Type | null {
	if (t == null) return t;
	if (isNullLiteral(literal)) {
		// Delegate to the shared helpers — they uniformly handle Union(T,null),
		// Maybe<T> wrappers, bare Null, and inert non-nullable types.
		// assumeTrue (=== null) keeps the null branch via extractNullFromType;
		// !assumeTrue (!== null) removes it via removeNullFromType.
		return assumeTrue ? extractNullFromType(t) : removeNullFromType(t);
	}
	const value = equalityLiteralType(skipHiddenConv(literal));
	if (value == null) return t;
	if (isMaybeType(t) && t.typeReturn != null) {
		const narrowed = filterByLiteral(t.typeReturn!, value, assumeTrue);
		if (assumeTrue) return narrowed.kind == TypeKind.Never ? t : narrowed;
		if (narrowed == t.typeReturn) return t;
		return narrowed.kind == TypeKind.Never ? nullType() : nullableUnionOf([narrowed, nullType()]);
	}
	if (t.kind != TypeKind.Union || t.typeChildren == null) return t;
	const narrowed = filterByLiteral(t, value, assumeTrue);
	return narrowed.kind == TypeKind.Never ? t : narrowed;
}

function filterByLiteral(t: Type, value: Type, assumeTrue: boolean): Type {
	if (t.kind != TypeKind.Union || t.typeChildren == null) {
		return (assumeTrue ? excludedByEquality(t, value) : sameLiteralType(t, value)) ? neverType() : t;
	}
	const kept: Type[] = [];
	for (const member of t.typeChildren) {
		if (member == null) return t;
		if (assumeTrue ? excludedByEquality(member, value) : sameLiteralType(member, value)) continue;
		kept.push(member);
	}
	if (kept.length == 0) return neverType();
	if (kept.length == t.typeChildren.length) return t;
	return unionPreservingDiscriminant(t, kept);
}

function equalityLiteralType(node: Node): Type | null {
	if (node.kind == NodeKind.StringLiteral) return createStringLiteral((node.data as StringLiteralData).value);
	let negated = false;
	let operand = node;
	if (node.kind == NodeKind.UnaryExpr && (node.data as UnaryExprData).unaryOp == "-") {
		negated = true;
		operand = (node.data as UnaryExprData).operand;
	}
	if (operand.kind != NodeKind.NumberLiteral) return null;
	const d = operand.data as NumberLiteralData;
	if (d.isFloat) return createNumberLiteral(fractionLiteralName(negated ? 0 - d.value : d.value), float64Type());
	return createNumberLiteral(integerLiteralName(negated ? 0 - d.intVal : d.intVal), int32Type());
}

function scalarBaseOf(t: Type): TypeKind {
	if (t.kind == TypeKind.String || t.kind == TypeKind.StringLiteral) return TypeKind.String;
	if (t.kind == TypeKind.NumberLiteral || isNumeric(t)) return TypeKind.Number;
	if (t.kind == TypeKind.Boolean || t.kind == TypeKind.BooleanLiteral) return TypeKind.Boolean;
	return TypeKind.Error;
}

function sameLiteralType(member: Type, value: Type): boolean {
	if (member.kind != value.kind) return false;
	if (member.typeName == value.typeName) return true;
	return member.kind == TypeKind.NumberLiteral && (isFloatType(numberLiteralBase(member)) || isFloatType(numberLiteralBase(value)))
		&& parseNumberLiteral(member.typeName) == parseNumberLiteral(value.typeName);
}

function excludedByEquality(member: Type, value: Type): boolean {
	const base = scalarBaseOf(member);
	if (base == TypeKind.Error) return false;
	if (base != scalarBaseOf(value)) return true;
	return member.kind == value.kind && !sameLiteralType(member, value);
}
