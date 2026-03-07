// Pointer Parameter Transform — standard reference introduction pattern
//
// Implements standard reference pattern: struct (interface) params are passed
// by pointer in C. This transform rewrites the AST so codegen stays dumb:
//
//   1. Function prototype: param type T → Ptr<T> (codegen emits T*)
//   2. Function body: param identifier uses → HiddenDeref(param) (codegen emits (*param))
//   3. Call sites: arg for pointer param → HiddenAddr(arg) (codegen emits &(arg))
//
// Reference: standard optimized C codegen patterns for struct parameters

import {
	Node, NodeKind,
	FunctionDeclData, CallExprData, IdentifierData,
	BlockStmtData, IfStmtData, WhileStmtData,
	ReturnStmtData, ExprStmtData, BinaryExprData,
	VariableDeclData, ForOfStmtData, ForStmtData,
	DoWhileStmtData, TryCatchStmtData,
	MemberExprData, ArrayAccessData, UnaryExprData,
	ConditionalExprData, ObjectLiteralData,
	UpdateExprData, SpreadExprData,
	ArrayLiteralData, MoveExprData,
	HiddenDerefData, HiddenStdConvData,
	SourceLocation,
} from "../../ast/node";
import { Type, TypeKind, createPtr, isInterfaceType, getTypeSize } from "../../checker/types";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeHiddenAddr, makeHiddenDeref } from "../util";
import { firstStmtKindAfter, stmtCountAfter, parseInput } from "../testUtil";

const defaultLoc: SourceLocation = { line: 0, column: 0 };

function safeLoc(node: Node): SourceLocation {
	if (node !== null && node.location !== null) return node.location;
	return defaultLoc;
}

// ===== Standard Reference: pointer parameter introduction =====
// Determines if a param type should be passed by pointer in C.
// Nim parity (ccgutils.nim:79-107):
//   tyObject: forwarded → true; size > floatSize*3 → true; final+no base → false; else → true
//   tyTuple: size > floatSize*3 → true
// We don't have inheritance or forwarded types, so all interfaces are "final + no base".
// Threshold: 24 bytes (floatSize=8 * 3) on 64-bit.
const PTR_THRESHOLD: number = 24;

export function ccgIntroducedPtr(t: Type): boolean {
	if (t === null) return false;
	// Nim: tyObject
	if (isInterfaceType(t)) return getTypeSize(t) > PTR_THRESHOLD;
	// Nim: tyTuple — same size threshold
	if (t.kind === TypeKind.Tuple) return getTypeSize(t) > PTR_THRESHOLD;
	// Result/Union/Span — always by pointer (compound types, no Nim equivalent for size check)
	if (t.kind === TypeKind.Result) return true;
	if (t.kind === TypeKind.Union) return true;
	if (t.kind === TypeKind.Span) return true;
	return false;
}

// ===== Main Entry Point =====

export function markPointerParams(program: Node, ctx: TransformContext): Node {
	// Pass 1: Rewrite function declarations — modify param types + insert HiddenDeref in body
	walkNode(program, (node: Node): Node => {
		if (node.kind === NodeKind.FunctionDecl) transformFunction(node);
		return node;
	});
	// Pass 2: Rewrite call sites — insert HiddenAddr for pointer param args
	walkNode(program, (node: Node): Node => {
		if (node.kind === NodeKind.CallExpr) transformCallSite(node);
		return node;
	});
	return program;
}

// ===== Pass 1: Function Declaration =====

function transformFunction(node: Node): void {
	const d = node.data as FunctionDeclData;
	const fnType = node.nodeType;
	if (fnType === null || fnType.typeChildren === null) return;
	if (d.fnBody === null) return;

	// Collect pointer param names
	const ptrParams: string[] = [];
	let i = 0;
	while (i < d.params.length) {
		if (i < fnType.typeChildren.length) {
			const paramType = fnType.typeChildren[i];
			if (ccgIntroducedPtr(paramType)) {
				ptrParams.push(d.params[i]);
				// Wrap param type: T → Ptr<T> so codegen emits T*
				fnType.typeChildren[i] = createPtr(paramType);
			}
		}
		i += 1;
	}

	if (ptrParams.length === 0) return;

	// Also update the symbol's function type (for call-site resolution in Pass 2)
	if (node.resolvedSym !== null && node.resolvedSym.symbolType !== null) {
		const symType = node.resolvedSym.symbolType;
		if (symType.typeChildren !== null) {
			i = 0;
			while (i < d.params.length && i < symType.typeChildren.length) {
				if (ccgIntroducedPtr(symType.typeChildren[i])) {
					symType.typeChildren[i] = createPtr(symType.typeChildren[i]);
				}
				i += 1;
			}
		}
	}

	// Wrap identifier uses of pointer params with HiddenDeref in function body
	wrapBodyIdentifiers(d.fnBody, ptrParams);
}

