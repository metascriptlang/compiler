// src/compiler/meta/bridge.ms
//
// AST Node ↔ Raiser VM RaiserValue serialization bridge.
//
// Macros run in the Raiser VM, which only knows primitives, arrays, and heap
// objects — not Node structs. This module bridges the two worlds:
//
//   nodeToValue:  Node    → RaiserValue (heap Object with named fields)
//   valueToNode:  RaiserValue → Node    (deserialize back)
//
// Used by:
//   - src/compiler/comptime.ms — @comptime block evaluation
//   - src/compiler/meta/expand.ms — (future) macro expansion pass
//
// Macro authors never call these directly. The compiler invokes them at the
// VM boundary when serializing macro inputs and deserializing macro outputs.
//
// Why serialize at all? The Raiser VM is intentionally DRC-free with its own
// memory model. Adding a NodeRef variant to RaiserValue would force lifetime
// tracking through the VM heaps. Serialization keeps the VM pure.

import {
	Node, NodeKind, SourceLocation, makeLoc, createNode, createNodeAt, DeclKind, ExternKind,
	// Literals
	NumberLiteralData, StringLiteralData, BooleanLiteralData,
	BigIntLiteralData, RegexLiteralData,
	// Expressions
	IdentifierData, BinaryExprData, UnaryExprData, UpdateExprData,
	CallExprData, MemberExprData, ArrayAccessData,
	ObjectLiteralData, ArrayLiteralData,
	ArrowFunctionData, FunctionExprData, TypeAssertionData,
	ConditionalExprData, SpreadExprData, NewExprData,
	TryExprData, MatchExprData, MatchCaseData,
	AwaitExprData, YieldExprData, MoveExprData, OutExprData, SizeofExprData,
	HiddenDerefData, QuoteExprData, ComptimeBlockData,
	// Patterns
	ArrayPatternData, ObjectPatternData, ObjectPatternPropData, DestructuringDeclData,
	// Statements
	ExprStmtData, ReturnStmtData, ThrowStmtData, DeferStmtData,
	VariableDeclData, IfStmtData, WhileStmtData, DoWhileStmtData,
	ForStmtData, ForOfStmtData, ForInStmtData,
	BlockStmtData, FunctionDeclData,
	SwitchStmtData, SwitchCaseData, MatchStmtData,
	TryCatchStmtData, BreakStmtData, ContinueStmtData, UnreachableStmtData,
	TestDeclData, AssertStmtData,
	// Declarations
	ImportDeclData, ExportDeclData, TypeAliasDeclData, EnumDeclData,
	InterfaceDeclData, ClassDeclData, ActorDeclData, PropertyDeclData,
	MethodDeclData, ConstructorDeclData,
	ExternDeclData, MacroDeclData, DecoratedDeclData,
	MacroInvocationData, TypeAnnotationData,
	ProgramData,
} from "../../ast/node";
import { Token, TokenKind, createToken } from "../../lexer/token";
import {
	RaiserValueKind, RaiserValue,
	RaiserObjectHeap, RaiserArrayHeap,
	heapArrayGet, heapArrayLen, raiserInt, raiserFloat, raiserBool, raiserString, raiserNil, raiserObject, raiserArray,
	heapAllocObject, heapObjectSetField, heapObjectGetField, heapAllocArray, heapArrayPush,
	createStructHeap, createArrayHeap,
} from "../../raiser/value";

// ===== Synthetic location/token helpers =====

export function synthToken(loc: SourceLocation): Token {
	return createToken(TokenKind.Ident, "", loc.line);
}

export function mkNumber(val: number, loc: SourceLocation): Node {
	return createNode(NodeKind.NumberLiteral, { value: val, isFloat: val % 1 !== 0 }, synthToken(loc));
}

export function mkString(val: string, loc: SourceLocation): Node {
	return createNode(NodeKind.StringLiteral, { value: val }, synthToken(loc));
}

export function mkBool(val: boolean, loc: SourceLocation): Node {
	return createNode(NodeKind.BooleanLiteral, { boolValue: val }, synthToken(loc));
}

export function mkNull(loc: SourceLocation): Node {
	return createNode(NodeKind.NullLiteral, { nullPlaceholder: true }, synthToken(loc));
}

// ===== Serialization helpers (write to RaiserValue) =====

function serializeNodes(nodes: Node[], objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap): RaiserValue {
	const handle = heapAllocArray(arrHeap);
	for (const node of nodes) {
		const v = nodeToValue(node, objHeap, arrHeap);
		heapArrayPush(arrHeap, handle, v);
	}
	return raiserArray(handle);
}

function serializeStrings(strs: string[], arrHeap: RaiserArrayHeap): RaiserValue {
	const handle = heapAllocArray(arrHeap);
	for (const s of strs) {
		const v = raiserString(s);
		heapArrayPush(arrHeap, handle, v);
	}
	return raiserArray(handle);
}

function setStr(objHeap: RaiserObjectHeap, h: number, name: string, val: string): void {
	const v = raiserString(val);
	heapObjectSetField(objHeap, h, name, v);
}

function setBool(objHeap: RaiserObjectHeap, h: number, name: string, val: boolean): void {
	const v = raiserBool(val);
	heapObjectSetField(objHeap, h, name, v);
}

function setNode(objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap, h: number, name: string, child: Node): void {
	if (child === null) {
		// Represent null Node fields as RaiserValue.Nil — readNode handles this on the way back
		heapObjectSetField(objHeap, h, name, raiserNil());
		return;
	}
	const v = nodeToValue(child, objHeap, arrHeap);
	heapObjectSetField(objHeap, h, name, v);
}

function setNodes(objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap, h: number, name: string, children: Node[]): void {
	const v = serializeNodes(children, objHeap, arrHeap);
	heapObjectSetField(objHeap, h, name, v);
}

function setStrs(objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap, h: number, name: string, strs: string[]): void {
	const v = serializeStrings(strs, arrHeap);
	heapObjectSetField(objHeap, h, name, v);
}

// ===== nodeToValue: AST Node → RaiserValue =====
//
// MAINTENANCE: nodeToValue and readNodeFromObject (further down) are paired.
// Each NodeKind case here MUST have a matching case in readNodeFromObject that
// reads back the SAME field names. When adding/removing fields in NodeData,
// update BOTH dispatchers, or round-trip serialization will silently corrupt nodes.

