// Per-kind NodeData field spec — the ONE place that knows a variant's field
// names and order, shared by every consumer that must walk or rebuild node
// payloads per kind (checker/preludePack walk+emit, monomorphize clone,
// ast/printer). Adding a NodeData field means touching the specs here plus
// the pack's buildNodeData (string-source inverse) — the exhaustive per-kind
// roundtrip tests tripwire all of them.
//
// Two spec shapes, deliberately separate:
//   - FieldSink (read-only): each method takes (fieldName, value), returns
//     void. Walk/enqueue, serialize, print — side-effect consumers.
//   - FieldXform (value map): each method takes a value, returns the
//     transformed value. rebuildNodeData constructs a fresh NodeData per kind
//     through it (deep clone is one xform among possible ones).
//
// MS has no method dispatch, so sinks/xforms are function-typed fields (the
// callbacks.ms pattern); calling V.node("left", x) loads the field and calls.

import { Node, NodeKind, NodeData, SourceLocation, Type, Symbol, DeclKind, ExternKind, makeLoc, createNodeAt,
	NumberLiteralData, StringLiteralData, BooleanLiteralData, RegexLiteralData, BigIntLiteralData,
	IdentifierData, BinaryExprData, UnaryExprData, UpdateExprData, CallExprData, MemberExprData,
	ArrayAccessData, ObjectLiteralData, ArrayLiteralData, ArrowFunctionData, FunctionExprData,
	TypeAssertionData, ConditionalExprData, SpreadExprData, NewExprData, TryExprData,
	MatchExprData, MatchCaseData, AwaitExprData, YieldExprData, MoveExprData, OutExprData, SizeofExprData,
	QuoteExprData, ComptimeBlockData, ArrayPatternData, ObjectPatternData, ObjectPatternPropData,
	DestructuringDeclData, ExprStmtData, ReturnStmtData, ThrowStmtData, DeferStmtData,
	VariableDeclData, IfStmtData, WhileStmtData, ForStmtData, ForOfStmtData, ForInStmtData,
	DoWhileStmtData, BlockStmtData, FunctionDeclData, SwitchStmtData, SwitchCaseData,
	MatchStmtData, TryCatchStmtData, UnreachableStmtData, TypeAnnotationData,
	MacroInvocationData, ImportDeclData, ExportDeclData, TypeAliasDeclData, EnumDeclData,
	InterfaceDeclData, ClassDeclData, ActorDeclData, PropertyDeclData, MethodDeclData, ConstructorDeclData,
	ExternDeclData, MacroDeclData, DecoratedDeclData, ProgramData, SpliceManyData,
	TestDeclData, AssertStmtData,
	HiddenStdConvData,
	TypeGenericData, TypeArrayData, TypeUnionData, TypeIntersectionData, TypeFunctionData, TypeObjectData,
	JSXElementData, JSXFragmentData, JSXTextData, JSXExpressionContainerData, JSXAttributeData, JSXSpreadAttributeData,
	BreakStmtData, ContinueStmtData, UnreachableStmtData,
} from "./node";

// ===== Read-only sink =====

export type SinkNodeFn = (name: string, n: Node | null) => void;
export type SinkNodeArrFn = (name: string, arr: (Node | null)[] | null) => void;
export type SinkNestedFn = (name: string, arrs: (Node | null)[][] | null) => void;
export type SinkTypeFn = (name: string, t: Type | null) => void;
export type SinkStrFn = (name: string, s: string) => void;
export type SinkStrArrFn = (name: string, arr: string[] | null) => void;
export type SinkIntFn = (name: string, v: int64) => void;
export type SinkFloatFn = (name: string, v: float64) => void;
export type SinkBoolFn = (name: string, b: boolean) => void;
export type SinkLocFn = (name: string, l: SourceLocation | null) => void;
export type SinkLocsFn = (name: string, l: SourceLocation[] | null) => void;
export type SinkFloatsFn = (name: string, a: number[] | null) => void;

export interface FieldSink {
	node: SinkNodeFn;
	nodes: SinkNodeArrFn;
	nodesNested: SinkNestedFn;
	typ: SinkTypeFn;
	str: SinkStrFn;
	strArr: SinkStrArrFn;
	integer: SinkIntFn;
	float: SinkFloatFn;
	bool: SinkBoolFn;
	loc: SinkLocFn;
	locs: SinkLocsFn;
	floats: SinkFloatsFn;
}

// Field kinds: str=escaped string, strArr=joined list, integer=int64,
// float=float64, bool=0/1, node/nodes=node ref, nodesNested=nested node
// lists, typ=type ref, loc=4 ints, locs/floats=list.
// ===== Value-mapping xform (rebuild direction) =====
//
// Mirror of nodeFields for consumers that CONSTRUCT a fresh NodeData per kind
// with each field passed through a mapping (deep clone is the canonical
// xform). Contract quirks that callers rely on:
//   - array-typed methods (nodes/strArr/locs/floats/nodesNested) normalize
//     null → [] (the same convention the pack reader uses)
//   - node/typ/loc stay nullable
// Field order MUST match nodeFields — the clone roundtrip test compares
// dumps built from the same samples against both.

export type XfNodeFn = (n: Node | null) => Node | null;
export type XfNodeArrFn = (arr: (Node | null)[] | null) => (Node | null)[];
export type XfNestedFn = (arrs: (Node | null)[][] | null) => (Node | null)[][];
export type XfTypeFn = (t: Type | null) => Type | null;
export type XfStrFn = (s: string) => string;
export type XfStrArrFn = (arr: string[] | null) => string[];
export type XfIntFn = (v: int64) => int64;
export type XfFloatFn = (v: float64) => float64;
export type XfBoolFn = (b: boolean) => boolean;
export type XfLocFn = (l: SourceLocation | null) => SourceLocation | null;
export type XfLocsFn = (l: SourceLocation[] | null) => SourceLocation[];
export type XfFloatsFn = (a: number[] | null) => number[];

export interface FieldXform {
	node: XfNodeFn;
	nodes: XfNodeArrFn;
	nodesNested: XfNestedFn;
	typ: XfTypeFn;
	str: XfStrFn;
	strArr: XfStrArrFn;
	integer: XfIntFn;
	float: XfFloatFn;
	bool: XfBoolFn;
	loc: XfLocFn;
	locs: XfLocsFn;
	floats: XfFloatsFn;
}

