// ComptimeEval — Evaluate @comptime blocks via Raiser VM, fold results into AST

import { check } from "std/testing";
import {
	Node, NodeKind, DeclKind, SourceLocation, createNode,
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
	AwaitExprData, YieldExprData, MoveExprData, OutExprData,
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
	TestDeclData, ExpectStmtData,
	// Declarations
	ImportDeclData, ExportDeclData, TypeAliasDeclData, EnumDeclData,
	InterfaceDeclData, ClassDeclData, PropertyDeclData,
	MethodDeclData, ConstructorDeclData,
	ExternDeclData, MacroDeclData, DecoratedDeclData,
	MacroInvocationData, TypeAnnotationData,
	ProgramData,
} from "../ast/node";
import { Token, TokenKind, createToken } from "../lexer/token";
import { parseSource } from "../parser/index";
import { evalASTFull } from "../codegen/raiser/eval";
import {
	RaiserValueKind, RaiserValue,
	RaiserObjectHeap, RaiserArrayHeap,
	heapArrayGet, heapArrayLen,
	raiserInt, raiserFloat, raiserBool, raiserString, raiserNil, raiserObject, raiserArray,
	heapAllocObject, heapObjectSetField, heapObjectGetField,
	heapAllocArray, heapArrayPush,
	createObjectHeap, createArrayHeap,
	clearObjectHeap, clearArrayHeap,
} from "../raiser/value";
import { RaiserContext } from "../raiser/context";

// --- Node builders (inlined to avoid import graph issues with transform/util) ---

function synthToken(loc: SourceLocation): Token {
	return createToken(TokenKind.Ident, "", loc.line);
}

function mkNumber(val: number, loc: SourceLocation): Node {
	return createNode(NodeKind.NumberLiteral, { value: val }, synthToken(loc));
}

function mkString(val: string, loc: SourceLocation): Node {
	return createNode(NodeKind.StringLiteral, { value: val }, synthToken(loc));
}

function mkBool(val: boolean, loc: SourceLocation): Node {
	return createNode(NodeKind.BooleanLiteral, { boolValue: val }, synthToken(loc));
}

function mkNull(loc: SourceLocation): Node {
	return createNode(NodeKind.NullLiteral, { nullPlaceholder: true }, synthToken(loc));
}

// --- RaiserValue → AST Node conversion ---

function valueToNode(val: RaiserValue, objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap, loc: SourceLocation): Node {
	if (val.kind === RaiserValueKind.Int) {
		return mkNumber(val.intVal, loc);
	} else if (val.kind === RaiserValueKind.Float) {
		return mkNumber(val.floatVal, loc);
	} else if (val.kind === RaiserValueKind.Bool) {
		return mkBool(val.intVal !== 0, loc);
	} else if (val.kind === RaiserValueKind.String) {
		return mkString(val.strVal, loc);
	} else if (val.kind === RaiserValueKind.Nil) {
		return mkNull(loc);
	} else if (val.kind === RaiserValueKind.Array) {
		const handle = val.intVal;
		const len = heapArrayLen(arrHeap, handle);
		const elements: Node[] = [];
		let i = 0;
		while (i < len) {
			const elem = heapArrayGet(arrHeap, handle, i);
			const elemNode = valueToNode(elem, objHeap, arrHeap, loc);
			elements.push(elemNode);
			i = i + 1;
		}
		return createNode(NodeKind.ArrayLiteral, { elements }, synthToken(loc));
	} else if (val.kind === RaiserValueKind.Object) {
		const handle = val.intVal;
		const obj = objHeap.objects[handle];
		const keys: string[] = [];
		const values: Node[] = [];
		let i = 0;
		while (i < obj.fields.length) {
			const fieldName = obj.fields[i].name;
			const fieldVal = obj.fields[i].value;
			keys.push(fieldName);
			const valNode = valueToNode(fieldVal, objHeap, arrHeap, loc);
			values.push(valNode);
			i = i + 1;
		}
		return createNode(NodeKind.ObjectLiteral, { properties: values, keys }, synthToken(loc));
	}
	return mkNull(loc);
}

// --- AST Node → RaiserValue serialization ---
// Each Node becomes an Object on the heap with fields: kind, line, column, + kind-specific data.

// Helper: serialize Node[] as RaiserArray of objects
function serializeNodes(nodes: Node[], objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap): RaiserValue {
	const handle = heapAllocArray(arrHeap);
	let i = 0;
	while (i < nodes.length) {
		const v = nodeToValue(nodes[i], objHeap, arrHeap);
		heapArrayPush(arrHeap, handle, v);
		i = i + 1;
	}
	return raiserArray(handle);
}

// Helper: serialize string[] as RaiserArray of strings
function serializeStrings(strs: string[], arrHeap: RaiserArrayHeap): RaiserValue {
	const handle = heapAllocArray(arrHeap);
	let i = 0;
	while (i < strs.length) {
		const v = raiserString(strs[i]);
		heapArrayPush(arrHeap, handle, v);
		i = i + 1;
	}
	return raiserArray(handle);
}