export function nodeToValue(node: Node, objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap): RaiserValue {
	const handle = heapAllocObject(objHeap);
	// Common fields: kind, line, column
	const kindVal = raiserInt(node.kind as number);
	heapObjectSetField(objHeap, handle, "kind", kindVal);
	const lineVal = raiserInt(node.location.line);
	heapObjectSetField(objHeap, handle, "line", lineVal);
	const colVal = raiserInt(node.location.column);
	heapObjectSetField(objHeap, handle, "column", colVal);

	match (node.kind) {
		// === Literals ===
		NodeKind.NumberLiteral => {
			const d = node.data as NumberLiteralData;
			const v = raiserFloat(d.value);
			heapObjectSetField(objHeap, handle, "value", v);
		},
		NodeKind.StringLiteral => {
			const d = node.data as StringLiteralData;
			setStr(objHeap, handle, "value", d.value);
		},
		NodeKind.BooleanLiteral => {
			const d = node.data as BooleanLiteralData;
			setBool(objHeap, handle, "boolValue", d.boolValue);
		},
		NodeKind.NullLiteral => {},
		NodeKind.BigIntLiteral => {
			const d = node.data as BigIntLiteralData;
			setStr(objHeap, handle, "bigintValue", d.bigintValue);
		},
		NodeKind.RegexLiteral => {
			const d = node.data as RegexLiteralData;
			setStr(objHeap, handle, "regexPattern", d.regexPattern);
		},

		// === Identifier ===
		NodeKind.Identifier => {
			const d = node.data as IdentifierData;
			setStr(objHeap, handle, "name", d.name);
		},

		// === Binary/Unary/Update ===
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			setStr(objHeap, handle, "operator", d.operator);
			setNode(objHeap, arrHeap, handle, "left", d.left);
			setNode(objHeap, arrHeap, handle, "right", d.right);
		},
		NodeKind.UnaryExpr => {
			const d = node.data as UnaryExprData;
			setStr(objHeap, handle, "unaryOp", d.unaryOp);
			setNode(objHeap, arrHeap, handle, "operand", d.operand);
		},
		NodeKind.UpdateExpr => {
			const d = node.data as UpdateExprData;
			setStr(objHeap, handle, "updateOp", d.updateOp);
			setNode(objHeap, arrHeap, handle, "updateArg", d.updateArg);
			setBool(objHeap, handle, "isPrefix", d.isPrefix);
		},

		// === Call/Member/Access ===
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			setNode(objHeap, arrHeap, handle, "callee", d.callee);
			setNodes(objHeap, arrHeap, handle, "arguments", d.arguments);
		},
		NodeKind.MemberExpr => {
			const d = node.data as MemberExprData;
			setNode(objHeap, arrHeap, handle, "object", d.object);
			setStr(objHeap, handle, "property", d.property);
			setBool(objHeap, handle, "isOptional", d.isOptional);
		},
		NodeKind.ArrayAccess => {
			const d = node.data as ArrayAccessData;
			setNode(objHeap, arrHeap, handle, "array", d.array);
			setNode(objHeap, arrHeap, handle, "index", d.index);
		},

		// === Collection literals ===
		NodeKind.ObjectLiteral => {
			const d = node.data as ObjectLiteralData;
			setNodes(objHeap, arrHeap, handle, "properties", d.properties);
			setStrs(objHeap, arrHeap, handle, "keys", d.keys);
		},
		NodeKind.ArrayLiteral => {
			const d = node.data as ArrayLiteralData;
			setNodes(objHeap, arrHeap, handle, "elements", d.elements);
		},

		// === Function expressions ===
		NodeKind.ArrowFunction => {
			const d = node.data as ArrowFunctionData;
			setStrs(objHeap, arrHeap, handle, "arrowParams", d.arrowParams);
			setStrs(objHeap, arrHeap, handle, "arrowParamTypes", d.arrowParamTypes);
			setNode(objHeap, arrHeap, handle, "arrowBody", d.arrowBody);
			setStr(objHeap, handle, "arrowFlags", d.arrowFlags);
			setStr(objHeap, handle, "arrowReturnType", d.arrowReturnType);
		},
		NodeKind.FunctionExpr => {
			const d = node.data as FunctionExprData;
			setStrs(objHeap, arrHeap, handle, "funcExprParams", d.funcExprParams);
			setStrs(objHeap, arrHeap, handle, "funcExprParamTypes", d.funcExprParamTypes);
			setNode(objHeap, arrHeap, handle, "funcExprBody", d.funcExprBody);
			setStr(objHeap, handle, "funcExprFlags", d.funcExprFlags);
			setStr(objHeap, handle, "funcExprReturnType", d.funcExprReturnType);
		},

		// === Other expressions ===
		NodeKind.TypeAssertion => {
			const d = node.data as TypeAssertionData;
			setNode(objHeap, arrHeap, handle, "asExpr", d.asExpr);
			setStr(objHeap, handle, "asType", d.asType);
		},
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			setNode(objHeap, arrHeap, handle, "ternaryCondition", d.ternaryCondition);
			setNode(objHeap, arrHeap, handle, "ternaryConsequent", d.ternaryConsequent);
			setNode(objHeap, arrHeap, handle, "ternaryAlternate", d.ternaryAlternate);
		},
		NodeKind.SpreadExpr => {
			const d = node.data as SpreadExprData;
			setNode(objHeap, arrHeap, handle, "spreadArg", d.spreadArg);
		},
		NodeKind.NewExpr => {
			const d = node.data as NewExprData;
			setNode(objHeap, arrHeap, handle, "newCallee", d.newCallee);
			setNodes(objHeap, arrHeap, handle, "newArguments", d.newArguments);
		},
		NodeKind.TryExpr => {
			const d = node.data as TryExprData;
			setNode(objHeap, arrHeap, handle, "tryArg", d.tryArg);
			setBool(objHeap, handle, "hasCatch", d.hasCatch);
			if (d.hasCatch) { setNode(objHeap, arrHeap, handle, "catchVal", d.catchVal); }
		},
		NodeKind.MatchExpr => {
			const d = node.data as MatchExprData;
			setNode(objHeap, arrHeap, handle, "matchDisc", d.matchDisc);
			setNodes(objHeap, arrHeap, handle, "matchCases", d.matchCases);
		},
		NodeKind.MatchCase => {
			const d = node.data as MatchCaseData;
			setNodes(objHeap, arrHeap, handle, "casePatterns", d.casePatterns);
			setNode(objHeap, arrHeap, handle, "caseGuard", d.caseGuard);
			setNode(objHeap, arrHeap, handle, "caseBody", d.caseBody);
		},
		NodeKind.AwaitExpr => {
			const d = node.data as AwaitExprData;
			setNode(objHeap, arrHeap, handle, "awaitArg", d.awaitArg);
		},
		NodeKind.YieldExpr => {
			const d = node.data as YieldExprData;
			setNode(objHeap, arrHeap, handle, "yieldArg", d.yieldArg);
			setBool(objHeap, handle, "isDelegate", d.isDelegate);
		},
		NodeKind.MoveExpr => {
			const d = node.data as MoveExprData;
			setNode(objHeap, arrHeap, handle, "moveArg", d.moveArg);
		},
		NodeKind.OutExpr => {
			const d = node.data as OutExprData;
			setNode(objHeap, arrHeap, handle, "outArg", d.outArg);
		},
		NodeKind.SizeofExpr => {
			const d = node.data as SizeofExprData;
			setStr(objHeap, handle, "sizeofType", d.sizeofType);
		},
		NodeKind.HiddenDeref => {
			const d = node.data as HiddenDerefData;
			setNode(objHeap, arrHeap, handle, "expr", d.expr);
		},
		NodeKind.QuoteExpr => {
			const d = node.data as QuoteExprData;
			setNode(objHeap, arrHeap, handle, "quoteBody", d.quoteBody);
		},
		NodeKind.ComptimeBlock => {
			const d = node.data as ComptimeBlockData;
			setNode(objHeap, arrHeap, handle, "comptimeBody", d.comptimeBody);
		},
		NodeKind.TypeAnnotation => {
			const d = node.data as TypeAnnotationData;
			setStr(objHeap, handle, "annotationType", d.annotationType);
		},

		// === Patterns ===
		NodeKind.ArrayPattern => {
			const d = node.data as ArrayPatternData;
			setNodes(objHeap, arrHeap, handle, "patternElements", d.patternElements);
			setBool(objHeap, handle, "hasRestElement", d.hasRestElement);
		},
		NodeKind.ObjectPattern => {
			const d = node.data as ObjectPatternData;
			setNodes(objHeap, arrHeap, handle, "patternProps", d.patternProps);
			setBool(objHeap, handle, "hasRestProp", d.hasRestProp);
		},
		NodeKind.ObjectPatternProp => {
			const d = node.data as ObjectPatternPropData;
			setStr(objHeap, handle, "propKey", d.propKey);
			setNode(objHeap, arrHeap, handle, "propAlias", d.propAlias);
		},
		NodeKind.DestructuringDecl => {
			const d = node.data as DestructuringDeclData;
			setNode(objHeap, arrHeap, handle, "destrPattern", d.destrPattern);
			setNode(objHeap, arrHeap, handle, "destrInit", d.destrInit);
			setBool(objHeap, handle, "destrIsConst", d.destrIsConst);
		},

		// === Statements ===
		NodeKind.ExprStmt => {
			const d = node.data as ExprStmtData;
			setNode(objHeap, arrHeap, handle, "expr", d.expr);
		},
		NodeKind.ReturnStmt => {
			const d = node.data as ReturnStmtData;
			setNode(objHeap, arrHeap, handle, "argument", d.argument);
		},
		NodeKind.ThrowStmt => {
			const d = node.data as ThrowStmtData;
			setNode(objHeap, arrHeap, handle, "throwArg", d.throwArg);
		},
		NodeKind.DeferStmt => {
			const d = node.data as DeferStmtData;
			setNode(objHeap, arrHeap, handle, "deferExpr", d.deferExpr);
		},
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			setNodes(objHeap, arrHeap, handle, "statements", d.statements);
		},
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			setStr(objHeap, handle, "declName", d.declName);
			setStr(objHeap, handle, "declType", d.declType);
			setNode(objHeap, arrHeap, handle, "initializer", d.initializer);
			const dk = raiserInt(d.declKind as number);
			heapObjectSetField(objHeap, handle, "declKind", dk);
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			setNode(objHeap, arrHeap, handle, "condition", d.condition);
			setNode(objHeap, arrHeap, handle, "consequent", d.consequent);
			setNode(objHeap, arrHeap, handle, "alternate", d.alternate);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			setNode(objHeap, arrHeap, handle, "whileCondition", d.whileCondition);
			setNode(objHeap, arrHeap, handle, "whileBody", d.whileBody);
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			setNode(objHeap, arrHeap, handle, "doBody", d.doBody);
			setNode(objHeap, arrHeap, handle, "doCondition", d.doCondition);
		},
		NodeKind.ForStmt => {
			const d = node.data as ForStmtData;
			setNode(objHeap, arrHeap, handle, "forInit", d.forInit);
			setNode(objHeap, arrHeap, handle, "forCondition", d.forCondition);
			setNode(objHeap, arrHeap, handle, "forUpdate", d.forUpdate);
			setNode(objHeap, arrHeap, handle, "forBody", d.forBody);
		},
		NodeKind.ForOfStmt => {
			const d = node.data as ForOfStmtData;
			setStr(objHeap, handle, "forOfBinding", d.forOfBinding);
			setBool(objHeap, handle, "forOfIsConst", d.forOfIsConst);
			setNode(objHeap, arrHeap, handle, "forOfIterable", d.forOfIterable);
			setNode(objHeap, arrHeap, handle, "forOfBody", d.forOfBody);
		},
		NodeKind.ForInStmt => {
			const d = node.data as ForInStmtData;
			setStr(objHeap, handle, "forInBinding", d.forInBinding);
			setBool(objHeap, handle, "forInIsConst", d.forInIsConst);
			setNode(objHeap, arrHeap, handle, "forInObject", d.forInObject);
			setNode(objHeap, arrHeap, handle, "forInBody", d.forInBody);
		},
		NodeKind.BreakStmt => {
			const d = node.data as BreakStmtData;
			setStr(objHeap, handle, "breakLabel", d.breakLabel);
		},
		NodeKind.ContinueStmt => {
			const d = node.data as ContinueStmtData;
			setStr(objHeap, handle, "continueLabel", d.continueLabel);
		},
		NodeKind.UnreachableStmt => {
			const d = node.data as UnreachableStmtData;
			setStr(objHeap, handle, "unreachableMsg", d.unreachableMsg);
		},
		NodeKind.SwitchStmt => {
			const d = node.data as SwitchStmtData;
			setNode(objHeap, arrHeap, handle, "switchDisc", d.switchDisc);
			setNodes(objHeap, arrHeap, handle, "switchCases", d.switchCases);
		},
		NodeKind.SwitchCase => {
			const d = node.data as SwitchCaseData;
			setNodes(objHeap, arrHeap, handle, "caseTests", d.caseTests);
			setNodes(objHeap, arrHeap, handle, "caseStmts", d.caseStmts);
			setBool(objHeap, handle, "isDefault", d.isDefault);
		},
		NodeKind.MatchStmt => {
			const d = node.data as MatchStmtData;
			setNode(objHeap, arrHeap, handle, "matchStmtDisc", d.matchStmtDisc);
			setNodes(objHeap, arrHeap, handle, "matchStmtCases", d.matchStmtCases);
		},
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			setNode(objHeap, arrHeap, handle, "tryBody", d.tryBody);
			setStr(objHeap, handle, "catchName", d.catchName);
			setNode(objHeap, arrHeap, handle, "catchBody", d.catchBody);
			setNode(objHeap, arrHeap, handle, "finallyBody", d.finallyBody);
		},

		// === Declarations ===
		NodeKind.FunctionDecl => {
			const d = node.data as FunctionDeclData;
			setStr(objHeap, handle, "fnName", d.fnName);
			setStrs(objHeap, arrHeap, handle, "params", d.params);
			setStrs(objHeap, arrHeap, handle, "fnParamTypes", d.fnParamTypes);
			setNode(objHeap, arrHeap, handle, "fnBody", d.fnBody);
			setStr(objHeap, handle, "fnFlags", d.fnFlags);
			setStr(objHeap, handle, "fnReturnType", d.fnReturnType);
		},
		NodeKind.ImportDecl => {
			const d = node.data as ImportDeclData;
			setStrs(objHeap, arrHeap, handle, "importNames", d.importNames);
			setStrs(objHeap, arrHeap, handle, "importAliases", d.importAliases);
			setStr(objHeap, handle, "importSource", d.importSource);
		},
		NodeKind.ExportDecl => {
			const d = node.data as ExportDeclData;
			setNode(objHeap, arrHeap, handle, "exportedDecl", d.exportedDecl);
		},
		NodeKind.TypeAliasDecl => {
			const d = node.data as TypeAliasDeclData;
			setStr(objHeap, handle, "aliasName", d.aliasName);
			setStr(objHeap, handle, "aliasType", d.aliasType);
			setBool(objHeap, handle, "aliasIsDistinct", d.aliasIsDistinct);
		},
		NodeKind.EnumDecl => {
			const d = node.data as EnumDeclData;
			setStr(objHeap, handle, "enumName", d.enumName);
			setStrs(objHeap, arrHeap, handle, "enumMembers", d.enumMembers);
		},
		NodeKind.InterfaceDecl | NodeKind.StructDecl => {
			const d = node.data as InterfaceDeclData;
			setStr(objHeap, handle, "interfaceName", d.interfaceName);
			setStrs(objHeap, arrHeap, handle, "interfaceFields", d.interfaceFields);
			setStrs(objHeap, arrHeap, handle, "interfaceFieldTypes", d.interfaceFieldTypes);
		},
		NodeKind.ClassDecl => {
			const d = node.data as ClassDeclData;
			setStr(objHeap, handle, "className", d.className);
			setStr(objHeap, handle, "classExtends", d.classExtends);
			setNodes(objHeap, arrHeap, handle, "classBody", d.classBody);
		},
		NodeKind.ActorDecl => {
			const d = node.data as ActorDeclData;
			setStr(objHeap, handle, "actorName", d.actorName);
			setNodes(objHeap, arrHeap, handle, "actorBody", d.actorBody);
		},
		NodeKind.PropertyDecl => {
			const d = node.data as PropertyDeclData;
			setStr(objHeap, handle, "propName", d.propName);
			setStr(objHeap, handle, "propType", d.propType);
			setBool(objHeap, handle, "propIsStatic", d.propIsStatic);
		},
		NodeKind.MethodDecl => {
			const d = node.data as MethodDeclData;
			setStr(objHeap, handle, "methodName", d.methodName);
			setStrs(objHeap, arrHeap, handle, "methodParams", d.methodParams);
			setStrs(objHeap, arrHeap, handle, "methodParamTypes", d.methodParamTypes);
			setNode(objHeap, arrHeap, handle, "methodBody", d.methodBody);
			setBool(objHeap, handle, "methodIsStatic", d.methodIsStatic);
			setStr(objHeap, handle, "methodFlags", d.methodFlags);
			setStr(objHeap, handle, "methodReturnType", d.methodReturnType);
		},
		NodeKind.ConstructorDecl => {
			const d = node.data as ConstructorDeclData;
			setStrs(objHeap, arrHeap, handle, "ctorParams", d.ctorParams);
			setStrs(objHeap, arrHeap, handle, "ctorParamTypes", d.ctorParamTypes);
			setNode(objHeap, arrHeap, handle, "ctorBody", d.ctorBody);
		},
		NodeKind.ExternDecl => {
			const d = node.data as ExternDeclData;
			heapObjectSetField(objHeap, handle, "externKind", raiserInt(d.externKind as number));
			setStr(objHeap, handle, "externName", d.externName);
			setStr(objHeap, handle, "nativeName", d.nativeName);
			setStr(objHeap, handle, "externType", d.externType);
		},
		NodeKind.MacroDecl => {
			const d = node.data as MacroDeclData;
			setStr(objHeap, handle, "macroDeclName", d.macroDeclName);
			setStrs(objHeap, arrHeap, handle, "macroDeclParams", d.macroDeclParams);
			setStrs(objHeap, arrHeap, handle, "macroDeclParamTypes", d.macroDeclParamTypes);
			setNode(objHeap, arrHeap, handle, "macroDeclBody", d.macroDeclBody);
		},
		NodeKind.DecoratedDecl => {
			const d = node.data as DecoratedDeclData;
			setNodes(objHeap, arrHeap, handle, "decorators", d.decorators);
			setNode(objHeap, arrHeap, handle, "decoratedNode", d.decoratedNode);
		},
		NodeKind.MacroInvocation => {
			const d = node.data as MacroInvocationData;
			setStr(objHeap, handle, "macroName", d.macroName);
			setNodes(objHeap, arrHeap, handle, "macroArgs", d.macroArgs);
		},

		// === Testing ===
		NodeKind.TestDecl => {
			const d = node.data as TestDeclData;
			setStr(objHeap, handle, "testName", d.testName);
			setNode(objHeap, arrHeap, handle, "testBody", d.testBody);
		},
		NodeKind.AssertStmt => {
			const d = node.data as AssertStmtData;
			setNode(objHeap, arrHeap, handle, "assertExpr", d.assertExpr);
			setStr(objHeap, handle, "assertSource", d.assertSource);
			setStr(objHeap, handle, "assertMessage", d.assertMessage);
		},

		// === Program ===
		NodeKind.Program => {
			const d = node.data as ProgramData;
			setNodes(objHeap, arrHeap, handle, "programStmts", d.programStmts);
		},

		// Any unrecognized kind: kind/line/column only
		_ => {},
	};

	return raiserObject(handle);
}

