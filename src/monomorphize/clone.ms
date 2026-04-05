// Monomorphization clone/substitute utilities — shared by collect + instantiate.
//
// These three functions (monoCloneNode, monoSubstAnnotation, monoConcreteTypeName)
// are pure helpers with no dependency on the collect pass's own state. They
// live here so both the checker's on-demand instantiation path
// (src/checker/instantiate.ms) and the monomorphize collect pass
// (src/monomorphize/collect.ms) can use them without a circular import.

import { Node, NodeKind, NodeData, makeLoc, createNodeAt, BlockStmtData, IfStmtData, WhileStmtData, ForStmtData, ForOfStmtData, ForInStmtData, DoWhileStmtData, SwitchStmtData, SwitchCaseData, FunctionDeclData, ArrowFunctionData, FunctionExprData, ClassDeclData, MethodDeclData, ConstructorDeclData, ExportDeclData, DecoratedDeclData, MacroDeclData, VariableDeclData, ReturnStmtData, ThrowStmtData, ExprStmtData, TryCatchStmtData, DeferStmtData, BinaryExprData, UnaryExprData, UpdateExprData, CallExprData, MemberExprData, ArrayAccessData, ObjectLiteralData, ArrayLiteralData, ConditionalExprData, SpreadExprData, NewExprData, TryExprData, MatchExprData, MatchStmtData, MatchCaseData, AwaitExprData, YieldExprData, MoveExprData, OutExprData, SizeofExprData, TypeAssertionData, DestructuringDeclData, QuoteExprData, MacroInvocationData, IdentifierData, NumberLiteralData, StringLiteralData, BooleanLiteralData, ImportDeclData, TypeAliasDeclData, EnumDeclData, InterfaceDeclData, PropertyDeclData, ExternDeclData, TypeAnnotationData, BreakStmtData, ContinueStmtData, UnreachableStmtData, BigIntLiteralData, RegexLiteralData, HiddenStdConvData, ProgramData, Type, TypeKind } from "../ast/node";
import { isResult, getResultOkType, getResultErrType } from "../checker/types";

// ===== Clone — deep AST copy =====

function cloneNodeArray(nodes: Node[]): Node[] {
	const result: Node[] = [];
	for (const n of nodes) { result.push(monoCloneNode(n)); }
	return result;
}

function cloneStringArray(strs: string[]): string[] {
	const result: string[] = [];
	for (const s of strs) { result.push(s); }
	return result;
}

// Copy node-level metadata from source to clone (copyTree parity: preserves typ, flags).
// nodeType and flags survive cloning so downstream passes have type info.
// resolvedSym is NOT copied — monomorphize relies on name rewriting (not sym refs),
// and on-demand instantiation re-resolves via checkFunctionBody + shared IdentCache.
// Copying resolvedSym would cause monomorphized functions to use the generic symbol's
// name in mangledFunctionName instead of the rewritten mangled name.
//
// Invariant: typeExpr / typeExprs are intentionally NOT copied. They are an
// LSP-only side channel carrying positioned type-annotation AST for
// hover/goto-def. The compile path uses the string-form type annotations
// (declType, fnReturnType, etc.) which ARE inside NodeData and therefore
// cloned by monoCloneNode. Dropping typeExpr on monomorphized clones is
// correct: the original generic symbol carries positions; instantiated
// clones don't need them for code generation.
function copyNodeMeta(src: Node, dst: Node): Node {
	dst.nodeType = src.nodeType;
	dst.flags = src.flags;
	return dst;
}

