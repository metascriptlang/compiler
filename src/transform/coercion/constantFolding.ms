// Constant Folding — compile-time evaluation of constant expressions
// Follows the standard reference implementation (constant folding)
//
// Folds:
//   2 + 3           → 5
//   "a" + "b"       → "ab"
//   !true            → false
//   5 > 3            → true
//
// Does NOT fold:
//   x + y            — non-constant operands
//   1 / 0            — division by zero (runtime)
//   "a" + 1          — mixed types

import {
	Node, NodeKind, SourceLocation, DeclKind, SymbolKind, SymbolFlag, Type, TypeKind, createNode,
	BinaryExprData, UnaryExprData, MemberExprData, VariableDeclData, PropertyDeclData, TypeAssertionData, HiddenStdConvData,
	NumberLiteralData, StringLiteralData, BooleanLiteralData,
} from "../../ast/node";
import { isIntegerType, isFloatType } from "../../checker/types";
import { TransformContext } from "../context";
import { walkNode } from "../walker";
import { makeNumber, makeIntNumber, makeString, makeBool, syntheticToken } from "../util";
import { firstExprKindAfter } from "../testUtil";

// ===== Main Entry Point =====

export function lowerConstFold(program: Node, ctx: TransformContext): Node {
	walkNode(program, foldNode);
	return program;
}

function foldNode(node: Node): Node {
	return match (node.kind) {
		NodeKind.BinaryExpr => foldBinary(node),
		NodeKind.UnaryExpr => foldUnary(node),
		NodeKind.MemberExpr => foldMember(node),
		NodeKind.Identifier => foldConstantExpression(node),
		NodeKind.TypeAssertion => foldConstantExpression(node),
		NodeKind.HiddenStdConv => foldConstantExpression(node),
		_ => node,
	};
}


const CONSTANT_CHAIN_LIMIT: int32 = 64;

function foldConstantExpression(node: Node): Node {
	const literal = constantLiteralOf(node, 0);
	return literal != null ? literal : node;
}

function isInlineConstantType(t: Type | null): boolean {
	if (t == null) return false;
	return isIntegerType(t) || isFloatType(t) || t.kind == TypeKind.Number || t.kind == TypeKind.Boolean;
}

function moduleConstInitializer(node: Node): Node {
	const none = null as unknown as Node;
	const sym = node.resolvedSym;
	if (sym == null || sym.symbolKind != SymbolKind.Variable) return none;
	if (!sym.symFlags.has(SymbolFlag.Global) || sym.symFlags.has(SymbolFlag.Mutable)) return none;
	const decl = sym.declNode;
	if (decl == null || decl.kind != NodeKind.VariableDecl) return none;
	if (!isInlineConstantType(decl.nodeType)) return none;
	const d = decl.data as VariableDeclData;
	if (d.declKind != DeclKind.Const || d.initializer == null) return none;
	return d.initializer;
}
function readonlyStaticInitializer(node: Node): Node {
	const none = null as unknown as Node;
	const sym = node.resolvedSym;
	if (sym == null || !sym.symFlags.has(SymbolFlag.Static) || sym.symFlags.has(SymbolFlag.Mutable)) return none;
	const decl = sym.declNode;
	if (decl == null || decl.kind != NodeKind.PropertyDecl || !isInlineConstantType(decl.nodeType)) return none;
	const d = decl.data as PropertyDeclData;
	if (!d.propIsStatic || !d.propIsReadonly || d.propInitializer == null) return none;
	return d.propInitializer;
}


function enumMemberOrdinal(expr: Node): int64 {
	if (expr == null || expr.kind != NodeKind.Identifier || expr.nodeType == null) return -1;
	const sym = expr.resolvedSym;
	if (sym == null || sym.symbolKind != SymbolKind.EnumMember) return -1;
	const t = expr.nodeType;
	const enumType = t.kind == TypeKind.Enum ? t : (t.kind == TypeKind.EnumLiteral ? t.typeReturn : null);
	if (enumType == null || enumType.kind != TypeKind.Enum) return -1;
	let index = 0;
	for (const member of enumType.typeNames) {
		if (member == sym.name) {
			if (enumType.typeChildren != null && index < enumType.typeChildren.length) return enumType.typeChildren[index].typeValue as int64;
			return index as int64;
		}
		index = index + 1;
	}
	return -1;
}