// ===== Deserialization helpers (read from RaiserValue) =====

function readStr(objHeap: RaiserObjectHeap, h: number, name: string): string {
	const v = heapObjectGetField(objHeap, h, name);
	if (v.kind === RaiserValueKind.String) return v.strVal;
	return "";
}

function readInt(objHeap: RaiserObjectHeap, h: number, name: string): number {
	const v = heapObjectGetField(objHeap, h, name);
	return match (v.kind) {
		RaiserValueKind.Int | RaiserValueKind.Bool => v.intVal,
		RaiserValueKind.Float => v.floatVal,
		_ => 0,
	};
}

function readFloat(objHeap: RaiserObjectHeap, h: number, name: string): number {
	const v = heapObjectGetField(objHeap, h, name);
	if (v.kind === RaiserValueKind.Float) return v.floatVal;
	if (v.kind === RaiserValueKind.Int) return v.intVal + 0.0;
	return 0.0;
}

function readBool(objHeap: RaiserObjectHeap, h: number, name: string): boolean {
	const v = heapObjectGetField(objHeap, h, name);
	if (v.kind === RaiserValueKind.Bool) return v.intVal !== 0;
	return false;
}

function readNode(objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap, h: number, name: string, fallbackLoc: SourceLocation): Node {
	const v = heapObjectGetField(objHeap, h, name);
	if (v.kind === RaiserValueKind.Nil) return null as unknown as Node;
	return valueToNode(v, objHeap, arrHeap, fallbackLoc);
}

