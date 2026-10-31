// Const Data Mark — flags an array literal whose every element is deep-constant data.
//
// A literal of constBlobMinElements or more elements made only of numbers, negated
// numbers, booleans, enum members, and structs or tuples of those, is data, not
// code: codegen prints one static initializer and copies it, instead of one store
// per element (a table of thousands of stores breaks the arm64 assembler). Runs
// last in the native tail so the elements are in their final shape.

import { Node, NodeKind, NodeFlag, SymbolKind, SymbolFlag, Type, TypeKind, UnaryExprData, ObjectLiteralData, ArrayLiteralData } from "../../ast/node";
import { isNumeric, storesNothing, fieldTypeView } from "../../checker/types";
import { hasFlag } from "../../checker/symbol";
import { TransformContext } from "../context";
import { walkNode } from "../walker";

const constBlobMinElements = 64;

export function markConstData(program: Node, ctx: TransformContext): Node {
	walkNode(program, markArray);
	return program;
}

function markArray(node: Node): Node {
	if (node.kind != NodeKind.ArrayLiteral || node.nodeType == null) return node;
	const arr = node.nodeType.kind == TypeKind.Ref && node.nodeType.typeReturn != null ? node.nodeType.typeReturn : node.nodeType;
	if (arr.kind != TypeKind.Array && arr.kind != TypeKind.SizedArray) return node;
	const d = node.data as ArrayLiteralData;
	if (d.elements.length < constBlobMinElements || !isConstFieldType(arr.typeReturn)) return node;
	for (const e of d.elements) {
		if (!isConstData(e)) return node;
	}
	node.flags = node.flags.incl(NodeFlag.ConstData);
	return node;
}

function isConstScalar(node: Readonly<Node>): boolean {
	if (node.kind == NodeKind.UnaryExpr) {
		const u = node.data as UnaryExprData;
		return u.unaryOp == "-" && u.operand.kind == NodeKind.NumberLiteral;
	}
	if (node.kind == NodeKind.Identifier) return node.resolvedSym != null && node.resolvedSym.symbolKind == SymbolKind.EnumMember;
	return node.kind == NodeKind.NumberLiteral || node.kind == NodeKind.BooleanLiteral;
}

function isConstFieldType(ft: Readonly<Type | null>): boolean {
	if (ft == null) return false;
	if (isNumeric(ft)) return true;
	const k = ft.kind;
	return k == TypeKind.Boolean || k == TypeKind.Enum || k == TypeKind.Struct || k == TypeKind.Tuple;
}

function isConstData(node: Readonly<Node>): boolean {
	if (node.nodeType == null) return false;
	if (isConstScalar(node)) return true;
	if (node.kind == NodeKind.ArrayLiteral && node.nodeType.kind == TypeKind.Tuple) {
		for (const e of (node.data as ArrayLiteralData).elements) {
			if (!isConstData(e)) return false;
		}
		return true;
	}
	if (node.kind != NodeKind.ObjectLiteral || node.flags.has(NodeFlag.Closure) || node.nodeType.kind != TypeKind.Struct) return false;
	if (node.nodeType.sym != null && hasFlag(node.nodeType.sym, SymbolFlag.ImportC)) return false;
	const owner = node.nodeType;
	const d = node.data as ObjectLiteralData;
	for (let i = 0; i < d.keys.length; i += 1) {
		const ft = fieldTypeView(owner, d.keys[i]);
		if (!isConstFieldType(ft) || storesNothing(owner, ft) || !isConstData(d.properties[i])) return false;
	}
	return true;
}