// Helper: set a string field on a heap object
function setStr(objHeap: RaiserObjectHeap, h: number, name: string, val: string): void {
	const v = raiserString(val);
	heapObjectSetField(objHeap, h, name, v);
}

// Helper: set a bool field on a heap object
function setBool(objHeap: RaiserObjectHeap, h: number, name: string, val: boolean): void {
	const v = raiserBool(val);
	heapObjectSetField(objHeap, h, name, v);
}

// Helper: set a Node field (recurse)
function setNode(objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap, h: number, name: string, child: Node): void {
	const v = nodeToValue(child, objHeap, arrHeap);
	heapObjectSetField(objHeap, h, name, v);
}

// Helper: set a Node[] field (serialize as array)
function setNodes(objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap, h: number, name: string, children: Node[]): void {
	const v = serializeNodes(children, objHeap, arrHeap);
	heapObjectSetField(objHeap, h, name, v);
}

// Helper: set a string[] field (serialize as array)
function setStrs(objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap, h: number, name: string, strs: string[]): void {
	const v = serializeStrings(strs, arrHeap);
	heapObjectSetField(objHeap, h, name, v);
}

function nodeToValue(node: Node, objHeap: RaiserObjectHeap, arrHeap: RaiserArrayHeap): RaiserValue {
	const handle = heapAllocObject(objHeap);
	// Common fields: kind, line, column
	const kindVal = raiserInt(node.kind as number);
	heapObjectSetField(objHeap, handle, "kind", kindVal);
	const lineVal = raiserInt(node.location.line);
	heapObjectSetField(objHeap, handle, "line", lineVal);
	const colVal = raiserInt(node.location.column);
	heapObjectSetField(objHeap, handle, "column", colVal);

	// === Literals ===
	if (node.kind === NodeKind.NumberLiteral) {
		const d = node.data as NumberLiteralData;
		const v = raiserFloat(d.value);
		heapObjectSetField(objHeap, handle, "value", v);
	} else if (node.kind === NodeKind.StringLiteral) {
		const d = node.data as StringLiteralData;
		setStr(objHeap, handle, "value", d.value);
	} else if (node.kind === NodeKind.BooleanLiteral) {
		const d = node.data as BooleanLiteralData;
		setBool(objHeap, handle, "boolValue", d.boolValue);
	} else if (node.kind === NodeKind.NullLiteral) {
		// kind field is sufficient
	} else if (node.kind === NodeKind.BigIntLiteral) {
		const d = node.data as BigIntLiteralData;
		setStr(objHeap, handle, "bigintValue", d.bigintValue);
	} else if (node.kind === NodeKind.RegexLiteral) {
		const d = node.data as RegexLiteralData;
		setStr(objHeap, handle, "regexPattern", d.regexPattern);

	// === Identifier ===
	} else if (node.kind === NodeKind.Identifier) {
		const d = node.data as IdentifierData;
		setStr(objHeap, handle, "name", d.name);

	// === Binary/Unary/Update ===
	} else if (node.kind === NodeKind.BinaryExpr) {
		const d = node.data as BinaryExprData;
		setStr(objHeap, handle, "operator", d.operator);
		setNode(objHeap, arrHeap, handle, "left", d.left);
		setNode(objHeap, arrHeap, handle, "right", d.right);
	} else if (node.kind === NodeKind.UnaryExpr) {
		const d = node.data as UnaryExprData;
		setStr(objHeap, handle, "unaryOp", d.unaryOp);
		setNode(objHeap, arrHeap, handle, "operand", d.operand);
	} else if (node.kind === NodeKind.UpdateExpr) {
		const d = node.data as UpdateExprData;
		setStr(objHeap, handle, "updateOp", d.updateOp);
		setNode(objHeap, arrHeap, handle, "updateArg", d.updateArg);
		setBool(objHeap, handle, "isPrefix", d.isPrefix);

	// === Call/Member/Access ===
	} else if (node.kind === NodeKind.CallExpr) {
		const d = node.data as CallExprData;
		setNode(objHeap, arrHeap, handle, "callee", d.callee);
		setNodes(objHeap, arrHeap, handle, "arguments", d.arguments);
	} else if (node.kind === NodeKind.MemberExpr) {
		const d = node.data as MemberExprData;
		setNode(objHeap, arrHeap, handle, "object", d.object);
		setStr(objHeap, handle, "property", d.property);
		setBool(objHeap, handle, "isOptional", d.isOptional);
	} else if (node.kind === NodeKind.ArrayAccess) {
		const d = node.data as ArrayAccessData;
		setNode(objHeap, arrHeap, handle, "array", d.array);
		setNode(objHeap, arrHeap, handle, "index", d.index);

	// === Collection literals ===
	} else if (node.kind === NodeKind.ObjectLiteral) {
		const d = node.data as ObjectLiteralData;
		setNodes(objHeap, arrHeap, handle, "properties", d.properties);
		setStrs(objHeap, arrHeap, handle, "keys", d.keys);
	} else if (node.kind === NodeKind.ArrayLiteral) {
		const d = node.data as ArrayLiteralData;
		setNodes(objHeap, arrHeap, handle, "elements", d.elements);

	// === Function expressions ===
	} else if (node.kind === NodeKind.ArrowFunction) {
		const d = node.data as ArrowFunctionData;
		setStrs(objHeap, arrHeap, handle, "arrowParams", d.arrowParams);
		setStrs(objHeap, arrHeap, handle, "arrowParamTypes", d.arrowParamTypes);
		setNode(objHeap, arrHeap, handle, "arrowBody", d.arrowBody);
		setStr(objHeap, handle, "arrowFlags", d.arrowFlags);
		setStr(objHeap, handle, "arrowReturnType", d.arrowReturnType);
	} else if (node.kind === NodeKind.FunctionExpr) {
		const d = node.data as FunctionExprData;
		setStrs(objHeap, arrHeap, handle, "funcExprParams", d.funcExprParams);
		setStrs(objHeap, arrHeap, handle, "funcExprParamTypes", d.funcExprParamTypes);
		setNode(objHeap, arrHeap, handle, "funcExprBody", d.funcExprBody);
		setStr(objHeap, handle, "funcExprFlags", d.funcExprFlags);
		setStr(objHeap, handle, "funcExprReturnType", d.funcExprReturnType);

	// === Other expressions ===
	} else if (node.kind === NodeKind.TypeAssertion) {
		const d = node.data as TypeAssertionData;
		setNode(objHeap, arrHeap, handle, "asExpr", d.asExpr);
		setStr(objHeap, handle, "asType", d.asType);
	} else if (node.kind === NodeKind.ConditionalExpr) {
		const d = node.data as ConditionalExprData;
		setNode(objHeap, arrHeap, handle, "ternaryCondition", d.ternaryCondition);
		setNode(objHeap, arrHeap, handle, "ternaryConsequent", d.ternaryConsequent);
		setNode(objHeap, arrHeap, handle, "ternaryAlternate", d.ternaryAlternate);
	} else if (node.kind === NodeKind.SpreadExpr) {
		const d = node.data as SpreadExprData;
		setNode(objHeap, arrHeap, handle, "spreadArg", d.spreadArg);
	} else if (node.kind === NodeKind.NewExpr) {
		const d = node.data as NewExprData;
		setNode(objHeap, arrHeap, handle, "newCallee", d.newCallee);
		setNodes(objHeap, arrHeap, handle, "newArguments", d.newArguments);
	} else if (node.kind === NodeKind.TryExpr) {
		const d = node.data as TryExprData;
		setNode(objHeap, arrHeap, handle, "tryArg", d.tryArg);
		setBool(objHeap, handle, "hasCatch", d.hasCatch);
		setNode(objHeap, arrHeap, handle, "catchVal", d.catchVal);
	} else if (node.kind === NodeKind.MatchExpr) {
		const d = node.data as MatchExprData;
		setNode(objHeap, arrHeap, handle, "matchDisc", d.matchDisc);
		setNodes(objHeap, arrHeap, handle, "matchCases", d.matchCases);
	} else if (node.kind === NodeKind.MatchCase) {
		const d = node.data as MatchCaseData;
		setNodes(objHeap, arrHeap, handle, "casePatterns", d.casePatterns);
		setNode(objHeap, arrHeap, handle, "caseBody", d.caseBody);
	} else if (node.kind === NodeKind.AwaitExpr) {
		const d = node.data as AwaitExprData;
		setNode(objHeap, arrHeap, handle, "awaitArg", d.awaitArg);
	} else if (node.kind === NodeKind.YieldExpr) {
		const d = node.data as YieldExprData;
		setNode(objHeap, arrHeap, handle, "yieldArg", d.yieldArg);
		setBool(objHeap, handle, "isDelegate", d.isDelegate);
	} else if (node.kind === NodeKind.MoveExpr) {
		const d = node.data as MoveExprData;
		setNode(objHeap, arrHeap, handle, "moveArg", d.moveArg);
	} else if (node.kind === NodeKind.OutExpr) {
		const d = node.data as OutExprData;
		setNode(objHeap, arrHeap, handle, "outArg", d.outArg);
	} else if (node.kind === NodeKind.HiddenDeref) {
		const d = node.data as HiddenDerefData;
		setNode(objHeap, arrHeap, handle, "expr", d.expr);
	} else if (node.kind === NodeKind.QuoteExpr) {
		const d = node.data as QuoteExprData;
		setNode(objHeap, arrHeap, handle, "quoteBody", d.quoteBody);
	} else if (node.kind === NodeKind.ComptimeBlock) {
		const d = node.data as ComptimeBlockData;
		setNode(objHeap, arrHeap, handle, "comptimeBody", d.comptimeBody);
	} else if (node.kind === NodeKind.TypeAnnotation) {
		const d = node.data as TypeAnnotationData;
		setStr(objHeap, handle, "annotationType", d.annotationType);

	// === Patterns ===
	} else if (node.kind === NodeKind.ArrayPattern) {
		const d = node.data as ArrayPatternData;
		setNodes(objHeap, arrHeap, handle, "patternElements", d.patternElements);
		setBool(objHeap, handle, "hasRestElement", d.hasRestElement);
	} else if (node.kind === NodeKind.ObjectPattern) {
		const d = node.data as ObjectPatternData;
		setNodes(objHeap, arrHeap, handle, "patternProps", d.patternProps);
		setBool(objHeap, handle, "hasRestProp", d.hasRestProp);
	} else if (node.kind === NodeKind.ObjectPatternProp) {
		const d = node.data as ObjectPatternPropData;
		setStr(objHeap, handle, "propKey", d.propKey);
		setNode(objHeap, arrHeap, handle, "propAlias", d.propAlias);
	} else if (node.kind === NodeKind.DestructuringDecl) {
		const d = node.data as DestructuringDeclData;
		setNode(objHeap, arrHeap, handle, "destrPattern", d.destrPattern);
		setNode(objHeap, arrHeap, handle, "destrInit", d.destrInit);
		setBool(objHeap, handle, "destrIsConst", d.destrIsConst);

	// === Statements ===
	} else if (node.kind === NodeKind.ExprStmt) {
		const d = node.data as ExprStmtData;
		setNode(objHeap, arrHeap, handle, "expr", d.expr);
	} else if (node.kind === NodeKind.ReturnStmt) {
		const d = node.data as ReturnStmtData;
		setNode(objHeap, arrHeap, handle, "argument", d.argument);
	} else if (node.kind === NodeKind.ThrowStmt) {
		const d = node.data as ThrowStmtData;
		setNode(objHeap, arrHeap, handle, "throwArg", d.throwArg);
	} else if (node.kind === NodeKind.DeferStmt) {
		const d = node.data as DeferStmtData;
		setNode(objHeap, arrHeap, handle, "deferExpr", d.deferExpr);
	} else if (node.kind === NodeKind.BlockStmt) {
		const d = node.data as BlockStmtData;
		setNodes(objHeap, arrHeap, handle, "statements", d.statements);
	} else if (node.kind === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		setStr(objHeap, handle, "declName", d.declName);
		setStr(objHeap, handle, "declType", d.declType);
		setNode(objHeap, arrHeap, handle, "initializer", d.initializer);
		const dk = raiserInt(d.declKind as number);
		heapObjectSetField(objHeap, handle, "declKind", dk);
	} else if (node.kind === NodeKind.IfStmt) {
		const d = node.data as IfStmtData;
		setNode(objHeap, arrHeap, handle, "condition", d.condition);
		setNode(objHeap, arrHeap, handle, "consequent", d.consequent);
		setNode(objHeap, arrHeap, handle, "alternate", d.alternate);
	} else if (node.kind === NodeKind.WhileStmt) {
		const d = node.data as WhileStmtData;
		setNode(objHeap, arrHeap, handle, "whileCondition", d.whileCondition);
		setNode(objHeap, arrHeap, handle, "whileBody", d.whileBody);
	} else if (node.kind === NodeKind.DoWhileStmt) {
		const d = node.data as DoWhileStmtData;
		setNode(objHeap, arrHeap, handle, "doBody", d.doBody);
		setNode(objHeap, arrHeap, handle, "doCondition", d.doCondition);
	} else if (node.kind === NodeKind.ForStmt) {
		const d = node.data as ForStmtData;
		setNode(objHeap, arrHeap, handle, "forInit", d.forInit);
		setNode(objHeap, arrHeap, handle, "forCondition", d.forCondition);
		setNode(objHeap, arrHeap, handle, "forUpdate", d.forUpdate);
		setNode(objHeap, arrHeap, handle, "forBody", d.forBody);
	} else if (node.kind === NodeKind.ForOfStmt) {
		const d = node.data as ForOfStmtData;
		setStr(objHeap, handle, "forOfBinding", d.forOfBinding);
		setBool(objHeap, handle, "forOfIsConst", d.forOfIsConst);
		setNode(objHeap, arrHeap, handle, "forOfIterable", d.forOfIterable);
		setNode(objHeap, arrHeap, handle, "forOfBody", d.forOfBody);
	} else if (node.kind === NodeKind.ForInStmt) {
		const d = node.data as ForInStmtData;
		setStr(objHeap, handle, "forInBinding", d.forInBinding);
		setBool(objHeap, handle, "forInIsConst", d.forInIsConst);
		setNode(objHeap, arrHeap, handle, "forInObject", d.forInObject);
		setNode(objHeap, arrHeap, handle, "forInBody", d.forInBody);
	} else if (node.kind === NodeKind.BreakStmt) {
		const d = node.data as BreakStmtData;
		setStr(objHeap, handle, "breakLabel", d.breakLabel);
	} else if (node.kind === NodeKind.ContinueStmt) {
		const d = node.data as ContinueStmtData;
		setStr(objHeap, handle, "continueLabel", d.continueLabel);
	} else if (node.kind === NodeKind.UnreachableStmt) {
		const d = node.data as UnreachableStmtData;
		setStr(objHeap, handle, "unreachableMsg", d.unreachableMsg);
	} else if (node.kind === NodeKind.SwitchStmt) {
		const d = node.data as SwitchStmtData;
		setNode(objHeap, arrHeap, handle, "switchDisc", d.switchDisc);
		setNodes(objHeap, arrHeap, handle, "switchCases", d.switchCases);
	} else if (node.kind === NodeKind.SwitchCase) {
		const d = node.data as SwitchCaseData;
		setNodes(objHeap, arrHeap, handle, "caseTests", d.caseTests);
		setNodes(objHeap, arrHeap, handle, "caseStmts", d.caseStmts);
		setBool(objHeap, handle, "isDefault", d.isDefault);
	} else if (node.kind === NodeKind.MatchStmt) {
		const d = node.data as MatchStmtData;
		setNode(objHeap, arrHeap, handle, "matchStmtDisc", d.matchStmtDisc);
		setNodes(objHeap, arrHeap, handle, "matchStmtCases", d.matchStmtCases);
	} else if (node.kind === NodeKind.TryCatchStmt) {
		const d = node.data as TryCatchStmtData;
		setNode(objHeap, arrHeap, handle, "tryBody", d.tryBody);
		setStr(objHeap, handle, "catchName", d.catchName);
		setNode(objHeap, arrHeap, handle, "catchBody", d.catchBody);
		setNode(objHeap, arrHeap, handle, "finallyBody", d.finallyBody);

	// === Declarations ===
	} else if (node.kind === NodeKind.FunctionDecl) {
		const d = node.data as FunctionDeclData;
		setStr(objHeap, handle, "fnName", d.fnName);
		setStrs(objHeap, arrHeap, handle, "params", d.params);
		setStrs(objHeap, arrHeap, handle, "fnParamTypes", d.fnParamTypes);
		setNode(objHeap, arrHeap, handle, "fnBody", d.fnBody);
		setStr(objHeap, handle, "fnFlags", d.fnFlags);
		setStr(objHeap, handle, "fnReturnType", d.fnReturnType);
	} else if (node.kind === NodeKind.ImportDecl) {
		const d = node.data as ImportDeclData;
		setStrs(objHeap, arrHeap, handle, "importNames", d.importNames);
		setStrs(objHeap, arrHeap, handle, "importAliases", d.importAliases);
		setStr(objHeap, handle, "importSource", d.importSource);
	} else if (node.kind === NodeKind.ExportDecl) {
		const d = node.data as ExportDeclData;
		setNode(objHeap, arrHeap, handle, "exportedDecl", d.exportedDecl);
	} else if (node.kind === NodeKind.TypeAliasDecl) {
		const d = node.data as TypeAliasDeclData;
		setStr(objHeap, handle, "aliasName", d.aliasName);
		setStr(objHeap, handle, "aliasType", d.aliasType);
		setBool(objHeap, handle, "aliasIsDistinct", d.aliasIsDistinct);
	} else if (node.kind === NodeKind.EnumDecl) {
		const d = node.data as EnumDeclData;
		setStr(objHeap, handle, "enumName", d.enumName);
		setStrs(objHeap, arrHeap, handle, "enumMembers", d.enumMembers);
	} else if (node.kind === NodeKind.InterfaceDecl) {
		const d = node.data as InterfaceDeclData;
		setStr(objHeap, handle, "interfaceName", d.interfaceName);
		setStrs(objHeap, arrHeap, handle, "interfaceFields", d.interfaceFields);
		setStrs(objHeap, arrHeap, handle, "interfaceFieldTypes", d.interfaceFieldTypes);
	} else if (node.kind === NodeKind.ClassDecl) {
		const d = node.data as ClassDeclData;
		setStr(objHeap, handle, "className", d.className);
		setStr(objHeap, handle, "classExtends", d.classExtends);
		setNodes(objHeap, arrHeap, handle, "classBody", d.classBody);
	} else if (node.kind === NodeKind.PropertyDecl) {
		const d = node.data as PropertyDeclData;
		setStr(objHeap, handle, "propName", d.propName);
		setStr(objHeap, handle, "propType", d.propType);
		setBool(objHeap, handle, "propIsStatic", d.propIsStatic);
	} else if (node.kind === NodeKind.MethodDecl) {
		const d = node.data as MethodDeclData;
		setStr(objHeap, handle, "methodName", d.methodName);
		setStrs(objHeap, arrHeap, handle, "methodParams", d.methodParams);
		setStrs(objHeap, arrHeap, handle, "methodParamTypes", d.methodParamTypes);
		setNode(objHeap, arrHeap, handle, "methodBody", d.methodBody);
		setBool(objHeap, handle, "methodIsStatic", d.methodIsStatic);
		setStr(objHeap, handle, "methodFlags", d.methodFlags);
		setStr(objHeap, handle, "methodReturnType", d.methodReturnType);
	} else if (node.kind === NodeKind.ConstructorDecl) {
		const d = node.data as ConstructorDeclData;
		setStrs(objHeap, arrHeap, handle, "ctorParams", d.ctorParams);
		setStrs(objHeap, arrHeap, handle, "ctorParamTypes", d.ctorParamTypes);
		setNode(objHeap, arrHeap, handle, "ctorBody", d.ctorBody);
	} else if (node.kind === NodeKind.ExternDecl) {
		const d = node.data as ExternDeclData;
		setStr(objHeap, handle, "externKind", d.externKind);
		setStr(objHeap, handle, "externName", d.externName);
	} else if (node.kind === NodeKind.MacroDecl) {
		const d = node.data as MacroDeclData;
		setStr(objHeap, handle, "macroDeclName", d.macroDeclName);
		setStrs(objHeap, arrHeap, handle, "macroDeclParams", d.macroDeclParams);
		setNode(objHeap, arrHeap, handle, "macroDeclBody", d.macroDeclBody);
	} else if (node.kind === NodeKind.DecoratedDecl) {
		const d = node.data as DecoratedDeclData;
		setNodes(objHeap, arrHeap, handle, "decorators", d.decorators);
		setNode(objHeap, arrHeap, handle, "decoratedNode", d.decoratedNode);
	} else if (node.kind === NodeKind.MacroInvocation) {
		const d = node.data as MacroInvocationData;
		setStr(objHeap, handle, "macroName", d.macroName);
		setNodes(objHeap, arrHeap, handle, "macroArgs", d.macroArgs);

	// === Testing ===
	} else if (node.kind === NodeKind.TestDecl) {
		const d = node.data as TestDeclData;
		setStr(objHeap, handle, "testName", d.testName);
		setNode(objHeap, arrHeap, handle, "testBody", d.testBody);
	} else if (node.kind === NodeKind.ExpectStmt) {
		const d = node.data as ExpectStmtData;
		setNode(objHeap, arrHeap, handle, "expectExpr", d.expectExpr);

	// === Program ===
	} else if (node.kind === NodeKind.Program) {
		const d = node.data as ProgramData;
		setNodes(objHeap, arrHeap, handle, "programStmts", d.programStmts);
	}
	// Any unrecognized kind: kind/line/column only

	return raiserObject(handle);
}