// Walk the function body and wrap Identifier nodes that match pointer params
// with HiddenDeref. Does NOT recurse into nested FunctionDecl/ArrowFunction
// (those have their own scope).
function wrapBodyIdentifiers(node: Node, ptrParams: string[]): void {
	if (node === null) return;

	match (node.kind) {
		NodeKind.BlockStmt => {
			const d = node.data as BlockStmtData;
			let i = 0;
			while (i < d.statements.length) {
				wrapBodyIdentifiers(d.statements[i], ptrParams);
				i += 1;
			}
		},
		NodeKind.ExprStmt => {
			const d = node.data as ExprStmtData;
			d.expr = wrapExpr(d.expr, ptrParams);
		},
		NodeKind.VariableDecl => {
			const d = node.data as VariableDeclData;
			if (d.initializer !== null) d.initializer = wrapExpr(d.initializer, ptrParams);
		},
		NodeKind.ReturnStmt => {
			const d = node.data as ReturnStmtData;
			if (d.argument !== null) d.argument = wrapExpr(d.argument, ptrParams);
		},
		NodeKind.IfStmt => {
			const d = node.data as IfStmtData;
			d.condition = wrapExpr(d.condition, ptrParams);
			wrapBodyIdentifiers(d.consequent, ptrParams);
			if (d.alternate !== null) wrapBodyIdentifiers(d.alternate, ptrParams);
		},
		NodeKind.WhileStmt => {
			const d = node.data as WhileStmtData;
			d.whileCondition = wrapExpr(d.whileCondition, ptrParams);
			wrapBodyIdentifiers(d.whileBody, ptrParams);
		},
		NodeKind.DoWhileStmt => {
			const d = node.data as DoWhileStmtData;
			d.doCondition = wrapExpr(d.doCondition, ptrParams);
			wrapBodyIdentifiers(d.doBody, ptrParams);
		},
		NodeKind.ForStmt => {
			const d = node.data as ForStmtData;
			if (d.forInit !== null) wrapBodyIdentifiers(d.forInit, ptrParams);
			if (d.forCondition !== null) d.forCondition = wrapExpr(d.forCondition, ptrParams);
			if (d.forUpdate !== null) d.forUpdate = wrapExpr(d.forUpdate, ptrParams);
			wrapBodyIdentifiers(d.forBody, ptrParams);
		},
		NodeKind.ForOfStmt => {
			const d = node.data as ForOfStmtData;
			d.forOfIterable = wrapExpr(d.forOfIterable, ptrParams);
			wrapBodyIdentifiers(d.forOfBody, ptrParams);
		},
		NodeKind.TryCatchStmt => {
			const d = node.data as TryCatchStmtData;
			wrapBodyIdentifiers(d.tryBody, ptrParams);
			if (d.catchBody !== null) wrapBodyIdentifiers(d.catchBody, ptrParams);
			if (d.finallyBody !== null) wrapBodyIdentifiers(d.finallyBody, ptrParams);
		},
		// Do NOT recurse into nested functions — they have their own scope
		NodeKind.FunctionDecl | NodeKind.ArrowFunction | NodeKind.FunctionExpr => {},
		_ => {},
	};
}

// Wrap an expression: if it's an Identifier matching a pointer param, wrap with HiddenDeref.
// For compound expressions, recurse into sub-expressions.
function wrapExpr(node: Node, ptrParams: string[]): Node {
	if (node === null) return node;

	match (node.kind) {
		NodeKind.Identifier => {
			const d = node.data as IdentifierData;
			if (isPtrParam(d.name, ptrParams)) {
				return makeHiddenDeref(node, safeLoc(node));
			}
			return node;
		},
		NodeKind.MemberExpr => {
			const d = node.data as MemberExprData;
			d.object = wrapExpr(d.object, ptrParams);
			return node;
		},
		NodeKind.ArrayAccess => {
			const d = node.data as ArrayAccessData;
			d.array = wrapExpr(d.array, ptrParams);
			d.index = wrapExpr(d.index, ptrParams);
			return node;
		},
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			// Don't wrap the callee if it's a direct function name
			// Only wrap arguments
			let i = 0;
			while (i < d.arguments.length) {
				d.arguments[i] = wrapExpr(d.arguments[i], ptrParams);
				i += 1;
			}
			return node;
		},
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			d.left = wrapExpr(d.left, ptrParams);
			d.right = wrapExpr(d.right, ptrParams);
			return node;
		},
		NodeKind.UnaryExpr => {
			const d = node.data as UnaryExprData;
			d.operand = wrapExpr(d.operand, ptrParams);
			return node;
		},
		NodeKind.UpdateExpr => {
			const d = node.data as UpdateExprData;
			d.updateArg = wrapExpr(d.updateArg, ptrParams);
			return node;
		},
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			d.ternaryCondition = wrapExpr(d.ternaryCondition, ptrParams);
			d.ternaryConsequent = wrapExpr(d.ternaryConsequent, ptrParams);
			d.ternaryAlternate = wrapExpr(d.ternaryAlternate, ptrParams);
			return node;
		},
		NodeKind.ObjectLiteral => {
			const d = node.data as ObjectLiteralData;
			let i = 0;
			while (i < d.properties.length) {
				d.properties[i] = wrapExpr(d.properties[i], ptrParams);
				i += 1;
			}
			return node;
		},
		NodeKind.ArrayLiteral => {
			const d = node.data as ArrayLiteralData;
			let i = 0;
			while (i < d.elements.length) {
				d.elements[i] = wrapExpr(d.elements[i], ptrParams);
				i += 1;
			}
			return node;
		},
		NodeKind.SpreadExpr => {
			const d = node.data as SpreadExprData;
			d.spreadArg = wrapExpr(d.spreadArg, ptrParams);
			return node;
		},
		NodeKind.MoveExpr => {
			const d = node.data as MoveExprData;
			d.moveArg = wrapExpr(d.moveArg, ptrParams);
			return node;
		},
		NodeKind.HiddenDeref => {
			const d = node.data as HiddenDerefData;
			d.expr = wrapExpr(d.expr, ptrParams);
			return node;
		},
		NodeKind.HiddenAddr => {
			const d = node.data as ExprStmtData;
			d.expr = wrapExpr(d.expr, ptrParams);
			return node;
		},
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => {
			const d = node.data as HiddenStdConvData;
			d.convExpr = wrapExpr(d.convExpr, ptrParams);
			return node;
		},
		_ => { return node; },
	};
}

