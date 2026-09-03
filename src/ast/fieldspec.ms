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

import { Node, NodeKind, SourceLocation, Type,
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