function retypedLiteral(literal: Node, t: Type | null, loc: SourceLocation): Node {
	const none = null as unknown as Node;
	if (literal.kind == NodeKind.BooleanLiteral) {
		if (t != null && t.kind != TypeKind.Boolean) return none;
		return makeBool((literal.data as BooleanLiteralData).boolValue, loc);
	}
	if (literal.kind != NodeKind.NumberLiteral) return none;
	const nd = literal.data as NumberLiteralData;
	if (t != null && isIntegerType(t)) {
		if (nd.isFloat) return none;
		return makeTypedInteger(wrapToWidth(nd.intVal as uint64, t), t, loc);
	}
	const copy = createNode(NodeKind.NumberLiteral, { value: nd.value, isFloat: nd.isFloat, intVal: nd.intVal, outOfRangeText: nd.outOfRangeText, isBitPattern: nd.isBitPattern }, syntheticToken(loc));
	copy.nodeType = t != null ? t : literal.nodeType;
	return copy;
}

function constantLiteralOf(expr: Node, depth: int32): Node {
	const none = null as unknown as Node;
	if (expr == null || depth > CONSTANT_CHAIN_LIMIT) return none;
	match (expr.kind) {
		NodeKind.NumberLiteral => { return retypedLiteral(expr, expr.nodeType, expr.location); },
		NodeKind.BooleanLiteral => { return retypedLiteral(expr, expr.nodeType, expr.location); },
		NodeKind.Identifier => {
			const initializer = moduleConstInitializer(expr);
			if (initializer == null) return none;
			const value = constantLiteralOf(initializer, depth + 1);
			if (value == null) return none;
			return retypedLiteral(value, expr.resolvedSym.declNode.nodeType, expr.location);
		},
		NodeKind.MemberExpr => {
			const initializer = readonlyStaticInitializer(expr);
			if (initializer == null) return none;
			const value = constantLiteralOf(initializer, depth + 1);
			if (value == null) return none;
			return retypedLiteral(value, expr.resolvedSym.declNode.nodeType, expr.location);
		},
		NodeKind.BinaryExpr => {
			const d = expr.data as BinaryExprData;
			const left = constantLiteralOf(d.left, depth + 1);
			if (left == null) return none;
			const right = constantLiteralOf(d.right, depth + 1);
			if (right == null) return none;
			const folded = foldBinaryLiterals(d.operator, left, right, expr);
			return folded != expr ? folded : none;
		},
		NodeKind.UnaryExpr => {
			const d = expr.data as UnaryExprData;
			const operand = constantLiteralOf(d.operand, depth + 1);
			if (operand == null) return none;
			const folded = foldUnaryLiteral(d.unaryOp, operand, expr);
			return folded != expr ? folded : none;
		},
		NodeKind.TypeAssertion => {
			const target = expr.nodeType;
			if (target == null || !isIntegerType(target)) return none;
			const asserted = (expr.data as TypeAssertionData).asExpr;
			const ordinal = enumMemberOrdinal(asserted);
			if (ordinal >= 0) return makeTypedInteger(wrapToWidth(ordinal as uint64, target), target, expr.location);
			const inner = constantLiteralOf(asserted, depth + 1);
			if (inner == null) return none;
			return retypedLiteral(inner, target, expr.location);
		},
		NodeKind.HiddenStdConv => {
			const inner = constantLiteralOf((expr.data as HiddenStdConvData).convExpr, depth + 1);
			if (inner == null || !isIntegerType(expr.nodeType)) return none;
			return retypedLiteral(inner, expr.nodeType, expr.location);
		},
		_ => {},
	};
	return none;
}


function integerBitWidth(t: Type): int32 {
	return match (t.kind) {
		TypeKind.Int8 => 8,
		TypeKind.Uint8 => 8,
		TypeKind.Int16 => 16,
		TypeKind.Uint16 => 16,
		TypeKind.Int32 => 32,
		TypeKind.Uint32 => 32,
		_ => 64,
	};
}

function isUnsignedIntegerType(t: Type): boolean {
	return t.kind == TypeKind.Uint8 || t.kind == TypeKind.Uint16 || t.kind == TypeKind.Uint32 || t.kind == TypeKind.Uint64;
}

