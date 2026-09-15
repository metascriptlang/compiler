// Fit / coercion / branch-join layer of the expression checker.
// Split out of checkExprPass.ms — depends on the expression dispatcher only
// through the checkerCallbacks door.

import { BinaryExprData, CallingConvention, IdentifierData, Node, NodeData, NodeFlag, NodeKind, NumberLiteralData, SourceLocation, SymbolKind, Type, TypeAssertionData, TypeKind, createNode, createNodeAt } from "../ast/node";
import { Token, TokenKind, createToken } from "../lexer/token";
import { dropsReadonlyView, isAnonStructAdoption, isAssignable, isNominalMismatch, isReinterpretUnsafe, needsStdConv, nonNullMemberOfNullable, sameType } from "./compat";
import { CheckerContext, addError, addWarning, classDescendsFrom, findAllExtensionsByName, findFirstMatchingExt, getExtFnType, resolveOperatorCall } from "./context";
import { lookupSymbol } from "./symbol";
import { unionOfTypes, canonicalizeBranchJoin, isPointerKindJoinPair, joinedPointerMember } from "./flow";
import { isTagCarriedUnion, peelToStruct, BITSET_MAX_MEMBERS, bitSetElemType, createBitSet, isOrdinalEnum, booleanType, createMaybeType, createPrimitive, createUnion, duVariantIndexOfType, maybePayloadWidenSlot, primitiveMemberIndexInUnion, variantIndexInUnion, findUnionVariant, float64Type, hasGenericParams, inferredType, int32Type, integerRank, isAtomicRef, isFloatType, isIntegerType, isMaybeType, isMaybeWrappable, isNarrowingIntConv, isNumeric, isPointerShapedForUnknown, isWideningInt64Conv, isPrimitiveUnionMember, isStringLike, isUnknownType, isUnresolvedType, nullType, numberType, peelToStructOrUnion, skipModifier, stringType, typeDisplayName, unwrapRef, unwrapRefNullUnion, voidType, withoutReadonlyView, typeNameOf, distinctWidenBody, distinctBody, PEEL_MAX_DEPTH } from "./types";
import { callCheckExpr } from "./checkerCallbacks";

// ===== Operator Inference =====

// Integer widening: promote to the wider of two integer types (C-style integer promotion).
function widenIntegers(a: Type, b: Type): Type {
	if (a.kind == b.kind) return a;
	return integerRank(a) >= integerRank(b) ? a : b;
}

// Mixed numeric promotion: number stays number, otherwise float64.
function promoteNumeric(a: Type, b: Type): Type {
	if (a.kind == TypeKind.Number || b.kind == TypeKind.Number) return numberType();
	if (a.kind == TypeKind.Float32 && b.kind == TypeKind.Float32) return createPrimitive(TypeKind.Float32);
	return float64Type();
}

function widenBranchLiteral(t: Type): Type {
	if (t.kind == TypeKind.StringLiteral) return stringType();
	if (t.kind == TypeKind.BooleanLiteral) return booleanType();
	return t;
}

function branchContributesToJoin(t: Type | null): boolean {
	return t != null && !isUnresolvedType(t)
		&& t.kind != TypeKind.Never && t.kind != TypeKind.Void
		&& t.kind != TypeKind.Error;
}

export function joinBranchTypes(types: Type[]): Type {
	const prepared: Type[] = [];
	for (const t of types) {
		if (!branchContributesToJoin(t)) continue;
		const w = widenBranchLiteral(t);
		let dup = false;
		for (let pi = 0; pi < prepared.length; pi++) {
			const p = prepared[pi];
			if (p == w || sameType(p, w)) { dup = true; break; }
			if (isPointerKindJoinPair(p, w)) {
				prepared[pi] = joinedPointerMember(p, w);
				dup = true;
				break;
			}
		}
		if (!dup) prepared.push(w);
	}
	if (prepared.length == 0) return inferredType();
	if (prepared.length == 1) return prepared[0];
	let allNumeric = true;
	for (const p of prepared) {
		if (!isNumeric(p) && p.kind != TypeKind.Enum) { allNumeric = false; break; }
	}
	if (allNumeric) {
		let acc = prepared[0].kind == TypeKind.Enum ? int32Type() : prepared[0];
		let ni = 1;
		while (ni < prepared.length) {
			let b = prepared[ni];
			if (b.kind == TypeKind.Enum) b = int32Type();
			acc = (isIntegerType(acc) && isIntegerType(b)) ? widenIntegers(acc, b) : promoteNumeric(acc, b);
			ni = ni + 1;
		}
		return acc;
	}
	return canonicalizeBranchJoin(unionOfTypes(prepared, null));
}

export function fitJoinedBranch(ctx: CheckerContext, expr: Node, joined: Type | null): Node {
	if (expr == null || joined == null || isUnresolvedType(joined)) return expr;
	const bt = expr.nodeType;
	if (bt == null || bt.kind == TypeKind.Never || bt.kind == TypeKind.Void || isUnresolvedType(bt)) return expr;
	if (bt == joined || sameType(bt, joined)) return expr;
	return fitNode(ctx, expr, joined, bt);
}

// Reference parity (sigmatch.nim:2596 `localConvMatch`, :2179 `implicitConv`): a
// stringification the call site needs is planted DURING checking, so it is bound
// by the same overload resolution a hand-written `x.toString()` gets and reaches
// codegen carrying its symbol. Returns null when nothing real binds — primitives
// and enums have no declaration and stay on the builtin-lowering path.
export function synthStringify(ctx: CheckerContext, expr: Node): Node | null {
	const t = expr.nodeType;
	if (t == null) return null;
	const peeled = peelToStructOrUnion(t);
	if (peeled == null || peeled.kind != TypeKind.Struct) return null;
	const loc = expr.location;
	const memberNode = createNodeAt(NodeKind.MemberExpr,
		{ object: expr, property: "toString", isOptional: false }, loc);
	const synthCall = createNodeAt(NodeKind.CallExpr,
		{ callee: memberNode, arguments: [], isDirectCall: true, resolvedOverloadIdx: -1 }, loc);
	// The trial is silent: a `toString` that cannot serve a zero-argument
	// string-returning call is not a user error, it just leaves this operand on
	// the builtin path. The receiver's own diagnostics were already recorded when
	// the caller checked it, so the trial's output is dropped either way.
	const errMark = ctx.errors.length;
	callCheckExpr(ctx, synthCall, null);
	const fits = ctx.errors.length == errMark;
	while (ctx.errors.length > errMark) { ctx.errors.pop(); }
	if (!fits) return null;
	if (synthCall.nodeType == null || !isStringLike(synthCall.nodeType)) return null;
	// The universal `.toString()` fallback mints a symbol with no declaration; it
	// is the shape that used to reach C codegen as a struct member call.
	if (synthCall.resolvedSym == null || synthCall.resolvedSym.declNode == null) return null;
	return synthCall;
}

// `Flag.A | Flag.B` is a set of enum members, not the numeric OR of their
// ordinals — the values are ordinals, so the numeric result is meaningless.
// Mirrors the reference's `set[T]`: membership is by ordinal bit position.
function inferBitSetOp(op: string, leftType: Type, rightType: Type): Type | null {
	if (leftType == null || rightType == null) return null;
	if (op != "|" && op != "&" && op != "^") return null;
	const leftElem = bitSetElemType(leftType);
	if (leftElem != null) {
		if (rightType.kind == TypeKind.Enum && rightType.typeName == leftElem.typeName) return leftType;
		const rightElem = bitSetElemType(rightType);
		if (rightElem != null && rightElem.typeName == leftElem.typeName) return leftType;
		return null;
	}
	const rightElem = bitSetElemType(rightType);
	if (rightElem != null) {
		if (leftType.kind == TypeKind.Enum && leftType.typeName == rightElem.typeName) return rightType;
		return null;
	}
	if (leftType.kind == TypeKind.Enum && rightType.kind == TypeKind.Enum
		&& leftType.typeName != "" && leftType.typeName == rightType.typeName
		&& isOrdinalEnum(leftType)) {
		return createBitSet(leftType);
	}
	return null;
}