// --- Evaluate a single ComptimeBlock node ---

function evalComptimeBlock(node: Node): Node {
	const d = node.data as ComptimeBlockData;
	const body = d.comptimeBody;
	const loc = node.location;

	// Extract statements from the body block
	const bodyData = body.data as BlockStmtData;
	const stmts = bodyData.statements;

	// Transform last ExprStmt into ReturnStmt so the VM captures the value
	// (standard comptime/REPL semantics — implicit return of last expression)
	const finalStmts: Node[] = [];
	let si = 0;
	while (si < stmts.length) {
		if (si === stmts.length - 1 && stmts[si].kind === NodeKind.ExprStmt) {
			const ed = stmts[si].data as ExprStmtData;
			finalStmts.push(createNode(NodeKind.ReturnStmt, { argument: ed.expr }, synthToken(loc)));
		} else {
			finalStmts.push(stmts[si]);
		}
		si = si + 1;
	}

	// Wrap in a synthetic Program node for the Raiser pipeline
	const program = createNode(NodeKind.Program, { programStmts: finalStmts }, synthToken(loc));

	// Evaluate through the Raiser VM
	let ctx = evalASTFull(program);

	// Convert VM result back to an AST literal
	const result = valueToNode(ctx.lastResult, ctx.objectHeap, ctx.arrayHeap, loc);

	// Reclaim VM heaps — prevents monotonic growth during long builds
	clearObjectHeap(ctx.objectHeap);
	clearArrayHeap(ctx.arrayHeap);
	ctx = null as unknown as RaiserContext;

	return result;
}

