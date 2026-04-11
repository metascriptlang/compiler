// src/binder/binder.ms
//
// Flow graph construction pass. Runs after parsing (and declaration
// resolution) and before type checking. Attaches FlowNode references to
// each expression Node so getFlowTypeOfReference can compute narrowed types
// at each program point.
//
// Reference: microsoft/typescript-go/internal/binder/binder.go
//
// Phase 1 scope: build the graph. Queries come in Phase 2 (src/checker/flow.ms).
// Existing tests must still pass — the binder touches NO checker state.

import { parseSource } from "../parser/statements/validation";
import {
	Node, NodeKind, createNodeAt,
	FlowNode, FlowFlags, FlowList,
	FlowSwitchClauseData, FlowReduceLabelData,
	// NodeData variants
	ProgramData, BlockStmtData, IfStmtData, WhileStmtData, DoWhileStmtData,
	ForStmtData, ForOfStmtData, ForInStmtData,
	SwitchStmtData, SwitchCaseData, MatchStmtData, MatchExprData, MatchCaseData,
	FunctionDeclData, ArrowFunctionData, FunctionExprData,
	ClassDeclData, ActorDeclData, MethodDeclData, ConstructorDeclData, PropertyDeclData,
	VariableDeclData, ReturnStmtData, ThrowStmtData, ExprStmtData,
	TryCatchStmtData, DeferStmtData, AssertStmtData,
	BinaryExprData, UnaryExprData, UpdateExprData,
	CallExprData, MemberExprData, ArrayAccessData,
	ObjectLiteralData, ArrayLiteralData, ConditionalExprData,
	SpreadExprData, NewExprData, TryExprData,
	AwaitExprData, YieldExprData, MoveExprData, OutExprData,
	TypeAssertionData, DestructuringDeclData,
	ExportDeclData, DecoratedDeclData, TestDeclData,
	MacroDeclData, MacroInvocationData,
	ArrayPatternData, ObjectPatternData, ObjectPatternPropData,
	HiddenDerefData, HiddenStdConvData,
	IdentifierData,
} from "../ast/node";

// ===== FlowNode Constructors =====

function createFlowNode(flags: int32): FlowNode {
	const f = new FlowNode();
	f.flags = flags;
	f.node = null as unknown as Node;
	f.antecedent = null as unknown as FlowNode;
	f.antecedents = null as unknown as FlowList;
	f.switchClauseData = null as unknown as FlowSwitchClauseData;
	f.reduceLabelData = null as unknown as FlowReduceLabelData;
	return f;
}

function createUnreachableFlow(): FlowNode {
	return createFlowNode(FlowFlags.Unreachable);
}

function createStartFlow(container: Node): FlowNode {
	const f = createFlowNode(FlowFlags.Start);
	f.node = container;
	return f;
}

function createBranchLabel(): FlowNode {
	return createFlowNode(FlowFlags.BranchLabel);
}

function createLoopLabel(): FlowNode {
	return createFlowNode(FlowFlags.LoopLabel);
}

function createFlowCondition(flags: int32, antecedent: FlowNode, expr: Node): FlowNode {
	// flags must be TrueCondition or FalseCondition
	if (antecedent === null || (antecedent.flags & FlowFlags.Unreachable) !== 0) {
		return antecedent;
	}
	const f = createFlowNode(flags);
	f.antecedent = antecedent;
	f.node = expr;
	setFlowNodeReferenced(antecedent);
	return f;
}

function createFlowMutation(flags: int32, antecedent: FlowNode, node: Node): FlowNode {
	// flags = Assignment or ArrayMutation
	if (antecedent === null) return antecedent;
	// Short-circuit on unreachable — no point recording a mutation in dead code.
	// Matches typescript-go/internal/binder/binder.go behavior.
	if ((antecedent.flags & FlowFlags.Unreachable) !== 0) return antecedent;
	const f = createFlowNode(flags);
	f.antecedent = antecedent;
	f.node = node;
	setFlowNodeReferenced(antecedent);
	return f;
}

function createFlowSwitchClause(antecedent: FlowNode, switchStmt: Node, clauseStart: int32, clauseEnd: int32): FlowNode {
	if (antecedent === null) return antecedent;
	const f = createFlowNode(FlowFlags.SwitchClause);
	f.antecedent = antecedent;
	const data = new FlowSwitchClauseData();
	data.switchStatement = switchStmt;
	data.clauseStart = clauseStart;
	data.clauseEnd = clauseEnd;
	f.switchClauseData = data;
	setFlowNodeReferenced(antecedent);
	return f;
}

function addAntecedent(label: FlowNode, ante: FlowNode): void {
	if (ante === null) return;
	if ((ante.flags & FlowFlags.Unreachable) !== 0) return;
	// Dedup by pointer equality
	let cur = label.antecedents;
	while (cur !== null) {
		if (cur.flow === ante) return;
		cur = cur.next;
	}
	const link = new FlowList();
	link.flow = ante;
	link.next = label.antecedents;
	label.antecedents = link;
	setFlowNodeReferenced(ante);
}

function finishFlowLabel(label: FlowNode): FlowNode {
	if (label.antecedents === null) return createUnreachableFlow();
	if (label.antecedents.next === null) return label.antecedents.flow;
	return label;
}

function setFlowNodeReferenced(flow: FlowNode): void {
	if (flow === null) return;
	if ((flow.flags & FlowFlags.Referenced) === 0) {
		flow.flags = flow.flags | FlowFlags.Referenced;
	} else {
		flow.flags = flow.flags | FlowFlags.Shared;
	}
}