export function inferBinaryOp(op: string, leftType: Type, rightType: Type): Type {
	const bitSetResult = inferBitSetOp(op, leftType, rightType);
	if (bitSetResult != null) return bitSetResult;
	if (leftType != null && rightType != null
		&& leftType.kind == TypeKind.BigInt && rightType.kind == TypeKind.BigInt
		&& (op == "+" || op == "-" || op == "*" || op == "/" || op == "%" || op == "**"
			|| op == "&" || op == "|" || op == "^" || op == "<<" || op == ">>")) {
		return leftType;
	}
	return match (op) {
		"===" | "!==" | "==" | "!=" | "<" | ">" | "<=" | ">=" | "instanceof" | "in" => booleanType(),
		"&&" | "||" => leftType,
		"+" => {
			if (isStringLike(leftType) || isStringLike(rightType)) return stringType();
			if (leftType != null && leftType.kind == TypeKind.Ptr) return leftType;
			if (rightType != null && rightType.kind == TypeKind.Ptr) return rightType;
			if (isIntegerType(leftType) && isIntegerType(rightType)) return widenIntegers(leftType, rightType);
			if (isNumeric(leftType) && isNumeric(rightType)) return promoteNumeric(leftType, rightType);
			return inferredType();
		},
		"-" => {
			if (leftType != null && leftType.kind == TypeKind.Ptr && rightType != null && rightType.kind == TypeKind.Ptr) return int32Type();
			if (leftType != null && leftType.kind == TypeKind.Ptr) return leftType;
			if (isIntegerType(leftType) && isIntegerType(rightType)) return widenIntegers(leftType, rightType);
			if (isNumeric(leftType) && isNumeric(rightType)) return promoteNumeric(leftType, rightType);
			return inferredType();
		},
		"*" | "/" | "%" | "**" => {
			if (isIntegerType(leftType) && isIntegerType(rightType)) return widenIntegers(leftType, rightType);
			if (isNumeric(leftType) && isNumeric(rightType)) return promoteNumeric(leftType, rightType);
			return float64Type();
		},
		"&" | "|" | "^" | "<<" | ">>" | ">>>" => {
			// Bitwise: promote to wider integer if both sides are integer
			if (isIntegerType(leftType) && isIntegerType(rightType)) return widenIntegers(leftType, rightType);
			if (isIntegerType(leftType)) return leftType;
			return int32Type();
		},
		"=" | "+=" | "-=" | "*=" | "/=" | "%=" | "&&=" | "||=" | "??=" => voidType(),
		"??" => {
			if (isMaybeType(leftType) && leftType.typeReturn != null) {
				const joined = joinBranchTypes([leftType.typeReturn, rightType]);
				return isUnresolvedType(joined) ? leftType.typeReturn : joined;
			}
			if (leftType != null && leftType.kind == TypeKind.Union) {
				const ptrMember = unwrapRefNullUnion(leftType);
				if (ptrMember != null) {
					const joined = joinBranchTypes([ptrMember, rightType]);
					return isUnresolvedType(joined) ? leftType : joined;
				}
			}
			return leftType;
		},
		_ => inferredType(),
	};
}

export function inferUnaryOp(op: string, operandType: Type): Type {
	return match (op) {
		"!" => booleanType(),
		"-" | "+" => {
			// Reference parity: -int32 → int32, +int32 → int32
			if (isIntegerType(operandType)) return operandType;
			if (isFloatType(operandType)) return operandType;
			if (operandType != null && operandType.kind == TypeKind.BigInt) return operandType;
			return numberType();
		},
		"~" => {
			// Reference parity: ~int32 → int32
			if (isIntegerType(operandType)) return operandType;
			if (operandType != null && operandType.kind == TypeKind.BigInt) return operandType;
			return int32Type();
		},
		"typeof" => stringType(),
		_ => inferredType(),
	};
}

// Wrap an expression in HiddenStdConv to a target type. Used for implicit numeric casts.
export function wrapInConv(expr: Node, targetType: Type): Node {
	const convTok = createToken(TokenKind.Ident, "", expr.location.line);
	const convNode = createNode(NodeKind.HiddenStdConv, { convExpr: expr, convType: targetType }, convTok);
	convNode.nodeType = targetType;
	convNode.flags = convNode.flags.incl(NodeFlag.Sem);
	return convNode;
}


// Synthesize T → Maybe<T> coercion at the checker layer. Used by both fitNode
// (var-decl/return/assign/object-field) and checkCallExpr (call args). Mirrors
// optionalCoercion.ms / nullableLower.ms's transform-layer wrap; kept separate
// per checker/transform layering. Two cases:
//   - null literal: retype as the Maybe wrapper so codegen emits `{0}` zero-init.
//     Wrapping null into `{value: null, present: true}` would be wrong.
//   - non-null:    `{ value: expr, present: true }` ObjectLiteral typed as wrapper.
//     Direct struct construction (Nim parity), no runtime helper.
// Caller is responsible for the gating check (`isMaybeType(formal) && !isMaybeType(exprType)`).
// Wrap a string arg passed to a cstring param in a HiddenStdConv so the FFI
// boundary conversion (msStringToCString on C; none on JS, cstring ≡ string)
// is inserted — mirrors an explicit `as cstring` cast, for implicit call args.
export function synthCStringConv(expr: Node, cstr: Type): Node {
	const tok = createToken(TokenKind.Ident, "", expr.location.line);
	const conv = createNode(NodeKind.HiddenStdConv, { convExpr: expr, convType: cstr } as unknown as NodeData, tok);
	conv.nodeType = cstr;
	conv.flags = conv.flags.incl(NodeFlag.Sem);
	return conv;
}

export function synthMaybeWrap(expr: Node, formal: Type, exprType: Type): Node {
	if (expr.kind == NodeKind.NullLiteral || exprType.kind == TypeKind.Null) {
		expr.nodeType = formal;
		return expr;
	}
	const wrapTok = createToken(TokenKind.Ident, "", expr.location.line);
	const presentLit = createNode(NodeKind.BooleanLiteral, { boolValue: true } as NodeData, wrapTok);
	presentLit.nodeType = booleanType();
	presentLit.flags = presentLit.flags.incl(NodeFlag.Sem);
	const wrapped = createNode(NodeKind.ObjectLiteral, {
		properties: [expr, presentLit],
		keys: ["value", "present"],
		keyLocations: [expr.location, expr.location],
	} as NodeData, wrapTok);
	wrapped.nodeType = formal;
	wrapped.flags = wrapped.flags.incl(NodeFlag.Sem);
	return wrapped;
}

// ===== Bitwise Operator Validation =====
// Reference parity: bitwise ops only have integer overloads. No float/double variants.
// Enums are integer-backed → allowed (Standard reference parity: enums can use bitwise ops).
// number (float64) → warning + implicit int32 cast (TypeScript ergonomics).

export function isBitwiseBinaryOp(op: string): boolean {
	return op == "&" || op == "|" || op == "^" || op == "<<" || op == ">>" || op == ">>>";
}

export function isBitwiseAllowed(t: Type | null): boolean {
	if (t == null) return false;
	if (bitSetElemType(t) != null) return true;
	return isIntegerType(t) || t.kind == TypeKind.Enum || t.kind == TypeKind.BigInt;
}


function reportOrdinalEnumMix(ctx: CheckerContext, op: string, leftType: Type, rightType: Type, node: Node): boolean {
	if (op != "|" && op != "&" && op != "^") return false;
	if (leftType == null || rightType == null) return false;
	if (leftType.kind != TypeKind.Enum || rightType.kind != TypeKind.Enum) return false;
	if (!isOrdinalEnum(leftType) && !isOrdinalEnum(rightType)) return false;
	if (leftType.typeName == "" || rightType.typeName == "") return false;
	if (leftType.typeName == rightType.typeName) return false;
	addError(ctx, "bitwise operator '" + op + "' on '" + typeDisplayName(leftType) + "' and '" + typeDisplayName(rightType) + "' mixes different enum sets", node.location.line, node.location.column);
	return true;
}