function readNodes(objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap, h: number, name: string, fallbackLoc: SourceLocation): Node[] {
	const v = heapObjectGetField(objHeap, h, name);
	const result: Node[] = [];
	if (v.kind !== RaiserValueKind.Array) return result;
	const handle = v.intVal;
	const len = heapArrayLen(arrHeap, handle);
	let i = 0;
	while (i < len) {
		const elem = heapArrayGet(arrHeap, handle, i);
		result.push(valueToNode(elem, objHeap, arrHeap, fallbackLoc));
		i = i + 1;
	}
	return result;
}

function readStrs(objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap, h: number, name: string): string[] {
	const v = heapObjectGetField(objHeap, h, name);
	const result: string[] = [];
	if (v.kind !== RaiserValueKind.Array) return result;
	const handle = v.intVal;
	const len = heapArrayLen(arrHeap, handle);
	let i = 0;
	while (i < len) {
		const elem = heapArrayGet(arrHeap, handle, i);
		if (elem.kind === RaiserValueKind.String) {
			result.push(elem.strVal);
		} else {
			result.push("");
		}
		i = i + 1;
	}
	return result;
}

function readLoc(objHeap: RaiserObjectHeap, h: number): SourceLocation {
	return makeLoc(readInt(objHeap, h, "line"), readInt(objHeap, h, "column"));
}

// ===== valueToNode: RaiserValue → AST Node =====

export function valueToNode(val: RaiserValue, objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap, fallbackLoc: SourceLocation): Node {
	return match (val.kind) {
		RaiserValueKind.Int => mkNumber(val.intVal, fallbackLoc),
		RaiserValueKind.Float => mkNumber(val.floatVal, fallbackLoc),
		RaiserValueKind.Bool => mkBool(val.intVal !== 0, fallbackLoc),
		RaiserValueKind.String => mkString(val.strVal, fallbackLoc),
		RaiserValueKind.Nil => mkNull(fallbackLoc),
		RaiserValueKind.Array => {
			const handle = val.intVal;
			const len = heapArrayLen(arrHeap, handle);
			const elements: Node[] = [];
			let i = 0;
			while (i < len) {
				const elem = heapArrayGet(arrHeap, handle, i);
				elements.push(valueToNode(elem, objHeap, arrHeap, fallbackLoc));
				i = i + 1;
			}
			return createNodeAt(NodeKind.ArrayLiteral, { elements }, fallbackLoc);
		},
		RaiserValueKind.Object => {
			const handle = val.intVal;
			// Check for "kind" field — if present, this is a serialized Node
			const kindField = heapObjectGetField(objHeap, handle, "kind");
			if (kindField.kind === RaiserValueKind.Int) {
				return readNodeFromObject(handle, kindField.intVal as NodeKind, objHeap, arrHeap, fallbackLoc);
			}
			// No "kind" field — fall back to ObjectLiteral
			return deserializeObjectLiteral(handle, objHeap, arrHeap, fallbackLoc);
		},
		_ => mkNull(fallbackLoc),
	};
}

function deserializeObjectLiteral(handle: number, objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap, loc: SourceLocation): Node {
	const obj = objHeap.objects[handle];
	const keys: string[] = [];
	const values: Node[] = [];
	for (const field of obj.fields) {
		keys.push(field.name);
		values.push(valueToNode(field.value, objHeap, arrHeap, loc));
	}
	return createNodeAt(NodeKind.ObjectLiteral, { properties: values, keys, keyLocations: [] }, loc);
}