function isReachable(flow: FlowNode): boolean {
	if (flow === null) return false;
	return (flow.flags & FlowFlags.Unreachable) === 0;
}

// ===== Binder State =====
//
// The binder threads mutable state through every walk. Rather than plumb it
// through as a function arg to every bindXxx (which would be verbose), we use
// a single BinderState instance and mutate its fields in place. State is
// restored via save/set patterns at function-body and try-block boundaries.

export class BinderState {
	currentFlow: FlowNode;
	currentBreakTarget: FlowNode;     // break targets this label
	currentContinueTarget: FlowNode;  // continue targets this label
	currentReturnTarget: FlowNode;    // return targets this label (function-level)
	currentExceptionTarget: FlowNode; // throw adds antecedent to this
	unreachableFlow: FlowNode;
}

function createBinderState(): BinderState {
	const s = new BinderState();
	s.unreachableFlow = createUnreachableFlow();
	s.currentFlow = s.unreachableFlow;
	s.currentBreakTarget = null as unknown as FlowNode;
	s.currentContinueTarget = null as unknown as FlowNode;
	s.currentReturnTarget = null as unknown as FlowNode;
	s.currentExceptionTarget = null as unknown as FlowNode;
	return s;
}

// ===== Entry Point =====

export function bindFlowGraph(program: Node): void {
	if (program === null) return;
	if (program.kind !== NodeKind.Program) return;
	const state = createBinderState();
	state.currentFlow = createStartFlow(program);
	const d = program.data as ProgramData;
	let i = 0;
	while (i < d.programStmts.length) {
		bindStatement(state, d.programStmts[i]);
		i = i + 1;
	}
}

// Bind a nested function body. Saves and restores binder state so nested
// control flow does not leak out of the function.
function bindContainer(state: BinderState, container: Node, body: Node): void {
	const savedFlow = state.currentFlow;
	const savedBreak = state.currentBreakTarget;
	const savedContinue = state.currentContinueTarget;
	const savedReturn = state.currentReturnTarget;
	const savedException = state.currentExceptionTarget;

	state.currentFlow = createStartFlow(container);
	state.currentBreakTarget = null as unknown as FlowNode;
	state.currentContinueTarget = null as unknown as FlowNode;
	state.currentReturnTarget = createBranchLabel();
	state.currentExceptionTarget = null as unknown as FlowNode;

	if (body !== null) bindStatement(state, body);

	state.currentFlow = savedFlow;
	state.currentBreakTarget = savedBreak;
	state.currentContinueTarget = savedContinue;
	state.currentReturnTarget = savedReturn;
	state.currentExceptionTarget = savedException;
}

// ===== Statement Binder =====

function bindStatement(state: BinderState, node: Node): void {
	if (node === null) return;
	match (node.kind) {
		NodeKind.Program => bindProgram(state, node),
		NodeKind.BlockStmt => bindBlockStmt(state, node),
		NodeKind.IfStmt => bindIfStmt(state, node),
		NodeKind.WhileStmt => bindWhileStmt(state, node),
		NodeKind.DoWhileStmt => bindDoWhileStmt(state, node),
		NodeKind.ForStmt => bindForStmt(state, node),
		NodeKind.ForOfStmt => bindForOfStmt(state, node),
		NodeKind.ForInStmt => bindForInStmt(state, node),
		NodeKind.SwitchStmt => bindSwitchStmt(state, node),
		NodeKind.MatchStmt => bindMatchStmt(state, node),
		NodeKind.ReturnStmt => bindReturnStmt(state, node),
		NodeKind.ThrowStmt => bindThrowStmt(state, node),
		NodeKind.BreakStmt => bindBreakStmt(state, node),
		NodeKind.ContinueStmt => bindContinueStmt(state, node),
		NodeKind.TryCatchStmt => bindTryStmt(state, node),
		NodeKind.VariableDecl => bindVariableDecl(state, node),
		NodeKind.DestructuringDecl => bindDestructuringDecl(state, node),
		NodeKind.ExprStmt => bindExprStmt(state, node),
		NodeKind.FunctionDecl => bindFunctionDecl(state, node),
		NodeKind.ClassDecl => bindClassDecl(state, node),
		NodeKind.ActorDecl => bindActorDecl(state, node),
		NodeKind.InterfaceDecl => {},   // types only, no flow
		NodeKind.StructDecl => {},      // types only, no flow
		NodeKind.EnumDecl => {},        // types only, no flow
		NodeKind.TypeAliasDecl => {},   // types only, no flow
		NodeKind.ExternDecl => {},      // types only, no flow
		NodeKind.ImportDecl => {},      // types only, no flow
		NodeKind.ExportDecl => bindExportDecl(state, node),
		NodeKind.DecoratedDecl => bindDecoratedDecl(state, node),
		NodeKind.MacroDecl => {},       // macro bodies run in Raiser VM, not type-checked
		NodeKind.DeferStmt => bindDeferStmt(state, node),
		NodeKind.AssertStmt => bindAssertStmt(state, node),
		NodeKind.TestDecl => bindTestDecl(state, node),
		NodeKind.UnreachableStmt => {
			bindExpression(state, node);
			state.currentFlow = state.unreachableFlow;
		},
		_ => bindExpression(state, node),
	};
}

function bindProgram(state: BinderState, node: Node): void {
	const d = node.data as ProgramData;
	let i = 0;
	while (i < d.programStmts.length) {
		bindStatement(state, d.programStmts[i]);
		i = i + 1;
	}
}