export function rebuildNodeData(n: Node, X: FieldXform): NodeData {
	const kind = n.kind;
	if (kind === NodeKind.NumberLiteral) { const d = n.data as NumberLiteralData; return { value: X.float(d.value), isFloat: X.bool(d.isFloat), intVal: X.integer(d.intVal), outOfRangeText: X.str(d.outOfRangeText), isBitPattern: X.bool(d.isBitPattern) } as NodeData; }
	if (kind === NodeKind.StringLiteral) { const d = n.data as StringLiteralData; return { value: X.str(d.value) } as NodeData; }
	if (kind === NodeKind.BooleanLiteral) { const d = n.data as BooleanLiteralData; return { boolValue: X.bool(d.boolValue) } as NodeData; }
	if (kind === NodeKind.NullLiteral) return { nullPlaceholder: true } as NodeData;
	if (kind === NodeKind.BigIntLiteral) { const d = n.data as BigIntLiteralData; return { bigintValue: X.str(d.bigintValue) } as NodeData; }
	if (kind === NodeKind.RegexLiteral) { const d = n.data as RegexLiteralData; return { regexPattern: X.str(d.regexPattern) } as NodeData; }
	if (kind === NodeKind.Identifier) { const d = n.data as IdentifierData; return { name: X.str(d.name) } as NodeData; }
	if (kind === NodeKind.BinaryExpr) { const d = n.data as BinaryExprData; return { operator: X.str(d.operator), left: X.node(d.left) as Node, right: X.node(d.right) as Node } as NodeData; }
	if (kind === NodeKind.UnaryExpr) { const d = n.data as UnaryExprData; return { unaryOp: X.str(d.unaryOp), operand: X.node(d.operand) as Node } as NodeData; }
	if (kind === NodeKind.UpdateExpr) { const d = n.data as UpdateExprData; return { updateOp: X.str(d.updateOp), updateArg: X.node(d.updateArg) as Node, isPrefix: X.bool(d.isPrefix) } as NodeData; }
	if (kind === NodeKind.CallExpr) { const d = n.data as CallExprData; return { callee: X.node(d.callee) as Node, arguments: X.nodes(d.arguments) as Node[], isDirectCall: X.bool(d.isDirectCall), resolvedOverloadIdx: X.float(d.resolvedOverloadIdx) } as NodeData; }
	if (kind === NodeKind.MemberExpr) { const d = n.data as MemberExprData; return { object: X.node(d.object) as Node, property: X.str(d.property), isOptional: X.bool(d.isOptional) } as NodeData; }
	if (kind === NodeKind.ArrayAccess) { const d = n.data as ArrayAccessData; return { array: X.node(d.array) as Node, index: X.node(d.index) as Node } as NodeData; }
	if (kind === NodeKind.ObjectLiteral) { const d = n.data as ObjectLiteralData; return { properties: X.nodes(d.properties) as Node[], keys: X.strArr(d.keys), keyLocations: X.locs(d.keyLocations) } as NodeData; }
	if (kind === NodeKind.ArrayLiteral) { const d = n.data as ArrayLiteralData; return { elements: X.nodes(d.elements) as Node[] } as NodeData; }
	if (kind === NodeKind.ArrowFunction) { const d = n.data as ArrowFunctionData; return { arrowParams: X.strArr(d.arrowParams), arrowParamTypes: X.strArr(d.arrowParamTypes), arrowBody: X.node(d.arrowBody) as Node, arrowFlags: X.str(d.arrowFlags), arrowReturnType: X.str(d.arrowReturnType), arrowDefaults: X.nodes(d.arrowDefaults) } as NodeData; }
	if (kind === NodeKind.FunctionExpr) { const d = n.data as FunctionExprData; return { funcExprParams: X.strArr(d.funcExprParams), funcExprParamTypes: X.strArr(d.funcExprParamTypes), funcExprBody: X.node(d.funcExprBody) as Node, funcExprFlags: X.str(d.funcExprFlags), funcExprReturnType: X.str(d.funcExprReturnType) } as NodeData; }
	if (kind === NodeKind.TypeAssertion) { const d = n.data as TypeAssertionData; return { asExpr: X.node(d.asExpr) as Node, asType: X.str(d.asType) } as NodeData; }
	if (kind === NodeKind.ConditionalExpr) { const d = n.data as ConditionalExprData; return { ternaryCondition: X.node(d.ternaryCondition) as Node, ternaryConsequent: X.node(d.ternaryConsequent) as Node, ternaryAlternate: X.node(d.ternaryAlternate) as Node } as NodeData; }
	if (kind === NodeKind.SpreadExpr) { const d = n.data as SpreadExprData; return { spreadArg: X.node(d.spreadArg) as Node } as NodeData; }
	if (kind === NodeKind.NewExpr) { const d = n.data as NewExprData; return { newCallee: X.node(d.newCallee) as Node, newArguments: X.nodes(d.newArguments) as Node[] } as NodeData; }
	if (kind === NodeKind.TryExpr) { const d = n.data as TryExprData; return { tryArg: X.node(d.tryArg) as Node, hasCatch: X.bool(d.hasCatch), catchVal: X.node(d.catchVal) as Node } as NodeData; }
	if (kind === NodeKind.MatchExpr) { const d = n.data as MatchExprData; return { matchDisc: X.node(d.matchDisc) as Node, matchCases: X.nodes(d.matchCases) as Node[] } as NodeData; }
	if (kind === NodeKind.MatchCase) { const d = n.data as MatchCaseData; return { casePatterns: X.nodes(d.casePatterns) as Node[], caseGuard: X.node(d.caseGuard) as Node, caseBody: X.node(d.caseBody) as Node } as NodeData; }
	if (kind === NodeKind.AwaitExpr) { const d = n.data as AwaitExprData; return { awaitArg: X.node(d.awaitArg) as Node } as NodeData; }
	if (kind === NodeKind.YieldExpr) { const d = n.data as YieldExprData; return { yieldArg: X.node(d.yieldArg) as Node, isDelegate: X.bool(d.isDelegate) } as NodeData; }
	if (kind === NodeKind.MoveExpr) { const d = n.data as MoveExprData; return { moveArg: X.node(d.moveArg) as Node } as NodeData; }
	if (kind === NodeKind.OutExpr) { const d = n.data as OutExprData; return { outArg: X.node(d.outArg) as Node } as NodeData; }
	if (kind === NodeKind.SizeofExpr) { const d = n.data as SizeofExprData; return { sizeofType: X.str(d.sizeofType) } as NodeData; }
	if (kind === NodeKind.HiddenStdConv || kind === NodeKind.HiddenSubConv) { const d = n.data as HiddenStdConvData; return { convExpr: X.node(d.convExpr) as Node, convType: X.typ(d.convType) as Type } as NodeData; }
	if (kind === NodeKind.HiddenDeref || kind === NodeKind.HiddenAddr) { const d = n.data as ExprStmtData; return { expr: X.node(d.expr) as Node } as NodeData; }
	if (kind === NodeKind.TypeAnnotation) { const d = n.data as TypeAnnotationData; return { annotationType: X.str(d.annotationType) } as NodeData; }
	if (kind === NodeKind.ArrayPattern) { const d = n.data as ArrayPatternData; return { patternElements: X.nodes(d.patternElements) as Node[], hasRestElement: X.bool(d.hasRestElement) } as NodeData; }
	if (kind === NodeKind.ObjectPattern) { const d = n.data as ObjectPatternData; return { patternProps: X.nodes(d.patternProps) as Node[], hasRestProp: X.bool(d.hasRestProp) } as NodeData; }
	if (kind === NodeKind.ObjectPatternProp) { const d = n.data as ObjectPatternPropData; return { propKey: X.str(d.propKey), propAlias: X.node(d.propAlias) as Node } as NodeData; }
	if (kind === NodeKind.DestructuringDecl) { const d = n.data as DestructuringDeclData; return { destrPattern: X.node(d.destrPattern) as Node, destrInit: X.node(d.destrInit) as Node, destrIsConst: X.bool(d.destrIsConst) } as NodeData; }
	if (kind === NodeKind.VariableDecl) { const d = n.data as VariableDeclData; return { declName: X.str(d.declName), declType: X.str(d.declType), initializer: X.node(d.initializer) as Node, declKind: X.integer(d.declKind as int32 as int64) as int32 as unknown as DeclKind, nameLocation: X.loc(d.nameLocation) as SourceLocation } as NodeData; }
	if (kind === NodeKind.IfStmt) { const d = n.data as IfStmtData; return { condition: X.node(d.condition) as Node, consequent: X.node(d.consequent) as Node, alternate: X.node(d.alternate) as Node } as NodeData; }
	if (kind === NodeKind.WhileStmt) { const d = n.data as WhileStmtData; return { whileCondition: X.node(d.whileCondition) as Node, whileBody: X.node(d.whileBody) as Node, whileLabel: X.str(d.whileLabel) } as NodeData; }
	if (kind === NodeKind.ForStmt) { const d = n.data as ForStmtData; return { forInit: X.node(d.forInit) as Node, forCondition: X.node(d.forCondition) as Node, forUpdate: X.node(d.forUpdate) as Node, forBody: X.node(d.forBody) as Node } as NodeData; }
	if (kind === NodeKind.ForOfStmt) { const d = n.data as ForOfStmtData; return { forOfBinding: X.str(d.forOfBinding), forOfIsConst: X.bool(d.forOfIsConst), forOfIterable: X.node(d.forOfIterable) as Node, forOfBody: X.node(d.forOfBody) as Node, forOfPattern: X.node(d.forOfPattern) as Node, bindingLocation: X.loc(d.bindingLocation) as SourceLocation } as NodeData; }
	if (kind === NodeKind.ForInStmt) { const d = n.data as ForInStmtData; return { forInBinding: X.str(d.forInBinding), forInIsConst: X.bool(d.forInIsConst), forInObject: X.node(d.forInObject) as Node, forInBody: X.node(d.forInBody) as Node } as NodeData; }
	if (kind === NodeKind.BlockStmt) { const d = n.data as BlockStmtData; return { statements: X.nodes(d.statements) as Node[] } as NodeData; }
	if (kind === NodeKind.ExprStmt) { const d = n.data as ExprStmtData; return { expr: X.node(d.expr) as Node } as NodeData; }
	if (kind === NodeKind.ReturnStmt) { const d = n.data as ReturnStmtData; return { argument: X.node(d.argument) } as NodeData; }
	if (kind === NodeKind.BreakStmt) { const d = n.data as BreakStmtData; return { breakLabel: X.str(d.breakLabel) } as NodeData; }
	if (kind === NodeKind.ContinueStmt) { const d = n.data as ContinueStmtData; return { continueLabel: X.str(d.continueLabel) } as NodeData; }
	if (kind === NodeKind.FunctionDecl) { const d = n.data as FunctionDeclData; return { fnName: X.str(d.fnName), params: X.strArr(d.params), fnParamTypes: X.strArr(d.fnParamTypes), fnBody: X.node(d.fnBody) as Node, fnFlags: X.str(d.fnFlags), fnReturnType: X.str(d.fnReturnType), fnDefaults: X.nodes(d.fnDefaults) as Node[], nativeName: X.str(d.nativeName), nameLocation: X.loc(d.nameLocation) as SourceLocation } as NodeData; }
	if (kind === NodeKind.DoWhileStmt) { const d = n.data as DoWhileStmtData; return { doBody: X.node(d.doBody) as Node, doCondition: X.node(d.doCondition) as Node } as NodeData; }
	if (kind === NodeKind.SwitchStmt) { const d = n.data as SwitchStmtData; return { switchDisc: X.node(d.switchDisc) as Node, switchCases: X.nodes(d.switchCases) as Node[] } as NodeData; }
	if (kind === NodeKind.SwitchCase) { const d = n.data as SwitchCaseData; return { caseTests: X.nodes(d.caseTests) as Node[], caseStmts: X.nodes(d.caseStmts) as Node[], isDefault: X.bool(d.isDefault) } as NodeData; }
	if (kind === NodeKind.UnreachableStmt) { const d = n.data as UnreachableStmtData; return { unreachableMsg: X.str(d.unreachableMsg) } as NodeData; }
	if (kind === NodeKind.MatchStmt) { const d = n.data as MatchStmtData; return { matchStmtDisc: X.node(d.matchStmtDisc) as Node, matchStmtCases: X.nodes(d.matchStmtCases) as Node[] } as NodeData; }
	if (kind === NodeKind.ImportDecl) { const d = n.data as ImportDeclData; return { importNames: X.strArr(d.importNames), importAliases: X.strArr(d.importAliases), importSource: X.str(d.importSource), nameLocations: X.locs(d.nameLocations) } as NodeData; }
	if (kind === NodeKind.ExportDecl) { const d = n.data as ExportDeclData; return { exportedDecl: X.node(d.exportedDecl) as Node } as NodeData; }
	if (kind === NodeKind.TypeAliasDecl) { const d = n.data as TypeAliasDeclData; return { aliasName: X.str(d.aliasName), aliasType: X.str(d.aliasType), aliasIsDistinct: X.bool(d.aliasIsDistinct), aliasGenericParams: X.str(d.aliasGenericParams), discriminantName: X.str(d.discriminantName), discriminantType: X.str(d.discriminantType), variantKeys: X.strArr(d.variantKeys), variantTypes: X.strArr(d.variantTypes), nameLocation: X.loc(d.nameLocation) as SourceLocation } as NodeData; }
	if (kind === NodeKind.EnumDecl) { const d = n.data as EnumDeclData; return { enumName: X.str(d.enumName), enumMembers: X.strArr(d.enumMembers), enumValues: X.floats(d.enumValues), nameLocation: X.loc(d.nameLocation) as SourceLocation, memberLocations: X.locs(d.memberLocations) } as NodeData; }
	if (kind === NodeKind.InterfaceDecl || kind === NodeKind.StructDecl) { const d = n.data as InterfaceDeclData; return { interfaceName: X.str(d.interfaceName), interfaceFields: X.strArr(d.interfaceFields), interfaceFieldTypes: X.strArr(d.interfaceFieldTypes), interfaceExtends: X.strArr(d.interfaceExtends), nameLocation: X.loc(d.nameLocation) as SourceLocation } as NodeData; }
	if (kind === NodeKind.ClassDecl) { const d = n.data as ClassDeclData; return { className: X.str(d.className), classExtends: X.str(d.classExtends), classBody: X.nodes(d.classBody) as Node[], nameLocation: X.loc(d.nameLocation) as SourceLocation } as NodeData; }
	if (kind === NodeKind.PropertyDecl) { const d = n.data as PropertyDeclData; return { propName: X.str(d.propName), propType: X.str(d.propType), propIsStatic: X.bool(d.propIsStatic), propIsReadonly: X.bool(d.propIsReadonly), propVisibility: X.str(d.propVisibility), propInitializer: X.node(d.propInitializer) as Node } as NodeData; }
	if (kind === NodeKind.MethodDecl) { const d = n.data as MethodDeclData; return { methodName: X.str(d.methodName), methodParams: X.strArr(d.methodParams), methodParamTypes: X.strArr(d.methodParamTypes), methodBody: X.node(d.methodBody) as Node, methodIsStatic: X.bool(d.methodIsStatic), methodFlags: X.str(d.methodFlags), methodVisibility: X.str(d.methodVisibility), methodReturnType: X.str(d.methodReturnType), methodDefaults: X.nodes(d.methodDefaults) as Node[], nativeName: X.str(d.nativeName), nameLocation: X.loc(d.nameLocation) as SourceLocation } as NodeData; }
	if (kind === NodeKind.ConstructorDecl) { const d = n.data as ConstructorDeclData; return { ctorParams: X.strArr(d.ctorParams), ctorParamTypes: X.strArr(d.ctorParamTypes), ctorBody: X.node(d.ctorBody) as Node, ctorDefaults: X.nodes(d.ctorDefaults) as Node[] } as NodeData; }
	if (kind === NodeKind.ThrowStmt) { const d = n.data as ThrowStmtData; return { throwArg: X.node(d.throwArg) as Node } as NodeData; }
	if (kind === NodeKind.TryCatchStmt) { const d = n.data as TryCatchStmtData; return { tryBody: X.node(d.tryBody) as Node, catchName: X.str(d.catchName), catchBody: X.node(d.catchBody) as Node, finallyBody: X.node(d.finallyBody) as Node, catchBindingLocation: X.loc(d.catchBindingLocation) as SourceLocation, hasCatchClause: X.bool(d.hasCatchClause) } as NodeData; }
	if (kind === NodeKind.MacroInvocation) { const d = n.data as MacroInvocationData; return { macroName: X.str(d.macroName), macroArgs: X.nodes(d.macroArgs) as Node[] } as NodeData; }
	if (kind === NodeKind.DecoratedDecl) { const d = n.data as DecoratedDeclData; return { decorators: X.nodes(d.decorators) as Node[], decoratedNode: X.node(d.decoratedNode) as Node } as NodeData; }
	if (kind === NodeKind.DeferStmt) { const d = n.data as DeferStmtData; return { deferExpr: X.node(d.deferExpr) as Node } as NodeData; }
	if (kind === NodeKind.TestDecl) { const d = n.data as TestDeclData; return { testName: X.str(d.testName), testBody: X.node(d.testBody) as Node } as NodeData; }
	if (kind === NodeKind.AssertStmt) { const d = n.data as AssertStmtData; return { assertExpr: X.node(d.assertExpr) as Node, assertSource: X.str(d.assertSource), assertMessage: X.str(d.assertMessage), assertMessageExpr: X.node(d.assertMessageExpr) } as NodeData; }
	if (kind === NodeKind.ExternDecl) { const d = n.data as ExternDeclData; return { externKind: X.integer(d.externKind as int32 as int64) as int32 as unknown as ExternKind, externName: X.str(d.externName), nativeName: X.str(d.nativeName), externType: X.str(d.externType) } as NodeData; }
	if (kind === NodeKind.MacroDecl) { const d = n.data as MacroDeclData; return { macroDeclName: X.str(d.macroDeclName), macroDeclParams: X.strArr(d.macroDeclParams), macroDeclParamTypes: X.strArr(d.macroDeclParamTypes), macroDeclReturnType: X.str(d.macroDeclReturnType), macroDeclBody: X.node(d.macroDeclBody) as Node } as NodeData; }
	if (kind === NodeKind.QuoteExpr) { const d = n.data as QuoteExprData; return { quoteBody: X.node(d.quoteBody) as Node } as NodeData; }
	if (kind === NodeKind.ComptimeBlock) { const d = n.data as ComptimeBlockData; return { comptimeBody: X.node(d.comptimeBody) as Node } as NodeData; }
	if (kind === NodeKind.TypeGeneric) { const d = n.data as TypeGenericData; return { typExprBase: X.node(d.typExprBase) as Node, typExprArgs: X.nodes(d.typExprArgs) as Node[] } as NodeData; }
	if (kind === NodeKind.TypeArray) { const d = n.data as TypeArrayData; return { typExprElement: X.node(d.typExprElement) as Node, typExprSize: X.float(d.typExprSize) } as NodeData; }
	if (kind === NodeKind.TypeUnion) { const d = n.data as TypeUnionData; return { typExprMembers: X.nodes(d.typExprMembers) as Node[], discFieldName: X.str(d.discFieldName), variantKeys: X.strArr(d.variantKeys), discKind: X.str(d.discKind) } as NodeData; }
	if (kind === NodeKind.TypeIntersection) { const d = n.data as TypeIntersectionData; return { typExprMembers: X.nodes(d.typExprMembers) as Node[] } as NodeData; }
	if (kind === NodeKind.TypeFunction) { const d = n.data as TypeFunctionData; return { typExprParams: X.nodes(d.typExprParams) as Node[], typExprReturn: X.node(d.typExprReturn) as Node, typExprParamNames: X.strArr(d.typExprParamNames) } as NodeData; }
	if (kind === NodeKind.TypeObject) { const d = n.data as TypeObjectData; return { typExprFieldNames: X.strArr(d.typExprFieldNames), typExprFieldTypes: X.nodes(d.typExprFieldTypes) as Node[], typExprIndexKey: X.node(d.typExprIndexKey) as Node, typExprIndexValue: X.node(d.typExprIndexValue) as Node, typExprFieldDecorators: X.nodesNested(d.typExprFieldDecorators) as Node[][], typExprTypeName: X.str(d.typExprTypeName) } as NodeData; }
	if (kind === NodeKind.Program) { const d = n.data as ProgramData; return { programStmts: X.nodes(d.programStmts) as Node[] } as NodeData; }
	if (kind === NodeKind.ActorDecl) { const d = n.data as ActorDeclData; return { actorName: X.str(d.actorName), actorBody: X.nodes(d.actorBody) as Node[], nameLocation: X.loc(d.nameLocation) as SourceLocation } as NodeData; }
	if (kind === NodeKind.SpliceMany) { const d = n.data as SpliceManyData; return { spliceNodes: X.nodes(d.spliceNodes) as Node[] } as NodeData; }
	if (kind === NodeKind.JSXElement) { const d = n.data as JSXElementData; return { jsxTag: X.str(d.jsxTag), jsxAttrs: X.nodes(d.jsxAttrs) as Node[], jsxChildren: X.nodes(d.jsxChildren) as Node[], jsxSelfClosing: X.bool(d.jsxSelfClosing) } as NodeData; }
	if (kind === NodeKind.JSXFragment) { const d = n.data as JSXFragmentData; return { jsxFragChildren: X.nodes(d.jsxFragChildren) as Node[] } as NodeData; }
	if (kind === NodeKind.JSXText) { const d = n.data as JSXTextData; return { jsxText: X.str(d.jsxText) } as NodeData; }
	if (kind === NodeKind.JSXExpressionContainer) { const d = n.data as JSXExpressionContainerData; return { jsxExpr: X.node(d.jsxExpr) as Node } as NodeData; }
	if (kind === NodeKind.JSXAttribute) { const d = n.data as JSXAttributeData; return { jsxAttrName: X.str(d.jsxAttrName), jsxAttrValue: X.node(d.jsxAttrValue) as Node } as NodeData; }
	if (kind === NodeKind.JSXSpreadAttribute) { const d = n.data as JSXSpreadAttributeData; return { jsxSpreadArg: X.node(d.jsxSpreadArg) as Node } as NodeData; }
	// Unknown kind: share the original payload (the pre-unification clone's
	// fallback semantics for not-yet-handled kinds).
	return n.data;
}

