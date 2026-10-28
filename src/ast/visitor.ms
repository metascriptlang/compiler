// forEachChild — canonical read-only child enumerator for all NodeKinds.
// Single source of truth for "what are the child nodes of this NodeKind?"
// Used by analysis passes (reachability, DCE, LSP suggest, validate).
// mapChildren, at the end of this file, is the MUTATING variant used by transform passes.
// SYNC: mapChildren must handle the same NodeKinds as forEachChild.

import {
	Node, NodeKind, createNodeAt, makeLoc, IdentifierData,
	ProgramData, BlockStmtData, IfStmtData, WhileStmtData, ForStmtData,
	ForOfStmtData, ForInStmtData, DoWhileStmtData, SwitchStmtData, SwitchCaseData,
	FunctionDeclData, ArrowFunctionData, FunctionExprData, EnumDeclData,
	ClassDeclData, ActorDeclData, MethodDeclData, ConstructorDeclData, PropertyDeclData,
	ExportDeclData, DecoratedDeclData, MacroDeclData,
	VariableDeclData, ReturnStmtData, ThrowStmtData, ExprStmtData,
	TryCatchStmtData, DeferStmtData,
	BinaryExprData, UnaryExprData, UpdateExprData,
	CallExprData, MemberExprData, ArrayAccessData,
	ObjectLiteralData, ArrayLiteralData, ConditionalExprData,
	SpreadExprData, NewExprData, TryExprData,
	MatchExprData, MatchStmtData, MatchCaseData,
	AwaitExprData, YieldExprData, MoveExprData, OutExprData,
	HiddenDerefData, HiddenStdConvData,
	TypeAssertionData, DestructuringDeclData, QuoteExprData, ComptimeBlockData,
	MacroInvocationData, TestDeclData, AssertStmtData,
	ArrayPatternData, ObjectPatternData, ObjectPatternPropData,
	TypeGenericData, TypeArrayData, TypeUnionData, TypeIntersectionData, TypeFunctionData, TypeObjectData,
	SpliceManyData,
	JSXElementData, JSXFragmentData, JSXExpressionContainerData, JSXAttributeData, JSXSpreadAttributeData, ComputedPropertyData,
} from "./node";

type ChildVisitor = (child: Node) => void;

// Visitor function: takes a node, returns replacement (or same node if unchanged)
export type Visitor = (node: Node) => Node;

// Check if a node is a function boundary (FunctionDecl, ArrowFunction, FunctionExpr)
export function isFuncBoundary(node: Node): boolean {
	return node.kind == NodeKind.FunctionDecl ||
		node.kind == NodeKind.ArrowFunction ||
		node.kind == NodeKind.FunctionExpr;
}

export function anyChild(node: Node, test: (child: Node) => boolean): boolean {
	let found = false;
	forEachChild(node, (child: Node): void => {
		if (!found && test(child)) found = true;
	});
	return found;
}

export enum Visit { Descend, Hit, Skip }

export function anyDescendant(node: Node | null, verdict: (n: Node) => Visit): boolean {
	let found = false;
	const scan = (c: Node | null): void => {
		if (found || c == null) return;
		const v = verdict(c);
		if (v == Visit.Hit) { found = true; return; }
		if (v == Visit.Skip) return;
		forEachChild(c, scan);
	};
	scan(node);
	return found;
}

function nameNode(name: string): Node {
	return createNodeAt(NodeKind.Identifier, { name }, makeLoc(1, 1));
}

function blockNode(stmts: Node[]): Node {
	return createNodeAt(NodeKind.BlockStmt, { statements: stmts }, makeLoc(1, 1));
}

function isNamed(n: Node, name: string): boolean {
	return n.kind == NodeKind.Identifier && (n.data as IdentifierData).name == name;
}

function hitNamed(name: string): (n: Node) => Visit {
	return (n: Node): Visit => isNamed(n, name) ? Visit.Hit : Visit.Descend;
}

test "anyChild: a match among the direct children" {
	const root = blockNode([nameNode("a"), nameNode("b")]);
	assert anyChild(root, (c: Node): boolean => isNamed(c, "b"));
}

test "anyChild: a match one level down is not a direct child" {
	const root = blockNode([nameNode("a"), blockNode([nameNode("b")])]);
	assert !anyChild(root, (c: Node): boolean => isNamed(c, "b"));
}

test "anyChild: no match, and a leaf has no children" {
	assert !anyChild(blockNode([nameNode("a")]), (c: Node): boolean => isNamed(c, "z"));
	assert !anyChild(nameNode("a"), (c: Node): boolean => true);
}

test "anyChild: stops testing after the first match" {
	const root = blockNode([nameNode("a"), nameNode("a"), nameNode("a")]);
	let calls = 0;
	assert anyChild(root, (c: Node): boolean => { calls += 1; return true; });
	assert calls == 1;
}

test "anyDescendant: a match at any depth, the node itself included" {
	const deep = blockNode([nameNode("a"), blockNode([blockNode([nameNode("b")])])]);
	assert anyDescendant(deep, hitNamed("b"));
	assert anyDescendant(nameNode("b"), hitNamed("b"));
}

test "anyDescendant: no match, and a null node" {
	const root = blockNode([nameNode("a"), blockNode([nameNode("b")])]);
	assert !anyDescendant(root, hitNamed("z"));
	assert !anyDescendant(null, (n: Node): Visit => Visit.Hit);
}