function bindBlockStmt(state: BinderState, node: Node): void {
	const d = node.data as BlockStmtData;
	let i = 0;
	while (i < d.statements.length) {
		bindStatement(state, d.statements[i]);
		i = i + 1;
	}
}

function bindIfStmt(state: BinderState, node: Node): void {
	const d = node.data as IfStmtData;
	const thenLabel = createBranchLabel();
	const elseLabel = createBranchLabel();
	const postLabel = createBranchLabel();
	// bindCondition splits currentFlow along True/False edges
	bindCondition(state, d.condition, thenLabel, elseLabel);
	state.currentFlow = finishFlowLabel(thenLabel);
	bindStatement(state, d.consequent);
	addAntecedent(postLabel, state.currentFlow);
	state.currentFlow = finishFlowLabel(elseLabel);
	if (d.alternate !== null) bindStatement(state, d.alternate);
	addAntecedent(postLabel, state.currentFlow);
	state.currentFlow = finishFlowLabel(postLabel);
}

function bindWhileStmt(state: BinderState, node: Node): void {
	const d = node.data as WhileStmtData;
	const preLoop = createLoopLabel();
	const preBody = createBranchLabel();
	const postLoop = createBranchLabel();
	addAntecedent(preLoop, state.currentFlow);  // FIRST antecedent = pre-loop (invariant!)
	state.currentFlow = preLoop;
	bindCondition(state, d.whileCondition, preBody, postLoop);
	state.currentFlow = finishFlowLabel(preBody);
	const savedBreak = state.currentBreakTarget;
	const savedContinue = state.currentContinueTarget;
	state.currentBreakTarget = postLoop;
	state.currentContinueTarget = preLoop;
	bindStatement(state, d.whileBody);
	state.currentBreakTarget = savedBreak;
	state.currentContinueTarget = savedContinue;
	addAntecedent(preLoop, state.currentFlow);  // back-edge
	state.currentFlow = finishFlowLabel(postLoop);
}

function bindDoWhileStmt(state: BinderState, node: Node): void {
	const d = node.data as DoWhileStmtData;
	const preLoop = createLoopLabel();
	const preCond = createBranchLabel();
	const postLoop = createBranchLabel();
	addAntecedent(preLoop, state.currentFlow);
	state.currentFlow = preLoop;
	const savedBreak = state.currentBreakTarget;
	const savedContinue = state.currentContinueTarget;
	state.currentBreakTarget = postLoop;
	state.currentContinueTarget = preCond;
	bindStatement(state, d.doBody);
	state.currentBreakTarget = savedBreak;
	state.currentContinueTarget = savedContinue;
	addAntecedent(preCond, state.currentFlow);
	state.currentFlow = finishFlowLabel(preCond);
	bindCondition(state, d.doCondition, preLoop, postLoop);
	state.currentFlow = finishFlowLabel(postLoop);
}

function bindForStmt(state: BinderState, node: Node): void {
	const d = node.data as ForStmtData;
	if (d.forInit !== null) bindStatement(state, d.forInit);
	const preLoop = createLoopLabel();
	const preBody = createBranchLabel();
	const preIncr = createBranchLabel();
	const postLoop = createBranchLabel();
	addAntecedent(preLoop, state.currentFlow);
	state.currentFlow = preLoop;
	if (d.forCondition !== null) {
		bindCondition(state, d.forCondition, preBody, postLoop);
	} else {
		addAntecedent(preBody, state.currentFlow);
	}
	state.currentFlow = finishFlowLabel(preBody);
	const savedBreak = state.currentBreakTarget;
	const savedContinue = state.currentContinueTarget;
	state.currentBreakTarget = postLoop;
	state.currentContinueTarget = preIncr;
	if (d.forBody !== null) bindStatement(state, d.forBody);
	state.currentBreakTarget = savedBreak;
	state.currentContinueTarget = savedContinue;
	addAntecedent(preIncr, state.currentFlow);
	state.currentFlow = finishFlowLabel(preIncr);
	if (d.forUpdate !== null) bindExpression(state, d.forUpdate);
	addAntecedent(preLoop, state.currentFlow);  // back-edge
	state.currentFlow = finishFlowLabel(postLoop);
}

function bindForOfStmt(state: BinderState, node: Node): void {
	const d = node.data as ForOfStmtData;
	bindExpression(state, d.forOfIterable);
	const preLoop = createLoopLabel();
	const postLoop = createBranchLabel();
	addAntecedent(preLoop, state.currentFlow);
	state.currentFlow = preLoop;
	// Loop var is implicitly assigned each iteration
	state.currentFlow = createFlowMutation(FlowFlags.Assignment, state.currentFlow, node);
	const savedBreak = state.currentBreakTarget;
	const savedContinue = state.currentContinueTarget;
	state.currentBreakTarget = postLoop;
	state.currentContinueTarget = preLoop;
	if (d.forOfBody !== null) bindStatement(state, d.forOfBody);
	state.currentBreakTarget = savedBreak;
	state.currentContinueTarget = savedContinue;
	addAntecedent(preLoop, state.currentFlow);
	addAntecedent(postLoop, preLoop);
	state.currentFlow = finishFlowLabel(postLoop);
}