// A BitSet combines only with its own element enum or an identical BitSet;
// anything else is a silently wrong mask, so it is rejected here rather than
// falling through to the integer rule.
function reportBitSetMismatch(ctx: CheckerContext, op: string, leftType: Type, rightType: Type, node: Node): boolean {
	const leftElem = bitSetElemType(leftType);
	const rightElem = bitSetElemType(rightType);
	if (leftElem == null && rightElem == null) return reportOrdinalEnumMix(ctx, op, leftType, rightType, node);
	const sizedElem = leftElem != null ? leftElem : rightElem;
	if (sizedElem != null && sizedElem.typeNames.length > BITSET_MAX_MEMBERS) {
		addError(ctx, "BitSet holds at most " + BITSET_MAX_MEMBERS.toString() + " members; enum '" + sizedElem.typeName + "' has " + sizedElem.typeNames.length.toString(), node.location.line, node.location.column);
		return true;
	}
	const leftName = leftElem != null ? leftElem.typeName : (leftType != null && leftType.kind == TypeKind.Enum ? leftType.typeName : "");
	const rightName = rightElem != null ? rightElem.typeName : (rightType != null && rightType.kind == TypeKind.Enum ? rightType.typeName : "");
	if (leftName != "" && leftName == rightName) return false;
	addError(ctx, "bitwise operator '" + op + "' on '" + typeDisplayName(leftType) + "' and '" + typeDisplayName(rightType) + "' mixes different enum sets", node.location.line, node.location.column);
	return true;
}

// TS parity: bigint never coerces to or from another numeric type, so a mixed
// arithmetic/bitwise operand pair is a compile error rather than a conversion.
// Returns true when the caller must abandon the node as an error.
export function rejectBigIntMix(ctx: CheckerContext, op: string, leftType: Type | null, rightType: Type | null, node: Node): boolean {
	const leftBig = leftType != null && leftType.kind == TypeKind.BigInt;
	const rightBig = rightType != null && rightType.kind == TypeKind.BigInt;
	if (!leftBig && !rightBig) return false;
	if (op == ">>>") {
		addError(ctx, "operator '>>>' is not allowed on bigint — use '>>'", node.location.line, node.location.column);
		return true;
	}
	if (leftBig == rightBig) return false;
	const isArith = op == "+" || op == "-" || op == "*" || op == "/" || op == "%" || op == "**"
		|| op == "+=" || op == "-=" || op == "*=" || op == "/=" || op == "%=";
	if (!isArith && !isBitwiseBinaryOp(op)) return false;
	const other = leftBig ? rightType : leftType;
	if ((op == "+" || op == "+=") && other != null && isStringLike(other)) return false;
	const otherName = other != null ? typeDisplayName(other) : "unknown";
	addError(ctx, "cannot mix bigint and '" + otherName + "' in '" + op + "' — convert explicitly with BigInt(x) or Number(b)", node.location.line, node.location.column);
	return true;
}

export function checkBitwiseOperands(ctx: CheckerContext, op: string, leftType: Type, rightType: Type, node: Node): void {
	if (reportBitSetMismatch(ctx, op, leftType, rightType, node)) return;
	const leftInt = leftType != null && isBitwiseAllowed(leftType);
	const rightInt = rightType != null && isBitwiseAllowed(rightType);
	const leftNum = leftType != null && leftType.kind == TypeKind.Number;
	const rightNum = rightType != null && rightType.kind == TypeKind.Number;
	// number → warn (TypeScript users), allow with implicit int32 cast.
	// Combined into a single emit so `n1 | n2` (both number) doesn't fire twice
	// — the message refers to the operator, not which operand is numeric.
	if (leftNum || rightNum) {
		addWarning(ctx, "bitwise operator '" + op + "' on 'number' implicitly casts to int32; prefer explicit integer type", node.location.line, node.location.column);
	}
	// Reject non-integer, non-number, non-enum types (string, boolean, etc.)
	if (!leftInt && !leftNum) {
		const name = leftType != null ? typeDisplayName(leftType) : "unknown";
		addError(ctx, "bitwise operator '" + op + "' requires integer type, got '" + name + "'", node.location.line, node.location.column);
	}
	if (!rightInt && !rightNum) {
		const name = rightType != null ? typeDisplayName(rightType) : "unknown";
		addError(ctx, "bitwise operator '" + op + "' requires integer type, got '" + name + "'", node.location.line, node.location.column);
	}
	// Reference parity: both operands must be the same integer size (skip if either is number/enum)
	if (leftInt && rightInt && isIntegerType(leftType) && isIntegerType(rightType) && leftType.kind != rightType.kind) {
		addError(ctx, "bitwise operator '" + op + "' requires same integer size, got '" + typeDisplayName(leftType) + "' and '" + typeDisplayName(rightType) + "'", node.location.line, node.location.column);
	}
}

function operandShape(t: Type): Type | null {
	let s = skipModifier(t);
	for (let depth = 0; depth < PEEL_MAX_DEPTH; depth += 1) {
		const body = distinctBody(s);
		if (body == null) return s;
		s = skipModifier(body);
	}
	return s;
}

function relationalNeedsOperator(t: Type): boolean {
	const s = operandShape(t);
	if (s == null) return false;
	if (s.kind == TypeKind.Struct) return !isMaybeType(s);
	return s.kind == TypeKind.Array || s.kind == TypeKind.SizedArray
		|| s.kind == TypeKind.Span || s.kind == TypeKind.Function || s.kind == TypeKind.Set;
}

export function relationalOperandsFail(ctx: CheckerContext, op: string, leftType: Type, rightType: Type): boolean {
	if (op != "<" && op != ">" && op != "<=" && op != ">=") return false;
	if (leftType == null || rightType == null) return false;
	if (hasGenericParams(leftType) || hasGenericParams(rightType)) return false;
	if (!relationalNeedsOperator(leftType) && !relationalNeedsOperator(rightType)) return false;
	return ctx.extensionRegistry == null
		|| resolveOperatorCall(ctx.table, ctx.extensionRegistry, op, [leftType, rightType]) == null;
}

export function checkRelationalOperands(ctx: CheckerContext, op: string, leftType: Type, rightType: Type, node: Node): void {
	if (!relationalOperandsFail(ctx, op, leftType, rightType)) return;
	addError(ctx, "operator '" + op + "' cannot be applied to types '" + typeDisplayName(leftType)
		+ "' and '" + typeDisplayName(rightType) + "' — declare `function `" + op + "`(a: "
		+ typeDisplayName(leftType) + ", b: " + typeDisplayName(rightType) + "): boolean`",
		node.location.line, node.location.column);
}

function binaryOperandClass(op: string): string {
	if (op == "+" || op == "-" || op == "*" || op == "/" || op == "%" || op == "**") return "arith";
	if (op == "==" || op == "!=" || op == "===" || op == "!==") return "eq";
	return "";
}

function binaryOperandSkip(t: Type): boolean {
	if (t == null) return true;
	const s = skipModifier(t);
	if (hasGenericParams(s) || isUnknownType(s) || isUnresolvedType(s) || isMaybeType(s)) return true;
	const k = s.kind;
	return k == TypeKind.Error || k == TypeKind.Null || k == TypeKind.Union
		|| k == TypeKind.GenericParam || k == TypeKind.GenericInstance
		|| k == TypeKind.TypeReference || k == TypeKind.Inferred || k == TypeKind.None
		|| k == TypeKind.Varargs || k == TypeKind.Alias || k == TypeKind.Conditional
		|| k == TypeKind.Result || k == TypeKind.BigInt;
}

function binaryPointerish(k: TypeKind): boolean {
	return k == TypeKind.Ref || k == TypeKind.Ptr || k == TypeKind.Cursor
		|| k == TypeKind.Borrow || k == TypeKind.Function || k == TypeKind.Array
		|| k == TypeKind.Span || k == TypeKind.SizedArray || k == TypeKind.CString;
}