// --- First pass: check if AST contains any ComptimeBlock nodes ---

function hasComptimeBlock(node: Node): boolean {
	if (node.kind === NodeKind.ComptimeBlock) return true;
	if (node.kind === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		return hasComptimeBlock(d.initializer);
	} else if (node.kind === NodeKind.ExprStmt) {
		const d = node.data as ExprStmtData;
		return hasComptimeBlock(d.expr);
	} else if (node.kind === NodeKind.ReturnStmt) {
		const d = node.data as ReturnStmtData;
		return hasComptimeBlock(d.argument);
	} else if (node.kind === NodeKind.BlockStmt) {
		const d = node.data as BlockStmtData;
		let i = 0;
		while (i < d.statements.length) {
			if (hasComptimeBlock(d.statements[i])) return true;
			i = i + 1;
		}
	} else if (node.kind === NodeKind.ExportDecl) {
		const d = node.data as ExportDeclData;
		return hasComptimeBlock(d.exportedDecl);
	} else if (node.kind === NodeKind.FunctionDecl) {
		const d = node.data as FunctionDeclData;
		return hasComptimeBlock(d.fnBody);
	} else if (node.kind === NodeKind.Program) {
		const d = node.data as ProgramData;
		let i = 0;
		while (i < d.programStmts.length) {
			if (hasComptimeBlock(d.programStmts[i])) return true;
			i = i + 1;
		}
	}
	return false;
}