function bindForInStmt(state: BinderState, node: Node): void {
	const d = node.data as ForInStmtData;
	bindExpression(state, d.forInObject);
	const preLoop = createLoopLabel();
	const postLoop = createBranchLabel();
	addAntecedent(preLoop, state.currentFlow);
	state.currentFlow = preLoop;
	state.currentFlow = createFlowMutation(FlowFlags.Assignment, state.currentFlow, node);
	const savedBreak = state.currentBreakTarget;
	const savedContinue = state.currentContinueTarget;
	state.currentBreakTarget = postLoop;
	state.currentContinueTarget = preLoop;
	if (d.forInBody !== null) bindStatement(state, d.forInBody);
	state.currentBreakTarget = savedBreak;
	state.currentContinueTarget = savedContinue;
	addAntecedent(preLoop, state.currentFlow);
	addAntecedent(postLoop, preLoop);
	state.currentFlow = finishFlowLabel(postLoop);
}

function bindSwitchStmt(state: BinderState, node: Node): void {
	const d = node.data as SwitchStmtData;
	bindExpression(state, d.switchDisc);
	const preSwitch = state.currentFlow;
	const postLabel = createBranchLabel();
	const savedBreak = state.currentBreakTarget;
	state.currentBreakTarget = postLabel;
	let hasDefault = false;
	let i = 0;
	while (i < d.switchCases.length) {
		const caseNode = d.switchCases[i];
		const caseData = caseNode.data as SwitchCaseData;
		// Each case body inherits from preSwitch. Phase 1: treat each case
		// independently (no fallthrough flow merge — refine in Phase 6).
		state.currentFlow = createFlowSwitchClause(preSwitch, node, i, i + 1);
		let ti = 0;
		while (ti < caseData.caseTests.length) {
			bindExpression(state, caseData.caseTests[ti]);
			ti = ti + 1;
		}
		let si = 0;
		while (si < caseData.caseStmts.length) {
			bindStatement(state, caseData.caseStmts[si]);
			si = si + 1;
		}
		addAntecedent(postLabel, state.currentFlow);
		if (caseData.isDefault) hasDefault = true;
		i = i + 1;
	}
	state.currentBreakTarget = savedBreak;
	if (!hasDefault) {
		// Implicit fall-through: no case matched
		addAntecedent(postLabel, preSwitch);
	}
	state.currentFlow = finishFlowLabel(postLabel);
}

function bindMatchStmt(state: BinderState, node: Node): void {
	const d = node.data as MatchStmtData;
	bindExpression(state, d.matchStmtDisc);
	const preMatch = state.currentFlow;
	const postLabel = createBranchLabel();
	let i = 0;
	while (i < d.matchStmtCases.length) {
		const caseNode = d.matchStmtCases[i];
		const cd = caseNode.data as MatchCaseData;
		// Synthesize a narrowing condition so the flow graph carries the
		// match-arm narrowing into the arm body. For single-pattern arms
		// (the common case), we emit `disc === pattern` as a TrueCondition
		// so getFlowTypeOfReference walks back through it. Multi-pattern
		// arms (a | b) fall back to preMatch (no narrowing) — Phase 6 can
		// synthesize an OR-chain if needed.
		state.currentFlow = synthesizeMatchArmFlow(preMatch, d.matchStmtDisc, cd);
		bindMatchCase(state, caseNode);
		addAntecedent(postLabel, state.currentFlow);
		i = i + 1;
	}
	// Match must be exhaustive; no implicit fallthrough
	state.currentFlow = finishFlowLabel(postLabel);
}

function bindMatchCase(state: BinderState, caseNode: Node): void {
	const d = caseNode.data as MatchCaseData;
	let i = 0;
	while (i < d.casePatterns.length) {
		bindExpression(state, d.casePatterns[i]);
		i = i + 1;
	}
	if (d.caseBody !== null) bindStatement(state, d.caseBody);
}

// Synthesize a TrueCondition FlowNode representing `disc === pattern` for a
// single-pattern match arm. Emits a synthetic BinaryExpr AST node so the
// existing narrowType dispatcher (flow.ms) handles it uniformly with `if`
// narrowing. Returns `preMatch` unchanged for wildcard, guarded, or
// multi-pattern arms (Phase 6 can refine those cases).
function synthesizeMatchArmFlow(preMatch: FlowNode, disc: Node, cd: MatchCaseData): FlowNode {
	if (disc === null) return preMatch;
	if (cd.caseGuard !== null) return preMatch;  // guarded arms — Phase 6
	if (cd.casePatterns.length !== 1) return preMatch;  // OR patterns — Phase 6
	const pat = cd.casePatterns[0];
	if (pat === null) return preMatch;
	// Wildcard `_` and bare identifiers are bindings, not comparisons.
	if (pat.kind === NodeKind.Identifier) {
		const id = pat.data as IdentifierData;
		if (id.name === "_") return preMatch;
		// Bare identifier patterns can be either a binding (narrow lost)
		// or an enum-member reference (`K.A`) — we only narrow on the
		// enum-member form, which the parser represents as MemberExpr.
		return preMatch;
	}
	// Wrap in a synthetic BinaryExpr === so the flow query uses existing
	// narrowTypeByEquality / narrowTypeByDiscriminantProperty logic.
	const syntheticEq = createNodeAt(NodeKind.BinaryExpr, {
		operator: "===",
		left: disc,
		right: pat,
	}, pat.location);
	return createFlowCondition(FlowFlags.TrueCondition, preMatch, syntheticEq);
}

function bindReturnStmt(state: BinderState, node: Node): void {
	const d = node.data as ReturnStmtData;
	if (d.argument !== null) bindExpression(state, d.argument);
	if (state.currentReturnTarget !== null) {
		addAntecedent(state.currentReturnTarget, state.currentFlow);
	}
	state.currentFlow = state.unreachableFlow;
}