// Reconstruct a Node from a serialized heap object.
// MAINTENANCE: This is the exact mirror of nodeToValue above. Field names MUST match.
// When you add a field to nodeToValue, add the corresponding read here.
function readNodeFromObject(h: number, kind: NodeKind, objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap, fallbackLoc: SourceLocation): Node {
	const loc = readLoc(objHeap, h);
	return match (kind) {
		// === Literals ===
		NodeKind.NumberLiteral => {
			const value = readFloat(objHeap, h, "value");
			return createNodeAt(NodeKind.NumberLiteral, { value, isFloat: value % 1 !== 0 }, loc);
		},
		NodeKind.StringLiteral => {
			return createNodeAt(NodeKind.StringLiteral, { value: readStr(objHeap, h, "value") }, loc);
		},
		NodeKind.BooleanLiteral => {
			return createNodeAt(NodeKind.BooleanLiteral, { boolValue: readBool(objHeap, h, "boolValue") }, loc);
		},
		NodeKind.NullLiteral => {
			return createNodeAt(NodeKind.NullLiteral, { nullPlaceholder: true }, loc);
		},
		NodeKind.BigIntLiteral => {
			return createNodeAt(NodeKind.BigIntLiteral, { bigintValue: readStr(objHeap, h, "bigintValue") }, loc);
		},
		NodeKind.RegexLiteral => {
			return createNodeAt(NodeKind.RegexLiteral, { regexPattern: readStr(objHeap, h, "regexPattern") }, loc);
		},

		// === Identifier ===
		NodeKind.Identifier => {
			return createNodeAt(NodeKind.Identifier, { name: readStr(objHeap, h, "name") }, loc);
		},

		// === Binary/Unary/Update ===
		NodeKind.BinaryExpr => {
			const operator = readStr(objHeap, h, "operator");
			const left = readNode(objHeap, arrHeap, h, "left", loc);
			const right = readNode(objHeap, arrHeap, h, "right", loc);
			return createNodeAt(NodeKind.BinaryExpr, { operator, left, right }, loc);
		},
		NodeKind.UnaryExpr => {
			const unaryOp = readStr(objHeap, h, "unaryOp");
			const operand = readNode(objHeap, arrHeap, h, "operand", loc);
			return createNodeAt(NodeKind.UnaryExpr, { unaryOp, operand }, loc);
		},
		NodeKind.UpdateExpr => {
			const updateOp = readStr(objHeap, h, "updateOp");
			const updateArg = readNode(objHeap, arrHeap, h, "updateArg", loc);
			const isPrefix = readBool(objHeap, h, "isPrefix");
			return createNodeAt(NodeKind.UpdateExpr, { updateOp, updateArg, isPrefix }, loc);
		},

		// === Call/Member/Access ===
		NodeKind.CallExpr => {
			const callee = readNode(objHeap, arrHeap, h, "callee", loc);
			const args = readNodes(objHeap, arrHeap, h, "arguments", loc);
			return createNodeAt(NodeKind.CallExpr, {
				callee, arguments: args, isDirectCall: true, resolvedOverloadIdx: 0,
			}, loc);
		},
		NodeKind.MemberExpr => {
			const object = readNode(objHeap, arrHeap, h, "object", loc);
			const property = readStr(objHeap, h, "property");
			const isOptional = readBool(objHeap, h, "isOptional");
			return createNodeAt(NodeKind.MemberExpr, { object, property, isOptional }, loc);
		},
		NodeKind.ArrayAccess => {
			const array = readNode(objHeap, arrHeap, h, "array", loc);
			const index = readNode(objHeap, arrHeap, h, "index", loc);
			return createNodeAt(NodeKind.ArrayAccess, { array, index }, loc);
		},

		// === Collection literals ===
		NodeKind.ObjectLiteral => {
			const properties = readNodes(objHeap, arrHeap, h, "properties", loc);
			const keys = readStrs(objHeap, arrHeap, h, "keys");
			return createNodeAt(NodeKind.ObjectLiteral, { properties, keys, keyLocations: [] }, loc);
		},
		NodeKind.ArrayLiteral => {
			const elements = readNodes(objHeap, arrHeap, h, "elements", loc);
			return createNodeAt(NodeKind.ArrayLiteral, { elements }, loc);
		},

		// === Function expressions ===
		NodeKind.ArrowFunction => {
			const arrowParams = readStrs(objHeap, arrHeap, h, "arrowParams");
			const arrowParamTypes = readStrs(objHeap, arrHeap, h, "arrowParamTypes");
			const arrowBody = readNode(objHeap, arrHeap, h, "arrowBody", loc);
			const arrowFlags = readStr(objHeap, h, "arrowFlags");
			const arrowReturnType = readStr(objHeap, h, "arrowReturnType");
			return createNodeAt(NodeKind.ArrowFunction, {
				arrowParams, arrowParamTypes, arrowBody, arrowFlags, arrowReturnType,
			}, loc);
		},
		NodeKind.FunctionExpr => {
			const funcExprParams = readStrs(objHeap, arrHeap, h, "funcExprParams");
			const funcExprParamTypes = readStrs(objHeap, arrHeap, h, "funcExprParamTypes");
			const funcExprBody = readNode(objHeap, arrHeap, h, "funcExprBody", loc);
			const funcExprFlags = readStr(objHeap, h, "funcExprFlags");
			const funcExprReturnType = readStr(objHeap, h, "funcExprReturnType");
			return createNodeAt(NodeKind.FunctionExpr, {
				funcExprParams, funcExprParamTypes, funcExprBody, funcExprFlags, funcExprReturnType,
			}, loc);
		},

		// === Other expressions ===
		NodeKind.TypeAssertion => {
			const asExpr = readNode(objHeap, arrHeap, h, "asExpr", loc);
			const asType = readStr(objHeap, h, "asType");
			return createNodeAt(NodeKind.TypeAssertion, { asExpr, asType }, loc);
		},
		NodeKind.ConditionalExpr => {
			const ternaryCondition = readNode(objHeap, arrHeap, h, "ternaryCondition", loc);
			const ternaryConsequent = readNode(objHeap, arrHeap, h, "ternaryConsequent", loc);
			const ternaryAlternate = readNode(objHeap, arrHeap, h, "ternaryAlternate", loc);
			return createNodeAt(NodeKind.ConditionalExpr, {
				ternaryCondition, ternaryConsequent, ternaryAlternate,
			}, loc);
		},
		NodeKind.SpreadExpr => {
			const spreadArg = readNode(objHeap, arrHeap, h, "spreadArg", loc);
			return createNodeAt(NodeKind.SpreadExpr, { spreadArg }, loc);
		},
		NodeKind.NewExpr => {
			const newCallee = readNode(objHeap, arrHeap, h, "newCallee", loc);
			const newArguments = readNodes(objHeap, arrHeap, h, "newArguments", loc);
			return createNodeAt(NodeKind.NewExpr, { newCallee, newArguments }, loc);
		},
		NodeKind.TryExpr => {
			const tryArg = readNode(objHeap, arrHeap, h, "tryArg", loc);
			const hasCatch = readBool(objHeap, h, "hasCatch");
			const catchVal = hasCatch ? readNode(objHeap, arrHeap, h, "catchVal", loc) : (null as unknown as Node);
			return createNodeAt(NodeKind.TryExpr, { tryArg, hasCatch, catchVal }, loc);
		},
		NodeKind.MatchExpr => {
			const matchDisc = readNode(objHeap, arrHeap, h, "matchDisc", loc);
			const matchCases = readNodes(objHeap, arrHeap, h, "matchCases", loc);
			return createNodeAt(NodeKind.MatchExpr, { matchDisc, matchCases }, loc);
		},
		NodeKind.MatchCase => {
			const casePatterns = readNodes(objHeap, arrHeap, h, "casePatterns", loc);
			const caseGuard = readNode(objHeap, arrHeap, h, "caseGuard", loc);
			const caseBody = readNode(objHeap, arrHeap, h, "caseBody", loc);
			return createNodeAt(NodeKind.MatchCase, {
				casePatterns, caseGuard, caseBody,
			}, loc);
		},
		NodeKind.AwaitExpr => {
			const awaitArg = readNode(objHeap, arrHeap, h, "awaitArg", loc);
			return createNodeAt(NodeKind.AwaitExpr, { awaitArg }, loc);
		},
		NodeKind.YieldExpr => {
			const yieldArg = readNode(objHeap, arrHeap, h, "yieldArg", loc);
			const isDelegate = readBool(objHeap, h, "isDelegate");
			return createNodeAt(NodeKind.YieldExpr, { yieldArg, isDelegate }, loc);
		},
		NodeKind.MoveExpr => {
			const moveArg = readNode(objHeap, arrHeap, h, "moveArg", loc);
			return createNodeAt(NodeKind.MoveExpr, { moveArg }, loc);
		},
		NodeKind.OutExpr => {
			const outArg = readNode(objHeap, arrHeap, h, "outArg", loc);
			return createNodeAt(NodeKind.OutExpr, { outArg }, loc);
		},
		NodeKind.SizeofExpr => {
			return createNodeAt(NodeKind.SizeofExpr, { sizeofType: readStr(objHeap, h, "sizeofType") }, loc);
		},
		NodeKind.HiddenDeref => {
			const expr = readNode(objHeap, arrHeap, h, "expr", loc);
			return createNodeAt(NodeKind.HiddenDeref, { expr }, loc);
		},
		NodeKind.QuoteExpr => {
			const quoteBody = readNode(objHeap, arrHeap, h, "quoteBody", loc);
			return createNodeAt(NodeKind.QuoteExpr, { quoteBody }, loc);
		},
		NodeKind.ComptimeBlock => {
			const comptimeBody = readNode(objHeap, arrHeap, h, "comptimeBody", loc);
			return createNodeAt(NodeKind.ComptimeBlock, { comptimeBody }, loc);
		},
		NodeKind.TypeAnnotation => {
			return createNodeAt(NodeKind.TypeAnnotation, { annotationType: readStr(objHeap, h, "annotationType") }, loc);
		},

		// === Patterns ===
		NodeKind.ArrayPattern => {
			const patternElements = readNodes(objHeap, arrHeap, h, "patternElements", loc);
			const hasRestElement = readBool(objHeap, h, "hasRestElement");
			return createNodeAt(NodeKind.ArrayPattern, { patternElements, hasRestElement }, loc);
		},
		NodeKind.ObjectPattern => {
			const patternProps = readNodes(objHeap, arrHeap, h, "patternProps", loc);
			const hasRestProp = readBool(objHeap, h, "hasRestProp");
			return createNodeAt(NodeKind.ObjectPattern, { patternProps, hasRestProp }, loc);
		},
		NodeKind.ObjectPatternProp => {
			const propKey = readStr(objHeap, h, "propKey");
			const propAlias = readNode(objHeap, arrHeap, h, "propAlias", loc);
			return createNodeAt(NodeKind.ObjectPatternProp, { propKey, propAlias }, loc);
		},
		NodeKind.DestructuringDecl => {
			const destrPattern = readNode(objHeap, arrHeap, h, "destrPattern", loc);
			const destrInit = readNode(objHeap, arrHeap, h, "destrInit", loc);
			const destrIsConst = readBool(objHeap, h, "destrIsConst");
			return createNodeAt(NodeKind.DestructuringDecl, { destrPattern, destrInit, destrIsConst }, loc);
		},

		// === Statements ===
		NodeKind.ExprStmt => {
			const expr = readNode(objHeap, arrHeap, h, "expr", loc);
			return createNodeAt(NodeKind.ExprStmt, { expr }, loc);
		},
		NodeKind.ReturnStmt => {
			const argument = readNode(objHeap, arrHeap, h, "argument", loc);
			return createNodeAt(NodeKind.ReturnStmt, { argument }, loc);
		},
		NodeKind.ThrowStmt => {
			const throwArg = readNode(objHeap, arrHeap, h, "throwArg", loc);
			return createNodeAt(NodeKind.ThrowStmt, { throwArg }, loc);
		},
		NodeKind.DeferStmt => {
			const deferExpr = readNode(objHeap, arrHeap, h, "deferExpr", loc);
			return createNodeAt(NodeKind.DeferStmt, { deferExpr }, loc);
		},
		NodeKind.BlockStmt => {
			const statements = readNodes(objHeap, arrHeap, h, "statements", loc);
			return createNodeAt(NodeKind.BlockStmt, { statements }, loc);
		},
		NodeKind.VariableDecl => {
			const declName = readStr(objHeap, h, "declName");
			const declType = readStr(objHeap, h, "declType");
			const initializer = readNode(objHeap, arrHeap, h, "initializer", loc);
			const declKind = readInt(objHeap, h, "declKind") as DeclKind;
			return createNodeAt(NodeKind.VariableDecl, {
				declName, declType, initializer, declKind, nameLocation: loc,
			}, loc);
		},
		NodeKind.IfStmt => {
			const condition = readNode(objHeap, arrHeap, h, "condition", loc);
			const consequent = readNode(objHeap, arrHeap, h, "consequent", loc);
			const alternate = readNode(objHeap, arrHeap, h, "alternate", loc);
			return createNodeAt(NodeKind.IfStmt, { condition, consequent, alternate }, loc);
		},
		NodeKind.WhileStmt => {
			const whileCondition = readNode(objHeap, arrHeap, h, "whileCondition", loc);
			const whileBody = readNode(objHeap, arrHeap, h, "whileBody", loc);
			return createNodeAt(NodeKind.WhileStmt, { whileCondition, whileBody }, loc);
		},
		NodeKind.DoWhileStmt => {
			const doBody = readNode(objHeap, arrHeap, h, "doBody", loc);
			const doCondition = readNode(objHeap, arrHeap, h, "doCondition", loc);
			return createNodeAt(NodeKind.DoWhileStmt, { doBody, doCondition }, loc);
		},
		NodeKind.ForStmt => {
			const forInit = readNode(objHeap, arrHeap, h, "forInit", loc);
			const forCondition = readNode(objHeap, arrHeap, h, "forCondition", loc);
			const forUpdate = readNode(objHeap, arrHeap, h, "forUpdate", loc);
			const forBody = readNode(objHeap, arrHeap, h, "forBody", loc);
			return createNodeAt(NodeKind.ForStmt, { forInit, forCondition, forUpdate, forBody }, loc);
		},
		NodeKind.ForOfStmt => {
			const forOfBinding = readStr(objHeap, h, "forOfBinding");
			const forOfIsConst = readBool(objHeap, h, "forOfIsConst");
			const forOfIterable = readNode(objHeap, arrHeap, h, "forOfIterable", loc);
			const forOfBody = readNode(objHeap, arrHeap, h, "forOfBody", loc);
			return createNodeAt(NodeKind.ForOfStmt, {
				forOfBinding, forOfIsConst, forOfIterable, forOfBody,
				forOfPattern: null as unknown as Node, bindingLocation: loc,
			}, loc);
		},
		NodeKind.ForInStmt => {
			const forInBinding = readStr(objHeap, h, "forInBinding");
			const forInIsConst = readBool(objHeap, h, "forInIsConst");
			const forInObject = readNode(objHeap, arrHeap, h, "forInObject", loc);
			const forInBody = readNode(objHeap, arrHeap, h, "forInBody", loc);
			return createNodeAt(NodeKind.ForInStmt, { forInBinding, forInIsConst, forInObject, forInBody }, loc);
		},
		NodeKind.BreakStmt => {
			return createNodeAt(NodeKind.BreakStmt, { breakLabel: readStr(objHeap, h, "breakLabel") }, loc);
		},
		NodeKind.ContinueStmt => {
			return createNodeAt(NodeKind.ContinueStmt, { continueLabel: readStr(objHeap, h, "continueLabel") }, loc);
		},
		NodeKind.UnreachableStmt => {
			return createNodeAt(NodeKind.UnreachableStmt, { unreachableMsg: readStr(objHeap, h, "unreachableMsg") }, loc);
		},
		NodeKind.SwitchStmt => {
			const switchDisc = readNode(objHeap, arrHeap, h, "switchDisc", loc);
			const switchCases = readNodes(objHeap, arrHeap, h, "switchCases", loc);
			return createNodeAt(NodeKind.SwitchStmt, { switchDisc, switchCases }, loc);
		},
		NodeKind.SwitchCase => {
			const caseTests = readNodes(objHeap, arrHeap, h, "caseTests", loc);
			const caseStmts = readNodes(objHeap, arrHeap, h, "caseStmts", loc);
			const isDefault = readBool(objHeap, h, "isDefault");
			return createNodeAt(NodeKind.SwitchCase, { caseTests, caseStmts, isDefault }, loc);
		},
		NodeKind.MatchStmt => {
			const matchStmtDisc = readNode(objHeap, arrHeap, h, "matchStmtDisc", loc);
			const matchStmtCases = readNodes(objHeap, arrHeap, h, "matchStmtCases", loc);
			return createNodeAt(NodeKind.MatchStmt, { matchStmtDisc, matchStmtCases }, loc);
		},
		NodeKind.TryCatchStmt => {
			const tryBody = readNode(objHeap, arrHeap, h, "tryBody", loc);
			const catchName = readStr(objHeap, h, "catchName");
			const catchBody = readNode(objHeap, arrHeap, h, "catchBody", loc);
			const finallyBody = readNode(objHeap, arrHeap, h, "finallyBody", loc);
			return createNodeAt(NodeKind.TryCatchStmt, {
				tryBody, catchName, catchBody, finallyBody, catchBindingLocation: loc,
			}, loc);
		},

		// === Declarations ===
		NodeKind.FunctionDecl => {
			const fnName = readStr(objHeap, h, "fnName");
			const params = readStrs(objHeap, arrHeap, h, "params");
			const fnParamTypes = readStrs(objHeap, arrHeap, h, "fnParamTypes");
			const fnBody = readNode(objHeap, arrHeap, h, "fnBody", loc);
			const fnFlags = readStr(objHeap, h, "fnFlags");
			const fnReturnType = readStr(objHeap, h, "fnReturnType");
			return createNodeAt(NodeKind.FunctionDecl, {
				fnName, params, fnParamTypes, fnBody, fnFlags, fnReturnType,
				fnDefaults: [], nativeName: "", nameLocation: loc,
			}, loc);
		},
		NodeKind.ImportDecl => {
			const importNames = readStrs(objHeap, arrHeap, h, "importNames");
			const importAliases = readStrs(objHeap, arrHeap, h, "importAliases");
			const importSource = readStr(objHeap, h, "importSource");
			return createNodeAt(NodeKind.ImportDecl, {
				importNames, importAliases, importSource, nameLocations: [],
			}, loc);
		},
		NodeKind.ExportDecl => {
			const exportedDecl = readNode(objHeap, arrHeap, h, "exportedDecl", loc);
			return createNodeAt(NodeKind.ExportDecl, { exportedDecl }, loc);
		},
		NodeKind.TypeAliasDecl => {
			const aliasName = readStr(objHeap, h, "aliasName");
			const aliasType = readStr(objHeap, h, "aliasType");
			const aliasIsDistinct = readBool(objHeap, h, "aliasIsDistinct");
			return createNodeAt(NodeKind.TypeAliasDecl, {
				aliasName, aliasType, aliasIsDistinct,
				discriminantName: "", discriminantType: "",
				variantKeys: [], variantTypes: [], nameLocation: loc,
			}, loc);
		},
		NodeKind.EnumDecl => {
			const enumName = readStr(objHeap, h, "enumName");
			const enumMembers = readStrs(objHeap, arrHeap, h, "enumMembers");
			return createNodeAt(NodeKind.EnumDecl, {
				enumName, enumMembers, enumValues: [], nameLocation: loc, memberLocations: [],
			}, loc);
		},
		NodeKind.InterfaceDecl => {
			const interfaceName = readStr(objHeap, h, "interfaceName");
			const interfaceFields = readStrs(objHeap, arrHeap, h, "interfaceFields");
			const interfaceFieldTypes = readStrs(objHeap, arrHeap, h, "interfaceFieldTypes");
			return createNodeAt(NodeKind.InterfaceDecl, {
				interfaceName, interfaceFields, interfaceFieldTypes, nameLocation: loc,
			}, loc);
		},
		NodeKind.StructDecl => {
			const interfaceName = readStr(objHeap, h, "interfaceName");
			const interfaceFields = readStrs(objHeap, arrHeap, h, "interfaceFields");
			const interfaceFieldTypes = readStrs(objHeap, arrHeap, h, "interfaceFieldTypes");
			return createNodeAt(NodeKind.StructDecl, {
				interfaceName, interfaceFields, interfaceFieldTypes, nameLocation: loc,
			}, loc);
		},
		NodeKind.ClassDecl => {
			const className = readStr(objHeap, h, "className");
			const classExtends = readStr(objHeap, h, "classExtends");
			const classBody = readNodes(objHeap, arrHeap, h, "classBody", loc);
			return createNodeAt(NodeKind.ClassDecl, {
				className, classExtends, classBody, nameLocation: loc,
			}, loc);
		},
		NodeKind.ActorDecl => {
			const actorName = readStr(objHeap, h, "actorName");
			const actorBody = readNodes(objHeap, arrHeap, h, "actorBody", loc);
			return createNodeAt(NodeKind.ActorDecl, { actorName, actorBody, nameLocation: loc }, loc);
		},
		NodeKind.PropertyDecl => {
			const propName = readStr(objHeap, h, "propName");
			const propType = readStr(objHeap, h, "propType");
			const propIsStatic = readBool(objHeap, h, "propIsStatic");
			return createNodeAt(NodeKind.PropertyDecl, {
				propName, propType, propIsStatic, propIsReadonly: false,
				propInitializer: null as unknown as Node,
			}, loc);
		},
		NodeKind.MethodDecl => {
			const methodName = readStr(objHeap, h, "methodName");
			const methodParams = readStrs(objHeap, arrHeap, h, "methodParams");
			const methodParamTypes = readStrs(objHeap, arrHeap, h, "methodParamTypes");
			const methodBody = readNode(objHeap, arrHeap, h, "methodBody", loc);
			const methodIsStatic = readBool(objHeap, h, "methodIsStatic");
			const methodFlags = readStr(objHeap, h, "methodFlags");
			const methodReturnType = readStr(objHeap, h, "methodReturnType");
			return createNodeAt(NodeKind.MethodDecl, {
				methodName, methodParams, methodParamTypes, methodBody,
				methodIsStatic, methodFlags, methodReturnType,
				nativeName: "", nameLocation: loc,
			}, loc);
		},
		NodeKind.ConstructorDecl => {
			const ctorParams = readStrs(objHeap, arrHeap, h, "ctorParams");
			const ctorParamTypes = readStrs(objHeap, arrHeap, h, "ctorParamTypes");
			const ctorBody = readNode(objHeap, arrHeap, h, "ctorBody", loc);
			return createNodeAt(NodeKind.ConstructorDecl, {
				ctorParams, ctorParamTypes, ctorBody, ctorDefaults: [],
			}, loc);
		},
		NodeKind.ExternDecl => {
			const externKind = readInt(objHeap, h, "externKind") as ExternKind;
			const externName = readStr(objHeap, h, "externName");
			const nativeName = readStr(objHeap, h, "nativeName");
			const externType = readStr(objHeap, h, "externType");
			return createNodeAt(NodeKind.ExternDecl, { externKind, externName, nativeName, externType }, loc);
		},
		NodeKind.MacroDecl => {
			const macroDeclName = readStr(objHeap, h, "macroDeclName");
			const macroDeclParams = readStrs(objHeap, arrHeap, h, "macroDeclParams");
			const macroDeclParamTypes = readStrs(objHeap, arrHeap, h, "macroDeclParamTypes");
			const macroDeclBody = readNode(objHeap, arrHeap, h, "macroDeclBody", loc);
			return createNodeAt(NodeKind.MacroDecl, { macroDeclName, macroDeclParams, macroDeclParamTypes, macroDeclBody }, loc);
		},
		NodeKind.DecoratedDecl => {
			const decorators = readNodes(objHeap, arrHeap, h, "decorators", loc);
			const decoratedNode = readNode(objHeap, arrHeap, h, "decoratedNode", loc);
			return createNodeAt(NodeKind.DecoratedDecl, { decorators, decoratedNode }, loc);
		},
		NodeKind.MacroInvocation => {
			const macroName = readStr(objHeap, h, "macroName");
			const macroArgs = readNodes(objHeap, arrHeap, h, "macroArgs", loc);
			return createNodeAt(NodeKind.MacroInvocation, { macroName, macroArgs }, loc);
		},

		// === Testing ===
		NodeKind.TestDecl => {
			const testName = readStr(objHeap, h, "testName");
			const testBody = readNode(objHeap, arrHeap, h, "testBody", loc);
			return createNodeAt(NodeKind.TestDecl, { testName, testBody }, loc);
		},
		NodeKind.AssertStmt => {
			const assertExpr = readNode(objHeap, arrHeap, h, "assertExpr", loc);
			const assertSource = readStr(objHeap, h, "assertSource");
			const assertMessage = readStr(objHeap, h, "assertMessage");
			return createNodeAt(NodeKind.AssertStmt, { assertExpr, assertSource, assertMessage }, loc);
		},

		// === Program ===
		NodeKind.Program => {
			const programStmts = readNodes(objHeap, arrHeap, h, "programStmts", loc);
			return createNodeAt(NodeKind.Program, { programStmts }, loc);
		},

		// Unknown kind — return a NullLiteral as safe fallback
		_ => createNodeAt(NodeKind.NullLiteral, { nullPlaceholder: true }, loc),
	};
}