// --- AST walker — find and replace ComptimeBlock nodes ---
// Uses if-else (not match) to avoid DRC workaround #24.

function walkNode(node: Node): Node {
	if (node.kind === NodeKind.ComptimeBlock) {
		return evalComptimeBlock(node);
	} else if (node.kind === NodeKind.VariableDecl) {
		const d = node.data as VariableDeclData;
		const newInit = walkNode(d.initializer);
		return createNode(NodeKind.VariableDecl, {
			declName: d.declName, declType: d.declType,
			initializer: newInit, declKind: d.declKind,
		}, synthToken(node.location));
	} else if (node.kind === NodeKind.ExprStmt) {
		const d = node.data as ExprStmtData;
		const newExpr = walkNode(d.expr);
		return createNode(NodeKind.ExprStmt, { expr: newExpr }, synthToken(node.location));
	} else if (node.kind === NodeKind.ReturnStmt) {
		const d = node.data as ReturnStmtData;
		const newArg = walkNode(d.argument);
		return createNode(NodeKind.ReturnStmt, { argument: newArg }, synthToken(node.location));
	} else if (node.kind === NodeKind.BlockStmt) {
		const d = node.data as BlockStmtData;
		const newStmts: Node[] = [];
		let i = 0;
		while (i < d.statements.length) {
			newStmts.push(walkNode(d.statements[i]));
			i = i + 1;
		}
		return createNode(NodeKind.BlockStmt, { statements: newStmts }, synthToken(node.location));
	} else if (node.kind === NodeKind.FunctionDecl) {
		const d = node.data as FunctionDeclData;
		const newBody = walkNode(d.fnBody);
		return createNode(NodeKind.FunctionDecl, {
			fnName: d.fnName, params: d.params, fnParamTypes: d.fnParamTypes,
			fnBody: newBody, fnFlags: d.fnFlags, fnReturnType: d.fnReturnType,
		}, synthToken(node.location));
	} else if (node.kind === NodeKind.IfStmt) {
		const d = node.data as IfStmtData;
		const newCons = walkNode(d.consequent);
		const newAlt = walkNode(d.alternate);
		return createNode(NodeKind.IfStmt, {
			condition: d.condition, consequent: newCons, alternate: newAlt,
		}, synthToken(node.location));
	} else if (node.kind === NodeKind.WhileStmt) {
		const d = node.data as WhileStmtData;
		const newBody = walkNode(d.whileBody);
		return createNode(NodeKind.WhileStmt, {
			whileCondition: d.whileCondition, whileBody: newBody,
		}, synthToken(node.location));
	} else if (node.kind === NodeKind.ExportDecl) {
		const d = node.data as ExportDeclData;
		const newDecl = walkNode(d.exportedDecl);
		return createNode(NodeKind.ExportDecl, { exportedDecl: newDecl }, synthToken(node.location));
	} else if (node.kind === NodeKind.Program) {
		const d = node.data as ProgramData;
		const newStmts: Node[] = [];
		let i = 0;
		while (i < d.programStmts.length) {
			newStmts.push(walkNode(d.programStmts[i]));
			i = i + 1;
		}
		return createNode(NodeKind.Program, { programStmts: newStmts }, synthToken(node.location));
	}
	return node;
}