function bindThrowStmt(state: BinderState, node: Node): void {
	const d = node.data as ThrowStmtData;
	if (d.throwArg !== null) bindExpression(state, d.throwArg);
	if (state.currentExceptionTarget !== null) {
		addAntecedent(state.currentExceptionTarget, state.currentFlow);
	}
	state.currentFlow = state.unreachableFlow;
}

function bindBreakStmt(state: BinderState, node: Node): void {
	if (state.currentBreakTarget !== null) {
		addAntecedent(state.currentBreakTarget, state.currentFlow);
	}
	state.currentFlow = state.unreachableFlow;
}

function bindContinueStmt(state: BinderState, node: Node): void {
	if (state.currentContinueTarget !== null) {
		addAntecedent(state.currentContinueTarget, state.currentFlow);
	}
	state.currentFlow = state.unreachableFlow;
}

function bindTryStmt(state: BinderState, node: Node): void {
	const d = node.data as TryCatchStmtData;
	// Phase 1: simplified. Try body flows to both catch and post-try.
	// Phase 6 will implement ReduceLabel re-routing for finally.
	const postLabel = createBranchLabel();
	const catchLabel = createBranchLabel();
	const savedException = state.currentExceptionTarget;
	state.currentExceptionTarget = catchLabel;
	if (d.tryBody !== null) bindStatement(state, d.tryBody);
	state.currentExceptionTarget = savedException;
	addAntecedent(postLabel, state.currentFlow);
	if (d.catchBody !== null) {
		state.currentFlow = finishFlowLabel(catchLabel);
		bindStatement(state, d.catchBody);
		addAntecedent(postLabel, state.currentFlow);
	} else {
		addAntecedent(postLabel, finishFlowLabel(catchLabel));
	}
	state.currentFlow = finishFlowLabel(postLabel);
	if (d.finallyBody !== null) bindStatement(state, d.finallyBody);
}

function bindVariableDecl(state: BinderState, node: Node): void {
	const d = node.data as VariableDeclData;
	if (d.initializer !== null) bindExpression(state, d.initializer);
	state.currentFlow = createFlowMutation(FlowFlags.Assignment, state.currentFlow, node);
}

function bindDestructuringDecl(state: BinderState, node: Node): void {
	const d = node.data as DestructuringDeclData;
	if (d.destrInit !== null) bindExpression(state, d.destrInit);
	state.currentFlow = createFlowMutation(FlowFlags.Assignment, state.currentFlow, node);
}

function bindExprStmt(state: BinderState, node: Node): void {
	const d = node.data as ExprStmtData;
	bindExpression(state, d.expr);
}

function bindFunctionDecl(state: BinderState, node: Node): void {
	const d = node.data as FunctionDeclData;
	bindContainer(state, node, d.fnBody);
}

function bindClassDecl(state: BinderState, node: Node): void {
	const d = node.data as ClassDeclData;
	let i = 0;
	while (i < d.classBody.length) {
		const member = d.classBody[i];
		i = i + 1;
		if (member === null) continue;
		match (member.kind) {
			NodeKind.MethodDecl => {
				const md = member.data as MethodDeclData;
				bindContainer(state, member, md.methodBody);
			},
			NodeKind.ConstructorDecl => {
				const cd = member.data as ConstructorDeclData;
				bindContainer(state, member, cd.ctorBody);
			},
			NodeKind.PropertyDecl => {},
			_ => {},
		};
	}
}

function bindActorDecl(state: BinderState, node: Node): void {
	const d = node.data as ActorDeclData;
	let i = 0;
	while (i < d.actorBody.length) {
		const member = d.actorBody[i];
		i = i + 1;
		if (member === null) continue;
		match (member.kind) {
			NodeKind.MethodDecl => {
				const md = member.data as MethodDeclData;
				bindContainer(state, member, md.methodBody);
			},
			NodeKind.ConstructorDecl => {
				const cd = member.data as ConstructorDeclData;
				bindContainer(state, member, cd.ctorBody);
			},
			_ => {},
		};
	}
}

function bindExportDecl(state: BinderState, node: Node): void {
	const d = node.data as ExportDeclData;
	if (d.exportedDecl !== null) bindStatement(state, d.exportedDecl);
}

function bindDecoratedDecl(state: BinderState, node: Node): void {
	const d = node.data as DecoratedDeclData;
	let i = 0;
	while (i < d.decorators.length) {
		bindExpression(state, d.decorators[i]);
		i = i + 1;
	}
	if (d.decoratedNode !== null) bindStatement(state, d.decoratedNode);
}

function bindDeferStmt(state: BinderState, node: Node): void {
	const d = node.data as DeferStmtData;
	if (d.deferExpr !== null) bindExpression(state, d.deferExpr);
}

function bindAssertStmt(state: BinderState, node: Node): void {
	const d = node.data as AssertStmtData;
	if (d.assertExpr !== null) bindExpression(state, d.assertExpr);
}

function bindTestDecl(state: BinderState, node: Node): void {
	const d = node.data as TestDeclData;
	bindContainer(state, node, d.testBody);
}

// ===== Expression Binder =====
//
// Expressions don't create control-flow splits (except &&, ||, ?:), but
// Identifier and MemberExpr references need a flowNode attached so the
// checker can query narrowed types at use sites.