function arithOperandsOk(op: string, a: Type, b: Type): boolean {
	if (isNumeric(a) && isNumeric(b)) return true;
	if (a.kind == TypeKind.Char || b.kind == TypeKind.Char) return true;
	if (op == "+" && (isStringLike(a) || isStringLike(b))) return true;
	if (a.kind == TypeKind.Ptr || b.kind == TypeKind.Ptr) return true;
	if (a.kind == TypeKind.Enum || b.kind == TypeKind.Enum) return true;
	return false;
}

function sameSetElement(a: Type, b: Type): boolean {
	const ea = bitSetElemType(a);
	const eb = bitSetElemType(b);
	return ea != null && eb != null && ea.typeName == eb.typeName;
}

function equalityOperandsOk(a: Type, b: Type): boolean {
	if (a.kind == TypeKind.Set || b.kind == TypeKind.Set) return sameSetElement(a, b);
	if (isNumeric(a) && isNumeric(b)) return true;
	if (isStringLike(a) && isStringLike(b)) return true;
	if (a.kind == TypeKind.Char || b.kind == TypeKind.Char) return true;
	if (a.kind == TypeKind.Boolean && b.kind == TypeKind.Boolean) return true;
	if (a.kind == TypeKind.BooleanLiteral || b.kind == TypeKind.BooleanLiteral) return true;
	if (a.kind == TypeKind.Enum || b.kind == TypeKind.Enum) return true;
	if (a.kind == TypeKind.EnumLiteral || b.kind == TypeKind.EnumLiteral) return true;
	if (a.kind == TypeKind.Void || b.kind == TypeKind.Void) return true;
	if (a.kind == TypeKind.Tuple && b.kind == TypeKind.Tuple) return true;
	if (a.kind == TypeKind.Struct && b.kind == TypeKind.Struct) return true;
	if (binaryPointerish(a.kind) && binaryPointerish(b.kind)) return true;
	return false;
}

export function widensToBase(ctx: CheckerContext, from: Type | null, to: Type | null): boolean {
	if (from == null || to == null) return false;
	const src = unwrapRef(from);
	const target = unwrapRef(to);
	if (src == null || target == null) return false;
	if (!classDescendsFrom(src.typeName, target.typeName)) return false;
	const srcSym = lookupSymbol(ctx.table, src.typeName);
	if (srcSym == null || srcSym.symbolKind != SymbolKind.Class) return false;
	const targetSym = lookupSymbol(ctx.table, target.typeName);
	return targetSym != null && targetSym.symbolKind == SymbolKind.Class;
}

function compoundBase(op: string): string {
	if (op.length < 2 || !op.endsWith("=") || op == "==" || op == "!=" || op == "<=" || op == ">="
		|| op == "===" || op == "!==") return op;
	return op.slice(0, op.length - 1);
}

export function binaryOperandsFail(ctx: CheckerContext, op: string, leftType: Type, rightType: Type): boolean {
	const bop = compoundBase(op);
	const cls = binaryOperandClass(bop);
	if (cls == "") return false;
	if (leftType == null || rightType == null) return false;
	const a = operandShape(leftType);
	const b = operandShape(rightType);
	if (a == null || b == null || binaryOperandSkip(a) || binaryOperandSkip(b)) return false;
	const ok = cls == "arith" ? arithOperandsOk(bop, a, b) : equalityOperandsOk(a, b);
	if (ok) return false;
	return ctx.extensionRegistry == null
		|| resolveOperatorCall(ctx.table, ctx.extensionRegistry, bop, [leftType, rightType]) == null;
}

export function isFunctionShaped(t: Type | null): boolean {
	if (t == null) return false;
	const s = operandShape(t);
	return s != null && s.kind == TypeKind.Function;
}

function numericLikeOperand(s: Type): boolean {
	return isNumeric(s) || s.kind == TypeKind.Enum || s.kind == TypeKind.EnumLiteral || s.kind == TypeKind.Char;
}

export function unaryArithFails(ctx: CheckerContext, op: string, t: Type | null): boolean {
	if (t == null) return false;
	const s = operandShape(t);
	if (s == null || binaryOperandSkip(s) || numericLikeOperand(s)) return false;
	return ctx.extensionRegistry == null || resolveOperatorCall(ctx.table, ctx.extensionRegistry, op, [t]) == null;
}

export function arrayIndexFails(arrType: Type | null, index: Node): boolean {
	if (arrType == null || index == null as unknown as Node || index.nodeType == null) return false;
	const k = arrType.kind;
	if (k != TypeKind.Array && k != TypeKind.SizedArray && k != TypeKind.Span && !isStringLike(arrType)) return false;
	if (index.kind == NodeKind.BinaryExpr) {
		const rop = (index.data as BinaryExprData).operator;
		if (rop == ".." || rop == "...") return false;
	}
	const s = operandShape(index.nodeType);
	return s != null && !binaryOperandSkip(s) && !numericLikeOperand(s);
}

export function refuseFunctionTruthiness(ctx: CheckerContext, expr: Node): void {
	if (expr == null as unknown as Node || !isFunctionShaped(expr.nodeType) || valueOfInPlace(ctx, expr)) return;
	addError(ctx, "a function is always truthy — call it to test its result", expr.location.line, expr.location.column);
}

export function checkSwitchCase(ctx: CheckerContext, disc: Node, test: Node): void {
	if (disc.nodeType == null || test.nodeType == null) return;
	if (!binaryOperandsFail(ctx, "===", disc.nodeType, test.nodeType)) return;
	if (valueOfInPlace(ctx, disc) && disc.nodeType != null && !binaryOperandsFail(ctx, "===", disc.nodeType, test.nodeType)) return;
	addError(ctx, "case of type '" + typeDisplayName(test.nodeType) + "' is not comparable to the switch value of type '"
		+ typeDisplayName(disc.nodeType!) + "'", test.location.line, test.location.column);
}

export function checkBinaryOperands(ctx: CheckerContext, op: string, leftType: Type, rightType: Type, node: Node): boolean {
	if (!binaryOperandsFail(ctx, op, leftType, rightType)) return false;
	addError(ctx, "operator '" + op + "' cannot be applied to types '" + typeDisplayName(leftType)
		+ "' and '" + typeDisplayName(rightType) + "' — declare `function `" + op + "`(a: "
		+ typeDisplayName(leftType) + ", b: " + typeDisplayName(rightType) + ")`",
		node.location.line, node.location.column);
	return true;
}

// ===== Integer Literal Coercion =====
// Reference parity: standard reference's integer literal and range handling. When a number literal appears
// where an integer type is expected and fits in range, coerce it automatically.

export function isNodeIntLit(node: Node): boolean {
	if (node.kind != NodeKind.NumberLiteral) return false;
	const d = node.data as NumberLiteralData;
	if (d.isFloat) return false;  // 0.0, 1e5 etc. — developer wrote float syntax
	return d.value % 1 == 0;
}

// INT64_MIN is the one int64 that is its own negation.
function isInt64Min(v: int64): boolean {
	return v < 0 && ((0 - (v as uint64)) as int64) == v;
}