// ===== Tests =====

test "NumberLiteral serialization" {
	const objHeap = createStructHeap();
	const arrHeap = createArrayHeap();
	const loc = makeLoc(5, 10);
	const node = mkNumber(42, loc);
	const val = nodeToValue(node, objHeap, arrHeap);
	assert val.kind === RaiserValueKind.Object;
	const kindVal = heapObjectGetField(objHeap, val.intVal, "kind");
	assert kindVal.intVal === (NodeKind.NumberLiteral as number);
	const numVal = heapObjectGetField(objHeap, val.intVal, "value");
	assert numVal.floatVal === 42;
	const lineVal = heapObjectGetField(objHeap, val.intVal, "line");
	assert lineVal.intVal === 5;
}

test "StringLiteral serialization" {
	const objHeap = createStructHeap();
	const arrHeap = createArrayHeap();
	const loc = makeLoc(1, 0);
	const node = mkString("hello", loc);
	const val = nodeToValue(node, objHeap, arrHeap);
	assert val.kind === RaiserValueKind.Object;
	const kindVal = heapObjectGetField(objHeap, val.intVal, "kind");
	assert kindVal.intVal === (NodeKind.StringLiteral as number);
	const strVal = heapObjectGetField(objHeap, val.intVal, "value");
	assert strVal.strVal === "hello";
}