export function nodeFields(n: Node, V: FieldSink): void {
	const kind = n.kind;
	if (kind === NodeKind.NumberLiteral) { const d = n.data as NumberLiteralData; V.bool("isFloat", d.isFloat); V.float("value", d.value); V.integer("intVal", d.intVal); V.str("outOfRangeText", d.outOfRangeText); V.bool("isBitPattern", d.isBitPattern); return; }
	if (kind === NodeKind.StringLiteral) { const d = n.data as StringLiteralData; V.str("value", d.value); return; }
	if (kind === NodeKind.BooleanLiteral) { const d = n.data as BooleanLiteralData; V.bool("boolValue", d.boolValue); return; }
	if (kind === NodeKind.NullLiteral) return;
	if (kind === NodeKind.BigIntLiteral) { const d = n.data as BigIntLiteralData; V.str("bigintValue", d.bigintValue); return; }
	if (kind === NodeKind.RegexLiteral) { const d = n.data as RegexLiteralData; V.str("regexPattern", d.regexPattern); return; }
	if (kind === NodeKind.Identifier) { const d = n.data as IdentifierData; V.str("name", d.name); return; }
	if (kind === NodeKind.BinaryExpr) { const d = n.data as BinaryExprData; V.str("operator", d.operator); V.node("left", d.left); V.node("right", d.right); return; }
	if (kind === NodeKind.UnaryExpr) { const d = n.data as UnaryExprData; V.str("unaryOp", d.unaryOp); V.node("operand", d.operand); return; }
	if (kind === NodeKind.UpdateExpr) { const d = n.data as UpdateExprData; V.str("updateOp", d.updateOp); V.node("updateArg", d.updateArg); V.bool("isPrefix", d.isPrefix); return; }
	if (kind === NodeKind.CallExpr) { const d = n.data as CallExprData; V.node("callee", d.callee); V.nodes("arguments", d.arguments); V.bool("isDirectCall", d.isDirectCall); V.float("resolvedOverloadIdx", d.resolvedOverloadIdx); return; }
	if (kind === NodeKind.MemberExpr) { const d = n.data as MemberExprData; V.node("object", d.object); V.str("property", d.property); V.bool("isOptional", d.isOptional); return; }
	if (kind === NodeKind.ArrayAccess) { const d = n.data as ArrayAccessData; V.node("array", d.array); V.node("index", d.index); return; }
	if (kind === NodeKind.ObjectLiteral) { const d = n.data as ObjectLiteralData; V.nodes("properties", d.properties); V.strArr("keys", d.keys); V.locs("keyLocations", d.keyLocations); return; }
	if (kind === NodeKind.ArrayLiteral) { const d = n.data as ArrayLiteralData; V.nodes("elements", d.elements); return; }
	if (kind === NodeKind.ArrowFunction) { const d = n.data as ArrowFunctionData; V.strArr("arrowParams", d.arrowParams); V.strArr("arrowParamTypes", d.arrowParamTypes); V.node("arrowBody", d.arrowBody); V.str("arrowFlags", d.arrowFlags); V.str("arrowReturnType", d.arrowReturnType); V.nodes("arrowDefaults", d.arrowDefaults); return; }
	if (kind === NodeKind.FunctionExpr) { const d = n.data as FunctionExprData; V.strArr("funcExprParams", d.funcExprParams); V.strArr("funcExprParamTypes", d.funcExprParamTypes); V.node("funcExprBody", d.funcExprBody); V.str("funcExprFlags", d.funcExprFlags); V.str("funcExprReturnType", d.funcExprReturnType); return; }
	if (kind === NodeKind.TypeAssertion) { const d = n.data as TypeAssertionData; V.node("asExpr", d.asExpr); V.str("asType", d.asType); return; }
	if (kind === NodeKind.ConditionalExpr) { const d = n.data as ConditionalExprData; V.node("ternaryCondition", d.ternaryCondition); V.node("ternaryConsequent", d.ternaryConsequent); V.node("ternaryAlternate", d.ternaryAlternate); return; }
	if (kind === NodeKind.SpreadExpr) { const d = n.data as SpreadExprData; V.node("spreadArg", d.spreadArg); return; }
	if (kind === NodeKind.NewExpr) { const d = n.data as NewExprData; V.node("newCallee", d.newCallee); V.nodes("newArguments", d.newArguments); return; }
	if (kind === NodeKind.TryExpr) { const d = n.data as TryExprData; V.node("tryArg", d.tryArg); V.bool("hasCatch", d.hasCatch); V.node("catchVal", d.catchVal); return; }
	if (kind === NodeKind.MatchExpr) { const d = n.data as MatchExprData; V.node("matchDisc", d.matchDisc); V.nodes("matchCases", d.matchCases); return; }
	if (kind === NodeKind.MatchCase) { const d = n.data as MatchCaseData; V.nodes("casePatterns", d.casePatterns); V.node("caseGuard", d.caseGuard); V.node("caseBody", d.caseBody); return; }
	if (kind === NodeKind.AwaitExpr) { const d = n.data as AwaitExprData; V.node("awaitArg", d.awaitArg); return; }
	if (kind === NodeKind.YieldExpr) { const d = n.data as YieldExprData; V.node("yieldArg", d.yieldArg); V.bool("isDelegate", d.isDelegate); return; }
	if (kind === NodeKind.MoveExpr) { const d = n.data as MoveExprData; V.node("moveArg", d.moveArg); return; }
	if (kind === NodeKind.OutExpr) { const d = n.data as OutExprData; V.node("outArg", d.outArg); return; }
	if (kind === NodeKind.SizeofExpr) { const d = n.data as SizeofExprData; V.str("sizeofType", d.sizeofType); return; }
	if (kind === NodeKind.HiddenStdConv || kind === NodeKind.HiddenSubConv) { const d = n.data as HiddenStdConvData; V.node("convExpr", d.convExpr); V.typ("convType", d.convType); return; }
	if (kind === NodeKind.HiddenDeref || kind === NodeKind.HiddenAddr) { const d = n.data as ExprStmtData; V.node("expr", d.expr); return; }
	if (kind === NodeKind.TypeAnnotation) { const d = n.data as TypeAnnotationData; V.str("annotationType", d.annotationType); return; }
	if (kind === NodeKind.ArrayPattern) { const d = n.data as ArrayPatternData; V.nodes("patternElements", d.patternElements); V.bool("hasRestElement", d.hasRestElement); return; }
	if (kind === NodeKind.ObjectPattern) { const d = n.data as ObjectPatternData; V.nodes("patternProps", d.patternProps); V.bool("hasRestProp", d.hasRestProp); return; }
	if (kind === NodeKind.ObjectPatternProp) { const d = n.data as ObjectPatternPropData; V.str("propKey", d.propKey); V.node("propAlias", d.propAlias); return; }
	if (kind === NodeKind.DestructuringDecl) { const d = n.data as DestructuringDeclData; V.node("destrPattern", d.destrPattern); V.node("destrInit", d.destrInit); V.bool("destrIsConst", d.destrIsConst); return; }
	if (kind === NodeKind.VariableDecl) { const d = n.data as VariableDeclData; V.str("declName", d.declName); V.str("declType", d.declType); V.node("initializer", d.initializer); V.integer("declKind", d.declKind as int32 as int64); V.loc("nameLocation", d.nameLocation); return; }
	if (kind === NodeKind.IfStmt) { const d = n.data as IfStmtData; V.node("condition", d.condition); V.node("consequent", d.consequent); V.node("alternate", d.alternate); return; }
	if (kind === NodeKind.WhileStmt) { const d = n.data as WhileStmtData; V.node("whileCondition", d.whileCondition); V.node("whileBody", d.whileBody); V.str("whileLabel", d.whileLabel); return; }
	if (kind === NodeKind.ForStmt) { const d = n.data as ForStmtData; V.node("forInit", d.forInit); V.node("forCondition", d.forCondition); V.node("forUpdate", d.forUpdate); V.node("forBody", d.forBody); return; }
	if (kind === NodeKind.ForOfStmt) { const d = n.data as ForOfStmtData; V.str("forOfBinding", d.forOfBinding); V.bool("forOfIsConst", d.forOfIsConst); V.node("forOfIterable", d.forOfIterable); V.node("forOfBody", d.forOfBody); V.node("forOfPattern", d.forOfPattern); V.loc("bindingLocation", d.bindingLocation); return; }
	if (kind === NodeKind.ForInStmt) { const d = n.data as ForInStmtData; V.str("forInBinding", d.forInBinding); V.bool("forInIsConst", d.forInIsConst); V.node("forInObject", d.forInObject); V.node("forInBody", d.forInBody); return; }
	if (kind === NodeKind.BlockStmt) { const d = n.data as BlockStmtData; V.nodes("statements", d.statements); return; }
	if (kind === NodeKind.ExprStmt) { const d = n.data as ExprStmtData; V.node("expr", d.expr); return; }
	if (kind === NodeKind.ReturnStmt) { const d = n.data as ReturnStmtData; V.node("argument", d.argument); return; }
	if (kind === NodeKind.BreakStmt) { const d = n.data as BreakStmtData; V.str("breakLabel", d.breakLabel); return; }
	if (kind === NodeKind.ContinueStmt) { const d = n.data as ContinueStmtData; V.str("continueLabel", d.continueLabel); return; }
	if (kind === NodeKind.FunctionDecl) { const d = n.data as FunctionDeclData; V.str("fnName", d.fnName); V.strArr("params", d.params); V.strArr("fnParamTypes", d.fnParamTypes); V.node("fnBody", d.fnBody); V.str("fnFlags", d.fnFlags); V.str("fnReturnType", d.fnReturnType); V.nodes("fnDefaults", d.fnDefaults); V.str("nativeName", d.nativeName); V.loc("nameLocation", d.nameLocation); return; }
	if (kind === NodeKind.DoWhileStmt) { const d = n.data as DoWhileStmtData; V.node("doBody", d.doBody); V.node("doCondition", d.doCondition); return; }
	if (kind === NodeKind.SwitchStmt) { const d = n.data as SwitchStmtData; V.node("switchDisc", d.switchDisc); V.nodes("switchCases", d.switchCases); return; }
	if (kind === NodeKind.SwitchCase) { const d = n.data as SwitchCaseData; V.nodes("caseTests", d.caseTests); V.nodes("caseStmts", d.caseStmts); V.bool("isDefault", d.isDefault); return; }
	if (kind === NodeKind.UnreachableStmt) { const d = n.data as UnreachableStmtData; V.str("unreachableMsg", d.unreachableMsg); return; }
	if (kind === NodeKind.MatchStmt) { const d = n.data as MatchStmtData; V.node("matchStmtDisc", d.matchStmtDisc); V.nodes("matchStmtCases", d.matchStmtCases); return; }
	if (kind === NodeKind.ImportDecl) { const d = n.data as ImportDeclData; V.strArr("importNames", d.importNames); V.strArr("importAliases", d.importAliases); V.str("importSource", d.importSource); V.locs("nameLocations", d.nameLocations); return; }
	if (kind === NodeKind.ExportDecl) { const d = n.data as ExportDeclData; V.node("exportedDecl", d.exportedDecl); return; }
	if (kind === NodeKind.TypeAliasDecl) { const d = n.data as TypeAliasDeclData; V.str("aliasName", d.aliasName); V.str("aliasType", d.aliasType); V.bool("aliasIsDistinct", d.aliasIsDistinct); V.str("aliasGenericParams", d.aliasGenericParams); V.str("discriminantName", d.discriminantName); V.str("discriminantType", d.discriminantType); V.strArr("variantKeys", d.variantKeys); V.strArr("variantTypes", d.variantTypes); V.loc("nameLocation", d.nameLocation); return; }
	if (kind === NodeKind.EnumDecl) { const d = n.data as EnumDeclData; V.str("enumName", d.enumName); V.strArr("enumMembers", d.enumMembers); V.floats("enumValues", d.enumValues); V.loc("nameLocation", d.nameLocation); V.locs("memberLocations", d.memberLocations); return; }
	if (kind === NodeKind.InterfaceDecl || kind === NodeKind.StructDecl) { const d = n.data as InterfaceDeclData; V.str("interfaceName", d.interfaceName); V.strArr("interfaceFields", d.interfaceFields); V.strArr("interfaceFieldTypes", d.interfaceFieldTypes); V.strArr("interfaceExtends", d.interfaceExtends); V.loc("nameLocation", d.nameLocation); return; }
	if (kind === NodeKind.ClassDecl) { const d = n.data as ClassDeclData; V.str("className", d.className); V.str("classExtends", d.classExtends); V.nodes("classBody", d.classBody); V.loc("nameLocation", d.nameLocation); return; }
	if (kind === NodeKind.PropertyDecl) { const d = n.data as PropertyDeclData; V.str("propName", d.propName); V.str("propType", d.propType); V.bool("propIsStatic", d.propIsStatic); V.bool("propIsReadonly", d.propIsReadonly); V.str("propVisibility", d.propVisibility); V.node("propInitializer", d.propInitializer); return; }
	if (kind === NodeKind.MethodDecl) { const d = n.data as MethodDeclData; V.str("methodName", d.methodName); V.strArr("methodParams", d.methodParams); V.strArr("methodParamTypes", d.methodParamTypes); V.node("methodBody", d.methodBody); V.bool("methodIsStatic", d.methodIsStatic); V.str("methodFlags", d.methodFlags); V.str("methodVisibility", d.methodVisibility); V.str("methodReturnType", d.methodReturnType); V.nodes("methodDefaults", d.methodDefaults); V.str("nativeName", d.nativeName); V.loc("nameLocation", d.nameLocation); return; }
	if (kind === NodeKind.ConstructorDecl) { const d = n.data as ConstructorDeclData; V.strArr("ctorParams", d.ctorParams); V.strArr("ctorParamTypes", d.ctorParamTypes); V.node("ctorBody", d.ctorBody); V.nodes("ctorDefaults", d.ctorDefaults); return; }
	if (kind === NodeKind.ThrowStmt) { const d = n.data as ThrowStmtData; V.node("throwArg", d.throwArg); return; }
	if (kind === NodeKind.TryCatchStmt) { const d = n.data as TryCatchStmtData; V.node("tryBody", d.tryBody); V.str("catchName", d.catchName); V.node("catchBody", d.catchBody); V.node("finallyBody", d.finallyBody); V.loc("catchBindingLocation", d.catchBindingLocation); V.bool("hasCatchClause", d.hasCatchClause); return; }
	if (kind === NodeKind.MacroInvocation) { const d = n.data as MacroInvocationData; V.str("macroName", d.macroName); V.nodes("macroArgs", d.macroArgs); return; }
	if (kind === NodeKind.DecoratedDecl) { const d = n.data as DecoratedDeclData; V.nodes("decorators", d.decorators); V.node("decoratedNode", d.decoratedNode); return; }
	if (kind === NodeKind.DeferStmt) { const d = n.data as DeferStmtData; V.node("deferExpr", d.deferExpr); return; }
	if (kind === NodeKind.TestDecl) { const d = n.data as TestDeclData; V.str("testName", d.testName); V.node("testBody", d.testBody); return; }
	if (kind === NodeKind.AssertStmt) { const d = n.data as AssertStmtData; V.node("assertExpr", d.assertExpr); V.str("assertSource", d.assertSource); V.str("assertMessage", d.assertMessage); V.node("assertMessageExpr", d.assertMessageExpr); return; }
	if (kind === NodeKind.ExternDecl) { const d = n.data as ExternDeclData; V.integer("externKind", d.externKind as int32 as int64); V.str("externName", d.externName); V.str("nativeName", d.nativeName); V.str("externType", d.externType); return; }
	if (kind === NodeKind.MacroDecl) { const d = n.data as MacroDeclData; V.str("macroDeclName", d.macroDeclName); V.strArr("macroDeclParams", d.macroDeclParams); V.strArr("macroDeclParamTypes", d.macroDeclParamTypes); V.str("macroDeclReturnType", d.macroDeclReturnType); V.node("macroDeclBody", d.macroDeclBody); return; }
	if (kind === NodeKind.QuoteExpr) { const d = n.data as QuoteExprData; V.node("quoteBody", d.quoteBody); return; }
	if (kind === NodeKind.ComptimeBlock) { const d = n.data as ComptimeBlockData; V.node("comptimeBody", d.comptimeBody); return; }
	if (kind === NodeKind.TypeGeneric) { const d = n.data as TypeGenericData; V.node("typExprBase", d.typExprBase); V.nodes("typExprArgs", d.typExprArgs); return; }
	if (kind === NodeKind.TypeArray) { const d = n.data as TypeArrayData; V.node("typExprElement", d.typExprElement); V.float("typExprSize", d.typExprSize); return; }
	if (kind === NodeKind.TypeUnion) { const d = n.data as TypeUnionData; V.nodes("typExprMembers", d.typExprMembers); V.str("discFieldName", d.discFieldName); V.strArr("variantKeys", d.variantKeys); V.str("discKind", d.discKind); return; }
	if (kind === NodeKind.TypeIntersection) { const d = n.data as TypeIntersectionData; V.nodes("typExprMembers", d.typExprMembers); return; }
	if (kind === NodeKind.TypeFunction) { const d = n.data as TypeFunctionData; V.nodes("typExprParams", d.typExprParams); V.node("typExprReturn", d.typExprReturn); V.strArr("typExprParamNames", d.typExprParamNames); return; }
	if (kind === NodeKind.TypeObject) { const d = n.data as TypeObjectData; V.strArr("typExprFieldNames", d.typExprFieldNames); V.nodes("typExprFieldTypes", d.typExprFieldTypes); V.node("typExprIndexKey", d.typExprIndexKey); V.node("typExprIndexValue", d.typExprIndexValue); V.nodesNested("typExprFieldDecorators", d.typExprFieldDecorators); V.str("typExprTypeName", d.typExprTypeName); return; }
	if (kind === NodeKind.Program) { const d = n.data as ProgramData; V.nodes("programStmts", d.programStmts); return; }
	if (kind === NodeKind.ActorDecl) { const d = n.data as ActorDeclData; V.str("actorName", d.actorName); V.nodes("actorBody", d.actorBody); V.loc("nameLocation", d.nameLocation); return; }
	if (kind === NodeKind.SpliceMany) { const d = n.data as SpliceManyData; V.nodes("spliceNodes", d.spliceNodes); return; }
	if (kind === NodeKind.JSXElement) { const d = n.data as JSXElementData; V.str("jsxTag", d.jsxTag); V.nodes("jsxAttrs", d.jsxAttrs); V.nodes("jsxChildren", d.jsxChildren); V.bool("jsxSelfClosing", d.jsxSelfClosing); return; }
	if (kind === NodeKind.JSXFragment) { const d = n.data as JSXFragmentData; V.nodes("jsxFragChildren", d.jsxFragChildren); return; }
	if (kind === NodeKind.JSXText) { const d = n.data as JSXTextData; V.str("jsxText", d.jsxText); return; }
	if (kind === NodeKind.JSXExpressionContainer) { const d = n.data as JSXExpressionContainerData; V.node("jsxExpr", d.jsxExpr); return; }
	if (kind === NodeKind.JSXAttribute) { const d = n.data as JSXAttributeData; V.str("jsxAttrName", d.jsxAttrName); V.node("jsxAttrValue", d.jsxAttrValue); return; }
	if (kind === NodeKind.JSXSpreadAttribute) { const d = n.data as JSXSpreadAttributeData; V.node("jsxSpreadArg", d.jsxSpreadArg); return; }
}