// Nim splits this in two. A BIT-PATTERN literal may fill the whole UNSIGNED
// width of its target and still be legal — `0x80` as int8 is -128, deliberately
// (lexer.nim:494-509). A DECIMAL literal is held to the target's SIGNED range
// (lexer.nim:536-548). `negated` is the unary minus the caller folded in: the
// token itself is always a magnitude, because the lexer never eats the sign.
export function literalFitsInType(node: Node, target: Type, negated: boolean): boolean {
	if (!isNodeIntLit(node)) return false;
	const d = node.data as NumberLiteralData;
	const mag = d.value;
	if (d.isBitPattern) {
		return match (target.kind) {
			TypeKind.Int8   => mag <= 255,
			TypeKind.Int16  => mag <= 65535,
			TypeKind.Int32  => mag <= 4294967295,
			TypeKind.Int64  => true,
			TypeKind.Uint8  => mag <= 255,
			TypeKind.Uint16 => mag <= 65535,
			TypeKind.Uint32 => mag <= 4294967295,
			TypeKind.Uint64 => true,
			_ => false,
		};
	}
	const v = negated ? 0 - mag : mag;
	return match (target.kind) {
		TypeKind.Int8   => v >= -128 && v <= 127,
		TypeKind.Int16  => v >= -32768 && v <= 32767,
		TypeKind.Int32  => v >= -2147483648 && v <= 2147483647,
		// Past 2^53 the double cannot answer this, so the magnitude is read off
		// intVal: a negative bit pattern means the magnitude reached 2^63, which
		// only a negated literal may do, and only exactly.
		TypeKind.Int64  => d.intVal >= 0 || (negated && isInt64Min(d.intVal)),
		TypeKind.Uint8  => v >= 0 && v <= 255,
		TypeKind.Uint16 => v >= 0 && v <= 65535,
		TypeKind.Uint32 => v >= 0 && v <= 4294967295,
		TypeKind.Uint64 => !negated || mag == 0,
		_ => false,
	};
}

// The parser decides this on the digits: at the boundary the double in `value`
// cannot separate 2^64-1 from 2^64, and the position the diagnostic needs only
// exists here (parse errors carry line 0).
export function reportLiteralRange(ctx: CheckerContext, node: Node): void {
	const text = (node.data as NumberLiteralData).outOfRangeText;
	if (text != "") {
		addError(ctx, "number out of range: '" + text + "'", node.location.line, node.location.column);
	}
}

// A minus directly in front of a number literal belongs to that literal's range
// rule — Nim folds it onto the token in the lexer (lexer.nim:333). Checked here
// because the operand on its own is a magnitude and cannot tell the legal
// -9223372036854775808 from an int64 overflow.
export function checkNegatedIntLiteral(ctx: CheckerContext, lit: Node, target: Type): void {
	reportLiteralRange(ctx, lit);
	if (!literalFitsInType(lit, target, true)) {
		const mag = (lit.data as NumberLiteralData).value;
		addError(ctx, "cannot convert -" + mag + " to " + typeDisplayName(target), lit.location.line, lit.location.column);
	}
	lit.nodeType = target;
}

// ===== Coercion Protocol — `as<TargetType>` convention =====
// Compiler synthesizes `expr` → `expr.as<TargetType>()` when:
//   - srcType not assignable to targetType, AND
//   - srcType has an extension `as<TargetType>(this T): TargetType` registered.
// Mirrors the toItems / getDynamicField synthesis pattern. Type opts in by
// declaring the extension; non-opt-in types remain strict (fall through to error).
//
// Naming convention: `as` + PascalCase(targetTypeName).
//   string  → asString          int8/16/32/64    → asInt8/asInt16/...
//   number  → asNumber          uint8/16/32/64   → asUint8/...
//   boolean => asBoolean         float32/64       → asFloat32/asFloat64
//   User type Color  → asColor

function coercionMethodName(t: Type): string {
	return match (t.kind) {
		TypeKind.String  => "asString",
		TypeKind.Number  => "asNumber",
		TypeKind.Boolean => "asBoolean",
		TypeKind.Int8    => "asInt8",
		TypeKind.Int16   => "asInt16",
		TypeKind.Int32   => "asInt32",
		TypeKind.Int64   => "asInt64",
		TypeKind.Uint8   => "asUint8",
		TypeKind.Uint16  => "asUint16",
		TypeKind.Uint32  => "asUint32",
		TypeKind.Uint64  => "asUint64",
		TypeKind.Float32 => "asFloat32",
		TypeKind.Float64 => "asFloat64",
		_ => t.typeName != ""
			? "as" + t.typeName.slice(0, 1).toUpperCase() + t.typeName.slice(1, t.typeName.length)
			: "",
	};
}

// Try to synthesize `expr.as<TargetType>()` coercion. Returns the synthesized
// CallExpr on success, or `null as unknown as Node` if no matching extension exists
// or the synthesized call doesn't type-check.
//
// Caller (e.g. fitNode, checkCallExpr arg coercion) substitutes the returned Node
// for `expr` at its slot. Result type matches targetType exactly.
export function trySynthesizeAsCoercion(ctx: CheckerContext, expr: Node, srcType: Type, targetType: Type): Node {
	if (ctx.extensionRegistry == null) return null as unknown as Node;
	// Nullable-ref target (`X | null`): coerce to the non-null member — the
	// synthesized X then flows into X|null via the normal member rule. Interface
	// members sit behind an unnamed Ref wrapper — peel it for the method name.
	if (targetType.kind == TypeKind.Union) {
		let nn = nonNullMemberOfNullable(targetType);
		if (nn != null && (nn.kind == TypeKind.Ref || nn.kind == TypeKind.Ptr) && nn.typeReturn != null) {
			nn = nn.typeReturn;
		}
		if (nn != null && !isUnresolvedType(nn)) targetType = nn;
	}
	const methodName = coercionMethodName(targetType);
	if (methodName == "") return null as unknown as Node;
	const exts = findAllExtensionsByName(ctx.extensionRegistry, methodName);
	if (exts.length == 0) return null as unknown as Node;
	// Receiver and declared return may sit behind unnamed Ref wrappers
	// (interface values) — peel for matching, same as the target peel above.
	let srcForMatch = srcType;
	if ((srcForMatch.kind == TypeKind.Ref || srcForMatch.kind == TypeKind.Ptr) && srcForMatch.typeReturn != null) {
		srcForMatch = srcForMatch.typeReturn;
	}
	const ext = findFirstMatchingExt(exts, srcForMatch);
	if (ext == null) return null as unknown as Node;
	// Verify return type matches target exactly (asInt32 vs asInt64 disambiguation).
	const extFnT = getExtFnType(ext);
	let extRet = extFnT.typeReturn;
	if (extRet != null && (extRet.kind == TypeKind.Ref || extRet.kind == TypeKind.Ptr) && extRet.typeReturn != null) {
		extRet = extRet.typeReturn;
	}
	if (extRet == null) return null as unknown as Node;
	if (extRet.kind != targetType.kind) return null as unknown as Node;
	if (targetType.typeName != "" && extRet.typeName != targetType.typeName) {
		return null as unknown as Node;
	}
	const loc = expr.location;
	const memberNode = createNodeAt(NodeKind.MemberExpr,
		{ object: expr, property: methodName, isOptional: false }, loc);
	const synthCall = createNodeAt(NodeKind.CallExpr,
		{ callee: memberNode, arguments: [], isDirectCall: true, resolvedOverloadIdx: -1 }, loc);
	callCheckExpr(ctx, synthCall, null);
	if (synthCall.nodeType == null) return null as unknown as Node;
	if (synthCall.nodeType.kind == TypeKind.Error) return null as unknown as Node;
	if (isUnresolvedType(synthCall.nodeType)) return null as unknown as Node;
	return synthCall;
}

export function hasValueOfProtocol(ctx: CheckerContext, t: Type | null): boolean {
	if (t == null || ctx.extensionRegistry == null) return false;
	let src = withoutReadonlyView(t);
	if (isUnresolvedType(src) || src.kind == TypeKind.Error || isUnknownType(src)) return false;
	if ((src.kind == TypeKind.Ref || src.kind == TypeKind.Ptr) && src.typeReturn != null) src = src.typeReturn;
	if (src.kind != TypeKind.Distinct && src.kind != TypeKind.GenericInstance && src.kind != TypeKind.Struct) return false;
	const exts = findAllExtensionsByName(ctx.extensionRegistry, "valueOf");
	if (exts.length == 0) return false;
	const ext = findFirstMatchingExt(exts, src);
	if (ext == null) return false;
	const srcName = typeNameOf(src);
	return srcName != "" && srcName == ext.receiverTypeName;
}