// --- Public API ---

export function evaluateComptimeBlocks(program: Node): Node {
	if (!hasComptimeBlock(program)) return program;
	return walkNode(program);
}

// --- Tests ---
test "int value" {
	const ctx = evalASTFull(createNode(NodeKind.Program, {
		programStmts: [
			createNode(NodeKind.ReturnStmt, {
				argument: createNode(NodeKind.NumberLiteral, { value: 42 }, createToken(TokenKind.Number, "42", 1)),
			}, createToken(TokenKind.Return, "return", 1)),
		],
	}, createToken(TokenKind.Ident, "", 1)));
	const loc: SourceLocation = { line: 1, column: 0 };
	const result = valueToNode(ctx.lastResult, ctx.objectHeap, ctx.arrayHeap, loc);
	check(result.kind === NodeKind.NumberLiteral);
}

test "NumberLiteral serialization" {
	const objHeap = createObjectHeap();
	const arrHeap = createArrayHeap();
	const loc: SourceLocation = { line: 5, column: 10 };
	const node = mkNumber(42, loc);
	const val = nodeToValue(node, objHeap, arrHeap);
	check(val.kind === RaiserValueKind.Object);
	// Verify kind field
	const kindVal = heapObjectGetField(objHeap, val.intVal, "kind");
	check(kindVal.intVal === (NodeKind.NumberLiteral as number));
	// Verify value field
	const numVal = heapObjectGetField(objHeap, val.intVal, "value");
	check(numVal.floatVal === 42);
	// Verify location
	const lineVal = heapObjectGetField(objHeap, val.intVal, "line");
	check(lineVal.intVal === 5);
}