test "BooleanLiteral serialization" {
	const objHeap = createStructHeap();
	const arrHeap = createArrayHeap();
	const loc = makeLoc(1, 0);
	const node = mkBool(true, loc);
	const val = nodeToValue(node, objHeap, arrHeap);
	assert val.kind === RaiserValueKind.Object;
	const kindVal = heapObjectGetField(objHeap, val.intVal, "kind");
	assert kindVal.intVal === (NodeKind.BooleanLiteral as number);
	const bVal = heapObjectGetField(objHeap, val.intVal, "boolValue");
	assert bVal.intVal === 1;
}

test "Identifier serialization" {
	const objHeap = createStructHeap();
	const arrHeap = createArrayHeap();
	const loc = makeLoc(1, 0);
	const node = createNode(NodeKind.Identifier, { name: "foo" }, synthToken(loc));
	const val = nodeToValue(node, objHeap, arrHeap);
	assert val.kind === RaiserValueKind.Object;
	const kindVal = heapObjectGetField(objHeap, val.intVal, "kind");
	assert kindVal.intVal === (NodeKind.Identifier as number);
	const nameVal = heapObjectGetField(objHeap, val.intVal, "name");
	assert nameVal.strVal === "foo";
}

test "BinaryExpr serialization" {
	const objHeap = createStructHeap();
	const arrHeap = createArrayHeap();
	const loc = makeLoc(1, 0);
	const left = mkNumber(2, loc);
	const right = mkNumber(3, loc);
	const binNode = createNode(NodeKind.BinaryExpr, {
		operator: "+", left, right,
	}, synthToken(loc));
	const val = nodeToValue(binNode, objHeap, arrHeap);
	assert val.kind === RaiserValueKind.Object;
	const opVal = heapObjectGetField(objHeap, val.intVal, "operator");
	assert opVal.strVal === "+";
	const leftVal = heapObjectGetField(objHeap, val.intVal, "left");
	assert leftVal.kind === RaiserValueKind.Object;
	const leftKind = heapObjectGetField(objHeap, leftVal.intVal, "kind");
	assert leftKind.intVal === (NodeKind.NumberLiteral as number);
	const rightVal = heapObjectGetField(objHeap, val.intVal, "right");
	assert rightVal.kind === RaiserValueKind.Object;
	const rightKind = heapObjectGetField(objHeap, rightVal.intVal, "kind");
	assert rightKind.intVal === (NodeKind.NumberLiteral as number);
}

// ===== Round-trip tests (Phase A3) =====

test "round-trip NumberLiteral" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const orig = mkNumber(42, makeLoc(1, 0));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, orig.location);
	assert back.kind === NodeKind.NumberLiteral;
	const d = back.data as NumberLiteralData;
	assert d.value === 42;
}

test "round-trip StringLiteral" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const orig = mkString("hello", makeLoc(1, 0));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, orig.location);
	assert back.kind === NodeKind.StringLiteral;
	const d = back.data as StringLiteralData;
	assert d.value === "hello";
}