export function slotTakesValue(exprType: Type, formal: Type): boolean {
	if (isAssignable(exprType, formal) && !isNominalMismatch(exprType, formal)) return true;
	if (formal.kind == TypeKind.Function) {
		const widened = distinctWidenBody(exprType);
		if (widened != null && isAssignable(widened, formal)) return true;
	}
	if (isMaybeType(formal) && formal.typeReturn != null) return slotTakesValue(exprType, formal.typeReturn);
	if (formal.kind == TypeKind.Union) {
		for (const member of formal.typeChildren) {
			if (member.kind != TypeKind.Null && slotTakesValue(exprType, member)) return true;
		}
	}
	return false;
}

export function operandReadsValue(ctx: CheckerContext, op: string, leftType: Type | null, rightType: Type | null, selfIsLeft: boolean): boolean {
	if (leftType == null || rightType == null) return false;
	const self = selfIsLeft ? leftType : rightType;
	const other = selfIsLeft ? rightType : leftType;
	if (!hasValueOfProtocol(ctx, self)) return false;
	if (compoundBase(op) == "+" && isStringLike(other) && !isStringLike(self)) return true;
	return relationalOperandsFail(ctx, op, leftType, rightType) || binaryOperandsFail(ctx, op, leftType, rightType);
}

export function valueOfInPlace(ctx: CheckerContext, node: Node): boolean {
	if (node == null as unknown as Node || node.flags.has(NodeFlag.ProtocolCall)) return false;
	if (!hasValueOfProtocol(ctx, node.nodeType)) return false;
	const inner = createNodeAt(node.kind, node.data, node.location);
	inner.nodeType = node.nodeType;
	inner.resolvedSym = node.resolvedSym;
	inner.typeExpr = node.typeExpr;
	inner.flowNode = node.flowNode;
	inner.variantSlot = node.variantSlot;
	inner.flags = node.flags.incl(NodeFlag.Sem);
	const member = createNodeAt(NodeKind.MemberExpr, { object: inner, property: "valueOf", isOptional: false }, node.location);
	node.kind = NodeKind.CallExpr;
	node.data = { callee: member, arguments: [], isDirectCall: true, resolvedOverloadIdx: -1 };
	node.flags = node.flags.excl(NodeFlag.Sem);
	node.nodeType = null;
	node.resolvedSym = null;
	node.flowNode = null;
	callCheckExpr(ctx, node, null);
	node.flags = node.flags.incl(NodeFlag.Sem).incl(NodeFlag.ProtocolCall);
	return true;
}


// ===== fitNode — Central Implicit Conversion Insertion =====
// Parity: standard reference's node fitting, conversion matching, and implicit conversion patterns
// Called at every "value flows into typed slot" point:
//   - Variable declaration initializer → declType
//   - Assignment RHS → LHS type
//   - Return argument → function return type
//   - Call arguments (handled separately in checkCallExpr via needsStdConv)
// Wraps expr in HiddenStdConv when narrowing integer conversion is needed.
// Transform phase (rangeCheckInject.ms) later converts HiddenStdConv → range check call.

// Render array-like types as `elem[]` for diagnostics — typeDisplayName otherwise
// shows the bare "Array". Peels a Ref wrapper (owned heap arrays are Ref<Array<T>>)
// at each level so `number[][]` reads back as `number[][]`.
function arrayDisplay(t: Type | null): string {
	let inner = skipModifier(t);
	let peeledRef = false;
	if (inner != null && inner.kind == TypeKind.Ref) { inner = inner.typeReturn; peeledRef = true; }
	if (inner != null && (inner.kind == TypeKind.Array || inner.kind == TypeKind.Span
			|| inner.kind == TypeKind.Ptr || inner.kind == TypeKind.SizedArray)) {
		if (inner.kind == TypeKind.Array && !peeledRef) return "Vec<" + arrayDisplay(inner.typeReturn) + ">";
		return arrayDisplay(inner.typeReturn) + "[]";
	}
	return typeDisplayName(t);
}

// A variant value meeting a union formal needs a real conversion: the C layouts
// differ (variant = plain struct, union = tag + variant slots), and codegen
// picks a temp's type from the STATIC type — so without this node it passes a
// bare variant struct where the union is expected and clang only warns.
// Reference: sigmatch.nim implicitConv(nkHiddenSubConv, ...).
function structuralMemberIndex(formal: Type, exprType: Type): int32 {
	if (!isTagCarriedUnion(formal) || isPrimitiveUnionMember(exprType)) return -1;
	let found: int32 = -1;
	let ci: int32 = 0;
	for (const child of formal.typeChildren) {
		if (child == null || child.kind == TypeKind.Null) return -1;
		if (sameType(child, exprType)) {
			if (found >= 0) return -1;
			found = ci;
		}
		ci += 1;
	}
	return found;
}

function slotHoldsStructByValue(member: Type): boolean {
	const s = peelToStruct(member);
	return s != null && s.kind == TypeKind.Struct;
}

export function widenVariantToUnion(expr: Node, formal: Type, exprType: Type): Node {
	if (unwrapRefNullUnion(formal) != null) return null as unknown as Node;
	// A flow-narrowed reference types as the variant, but its storage is the
	// declared union struct — wrapping it would deref that struct as a variant
	// pointer. The fit is an identity pass; stamping the position's type as
	// the union keeps every downstream repr decision (address-of at the call,
	// return/NRVO shape) identical to an un-narrowed reference.
	if (declaredTagUnionOf(expr) != null) {
		if (formal.kind == TypeKind.Union) {
			expr.nodeType = formal;
			return expr;
		}
		return null as unknown as Node;
	}
	const valueType = unwrapRef(exprType);
	let vi = variantIndexInUnion(formal, valueType);
	if (vi < 0) vi = structuralMemberIndex(formal, exprType);
	if (vi < 0) return null as unknown as Node;
	const convTok = createToken(TokenKind.Ident, "", expr.location.line);
	// A union slot holds the variant BY VALUE, so a ref operand is READ and
	// copied, never consumed: handing the pointer to the conversion makes the
	// analyzer sink it (wasMoved) and the heap cell is then destroyed by
	// nobody. Spelling the deref keeps the ref owned by its own scope and
	// routes the payload through the ordinary value-copy path.
	let operand = expr;
	if (valueType != exprType && slotHoldsStructByValue(formal.typeChildren[vi])) {
		const drefNode = createNode(NodeKind.HiddenDeref, { expr: expr }, convTok);
		drefNode.nodeType = valueType;
		operand = drefNode;
	}
	const convNode = createNode(NodeKind.HiddenSubConv, { convExpr: operand, convType: formal }, convTok);
	convNode.nodeType = formal;
	// Same stamp convention as the object-literal path: codegen reads the slot,
	// it never re-derives one (+1 so 0 keeps meaning "not set").
	convNode.flags = convNode.flags.incl(NodeFlag.Sem);
	convNode.variantSlot = vi + 1;
	return convNode;
}

// The nullable twin of widenVariantToUnion: `string | null` meeting
// `number | string | null` is the same subtyping one level down, under the
// Maybe carrier. It cannot be a reinterpret — the narrow carrier holds its
// payload bare where the wide one holds a tagged union — so it takes the same
// conversion node, stamped with the same slot, and codegen rebuilds the
// carrier around an injected payload.
export function widenMaybePayload(expr: Node, formal: Type, exprType: Type): Node {
	const vi = maybePayloadWidenSlot(exprType, formal);
	if (vi < 0) return null as unknown as Node;
	const convTok = createToken(TokenKind.Ident, "", expr.location.line);
	const convNode = createNode(NodeKind.HiddenSubConv, { convExpr: expr, convType: formal }, convTok);
	convNode.nodeType = formal;
	convNode.flags = convNode.flags.incl(NodeFlag.Sem);
	convNode.variantSlot = vi + 1;
	return convNode;
}