test "anyDescendant: does not descend into a skipped node" {
	const root = blockNode([nameNode("a"), blockNode([nameNode("b")])]);
	const skipBlock = (n: Node): Visit => n.kind == NodeKind.BlockStmt && n != root ? Visit.Skip : isNamed(n, "b") ? Visit.Hit : Visit.Descend;
	assert !anyDescendant(root, skipBlock);
}

test "anyDescendant: stops testing after the first match" {
	const root = blockNode([nameNode("a"), nameNode("a"), blockNode([nameNode("a")])]);
	let calls = 0;
	assert anyDescendant(root, (n: Node): Visit => { calls += 1; return n.kind == NodeKind.Identifier ? Visit.Hit : Visit.Descend; });
	assert calls == 2;
}

function numNode(v: float64): Node {
	return createNodeAt(NodeKind.NumberLiteral, { value: v, isFloat: false }, makeLoc(1, 1));
}

function childrenOf(n: Node): Node[] {
	const out: Node[] = [];
	forEachChild(n, (c: Node): void => { out.push(c); });
	return out;
}

test "forEachChild: an enum visits each member initialiser and skips a member without one" {
	const a = numNode(1);
	const b = numNode(2);
	const none = null as unknown as Node;
	const decl = createNodeAt(NodeKind.EnumDecl, { enumName: "E", enumMembers: ["A", "B", "C"], enumValues: [1, 0, 2], nameLocation: makeLoc(1, 1), memberLocations: [], enumInits: [a, none, b] }, makeLoc(1, 1));
	const seen = childrenOf(decl);
	assert seen.length == 2 && seen[0] == a && seen[1] == b;
}

test "mapChildren: an enum rewrites each member initialiser in place" {
	const a = numNode(1);
	const none = null as unknown as Node;
	const repl = numNode(9);
	const decl = createNodeAt(NodeKind.EnumDecl, { enumName: "E", enumMembers: ["A", "B"], enumValues: [1, 0], nameLocation: makeLoc(1, 1), memberLocations: [], enumInits: [a, none] }, makeLoc(1, 1));
	mapChildren(decl, (n: Node): Node => repl);
	const inits = (decl.data as EnumDeclData).enumInits;
	assert inits[0] == repl && inits[1] == null;
}

test "forEachChild: a decorated declaration visits its decorators before the declaration" {
	const dec = createNodeAt(NodeKind.MacroInvocation, { macroName: "tag", macroArgs: [], macroHasParens: false }, makeLoc(1, 1));
	const inner = blockNode([]);
	const decorated = createNodeAt(NodeKind.DecoratedDecl, { decorators: [dec], decoratedNode: inner }, makeLoc(1, 1));
	const seen = childrenOf(decorated);
	assert seen.length == 2 && seen[0] == dec && seen[1] == inner;
}

test "mapChildren: a decorated declaration rewrites its decorators and the declaration" {
	const dec = createNodeAt(NodeKind.MacroInvocation, { macroName: "tag", macroArgs: [], macroHasParens: false }, makeLoc(1, 1));
	const inner = blockNode([]);
	const decorated = createNodeAt(NodeKind.DecoratedDecl, { decorators: [dec], decoratedNode: inner }, makeLoc(1, 1));
	const repl = nameNode("r");
	mapChildren(decorated, (n: Node): Node => repl);
	const d = decorated.data as DecoratedDeclData;
	assert d.decorators[0] == repl && d.decoratedNode == repl;
}

export function literalHeldClosures(init: Node, out: Node[]): void {
	if (init.kind == NodeKind.ArrowFunction || init.kind == NodeKind.FunctionExpr) {
		out.push(init);
	} else if (init.kind == NodeKind.ObjectLiteral) {
		for (const p of (init.data as ObjectLiteralData).properties) literalHeldClosures(p, out);
	} else if (init.kind == NodeKind.ArrayLiteral) {
		for (const e of (init.data as ArrayLiteralData).elements) literalHeldClosures(e, out);
	}
}

export function initializerHoldsClosure(init: Node | null): boolean {
	if (init == null) return false;
	const held: Node[] = [];
	literalHeldClosures(init, held);
	return held.length > 0;
}

// Visit all child nodes of a given node (read-only, no mutation).
function visitChild(cb: ChildVisitor, n: Node | null): void {
	if (n != null) cb(n);
}

function visitAll(cb: ChildVisitor, nodes: Node[]): void {
	for (let i = 0; i < nodes.length; i++) visitChild(cb, nodes[i]);
}