// ===== Exhaustive per-kind test helpers =====
//
// A fourth, deliberately independent per-kind walk: the samples and the dump
// below are written from std/meta/node.ms's NodeData union, NOT from
// nodeFields/rebuildNodeData. Every field gets a distinctive non-default
// value, so a field that a consumer drops or misroutes re-emerges as a
// default and the dump diverges. If a NodeKind or a NodeData field lands in
// node.ms without spec coverage, this is the tripwire — extend pkSamples
// (enum order, strictly ascending kind ints), pkDumpNode, and the 91 count
// together. The sample Types are injected by callers because this module is
// an ast leaf and must not import the checker's type factories.

export function pkLoc(seed: int32): SourceLocation {
	const l = makeLoc(seed, seed + 10);
	l.endLine = seed + 20;
	l.endColumn = seed + 30;
	return l;
}

export function pkIdent(name: string): Node {
	return createNodeAt(NodeKind.Identifier, { name: name } as NodeData, makeLoc(3, 4));
}

export function pkNum(v: number, iv: int64): Node {
	return createNodeAt(NodeKind.NumberLiteral, { value: v, isFloat: true, intVal: iv, outOfRangeText: "oor", isBitPattern: true } as NodeData, makeLoc(5, 6));
}

export function pkSamples(rootSym: Symbol, nodeTypeSample: Type, convTypeSample: Type): Node[] {
	const a = pkIdent("a");
	const n1 = pkNum(1.5, 11);
	const block = createNodeAt(NodeKind.BlockStmt, { statements: [a] } as NodeData, makeLoc(7, 8));
	const matchCase = createNodeAt(NodeKind.MatchCase, { casePatterns: [a], caseGuard: a, caseBody: a } as NodeData, makeLoc(9, 2));
	const switchCase = createNodeAt(NodeKind.SwitchCase, { caseTests: [n1], caseStmts: [a], isDefault: true } as NodeData, makeLoc(10, 2));
	const objPatProp = createNodeAt(NodeKind.ObjectPatternProp, { propKey: "k", propAlias: a } as NodeData, makeLoc(11, 2));
	const objPat = createNodeAt(NodeKind.ObjectPattern, { patternProps: [objPatProp], hasRestProp: true } as NodeData, makeLoc(12, 2));
	const fnDecl = createNodeAt(NodeKind.FunctionDecl, { fnName: "fd", params: ["p1", "p2"], fnParamTypes: ["int32", "string"], fnBody: block, fnFlags: "ff", fnReturnType: "int32", fnDefaults: [n1], nativeName: "nn", nameLocation: pkLoc(1) } as NodeData, makeLoc(13, 1));
	// header-column coverage rides on two samples: flags/typeArg/typeExpr/
	// typeExprs/paramLocations/nodeType on the FunctionDecl, resolvedSym on
	// an Identifier (a cross-table link back into S).
	fnDecl.flags = 85;
	fnDecl.typeArg = "TArg";
	fnDecl.typeExpr = pkIdent("te");
	fnDecl.typeExprs = [pkIdent("te1"), pkIdent("te2")];
	fnDecl.paramLocations = [pkLoc(2), pkLoc(3)];
	fnDecl.nodeType = nodeTypeSample;
	const linked = pkIdent("linked");
	linked.resolvedSym = rootSym;
	const methodDecl = createNodeAt(NodeKind.MethodDecl, { methodName: "m", methodParams: ["p"], methodParamTypes: ["int32"], methodBody: block, methodIsStatic: true, methodFlags: "mf", methodVisibility: "priv", methodReturnType: "void", methodDefaults: [n1], nativeName: "mn", nameLocation: pkLoc(4) } as NodeData, makeLoc(14, 2));
	const jsxText = createNodeAt(NodeKind.JSXText, { jsxText: "hello" } as NodeData, makeLoc(15, 2));
	const jsxAttr = createNodeAt(NodeKind.JSXAttribute, { jsxAttrName: "id", jsxAttrValue: a } as NodeData, makeLoc(16, 2));
	const out: Node[] = [];
	out.push(createNodeAt(NodeKind.NumberLiteral, { value: 2.5, isFloat: true, intVal: 42, outOfRangeText: "oor", isBitPattern: true } as NodeData, makeLoc(17, 1)));
	out.push(createNodeAt(NodeKind.StringLiteral, { value: "pk\tstr,com" } as NodeData, makeLoc(17, 2)));
	out.push(createNodeAt(NodeKind.BooleanLiteral, { boolValue: true } as NodeData, makeLoc(17, 3)));
	out.push(createNodeAt(NodeKind.NullLiteral, { nullPlaceholder: true } as NodeData, makeLoc(17, 4)));
	out.push(createNodeAt(NodeKind.BigIntLiteral, { bigintValue: "123n" } as NodeData, makeLoc(17, 5)));
	out.push(createNodeAt(NodeKind.RegexLiteral, { regexPattern: "/a+b/gi" } as NodeData, makeLoc(17, 6)));
	out.push(a);
	out.push(createNodeAt(NodeKind.BinaryExpr, { operator: "+", left: a, right: n1 } as NodeData, makeLoc(17, 8)));
	out.push(createNodeAt(NodeKind.UnaryExpr, { unaryOp: "!", operand: a } as NodeData, makeLoc(17, 9)));
	out.push(createNodeAt(NodeKind.UpdateExpr, { updateOp: "++", updateArg: a, isPrefix: true } as NodeData, makeLoc(17, 10)));
	out.push(createNodeAt(NodeKind.CallExpr, { callee: a, arguments: [a, n1], isDirectCall: true, resolvedOverloadIdx: -7 } as NodeData, makeLoc(17, 11)));
	out.push(createNodeAt(NodeKind.MemberExpr, { object: a, property: "fld", isOptional: true } as NodeData, makeLoc(17, 12)));
	out.push(createNodeAt(NodeKind.ArrayAccess, { array: a, index: n1 } as NodeData, makeLoc(17, 13)));
	out.push(createNodeAt(NodeKind.ObjectLiteral, { properties: [a], keys: ["k1", "k2"], keyLocations: [pkLoc(5)] } as NodeData, makeLoc(17, 14)));
	out.push(createNodeAt(NodeKind.ArrayLiteral, { elements: [n1, a] } as NodeData, makeLoc(17, 15)));
	out.push(createNodeAt(NodeKind.ArrowFunction, { arrowParams: ["x", "y"], arrowParamTypes: ["int32", "string"], arrowBody: block, arrowFlags: "af", arrowReturnType: "void", arrowDefaults: [a, null as unknown as Node] } as NodeData, makeLoc(17, 16)));
	out.push(createNodeAt(NodeKind.FunctionExpr, { funcExprParams: ["x"], funcExprParamTypes: ["int32"], funcExprBody: block, funcExprFlags: "fef", funcExprReturnType: "int32" } as NodeData, makeLoc(17, 17)));
	out.push(createNodeAt(NodeKind.TypeAssertion, { asExpr: n1, asType: "int64" } as NodeData, makeLoc(17, 18)));
	out.push(createNodeAt(NodeKind.ConditionalExpr, { ternaryCondition: a, ternaryConsequent: n1, ternaryAlternate: a } as NodeData, makeLoc(17, 19)));
	out.push(createNodeAt(NodeKind.SpreadExpr, { spreadArg: a } as NodeData, makeLoc(17, 20)));
	out.push(createNodeAt(NodeKind.NewExpr, { newCallee: a, newArguments: [n1] } as NodeData, makeLoc(17, 21)));
	out.push(createNodeAt(NodeKind.TryExpr, { tryArg: a, hasCatch: true, catchVal: pkIdent("cv") } as NodeData, makeLoc(17, 22)));
	out.push(createNodeAt(NodeKind.MatchExpr, { matchDisc: a, matchCases: [matchCase] } as NodeData, makeLoc(17, 23)));
	out.push(matchCase);
	out.push(createNodeAt(NodeKind.AwaitExpr, { awaitArg: a } as NodeData, makeLoc(17, 25)));
	out.push(createNodeAt(NodeKind.YieldExpr, { yieldArg: a, isDelegate: true } as NodeData, makeLoc(17, 26)));
	out.push(createNodeAt(NodeKind.MoveExpr, { moveArg: a } as NodeData, makeLoc(17, 27)));
	out.push(createNodeAt(NodeKind.OutExpr, { outArg: a } as NodeData, makeLoc(17, 28)));
	out.push(createNodeAt(NodeKind.HiddenDeref, { expr: a } as NodeData, makeLoc(17, 29)));
	out.push(createNodeAt(NodeKind.HiddenAddr, { expr: a } as NodeData, makeLoc(17, 30)));
	out.push(createNodeAt(NodeKind.HiddenStdConv, { convExpr: a, convType: convTypeSample } as NodeData, makeLoc(17, 31)));
	out.push(createNodeAt(NodeKind.HiddenSubConv, { convExpr: a, convType: convTypeSample } as NodeData, makeLoc(17, 32)));
	out.push(createNodeAt(NodeKind.TypeAnnotation, { annotationType: "float32" } as NodeData, makeLoc(17, 33)));
	out.push(createNodeAt(NodeKind.ArrayPattern, { patternElements: [a, n1], hasRestElement: true } as NodeData, makeLoc(17, 34)));
	out.push(objPat);
	out.push(objPatProp);
	out.push(createNodeAt(NodeKind.DestructuringDecl, { destrPattern: objPat, destrInit: n1, destrIsConst: true } as NodeData, makeLoc(17, 37)));
	out.push(createNodeAt(NodeKind.VariableDecl, { declName: "v", declType: "int32", initializer: n1, declKind: 2 as int32 as unknown as DeclKind, nameLocation: pkLoc(6) } as NodeData, makeLoc(17, 38)));
	out.push(createNodeAt(NodeKind.IfStmt, { condition: a, consequent: block, alternate: a } as NodeData, makeLoc(17, 39)));
	out.push(createNodeAt(NodeKind.WhileStmt, { whileCondition: a, whileBody: block, whileLabel: "lbl" } as NodeData, makeLoc(17, 40)));
	out.push(createNodeAt(NodeKind.ForStmt, { forInit: a, forCondition: a, forUpdate: a, forBody: block } as NodeData, makeLoc(17, 41)));
	out.push(createNodeAt(NodeKind.ForOfStmt, { forOfBinding: "x", forOfIsConst: true, forOfIterable: a, forOfBody: block, forOfPattern: a, bindingLocation: pkLoc(7) } as NodeData, makeLoc(17, 42)));
	out.push(createNodeAt(NodeKind.ForInStmt, { forInBinding: "y", forInIsConst: true, forInObject: a, forInBody: block } as NodeData, makeLoc(17, 43)));
	out.push(block);
	out.push(createNodeAt(NodeKind.ExprStmt, { expr: a } as NodeData, makeLoc(17, 45)));
	out.push(createNodeAt(NodeKind.ReturnStmt, { argument: n1 } as NodeData, makeLoc(17, 46)));
	out.push(createNodeAt(NodeKind.BreakStmt, { breakLabel: "bk" } as NodeData, makeLoc(17, 47)));
	out.push(createNodeAt(NodeKind.ContinueStmt, { continueLabel: "ct" } as NodeData, makeLoc(17, 48)));
	out.push(fnDecl);
	out.push(createNodeAt(NodeKind.DoWhileStmt, { doBody: block, doCondition: a } as NodeData, makeLoc(17, 50)));
	out.push(createNodeAt(NodeKind.SwitchStmt, { switchDisc: a, switchCases: [switchCase] } as NodeData, makeLoc(17, 51)));
	out.push(switchCase);
	out.push(createNodeAt(NodeKind.UnreachableStmt, { unreachableMsg: "um" } as NodeData, makeLoc(17, 53)));
	out.push(createNodeAt(NodeKind.MatchStmt, { matchStmtDisc: a, matchStmtCases: [matchCase] } as NodeData, makeLoc(17, 54)));
	out.push(createNodeAt(NodeKind.ImportDecl, { importNames: ["a", "b"], importAliases: ["x", "y"], importSource: "std/fs", nameLocations: null as unknown as SourceLocation[] } as NodeData, makeLoc(17, 55)));
	out.push(createNodeAt(NodeKind.ExportDecl, { exportedDecl: fnDecl } as NodeData, makeLoc(17, 56)));
	out.push(createNodeAt(NodeKind.TypeAliasDecl, { aliasName: "TA", aliasType: "int32", aliasIsDistinct: true, aliasGenericParams: "<T>", discriminantName: "d", discriminantType: "string", variantKeys: ["A", "B"], variantTypes: ["{a}", "{b}"], nameLocation: pkLoc(8) } as NodeData, makeLoc(17, 57)));
	out.push(createNodeAt(NodeKind.EnumDecl, { enumName: "E", enumMembers: ["A", "B"], enumValues: [1.5, -2.25], nameLocation: pkLoc(9), memberLocations: [pkLoc(10)] } as NodeData, makeLoc(17, 58)));
	out.push(createNodeAt(NodeKind.InterfaceDecl, { interfaceName: "I1", interfaceFields: ["f"], interfaceFieldTypes: ["int32"], interfaceExtends: ["B1"], nameLocation: pkLoc(11) } as NodeData, makeLoc(17, 59)));
	out.push(createNodeAt(NodeKind.StructDecl, { interfaceName: "S1", interfaceFields: ["g"], interfaceFieldTypes: ["string"], interfaceExtends: ["B2"], nameLocation: pkLoc(12) } as NodeData, makeLoc(17, 60)));
	out.push(createNodeAt(NodeKind.ClassDecl, { className: "C", classExtends: "Base", classBody: [methodDecl], nameLocation: pkLoc(13) } as NodeData, makeLoc(17, 61)));
	out.push(createNodeAt(NodeKind.PropertyDecl, { propName: "p", propType: "int32", propIsStatic: true, propIsReadonly: true, propVisibility: "pub", propInitializer: n1 } as NodeData, makeLoc(17, 62)));
	out.push(methodDecl);
	out.push(createNodeAt(NodeKind.ConstructorDecl, { ctorParams: ["c"], ctorParamTypes: ["int32"], ctorBody: block, ctorDefaults: [a] } as NodeData, makeLoc(17, 64)));
	out.push(createNodeAt(NodeKind.ThrowStmt, { throwArg: a } as NodeData, makeLoc(17, 65)));
	out.push(createNodeAt(NodeKind.TryCatchStmt, { tryBody: block, catchName: "e", catchBody: block, finallyBody: block, catchBindingLocation: pkLoc(14), hasCatchClause: true } as NodeData, makeLoc(17, 66)));
	out.push(createNodeAt(NodeKind.MacroInvocation, { macroName: "mac", macroArgs: [a, n1] } as NodeData, makeLoc(17, 67)));
	out.push(createNodeAt(NodeKind.DecoratedDecl, { decorators: [a], decoratedNode: fnDecl } as NodeData, makeLoc(17, 68)));
	out.push(createNodeAt(NodeKind.DeferStmt, { deferExpr: a } as NodeData, makeLoc(17, 69)));
	out.push(createNodeAt(NodeKind.TestDecl, { testName: "t", testBody: block } as NodeData, makeLoc(17, 70)));
	out.push(createNodeAt(NodeKind.AssertStmt, { assertExpr: a, assertSource: "src.ms", assertMessage: "msg", assertMessageExpr: pkIdent("am") } as NodeData, makeLoc(17, 71)));
	out.push(createNodeAt(NodeKind.ExternDecl, { externKind: 2 as int32 as unknown as ExternKind, externName: "ext", nativeName: "nat", externType: "void" } as NodeData, makeLoc(17, 72)));
	out.push(createNodeAt(NodeKind.MacroDecl, { macroDeclName: "md", macroDeclParams: ["p"], macroDeclParamTypes: ["string"], macroDeclReturnType: "void", macroDeclBody: block } as NodeData, makeLoc(17, 73)));
	out.push(createNodeAt(NodeKind.QuoteExpr, { quoteBody: block } as NodeData, makeLoc(17, 74)));
	out.push(createNodeAt(NodeKind.ComptimeBlock, { comptimeBody: block } as NodeData, makeLoc(17, 75)));
	out.push(createNodeAt(NodeKind.SizeofExpr, { sizeofType: "int32" } as NodeData, makeLoc(17, 76)));
	out.push(createNodeAt(NodeKind.TypeGeneric, { typExprBase: a, typExprArgs: [a, n1] } as NodeData, makeLoc(17, 77)));
	out.push(createNodeAt(NodeKind.TypeArray, { typExprElement: a, typExprSize: -1 } as NodeData, makeLoc(17, 78)));
	out.push(createNodeAt(NodeKind.TypeUnion, { typExprMembers: [a, n1], discFieldName: "kind", variantKeys: ["A", "B"], discKind: "enum" } as NodeData, makeLoc(17, 79)));
	out.push(createNodeAt(NodeKind.TypeFunction, { typExprParams: [a], typExprReturn: a, typExprParamNames: ["p"] } as NodeData, makeLoc(17, 80)));
	out.push(createNodeAt(NodeKind.TypeObject, { typExprFieldNames: ["f1", "f2"], typExprFieldTypes: [a, n1], typExprIndexKey: a, typExprIndexValue: a, typExprFieldDecorators: [[a], [a, n1]], typExprTypeName: "TObj" } as NodeData, makeLoc(17, 81)));
	out.push(createNodeAt(NodeKind.Program, { programStmts: [a] } as NodeData, makeLoc(17, 82)));
	out.push(createNodeAt(NodeKind.ActorDecl, { actorName: "act", actorBody: [a, block], nameLocation: pkLoc(15) } as NodeData, makeLoc(17, 83)));
	out.push(createNodeAt(NodeKind.SpliceMany, { spliceNodes: [a, n1] } as NodeData, makeLoc(17, 84)));
	out.push(createNodeAt(NodeKind.TypeIntersection, { typExprMembers: [a, n1] } as NodeData, makeLoc(17, 85)));
	out.push(createNodeAt(NodeKind.JSXElement, { jsxTag: "div", jsxAttrs: [jsxAttr], jsxChildren: [jsxText], jsxSelfClosing: true } as NodeData, makeLoc(17, 86)));
	out.push(createNodeAt(NodeKind.JSXFragment, { jsxFragChildren: [jsxText] } as NodeData, makeLoc(17, 87)));
	out.push(jsxText);
	out.push(createNodeAt(NodeKind.JSXExpressionContainer, { jsxExpr: a } as NodeData, makeLoc(17, 89)));
	out.push(jsxAttr);
	out.push(createNodeAt(NodeKind.JSXSpreadAttribute, { jsxSpreadArg: a } as NodeData, makeLoc(17, 91)));
	// resolvedSym coverage: slot 6 (Identifier) carries the cross-table link.
	out[6] = linked;
	return out;
}