// Declared (pre-narrowing) tagged union of a reference — the checker-side twin
// of codegen's duDeclaredUnionOfObject. Null-member and all-strlit unions are
// excluded for the same repr reasons as primitiveMemberIndexInUnion.
function declaredTagUnionOf(expr: Node): Type | null {
	let walk: Node = expr;
	while (walk != null && walk.kind == NodeKind.TypeAssertion) {
		walk = (walk.data as TypeAssertionData).asExpr;
	}
	if (walk == null || walk.kind != NodeKind.Identifier || walk.resolvedSym == null) return null;
	const t = walk.resolvedSym.symbolType;
	if (t == null || t.kind != TypeKind.Union || t.typeChildren == null) return null;
	if (unwrapRefNullUnion(t) != null) return null;
	let allStrLit = true;
	for (const child of t.typeChildren) {
		if (child == null || child.kind == TypeKind.Null) return null;
		if (child.kind != TypeKind.StringLiteral) allStrLit = false;
	}
	if (allStrLit) return null;
	return t;
}

// The projection twin of widenVariantToUnion: a flow-narrowed reference whose
// DECLARED type is a tagged union types as the member, but its C storage is
// still the union struct — codegen needs a node selecting the active slot.
// Same stamp convention (+1 so 0 means "not set"); the emitter tells the two
// directions apart by convType: union = inject, member = project.
export function narrowUnionToVariant(expr: Node, exprType: Type): Node {
	if (exprType.kind == TypeKind.Union) return null as unknown as Node;
	const declared = declaredTagUnionOf(expr);
	if (declared == null) return null as unknown as Node;
	let vi: int32 = -1;
	let ci: int32 = 0;
	for (const child of declared.typeChildren) {
		if (child == exprType) { vi = ci; break; }
		ci += 1;
	}
	if (vi < 0) {
		const value = unwrapRef(exprType);
		vi = value != null && value.kind == TypeKind.Struct
			? variantIndexInUnion(declared, value)
			: primitiveMemberIndexInUnion(declared, exprType);
	}
	if (vi < 0) return null as unknown as Node;
	const member = declared.typeChildren[vi];
	const convTok = createToken(TokenKind.Ident, "", expr.location.line);
	const convNode = createNode(NodeKind.HiddenSubConv, { convExpr: expr, convType: member }, convTok);
	convNode.nodeType = member;
	convNode.flags = convNode.flags.incl(NodeFlag.Sem);
	convNode.variantSlot = vi + 1;
	return convNode;
}

// Adoption action for isAnonStructAdoption pairs: re-construct the frozen
// anonymous value member-wise as the named struct. Identifier sources only —
// anything else would need single-eval temp machinery. Returns null when the
// pair does not adopt; callers fall through to their existing reject path.
export function tryAdoptAnonStruct(expr: Node, formalIn: Type | null, exprTypeIn: Type | null): Node {
	const formal = skipModifier(formalIn);
	const exprType = skipModifier(exprTypeIn);
	if (formal == null || exprType == null) return null as unknown as Node;
	if (expr.kind != NodeKind.Identifier) return null as unknown as Node;
	if (!isAnonStructAdoption(exprType, formal)) return null as unknown as Node;
	const tok = createToken(TokenKind.Ident, "", expr.location.line);
	const props: Node[] = [];
	const keys: string[] = [];
	const keyLocs: SourceLocation[] = [];
	const identD = expr.data as IdentifierData;
	for (let i = 0; i < formal.typeNames.length; i += 1) {
		const objNode = createNode(NodeKind.Identifier, { name: identD.name } as NodeData, tok);
		objNode.resolvedSym = expr.resolvedSym;
		objNode.nodeType = exprType;
		objNode.flags = objNode.flags.incl(NodeFlag.Sem);
		objNode.location = expr.location;
		const mem = createNode(NodeKind.MemberExpr, { object: objNode, property: formal.typeNames[i], isOptional: false } as NodeData, tok);
		mem.nodeType = formal.typeChildren[i];
		mem.flags = mem.flags.incl(NodeFlag.Sem);
		mem.location = expr.location;
		props.push(mem);
		keys.push(formal.typeNames[i]);
		keyLocs.push(expr.location);
	}
	const lit = createNode(NodeKind.ObjectLiteral, { properties: props, keys: keys, keyLocations: keyLocs } as NodeData, tok);
	lit.nodeType = formal;
	lit.flags = lit.flags.incl(NodeFlag.Sem);
	lit.location = expr.location;
	return lit;
}

export function reportReadonlyDrop(ctx: CheckerContext, source: Type | null, target: Type | null, line: int32, column: int32): void {
	addError(ctx, "Type '" + typeDisplayName(source) + "' is not assignable to type '" + typeDisplayName(target) + "' — a read-only view never converts back to the mutable type (PARALOCK E24)", line, column);
}