test "StringLiteral serialization" {
	const objHeap = createObjectHeap();
	const arrHeap = createArrayHeap();
	const loc: SourceLocation = { line: 1, column: 0 };
	const node = mkString("hello", loc);
	const val = nodeToValue(node, objHeap, arrHeap);
	check(val.kind === RaiserValueKind.Object);
	const kindVal = heapObjectGetField(objHeap, val.intVal, "kind");
	check(kindVal.intVal === (NodeKind.StringLiteral as number));
	const strVal = heapObjectGetField(objHeap, val.intVal, "value");
	check(strVal.strVal === "hello");
}

test "BooleanLiteral serialization" {
	const objHeap = createObjectHeap();
	const arrHeap = createArrayHeap();
	const loc: SourceLocation = { line: 1, column: 0 };
	const node = mkBool(true, loc);
	const val = nodeToValue(node, objHeap, arrHeap);
	check(val.kind === RaiserValueKind.Object);
	const kindVal = heapObjectGetField(objHeap, val.intVal, "kind");
	check(kindVal.intVal === (NodeKind.BooleanLiteral as number));
	const bVal = heapObjectGetField(objHeap, val.intVal, "boolValue");
	check(bVal.intVal === 1);
}

test "Identifier serialization" {
	const objHeap = createObjectHeap();
	const arrHeap = createArrayHeap();
	const loc: SourceLocation = { line: 1, column: 0 };
	const node = createNode(NodeKind.Identifier, { name: "foo" }, synthToken(loc));
	const val = nodeToValue(node, objHeap, arrHeap);
	check(val.kind === RaiserValueKind.Object);
	const kindVal = heapObjectGetField(objHeap, val.intVal, "kind");
	check(kindVal.intVal === (NodeKind.Identifier as number));
	const nameVal = heapObjectGetField(objHeap, val.intVal, "name");
	check(nameVal.strVal === "foo");
}