function wrapToWidth(bits: uint64, t: Type): int64 {
	const width = integerBitWidth(t);
	if (width == 64) return bits as int64;
	const modulus: int64 = (1 as int64) << (width as int64);
	const low: int64 = (bits as int64) & (modulus - 1);
	if (isUnsignedIntegerType(t)) return low;
	return low >= modulus / 2 ? low - modulus : low;
}

function literalFitsWidth(d: NumberLiteralData, t: Type): boolean {
	if (t.kind == TypeKind.Uint64) return true;
	if (d.outOfRangeText != "") return false;
	if (d.intVal < 0 && d.value > 0) return false;
	if (t.kind == TypeKind.Int64) return true;
	return wrapToWidth(d.intVal as uint64, t) == d.intVal;
}

function makeTypedInteger(value: int64, t: Type, loc: SourceLocation): Node {
	const magnitude: number = isUnsignedIntegerType(t) ? (value as uint64) as number : value as number;
	const n = createNode(NodeKind.NumberLiteral, { value: magnitude, isFloat: false, intVal: value, outOfRangeText: "", isBitPattern: false }, syntheticToken(loc));
	n.nodeType = t;
	return n;
}

function signedMagnitude(value: int64): uint64 {
	return value < 0 ? 0 - (value as uint64) : value as uint64;
}

function signedMagnitudeLimit(negative: boolean, t: Type): uint64 {
	const signBit = (1 as uint64) << ((integerBitWidth(t) - 1) as uint64);
	return negative ? signBit : signBit - 1;
}

function signedMinValue(t: Type): int64 {
	const signBit = (1 as uint64) << ((integerBitWidth(t) - 1) as uint64);
	return wrapToWidth(signBit, t);
}

function signedResultIsExact(op: string, left: int64, right: int64, t: Type): boolean {
	if (op == "*") {
		const leftMagnitude = signedMagnitude(left);
		const rightMagnitude = signedMagnitude(right);
		const negative = (left < 0) != (right < 0);
		const limit = signedMagnitudeLimit(negative, t);
		return rightMagnitude == 0 || leftMagnitude <= limit / rightMagnitude;
	}
	const bits: uint64 = op == "+" ? (left as uint64) + (right as uint64) : (left as uint64) - (right as uint64);
	const result = bits as int64;
	if (op == "+") {
		if (left >= 0 && right >= 0 && result < 0) return false;
		if (left < 0 && right < 0 && result >= 0) return false;
	} else {
		if (left >= 0 && right < 0 && result < 0) return false;
		if (left < 0 && right >= 0 && result >= 0) return false;
	}
	return wrapToWidth(bits, t) == result;
}

function foldIntegerArithmetic(op: string, leftValue: int64, rightValue: int64, t: Type, loc: SourceLocation, fallback: Node): Node {
	const width = integerBitWidth(t);
	const unsigned = isUnsignedIntegerType(t);
	const left = wrapToWidth(leftValue as uint64, t);
	const right = wrapToWidth(rightValue as uint64, t);
	const leftBits = left as uint64;
	const rightBits = right as uint64;
	if (op == "+" || op == "-" || op == "*") {
		if (!unsigned && !signedResultIsExact(op, left, right, t)) return fallback;
		const bits: uint64 = match (op) {
			"+" => leftBits + rightBits,
			"-" => leftBits - rightBits,
			_ => leftBits * rightBits,
		};
		return makeTypedInteger(wrapToWidth(bits, t), t, loc);
	}
	if (op == "/" || op == "%") {
		if (right == 0) return fallback;
		if (unsigned) {
			const bits: uint64 = op == "/" ? leftBits / rightBits : leftBits % rightBits;
			return makeTypedInteger(wrapToWidth(bits, t), t, loc);
		}
		if (left == signedMinValue(t) && right == -1) return fallback;
		const quotient: int64 = op == "/" ? left / right : left % right;
		return makeTypedInteger(quotient, t, loc);
	}
	if (op == "&" || op == "|" || op == "^") {
		const bits: uint64 = match (op) {
			"&" => leftBits & rightBits,
			"|" => leftBits | rightBits,
			_ => leftBits ^ rightBits,
		};
		return makeTypedInteger(wrapToWidth(bits, t), t, loc);
	}
	if (op == "<<" || op == ">>") {
		if (right < 0 || right >= (width as int64)) return fallback;
		if (op == "<<") return makeTypedInteger(wrapToWidth(leftBits << rightBits, t), t, loc);
		if (unsigned) return makeTypedInteger(wrapToWidth(leftBits >> rightBits, t), t, loc);
		return makeTypedInteger(left >> right, t, loc);
	}
	return fallback;
}