export function monoCloneNode(node: Node): Node {
	if (node === null) return null as unknown as Node;
	const loc = makeLoc(node.location.line, node.location.column);
	const kind = node.kind;

	if (kind === NodeKind.NumberLiteral) { const d = node.data as NumberLiteralData; const data: NodeData = { value: d.value, isFloat: d.isFloat }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.StringLiteral) { const d = node.data as StringLiteralData; return copyNodeMeta(node, createNodeAt(kind, { value: d.value } as NodeData, loc)); }
	if (kind === NodeKind.BooleanLiteral) { const d = node.data as BooleanLiteralData; const data: NodeData = { boolValue: d.boolValue }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.NullLiteral) { const data: NodeData = { nullPlaceholder: true }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.BigIntLiteral) { const d = node.data as BigIntLiteralData; const data: NodeData = { bigintValue: d.bigintValue }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.RegexLiteral) { const d = node.data as RegexLiteralData; const data: NodeData = { regexPattern: d.regexPattern }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.Identifier) { const d = node.data as IdentifierData; const data: NodeData = { name: d.name }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.BinaryExpr) { const d = node.data as BinaryExprData; const data: NodeData = { operator: d.operator, left: monoCloneNode(d.left), right: monoCloneNode(d.right) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.UnaryExpr) { const d = node.data as UnaryExprData; const data: NodeData = { unaryOp: d.unaryOp, operand: monoCloneNode(d.operand) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.UpdateExpr) { const d = node.data as UpdateExprData; const data: NodeData = { updateOp: d.updateOp, updateArg: monoCloneNode(d.updateArg), isPrefix: d.isPrefix }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.CallExpr) { const d = node.data as CallExprData; const data: NodeData = { callee: monoCloneNode(d.callee), arguments: cloneNodeArray(d.arguments), isDirectCall: d.isDirectCall, resolvedOverloadIdx: d.resolvedOverloadIdx }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.MemberExpr) { const d = node.data as MemberExprData; const data: NodeData = { object: monoCloneNode(d.object), property: d.property, isOptional: d.isOptional }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ArrayAccess) { const d = node.data as ArrayAccessData; const data: NodeData = { array: monoCloneNode(d.array), index: monoCloneNode(d.index) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ObjectLiteral) { const d = node.data as ObjectLiteralData; const data: NodeData = { properties: cloneNodeArray(d.properties), keys: cloneStringArray(d.keys), keyLocations: d.keyLocations !== null ? d.keyLocations : [] }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ArrayLiteral) { const d = node.data as ArrayLiteralData; const data: NodeData = { elements: cloneNodeArray(d.elements) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ArrowFunction) { const d = node.data as ArrowFunctionData; const data: NodeData = { arrowParams: cloneStringArray(d.arrowParams), arrowParamTypes: cloneStringArray(d.arrowParamTypes), arrowBody: monoCloneNode(d.arrowBody), arrowFlags: d.arrowFlags, arrowReturnType: d.arrowReturnType }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.FunctionExpr) { const d = node.data as FunctionExprData; const data: NodeData = { funcExprParams: cloneStringArray(d.funcExprParams), funcExprParamTypes: cloneStringArray(d.funcExprParamTypes), funcExprBody: monoCloneNode(d.funcExprBody), funcExprFlags: d.funcExprFlags, funcExprReturnType: d.funcExprReturnType }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.TypeAssertion) { const d = node.data as TypeAssertionData; const data: NodeData = { asExpr: monoCloneNode(d.asExpr), asType: d.asType }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ConditionalExpr) { const d = node.data as ConditionalExprData; const data: NodeData = { ternaryCondition: monoCloneNode(d.ternaryCondition), ternaryConsequent: monoCloneNode(d.ternaryConsequent), ternaryAlternate: monoCloneNode(d.ternaryAlternate) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.SpreadExpr) { const d = node.data as SpreadExprData; const data: NodeData = { spreadArg: monoCloneNode(d.spreadArg) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.NewExpr) { const d = node.data as NewExprData; const data: NodeData = { newCallee: monoCloneNode(d.newCallee), newArguments: cloneNodeArray(d.newArguments) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.TryExpr) { const d = node.data as TryExprData; const data: NodeData = { tryArg: monoCloneNode(d.tryArg), hasCatch: d.hasCatch, catchVal: d.hasCatch ? monoCloneNode(d.catchVal) : null as unknown as Node }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.MatchExpr) { const d = node.data as MatchExprData; const data: NodeData = { matchDisc: monoCloneNode(d.matchDisc), matchCases: cloneNodeArray(d.matchCases) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.MatchCase) { const d = node.data as MatchCaseData; const data: NodeData = { casePatterns: cloneNodeArray(d.casePatterns), caseBody: monoCloneNode(d.caseBody) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.AwaitExpr) { const d = node.data as AwaitExprData; const data: NodeData = { awaitArg: monoCloneNode(d.awaitArg) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.YieldExpr) { const d = node.data as YieldExprData; const data: NodeData = { yieldArg: monoCloneNode(d.yieldArg), isDelegate: d.isDelegate }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.MoveExpr) { const d = node.data as MoveExprData; const data: NodeData = { moveArg: monoCloneNode(d.moveArg) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.OutExpr) { const d = node.data as OutExprData; const data: NodeData = { outArg: monoCloneNode(d.outArg) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.SizeofExpr) { const d = node.data as SizeofExprData; const data: NodeData = { sizeofType: d.sizeofType }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.HiddenDeref || kind === NodeKind.HiddenAddr) { const d = node.data as ExprStmtData; const data: NodeData = { expr: monoCloneNode(d.expr) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.HiddenStdConv || kind === NodeKind.HiddenSubConv) { const d = node.data as HiddenStdConvData; const data: NodeData = { convExpr: monoCloneNode(d.convExpr), convType: d.convType }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.TypeAnnotation) { const d = node.data as TypeAnnotationData; const data: NodeData = { annotationType: d.annotationType }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.DestructuringDecl) { const d = node.data as DestructuringDeclData; const data: NodeData = { destrPattern: monoCloneNode(d.destrPattern), destrInit: monoCloneNode(d.destrInit), destrIsConst: d.destrIsConst }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.VariableDecl) { const d = node.data as VariableDeclData; const data: NodeData = { declName: d.declName, declType: d.declType, initializer: monoCloneNode(d.initializer), declKind: d.declKind, nameLocation: d.nameLocation }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.IfStmt) { const d = node.data as IfStmtData; const data: NodeData = { condition: monoCloneNode(d.condition), consequent: monoCloneNode(d.consequent), alternate: monoCloneNode(d.alternate) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.WhileStmt) { const d = node.data as WhileStmtData; const data: NodeData = { whileCondition: monoCloneNode(d.whileCondition), whileBody: monoCloneNode(d.whileBody) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ForStmt) { const d = node.data as ForStmtData; const data: NodeData = { forInit: monoCloneNode(d.forInit), forCondition: monoCloneNode(d.forCondition), forUpdate: monoCloneNode(d.forUpdate), forBody: monoCloneNode(d.forBody) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ForOfStmt) { const d = node.data as ForOfStmtData; const data: NodeData = { forOfBinding: d.forOfBinding, forOfIsConst: d.forOfIsConst, forOfIterable: monoCloneNode(d.forOfIterable), forOfBody: monoCloneNode(d.forOfBody), forOfPattern: d.forOfPattern !== null ? monoCloneNode(d.forOfPattern) : null as unknown as Node, bindingLocation: d.bindingLocation }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ForInStmt) { const d = node.data as ForInStmtData; const data: NodeData = { forInBinding: d.forInBinding, forInIsConst: d.forInIsConst, forInObject: monoCloneNode(d.forInObject), forInBody: monoCloneNode(d.forInBody) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.DoWhileStmt) { const d = node.data as DoWhileStmtData; const data: NodeData = { doBody: monoCloneNode(d.doBody), doCondition: monoCloneNode(d.doCondition) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.BlockStmt) { const d = node.data as BlockStmtData; const data: NodeData = { statements: cloneNodeArray(d.statements) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ExprStmt) { const d = node.data as ExprStmtData; const data: NodeData = { expr: monoCloneNode(d.expr) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ReturnStmt) { const d = node.data as ReturnStmtData; const data: NodeData = { argument: monoCloneNode(d.argument) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.BreakStmt) { const d = node.data as BreakStmtData; const data: NodeData = { breakLabel: d.breakLabel }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ContinueStmt) { const d = node.data as ContinueStmtData; const data: NodeData = { continueLabel: d.continueLabel }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.UnreachableStmt) { const d = node.data as UnreachableStmtData; const data: NodeData = { unreachableMsg: d.unreachableMsg }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.FunctionDecl) { const d = node.data as FunctionDeclData; const data: NodeData = { fnName: d.fnName, params: cloneStringArray(d.params), fnParamTypes: cloneStringArray(d.fnParamTypes), fnBody: monoCloneNode(d.fnBody), fnFlags: d.fnFlags, fnReturnType: d.fnReturnType, fnDefaults: cloneNodeArray(d.fnDefaults), nameLocation: d.nameLocation }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.SwitchStmt) { const d = node.data as SwitchStmtData; const data: NodeData = { switchDisc: monoCloneNode(d.switchDisc), switchCases: cloneNodeArray(d.switchCases) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.SwitchCase) { const d = node.data as SwitchCaseData; const data: NodeData = { caseTests: cloneNodeArray(d.caseTests), caseStmts: cloneNodeArray(d.caseStmts), isDefault: d.isDefault }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.MatchStmt) { const d = node.data as MatchStmtData; const data: NodeData = { matchStmtDisc: monoCloneNode(d.matchStmtDisc), matchStmtCases: cloneNodeArray(d.matchStmtCases) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ImportDecl) { const d = node.data as ImportDeclData; const data: NodeData = { importNames: cloneStringArray(d.importNames), importAliases: cloneStringArray(d.importAliases), importSource: d.importSource, nameLocations: d.nameLocations !== null ? d.nameLocations : [] }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ExportDecl) { const d = node.data as ExportDeclData; const data: NodeData = { exportedDecl: monoCloneNode(d.exportedDecl) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.TypeAliasDecl) { const d = node.data as TypeAliasDeclData; const data: NodeData = { aliasName: d.aliasName, aliasType: d.aliasType, aliasIsDistinct: d.aliasIsDistinct, discriminantName: d.discriminantName, discriminantType: d.discriminantType, variantKeys: cloneStringArray(d.variantKeys), variantTypes: cloneStringArray(d.variantTypes), nameLocation: d.nameLocation }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.EnumDecl) { const d = node.data as EnumDeclData; const data: NodeData = { enumName: d.enumName, enumMembers: cloneStringArray(d.enumMembers), nameLocation: d.nameLocation, memberLocations: d.memberLocations !== null ? d.memberLocations : [] }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.InterfaceDecl) { const d = node.data as InterfaceDeclData; const data: NodeData = { interfaceName: d.interfaceName, interfaceFields: cloneStringArray(d.interfaceFields), interfaceFieldTypes: cloneStringArray(d.interfaceFieldTypes), nameLocation: d.nameLocation }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.StructDecl) { const d = node.data as InterfaceDeclData; const data: NodeData = { interfaceName: d.interfaceName, interfaceFields: cloneStringArray(d.interfaceFields), interfaceFieldTypes: cloneStringArray(d.interfaceFieldTypes), nameLocation: d.nameLocation }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ClassDecl) { const d = node.data as ClassDeclData; const data: NodeData = { className: d.className, classExtends: d.classExtends, classBody: cloneNodeArray(d.classBody), nameLocation: d.nameLocation }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.PropertyDecl) { const d = node.data as PropertyDeclData; const data: NodeData = { propName: d.propName, propType: d.propType, propIsStatic: d.propIsStatic, propInitializer: d.propInitializer }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.MethodDecl) { const d = node.data as MethodDeclData; const data: NodeData = { methodName: d.methodName, methodParams: cloneStringArray(d.methodParams), methodParamTypes: cloneStringArray(d.methodParamTypes), methodBody: monoCloneNode(d.methodBody), methodIsStatic: d.methodIsStatic, methodFlags: d.methodFlags, methodReturnType: d.methodReturnType, nameLocation: d.nameLocation }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ConstructorDecl) { const d = node.data as ConstructorDeclData; const data: NodeData = { ctorParams: cloneStringArray(d.ctorParams), ctorParamTypes: cloneStringArray(d.ctorParamTypes), ctorBody: monoCloneNode(d.ctorBody) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ThrowStmt) { const d = node.data as ThrowStmtData; const data: NodeData = { throwArg: monoCloneNode(d.throwArg) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.TryCatchStmt) { const d = node.data as TryCatchStmtData; const data: NodeData = { tryBody: monoCloneNode(d.tryBody), catchName: d.catchName, catchBody: monoCloneNode(d.catchBody), finallyBody: monoCloneNode(d.finallyBody), catchBindingLocation: d.catchBindingLocation }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.MacroInvocation) { const d = node.data as MacroInvocationData; const data: NodeData = { macroName: d.macroName, macroArgs: cloneNodeArray(d.macroArgs) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.DecoratedDecl) { const d = node.data as DecoratedDeclData; const data: NodeData = { decorators: cloneNodeArray(d.decorators), decoratedNode: monoCloneNode(d.decoratedNode) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.DeferStmt) { const d = node.data as DeferStmtData; const data: NodeData = { deferExpr: monoCloneNode(d.deferExpr) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.ExternDecl) { const d = node.data as ExternDeclData; const data: NodeData = { externKind: d.externKind, externName: d.externName, nativeName: d.nativeName, externType: d.externType }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.MacroDecl) { const d = node.data as MacroDeclData; const data: NodeData = { macroDeclName: d.macroDeclName, macroDeclParams: cloneStringArray(d.macroDeclParams), macroDeclBody: monoCloneNode(d.macroDeclBody) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.QuoteExpr) { const d = node.data as QuoteExprData; const data: NodeData = { quoteBody: monoCloneNode(d.quoteBody) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	if (kind === NodeKind.Program) { const d = node.data as ProgramData; const data: NodeData = { programStmts: cloneNodeArray(d.programStmts) }; return copyNodeMeta(node, createNodeAt(kind, data, loc)); }
	return copyNodeMeta(node, createNodeAt(kind, node.data, loc));
}

// ===== Substitute — rewrite generic param names in string-form type annotations =====

function monoIsAlphaNumOrUnderscore(ch: string): boolean {
	if (ch === "_") return true;
	if (ch === "a" || ch === "b" || ch === "c" || ch === "d" || ch === "e" || ch === "f" || ch === "g" || ch === "h" || ch === "i" || ch === "j" || ch === "k" || ch === "l" || ch === "m" || ch === "n" || ch === "o" || ch === "p" || ch === "q" || ch === "r" || ch === "s" || ch === "t" || ch === "u" || ch === "v" || ch === "w" || ch === "x" || ch === "y" || ch === "z") return true;
	if (ch === "A" || ch === "B" || ch === "C" || ch === "D" || ch === "E" || ch === "F" || ch === "G" || ch === "H" || ch === "I" || ch === "J" || ch === "K" || ch === "L" || ch === "M" || ch === "N" || ch === "O" || ch === "P" || ch === "Q" || ch === "R" || ch === "S" || ch === "T" || ch === "U" || ch === "V" || ch === "W" || ch === "X" || ch === "Y" || ch === "Z") return true;
	if (ch === "0" || ch === "1" || ch === "2" || ch === "3" || ch === "4" || ch === "5" || ch === "6" || ch === "7" || ch === "8" || ch === "9") return true;
	return false;
}

export function monoSubstAnnotation(annotation: string, paramName: string, concreteTypeName: string): string {
	if (annotation === "") return "";
	if (annotation === paramName) return concreteTypeName;
	let result = "";
	let i = 0;
	while (i < annotation.byteLength) {
		let isMatch = true;
		if (i + paramName.byteLength > annotation.byteLength) { isMatch = false; } else {
			for (let pi = 0; pi < paramName.byteLength; pi += 1) { if (annotation.charAt(i + pi) !== paramName.charAt(pi)) { isMatch = false; } }
		}
		if (isMatch) {
			let prevOk = true;
			let nextOk = true;
			if (i > 0) { prevOk = !monoIsAlphaNumOrUnderscore(annotation.charAt(i - 1)); }
			const nextPos = i + paramName.byteLength;
			if (nextPos < annotation.byteLength) { nextOk = !monoIsAlphaNumOrUnderscore(annotation.charAt(nextPos)); }
			if (prevOk && nextOk) { result = result + concreteTypeName; i = i + paramName.byteLength; } else { result = result + annotation.charAt(i); i += 1; }
		} else { result = result + annotation.charAt(i); i += 1; }
	}
	return result;
}

// Type-to-string for annotation substitution (human-readable MetaScript type names).
// Used by substituteAnnotations to replace generic params in type annotations.
export function monoConcreteTypeName(t: Type): string {
	if (t === null) return "unknown";
	if (isResult(t)) return `Result<${monoConcreteTypeName(getResultOkType(t))}, ${monoConcreteTypeName(getResultErrType(t))}>`;
	return match (t.kind) {
		TypeKind.Number => "number",
		TypeKind.String => "string",
		TypeKind.Boolean => "boolean",
		TypeKind.Void => "void",
		TypeKind.Null => "null",
		TypeKind.Ref => monoConcreteTypeName(t.typeReturn),
		TypeKind.Ptr => `Ptr<${monoConcreteTypeName(t.typeReturn)}>`,
		TypeKind.Array => `Array<${monoConcreteTypeName(t.typeReturn)}>`,
		TypeKind.Struct | TypeKind.Enum => t.typeName,
		TypeKind.GenericInstance => {
			let name = t.typeName;
			let i = 0;
			while (i < t.typeChildren.length) {
				name = name + (i === 0 ? "<" : ", ") + monoConcreteTypeName(t.typeChildren[i]);
				i = i + 1;
			}
			return name + ">";
		},
		TypeKind.Union => t.typeName !== "" ? t.typeName : "Union",
		TypeKind.Function => "Function",
		TypeKind.Int8 => "int8",
		TypeKind.Int16 => "int16",
		TypeKind.Int32 => "int32",
		TypeKind.Int64 => "int64",
		TypeKind.Uint8 => "uint8",
		TypeKind.Uint16 => "uint16",
		TypeKind.Uint32 => "uint32",
		TypeKind.Uint64 => "uint64",
		TypeKind.Float32 => "float32",
		TypeKind.Float64 => "float64",
		TypeKind.Char => "char",
		TypeKind.CString => "cstring",
		_ => "unknown",
	};
}