function isPtrParam(name: string, ptrParams: string[]): boolean {
	let i = 0;
	while (i < ptrParams.length) {
		if (ptrParams[i] === name) return true;
		i += 1;
	}
	return false;
}

// ===== Pass 2: Call Site =====
// At each CallExpr, check the callee's resolved function type.
// For params that are Ptr<T> (introduced by Pass 1), wrap the arg with HiddenAddr.

function transformCallSite(node: Node): void {
	const cd = node.data as CallExprData;

	// Resolve the callee's function type — prefer resolvedSym.symbolType
	let fnType: Type = null as unknown as Type;
	if (cd.callee.resolvedSym !== null && cd.callee.resolvedSym.symbolType !== null) {
		fnType = cd.callee.resolvedSym.symbolType;
	}
	if ((fnType === null || fnType.kind !== TypeKind.Function) && cd.callee.nodeType !== null) {
		fnType = cd.callee.nodeType;
	}
	if (fnType === null || fnType.kind !== TypeKind.Function) return;
	if (fnType.typeChildren === null) return;

	const paramTypes = fnType.typeChildren;
	let i = 0;
	const minLen = (paramTypes.length < cd.arguments.length) ? paramTypes.length : cd.arguments.length;
	while (i < minLen) {
		// If Pass 1 wrapped the param type in Ptr<T>, the arg needs HiddenAddr
		if (paramTypes[i] !== null && paramTypes[i].kind === TypeKind.Ptr) {
			const arg = cd.arguments[i];
			// Don't double-wrap: if already HiddenAddr, skip
			if (arg.kind !== NodeKind.HiddenAddr) {
				cd.arguments[i] = makeHiddenAddr(arg, safeLoc(arg));
			}
		}
		i += 1;
	}
}

// Utility for C codegen: check if a type name is a primitive (value type in C)
export function isPrimitiveTypeName(typeName: string): boolean {
	return match (typeName) {
		"number" | "string" | "boolean" | "void" | "null" | "undefined" | "any" | "unknown" | "never" => true,
		"int8" | "int16" | "int32" | "int64" | "uint8" | "uint16" | "uint32" | "uint64" => true,
		"float32" | "float64" => true,
		_ => false,
	};
}

// ===== Tests =====
test "non-function passthrough" { assert stmtCountAfter("const x = 1;", markPointerParams) === 1; }

test "function stays FunctionDecl" { assert firstStmtKindAfter("function foo() {}", markPointerParams) === NodeKind.FunctionDecl; }

test "stmt count preserved" { assert stmtCountAfter("let a = 1; let b = 2;", markPointerParams) === 2; }

test "isPrimitive number" { assert isPrimitiveTypeName("number"); }

test "isPrimitive string" { assert isPrimitiveTypeName("string"); }

test "isPrimitive boolean" { assert isPrimitiveTypeName("boolean"); }

test "isPrimitive void" { assert isPrimitiveTypeName("void"); }

test "isPrimitive int32" { assert isPrimitiveTypeName("int32"); }

test "isPrimitive float64" { assert isPrimitiveTypeName("float64"); }

test "not primitive Node" { assert !isPrimitiveTypeName("Node"); }

test "not primitive Token" { assert !isPrimitiveTypeName("Token"); }

test "not primitive Array" { assert !isPrimitiveTypeName("Array"); }

test "not primitive empty" { assert !isPrimitiveTypeName(""); }