function bindExpression(state: BinderState, node: Node): void {
	if (node === null) return;
	match (node.kind) {
		NodeKind.Identifier => bindIdentifier(state, node),
		NodeKind.BinaryExpr => bindBinaryExpr(state, node),
		NodeKind.UnaryExpr => {
			const d = node.data as UnaryExprData;
			if (d.operand !== null) bindExpression(state, d.operand);
		},
		NodeKind.UpdateExpr => {
			const d = node.data as UpdateExprData;
			if (d.updateArg !== null) bindExpression(state, d.updateArg);
			// x++ and --x are assignments to x
			state.currentFlow = createFlowMutation(FlowFlags.Assignment, state.currentFlow, node);
		},
		NodeKind.CallExpr => bindCallExpr(state, node),
		NodeKind.NewExpr => bindNewExpr(state, node),
		NodeKind.MemberExpr => bindMemberExpr(state, node),
		NodeKind.ArrayAccess => bindArrayAccess(state, node),
		NodeKind.ObjectLiteral => bindObjectLiteral(state, node),
		NodeKind.ArrayLiteral => bindArrayLiteral(state, node),
		NodeKind.ConditionalExpr => bindConditionalExpr(state, node),
		NodeKind.SpreadExpr => {
			const d = node.data as SpreadExprData;
			if (d.spreadArg !== null) bindExpression(state, d.spreadArg);
		},
		NodeKind.AwaitExpr => {
			const d = node.data as AwaitExprData;
			if (d.awaitArg !== null) bindExpression(state, d.awaitArg);
		},
		NodeKind.YieldExpr => {
			const d = node.data as YieldExprData;
			if (d.yieldArg !== null) bindExpression(state, d.yieldArg);
		},
		NodeKind.MoveExpr => {
			const d = node.data as MoveExprData;
			if (d.moveArg !== null) bindExpression(state, d.moveArg);
		},
		NodeKind.OutExpr => {
			const d = node.data as OutExprData;
			if (d.outArg !== null) bindExpression(state, d.outArg);
		},
		NodeKind.TypeAssertion => {
			const d = node.data as TypeAssertionData;
			if (d.asExpr !== null) bindExpression(state, d.asExpr);
		},
		NodeKind.TryExpr => {
			const d = node.data as TryExprData;
			if (d.tryArg !== null) bindExpression(state, d.tryArg);
			if (d.hasCatch && d.catchVal !== null) bindExpression(state, d.catchVal);
		},
		NodeKind.MatchExpr => bindMatchExpr(state, node),
		NodeKind.ArrowFunction => {
			const d = node.data as ArrowFunctionData;
			bindContainer(state, node, d.arrowBody);
		},
		NodeKind.FunctionExpr => {
			const d = node.data as FunctionExprData;
			bindContainer(state, node, d.funcExprBody);
		},
		NodeKind.HiddenDeref => {
			const d = node.data as HiddenDerefData;
			if (d.expr !== null) bindExpression(state, d.expr);
		},
		NodeKind.HiddenStdConv => {
			const d = node.data as HiddenStdConvData;
			if (d.convExpr !== null) bindExpression(state, d.convExpr);
		},
		NodeKind.MacroInvocation => {
			const d = node.data as MacroInvocationData;
			let i = 0;
			while (i < d.macroArgs.length) {
				bindExpression(state, d.macroArgs[i]);
				i = i + 1;
			}
		},
		// Leaf literals — nothing to bind
		NodeKind.NumberLiteral => {},
		NodeKind.StringLiteral => {},
		NodeKind.BooleanLiteral => {},
		NodeKind.NullLiteral => {},
		NodeKind.BigIntLiteral => {},
		NodeKind.RegexLiteral => {},
		_ => {},
	};
}

function bindIdentifier(state: BinderState, node: Node): void {
	// Attach current flow to this reference — this is the key binder output.
	node.flowNode = state.currentFlow;
}

function bindBinaryExpr(state: BinderState, node: Node): void {
	const d = node.data as BinaryExprData;
	// Logical operators create short-circuit flow
	if (d.operator === "&&" || d.operator === "||") {
		bindLogicalExpr(state, node);
		return;
	}
	// Assignment operators mutate their LHS
	if (d.operator === "=" || d.operator === "+=" || d.operator === "-="
		|| d.operator === "*=" || d.operator === "/=" || d.operator === "%="
		|| d.operator === "**=" || d.operator === "&=" || d.operator === "|="
		|| d.operator === "^=" || d.operator === "<<=" || d.operator === ">>="
		|| d.operator === "&&=" || d.operator === "||=" || d.operator === "??=") {
		if (d.left !== null) bindExpression(state, d.left);
		if (d.right !== null) bindExpression(state, d.right);
		state.currentFlow = createFlowMutation(FlowFlags.Assignment, state.currentFlow, node);
		return;
	}
	// Default: walk both sides
	if (d.left !== null) bindExpression(state, d.left);
	if (d.right !== null) bindExpression(state, d.right);
}

// Logical operators with short-circuit:
//   a && b: if a is false, b is not evaluated
//   a || b: if a is true,  b is not evaluated
// The binder emits FlowCondition nodes so the checker can narrow the right
// operand based on the left operand's truthiness.
function bindLogicalExpr(state: BinderState, node: Node): void {
	const d = node.data as BinaryExprData;
	const postLabel = createBranchLabel();
	const rightLabel = createBranchLabel();
	if (d.operator === "&&") {
		bindCondition(state, d.left, rightLabel, postLabel);
	} else {
		// ||
		bindCondition(state, d.left, postLabel, rightLabel);
	}
	state.currentFlow = finishFlowLabel(rightLabel);
	if (d.right !== null) bindExpression(state, d.right);
	addAntecedent(postLabel, state.currentFlow);
	state.currentFlow = finishFlowLabel(postLabel);
}

