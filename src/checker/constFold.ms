import {
	Node, NodeKind, NodeFlag, SourceLocation, DeclKind, SymbolKind, SymbolFlag, Type, TypeKind, createNode,
	BinaryExprData, UnaryExprData, VariableDeclData, PropertyDeclData, TypeAssertionData, HiddenStdConvData,
	NumberLiteralData, StringLiteralData, BooleanLiteralData,
	MemberExprData, ArrayAccessData, ArrayLiteralData, ObjectLiteralData, ConditionalExprData, SpreadExprData, HiddenDerefData,
} from "../ast/node";
import { isIntegerType, isFloatType, createPrimitive } from "./types";
import { makeNumber, makeIntNumber, makeString, makeBool, syntheticToken } from "./literalNodes";

const CONSTANT_CHAIN_LIMIT: int32 = 64;

export function foldConstantExpression(node: Node): Node {
	const literal = constantLiteralOf(node, 0);
	return literal != null ? literal : node;
}

function isInlineConstantType(t: Type | null): boolean {
	if (t == null) return false;
	return isIntegerType(t) || isFloatType(t) || t.kind == TypeKind.Number || t.kind == TypeKind.Boolean;
}

function constInitializer(node: Node): Node {
	const none = null as unknown as Node;
	const sym = node.resolvedSym;
	if (sym == null || sym.symbolKind != SymbolKind.Variable) return none;
	if (sym.symFlags.has(SymbolFlag.Mutable)) return none;
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

export function literalTakesType(literal: Node, t: Type | null): boolean {
	if (literal.kind == NodeKind.BooleanLiteral) return t == null || t.kind == TypeKind.Boolean;
	if (literal.kind != NodeKind.NumberLiteral) return false;
	if (t == null) return true;
	if (isFloat32Type(literal.nodeType) && !isFloat32Type(t)) return false;
	return !isIntegerType(t) || !(literal.data as NumberLiteralData).isFloat;
}

function retypedLiteral(literal: Node, t: Type | null, loc: SourceLocation): Node {
	const none = null as unknown as Node;
	if (!literalTakesType(literal, t)) return none;
	if (literal.kind == NodeKind.BooleanLiteral) return makeBool((literal.data as BooleanLiteralData).boolValue, loc);
	const nd = literal.data as NumberLiteralData;
	if (t != null && isIntegerType(t)) return makeTypedInteger(wrapToWidth(nd.intVal as uint64, t), t, loc);
	const copy = createNode(NodeKind.NumberLiteral, { value: nd.value, isFloat: nd.isFloat, intVal: nd.intVal, outOfRangeText: nd.outOfRangeText, isBitPattern: nd.isBitPattern }, syntheticToken(loc));
	copy.nodeType = t != null ? t : literal.nodeType;
	return copy;
}

export function isUntypedIntegerConstant(expr: Node, depth: int32): boolean {
	if (expr == null || depth > CONSTANT_CHAIN_LIMIT) return false;
	if (expr.kind == NodeKind.NumberLiteral) return !(expr.data as NumberLiteralData).isFloat;
	if (expr.kind == NodeKind.Identifier) {
		const initializer = constInitializer(expr);
		if (initializer == null || (expr.resolvedSym.declNode.data as VariableDeclData).declType != "") return false;
		return isUntypedIntegerConstant(initializer, depth + 1);
	}
	if (expr.kind == NodeKind.MemberExpr) {
		const initializer = readonlyStaticInitializer(expr);
		if (initializer == null || (expr.resolvedSym.declNode.data as PropertyDeclData).propType != "") return false;
		return isUntypedIntegerConstant(initializer, depth + 1);
	}
	if (expr.kind == NodeKind.BinaryExpr) {
		const d = expr.data as BinaryExprData;
		return !expr.flags.has(NodeFlag.UserOp) && isUntypedIntegerConstant(d.left, depth + 1) && isUntypedIntegerConstant(d.right, depth + 1);
	}
	if (expr.kind == NodeKind.UnaryExpr) return isUntypedIntegerConstant((expr.data as UnaryExprData).operand, depth + 1);
	return false;
}

export function isUntypedConstant(expr: Node, depth: int32): boolean {
	if (expr == null || depth > CONSTANT_CHAIN_LIMIT) return false;
	if (expr.kind == NodeKind.NumberLiteral) return true;
	if (expr.kind == NodeKind.Identifier) {
		const initializer = constInitializer(expr);
		if (initializer == null || (expr.resolvedSym.declNode.data as VariableDeclData).declType != "") return false;
		return isUntypedConstant(initializer, depth + 1);
	}
	if (expr.kind == NodeKind.MemberExpr) {
		const initializer = readonlyStaticInitializer(expr);
		if (initializer == null || (expr.resolvedSym.declNode.data as PropertyDeclData).propType != "") return false;
		return isUntypedConstant(initializer, depth + 1);
	}
	if (expr.kind == NodeKind.BinaryExpr) {
		const d = expr.data as BinaryExprData;
		return !expr.flags.has(NodeFlag.UserOp) && isUntypedConstant(d.left, depth + 1) && isUntypedConstant(d.right, depth + 1);
	}
	if (expr.kind == NodeKind.UnaryExpr) return isUntypedConstant((expr.data as UnaryExprData).operand, depth + 1);
	return false;
}

export function isCompileTimeValue(expr: Node, depth: int32): boolean {
	if (expr == null || depth > CONSTANT_CHAIN_LIMIT) return false;
	return match (expr.kind) {
		NodeKind.NumberLiteral => true,
		NodeKind.StringLiteral => true,
		NodeKind.BooleanLiteral => true,
		NodeKind.BigIntLiteral => true,
		NodeKind.NullLiteral => true,
		NodeKind.Identifier => isCompileTimeBinding(expr, depth),
		NodeKind.MemberExpr => readonlyStaticInitializer(expr) != null || isCompileTimeValue((expr.data as MemberExprData).object, depth),
		NodeKind.ArrayAccess => isCompileTimeValue((expr.data as ArrayAccessData).array, depth) && isCompileTimeValue((expr.data as ArrayAccessData).index, depth),
		NodeKind.ArrayLiteral => allCompileTimeValues((expr.data as ArrayLiteralData).elements, depth),
		NodeKind.ObjectLiteral => allCompileTimeValues((expr.data as ObjectLiteralData).properties, depth),
		NodeKind.SpreadExpr => isCompileTimeValue((expr.data as SpreadExprData).spreadArg, depth),
		NodeKind.BinaryExpr => !expr.flags.has(NodeFlag.UserOp) && isCompileTimeValue((expr.data as BinaryExprData).left, depth) && isCompileTimeValue((expr.data as BinaryExprData).right, depth),
		NodeKind.UnaryExpr => isCompileTimeValue((expr.data as UnaryExprData).operand, depth),
		NodeKind.ConditionalExpr => isCompileTimeValue((expr.data as ConditionalExprData).ternaryCondition, depth)
			&& isCompileTimeValue((expr.data as ConditionalExprData).ternaryConsequent, depth)
			&& isCompileTimeValue((expr.data as ConditionalExprData).ternaryAlternate, depth),
		NodeKind.TypeAssertion => isCompileTimeValue((expr.data as TypeAssertionData).asExpr, depth),
		NodeKind.HiddenStdConv => isCompileTimeValue((expr.data as HiddenStdConvData).convExpr, depth),
		NodeKind.HiddenSubConv => isCompileTimeValue((expr.data as HiddenStdConvData).convExpr, depth),
		NodeKind.HiddenDeref => isCompileTimeValue((expr.data as HiddenDerefData).expr, depth),
		_ => false,
	};
}

function allCompileTimeValues(nodes: Node[], depth: int32): boolean {
	for (const n of nodes) {
		if (!isCompileTimeValue(n, depth)) return false;
	}
	return true;
}

function isCompileTimeBinding(ident: Node, depth: int32): boolean {
	const sym = ident.resolvedSym;
	if (sym == null) return false;
	if (sym.symbolKind == SymbolKind.EnumMember) return true;
	if (sym.symbolKind != SymbolKind.Variable || sym.symFlags.has(SymbolFlag.Mutable)) return false;
	if (!sym.symFlags.has(SymbolFlag.Global) || sym.symFlags.has(SymbolFlag.StaticLocal)) return false;
	const decl = sym.declNode;
	if (decl == null || decl.kind != NodeKind.VariableDecl) return false;
	const d = decl.data as VariableDeclData;
	return d.declKind == DeclKind.Const && isCompileTimeValue(d.initializer, depth + 1);
}

export function exactUntypedInteger(expr: Node, depth: int32): Node {
	const none = null as unknown as Node;
	if (expr == null || depth > CONSTANT_CHAIN_LIMIT) return none;
	match (expr.kind) {
		NodeKind.NumberLiteral => {
			const d = expr.data as NumberLiteralData;
			if (d.isFloat || d.outOfRangeText != "" || (d.intVal < 0 && d.value > 0)) return none;
			return makeTypedInteger(d.intVal, createPrimitive(TypeKind.Int64), expr.location);
		},
		NodeKind.Identifier => {
			const initializer = constInitializer(expr);
			if (initializer == null || (expr.resolvedSym.declNode.data as VariableDeclData).declType != "") return none;
			return exactWithin(exactUntypedInteger(initializer, depth + 1), expr.resolvedSym.declNode.nodeType);
		},
		NodeKind.MemberExpr => {
			const initializer = readonlyStaticInitializer(expr);
			if (initializer == null || (expr.resolvedSym.declNode.data as PropertyDeclData).propType != "") return none;
			return exactWithin(exactUntypedInteger(initializer, depth + 1), expr.resolvedSym.declNode.nodeType);
		},
		NodeKind.BinaryExpr => {
			const d = expr.data as BinaryExprData;
			if (isComparisonOperator(d.operator) || expr.flags.has(NodeFlag.UserOp)) return none;
			const left = exactUntypedInteger(d.left, depth + 1);
			if (left == null) return none;
			const right = exactUntypedInteger(d.right, depth + 1);
			if (right == null) return none;
			return exactIntegerBinary(d.operator, integerValueOf(left), integerValueOf(right), expr.location);
		},
		NodeKind.UnaryExpr => {
			const d = expr.data as UnaryExprData;
			const operand = exactUntypedInteger(d.operand, depth + 1);
			if (operand == null || (d.unaryOp != "-" && d.unaryOp != "+" && d.unaryOp != "~")) return none;
			const value = integerValueOf(operand);
			if (d.unaryOp == "-" && value == signedMinValue(createPrimitive(TypeKind.Int64))) return none;
			if (d.unaryOp == "~" && !integerValueFits(value, createPrimitive(TypeKind.Int32))) return none;
			const bits: uint64 = match (d.unaryOp) {
				"-" => 0 - (value as uint64),
				"~" => ~(value as uint64),
				_ => value as uint64,
			};
			return makeTypedInteger(bits as int64, createPrimitive(TypeKind.Int64), expr.location);
		},
		_ => {},
	};
	return none;
}

function isBitwiseOperator(op: string): boolean {
	return op == "&" || op == "|" || op == "^" || op == "<<" || op == ">>";
}

function exactIntegerBinary(op: string, left: int64, right: int64, loc: SourceLocation): Node {
	const none = null as unknown as Node;
	const wide = createPrimitive(TypeKind.Int64);
	if (!isBitwiseOperator(op)) return foldIntegerArithmetic(op, left, right, wide, loc, none);
	const narrow = createPrimitive(TypeKind.Int32);
	if (!integerValueFits(left, narrow) || !integerValueFits(right, narrow)) return none;
	const folded = foldIntegerArithmetic(op, left, right, narrow, loc, none);
	return folded == null ? none : makeTypedInteger(integerValueOf(folded), wide, loc);
}

export function integerValueOf(literal: Node): int64 {
	return (literal.data as NumberLiteralData).intVal;
}

export function integerValueFits(value: int64, t: Type): boolean {
	if (!isIntegerType(t)) return false;
	if (isUnsignedIntegerType(t) && value < 0) return false;
	return integerBitWidth(t) == 64 || wrapToWidth(value as uint64, t) == value;
}

export function typedIntegerLiteral(value: int64, t: Type, loc: SourceLocation): Node {
	return makeTypedInteger(value, t, loc);
}

function exactWithin(literal: Node, t: Type | null): Node {
	if (literal == null || t == null || !integerValueFits(integerValueOf(literal), t)) return null as unknown as Node;
	return literal;
}

function foldedOperand(expr: Node, depth: int32): Node {
	if (expr != null && (expr.kind == NodeKind.NumberLiteral || expr.kind == NodeKind.BooleanLiteral)) return expr;
	return constantLiteralOf(expr, depth);
}

export function constantLiteralOf(expr: Node, depth: int32): Node {
	const none = null as unknown as Node;
	if (expr == null || depth > CONSTANT_CHAIN_LIMIT) return none;
	match (expr.kind) {
		NodeKind.NumberLiteral => { return retypedLiteral(expr, expr.nodeType, expr.location); },
		NodeKind.BooleanLiteral => { return retypedLiteral(expr, expr.nodeType, expr.location); },
		NodeKind.Identifier => {
			const initializer = constInitializer(expr);
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
			const left = foldedOperand(d.left, depth + 1);
			if (left == null) return none;
			const right = foldedOperand(d.right, depth + 1);
			if (right == null) return none;
			const folded = foldBinaryLiterals(d.operator, left, right, expr);
			return folded != expr ? folded : none;
		},
		NodeKind.UnaryExpr => {
			const d = expr.data as UnaryExprData;
			const operand = foldedOperand(d.operand, depth + 1);
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

function constBindingInitializer(ident: Node): Node {
	const none = null as unknown as Node;
	const sym = ident.resolvedSym;
	if (sym == null || sym.symbolKind != SymbolKind.Variable || sym.symFlags.has(SymbolFlag.Mutable)) return none;
	const decl = sym.declNode;
	if (decl == null || decl.kind != NodeKind.VariableDecl) return none;
	const d = decl.data as VariableDeclData;
	return d.declKind == DeclKind.Const && readonlyDataTypeShape(decl.nodeType, 0) ? d.initializer : none;
}

function isScalarLiteral(node: Node): boolean {
	return node != null && (node.kind == NodeKind.NumberLiteral || node.kind == NodeKind.BooleanLiteral);
}

function scalarTreeOf(expr: Node, depth: int32): Node {
	const tree = constantTreeOf(expr, depth);
	return isScalarLiteral(tree) ? tree : null as unknown as Node;
}

function constantTreeOf(expr: Node, depth: int32): Node {
	const none = null as unknown as Node;
	if (expr == null || depth > CONSTANT_CHAIN_LIMIT) return none;
	const scalar = constantLiteralOf(expr, depth);
	if (scalar != null) return scalar;
	match (expr.kind) {
		NodeKind.Identifier => {
			const initializer = constBindingInitializer(expr);
			return initializer != null ? constantTreeOf(initializer, depth + 1) : none;
		},
		NodeKind.ArrayLiteral => {
			if (!readonlyDataTypeShape(expr.nodeType, 0)) return none;
			const elements: Node[] = [];
			for (const e of (expr.data as ArrayLiteralData).elements) {
				const folded = constantTreeOf(e, depth + 1);
				if (folded == null) return none;
				elements.push(folded);
			}
			const copy = createNode(NodeKind.ArrayLiteral, { elements: elements }, syntheticToken(expr.location));
			copy.nodeType = expr.nodeType;
			return copy;
		},
		NodeKind.ObjectLiteral => {
			if (!readonlyDataTypeShape(expr.nodeType, 0)) return none;
			const od = expr.data as ObjectLiteralData;
			const properties: Node[] = [];
			for (const p of od.properties) {
				const folded = constantTreeOf(p, depth + 1);
				if (folded == null) return none;
				properties.push(folded);
			}
			const copy = createNode(NodeKind.ObjectLiteral, { properties: properties, keys: od.keys.slice(0), keyLocations: od.keyLocations.slice(0) }, syntheticToken(expr.location));
			copy.nodeType = expr.nodeType;
			return copy;
		},
		NodeKind.ArrayAccess => {
			const d = expr.data as ArrayAccessData;
			const array = constantTreeOf(d.array, depth + 1);
			const index = scalarTreeOf(d.index, depth + 1);
			if (array == null || array.kind != NodeKind.ArrayLiteral || index == null || index.kind != NodeKind.NumberLiteral) return none;
			const nd = index.data as NumberLiteralData;
			const elements = (array.data as ArrayLiteralData).elements;
			if (nd.isFloat || nd.intVal < 0 || nd.intVal >= elements.length as int64) return none;
			return elements[nd.intVal as int32];
		},
		NodeKind.MemberExpr => {
			const d = expr.data as MemberExprData;
			const object = constantTreeOf(d.object, depth + 1);
			if (object == null || object.kind != NodeKind.ObjectLiteral) return none;
			const od = object.data as ObjectLiteralData;
			const at = od.keys.indexOf(d.property);
			return at >= 0 ? od.properties[at] : none;
		},
		NodeKind.HiddenStdConv => {
			const inner = scalarTreeOf((expr.data as HiddenStdConvData).convExpr, depth + 1);
			return inner != null ? retypedLiteral(inner, expr.nodeType, expr.location) : none;
		},
		NodeKind.TypeAssertion => {
			const inner = scalarTreeOf((expr.data as TypeAssertionData).asExpr, depth + 1);
			return inner != null ? retypedLiteral(inner, expr.nodeType, expr.location) : none;
		},
		NodeKind.BinaryExpr => {
			const d = expr.data as BinaryExprData;
			const left = scalarTreeOf(d.left, depth + 1);
			const right = left != null ? scalarTreeOf(d.right, depth + 1) : none;
			if (right == null) return none;
			const folded = foldBinaryLiterals(d.operator, left, right, expr);
			return folded != expr ? folded : none;
		},
		NodeKind.UnaryExpr => {
			const d = expr.data as UnaryExprData;
			const operand = scalarTreeOf(d.operand, depth + 1);
			if (operand == null) return none;
			const folded = foldUnaryLiteral(d.unaryOp, operand, expr);
			return folded != expr ? folded : none;
		},
		_ => {},
	};
	return none;
}

export function foldConstInitializer(binding: Node): void {
	const d = binding.data as VariableDeclData;
	if (d.declKind != DeclKind.Const || d.initializer == null || !readonlyDataTypeShape(binding.nodeType, 0)) return;
	if (isScalarLiteral(d.initializer) || readonlyDataInitializer(d.initializer, 0)) return;
	const folded = constantTreeOf(d.initializer, 0);
	if (folded == null) return;
	if (isScalarLiteral(folded)) {
		const typed = retypedLiteral(folded, binding.nodeType, d.initializer.location);
		if (typed != null) d.initializer = typed;
		return;
	}
	if (binding.nodeType != null) folded.nodeType = binding.nodeType;
	d.initializer = folded;
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

export function foldBinaryLiterals(op: string, left: Node, right: Node, node: Node): Node {
	const loc = node.location;
	if (left.kind != right.kind || node.flags.has(NodeFlag.UserOp)) return node;

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
			if (!fitsDouble(ld) || !fitsDouble(rd) || involvesFloat32(left, right, node)) return node;
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

function isFloat32Type(t: Type | null): boolean {
	return t != null && t.kind == TypeKind.Float32;
}

function involvesFloat32(left: Node, right: Node, node: Node): boolean {
	return isFloat32Type(left.nodeType) || isFloat32Type(right.nodeType) || isFloat32Type(node.nodeType);
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

export function foldUnaryLiteral(op: string, operand: Node, node: Node): Node {
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
			if (!od.isFloat && node.nodeType != null && isIntegerType(node.nodeType) && literalFitsWidth(od, node.nodeType) && (op == "-" || op == "+" || op == "~")) {
				if (op == "-" && !isUnsignedIntegerType(node.nodeType) && od.intVal == signedMinValue(node.nodeType)) return node;
				const bits: uint64 = match (op) {
					"-" => 0 - (od.intVal as uint64),
					"~" => ~(od.intVal as uint64),
					_ => od.intVal as uint64,
				};
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


const READONLY_DATA_DEPTH_LIMIT: int32 = 32;

// A module-level `const` of sized-array or struct type whose leaves are all
// scalar literals is read-only data: nothing can write it (a `const` binding is
// deep — element and field writes are checker errors), so the SBF link may keep
// it in .rodata instead of writable static storage.
export function readonlyDataInitializer(init: Readonly<Node> | null, depth: int32): boolean {
	if (init == null || depth > READONLY_DATA_DEPTH_LIMIT) return false;
	match (init.kind) {
		NodeKind.NumberLiteral | NodeKind.BooleanLiteral => { return true; },
		NodeKind.HiddenStdConv => {
			return readonlyDataInitializer((init.data as HiddenStdConvData).convExpr, depth + 1);
		},
		NodeKind.ArrayLiteral => {
			const ad = init.data as ArrayLiteralData;
			for (const e of ad.elements) {
				if (!readonlyDataInitializer(e, depth + 1)) return false;
			}
			return true;
		},
		NodeKind.ObjectLiteral => {
			const od = init.data as ObjectLiteralData;
			if (od.properties.length == 0) return false;
			for (const p of od.properties) {
				if (!readonlyDataInitializer(p, depth + 1)) return false;
			}
			return true;
		},
		_ => { return false; },
	};
}

export function readonlyDataTypeShape(t: Type | null, depth: int32): boolean {
	if (t == null || depth > READONLY_DATA_DEPTH_LIMIT) return false;
	if (isIntegerType(t) || isFloatType(t) || t.kind == TypeKind.Number || t.kind == TypeKind.Boolean) return true;
	if (t.kind == TypeKind.SizedArray) return readonlyDataTypeShape(t.typeReturn, depth + 1);
	if (t.kind == TypeKind.Struct) {
		for (const f of t.typeChildren) {
			if (!readonlyDataTypeShape(f, depth + 1)) return false;
		}
		return true;
	}
	return false;
}

export function readonlyDataConstBinding(binding: Readonly<Node>): boolean {
	return readonlyDataTypeShape(binding.nodeType, 0)
		&& readonlyDataInitializer((binding.data as VariableDeclData).initializer, 0);
}