export function forEachChild(node: Node, cb: ChildVisitor): void {
	if (node == null) return;
	match (node.kind) {
		// Program root
		NodeKind.Program => {
			const d: Cursor<ProgramData> = node.data as ProgramData;
			visitAll(cb, d.programStmts);
		},
		// SpliceMany — A2 macro multi-decl emission
		NodeKind.SpliceMany => {
			const d: Cursor<SpliceManyData> = node.data as SpliceManyData;
			visitAll(cb, d.spliceNodes);
		},
		// Block
		NodeKind.BlockStmt => {
			const d: Cursor<BlockStmtData> = node.data as BlockStmtData;
			visitAll(cb, d.statements);
		},
		// Statements with child nodes
		NodeKind.IfStmt => {
			const d: Cursor<IfStmtData> = node.data as IfStmtData;
			visitChild(cb, d.condition);
			visitChild(cb, d.consequent);
			visitChild(cb, d.alternate);
		},
		NodeKind.WhileStmt => {
			const d: Cursor<WhileStmtData> = node.data as WhileStmtData;
			visitChild(cb, d.whileCondition);
			visitChild(cb, d.whileBody);
		},
		NodeKind.ForStmt => {
			const d: Cursor<ForStmtData> = node.data as ForStmtData;
			visitChild(cb, d.forInit);
			visitChild(cb, d.forCondition);
			visitChild(cb, d.forUpdate);
			visitChild(cb, d.forBody);
		},
		NodeKind.ForOfStmt => {
			const d: Cursor<ForOfStmtData> = node.data as ForOfStmtData;
			visitChild(cb, d.forOfIterable);
			visitChild(cb, d.forOfBody);
			visitChild(cb, d.forOfPattern);
		},
		NodeKind.ForInStmt => {
			const d: Cursor<ForInStmtData> = node.data as ForInStmtData;
			visitChild(cb, d.forInObject);
			visitChild(cb, d.forInBody);
		},
		NodeKind.DoWhileStmt => {
			const d: Cursor<DoWhileStmtData> = node.data as DoWhileStmtData;
			visitChild(cb, d.doBody);
			visitChild(cb, d.doCondition);
		},
		NodeKind.SwitchStmt => {
			const d: Cursor<SwitchStmtData> = node.data as SwitchStmtData;
			visitChild(cb, d.switchDisc);
			visitAll(cb, d.switchCases);
		},
		NodeKind.SwitchCase => {
			const d: Cursor<SwitchCaseData> = node.data as SwitchCaseData;
			visitAll(cb, d.caseTests);
			visitAll(cb, d.caseStmts);
		},
		NodeKind.MatchStmt => {
			const d: Cursor<MatchStmtData> = node.data as MatchStmtData;
			visitChild(cb, d.matchStmtDisc);
			visitAll(cb, d.matchStmtCases);
		},
		NodeKind.MatchExpr => {
			const d: Cursor<MatchExprData> = node.data as MatchExprData;
			visitChild(cb, d.matchDisc);
			visitAll(cb, d.matchCases);
		},
		NodeKind.MatchCase => {
			const d: Cursor<MatchCaseData> = node.data as MatchCaseData;
			visitAll(cb, d.casePatterns);
			visitChild(cb, d.caseGuard);
			visitChild(cb, d.caseBody);
		},
		// Declarations with bodies
		NodeKind.FunctionDecl => {
			const d: Cursor<FunctionDeclData> = node.data as FunctionDeclData;
			visitChild(cb, d.fnBody);
		},
		NodeKind.ArrowFunction => {
			const d: Cursor<ArrowFunctionData> = node.data as ArrowFunctionData;
			visitChild(cb, d.arrowBody);
		},
		NodeKind.FunctionExpr => {
			const d: Cursor<FunctionExprData> = node.data as FunctionExprData;
			visitChild(cb, d.funcExprBody);
		},
		NodeKind.ClassDecl => {
			const d: Cursor<ClassDeclData> = node.data as ClassDeclData;
			visitAll(cb, d.classBody);
		},
		NodeKind.MethodDecl => {
			const d: Cursor<MethodDeclData> = node.data as MethodDeclData;
			visitChild(cb, d.methodBody);
		},
		NodeKind.ConstructorDecl => {
			const d: Cursor<ConstructorDeclData> = node.data as ConstructorDeclData;
			visitChild(cb, d.ctorBody);
			for (const p of d.ctorParamProps) visitChild(cb, p);
		},
		NodeKind.ExportDecl => {
			const d: Cursor<ExportDeclData> = node.data as ExportDeclData;
			visitChild(cb, d.exportedDecl);
		},
		NodeKind.DecoratedDecl => {
			const d: Cursor<DecoratedDeclData> = node.data as DecoratedDeclData;
			visitAll(cb, d.decorators);
			visitChild(cb, d.decoratedNode);
		},
		NodeKind.EnumDecl => {
			const d: Cursor<EnumDeclData> = node.data as EnumDeclData;
			visitAll(cb, d.enumInits);
		},
		NodeKind.MacroDecl => {
			const d: Cursor<MacroDeclData> = node.data as MacroDeclData;
			visitChild(cb, d.macroDeclBody);
		},
		// Simple statements with one child
		NodeKind.VariableDecl => {
			const d: Cursor<VariableDeclData> = node.data as VariableDeclData;
			visitChild(cb, d.initializer);
		},
		NodeKind.ReturnStmt => {
			const d: Cursor<ReturnStmtData> = node.data as ReturnStmtData;
			visitChild(cb, d.argument!);
		},
		NodeKind.ThrowStmt => {
			const d: Cursor<ThrowStmtData> = node.data as ThrowStmtData;
			visitChild(cb, d.throwArg);
		},
		NodeKind.ExprStmt => {
			const d: Cursor<ExprStmtData> = node.data as ExprStmtData;
			visitChild(cb, d.expr);
		},
		NodeKind.DeferStmt => {
			const d: Cursor<DeferStmtData> = node.data as DeferStmtData;
			visitChild(cb, d.deferExpr);
		},
		NodeKind.TryCatchStmt => {
			const d: Cursor<TryCatchStmtData> = node.data as TryCatchStmtData;
			visitChild(cb, d.tryBody);
			visitChild(cb, d.catchBody);
			visitChild(cb, d.finallyBody);
		},
		// Expressions
		NodeKind.BinaryExpr => {
			const d: Cursor<BinaryExprData> = node.data as BinaryExprData;
			visitChild(cb, d.left);
			visitChild(cb, d.right);
		},
		NodeKind.UnaryExpr => {
			const d: Cursor<UnaryExprData> = node.data as UnaryExprData;
			visitChild(cb, d.operand);
		},
		NodeKind.UpdateExpr => {
			const d: Cursor<UpdateExprData> = node.data as UpdateExprData;
			visitChild(cb, d.updateArg);
		},
		NodeKind.CallExpr => {
			const d: Cursor<CallExprData> = node.data as CallExprData;
			visitChild(cb, d.callee);
			visitAll(cb, d.arguments);
		},
		NodeKind.MemberExpr => {
			const d: Cursor<MemberExprData> = node.data as MemberExprData;
			visitChild(cb, d.object);
		},
		NodeKind.ArrayAccess => {
			const d: Cursor<ArrayAccessData> = node.data as ArrayAccessData;
			visitChild(cb, d.array);
			visitChild(cb, d.index);
		},
		NodeKind.ObjectLiteral => {
			const d: Cursor<ObjectLiteralData> = node.data as ObjectLiteralData;
			visitAll(cb, d.properties);
		},
		NodeKind.ArrayLiteral => {
			const d: Cursor<ArrayLiteralData> = node.data as ArrayLiteralData;
			visitAll(cb, d.elements);
		},
		NodeKind.ConditionalExpr => {
			const d: Cursor<ConditionalExprData> = node.data as ConditionalExprData;
			visitChild(cb, d.ternaryCondition);
			visitChild(cb, d.ternaryConsequent);
			visitChild(cb, d.ternaryAlternate);
		},
		NodeKind.SpreadExpr => {
			const d: Cursor<SpreadExprData> = node.data as SpreadExprData;
			visitChild(cb, d.spreadArg);
		},
		NodeKind.NewExpr => {
			const d: Cursor<NewExprData> = node.data as NewExprData;
			visitChild(cb, d.newCallee);
			visitAll(cb, d.newArguments);
		},
		NodeKind.TryExpr => {
			const d: Cursor<TryExprData> = node.data as TryExprData;
			visitChild(cb, d.tryArg);
			if (d.hasCatch) { visitChild(cb, d.catchVal); }
		},
		NodeKind.AwaitExpr => {
			const d: Cursor<AwaitExprData> = node.data as AwaitExprData;
			visitChild(cb, d.awaitArg);
		},
		NodeKind.YieldExpr => {
			const d: Cursor<YieldExprData> = node.data as YieldExprData;
			visitChild(cb, d.yieldArg);
		},
		NodeKind.MoveExpr => {
			const d: Cursor<MoveExprData> = node.data as MoveExprData;
			visitChild(cb, d.moveArg);
		},
		NodeKind.OutExpr => {
			const d: Cursor<OutExprData> = node.data as OutExprData;
			visitChild(cb, d.outArg);
		},
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => {
			const d: Cursor<HiddenDerefData> = node.data as HiddenDerefData;
			visitChild(cb, d.expr);
		},
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => {
			const d: Cursor<HiddenStdConvData> = node.data as HiddenStdConvData;
			visitChild(cb, d.convExpr);
		},
		NodeKind.TypeAssertion => {
			const d: Cursor<TypeAssertionData> = node.data as TypeAssertionData;
			visitChild(cb, d.asExpr);
		},
		NodeKind.DestructuringDecl => {
			const d: Cursor<DestructuringDeclData> = node.data as DestructuringDeclData;
			visitChild(cb, d.destrPattern);
			visitChild(cb, d.destrInit);
		},
		NodeKind.QuoteExpr => {
			const d: Cursor<QuoteExprData> = node.data as QuoteExprData;
			visitChild(cb, d.quoteBody);
		},
		NodeKind.ComptimeBlock => {
			const d: Cursor<ComptimeBlockData> = node.data as ComptimeBlockData;
			visitChild(cb, d.comptimeBody);
		},
		NodeKind.MacroInvocation => {
			const d: Cursor<MacroInvocationData> = node.data as MacroInvocationData;
			visitAll(cb, d.macroArgs);
		},
		NodeKind.TestDecl => {
			const d: Cursor<TestDeclData> = node.data as TestDeclData;
			visitChild(cb, d.testBody);
		},
		NodeKind.AssertStmt => {
			const d: Cursor<AssertStmtData> = node.data as AssertStmtData;
			visitChild(cb, d.assertExpr);
			visitChild(cb, d.assertMessageExpr);
		},
		NodeKind.ActorDecl => {
			const d: Cursor<ActorDeclData> = node.data as ActorDeclData;
			visitAll(cb, d.actorBody);
		},
		NodeKind.PropertyDecl => {
			const d: Cursor<PropertyDeclData> = node.data as PropertyDeclData;
			visitChild(cb, d.propInitializer);
		},
		NodeKind.ArrayPattern => {
			const d: Cursor<ArrayPatternData> = node.data as ArrayPatternData;
			visitAll(cb, d.patternElements);
			visitAll(cb, d.patternDefaults);
		},
		NodeKind.ObjectPattern => {
			const d: Cursor<ObjectPatternData> = node.data as ObjectPatternData;
			visitAll(cb, d.patternProps);
		},
		NodeKind.ObjectPatternProp => {
			const d: Cursor<ObjectPatternPropData> = node.data as ObjectPatternPropData;
			visitChild(cb, d.propAlias);
			visitChild(cb, d.propDefault);
		},
		NodeKind.TypeGeneric => {
			const d: Cursor<TypeGenericData> = node.data as TypeGenericData;
			visitChild(cb, d.typExprBase);
			visitAll(cb, d.typExprArgs);
		},
		NodeKind.TypeArray => {
			const d: Cursor<TypeArrayData> = node.data as TypeArrayData;
			visitChild(cb, d.typExprElement);
		},
		NodeKind.TypeUnion => {
			const d: Cursor<TypeUnionData> = node.data as TypeUnionData;
			visitAll(cb, d.typExprMembers);
		},
		NodeKind.TypeIntersection => {
			const d: Cursor<TypeIntersectionData> = node.data as TypeIntersectionData;
			visitAll(cb, d.typExprMembers);
		},
		NodeKind.TypeFunction => {
			const d: Cursor<TypeFunctionData> = node.data as TypeFunctionData;
			visitAll(cb, d.typExprParams);
			visitChild(cb, d.typExprReturn);
		},
		NodeKind.TypeObject => {
			const d: Cursor<TypeObjectData> = node.data as TypeObjectData;
			visitAll(cb, d.typExprFieldTypes);
			visitChild(cb, d.typExprIndexKey);
			visitChild(cb, d.typExprIndexValue);
			for (let i = 0; i < d.typExprFieldDecorators.length; i++) visitAll(cb, d.typExprFieldDecorators[i]);
		},
		NodeKind.JSXElement => {
			const d: Cursor<JSXElementData> = node.data as JSXElementData;
			visitAll(cb, d.jsxAttrs);
			visitAll(cb, d.jsxChildren);
		},
		NodeKind.JSXFragment => {
			const d: Cursor<JSXFragmentData> = node.data as JSXFragmentData;
			visitAll(cb, d.jsxFragChildren);
		},
		NodeKind.JSXExpressionContainer => {
			const d: Cursor<JSXExpressionContainerData> = node.data as JSXExpressionContainerData;
			visitChild(cb, d.jsxExpr);
		},
		NodeKind.JSXAttribute => {
			const d: Cursor<JSXAttributeData> = node.data as JSXAttributeData;
			visitChild(cb, d.jsxAttrValue);
		},
		NodeKind.JSXSpreadAttribute => {
			const d: Cursor<JSXSpreadAttributeData> = node.data as JSXSpreadAttributeData;
			visitChild(cb, d.jsxSpreadArg);
		},
		NodeKind.ComputedProperty => {
			const d: Cursor<ComputedPropertyData> = node.data as ComputedPropertyData;
			visitChild(cb, d.computedKey);
			visitChild(cb, d.computedValue);
		},
		// Genuine leaves (no Node children). Listed explicitly (not via `_`) so
		// adding a new NodeKind forces an exhaustiveness error here, preventing
		// the silent-gap class of bugs that bit replaceTypeVars.
		NodeKind.NumberLiteral | NodeKind.StringLiteral | NodeKind.BooleanLiteral
			| NodeKind.NullLiteral | NodeKind.BigIntLiteral | NodeKind.RegexLiteral
			| NodeKind.Identifier | NodeKind.TypeAnnotation | NodeKind.SizeofExpr
			| NodeKind.BreakStmt | NodeKind.ContinueStmt | NodeKind.UnreachableStmt
			| NodeKind.ImportDecl | NodeKind.TypeAliasDecl
			| NodeKind.InterfaceDecl | NodeKind.StructDecl | NodeKind.ExternDecl
			| NodeKind.JSXText => {},
	};
}