export function fitNode(ctx: CheckerContext, expr: Node, formal: Type | null, exprType: Type | null): Node {
	if (formal == null || exprType == null) return expr;
	if (dropsReadonlyView(exprType, formal)) { reportReadonlyDrop(ctx, exprType, formal, expr.location.line, expr.location.column); return expr; }
	if (formal.kind == TypeKind.Unknown || isUnresolvedType(formal)) {
		if (isUnknownType(formal)) {
			let srcT = exprType;
			let probe = expr;
			while (probe.kind == NodeKind.TypeAssertion) {
				probe = (probe.data as TypeAssertionData).asExpr;
				if (probe != null && probe.nodeType != null) srcT = probe.nodeType;
			}
			// Explicit cast chains reinterpret pointer-SIZED scalars (Nim isCastable,
			// semexprs.nim:320: dstSize >= srcSize / integral); fat values stay illegal.
			const castReinterpretOk = probe != expr && srcT != null
				&& (isIntegerType(srcT) || srcT.kind == TypeKind.Boolean || srcT.kind == TypeKind.Char || srcT.kind == TypeKind.Enum);
			if (!isPointerShapedForUnknown(srcT) && !castReinterpretOk) {
				addError(ctx, "cannot pass value type " + typeDisplayName(srcT) + " as unknown — no void* representation (box it or pass a Ref/Ptr)", expr.location.line, expr.location.column);
			}
		}
		return expr;
	}
	if (exprType.kind == TypeKind.Unknown || isUnresolvedType(exprType)) {
		const collapsed = formal.kind == TypeKind.Union ? unwrapRefNullUnion(formal) : null;
		const unknownFamilyFormal = formal.kind == TypeKind.GenericParam
			|| (collapsed != null && (collapsed.kind == TypeKind.Unknown || isUnresolvedType(collapsed)));
		if (isUnknownType(exprType) && !unknownFamilyFormal) {
			addError(ctx, "unknown is not assignable to " + typeDisplayName(formal) + " — narrow with an explicit cast", expr.location.line, expr.location.column);
		}
		return expr;
	}
	if (exprType.kind == TypeKind.Never) return expr;
	if (exprType.kind == TypeKind.Void && formal.kind != TypeKind.Void
		&& formal.kind != TypeKind.GenericParam) {
		addError(ctx, "type 'void' is not assignable to type '" + typeDisplayName(formal)
			+ "' — a void call produces no value", expr.location.line, expr.location.column);
		return expr;
	}
	if (!hasGenericParams(formal) && !slotTakesValue(exprType, formal) && valueOfInPlace(ctx, expr)) {
		return fitNode(ctx, expr, formal, expr.nodeType);
	}
	const adopted = tryAdoptAnonStruct(expr, formal, exprType);
	if (adopted != null as unknown as Node) return adopted;
	// Direct function → closure auto-wrap (Reference parity: nkHiddenSubConv → nkClosure).
	// When a named function (CcDefault) flows into a closure-typed slot (CcClosure),
	// wrap as `{fn: expr, env: null}` ObjectLiteral with NodeFlag.Closure.
	// Catches: var init, return, object field with closure type — `closureCallMarker.ms`
	// already handles the call-arg case via wrapFuncArgsAsThunks.
	if (formal.kind == TypeKind.Function && exprType.kind == TypeKind.Function
		&& formal.callConv == CallingConvention.CcClosure
		&& exprType.callConv != CallingConvention.CcClosure
		&& expr.kind == NodeKind.Identifier
		&& expr.resolvedSym != null
		&& expr.resolvedSym.symbolKind == SymbolKind.Function) {
		const wrapTok = createToken(TokenKind.Ident, "", expr.location.line);
		const nullNode = createNode(NodeKind.NullLiteral, { nullPlaceholder: true } as NodeData, wrapTok);
		nullNode.nodeType = nullType();
		nullNode.flags = nullNode.flags.incl(NodeFlag.Sem);
		const wrapped = createNode(NodeKind.ObjectLiteral, {
			properties: [expr, nullNode],
			keys: ["fn", "env"],
			keyLocations: [expr.location, expr.location],
		} as NodeData, wrapTok);
		wrapped.nodeType = formal;
		wrapped.flags = wrapped.flags.incl(NodeFlag.Closure).incl(NodeFlag.Sem);
		return wrapped;
	}
	// Implicit T → Maybe<T> coercion (Nim-parity `some(val)` / `none(T)`).
	// MUST run BEFORE the same-kind early return below — both Token and
	// Maybe<Token> have kind=Struct, so kind-equality alone wouldn't distinguish
	// them. Skip when expr is already Maybe-typed (passthrough like
	// `return otherMaybeFn()`).
	if (isMaybeType(formal) && formal.typeReturn != null && !isMaybeType(exprType)) {
		if (isNominalMismatch(exprType, formal)) {
			addError(ctx, "Type '" + typeDisplayName(exprType) + "' is not assignable to type '" + typeDisplayName(formal.typeReturn) + " | null'", expr.location.line, expr.location.column);
			return expr;
		}
		return synthMaybeWrap(expr, formal, exprType);
	}
	if (isMaybeType(formal) && isMaybeType(exprType)) {
		const widenedMaybe = widenMaybePayload(expr, formal, exprType);
		if (widenedMaybe != null as unknown as Node) return widenedMaybe;
	}
	// A variant value meeting a union formal converts HERE so every fit
	// position (var init, assign, return, ternary, call arg) shares the one
	// wrap — no position can forget it. Nilable pointer unions collapse to a
	// bare pointer and take no tag.
	if (formal.kind == TypeKind.Union && exprType.kind != TypeKind.Union
		&& unwrapRefNullUnion(formal) == null) {
		const widened = widenVariantToUnion(expr, formal, exprType);
		if (widened != null as unknown as Node) return widened;
	}
	if (formal.kind != TypeKind.Union && exprType.kind != TypeKind.Union) {
		const projected = narrowUnionToVariant(expr, exprType);
		if (projected != null as unknown as Node) return projected;
	}
	if (isNominalMismatch(exprType, formal)) {
		addError(ctx, "Type '" + typeDisplayName(exprType) + "' is not assignable to type '" + typeDisplayName(formal) + "'", expr.location.line, expr.location.column);
		return expr;
	}
	if (formal.kind == exprType.kind && !isReinterpretUnsafe(exprType, formal)) return expr;
	if ((exprType.kind == TypeKind.CString && formal.kind == TypeKind.String)
		|| ((exprType.kind == TypeKind.String || exprType.kind == TypeKind.StringLiteral)
			&& formal.kind == TypeKind.CString)) {
		const convTok = createToken(TokenKind.Ident, "", expr.location.line);
		const convNode = createNode(NodeKind.HiddenStdConv, { convExpr: expr, convType: formal }, convTok);
		convNode.nodeType = formal;
		convNode.flags = convNode.flags.incl(NodeFlag.Sem);
		return convNode;
	}
	// A float reaching an integer slot drops its fractional part, and at the
	// field / element / return positions there is no annotation beside the
	// value to warn the reader — so the cut has to be the programmer's word,
	// spelled `as intN`. An integral literal still flows implicitly because
	// nothing is lost, which is the line zig draws with "fractional component
	// prevents float value from coercion".
	if ((isFloatType(exprType) || exprType.kind == TypeKind.Number)
		&& isIntegerType(formal)
		&& !isIntegralNumberLiteral(expr)) {
		addError(ctx, "implicit " + typeDisplayName(exprType) + " → " + typeDisplayName(formal)
			+ " narrowing drops the fractional part — write an explicit 'as " + typeDisplayName(formal) + "'",
			expr.location.line, expr.location.column);
		return expr;
	}
	// Narrowing integer conversion: wrap in HiddenStdConv
	if (isNarrowingIntConv(exprType, formal)) {
		const convTok = createToken(TokenKind.Ident, "", expr.location.line);
		const convNode = createNode(NodeKind.HiddenStdConv, { convExpr: expr, convType: formal }, convTok);
		convNode.nodeType = formal;
		convNode.flags = convNode.flags.incl(NodeFlag.Sem);
		return convNode;
	}
	if (isWideningInt64Conv(exprType, formal)) {
		const convTok = createToken(TokenKind.Ident, "", expr.location.line);
		const convNode = createNode(NodeKind.HiddenStdConv, { convExpr: expr, convType: formal }, convTok);
		convNode.nodeType = formal;
		convNode.flags = convNode.flags.incl(NodeFlag.Sem);
		return convNode;
	}
	// Convention-based coercion protocol: try `expr.as<TargetType>()` synthesis.
	// Opt-in for any type via extension methods named asString/asNumber/asBoolean/asInt32/etc.
	const coercionCall = trySynthesizeAsCoercion(ctx, expr, exprType, formal);
	if (coercionCall != null as unknown as Node) {
		return coercionCall;
	}
	// Scope: the memory-safety class only — container element-repr and pointer vs
	// scalar. General `!isAssignable` rejection is intentionally NOT applied — see
	// NIM-REF.md "Container element assignability + enforcement site" (terminal;
	// two intentional divergences: TS non-null types + Ref→Ptr cursor).
	if (isReinterpretUnsafe(exprType, formal)) {
		addError(ctx, "Type '" + arrayDisplay(exprType) + "' is not assignable to type '" + arrayDisplay(formal) + "' — memory layout differs (pointer vs scalar, array element, shared field, or function signature repr); a raw cast would reinterpret, not convert (convert explicitly or provide an as" + (formal.typeName != "" ? formal.typeName.slice(0, 1).toUpperCase() + formal.typeName.slice(1, formal.typeName.length) : "X") + " extension)", expr.location.line, expr.location.column);
	}
	return expr;
}

// A float literal whose value has no fractional part converts exactly, so it
// keeps flowing into an integer slot. The magnitude guard keeps the round-trip
// itself well defined; anything past it cannot fit an integer slot anyway.
export function isIntegralNumberLiteral(expr: Node): boolean {
	if (expr.kind != NodeKind.NumberLiteral) return false;
	const v = (expr.data as NumberLiteralData).value;
	if (v > 9007199254740991.0 || v < -9007199254740991.0) return false;
	const truncated = v as int64;
	return (truncated as float64) == v;
}

// Walk through TypeAssertion chain to check if core expression is NullLiteral.
// Matches: null, null as unknown, null as unknown as T, etc.
function isNullAssertion(node: Node): boolean {
	if (node == null) return false;
	if (node.kind == NodeKind.NullLiteral) return true;
	if (node.kind == NodeKind.TypeAssertion) {
		return isNullAssertion((node.data as TypeAssertionData).asExpr);
	}
	return false;
}

// Unwrap `expr as unknown` chains — returns inner expr if found, null otherwise.
// General: collapses TS-specific double-cast before downstream handlers run.
export function unwrapAsUnknown(node: Node): Node | null {
	if (node == null) return null;
	if (node.kind == NodeKind.TypeAssertion) {
		const d = node.data as TypeAssertionData;
		if (d.asType == "unknown") return d.asExpr;
		// Nested: `expr as unknown as unknown` (unlikely but safe)
		return unwrapAsUnknown(d.asExpr);
	}
	return null;
}