export function pkDumpLoc(l: SourceLocation | null): string {
	if (l === null) return "L-";
	return `L${l.line},${l.column},${l.endLine},${l.endColumn}`;
}

// withMeta=false compares payload only (kind + location + per-kind fields),
// skipping header extras (flags/typeArg/typeExpr/typeExprs/paramLocations/
// nodeType/resolvedSym) — the axes where clone modes intentionally differ
// (copyNodeMeta) and thus must not be asserted equal.
export function pkDumpNode(n: Node | null, withMeta: boolean = true): string {
	if (n === null) return "null";
	let s = `k${n.kind as int32}`;
	if (withMeta) s = s + `f${n.flags}ta=${n.typeArg}`;
	s = s + pkDumpLoc(n.location);
	if (withMeta) {
		if (n.typeExpr !== null) s = s + "te=" + pkDumpNode(n.typeExpr);
		if (n.typeExprs !== null) {
			s = s + "tes=";
			for (const t of n.typeExprs) s = s + pkDumpNode(t) + ";";
		}
		if (n.paramLocations !== null) {
			s = s + "pls=";
			for (const p of n.paramLocations) s = s + pkDumpLoc(p) + ";";
		}
		if (n.nodeType !== null) s = s + `nt=${n.nodeType.kind as int32}:${n.nodeType.typeName}`;
		if (n.resolvedSym !== null) s = s + `sym=${n.resolvedSym.name}/${n.resolvedSym.symFlags}`;
	}
	const kind = n.kind;
	if (kind === NodeKind.NumberLiteral) { const d = n.data as NumberLiteralData; return s + `num=${d.value}/${d.isFloat ? "T" : "F"}/${d.intVal}/${d.outOfRangeText}/${d.isBitPattern ? "T" : "F"}`; }
	if (kind === NodeKind.StringLiteral) { const d = n.data as StringLiteralData; return s + `str=${d.value}`; }
	if (kind === NodeKind.BooleanLiteral) { const d = n.data as BooleanLiteralData; return s + `bool=${d.boolValue ? "T" : "F"}`; }
	if (kind === NodeKind.NullLiteral) return s + "null=nph";
	if (kind === NodeKind.BigIntLiteral) { const d = n.data as BigIntLiteralData; return s + `big=${d.bigintValue}`; }
	if (kind === NodeKind.RegexLiteral) { const d = n.data as RegexLiteralData; return s + `re=${d.regexPattern}`; }
	if (kind === NodeKind.Identifier) { const d = n.data as IdentifierData; return s + `id=${d.name}`; }
	if (kind === NodeKind.BinaryExpr) { const d = n.data as BinaryExprData; return s + `bin=${d.operator}(${pkDumpNode(d.left, withMeta)}),${pkDumpNode(d.right, withMeta)})`; }
	if (kind === NodeKind.UnaryExpr) { const d = n.data as UnaryExprData; return s + `un=${d.unaryOp}(${pkDumpNode(d.operand, withMeta)})`; }
	if (kind === NodeKind.UpdateExpr) { const d = n.data as UpdateExprData; return s + `upd=${d.updateOp}${d.isPrefix ? "P" : "S"}(${pkDumpNode(d.updateArg, withMeta)})`; }
	if (kind === NodeKind.CallExpr) { const d = n.data as CallExprData; s = s + `call=${pkDumpNode(d.callee, withMeta)}dir=${d.isDirectCall ? "T" : "F"}roi=${d.resolvedOverloadIdx}args=`; for (const x of d.arguments) s = s + pkDumpNode(x, withMeta) + ";"; return s; }
	if (kind === NodeKind.MemberExpr) { const d = n.data as MemberExprData; return s + `mem=${pkDumpNode(d.object, withMeta)}.${d.property}opt=${d.isOptional ? "T" : "F"}`; }
	if (kind === NodeKind.ArrayAccess) { const d = n.data as ArrayAccessData; return s + `aa=${pkDumpNode(d.array, withMeta)}[${pkDumpNode(d.index, withMeta)}]`; }
	if (kind === NodeKind.ObjectLiteral) { const d = n.data as ObjectLiteralData; s = s + "obj=keys=" + d.keys.join("|") + "klocs="; for (const l of d.keyLocations) s = s + pkDumpLoc(l) + ";"; s = s + "props="; for (const p of d.properties) s = s + pkDumpNode(p, withMeta) + ";"; return s; }
	if (kind === NodeKind.ArrayLiteral) { const d = n.data as ArrayLiteralData; s = s + "arr="; for (const e of d.elements) s = s + pkDumpNode(e, withMeta) + ";"; return s; }
	if (kind === NodeKind.ArrowFunction) { const d = n.data as ArrowFunctionData; s = s + `arrow=${d.arrowParams.join("|")}/${d.arrowParamTypes.join("|")}/${d.arrowFlags}/${d.arrowReturnType}body=${pkDumpNode(d.arrowBody, withMeta)}defs=`; for (const x of d.arrowDefaults) s = s + pkDumpNode(x, withMeta) + ";"; return s; }
	if (kind === NodeKind.FunctionExpr) { const d = n.data as FunctionExprData; return s + `fexpr=${d.funcExprParams.join("|")}/${d.funcExprParamTypes.join("|")}/${d.funcExprFlags}/${d.funcExprReturnType}body=${pkDumpNode(d.funcExprBody, withMeta)}`; }
	if (kind === NodeKind.TypeAssertion) { const d = n.data as TypeAssertionData; return s + `as=${pkDumpNode(d.asExpr, withMeta)}:${d.asType}`; }
	if (kind === NodeKind.ConditionalExpr) { const d = n.data as ConditionalExprData; return s + `cond=(${pkDumpNode(d.ternaryCondition, withMeta)}?${pkDumpNode(d.ternaryConsequent, withMeta)}:${pkDumpNode(d.ternaryAlternate, withMeta)})`; }
	if (kind === NodeKind.SpreadExpr) { const d = n.data as SpreadExprData; return s + `spread=${pkDumpNode(d.spreadArg, withMeta)}`; }
	if (kind === NodeKind.NewExpr) { const d = n.data as NewExprData; s = s + `new=${pkDumpNode(d.newCallee, withMeta)}args=`; for (const x of d.newArguments) s = s + pkDumpNode(x, withMeta) + ";"; return s; }
	if (kind === NodeKind.TryExpr) { const d = n.data as TryExprData; return s + `try=${pkDumpNode(d.tryArg, withMeta)}catch=${d.hasCatch ? "T" : "F"}(${pkDumpNode(d.catchVal, withMeta)})`; }
	if (kind === NodeKind.MatchExpr) { const d = n.data as MatchExprData; s = s + `mex=${pkDumpNode(d.matchDisc, withMeta)}cases=`; for (const c of d.matchCases) s = s + pkDumpNode(c, withMeta) + ";"; return s; }
	if (kind === NodeKind.MatchCase) { const d = n.data as MatchCaseData; s = s + "case=p="; for (const p of d.casePatterns) s = s + pkDumpNode(p, withMeta) + ";"; return s + `g=${pkDumpNode(d.caseGuard, withMeta)}b=${pkDumpNode(d.caseBody, withMeta)}`; }
	if (kind === NodeKind.AwaitExpr) { const d = n.data as AwaitExprData; return s + `await=${pkDumpNode(d.awaitArg, withMeta)}`; }
	if (kind === NodeKind.YieldExpr) { const d = n.data as YieldExprData; return s + `yield=${pkDumpNode(d.yieldArg, withMeta)}${d.isDelegate ? "D" : "S"}`; }
	if (kind === NodeKind.MoveExpr) { const d = n.data as MoveExprData; return s + `move=${pkDumpNode(d.moveArg, withMeta)}`; }
	if (kind === NodeKind.OutExpr) { const d = n.data as OutExprData; return s + `out=${pkDumpNode(d.outArg, withMeta)}`; }
	if (kind === NodeKind.HiddenDeref || kind === NodeKind.HiddenAddr) { const d = n.data as ExprStmtData; return s + `hid=${pkDumpNode(d.expr, withMeta)}`; }
	if (kind === NodeKind.HiddenStdConv || kind === NodeKind.HiddenSubConv) { const d = n.data as HiddenStdConvData; return s + `conv=${pkDumpNode(d.convExpr, withMeta)}:${d.convType.kind as int32}:${d.convType.typeName}`; }
	if (kind === NodeKind.TypeAnnotation) { const d = n.data as TypeAnnotationData; return s + `ann=${d.annotationType}`; }
	if (kind === NodeKind.ArrayPattern) { const d = n.data as ArrayPatternData; s = s + `apat=${d.hasRestElement ? "T" : "F"}`; for (const p of d.patternElements) s = s + pkDumpNode(p, withMeta) + ";"; return s; }
	if (kind === NodeKind.ObjectPattern) { const d = n.data as ObjectPatternData; s = s + `opat=${d.hasRestProp ? "T" : "F"}`; for (const p of d.patternProps) s = s + pkDumpNode(p, withMeta) + ";"; return s; }
	if (kind === NodeKind.ObjectPatternProp) { const d = n.data as ObjectPatternPropData; return s + `oprop=${d.propKey}:${pkDumpNode(d.propAlias, withMeta)}`; }
	if (kind === NodeKind.DestructuringDecl) { const d = n.data as DestructuringDeclData; return s + `destr=${pkDumpNode(d.destrPattern, withMeta)}=${pkDumpNode(d.destrInit, withMeta)}${d.destrIsConst ? "C" : "L"}`; }
	if (kind === NodeKind.VariableDecl) { const d = n.data as VariableDeclData; return s + `var=${d.declName}:${d.declType}:${d.declKind as int32}:${pkDumpLoc(d.nameLocation)}=${pkDumpNode(d.initializer, withMeta)}`; }
	if (kind === NodeKind.IfStmt) { const d = n.data as IfStmtData; return s + `if=(${pkDumpNode(d.condition, withMeta)}${pkDumpNode(d.consequent, withMeta)}${pkDumpNode(d.alternate, withMeta)})`; }
	if (kind === NodeKind.WhileStmt) { const d = n.data as WhileStmtData; return s + `while=${d.whileLabel}(${pkDumpNode(d.whileCondition, withMeta)}${pkDumpNode(d.whileBody, withMeta)})`; }
	if (kind === NodeKind.ForStmt) { const d = n.data as ForStmtData; return s + `for=(${pkDumpNode(d.forInit, withMeta)}${pkDumpNode(d.forCondition, withMeta)}${pkDumpNode(d.forUpdate, withMeta)}${pkDumpNode(d.forBody, withMeta)})`; }
	if (kind === NodeKind.ForOfStmt) { const d = n.data as ForOfStmtData; return s + `forof=${d.forOfBinding}${d.forOfIsConst ? "C" : "L"}:${pkDumpLoc(d.bindingLocation)}(${pkDumpNode(d.forOfIterable, withMeta)}${pkDumpNode(d.forOfBody, withMeta)}${pkDumpNode(d.forOfPattern, withMeta)})`; }
	if (kind === NodeKind.ForInStmt) { const d = n.data as ForInStmtData; return s + `forin=${d.forInBinding}${d.forInIsConst ? "C" : "L"}(${pkDumpNode(d.forInObject, withMeta)}${pkDumpNode(d.forInBody, withMeta)})`; }
	if (kind === NodeKind.BlockStmt) { const d = n.data as BlockStmtData; s = s + "blk="; for (const x of d.statements) s = s + pkDumpNode(x, withMeta) + ";"; return s; }
	if (kind === NodeKind.ExprStmt) { const d = n.data as ExprStmtData; return s + `expr=${pkDumpNode(d.expr, withMeta)}`; }
	if (kind === NodeKind.ReturnStmt) { const d = n.data as ReturnStmtData; return s + `ret=${pkDumpNode(d.argument, withMeta)}`; }
	if (kind === NodeKind.BreakStmt) { const d = n.data as BreakStmtData; return s + `brk=${d.breakLabel}`; }
	if (kind === NodeKind.ContinueStmt) { const d = n.data as ContinueStmtData; return s + `cont=${d.continueLabel}`; }
	if (kind === NodeKind.FunctionDecl) { const d = n.data as FunctionDeclData; s = s + `fn=${d.fnName}:${d.params.join("|")}:${d.fnParamTypes.join("|")}:${d.fnFlags}:${d.fnReturnType}:${d.nativeName}:${pkDumpLoc(d.nameLocation)}body=${pkDumpNode(d.fnBody, withMeta)}defs=`; for (const x of d.fnDefaults) s = s + pkDumpNode(x, withMeta) + ";"; return s; }
	if (kind === NodeKind.DoWhileStmt) { const d = n.data as DoWhileStmtData; return s + `do=(${pkDumpNode(d.doBody, withMeta)}${pkDumpNode(d.doCondition, withMeta)})`; }
	if (kind === NodeKind.SwitchStmt) { const d = n.data as SwitchStmtData; s = s + `sw=${pkDumpNode(d.switchDisc, withMeta)}cases=`; for (const c of d.switchCases) s = s + pkDumpNode(c, withMeta) + ";"; return s; }
	if (kind === NodeKind.SwitchCase) { const d = n.data as SwitchCaseData; s = s + `swc=${d.isDefault ? "T" : "F"}t=`; for (const t of d.caseTests) s = s + pkDumpNode(t, withMeta) + ";"; s = s + "s="; for (const x of d.caseStmts) s = s + pkDumpNode(x, withMeta) + ";"; return s; }
	if (kind === NodeKind.UnreachableStmt) { const d = n.data as UnreachableStmtData; return s + `unr=${d.unreachableMsg}`; }
	if (kind === NodeKind.MatchStmt) { const d = n.data as MatchStmtData; s = s + `msw=${pkDumpNode(d.matchStmtDisc, withMeta)}cases=`; for (const c of d.matchStmtCases) s = s + pkDumpNode(c, withMeta) + ";"; return s; }
	if (kind === NodeKind.ImportDecl) { const d = n.data as ImportDeclData; s = s + `imp=${d.importNames.join("|")}:${d.importAliases.join("|")}:${d.importSource}locs=`; if (d.nameLocations !== null && d.nameLocations.length > 0) { for (const l of d.nameLocations) s = s + pkDumpLoc(l) + ";"; } else { s = s + "null"; } return s; }
	if (kind === NodeKind.ExportDecl) { const d = n.data as ExportDeclData; return s + `exp=${pkDumpNode(d.exportedDecl, withMeta)}`; }
	if (kind === NodeKind.TypeAliasDecl) { const d = n.data as TypeAliasDeclData; return s + `ta=${d.aliasName}:${d.aliasType}:${d.aliasIsDistinct ? "T" : "F"}:${d.aliasGenericParams}:${d.discriminantName}:${d.discriminantType}:${d.variantKeys.join("|")}:${d.variantTypes.join("|")}:${pkDumpLoc(d.nameLocation)}`; }
	if (kind === NodeKind.EnumDecl) { const d = n.data as EnumDeclData; s = s + `en=${d.enumName}:${d.enumMembers.join("|")}vals=`; for (const v of d.enumValues) s = s + `${v};`; s = s + `:${pkDumpLoc(d.nameLocation)}mlocs=`; if (d.memberLocations !== null) { for (const l of d.memberLocations) s = s + pkDumpLoc(l) + ";"; } else { s = s + "null"; } return s; }
	if (kind === NodeKind.InterfaceDecl || kind === NodeKind.StructDecl) { const d = n.data as InterfaceDeclData; return s + `iface=${d.interfaceName}:${d.interfaceFields.join("|")}:${d.interfaceFieldTypes.join("|")}:${d.interfaceExtends.join("|")}:${pkDumpLoc(d.nameLocation)}`; }
	if (kind === NodeKind.ClassDecl) { const d = n.data as ClassDeclData; s = s + `cls=${d.className}:${d.classExtends}:${pkDumpLoc(d.nameLocation)}body=`; for (const m of d.classBody) s = s + pkDumpNode(m, withMeta) + ";"; return s; }
	if (kind === NodeKind.PropertyDecl) { const d = n.data as PropertyDeclData; return s + `prop=${d.propName}:${d.propType}:${d.propIsStatic ? "T" : "F"}:${d.propIsReadonly ? "T" : "F"}:${d.propVisibility}:${pkDumpNode(d.propInitializer, withMeta)}`; }
	if (kind === NodeKind.MethodDecl) { const d = n.data as MethodDeclData; s = s + `meth=${d.methodName}:${d.methodParams.join("|")}:${d.methodParamTypes.join("|")}:${d.methodIsStatic ? "T" : "F"}:${d.methodFlags}:${d.methodVisibility}:${d.methodReturnType}:${d.nativeName}:${pkDumpLoc(d.nameLocation)}body=${pkDumpNode(d.methodBody, withMeta)}defs=`; for (const x of d.methodDefaults) s = s + pkDumpNode(x, withMeta) + ";"; return s; }
	if (kind === NodeKind.ConstructorDecl) { const d = n.data as ConstructorDeclData; s = s + `ctor=${d.ctorParams.join("|")}:${d.ctorParamTypes.join("|")}body=${pkDumpNode(d.ctorBody, withMeta)}defs=`; for (const x of d.ctorDefaults) s = s + pkDumpNode(x, withMeta) + ";"; return s; }
	if (kind === NodeKind.ThrowStmt) { const d = n.data as ThrowStmtData; return s + `throw=${pkDumpNode(d.throwArg, withMeta)}`; }
	if (kind === NodeKind.TryCatchStmt) { const d = n.data as TryCatchStmtData; return s + `tc=${pkDumpNode(d.tryBody, withMeta)}:${d.catchName}:${pkDumpNode(d.catchBody, withMeta)}:${pkDumpNode(d.finallyBody, withMeta)}:${pkDumpLoc(d.catchBindingLocation)}:${d.hasCatchClause ? "T" : "F"}`; }
	if (kind === NodeKind.MacroInvocation) { const d = n.data as MacroInvocationData; s = s + `mi=${d.macroName}args=`; for (const x of d.macroArgs) s = s + pkDumpNode(x, withMeta) + ";"; return s; }
	if (kind === NodeKind.DecoratedDecl) { const d = n.data as DecoratedDeclData; s = s + `dec=`; for (const x of d.decorators) s = s + pkDumpNode(x, withMeta) + ";"; return s + `>${pkDumpNode(d.decoratedNode, withMeta)}`; }
	if (kind === NodeKind.DeferStmt) { const d = n.data as DeferStmtData; return s + `defer=${pkDumpNode(d.deferExpr, withMeta)}`; }
	if (kind === NodeKind.TestDecl) { const d = n.data as TestDeclData; return s + `test=${d.testName}:${pkDumpNode(d.testBody, withMeta)}`; }
	if (kind === NodeKind.AssertStmt) { const d = n.data as AssertStmtData; return s + `assert=${pkDumpNode(d.assertExpr, withMeta)}:${d.assertSource}:${d.assertMessage}:${pkDumpNode(d.assertMessageExpr, withMeta)}`; }
	if (kind === NodeKind.ExternDecl) { const d = n.data as ExternDeclData; return s + `ext=${d.externKind as int32}:${d.externName}:${d.nativeName}:${d.externType}`; }
	if (kind === NodeKind.MacroDecl) { const d = n.data as MacroDeclData; return s + `mdecl=${d.macroDeclName}:${d.macroDeclParams.join("|")}:${d.macroDeclParamTypes.join("|")}:${d.macroDeclReturnType}:${pkDumpNode(d.macroDeclBody, withMeta)}`; }
	if (kind === NodeKind.QuoteExpr) { const d = n.data as QuoteExprData; return s + `quote=${pkDumpNode(d.quoteBody, withMeta)}`; }
	if (kind === NodeKind.ComptimeBlock) { const d = n.data as ComptimeBlockData; return s + `cp=${pkDumpNode(d.comptimeBody, withMeta)}`; }
	if (kind === NodeKind.SizeofExpr) { const d = n.data as SizeofExprData; return s + `sizeof=${d.sizeofType}`; }
	if (kind === NodeKind.TypeGeneric) { const d = n.data as TypeGenericData; s = s + `tg=${pkDumpNode(d.typExprBase, withMeta)}args=`; for (const x of d.typExprArgs) s = s + pkDumpNode(x, withMeta) + ";"; return s; }
	if (kind === NodeKind.TypeArray) { const d = n.data as TypeArrayData; return s + `tarr=${pkDumpNode(d.typExprElement, withMeta)}:${d.typExprSize}`; }
	if (kind === NodeKind.TypeUnion) { const d = n.data as TypeUnionData; s = s + `tu=${d.discFieldName}:${d.discKind}:${d.variantKeys.join("|")}members=`; for (const x of d.typExprMembers) s = s + pkDumpNode(x, withMeta) + ";"; return s; }
	if (kind === NodeKind.TypeIntersection) { const d = n.data as TypeIntersectionData; s = s + "ti="; for (const x of d.typExprMembers) s = s + pkDumpNode(x, withMeta) + ";"; return s; }
	if (kind === NodeKind.TypeFunction) { const d = n.data as TypeFunctionData; s = s + `tf=${d.typExprParamNames.join("|")}ret=${pkDumpNode(d.typExprReturn, withMeta)}params=`; for (const x of d.typExprParams) s = s + pkDumpNode(x, withMeta) + ";"; return s; }
	if (kind === NodeKind.TypeObject) { const d = n.data as TypeObjectData; s = s + `to=${d.typExprFieldNames.join("|")}:${d.typExprTypeName}ik=${pkDumpNode(d.typExprIndexKey, withMeta)}iv=${pkDumpNode(d.typExprIndexValue, withMeta)}fts=`; for (const x of d.typExprFieldTypes) s = s + pkDumpNode(x, withMeta) + ";"; s = s + "decs="; if (d.typExprFieldDecorators !== null) { for (const row of d.typExprFieldDecorators) { for (const x of row) s = s + pkDumpNode(x, withMeta) + ","; s = s + ";"; } } return s; }
	if (kind === NodeKind.Program) { const d = n.data as ProgramData; s = s + "prog="; for (const x of d.programStmts) s = s + pkDumpNode(x, withMeta) + ";"; return s; }
	if (kind === NodeKind.ActorDecl) { const d = n.data as ActorDeclData; s = s + `actor=${d.actorName}:${pkDumpLoc(d.nameLocation)}body=`; for (const x of d.actorBody) s = s + pkDumpNode(x, withMeta) + ";"; return s; }
	if (kind === NodeKind.SpliceMany) { const d = n.data as SpliceManyData; s = s + "spl="; for (const x of d.spliceNodes) s = s + pkDumpNode(x, withMeta) + ";"; return s; }
	if (kind === NodeKind.JSXElement) { const d = n.data as JSXElementData; s = s + `jxe=${d.jsxTag}:${d.jsxSelfClosing ? "T" : "F"}attrs=`; for (const x of d.jsxAttrs) s = s + pkDumpNode(x, withMeta) + ";"; s = s + "kids="; for (const x of d.jsxChildren) s = s + pkDumpNode(x, withMeta) + ";"; return s; }
	if (kind === NodeKind.JSXFragment) { const d = n.data as JSXFragmentData; s = s + "jxf="; for (const x of d.jsxFragChildren) s = s + pkDumpNode(x, withMeta) + ";"; return s; }
	if (kind === NodeKind.JSXText) { const d = n.data as JSXTextData; return s + `jxt=${d.jsxText}`; }
	if (kind === NodeKind.JSXExpressionContainer) { const d = n.data as JSXExpressionContainerData; return s + `jxc=${pkDumpNode(d.jsxExpr, withMeta)}`; }
	if (kind === NodeKind.JSXAttribute) { const d = n.data as JSXAttributeData; return s + `jxa=${d.jsxAttrName}:${pkDumpNode(d.jsxAttrValue, withMeta)}`; }
	if (kind === NodeKind.JSXSpreadAttribute) { const d = n.data as JSXSpreadAttributeData; return s + `jxs=${pkDumpNode(d.jsxSpreadArg, withMeta)}`; }
	return s + "unknown";
}