// Apply f to all child nodes of a given node (mutates in place).
// Core dispatch used by walkChildren, and directly by bounded walkers
// that stop at function boundaries.
// SYNC: forEachChild must handle the same NodeKinds (read-only variant).
export function mapChildren(node: Node, f: Visitor): void {
	match (node.kind) {
		// Program root
		NodeKind.Program => {
			const d: Cursor<ProgramData> = node.data as ProgramData;
			for (let i = 0; i < d.programStmts.length; i += 1) {
				d.programStmts[i] = f(d.programStmts[i]);
			}
		},
		// SpliceMany — A2 macro multi-decl emission
		NodeKind.SpliceMany => {
			const d: Cursor<SpliceManyData> = node.data as SpliceManyData;
			for (let i = 0; i < d.spliceNodes.length; i += 1) {
				d.spliceNodes[i] = f(d.spliceNodes[i]);
			}
		},
		// Block
		NodeKind.BlockStmt => {
			const d: Cursor<BlockStmtData> = node.data as BlockStmtData;
			for (let i = 0; i < d.statements.length; i += 1) {
				d.statements[i] = f(d.statements[i]);
			}
		},
		// Statements with child nodes
		NodeKind.IfStmt => {
			const d: Cursor<IfStmtData> = node.data as IfStmtData;
			d.condition = f(d.condition);
			d.consequent = f(d.consequent);
			d.alternate = f(d.alternate);
		},
		NodeKind.WhileStmt => {
			const d: Cursor<WhileStmtData> = node.data as WhileStmtData;
			d.whileCondition = f(d.whileCondition);
			d.whileBody = f(d.whileBody);
		},
		NodeKind.ForStmt => {
			const d: Cursor<ForStmtData> = node.data as ForStmtData;
			d.forInit = f(d.forInit);
			d.forCondition = f(d.forCondition);
			d.forUpdate = f(d.forUpdate);
			d.forBody = f(d.forBody);
		},
		NodeKind.ForOfStmt => {
			const d: Cursor<ForOfStmtData> = node.data as ForOfStmtData;
			d.forOfIterable = f(d.forOfIterable);
			d.forOfBody = f(d.forOfBody);
			if (d.forOfPattern != null) { d.forOfPattern = f(d.forOfPattern); }
		},
		NodeKind.ForInStmt => {
			const d: Cursor<ForInStmtData> = node.data as ForInStmtData;
			d.forInObject = f(d.forInObject);
			d.forInBody = f(d.forInBody);
		},
		NodeKind.DoWhileStmt => {
			const d: Cursor<DoWhileStmtData> = node.data as DoWhileStmtData;
			d.doBody = f(d.doBody);
			d.doCondition = f(d.doCondition);
		},
		NodeKind.SwitchStmt => {
			const d: Cursor<SwitchStmtData> = node.data as SwitchStmtData;
			d.switchDisc = f(d.switchDisc);
			for (let i = 0; i < d.switchCases.length; i += 1) {
				d.switchCases[i] = f(d.switchCases[i]);
			}
		},
		NodeKind.SwitchCase => {
			const d: Cursor<SwitchCaseData> = node.data as SwitchCaseData;
			for (let i = 0; i < d.caseTests.length; i += 1) {
				d.caseTests[i] = f(d.caseTests[i]);
			}
			for (let j = 0; j < d.caseStmts.length; j += 1) {
				d.caseStmts[j] = f(d.caseStmts[j]);
			}
		},
		NodeKind.MatchStmt => {
			const d: Cursor<MatchStmtData> = node.data as MatchStmtData;
			d.matchStmtDisc = f(d.matchStmtDisc);
			for (let i = 0; i < d.matchStmtCases.length; i += 1) {
				d.matchStmtCases[i] = f(d.matchStmtCases[i]);
			}
		},
		NodeKind.MatchExpr => {
			const d: Cursor<MatchExprData> = node.data as MatchExprData;
			d.matchDisc = f(d.matchDisc);
			for (let i = 0; i < d.matchCases.length; i += 1) {
				d.matchCases[i] = f(d.matchCases[i]);
			}
		},
		NodeKind.MatchCase => {
			const d: Cursor<MatchCaseData> = node.data as MatchCaseData;
			for (let i = 0; i < d.casePatterns.length; i += 1) {
				d.casePatterns[i] = f(d.casePatterns[i]);
			}
			if (d.caseGuard != null) { d.caseGuard = f(d.caseGuard); }
			d.caseBody = f(d.caseBody);
		},
		// Declarations with bodies
		NodeKind.FunctionDecl => {
			const d: Cursor<FunctionDeclData> = node.data as FunctionDeclData;
			d.fnBody = f(d.fnBody);
		},
		NodeKind.ArrowFunction => {
			const d: Cursor<ArrowFunctionData> = node.data as ArrowFunctionData;
			d.arrowBody = f(d.arrowBody);
		},
		NodeKind.FunctionExpr => {
			const d: Cursor<FunctionExprData> = node.data as FunctionExprData;
			d.funcExprBody = f(d.funcExprBody);
		},
		NodeKind.ClassDecl => {
			const d: Cursor<ClassDeclData> = node.data as ClassDeclData;
			for (let i = 0; i < d.classBody.length; i += 1) {
				d.classBody[i] = f(d.classBody[i]);
			}
		},
		NodeKind.ActorDecl => {
			const d: Cursor<ActorDeclData> = node.data as ActorDeclData;
			for (let i = 0; i < d.actorBody.length; i += 1) {
				d.actorBody[i] = f(d.actorBody[i]);
			}
		},
		NodeKind.MethodDecl => {
			const d: Cursor<MethodDeclData> = node.data as MethodDeclData;
			d.methodBody = f(d.methodBody);
		},
		NodeKind.ConstructorDecl => {
			const d: Cursor<ConstructorDeclData> = node.data as ConstructorDeclData;
			d.ctorBody = f(d.ctorBody);
			for (let i = 0; i < d.ctorParamProps.length; i += 1) {
				if (d.ctorParamProps[i] != null) d.ctorParamProps[i] = f(d.ctorParamProps[i]);
			}
		},
		NodeKind.ExportDecl => {
			const d: Cursor<ExportDeclData> = node.data as ExportDeclData;
			d.exportedDecl = f(d.exportedDecl);
		},
		NodeKind.DecoratedDecl => {
			const d: Cursor<DecoratedDeclData> = node.data as DecoratedDeclData;
			for (let i = 0; i < d.decorators.length; i += 1) {
				d.decorators[i] = f(d.decorators[i]);
			}
			d.decoratedNode = f(d.decoratedNode);
		},
		NodeKind.EnumDecl => {
			const d: Cursor<EnumDeclData> = node.data as EnumDeclData;
			for (let i = 0; i < d.enumInits.length; i += 1) {
				if (d.enumInits[i] != null) { d.enumInits[i] = f(d.enumInits[i]); }
			}
		},
		NodeKind.MacroDecl => {
			const d: Cursor<MacroDeclData> = node.data as MacroDeclData;
			d.macroDeclBody = f(d.macroDeclBody);
		},
		// Simple statements with one child
		NodeKind.VariableDecl => {
			const d: Cursor<VariableDeclData> = node.data as VariableDeclData;
			if (d.initializer != null) d.initializer = f(d.initializer);
		},
		NodeKind.ReturnStmt => {
			const d: Cursor<ReturnStmtData> = node.data as ReturnStmtData;
			d.argument = f(d.argument!);
		},
		NodeKind.ThrowStmt => {
			const d: Cursor<ThrowStmtData> = node.data as ThrowStmtData;
			d.throwArg = f(d.throwArg);
		},
		NodeKind.ExprStmt => {
			const d: Cursor<ExprStmtData> = node.data as ExprStmtData;
			d.expr = f(d.expr);
		},
		NodeKind.DeferStmt => {
			const d: Cursor<DeferStmtData> = node.data as DeferStmtData;
			d.deferExpr = f(d.deferExpr);
		},
		NodeKind.TryCatchStmt => {
			const d: Cursor<TryCatchStmtData> = node.data as TryCatchStmtData;
			d.tryBody = f(d.tryBody);
			d.catchBody = f(d.catchBody);
			d.finallyBody = f(d.finallyBody);
		},
		// Expressions
		NodeKind.BinaryExpr => {
			const d: Cursor<BinaryExprData> = node.data as BinaryExprData;
			d.left = f(d.left);
			d.right = f(d.right);
		},
		NodeKind.UnaryExpr => {
			const d: Cursor<UnaryExprData> = node.data as UnaryExprData;
			d.operand = f(d.operand);
		},
		NodeKind.UpdateExpr => {
			const d: Cursor<UpdateExprData> = node.data as UpdateExprData;
			d.updateArg = f(d.updateArg);
		},
		NodeKind.CallExpr => {
			const d: Cursor<CallExprData> = node.data as CallExprData;
			d.callee = f(d.callee);
			for (let i = 0; i < d.arguments.length; i += 1) {
				d.arguments[i] = f(d.arguments[i]);
			}
		},
		NodeKind.MemberExpr => {
			const d: Cursor<MemberExprData> = node.data as MemberExprData;
			d.object = f(d.object);
		},
		NodeKind.ArrayAccess => {
			const d: Cursor<ArrayAccessData> = node.data as ArrayAccessData;
			d.array = f(d.array);
			d.index = f(d.index);
		},
		NodeKind.ObjectLiteral => {
			const d: Cursor<ObjectLiteralData> = node.data as ObjectLiteralData;
			for (let i = 0; i < d.properties.length; i += 1) {
				d.properties[i] = f(d.properties[i]);
			}
		},
		NodeKind.ArrayLiteral => {
			const d: Cursor<ArrayLiteralData> = node.data as ArrayLiteralData;
			for (let i = 0; i < d.elements.length; i += 1) {
				d.elements[i] = f(d.elements[i]);
			}
		},
		NodeKind.ConditionalExpr => {
			const d: Cursor<ConditionalExprData> = node.data as ConditionalExprData;
			d.ternaryCondition = f(d.ternaryCondition);
			d.ternaryConsequent = f(d.ternaryConsequent);
			d.ternaryAlternate = f(d.ternaryAlternate);
		},
		NodeKind.SpreadExpr => {
			const d: Cursor<SpreadExprData> = node.data as SpreadExprData;
			d.spreadArg = f(d.spreadArg);
		},
		NodeKind.NewExpr => {
			const d: Cursor<NewExprData> = node.data as NewExprData;
			d.newCallee = f(d.newCallee);
			for (let i = 0; i < d.newArguments.length; i += 1) {
				d.newArguments[i] = f(d.newArguments[i]);
			}
		},
		NodeKind.TryExpr => {
			const d: Cursor<TryExprData> = node.data as TryExprData;
			d.tryArg = f(d.tryArg);
			if (d.hasCatch) { d.catchVal = f(d.catchVal); }
		},
		NodeKind.AwaitExpr => {
			const d: Cursor<AwaitExprData> = node.data as AwaitExprData;
			d.awaitArg = f(d.awaitArg);
		},
		NodeKind.YieldExpr => {
			const d: Cursor<YieldExprData> = node.data as YieldExprData;
			d.yieldArg = f(d.yieldArg);
		},
		NodeKind.MoveExpr => {
			const d: Cursor<MoveExprData> = node.data as MoveExprData;
			d.moveArg = f(d.moveArg);
		},
		NodeKind.OutExpr => {
			const d: Cursor<OutExprData> = node.data as OutExprData;
			d.outArg = f(d.outArg);
		},
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => {
			const d: Cursor<HiddenDerefData> = node.data as HiddenDerefData;
			d.expr = f(d.expr);
		},
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => {
			const d: Cursor<HiddenStdConvData> = node.data as HiddenStdConvData;
			d.convExpr = f(d.convExpr);
		},
		NodeKind.TypeAssertion => {
			const d: Cursor<TypeAssertionData> = node.data as TypeAssertionData;
			d.asExpr = f(d.asExpr);
		},
		NodeKind.DestructuringDecl => {
			const d: Cursor<DestructuringDeclData> = node.data as DestructuringDeclData;
			d.destrPattern = f(d.destrPattern);
			d.destrInit = f(d.destrInit);
		},
		NodeKind.QuoteExpr => {
			const d: Cursor<QuoteExprData> = node.data as QuoteExprData;
			d.quoteBody = f(d.quoteBody);
		},
		NodeKind.ComptimeBlock => {
			const d: Cursor<ComptimeBlockData> = node.data as ComptimeBlockData;
			d.comptimeBody = f(d.comptimeBody);
		},
		NodeKind.MacroInvocation => {
			const d: Cursor<MacroInvocationData> = node.data as MacroInvocationData;
			for (let i = 0; i < d.macroArgs.length; i += 1) {
				d.macroArgs[i] = f(d.macroArgs[i]);
			}
		},
		NodeKind.TestDecl => {
			const d: Cursor<TestDeclData> = node.data as TestDeclData;
			d.testBody = f(d.testBody);
		},
		NodeKind.AssertStmt => {
			const d: Cursor<AssertStmtData> = node.data as AssertStmtData;
			d.assertExpr = f(d.assertExpr);
			if (d.assertMessageExpr != null) { d.assertMessageExpr = f(d.assertMessageExpr); }
		},
		NodeKind.PropertyDecl => {
			const d: Cursor<PropertyDeclData> = node.data as PropertyDeclData;
			if (d.propInitializer != null) { d.propInitializer = f(d.propInitializer); }
		},
		NodeKind.ArrayPattern => {
			const d: Cursor<ArrayPatternData> = node.data as ArrayPatternData;
			for (let i = 0; i < d.patternElements.length; i += 1) {
				d.patternElements[i] = f(d.patternElements[i]);
			}
			for (let i = 0; i < d.patternDefaults.length; i += 1) {
				if (d.patternDefaults[i] != null) { d.patternDefaults[i] = f(d.patternDefaults[i]); }
			}
		},
		NodeKind.ObjectPattern => {
			const d: Cursor<ObjectPatternData> = node.data as ObjectPatternData;
			for (let i = 0; i < d.patternProps.length; i += 1) {
				d.patternProps[i] = f(d.patternProps[i]);
			}
		},
		NodeKind.ObjectPatternProp => {
			const d: Cursor<ObjectPatternPropData> = node.data as ObjectPatternPropData;
			if (d.propAlias != null) { d.propAlias = f(d.propAlias); }
			if (d.propDefault != null) { d.propDefault = f(d.propDefault); }
		},
		NodeKind.TypeGeneric => {
			const d: Cursor<TypeGenericData> = node.data as TypeGenericData;
			d.typExprBase = f(d.typExprBase);
			for (let i = 0; i < d.typExprArgs.length; i += 1) {
				d.typExprArgs[i] = f(d.typExprArgs[i]);
			}
		},
		NodeKind.TypeArray => {
			const d: Cursor<TypeArrayData> = node.data as TypeArrayData;
			d.typExprElement = f(d.typExprElement);
		},
		NodeKind.TypeUnion => {
			const d: Cursor<TypeUnionData> = node.data as TypeUnionData;
			for (let i = 0; i < d.typExprMembers.length; i += 1) {
				d.typExprMembers[i] = f(d.typExprMembers[i]);
			}
		},
		NodeKind.TypeIntersection => {
			const d: Cursor<TypeIntersectionData> = node.data as TypeIntersectionData;
			for (let i = 0; i < d.typExprMembers.length; i += 1) {
				d.typExprMembers[i] = f(d.typExprMembers[i]);
			}
		},
		NodeKind.TypeFunction => {
			const d: Cursor<TypeFunctionData> = node.data as TypeFunctionData;
			for (let i = 0; i < d.typExprParams.length; i += 1) {
				d.typExprParams[i] = f(d.typExprParams[i]);
			}
			if (d.typExprReturn != null) { d.typExprReturn = f(d.typExprReturn); }
		},
		NodeKind.TypeObject => {
			const d: Cursor<TypeObjectData> = node.data as TypeObjectData;
			for (let i = 0; i < d.typExprFieldTypes.length; i += 1) {
				d.typExprFieldTypes[i] = f(d.typExprFieldTypes[i]);
			}
			if (d.typExprIndexKey != null) { d.typExprIndexKey = f(d.typExprIndexKey); }
			if (d.typExprIndexValue != null) { d.typExprIndexValue = f(d.typExprIndexValue); }
			for (let di = 0; di < d.typExprFieldDecorators.length; di += 1) {
				const decs = d.typExprFieldDecorators[di];
				for (let dj = 0; dj < decs.length; dj += 1) {
					decs[dj] = f(decs[dj]);
				}
			}
		},
		NodeKind.JSXElement => {
			const d: Cursor<JSXElementData> = node.data as JSXElementData;
			for (let i = 0; i < d.jsxAttrs.length; i += 1) d.jsxAttrs[i] = f(d.jsxAttrs[i]);
			for (let j = 0; j < d.jsxChildren.length; j += 1) d.jsxChildren[j] = f(d.jsxChildren[j]);
		},
		NodeKind.JSXFragment => {
			const d: Cursor<JSXFragmentData> = node.data as JSXFragmentData;
			for (let i = 0; i < d.jsxFragChildren.length; i += 1) d.jsxFragChildren[i] = f(d.jsxFragChildren[i]);
		},
		NodeKind.JSXExpressionContainer => {
			const d: Cursor<JSXExpressionContainerData> = node.data as JSXExpressionContainerData;
			d.jsxExpr = f(d.jsxExpr);
		},
		NodeKind.JSXAttribute => {
			const d: Cursor<JSXAttributeData> = node.data as JSXAttributeData;
			d.jsxAttrValue = f(d.jsxAttrValue);
		},
		NodeKind.JSXSpreadAttribute => {
			const d: Cursor<JSXSpreadAttributeData> = node.data as JSXSpreadAttributeData;
			d.jsxSpreadArg = f(d.jsxSpreadArg);
		},
		NodeKind.ComputedProperty => {
			const d: Cursor<ComputedPropertyData> = node.data as ComputedPropertyData;
			d.computedKey = f(d.computedKey);
			d.computedValue = f(d.computedValue);
		},
		// Genuine leaves (no Node children). Listed explicitly (not via `_`) so
		// adding a new NodeKind forces an exhaustiveness error here — keeping
		// this walker in sync with the AST by construction.
		NodeKind.NumberLiteral | NodeKind.StringLiteral | NodeKind.BooleanLiteral
			| NodeKind.NullLiteral | NodeKind.BigIntLiteral | NodeKind.RegexLiteral
			| NodeKind.Identifier | NodeKind.TypeAnnotation | NodeKind.SizeofExpr
			| NodeKind.BreakStmt | NodeKind.ContinueStmt | NodeKind.UnreachableStmt
			| NodeKind.ImportDecl | NodeKind.TypeAliasDecl
			| NodeKind.InterfaceDecl | NodeKind.StructDecl | NodeKind.ExternDecl
			| NodeKind.JSXText => {},
	};
}