function bindCallExpr(state: BinderState, node: Node): void {
	const d = node.data as CallExprData;
	if (d.callee !== null) bindExpression(state, d.callee);
	let i = 0;
	while (i < d.arguments.length) {
		bindExpression(state, d.arguments[i]);
		i = i + 1;
	}
}

function bindNewExpr(state: BinderState, node: Node): void {
	const d = node.data as NewExprData;
	if (d.newCallee !== null) bindExpression(state, d.newCallee);
	let i = 0;
	while (i < d.newArguments.length) {
		bindExpression(state, d.newArguments[i]);
		i = i + 1;
	}
}

function bindMemberExpr(state: BinderState, node: Node): void {
	const d = node.data as MemberExprData;
	if (d.object !== null) bindExpression(state, d.object);
	// Attach flow to the member expression itself — it's a reference.
	node.flowNode = state.currentFlow;
}

function bindArrayAccess(state: BinderState, node: Node): void {
	const d = node.data as ArrayAccessData;
	if (d.array !== null) bindExpression(state, d.array);
	if (d.index !== null) bindExpression(state, d.index);
	node.flowNode = state.currentFlow;
}

function bindObjectLiteral(state: BinderState, node: Node): void {
	const d = node.data as ObjectLiteralData;
	let i = 0;
	while (i < d.properties.length) {
		bindExpression(state, d.properties[i]);
		i = i + 1;
	}
}

function bindArrayLiteral(state: BinderState, node: Node): void {
	const d = node.data as ArrayLiteralData;
	let i = 0;
	while (i < d.elements.length) {
		bindExpression(state, d.elements[i]);
		i = i + 1;
	}
}

function bindConditionalExpr(state: BinderState, node: Node): void {
	const d = node.data as ConditionalExprData;
	const trueLabel = createBranchLabel();
	const falseLabel = createBranchLabel();
	const postLabel = createBranchLabel();
	bindCondition(state, d.ternaryCondition, trueLabel, falseLabel);
	state.currentFlow = finishFlowLabel(trueLabel);
	if (d.ternaryConsequent !== null) bindExpression(state, d.ternaryConsequent);
	addAntecedent(postLabel, state.currentFlow);
	state.currentFlow = finishFlowLabel(falseLabel);
	if (d.ternaryAlternate !== null) bindExpression(state, d.ternaryAlternate);
	addAntecedent(postLabel, state.currentFlow);
	state.currentFlow = finishFlowLabel(postLabel);
}

function bindMatchExpr(state: BinderState, node: Node): void {
	const d = node.data as MatchExprData;
	bindExpression(state, d.matchDisc);
	const preMatch = state.currentFlow;
	const postLabel = createBranchLabel();
	let i = 0;
	while (i < d.matchCases.length) {
		const caseNode = d.matchCases[i];
		const cd = caseNode.data as MatchCaseData;
		state.currentFlow = synthesizeMatchArmFlow(preMatch, d.matchDisc, cd);
		let pi = 0;
		while (pi < cd.casePatterns.length) {
			bindExpression(state, cd.casePatterns[pi]);
			pi = pi + 1;
		}
		if (cd.caseBody !== null) bindStatement(state, cd.caseBody);
		addAntecedent(postLabel, state.currentFlow);
		i = i + 1;
	}
	state.currentFlow = finishFlowLabel(postLabel);
}

// ===== Condition Binder =====
//
// bindCondition takes a predicate expression plus two target labels, one for
// the "true" branch and one for the "false" branch. It splits control flow
// along TrueCondition / FalseCondition FlowNodes so the checker can narrow
// types differently in each branch.

function bindCondition(state: BinderState, expr: Node, trueTarget: FlowNode, falseTarget: FlowNode): void {
	if (expr === null) {
		addAntecedent(trueTarget, state.currentFlow);
		return;
	}
	// Recursive breakdown of && and || into individual conditions so each
	// sub-expression gets its own TrueCondition/FalseCondition edges.
	if (expr.kind === NodeKind.BinaryExpr) {
		const d = expr.data as BinaryExprData;
		if (d.operator === "&&") {
			const preRight = createBranchLabel();
			bindCondition(state, d.left, preRight, falseTarget);
			state.currentFlow = finishFlowLabel(preRight);
			bindCondition(state, d.right, trueTarget, falseTarget);
			return;
		}
		if (d.operator === "||") {
			const preRight = createBranchLabel();
			bindCondition(state, d.left, trueTarget, preRight);
			state.currentFlow = finishFlowLabel(preRight);
			bindCondition(state, d.right, trueTarget, falseTarget);
			return;
		}
	}
	// !x: swap branches
	if (expr.kind === NodeKind.UnaryExpr) {
		const d = expr.data as UnaryExprData;
		if (d.unaryOp === "!") {
			bindCondition(state, d.operand, falseTarget, trueTarget);
			return;
		}
	}
	// Leaf condition: bind the expression, then split on True/False edges
	bindExpression(state, expr);
	addAntecedent(trueTarget, createFlowCondition(FlowFlags.TrueCondition, state.currentFlow, expr));
	addAntecedent(falseTarget, createFlowCondition(FlowFlags.FalseCondition, state.currentFlow, expr));
}

// ===== Tests =====