// ===== Kind labels =====
// Pure data for the generic AST printer (ast/printer.ms) — the enum member
// names verbatim. No logic; an unknown value prints as Kind<N>.

export function nodeKindName(kind: NodeKind): string {
	return match (kind) {
		NodeKind.NumberLiteral => "NumberLiteral",
		NodeKind.StringLiteral => "StringLiteral",
		NodeKind.BooleanLiteral => "BooleanLiteral",
		NodeKind.NullLiteral => "NullLiteral",
		NodeKind.BigIntLiteral => "BigIntLiteral",
		NodeKind.RegexLiteral => "RegexLiteral",
		NodeKind.Identifier => "Identifier",
		NodeKind.BinaryExpr => "BinaryExpr",
		NodeKind.UnaryExpr => "UnaryExpr",
		NodeKind.UpdateExpr => "UpdateExpr",
		NodeKind.CallExpr => "CallExpr",
		NodeKind.MemberExpr => "MemberExpr",
		NodeKind.ArrayAccess => "ArrayAccess",
		NodeKind.ObjectLiteral => "ObjectLiteral",
		NodeKind.ArrayLiteral => "ArrayLiteral",
		NodeKind.ArrowFunction => "ArrowFunction",
		NodeKind.FunctionExpr => "FunctionExpr",
		NodeKind.TypeAssertion => "TypeAssertion",
		NodeKind.ConditionalExpr => "ConditionalExpr",
		NodeKind.SpreadExpr => "SpreadExpr",
		NodeKind.NewExpr => "NewExpr",
		NodeKind.TryExpr => "TryExpr",
		NodeKind.MatchExpr => "MatchExpr",
		NodeKind.MatchCase => "MatchCase",
		NodeKind.AwaitExpr => "AwaitExpr",
		NodeKind.YieldExpr => "YieldExpr",
		NodeKind.MoveExpr => "MoveExpr",
		NodeKind.OutExpr => "OutExpr",
		NodeKind.HiddenDeref => "HiddenDeref",
		NodeKind.HiddenAddr => "HiddenAddr",
		NodeKind.HiddenStdConv => "HiddenStdConv",
		NodeKind.HiddenSubConv => "HiddenSubConv",
		NodeKind.TypeAnnotation => "TypeAnnotation",
		NodeKind.ArrayPattern => "ArrayPattern",
		NodeKind.ObjectPattern => "ObjectPattern",
		NodeKind.ObjectPatternProp => "ObjectPatternProp",
		NodeKind.DestructuringDecl => "DestructuringDecl",
		NodeKind.VariableDecl => "VariableDecl",
		NodeKind.IfStmt => "IfStmt",
		NodeKind.WhileStmt => "WhileStmt",
		NodeKind.ForStmt => "ForStmt",
		NodeKind.ForOfStmt => "ForOfStmt",
		NodeKind.ForInStmt => "ForInStmt",
		NodeKind.BlockStmt => "BlockStmt",
		NodeKind.ExprStmt => "ExprStmt",
		NodeKind.ReturnStmt => "ReturnStmt",
		NodeKind.BreakStmt => "BreakStmt",
		NodeKind.ContinueStmt => "ContinueStmt",
		NodeKind.FunctionDecl => "FunctionDecl",
		NodeKind.DoWhileStmt => "DoWhileStmt",
		NodeKind.SwitchStmt => "SwitchStmt",
		NodeKind.SwitchCase => "SwitchCase",
		NodeKind.UnreachableStmt => "UnreachableStmt",
		NodeKind.MatchStmt => "MatchStmt",
		NodeKind.ImportDecl => "ImportDecl",
		NodeKind.ExportDecl => "ExportDecl",
		NodeKind.TypeAliasDecl => "TypeAliasDecl",
		NodeKind.EnumDecl => "EnumDecl",
		NodeKind.InterfaceDecl => "InterfaceDecl",
		NodeKind.StructDecl => "StructDecl",
		NodeKind.ClassDecl => "ClassDecl",
		NodeKind.PropertyDecl => "PropertyDecl",
		NodeKind.MethodDecl => "MethodDecl",
		NodeKind.ConstructorDecl => "ConstructorDecl",
		NodeKind.ThrowStmt => "ThrowStmt",
		NodeKind.TryCatchStmt => "TryCatchStmt",
		NodeKind.MacroInvocation => "MacroInvocation",
		NodeKind.DecoratedDecl => "DecoratedDecl",
		NodeKind.DeferStmt => "DeferStmt",
		NodeKind.TestDecl => "TestDecl",
		NodeKind.AssertStmt => "AssertStmt",
		NodeKind.ExternDecl => "ExternDecl",
		NodeKind.MacroDecl => "MacroDecl",
		NodeKind.QuoteExpr => "QuoteExpr",
		NodeKind.ComptimeBlock => "ComptimeBlock",
		NodeKind.SizeofExpr => "SizeofExpr",
		NodeKind.TypeGeneric => "TypeGeneric",
		NodeKind.TypeArray => "TypeArray",
		NodeKind.TypeUnion => "TypeUnion",
		NodeKind.TypeFunction => "TypeFunction",
		NodeKind.TypeObject => "TypeObject",
		NodeKind.Program => "Program",
		NodeKind.ActorDecl => "ActorDecl",
		NodeKind.SpliceMany => "SpliceMany",
		NodeKind.TypeIntersection => "TypeIntersection",
		NodeKind.JSXElement => "JSXElement",
		NodeKind.JSXFragment => "JSXFragment",
		NodeKind.JSXText => "JSXText",
		NodeKind.JSXExpressionContainer => "JSXExpressionContainer",
		NodeKind.JSXAttribute => "JSXAttribute",
		NodeKind.JSXSpreadAttribute => "JSXSpreadAttribute",
		_ => `Kind${kind as int32}`,
	};
}