function foldIntegerComparison(op: string, leftValue: int64, rightValue: int64, t: Type, loc: SourceLocation, fallback: Node): Node {
	const left = wrapToWidth(leftValue as uint64, t);
	const right = wrapToWidth(rightValue as uint64, t);
	if (op == "===" || op == "==") return makeBool(left == right, loc);
	if (op == "!==" || op == "!=") return makeBool(left != right, loc);
	const unsigned = isUnsignedIntegerType(t);
	const leftBits = left as uint64;
	const rightBits = right as uint64;
	return match (op) {
		"<" => makeBool(unsigned ? leftBits < rightBits : left < right, loc),
		"<=" => makeBool(unsigned ? leftBits <= rightBits : left <= right, loc),
		">" => makeBool(unsigned ? leftBits > rightBits : left > right, loc),
		">=" => makeBool(unsigned ? leftBits >= rightBits : left >= right, loc),
		_ => fallback,
	};
}

function isComparisonOperator(op: string): boolean {
	return op == "<" || op == "<=" || op == ">" || op == ">=" || op == "===" || op == "!==" || op == "==" || op == "!=";
}

// ===== Binary Folding =====

function foldBinary(node: Node): Node {
	const d = node.data as BinaryExprData;
	// NOTE: do NOT create `const op = d.operator` — DRC treats it as a move from d->operator,
	// which zeroes the node's operator field because d is a pointer alias into node.data.
	// Use d.operator directly everywhere instead.
	return foldBinaryLiterals(d.operator, d.left, d.right, node);
}

function foldBinaryLiterals(op: string, left: Node, right: Node, node: Node): Node {
	const loc = node.location;
	if (left.kind != right.kind) return node;

	const result = match (left.kind) {
		NodeKind.NumberLiteral => {
			const ld = left.data as NumberLiteralData;
			const rd = right.data as NumberLiteralData;
			if (!ld.isFloat && !rd.isFloat) {
				if (isComparisonOperator(op) && left.nodeType != null && isIntegerType(left.nodeType)
						&& literalFitsWidth(ld, left.nodeType) && literalFitsWidth(rd, left.nodeType)) {
					return foldIntegerComparison(op, ld.intVal, rd.intVal, left.nodeType, loc, node);
				}
				if (!isComparisonOperator(op) && node.nodeType != null && isIntegerType(node.nodeType)
						&& literalFitsWidth(ld, node.nodeType) && literalFitsWidth(rd, node.nodeType)) {
					return foldIntegerArithmetic(op, ld.intVal, rd.intVal, node.nodeType, loc, node);
				}
			}
			if (!fitsDouble(ld) || !fitsDouble(rd)) return node;
			return foldNumberBinary(op, ld.value, rd.value, loc, node);
		},
		NodeKind.StringLiteral => {
			const ls = (left.data as StringLiteralData).value;
			const rs = (right.data as StringLiteralData).value;
			return foldStringBinary(op, ls, rs, loc, node);
		},
		NodeKind.BooleanLiteral => {
			const lb = (left.data as BooleanLiteralData).boolValue;
			const rb = (right.data as BooleanLiteralData).boolValue;
			return foldBoolBinary(op, lb, rb, loc, node);
		},
		_ => node,
	};
	if (result != node && node.nodeType != null) {
		result.nodeType = node.nodeType;
	}
	return result;
}

// True when the literal's exact value survives a round trip through a double.
function fitsDouble(d: NumberLiteralData): boolean {
	if (d.isFloat) return true;
	return ((d.intVal as number) as int64) == d.intVal;
}

function foldNumberBinary(op: string, lv: number, rv: number, loc: SourceLocation, fallback: Node): Node {
	// Guard: division by zero — leave as runtime
	if (rv == 0 && (op == "/" || op == "%")) return fallback;

	return match (op) {
		"+" => makeNumber(lv + rv, loc),
		"-" => makeNumber(lv - rv, loc),
		"*" => makeNumber(lv * rv, loc),
		"/" => makeNumber(lv / rv, loc),
		"%" => makeNumber(lv % rv, loc),
		"<" => makeBool(lv < rv, loc),
		"<=" => makeBool(lv <= rv, loc),
		">" => makeBool(lv > rv, loc),
		">=" => makeBool(lv >= rv, loc),
		"===" => makeBool(lv == rv, loc),
		"!==" => makeBool(lv != rv, loc),
		_ => fallback,
	};
}