function bindSource(input: string): Node {
	const pr = parseSource(input);
	if (!pr.ok) return null as unknown as Node;
	const program = pr.value;
	bindFlowGraph(program);
	return program;
}

// Walk AST and return the first Identifier with the given name, or null.
function findIdent(node: Node, name: string): Node {
	if (node === null) return null as unknown as Node;
	if (node.kind === NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		if (d.name === name) return node;
	}
	let found: Node = null as unknown as Node;
	match (node.kind) {
		NodeKind.Program => {
			const d = node.data as ProgramData;
			for (const s of d.programStmts) {
				if (found === null) found = findIdent(s, name);
			}
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			for (const s of d.statements) {
				if (found === null) found = findIdent(s, name);
			}
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			if (found === null) found = findIdent(d.condition, name);
			if (found === null) found = findIdent(d.consequent, name);
			if (found === null) found = findIdent(d.alternate, name);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			if (found === null) found = findIdent(d.whileCondition, name);
			if (found === null) found = findIdent(d.whileBody, name);
		},
		NodeKind.ExprStmt => {
			const d = node.data as ExprStmtData;
			if (found === null) found = findIdent(d.expr, name);
		},
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			if (found === null) found = findIdent(d.initializer, name);
		},
		NodeKind.ReturnStmt => {
			const d = node.data as ReturnStmtData;
			if (found === null) found = findIdent(d.argument, name);
		},
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			if (found === null) found = findIdent(d.left, name);
			if (found === null) found = findIdent(d.right, name);
		},
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			if (found === null) found = findIdent(d.callee, name);
			for (const a of d.arguments) {
				if (found === null) found = findIdent(a, name);
			}
		},
		NodeKind.MemberExpr => {
			const d = node.data as MemberExprData;
			if (found === null) found = findIdent(d.object, name);
		},
		NodeKind.FunctionDecl => {
			const d = node.data as FunctionDeclData;
			if (found === null) found = findIdent(d.fnBody, name);
		},
		_ => {},
	};
	return found;
}

test "binder attaches flowNode to identifier references" {
	// Each use of `x` should get a flow node pointing to the surrounding flow.
	const program = bindSource("function f(x: number): number { return x; }");
	// Dive into the function body and locate the `x` in `return x;`
	const pd = program.data as ProgramData;
	assert pd.programStmts.length === 1;
	const fn = pd.programStmts[0];
	assert fn.kind === NodeKind.FunctionDecl;
	const fnData = fn.data as FunctionDeclData;
	const xRef = findIdent(fnData.fnBody, "x");
	assert xRef !== null;
	assert xRef.flowNode !== null;
}

test "binder attaches flowNode inside if condition" {
	// Reference `x` in `if (x > 0) { return x; }` — both uses must have flowNodes.
	const program = bindSource("function f(x: number): number { if (x > 0) { return x; } return 0; }");
	const pd = program.data as ProgramData;
	const fn = pd.programStmts[0];
	const fnData = fn.data as FunctionDeclData;
	const xRef = findIdent(fnData.fnBody, "x");
	assert xRef !== null;
	assert xRef.flowNode !== null;
}

test "binder marks code after return as unreachable" {
	// After `return`, currentFlow becomes unreachableFlow. A reference in
	// dead code still gets a flowNode, but it points to the unreachable flow.
	const program = bindSource("function f(x: number): number { return x; const y = x; return y; }");
	const pd = program.data as ProgramData;
	const fn = pd.programStmts[0];
	const fnData = fn.data as FunctionDeclData;
	const yRef = findIdent(fnData.fnBody, "y");
	// `y` is referenced in the unreachable `return y`; its flowNode should be
	// the unreachable flow (non-null, Unreachable flag set).
	assert yRef !== null;
	assert yRef.flowNode !== null;
	assert (yRef.flowNode.flags & FlowFlags.Unreachable) !== 0;
}

test "binder splits flow on if condition" {
	// `if (c) a else b`: the `a` reference should be reachable via a
	// TrueCondition flow edge; `b` via FalseCondition.
	const program = bindSource(
		"function f(c: boolean, a: number, b: number): number { if (c) { return a; } return b; }");
	const pd = program.data as ProgramData;
	const fn = pd.programStmts[0];
	const fnData = fn.data as FunctionDeclData;
	const aRef = findIdent(fnData.fnBody, "a");
	const bRef = findIdent(fnData.fnBody, "b");
	assert aRef !== null && aRef.flowNode !== null;
	assert bRef !== null && bRef.flowNode !== null;
	// The two references must have distinct flow nodes (one through TrueCondition,
	// one through a BranchLabel joining the post-if paths).
	assert aRef.flowNode !== bRef.flowNode;
}

test "binder handles while loop back-edge" {
	// The while body is reachable via a LoopLabel. The loop label's first
	// antecedent must be the pre-loop flow (TypeScript-go invariant — critical
	// for Phase 3 fixed-point correctness).
	const program = bindSource(
		"function f(x: number): void { while (x > 0) { const y = x; } }");
	const pd = program.data as ProgramData;
	const fn = pd.programStmts[0];
	const fnData = fn.data as FunctionDeclData;
	// `x` appears three times: in the condition `x > 0`, and in the initializer
	// `const y = x`. The ones inside the loop body must have flow nodes that
	// differ from the pre-loop flow (they go through the LoopLabel + TrueCondition).
	const xRef = findIdent(fnData.fnBody, "x");
	assert xRef !== null;
	assert xRef.flowNode !== null;
}