test "round-trip BooleanLiteral" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const orig = mkBool(true, makeLoc(1, 0));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, orig.location);
	assert back.kind === NodeKind.BooleanLiteral;
	const d = back.data as BooleanLiteralData;
	assert d.boolValue === true;
}

test "round-trip Identifier" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(2, 5);
	const orig = createNode(NodeKind.Identifier, { name: "myVar" }, synthToken(loc));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, loc);
	assert back.kind === NodeKind.Identifier;
	const d = back.data as IdentifierData;
	assert d.name === "myVar";
}

test "round-trip BinaryExpr" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const left = mkNumber(1, loc);
	const right = mkNumber(2, loc);
	const orig = createNode(NodeKind.BinaryExpr, { operator: "+", left, right }, synthToken(loc));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, loc);
	assert back.kind === NodeKind.BinaryExpr;
	const d = back.data as BinaryExprData;
	assert d.operator === "+";
	assert d.left.kind === NodeKind.NumberLiteral;
	assert d.right.kind === NodeKind.NumberLiteral;
	assert (d.left.data as NumberLiteralData).value === 1;
	assert (d.right.data as NumberLiteralData).value === 2;
}

test "round-trip CallExpr with arguments" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const callee = createNode(NodeKind.Identifier, { name: "log" }, synthToken(loc));
	const args = [mkString("hello", loc), mkNumber(42, loc)];
	const orig = createNode(NodeKind.CallExpr, {
		callee, arguments: args, isDirectCall: true, resolvedOverloadIdx: 0,
	}, synthToken(loc));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, loc);
	assert back.kind === NodeKind.CallExpr;
	const d = back.data as CallExprData;
	assert d.callee.kind === NodeKind.Identifier;
	assert d.arguments.length === 2;
	assert d.arguments[0].kind === NodeKind.StringLiteral;
	assert d.arguments[1].kind === NodeKind.NumberLiteral;
}

test "round-trip MemberExpr" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const obj = createNode(NodeKind.Identifier, { name: "foo" }, synthToken(loc));
	const orig = createNode(NodeKind.MemberExpr, {
		object: obj, property: "bar", isOptional: false,
	}, synthToken(loc));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, loc);
	assert back.kind === NodeKind.MemberExpr;
	const d = back.data as MemberExprData;
	assert d.property === "bar";
	assert d.object.kind === NodeKind.Identifier;
}

test "round-trip BlockStmt with statements" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const ret = createNode(NodeKind.ReturnStmt, { argument: mkNumber(7, loc) }, synthToken(loc));
	const orig = createNode(NodeKind.BlockStmt, { statements: [ret] }, synthToken(loc));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, loc);
	assert back.kind === NodeKind.BlockStmt;
	const d = back.data as BlockStmtData;
	assert d.statements.length === 1;
	assert d.statements[0].kind === NodeKind.ReturnStmt;
}

test "round-trip IfStmt" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const cond = mkBool(true, loc);
	const cons = createNode(NodeKind.BlockStmt, { statements: [] }, synthToken(loc));
	const alt = createNode(NodeKind.BlockStmt, { statements: [] }, synthToken(loc));
	const orig = createNode(NodeKind.IfStmt, { condition: cond, consequent: cons, alternate: alt }, synthToken(loc));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, loc);
	assert back.kind === NodeKind.IfStmt;
	const d = back.data as IfStmtData;
	assert d.condition.kind === NodeKind.BooleanLiteral;
	assert d.consequent.kind === NodeKind.BlockStmt;
	assert d.alternate.kind === NodeKind.BlockStmt;
}

test "round-trip VariableDecl" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(3, 0);
	const init = mkNumber(100, loc);
	const orig = createNode(NodeKind.VariableDecl, {
		declName: "x", declType: "number", initializer: init,
		declKind: DeclKind.Const, nameLocation: loc,
	}, synthToken(loc));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, loc);
	assert back.kind === NodeKind.VariableDecl;
	const d = back.data as VariableDeclData;
	assert d.declName === "x";
	assert d.declType === "number";
	assert d.declKind === DeclKind.Const;
	assert d.initializer.kind === NodeKind.NumberLiteral;
}

test "round-trip FunctionDecl" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const body = createNode(NodeKind.BlockStmt, { statements: [] }, synthToken(loc));
	const orig = createNode(NodeKind.FunctionDecl, {
		fnName: "add", params: ["a", "b"], fnParamTypes: ["number", "number"],
		fnBody: body, fnFlags: "", fnReturnType: "number",
		fnDefaults: [], nativeName: "", nameLocation: loc,
	}, synthToken(loc));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, loc);
	assert back.kind === NodeKind.FunctionDecl;
	const d = back.data as FunctionDeclData;
	assert d.fnName === "add";
	assert d.params.length === 2;
	assert d.params[0] === "a";
	assert d.params[1] === "b";
	assert d.fnReturnType === "number";
}

test "round-trip ImportDecl" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const orig = createNode(NodeKind.ImportDecl, {
		importNames: ["X", "Y"], importAliases: ["X", "Z"],
		importSource: "./mod", nameLocations: [],
	}, synthToken(loc));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, loc);
	assert back.kind === NodeKind.ImportDecl;
	const d = back.data as ImportDeclData;
	assert d.importNames.length === 2;
	assert d.importNames[0] === "X";
	assert d.importAliases[1] === "Z";
	assert d.importSource === "./mod";
}

test "round-trip Program with multiple statements" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const decl = createNode(NodeKind.VariableDecl, {
		declName: "x", declType: "", initializer: mkNumber(1, loc),
		declKind: DeclKind.Const, nameLocation: loc,
	}, synthToken(loc));
	const ret = createNode(NodeKind.ReturnStmt, { argument: createNode(NodeKind.Identifier, { name: "x" }, synthToken(loc)) }, synthToken(loc));
	const orig = createNode(NodeKind.Program, { programStmts: [decl, ret] }, synthToken(loc));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, loc);
	assert back.kind === NodeKind.Program;
	const d = back.data as ProgramData;
	assert d.programStmts.length === 2;
	assert d.programStmts[0].kind === NodeKind.VariableDecl;
	assert d.programStmts[1].kind === NodeKind.ReturnStmt;
}

test "round-trip nested expressions" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	// (1 + 2) * 3
	const inner = createNode(NodeKind.BinaryExpr, {
		operator: "+", left: mkNumber(1, loc), right: mkNumber(2, loc),
	}, synthToken(loc));
	const orig = createNode(NodeKind.BinaryExpr, {
		operator: "*", left: inner, right: mkNumber(3, loc),
	}, synthToken(loc));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, loc);
	assert back.kind === NodeKind.BinaryExpr;
	const outer = back.data as BinaryExprData;
	assert outer.operator === "*";
	assert outer.left.kind === NodeKind.BinaryExpr;
	const innerBack = outer.left.data as BinaryExprData;
	assert innerBack.operator === "+";
	assert (innerBack.left.data as NumberLiteralData).value === 1;
	assert (innerBack.right.data as NumberLiteralData).value === 2;
	assert (outer.right.data as NumberLiteralData).value === 3;
}

test "round-trip MatchCase with guard" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const pat = mkNumber(1, loc);
	// guard: x > 0  (a BinaryExpr standing in for a real guard)
	const guard = createNode(NodeKind.BinaryExpr, {
		operator: ">",
		left: createNode(NodeKind.Identifier, { name: "x" }, synthToken(loc)),
		right: mkNumber(0, loc),
	}, synthToken(loc));
	const body = createNode(NodeKind.BlockStmt, { statements: [] }, synthToken(loc));
	const orig = createNode(NodeKind.MatchCase, {
		casePatterns: [pat], caseGuard: guard, caseBody: body,
	}, synthToken(loc));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, loc);
	assert back.kind === NodeKind.MatchCase;
	const d = back.data as MatchCaseData;
	assert d.casePatterns.length === 1;
	assert d.caseGuard !== null;
	assert d.caseGuard.kind === NodeKind.BinaryExpr;
	assert (d.caseGuard.data as BinaryExprData).operator === ">";
}

test "round-trip MatchCase without guard (null)" {
	const objH = createStructHeap();
	const arrH = createArrayHeap();
	const loc = makeLoc(1, 0);
	const pat = mkNumber(1, loc);
	const body = createNode(NodeKind.BlockStmt, { statements: [] }, synthToken(loc));
	const orig = createNode(NodeKind.MatchCase, {
		casePatterns: [pat], caseGuard: null as unknown as Node, caseBody: body,
	}, synthToken(loc));
	const val = nodeToValue(orig, objH, arrH);
	const back = valueToNode(val, objH, arrH, loc);
	assert back.kind === NodeKind.MatchCase;
	const d = back.data as MatchCaseData;
	assert d.caseGuard === null;
}