test "BinaryExpr serialization" {
	const objHeap = createObjectHeap();
	const arrHeap = createArrayHeap();
	const loc: SourceLocation = { line: 1, column: 0 };
	const left = mkNumber(2, loc);
	const right = mkNumber(3, loc);
	const binNode = createNode(NodeKind.BinaryExpr, {
		operator: "+", left, right,
	}, synthToken(loc));
	const val = nodeToValue(binNode, objHeap, arrHeap);
	check(val.kind === RaiserValueKind.Object);
	// Verify operator
	const opVal = heapObjectGetField(objHeap, val.intVal, "operator");
	check(opVal.strVal === "+");
	// Verify left child is an object
	const leftVal = heapObjectGetField(objHeap, val.intVal, "left");
	check(leftVal.kind === RaiserValueKind.Object);
	// Verify left child kind is NumberLiteral
	const leftKind = heapObjectGetField(objHeap, leftVal.intVal, "kind");
	check(leftKind.intVal === (NodeKind.NumberLiteral as number));
	// Verify right child
	const rightVal = heapObjectGetField(objHeap, val.intVal, "right");
	check(rightVal.kind === RaiserValueKind.Object);
	const rightKind = heapObjectGetField(objHeap, rightVal.intVal, "kind");
	check(rightKind.intVal === (NodeKind.NumberLiteral as number));
}

// --- E2E Comptime Tests ---

test "comptime int arithmetic" {
	const pr = parseSource("const VERSION = @comptime { 10 + 5 };");
	check(pr.ok);
	const result = evaluateComptimeBlocks(pr.value);
	const pd = result.data as ProgramData;
	const varDecl = pd.programStmts[0];
	check(varDecl.kind === NodeKind.VariableDecl);
	const vd = varDecl.data as VariableDeclData;
	check(vd.initializer.kind === NodeKind.NumberLiteral);
	const nd = vd.initializer.data as NumberLiteralData;
	check(nd.value === 15);
}

test "comptime string" {
	const pr = parseSource("const PLATFORM = @comptime { \"darwin\" };");
	check(pr.ok);
	const result = evaluateComptimeBlocks(pr.value);
	const pd = result.data as ProgramData;
	const varDecl = pd.programStmts[0];
	const vd = varDecl.data as VariableDeclData;
	check(vd.initializer.kind === NodeKind.StringLiteral);
	const sd = vd.initializer.data as StringLiteralData;
	check(sd.value === "darwin");
}

test "comptime boolean" {
	const pr = parseSource("const DEBUG = @comptime { true };");
	check(pr.ok);
	const result = evaluateComptimeBlocks(pr.value);
	const pd = result.data as ProgramData;
	const varDecl = pd.programStmts[0];
	const vd = varDecl.data as VariableDeclData;
	check(vd.initializer.kind === NodeKind.BooleanLiteral);
	const bd = vd.initializer.data as BooleanLiteralData;
	check(bd.boolValue === true);
}

test "no comptime passes through" {
	const pr = parseSource("const x = 42;");
	check(pr.ok);
	const result = evaluateComptimeBlocks(pr.value);
	check(result === pr.value);
}