function foldStringBinary(op: string, lv: string, rv: string, loc: SourceLocation, fallback: Node): Node {
	return match (op) {
		"+" => makeString(lv + rv, loc),
		"===" => makeBool(lv == rv, loc),
		"!==" => makeBool(lv != rv, loc),
		_ => fallback,
	};
}

function foldBoolBinary(op: string, lb: boolean, rb: boolean, loc: SourceLocation, fallback: Node): Node {
	return match (op) {
		"===" => makeBool(lb == rb, loc),
		"!==" => makeBool(lb != rb, loc),
		"&&" => makeBool(lb && rb, loc),
		"||" => makeBool(lb || rb, loc),
		_ => fallback,
	};
}

// ===== Unary Folding =====

function foldUnary(node: Node): Node {
	const d = node.data as UnaryExprData;
	// NOTE: do NOT copy d.unaryOp to local — same DRC alias issue as foldBinary.
	return foldUnaryLiteral(d.unaryOp, d.operand, node);
}

function foldUnaryLiteral(op: string, operand: Node, node: Node): Node {
	const loc = node.location;

	match (operand.kind) {
		NodeKind.BooleanLiteral => {
			if (op == "!") {
				const bv = (operand.data as BooleanLiteralData).boolValue;
				return makeBool(!bv, loc);
			}
		},
		NodeKind.NumberLiteral => {
			const od = operand.data as NumberLiteralData;
			const nv = od.value;
			if (!od.isFloat && node.nodeType != null && isIntegerType(node.nodeType) && literalFitsWidth(od, node.nodeType) && (op == "-" || op == "+")) {
				if (op == "-" && !isUnsignedIntegerType(node.nodeType) && od.intVal == signedMinValue(node.nodeType)) return node;
				const bits: uint64 = op == "-" ? 0 - (od.intVal as uint64) : od.intVal as uint64;
				return makeTypedInteger(wrapToWidth(bits, node.nodeType), node.nodeType, loc);
			}
			const result = match (op) {
				"-" => od.isFloat ? makeNumber(0 - nv, loc) : makeIntNumber((0 - (od.intVal as uint64)) as int64, loc),
				"+" => od.isFloat ? makeNumber(nv, loc) : makeIntNumber(od.intVal, loc),
				_ => node,
			};
			if (result != node && node.nodeType != null) {
				result.nodeType = node.nodeType;
			}
			return result;
		},
		_ => {},
	};

	return node;
}

// ===== Member Folding =====
// "a".code → NumberLiteral(97) — compile-time character code

function foldMember(node: Node): Node {
	const d = node.data as MemberExprData;
	if (d.property == "code" && d.object.kind == NodeKind.StringLiteral) {
		const sd = d.object.data as StringLiteralData;
		if (sd.value.byteLength > 0) {
			const cc = sd.value.charCodeAt(0);
			return makeNumber(cc, node.location);
		}
	}
	return foldConstantExpression(node);
}

// ===== Tests =====
test "number addition" { assert firstExprKindAfter("2 + 3;", lowerConstFold) == NodeKind.NumberLiteral; }

test "string concat" { assert firstExprKindAfter("\"a\" + \"b\";", lowerConstFold) == NodeKind.StringLiteral; }

test "boolean negation" { assert firstExprKindAfter("!true;", lowerConstFold) == NodeKind.BooleanLiteral; }

test "comparison" { assert firstExprKindAfter("5 > 3;", lowerConstFold) == NodeKind.BooleanLiteral; }

test "non-constant unchanged" { assert firstExprKindAfter("x + y;", lowerConstFold) == NodeKind.BinaryExpr; }

test "nested constant folds bottom-up" { assert firstExprKindAfter("(2 + 3) * 4;", lowerConstFold) == NodeKind.NumberLiteral; }

test "mixed types unchanged" { assert firstExprKindAfter("1 + x;", lowerConstFold) == NodeKind.BinaryExpr; }

test "division by zero unchanged" { assert firstExprKindAfter("1 / 0;", lowerConstFold) == NodeKind.BinaryExpr; }
