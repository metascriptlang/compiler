// Expression Checker — type inference for all expression kinds
// Extracted from checkPass.ms. Uses checkerCallbacks for mutual recursion with checkStmt.

import {
	Node, NodeKind, NodeData, createNode, NodeFlag,
	IdentifierData, BinaryExprData, UnaryExprData, UpdateExprData, NumberLiteralData,
	CallExprData, MemberExprData, ArrayAccessData,
	ObjectLiteralData, ArrayLiteralData, ConditionalExprData,
	TypeAssertionData, SpreadExprData, NewExprData, TryExprData,
	AwaitExprData, YieldExprData, MoveExprData, OutExprData, SizeofExprData,
	HiddenDerefData, HiddenStdConvData, MacroInvocationData, StringLiteralData,
	ArrowFunctionData, FunctionExprData, MatchCaseData, MatchExprData,
	FunctionDeclData, BlockStmtData, ExprStmtData,
} from "../ast/node";
import { TokenKind, createToken } from "../lexer/token";
import {
	Type, TypeKind,
	unknownType, numberType, stringType, booleanType, charType,
	voidType, nullType, errorType,
	createArray, createSpan, createFunction, createTypeRef, createStruct, createRef, substituteType, instantiateGeneric,
	isNumeric, isIntegerType, isStringType, isCallable, getReturnType, getElementType, getProperty, sizeOfType,
	typeNameOf, unwrapRef, isDiscriminatedUnion, findVariantByDiscriminant, findFieldInVariant,
	unifyType, createUnifyBindings, hasGenericParams,
	getMinArity, isNarrowingIntConv, CallingConvention,
} from "./types";
import {
	Symbol, SymbolKind, ScopeKind, SymbolState,
	defineSymbol, lookupSymbol, makeSymbol, openScope, closeScope, hasOverloads,
} from "./symbol";
import { CheckerContext, addError, addWarning, findAllExtensionsByName, ExtensionMethod, isCancelled, isReceiverMatch, filterExtsByReceiverType, findFirstMatchingExt } from "./context";
import {
	scoreCandidate, isAssignable, needsStdConv, resolveOverloadIdx,
	findFirstMismatch, typeRelation, TypeRelation,
	scoreCandidatePriority, isNoMatch, emptyCandidateScore, cmpCandidates,
} from "./compat";
import { callCheckStmt, registerCheckExpr } from "./checkerCallbacks";
import { resolveAnnotation, ensureShaped, recordGenericTypeInstantiation, buildTypeArgKey } from "./resolvePass";
import { parseNumberLiteral, sliceStr, findChar, charAt, splitTopLevel, trimStr } from "../utils/string";
import { findCallTypeArg, getExplicitTypeArg, getGenericDecl } from "../parser/context";

// Extension receiver matching functions imported from context.ms (shared with LSP)

// ===== Expression Checker =====

export function checkExpr(ctx: CheckerContext, node: Node, expectedType: Type): Type {
	// Implementation parity: skip already-checked nodes (nfSem guard)
	if ((node.flags & NodeFlag.Sem) !== 0 && node.nodeType !== null) return node.nodeType;
	if (isCancelled(ctx.cancelCtx, ctx.cancelVersion)) return unknownType();

	const result = match (node.kind) {
		NodeKind.NumberLiteral => {
			if (expectedType !== null && isIntegerType(expectedType)) {
				if (literalFitsInType(node, expectedType)) {
					expectedType;
				} else if (isNodeIntLit(node)) {
					// Reference parity: standard reference's type change diagnostic emits compile-time error for out-of-range literals
					const v = (node.data as NumberLiteralData).value;
					addError(ctx, "cannot convert " + v + " to " + typeNameOf(expectedType), node.location.line, node.location.column);
					expectedType;
				} else {
					numberType();
				}
			} else {
				numberType();
			}
		},
		NodeKind.BigIntLiteral => numberType(),
		NodeKind.StringLiteral => stringType(),
		NodeKind.BooleanLiteral => booleanType(),
		NodeKind.NullLiteral => nullType(),
		NodeKind.RegexLiteral | NodeKind.QuoteExpr | NodeKind.ComptimeBlock => unknownType(),
		NodeKind.Identifier => {
			const d = node.data as IdentifierData;
			const sym = lookupSymbol(ctx.table, d.name);
			if (sym === null) {
				addError(ctx, `Undefined variable '${d.name}'`, node.location.line, node.location.column);
				return errorType();
			}
			// Demand-driven: ensure the symbol's signature is resolved before using its type
			ensureShaped(sym, ctx);
			node.resolvedSym = sym;
			sym.symbolType;
		},
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			const leftType = checkExpr(ctx, d.left, null as unknown as Type);
			// For assignment, pass LHS type as expectedType to RHS
			const rightExpected = (d.operator === "=") ? leftType : null as unknown as Type;
			let rightType = checkExpr(ctx, d.right, rightExpected);
			// Parity: standard reference node fitting — insert HiddenStdConv for narrowing assignment
			if (d.operator === "=" && leftType !== null) {
				d.right = fitNode(ctx, d.right, leftType, rightType);
			}
			// Post-hoc literal coercion: if one side is integer and other is fitting literal, coerce
			let effLeft = leftType;
			let effRight = rightType;
			if (isIntegerType(leftType) && rightType !== null && rightType.kind === TypeKind.Number
				&& isNodeIntLit(d.right) && literalFitsInType(d.right, leftType)) {
				effRight = leftType;
				d.right.nodeType = leftType;
			} else if (isIntegerType(rightType) && leftType !== null && leftType.kind === TypeKind.Number
				&& isNodeIntLit(d.left) && literalFitsInType(d.left, rightType)) {
				effLeft = rightType;
				d.left.nodeType = rightType;
			}
			// Bitwise ops require integer operands (reference parity: no float overloads)
			if (isBitwiseBinaryOp(d.operator)) {
				checkBitwiseOperands(ctx, d.operator, effLeft, effRight, node);
			}
			inferBinaryOp(d.operator, effLeft, effRight);
		},
		NodeKind.UnaryExpr => {
			const d = node.data as UnaryExprData;
			// Propagate expectedType through unary +/- for literal coercion (e.g., -128 → int8)
			const unaryExpected = (d.unaryOp === "-" || d.unaryOp === "+") ? expectedType : null as unknown as Type;
			const operandType = checkExpr(ctx, d.operand, unaryExpected);
			// Bitwise NOT: integer/enum = ok, number = warn, other = error
			if (d.unaryOp === "~") {
				if (operandType !== null && operandType.kind === TypeKind.Number) {
					addWarning(ctx, "bitwise NOT '~' on 'number' implicitly casts to int32; prefer explicit integer type", node.location.line, node.location.column);
				} else if (!isBitwiseAllowed(operandType)) {
					const name = operandType !== null ? typeNameOf(operandType) : "unknown";
					addError(ctx, "bitwise NOT '~' requires integer type, got '" + name + "'", node.location.line, node.location.column);
				}
			}
			inferUnaryOp(d.unaryOp, operandType);
		},
		NodeKind.UpdateExpr => {
			const d = node.data as UpdateExprData;
			checkExpr(ctx, d.updateArg, null as unknown as Type);
			numberType();
		},
		NodeKind.CallExpr => checkCallExpr(ctx, node, expectedType),
		NodeKind.MemberExpr => checkMemberExpr(ctx, node),
		NodeKind.ArrayAccess => {
			const d = node.data as ArrayAccessData;
			const arrType = checkExpr(ctx, d.array, null as unknown as Type);
			checkExpr(ctx, d.index, null as unknown as Type);
			// Range access: arr[start..end] returns Span<elemType>
			let accessType: Type = unknownType();
			if (d.index.kind === NodeKind.BinaryExpr) {
				const bd = d.index.data as BinaryExprData;
				if (bd.operator === ".." || bd.operator === "...") {
					const elemType = (arrType.kind === TypeKind.String) ? charType() : getElementType(arrType);
					accessType = createSpan(elemType);
				} else if (arrType.kind === TypeKind.String) {
					accessType = stringType();
				} else {
					accessType = getElementType(arrType);
				}
			} else if (arrType.kind === TypeKind.String) {
				accessType = stringType();
			} else {
				accessType = getElementType(arrType);
			}
			node.nodeType = accessType;
			accessType;
		},
		NodeKind.ObjectLiteral => {
			const d = node.data as ObjectLiteralData;
			if (expectedType !== null && expectedType.kind === TypeKind.Struct
				&& expectedType.typeChildren !== null) {
				// Implementation parity: stamp literal with expected type, propagate field types
				node.nodeType = expectedType;
				let fi = 0;
				while (fi < d.properties.length) {
					const fieldExpected = (fi < expectedType.typeChildren.length)
						? expectedType.typeChildren[fi]
						: null as unknown as Type;
					checkExpr(ctx, d.properties[fi], fieldExpected);
					fi = fi + 1;
				}
				expectedType;
			} else if (expectedType !== null && expectedType.kind === TypeKind.Union
				&& isDiscriminatedUnion(expectedType)) {
				// Discriminated union construction validation
				checkDiscriminatedConstruction(ctx, node, d, expectedType);
			} else {
				for (const prop of d.properties) {
					checkExpr(ctx, prop, null as unknown as Type);
				}
				unknownType();
			}
		},
		NodeKind.ArrayLiteral => {
			const d = node.data as ArrayLiteralData;
			const elemExpected = (expectedType !== null
				&& (expectedType.kind === TypeKind.Array || expectedType.kind === TypeKind.SizedArray)
				&& expectedType.typeReturn !== null)
				? expectedType.typeReturn
				: null as unknown as Type;
			if (d.elements.length === 0) {
				if (expectedType !== null && (expectedType.kind === TypeKind.Array || expectedType.kind === TypeKind.SizedArray)) {
					expectedType;
				} else {
					createArray(unknownType());
				}
			} else {
				const elemType = checkExpr(ctx, d.elements[0], elemExpected);
				let i = 1;
				while (i < d.elements.length) { checkExpr(ctx, d.elements[i], elemExpected); i += 1; }
				if (expectedType !== null && (expectedType.kind === TypeKind.Array || expectedType.kind === TypeKind.SizedArray)) {
					expectedType;
				} else {
					createArray(elemType);
				}
			}
		},
		NodeKind.ArrowFunction => checkArrowExpr(ctx, node),
		NodeKind.FunctionExpr => checkFuncExpr(ctx, node),
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			checkExpr(ctx, d.ternaryCondition, null as unknown as Type);
			const consequentType = checkExpr(ctx, d.ternaryConsequent, expectedType);
			checkExpr(ctx, d.ternaryAlternate, expectedType);
			consequentType;
		},
		NodeKind.TypeAssertion => {
			const d = node.data as TypeAssertionData;
			const srcType = checkExpr(ctx, d.asExpr, null as unknown as Type);
			const targetType = (d.asType !== "") ? resolveAnnotation(d.asType, ctx) : unknownType();
			// Standard reference parity: cast just sets result.typ = targetType, no variant resolution.
			// Field type info is already in targetType (from type alias or inline struct).
			// C codegen handles variant index resolution at emission time.
			node.nodeType = targetType;
			node.nodeType;
		},
		NodeKind.SpreadExpr => {
			const d = node.data as SpreadExprData;
			checkExpr(ctx, d.spreadArg, null as unknown as Type);
			unknownType();
		},
		NodeKind.NewExpr => {
			const d = node.data as NewExprData;
			const calleeType = checkExpr(ctx, d.newCallee, null as unknown as Type);
			// Resolve generic type args: new Box<number>(42)
			let resolvedType = calleeType;
			if (d.newCallee.kind === NodeKind.Identifier) {
				const calleeName = (d.newCallee.data as IdentifierData).name;
				const ltCol = d.newCallee.location.column + calleeName.length;
				const typeArgStr = getExplicitTypeArg(d.newCallee.location.line, ltCol);
				if (typeArgStr !== "") {
					const genericParams = getGenericDecl(calleeName);
					if (genericParams !== "") {
						const args = splitTopLevel(typeArgStr, ",");
						recordGenericTypeInstantiation(calleeName, genericParams, args, ctx);
						// Build instantiated Ref<Struct> type
						const typeArgKey = buildTypeArgKey(args, ctx);
						const mangledName = calleeName + "__" + typeArgKey;
						const baseSym = lookupSymbol(ctx.table, calleeName);
						if (baseSym !== null) {
							ensureShaped(baseSym, ctx);
							const baseType = baseSym.symbolType;
							// Substitute generic params with concrete types
							const paramNames = splitTopLevel(genericParams, ",");
							const trimmedParamNames: string[] = [];
							const concreteTypes: Type[] = [];
							for (let pi = 0; pi < paramNames.length; pi += 1) {
								trimmedParamNames.push(trimStr(paramNames[pi]));
								const argName = pi < args.length ? trimStr(args[pi]) : "";
								concreteTypes.push(resolveAnnotation(argName, ctx));
							}
							const instType = instantiateGeneric(baseType, trimmedParamNames, concreteTypes);
							// Set mangled name on inner struct
							const instInner = (instType.kind === TypeKind.Ref && instType.typeReturn !== null) ? instType.typeReturn : instType;
							instInner.typeName = mangledName;
							resolvedType = instType;
						}
					}
				}
			}
			// Resolve inner struct type for field type propagation
			const innerType = (resolvedType !== null && resolvedType.kind === TypeKind.Ref && resolvedType.typeReturn !== null)
				? resolvedType.typeReturn : resolvedType;
			const fieldTypes = (innerType !== null && innerType.typeChildren !== null) ? innerType.typeChildren : null as unknown as Type[];
			let ai = 0;
			while (ai < d.newArguments.length) {
				const argExpected = (fieldTypes !== null && ai < fieldTypes.length) ? fieldTypes[ai] : null as unknown as Type;
				checkExpr(ctx, d.newArguments[ai], argExpected);
				ai = ai + 1;
			}
			if (resolvedType.kind === TypeKind.Struct || resolvedType.kind === TypeKind.Ref) {
				resolvedType;
			} else {
				unknownType();
			}
		},
		NodeKind.TryExpr => checkTryExpr(ctx, node),
		NodeKind.MatchExpr => checkMatchExpr(ctx, node),
		NodeKind.AwaitExpr => {
			const d = node.data as AwaitExprData;
			checkExpr(ctx, d.awaitArg, null as unknown as Type);
			unknownType();
		},
		NodeKind.YieldExpr => {
			const d = node.data as YieldExprData;
			checkExpr(ctx, d.yieldArg, null as unknown as Type);
			unknownType();
		},
		NodeKind.MoveExpr => {
			const d = node.data as MoveExprData;
			// Validate operand: only identifiers, member access, array access, and calls allowed
			if (d.moveArg.kind !== NodeKind.Identifier
				&& d.moveArg.kind !== NodeKind.MemberExpr
				&& d.moveArg.kind !== NodeKind.ArrayAccess
				&& d.moveArg.kind !== NodeKind.CallExpr) {
				addError(ctx, "invalid 'move' operand: expected identifier, field access, array access, or call expression", node.location.line, node.location.column);
			}
			checkExpr(ctx, d.moveArg, null as unknown as Type);
		},
		NodeKind.OutExpr => {
			const d = node.data as OutExprData;
			checkExpr(ctx, d.outArg, null as unknown as Type);
			unknownType();
		},
		NodeKind.SizeofExpr => {
			const d = node.data as SizeofExprData;
			const resolved = resolveAnnotation(d.sizeofType, ctx);
			const size = sizeOfType(resolved);
			node.kind = NodeKind.NumberLiteral;
			node.data = { value: size } as unknown as NodeData;
			numberType();
		},
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => {
			const d = node.data as HiddenDerefData;
			checkExpr(ctx, d.expr, null as unknown as Type);
		},
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => {
			const d = node.data as HiddenStdConvData;
			checkExpr(ctx, d.convExpr, null as unknown as Type);
			d.convType;
		},
		NodeKind.MacroInvocation => {
			// Implementation parity: pragma/macro args are type-checked
			const md = node.data as MacroInvocationData;
			// reference parity: @emit backtick interpolation (reference emit processing)
			if (md.macroName === "emit") {
				processEmitInterpolation(ctx, md, node);
			}
			let ai = 0;
			while (ai < md.macroArgs.length) {
				checkExpr(ctx, md.macroArgs[ai], null as unknown as Type);
				ai = ai + 1;
			}
			voidType();
		},
		_ => unknownType(),
	};
	node.nodeType = result;
	node.flags = node.flags | NodeFlag.Sem;
	return result;
}

// ===== Operator Inference =====

function inferBinaryOp(op: string, leftType: Type, rightType: Type): Type {
	return match (op) {
		"===" | "!==" | "==" | "!=" | "<" | ">" | "<=" | ">=" => booleanType(),
		"&&" | "||" => leftType,
		"+" => {
			if (isStringType(leftType) || isStringType(rightType)) return stringType();
			if (leftType !== null && leftType.kind === TypeKind.Ptr) return leftType;
			if (rightType !== null && rightType.kind === TypeKind.Ptr) return rightType;
			// Reference parity: int32 + int32 → int32 (magic proc preserves type)
			if (isIntegerType(leftType) && isIntegerType(rightType) && leftType.kind === rightType.kind) return leftType;
			if (isNumeric(leftType) && isNumeric(rightType)) return numberType();
			unknownType();
		},
		"-" => {
			if (leftType !== null && leftType.kind === TypeKind.Ptr && rightType !== null && rightType.kind === TypeKind.Ptr) return numberType();
			if (leftType !== null && leftType.kind === TypeKind.Ptr) return leftType;
			// Reference parity: int32 - int32 → int32
			if (isIntegerType(leftType) && isIntegerType(rightType) && leftType.kind === rightType.kind) return leftType;
			numberType();
		},
		"*" | "/" | "%" | "**" => {
			// Reference parity: int32 * int32 → int32
			if (isIntegerType(leftType) && isIntegerType(rightType) && leftType.kind === rightType.kind) return leftType;
			numberType();
		},
		"&" | "|" | "^" | "<<" | ">>" | ">>>" => {
			if (isIntegerType(leftType)) return leftType;
			numberType();
		},
		"??" => leftType,
		_ => unknownType(),
	};
}

function inferUnaryOp(op: string, operandType: Type): Type {
	return match (op) {
		"!" => booleanType(),
		"-" | "+" => {
			// Reference parity: -int32 → int32, +int32 → int32
			if (isIntegerType(operandType)) return operandType;
			numberType();
		},
		"~" => {
			// Reference parity: ~int32 → int32
			if (isIntegerType(operandType)) return operandType;
			numberType();
		},
		"typeof" => stringType(),
		_ => unknownType(),
	};
}

// ===== Bitwise Operator Validation =====
// Reference parity: bitwise ops only have integer overloads. No float/double variants.
// Enums are integer-backed → allowed (Standard reference parity: enums can use bitwise ops).
// number (float64) → warning + implicit int32 cast (TypeScript ergonomics).

function isBitwiseBinaryOp(op: string): boolean {
	return op === "&" || op === "|" || op === "^" || op === "<<" || op === ">>" || op === ">>>";
}

function isBitwiseAllowed(t: Type): boolean {
	if (t === null) return false;
	return isIntegerType(t) || t.kind === TypeKind.Enum;
}

function checkBitwiseOperands(ctx: CheckerContext, op: string, leftType: Type, rightType: Type, node: Node): void {
	const leftInt = leftType !== null && isBitwiseAllowed(leftType);
	const rightInt = rightType !== null && isBitwiseAllowed(rightType);
	const leftNum = leftType !== null && leftType.kind === TypeKind.Number;
	const rightNum = rightType !== null && rightType.kind === TypeKind.Number;
	// number → warn (TypeScript users), allow with implicit int32 cast
	if (leftNum) {
		addWarning(ctx, "bitwise operator '" + op + "' on 'number' implicitly casts to int32; prefer explicit integer type", node.location.line, node.location.column);
	}
	if (rightNum) {
		addWarning(ctx, "bitwise operator '" + op + "' on 'number' implicitly casts to int32; prefer explicit integer type", node.location.line, node.location.column);
	}
	// Reject non-integer, non-number, non-enum types (string, boolean, etc.)
	if (!leftInt && !leftNum) {
		const name = leftType !== null ? typeNameOf(leftType) : "unknown";
		addError(ctx, "bitwise operator '" + op + "' requires integer type, got '" + name + "'", node.location.line, node.location.column);
	}
	if (!rightInt && !rightNum) {
		const name = rightType !== null ? typeNameOf(rightType) : "unknown";
		addError(ctx, "bitwise operator '" + op + "' requires integer type, got '" + name + "'", node.location.line, node.location.column);
	}
	// Reference parity: both operands must be the same integer size (skip if either is number/enum)
	if (leftInt && rightInt && isIntegerType(leftType) && isIntegerType(rightType) && leftType.kind !== rightType.kind) {
		addError(ctx, "bitwise operator '" + op + "' requires same integer size, got '" + typeNameOf(leftType) + "' and '" + typeNameOf(rightType) + "'", node.location.line, node.location.column);
	}
}

// ===== Integer Literal Coercion =====
// Reference parity: standard reference's integer literal and range handling. When a number literal appears
// where an integer type is expected and fits in range, coerce it automatically.

function isNodeIntLit(node: Node): boolean {
	if (node.kind !== NodeKind.NumberLiteral) return false;
	const d = node.data as NumberLiteralData;
	const v = d.value;
	return v % 1 === 0;
}

function literalFitsInType(node: Node, target: Type): boolean {
	if (!isNodeIntLit(node)) return false;
	const v = (node.data as NumberLiteralData).value;
	return match (target.kind) {
		TypeKind.Int8   => v >= -128 && v <= 127,
		TypeKind.Int16  => v >= -32768 && v <= 32767,
		TypeKind.Int32  => v >= -2147483648 && v <= 2147483647,
		TypeKind.Int64  => true,
		TypeKind.Uint8  => v >= 0 && v <= 255,
		TypeKind.Uint16 => v >= 0 && v <= 65535,
		TypeKind.Uint32 => v >= 0 && v <= 4294967295,
		TypeKind.Uint64 => v >= 0,
		_ => false,
	};
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

export function fitNode(ctx: CheckerContext, expr: Node, formal: Type, exprType: Type): Node {
	if (formal === null || exprType === null) return expr;
	if (formal.kind === TypeKind.Unknown || exprType.kind === TypeKind.Unknown) return expr;
	if (formal.kind === exprType.kind) return expr;
	// Narrowing integer conversion: wrap in HiddenStdConv
	if (isNarrowingIntConv(exprType, formal)) {
		const convTok = createToken(TokenKind.Ident, "", expr.location.line);
		const convNode = createNode(NodeKind.HiddenStdConv, { convExpr: expr, convType: formal }, convTok);
		convNode.nodeType = formal;
		convNode.flags = convNode.flags | NodeFlag.Sem;
		return convNode;
	}
	return expr;
}

// ===== Callee Name Extraction =====

function getCalleeName(callee: Node): string {
	if (callee.kind === NodeKind.Identifier) {
		return (callee.data as IdentifierData).name;
	}
	if (callee.kind === NodeKind.MemberExpr) {
		return (callee.data as MemberExprData).property;
	}
	return "<unknown>";
}

// ===== Default Parameter Filling =====

function getCalleeNameForDefaults(callNode: Node): string {
	const cd = callNode.data as CallExprData;
	if (cd.callee.kind === NodeKind.Identifier) {
		return (cd.callee.data as IdentifierData).name;
	}
	return "";
}

function makeNumberDefault(val: number): Node {
	const tok = createToken(TokenKind.Number, "", 0);
	return createNode(NodeKind.NumberLiteral, { value: val }, tok);
}
function makeStringDefault(val: string): Node {
	const tok = createToken(TokenKind.String, "", 0);
	return createNode(NodeKind.StringLiteral, { value: val }, tok);
}
function makeBoolDefault(val: boolean): Node {
	const tok = createToken(TokenKind.Ident, "", 0);
	return createNode(NodeKind.BooleanLiteral, { boolValue: val }, tok);
}
function makeNullDefault(): Node {
	const tok = createToken(TokenKind.Ident, "", 0);
	return createNode(NodeKind.NullLiteral, { nullPlaceholder: true }, tok);
}
function makeIdentDefault(name: string): Node {
	const tok = createToken(TokenKind.Ident, "", 0);
	return createNode(NodeKind.Identifier, { name }, tok);
}

function defaultTextToNode(text: string): Node {
	if (text === "true") return makeBoolDefault(true);
	if (text === "false") return makeBoolDefault(false);
	if (text === "null") return makeNullDefault();
	if (text === "\"\"") return makeStringDefault("");
	// String literal: starts with "
	if (text.length > 1 && text[0] === "\"") {
		return makeStringDefault(text.slice(1, text.length - 1));
	}
	// Try parsing as number (num !== num checks for NaN)
	const num = parseNumberLiteral(text);
	if (num === num) return makeNumberDefault(num);
	// Empty array — use identifier fallback
	// Identifier (enum member, variable, etc.)
	return makeIdentDefault(text);
}

function fillDefaultArgsForNode(ctx: CheckerContext, callNode: Node, fnName: string,
	totalParams: number): void {
	const cd = callNode.data as CallExprData;
	// Get defaults from Symbol (works for both same-module and cross-module)
	let fnDefaults: string[] = null as unknown as string[];
	if (cd.callee.resolvedSym !== null) {
		// Prefer Symbol.defaultParamText (set by resolvePass + collectPass cross-module)
		if (cd.callee.resolvedSym.defaultParamText !== null && cd.callee.resolvedSym.defaultParamText.length > 0) {
			fnDefaults = cd.callee.resolvedSym.defaultParamText;
		} else if (cd.callee.resolvedSym.declNode !== null && cd.callee.resolvedSym.declNode.kind === NodeKind.FunctionDecl) {
			// Fallback: read from FunctionDeclData.fnDefaults (same-module, declNode is the actual FunctionDecl)
			const declData = cd.callee.resolvedSym.declNode.data as FunctionDeclData;
			if (declData.fnDefaults !== null) fnDefaults = declData.fnDefaults;
		}
	}
	let argIdx = cd.arguments.length;
	while (argIdx < totalParams) {
		let text = "";
		if (fnDefaults !== null && argIdx < fnDefaults.length) {
			text = fnDefaults[argIdx];
		}
		if (text === "") { argIdx = argIdx + 1; continue; }
		const defNode = defaultTextToNode(text);
		cd.arguments.push(defNode);
		argIdx = argIdx + 1;
	}
}

// ===== TryExpr =====

function checkTryExpr(ctx: CheckerContext, node: Node): Type {
	const d = node.data as TryExprData;
	const argType = checkExpr(ctx, d.tryArg, null as unknown as Type);
	// tryArg.nodeType = Result<T,E> (set by checkExpr on the CallExpr)
	// resultDesugar reads tryArg.nodeType for the full Result type.
	// TryExpr itself evaluates to T (the unwrapped value).
	if (d.hasCatch) {
		checkExpr(ctx, d.catchVal, null as unknown as Type);
	}
	if (argType !== null && argType.kind === TypeKind.Result && argType.typeReturn !== null) {
		return argType.typeReturn;
	}
	return argType;
}

// ===== Call Expression + Overload Resolution =====

function checkCallExpr(ctx: CheckerContext, node: Node, expectedType: Type): Type {
	const d = node.data as CallExprData;
	// Check callee FIRST to get param types for expectedType propagation (Implementation parity)
	let calleeType = checkExpr(ctx, d.callee, null as unknown as Type);
	// Detect overloaded paths early — these need argTypes for scoring
	let needsOverloadScoring = false;
	let overloadSym: Symbol = null as unknown as Symbol;
	// Check for overloads + set resolvedSym for direct calls
	if (d.callee.kind === NodeKind.Identifier) {
		const calleeName = (d.callee.data as IdentifierData).name;
		const sym = lookupSymbol(ctx.table, calleeName);
		if (sym !== null) {
			// Demand-driven: ensure callee signature is ready
			ensureShaped(sym, ctx);
			node.resolvedSym = sym;
			if (hasOverloads(sym)) {
				needsOverloadScoring = true;
				overloadSym = sym;
			}
		}
		// Reference parity: detect closure calls by type,
		// not symbol kind. If callee type has callConv == ccClosure, mark as indirect call.
		if (calleeType !== null && calleeType.kind === TypeKind.Function
			&& calleeType.callConv === CallingConvention.CcClosure) {
			d.isDirectCall = false;
		}
	} else if (d.callee.kind === NodeKind.MemberExpr) {
		// Method call: resolveMemberExpr already set resolvedSym on the callee node
		if (d.callee.resolvedSym !== null) {
			node.resolvedSym = d.callee.resolvedSym;
		}
		// Static extension override: when MemberExpr resolved to a property (e.g. Result.ok field)
		// but a static extension function exists with @builtin (e.g. Result.ok() constructor),
		// prefer the extension function for call expressions.
		if (ctx.extensionRegistry !== null) {
			const me = d.callee.data as MemberExprData;
			const objType = me.object.nodeType;
			// Use typeNameOf to unwrap Ref<Struct> → struct name (e.g. JSON class → "JSON")
			const objName = objType !== null ? typeNameOf(objType) : "";
			if (objName !== "") {
				let allByName = findAllExtensionsByName(ctx.extensionRegistry, me.property);
				// Also search by mangled name (className_methodName) for class static methods
				if (allByName.length === 0) {
					allByName = findAllExtensionsByName(ctx.extensionRegistry, objName + "_" + me.property);
				}
				const staticType = createTypeRef("typeof " + objName);
				const ext = findFirstMatchingExt(allByName, staticType);
				if (ext !== null) {
					// Direct sym link — no name-based lookup
					const extSym = ext.sym !== null ? ext.sym : lookupSymbol(ctx.table, ext.methodName);
					if (extSym !== null) {
						ensureShaped(extSym, ctx);
						node.resolvedSym = extSym;
						d.callee.resolvedSym = extSym;
						// Update calleeType so generic return inference works below
						if (extSym.symbolType.kind === TypeKind.Function) {
							calleeType = extSym.symbolType;
						}
					}
				}
			}
		}
	}
	// Check args — with expectedType from callee params for non-overloaded calls
	const argTypes: Type[] = [];
	let ai = 0;
	while (ai < d.arguments.length) {
		let paramExpected = null as unknown as Type;
		if (!needsOverloadScoring && calleeType.kind === TypeKind.Function
			&& calleeType.typeChildren !== null
			&& ai < calleeType.typeChildren.length) {
			paramExpected = calleeType.typeChildren[ai];
		}
		const argType = checkExpr(ctx, d.arguments[ai], paramExpected);
		argTypes.push(argType);
		ai = ai + 1;
	}
	// Overloaded direct calls — use argTypes for scoring
	if (needsOverloadScoring) {
		return resolveOverloadCall(ctx, overloadSym, argTypes, node);
	}
	// Extension method overloads: obj.method(args) where multiple extensions match
	// Standard-aligned: collect all extensions by name, then filter by receiver type compatibility
	// Skip when objType is Unknown — can't meaningfully select an overload
	if (d.callee.kind === NodeKind.MemberExpr && ctx.extensionRegistry !== null) {
		const me = d.callee.data as MemberExprData;
		const objType = me.object.nodeType;
		if (objType !== null && objType.kind !== TypeKind.Unknown) {
			let allByName = findAllExtensionsByName(ctx.extensionRegistry, me.property);
			// Also search by mangled name for class methods
			if (allByName.length === 0) {
				const recvName = typeNameOf(objType);
				if (recvName !== "") {
					allByName = findAllExtensionsByName(ctx.extensionRegistry, recvName + "_" + me.property);
				}
			}
			const filtered = filterExtsByReceiverType(allByName, objType);
			if (filtered.length === 1) {
				// Single match — use directly
				const winner = filtered[0];
				if (winner.sym !== null) node.resolvedSym = winner.sym;
				// Strip receiver and return inferred type
				let srcType = winner.fnType;
				if (!winner.isStatic && srcType.typeChildren.length > 0) {
					if (hasGenericParams(srcType)) {
						const eb = createUnifyBindings();
						unifyType(srcType.typeChildren[0], objType, eb);
						if (eb.names.length > 0) srcType = instantiateGeneric(srcType, eb.names, eb.types);
					}
					return inferGenericReturn(srcType, argTypes, expectedType);
				}
				// Explicit type arg resolution for generic methods (e.g. JSON.parse<Person>)
				if (hasGenericParams(srcType)) {
					const explicitArg = findCallTypeArg(node);
					if (explicitArg !== "") {
						return inferGenericReturnWithExplicit(srcType, argTypes, expectedType, explicitArg, ctx);
					}
				}
				return inferGenericReturn(srcType, argTypes, expectedType);
			} else if (filtered.length > 1) {
				return resolveExtensionOverloadCall(ctx, filtered, argTypes, objType, me.property, node);
			}
		}
	}
	// Check argument types + infer generic return
	if (calleeType.kind === TypeKind.Function) {
		// Fill default arguments if too few args provided
		const minAr = getMinArity(calleeType);
		if (argTypes.length < minAr) {
			addError(ctx, "Too few arguments: expected at least " + intToString(minAr) + ", got " + intToString(argTypes.length), node.location.line, node.location.column);
		} else if (argTypes.length > calleeType.typeChildren.length) {
			addError(ctx, "Too many arguments: expected at most " + intToString(calleeType.typeChildren.length) + ", got " + intToString(argTypes.length), node.location.line, node.location.column);
		} else if (argTypes.length < calleeType.typeChildren.length) {
			const calleeNameForDef = getCalleeNameForDefaults(node);
			if (calleeNameForDef !== "") {
				fillDefaultArgsForNode(ctx, node, calleeNameForDef, calleeType.typeChildren.length);
			}
		}
		// Type-check only provided args (defaults are trusted)
		for (let pi = 0; pi < calleeType.typeChildren.length && pi < argTypes.length; pi += 1) {
			const paramType = calleeType.typeChildren[pi];
			if (argTypes[pi] === null || argTypes[pi] === null) continue;
			if (paramType.kind !== TypeKind.Unknown && paramType.kind !== TypeKind.GenericParam
				&& paramType.kind !== TypeKind.Function
				&& argTypes[pi].kind !== TypeKind.Unknown && argTypes[pi].kind !== TypeKind.Error
				&& argTypes[pi].kind !== TypeKind.Function) {
				if (!isAssignable(argTypes[pi], paramType)) {
					const calleeName = getCalleeName(d.callee);
					addError(ctx, "Argument type mismatch in '" + calleeName + "' arg " + intToString(pi) + ": got " + typeNameOf(argTypes[pi]) + ", expected " + typeNameOf(paramType), node.location.line, node.location.column);
				} else if (needsStdConv(argTypes[pi], paramType)) {
					// Implementation parity: insert HiddenStdConv for numeric widening/narrowing OR Span coercion
					const convTok = createToken(TokenKind.Ident, "", d.arguments[pi].location.line);
					const convNode = createNode(NodeKind.HiddenStdConv, { convExpr: d.arguments[pi], convType: paramType }, convTok);
					convNode.nodeType = paramType;
					convNode.flags = convNode.flags | NodeFlag.Sem;
					d.arguments[pi] = convNode;
				}
			}
		}
		// If explicit type args (<T>) and generic params, resolve type args at checker time
		if (hasGenericParams(calleeType)) {
			const explicitArg = findCallTypeArg(node);
			if (explicitArg !== "") {
				return inferGenericReturnWithExplicit(calleeType, argTypes, expectedType, explicitArg, ctx);
			}
		}
		return inferGenericReturn(calleeType, argTypes, expectedType);
	}
	return getReturnType(calleeType);
}

// Resolve generic return type using explicit type arg (e.g. parse<Person>)
function inferGenericReturnWithExplicit(fnType: Type, argTypes: Type[], expectedType: Type, explicitArg: string, ctx: CheckerContext): Type {
	let returnType = fnType.typeReturn;
	if (returnType === null) return unknownType();
	// Resolve the explicit type arg to an actual type
	const resolvedSym = lookupSymbol(ctx.table, explicitArg);
	if (resolvedSym === null) return inferGenericReturn(fnType, argTypes, expectedType);
	const concreteType = resolvedSym.symbolType;
	// Find generic param names in the return type and substitute
	const genericNames = collectGenericParamNames(returnType);
	// Single type arg → bind to first generic param found
	if (genericNames.length > 0) {
		returnType = substituteType(returnType, genericNames[0], concreteType);
	}
	return returnType;
}

// Collect all unique GenericParam type names from a type tree
function collectGenericParamNames(t: Type): string[] {
	const names: string[] = [];
	collectGenericNamesInner(t, names);
	return names;
}

function collectGenericNamesInner(t: Type, names: string[]): void {
	if (t === null) return;
	if (t.kind === TypeKind.GenericParam) {
		// Avoid duplicates
		let found = false;
		for (const n of names) {
			if (n === t.typeName) { found = true; }
		}
		if (!found) names.push(t.typeName);
		return;
	}
	if (t.typeReturn !== null) collectGenericNamesInner(t.typeReturn, names);
	if (t.typeExtra !== null) collectGenericNamesInner(t.typeExtra, names);
	for (let i = 0; i < t.typeChildren.length; i += 1) {
		collectGenericNamesInner(t.typeChildren[i], names);
	}
}

export function inferGenericReturn(fnType: Type, argTypes: Type[], expectedType: Type): Type {
	let returnType = fnType.typeReturn;
	if (returnType === null) return unknownType();
	// Collect all bindings from all params via unification (handles nested generics)
	const b = createUnifyBindings();
	for (let i = 0; i < fnType.typeChildren.length && i < argTypes.length; i += 1) {
		if (argTypes[i] !== null && argTypes[i] !== null && argTypes[i].kind !== TypeKind.Unknown) {
			unifyType(fnType.typeChildren[i], argTypes[i], b);
		}
	}
	// If expected type is available (e.g. from variable decl or return stmt),
	// unify return type with it to bind remaining generic params.
	// This handles Result.ok(x) where T is known from arg but E needs expected type.
	if (expectedType !== null && expectedType.kind !== TypeKind.Unknown) {
		unifyType(returnType, expectedType, b);
	}
	// Apply all bindings to return type
	for (let j = 0; j < b.names.length; j += 1) {
		returnType = substituteType(returnType, b.names[j], b.types[j]);
	}
	return returnType;
}

function resolveOverloadCall(ctx: CheckerContext, sym: Symbol, argTypes: Type[], callNode: Node): Type {
	// Build candidate array: primary at [0], overloads at [1..n]
	const candidates: Type[] = [];
	candidates.push(sym.symbolType);
	let oi = 0;
	while (oi < sym.overloads.length) {
		candidates.push(sym.overloads[oi].symbolType);
		oi = oi + 1;
	}
	// All same scope for now (cross-module scope = Phase 6)
	const scopeDepths: number[] = [];
	let di = 0;
	while (di < candidates.length) {
		scopeDepths.push(0);
		di = di + 1;
	}
	const idx = resolveOverloadIdxWithInheritance(ctx, candidates, argTypes, scopeDepths);
	if (idx === -2) {
		// Ambiguous call — find the two matching candidates for error
		addError(ctx, "Ambiguous call to overloaded function '" + sym.name + "'", callNode.location.line, callNode.location.column);
		return getReturnType(sym.symbolType);
	}
	if (idx === -1) {
		// No matching overload — detailed error with per-candidate mismatch
		let msg = "No matching overload for '" + sym.name + "'\n  Expected one of:";
		let ci = 0;
		while (ci < candidates.length) {
			if (candidates[ci].kind === TypeKind.Function) {
				msg = msg + "\n    " + formatCandidateSig(sym.name, candidates[ci]);
				const mpos = findFirstMismatch(candidates[ci].typeChildren, argTypes, getMinArity(candidates[ci]));
				if (mpos >= 0 && mpos < argTypes.length && mpos < candidates[ci].typeChildren.length) {
					msg = msg + "\n      first mismatch at position " + intToString(mpos + 1) + ": expected '" + typeNameOf(candidates[ci].typeChildren[mpos]) + "', got '" + typeNameOf(argTypes[mpos]) + "'";
				} else if (candidates[ci].typeChildren.length !== argTypes.length) {
					msg = msg + "\n      expected " + intToString(candidates[ci].typeChildren.length) + " argument(s), got " + intToString(argTypes.length);
				}
			}
			ci = ci + 1;
		}
		addError(ctx, msg, callNode.location.line, callNode.location.column);
		return getReturnType(sym.symbolType);
	}
	// Success — store resolved index + symbol on AST node, fill default args, infer return
	const cd = callNode.data as CallExprData;
	cd.resolvedOverloadIdx = idx;
	if (idx === 0) {
		callNode.resolvedSym = sym;
	} else if (idx > 0 && idx - 1 < sym.overloads.length) {
		callNode.resolvedSym = sym.overloads[idx - 1];
	}
	const winner = candidates[idx];
	if (winner.kind === TypeKind.Function && argTypes.length < winner.typeChildren.length) {
		fillDefaultArgsForNode(ctx, callNode, sym.name, winner.typeChildren.length);
	}
	return inferGenericReturn(winner, argTypes, null as unknown as Type);
}

// Resolve extension method overloads: multiple extensions match same receiver+method.
// Each extension's fnType includes the receiver as param[0]; strip it before scoring.
function resolveExtensionOverloadCall(ctx: CheckerContext, exts: ExtensionMethod[],
	argTypes: Type[], objType: Type, methodName: string, callNode: Node): Type {
	const candidates: Type[] = [];
	let ei = 0;
	while (ei < exts.length) {
		let srcType = exts[ei].fnType;
		// Generic: infer type params from receiver first
		if (hasGenericParams(srcType)) {
			const eb = createUnifyBindings();
			unifyType(srcType.typeChildren[0], objType, eb);
			if (eb.names.length > 0) {
				srcType = instantiateGeneric(srcType, eb.names, eb.types);
			}
		}
		// Strip receiver param — build Function(params[1..], return)
		if (!exts[ei].isStatic && srcType.typeChildren.length > 0) {
			const callParams: Type[] = [];
			const callNames: string[] = [];
			let ci = 1;
			while (ci < srcType.typeChildren.length) {
				callParams.push(srcType.typeChildren[ci]);
				ci = ci + 1;
			}
			ci = 1;
			while (ci < srcType.typeNames.length) {
				callNames.push(srcType.typeNames[ci]);
				ci = ci + 1;
			}
			candidates.push(createFunction(callParams, callNames, srcType.typeReturn));
		} else {
			candidates.push(srcType);
		}
		ei = ei + 1;
	}
	// Score and resolve
	const scopeDepths: number[] = [];
	let di = 0;
	while (di < candidates.length) {
		scopeDepths.push(0);
		di = di + 1;
	}
	let idx = resolveOverloadIdxWithInheritance(ctx, candidates, argTypes, scopeDepths);
	if (idx === -2) {
		// Tiebreaker: prefer concrete extension over generic (Standard reference pattern)
		let concreteIdx = -1;
		let concreteCount = 0;
		let ti = 0;
		while (ti < exts.length) {
			if (!hasGenericParams(exts[ti].fnType)) {
				concreteIdx = ti;
				concreteCount = concreteCount + 1;
			}
			ti = ti + 1;
		}
		if (concreteCount === 1) {
			idx = concreteIdx;
		} else {
			addError(ctx, "Ambiguous call to overloaded extension method '" + methodName + "'", callNode.location.line, callNode.location.column);
			return getReturnType(candidates[0]);
		}
	}
	if (idx === -1) {
		let msg = "No matching overload for extension method '" + methodName + "'\n  Expected one of:";
		let ci = 0;
		while (ci < candidates.length) {
			if (candidates[ci].kind === TypeKind.Function) {
				msg = msg + "\n    " + formatCandidateSig(methodName, candidates[ci]);
			}
			ci = ci + 1;
		}
		addError(ctx, msg, callNode.location.line, callNode.location.column);
		return getReturnType(candidates[0]);
	}
	// Set resolvedSym to the winning extension's symbol
	if (idx >= 0 && idx < exts.length && exts[idx].sym !== null) {
		callNode.resolvedSym = exts[idx].sym;
	}
	return inferGenericReturn(candidates[idx], argTypes, null as unknown as Type);
}

function formatCandidateSig(name: string, fnType: Type): string {
	let sig = "function " + name + "(";
	let pi = 0;
	while (pi < fnType.typeChildren.length) {
		if (pi > 0) sig = sig + ", ";
		if (pi < fnType.typeNames.length) {
			sig = sig + fnType.typeNames[pi] + ": ";
		}
		sig = sig + typeNameOf(fnType.typeChildren[pi]);
		pi = pi + 1;
	}
	sig = sig + ")";
	if (fnType.typeReturn !== null) {
		sig = sig + ": " + typeNameOf(fnType.typeReturn);
	}
	return sig;
}

function intToString(n: number): string {
	return match (n) {
		0 => "0", 1 => "1", 2 => "2", 3 => "3", 4 => "4",
		5 => "5", 6 => "6", 7 => "7", 8 => "8", 9 => "9",
		10 => "10", 11 => "11", 12 => "12", 13 => "13", 14 => "14",
		15 => "15", 16 => "16", 17 => "17", 18 => "18", 19 => "19",
		20 => "20",
		_ => "?",
	};
}

// ===== Inheritance Depth (inline — avoids importing symbol.ms in compat.ms) =====

// Walk class inheritance chain from sourceType to targetType.
// Returns depth (1 = direct parent, 2 = grandparent), or -1 if not in chain.
function inheritanceDepth(sourceType: Type, targetType: Type, ctx: CheckerContext): number {
	if (sourceType === null || targetType === null) return -1;
	// Unwrap Ref<Object> to access inner Object's typeName/typeExtra
	const src = unwrapRef(sourceType);
	const tgt = unwrapRef(targetType);
	if (src.typeName === "" || tgt.typeName === "") return -1;
	let current = src;
	let depth = 0;
	while (current !== null) {
		depth = depth + 1;
		if (current.typeExtra === null) return -1;
		if (current.typeExtra.typeName === "") return -1;
		if (current.typeExtra.typeName === tgt.typeName) return depth;
		const baseSym = lookupSymbol(ctx.table, current.typeExtra.typeName);
		if (baseSym === null) return -1;
		if (baseSym.symbolKind !== SymbolKind.Class) return -1;
		current = unwrapRef(baseSym.symbolType);
		if (depth > 20) return -1;
	}
	return -1;
}

// Resolve overloads with inheritance penalty.
function resolveOverloadIdxWithInheritance(ctx: CheckerContext, candidates: Type[],
	argTypes: Type[], scopeDepths: number[]): number {
	let bestIdx = -1;
	let bestScore = emptyCandidateScore();
	let bestType: Type = null as unknown as Type;
	let ambiguous = false;
	let i = 0;
	while (i < candidates.length) {
		if (candidates[i].kind !== TypeKind.Function) { i = i + 1; continue; }
		const score = scoreCandidatePriority(candidates[i].typeChildren, argTypes, getMinArity(candidates[i]));
		if (isNoMatch(score)) { i = i + 1; continue; }
		if (i < scopeDepths.length) {
			score.calleeScope = scopeDepths[i];
		}
		// Compute inheritance penalty
		let maxDepth = -1;
		let pi = 0;
		while (pi < candidates[i].typeChildren.length && pi < argTypes.length) {
			const pType = candidates[i].typeChildren[pi];
			const aType = argTypes[pi];
			if (pType.kind === TypeKind.Struct && aType.kind === TypeKind.Struct) {
				if (pType.typeName !== "" && aType.typeName !== "" && pType.typeName !== aType.typeName) {
					const depth = inheritanceDepth(aType, pType, ctx);
					if (depth > 0 && (maxDepth === -1 || depth > maxDepth)) {
						maxDepth = depth;
					}
				}
			}
			pi = pi + 1;
		}
		if (maxDepth > 0) {
			score.inheritancePenalty = maxDepth;
		}
		if (bestIdx === -1) {
			bestIdx = i;
			bestScore = score;
			bestType = candidates[i];
			ambiguous = false;
		} else {
			const cmp = cmpCandidates(score, bestScore, candidates[i], bestType);
			if (cmp > 0) {
				bestIdx = i;
				bestScore = score;
				bestType = candidates[i];
				ambiguous = false;
			} else if (cmp === 0) {
				ambiguous = true;
			}
		}
		i = i + 1;
	}
	if (ambiguous) return -2;
	return bestIdx;
}

// ===== Member Expression + Extension Method Resolution =====

// Check if a type maps to a pointer in C (Ref, Ptr, Borrow — NOT Object/interface)
function isPointerInC(t: Type, ctx: CheckerContext): boolean {
	if (t === null) return false;
	return t.kind === TypeKind.Ref || t.kind === TypeKind.Ptr || t.kind === TypeKind.Borrow;
}

// Validate object literal construction against a discriminated union type.
// Finds the discriminant field in the literal, resolves the variant, and validates fields.
function checkDiscriminatedConstruction(ctx: CheckerContext, node: Node, d: ObjectLiteralData, unionType: Type): Type {
	const discName = unionType.typeNames[0]; // discriminant field name (e.g. "kind")

	// Find the discriminant field in the object literal keys
	let discIdx = -1;
	let ki = 0;
	while (ki < d.keys.length) {
		if (d.keys[ki] === discName) {
			discIdx = ki;
			ki = d.keys.length; // break
		}
		ki = ki + 1;
	}

	if (discIdx < 0) {
		// No discriminant field — fall back to checking all properties without validation
		for (const prop of d.properties) {
			checkExpr(ctx, prop, null as unknown as Type);
		}
		addError(ctx, "Object literal for discriminated union '" + unionType.typeName + "' missing discriminant field '" + discName + "'", node.location.line, node.location.column);
		node.nodeType = unionType;
		return unionType;
	}

	// Check the discriminant expression first to get its value
	const discExpr = d.properties[discIdx];
	const discType = checkExpr(ctx, discExpr, unionType.typeExtra);

	// Try to extract the enum value name from the discriminant expression
	// After checker rewrites: EnumType.Member → Identifier "EnumType_Member"
	let discValue = "";
	if (discExpr.kind === NodeKind.Identifier) {
		const id = discExpr.data as IdentifierData;
		discValue = id.name;
	}

	// Find matching variant
	let variantIdx = -1;
	if (discValue !== "") {
		variantIdx = findVariantByDiscriminant(unionType, discValue);
		// Also try with underscore → dot conversion: "Kind_A" → "Kind.A"
		if (variantIdx < 0) {
			let dotted = "";
			let ci = 0;
			while (ci < discValue.length) {
				const ch = charAt(discValue, ci);
				if (ch === "_") {
					dotted = dotted + ".";
				} else {
					dotted = dotted + ch;
				}
				ci = ci + 1;
			}
			variantIdx = findVariantByDiscriminant(unionType, dotted);
		}
	}

	if (variantIdx >= 0 && variantIdx < unionType.typeChildren.length) {
		const variant = unionType.typeChildren[variantIdx];
		// Validate remaining fields match this variant
		node.nodeType = unionType;
		let fi = 0;
		while (fi < d.keys.length) {
			if (fi === discIdx) {
				// Discriminant already checked
				fi = fi + 1;
				continue;
			}
			const key = d.keys[fi];
			const fieldType = findFieldInVariant(variant, key);
			if (fieldType !== null) {
				checkExpr(ctx, d.properties[fi], fieldType);
			} else {
				checkExpr(ctx, d.properties[fi], null as unknown as Type);
				addError(ctx, "Field '" + key + "' does not exist on variant " + unionType.typeNames[variantIdx + 1] + " of '" + unionType.typeName + "'", node.location.line, node.location.column);
			}
			fi = fi + 1;
		}
		return unionType;
	}

	// Could not resolve variant — check properties without validation
	let pi = 0;
	while (pi < d.properties.length) {
		if (pi !== discIdx) {
			checkExpr(ctx, d.properties[pi], null as unknown as Type);
		}
		pi = pi + 1;
	}
	node.nodeType = unionType;
	return unionType;
}

function checkMemberExpr(ctx: CheckerContext, node: Node): Type {
	const d = node.data as MemberExprData;
	const objType = checkExpr(ctx, d.object, null as unknown as Type);
	// Enum member access: Color.Red → rewrite to Identifier "Color_Red" (standard reference pattern)
	// This rewrites the AST so codegen never sees enum-specific MemberExpr
	if (objType.kind === TypeKind.Enum) {
		const enumName = objType.typeName;
		const mangledName = enumName + "_" + d.property;
		// Rewrite entire node to Identifier
		node.kind = NodeKind.Identifier;
		node.data = { name: mangledName };
		// Find and set the resolved enum member symbol
		const enumSym = lookupSymbol(ctx.table, enumName);
		if (enumSym !== null) {
			const memberSym = lookupSymbol(ctx.table, mangledName);
			node.resolvedSym = memberSym;
		}
		node.nodeType = objType;
		return objType;
	}
	// reference parity: strip Ref/Ptr BEFORE field resolution, insert deref AFTER
	// reference: skip pointer types → lookup field → make dereference
	const needsDeref = isPointerInC(objType, ctx);
	let resolvedObjType = objType;
	if (needsDeref && objType.typeReturn !== null) {
		resolvedObjType = objType.typeReturn;
	}
	const propType = getProperty(resolvedObjType, d.property);
	// Result fields: ok, value, error — synthetic symbol (no typeName on Result)
	if (resolvedObjType.kind === TypeKind.Result && propType.kind !== TypeKind.Unknown) {
		const resultPropSym = makeSymbol(d.property, SymbolKind.Property, propType, false);
		resultPropSym.state = SymbolState.Shaped;
		node.resolvedSym = resultPropSym;
		return propType;
	}
	if (propType.kind !== TypeKind.Unknown) {
		// reference parity: insert HiddenDeref AFTER field resolution succeeds
		if (needsDeref) {
			const tok = createToken(TokenKind.Ident, "", node.location.line);
			const derefNode = createNode(NodeKind.HiddenDeref, { expr: d.object }, tok);
			derefNode.nodeType = resolvedObjType;
			d.object = derefNode;
		}
		// Resolve property symbol: search symbol table for TypeName_propName (named types)
		if (resolvedObjType.typeName !== "") {
			const propSymName = resolvedObjType.typeName + "_" + d.property;
			const propSym = lookupSymbol(ctx.table, propSymName);
			if (propSym !== null) {
				ensureShaped(propSym, ctx);
				node.resolvedSym = propSym;
			}
		}
		// Standard reference parity: fallback — search the type's field list directly
		// (lookupInRecordAndBuildCheck pattern). Works for anonymous structs,
		// type alias targets, and named types whose fields aren't in the symbol table.
		if (node.resolvedSym === null && resolvedObjType.typeNames !== null) {
			let mi = 0;
			for (const mName of resolvedObjType.typeNames) {
				if (mName === d.property) {
					const synthSym = makeSymbol(mName, SymbolKind.Property, resolvedObjType.typeChildren[mi], false);
					synthSym.state = SymbolState.Shaped;
					if (resolvedObjType.typeChildren[mi].typeName !== "") {
						synthSym.nativeName = resolvedObjType.typeChildren[mi].typeName;
					}
					node.resolvedSym = synthSym;
					break;
				}
				mi = mi + 1;
			}
		}
		return propType;
	}

	// Builtin properties: .length on array/string
	if (d.property === "length" && (resolvedObjType.kind === TypeKind.Array || resolvedObjType.kind === TypeKind.String || resolvedObjType.kind === TypeKind.CString)) {
		// Create a synthetic symbol for 'length' to satisfy the validator
		const lengthSym = makeSymbol("length", SymbolKind.Property, numberType(), false);
		lengthSym.state = SymbolState.Shaped;
		node.resolvedSym = lengthSym;
		return numberType();
	}
	// String .code — compile-time char code, folded by constantFolding transform
	if (d.property === "code" && resolvedObjType.kind === TypeKind.String) {
		const codeSym = makeSymbol("code", SymbolKind.Property, numberType(), false);
		codeSym.state = SymbolState.Shaped;
		node.resolvedSym = codeSym;
		return numberType();
	}
	// String-specific properties: .byteLength, .unicodeLength
	if ((d.property === "byteLength" || d.property === "unicodeLength") && resolvedObjType.kind === TypeKind.String) {
		const propSym = makeSymbol(d.property, SymbolKind.Property, numberType(), false);
		propSym.state = SymbolState.Shaped;
		node.resolvedSym = propSym;
		return numberType();
	}
	// Map properties and methods
	if (resolvedObjType.kind === TypeKind.Map) {
		if (d.property === "size") {
			const sizeSym = makeSymbol("size", SymbolKind.Property, numberType(), false);
			sizeSym.state = SymbolState.Shaped;
			node.resolvedSym = sizeSym;
			return numberType();
		}
		// Map methods: get, set, has, delete, clear → function types
		const valType = resolvedObjType.typeExtra !== null ? resolvedObjType.typeExtra : unknownType();
		const keyType = resolvedObjType.typeReturn !== null ? resolvedObjType.typeReturn : unknownType();
		let methodType: Type = null as unknown as Type;
		if (d.property === "get") {
			methodType = createFunction([keyType], ["key"], valType);
		} else if (d.property === "has") {
			methodType = createFunction([keyType], ["key"], booleanType());
		} else if (d.property === "set") {
			methodType = createFunction([keyType, valType], ["key", "value"], voidType());
		} else if (d.property === "delete") {
			methodType = createFunction([keyType], ["key"], booleanType());
		} else if (d.property === "clear") {
			methodType = createFunction([], [], voidType());
		}
		if (methodType !== null) {
			const methodSym = makeSymbol(d.property, SymbolKind.Method, methodType, false);
			methodSym.state = SymbolState.Shaped;
			node.resolvedSym = methodSym;
			return methodType;
		}
	}
	// Set properties and methods
	if (resolvedObjType.kind === TypeKind.Set) {
		if (d.property === "size") {
			const sizeSym = makeSymbol("size", SymbolKind.Property, numberType(), false);
			sizeSym.state = SymbolState.Shaped;
			node.resolvedSym = sizeSym;
			return numberType();
		}
		const elemType = resolvedObjType.typeReturn !== null ? resolvedObjType.typeReturn : unknownType();
		let methodType: Type = null as unknown as Type;
		if (d.property === "has") {
			methodType = createFunction([elemType], ["value"], booleanType());
		} else if (d.property === "add") {
			methodType = createFunction([elemType], ["value"], voidType());
		} else if (d.property === "delete") {
			methodType = createFunction([elemType], ["value"], booleanType());
		} else if (d.property === "clear") {
			methodType = createFunction([], [], voidType());
		}
		if (methodType !== null) {
			const methodSym = makeSymbol(d.property, SymbolKind.Method, methodType, false);
			methodSym.state = SymbolState.Shaped;
			node.resolvedSym = methodSym;
			return methodType;
		}
	}
	// Class method lookup: ClassName_methodName in symbol table (methods are standalone procs)
	if (resolvedObjType.typeName !== "") {
		const classMethName = resolvedObjType.typeName + "_" + d.property;
		const classMethSym = lookupSymbol(ctx.table, classMethName);
		if (classMethSym !== null && classMethSym.symbolKind === SymbolKind.Function) {
			ensureShaped(classMethSym, ctx);
			node.resolvedSym = classMethSym;
			if (needsDeref) {
				const tok = createToken(TokenKind.Ident, "", node.location.line);
				const derefNode = createNode(NodeKind.HiddenDeref, { expr: d.object }, tok);
				derefNode.nodeType = resolvedObjType;
				d.object = derefNode;
			}
			// Strip receiver param (index 0) for instance methods only — static methods have no "this"
			const methType = classMethSym.symbolType;
			if (methType.kind === TypeKind.Function && methType.typeChildren.length > 0 && methType.typeNames.length > 0 && methType.typeNames[0] === "this") {
				const callParams: Type[] = [];
				const callNames: string[] = [];
				for (let ci = 1; ci < methType.typeChildren.length; ci += 1) {
					callParams.push(methType.typeChildren[ci]);
				}
				for (let ci = 1; ci < methType.typeNames.length; ci += 1) {
					callNames.push(methType.typeNames[ci]);
				}
				return createFunction(callParams, callNames, methType.typeReturn);
			}
			return methType;
		}
	}
	// Fall back to extension registry — standard-aligned type-based lookup
	if (ctx.extensionRegistry !== null) {
		let allByName = findAllExtensionsByName(ctx.extensionRegistry, d.property);
		let ext = findFirstMatchingExt(allByName, objType);
		// Static extension fallback: match 'typeof Type'
		if (ext === null && objType.typeName !== "") {
			const staticType = createTypeRef("typeof " + objType.typeName);
			ext = findFirstMatchingExt(allByName, staticType);
			// Also try mangled name (className_methodName) for class static methods
			if (ext === null) {
				const mangledByName = findAllExtensionsByName(ctx.extensionRegistry, objType.typeName + "_" + d.property);
				ext = findFirstMatchingExt(mangledByName, staticType);
			}
		}
		if (ext !== null) {
			// Direct sym link — no name-based lookup needed
			if (ext.sym !== null) {
				ensureShaped(ext.sym, ctx);
				node.resolvedSym = ext.sym;
			}
			// Instance extension: strip receiver param (index 0) so checkCallExpr
			// sees only user-visible params. The receiver is already in MemberExpr.object.
			if (!ext.isStatic && ext.fnType.typeChildren.length > 0) {
				let srcType = ext.fnType;
				// Generic: infer type params from receiver first
				if (hasGenericParams(srcType)) {
					const eb = createUnifyBindings();
					unifyType(srcType.typeChildren[0], objType, eb);
					if (eb.names.length > 0) {
						srcType = instantiateGeneric(srcType, eb.names, eb.types);
					}
				}
				// Strip receiver — build Function(params[1..], return)
				const callParams: Type[] = [];
				const callNames: string[] = [];
				for (let ci = 1; ci < srcType.typeChildren.length; ci += 1) {
					callParams.push(srcType.typeChildren[ci]);
				}
				for (let ci = 1; ci < srcType.typeNames.length; ci += 1) {
					callNames.push(srcType.typeNames[ci]);
				}
				return createFunction(callParams, callNames, srcType.typeReturn);
			}
			return ext.fnType;
		}
	}
	// Unresolved member access — emit error if object type is known
	if (propType.kind === TypeKind.Unknown && resolvedObjType.kind !== TypeKind.Unknown) {
		const typeName = typeNameOf(resolvedObjType) !== "" ? typeNameOf(resolvedObjType) : "object";
		addError(ctx, `Property '${d.property}' does not exist on type '${typeName}'`, node.location.line, node.location.column);
	}
	return propType;
}

// ===== Match Expression =====

function checkMatchExpr(ctx: CheckerContext, node: Node): Type {
	const d = node.data as MatchExprData;
	const discType = checkExpr(ctx, d.matchDisc, null as unknown as Type);
	let returnType = unknownType();
	let hasWildcard = false;
	const coveredMembers: string[] = [];
	for (const c of d.matchCases) {
		const cd = c.data as MatchCaseData;
		for (const p of cd.casePatterns) {
			if (p.kind === NodeKind.Identifier) {
				// Wildcard/binding — Standard reference's else has no pattern nodes at all.
				// We set nodeType for validator; no symbol needed (never referenced).
				hasWildcard = true;
				p.nodeType = discType;
			} else {
				// Extract enum member name before checkExpr (which rewrites MemberExpr → Identifier)
				if (p.kind === NodeKind.MemberExpr) {
					const pmd = p.data as MemberExprData;
					coveredMembers.push(pmd.property);
				}
				// All pattern expressions: semConstExpr + fitNode (reference parity)
				checkExpr(ctx, p, discType);
			}
		}
		let bodyType = unknownType();
		if (cd.caseBody.kind === NodeKind.BlockStmt) {
			// Block arm: check statements inside, infer type from last expression
			callCheckStmt(ctx, cd.caseBody);
			const bd = cd.caseBody.data as BlockStmtData;
			if (bd.statements.length > 0) {
				const last = bd.statements[bd.statements.length - 1];
				if (last.kind === NodeKind.ExprStmt) {
					bodyType = checkExpr(ctx, (last.data as ExprStmtData).expr, null as unknown as Type);
				}
			}
		} else {
			bodyType = checkExpr(ctx, cd.caseBody, null as unknown as Type);
		}
		if (returnType.kind === TypeKind.Unknown && bodyType.kind !== TypeKind.Unknown) {
			returnType = bodyType;
		}
	}
	if (discType.kind === TypeKind.Enum && !hasWildcard) {
		checkEnumExhaustiveness(ctx, discType, coveredMembers);
	}
	return returnType;
}

export function checkEnumExhaustiveness(ctx: CheckerContext, enumType: Type, covered: string[]): void {
	for (const member of enumType.typeNames) {
		let found = false;
		for (const c of covered) {
			if (c === member) { found = true; }
		}
		if (!found) {
			addError(ctx, "Non-exhaustive match: missing '" + enumType.typeName + "." + member + "'", 0, 0);
		}
	}
}

// ===== Anonymous Functions =====

export function checkAnonymousFunction(ctx: CheckerContext, name: string, params: string[], paramTypes: string[], body: Node): Type {
	const savedReturn = ctx.inferredReturn;
	ctx.inferredReturn = unknownType();

	const savedFunction = ctx.currentFunction;
	const sym = makeSymbol(name, SymbolKind.Function, unknownType(), false);
	ctx.currentFunction = sym;
	openScope(ctx.table, ScopeKind.Function);
	let pi = 0;
	for (const p of params) {
		let pType = unknownType();
		if (pi < paramTypes.length && paramTypes[pi] !== "") {
			pType = resolveAnnotation(paramTypes[pi], ctx);
		}
		defineSymbol(ctx.table, makeSymbol(p, SymbolKind.Parameter, pType, false));
		pi += 1;
	}
	if (body.kind === NodeKind.BlockStmt) {
		callCheckStmt(ctx, body);
	} else {
		const exprType = checkExpr(ctx, body, null as unknown as Type);
		if (ctx.inferredReturn.kind === TypeKind.Unknown) {
			ctx.inferredReturn = exprType;
		}
	}
	closeScope(ctx.table);
	ctx.currentFunction = savedFunction;

	const inferredRet = ctx.inferredReturn;
	ctx.inferredReturn = savedReturn;

	const types: Type[] = [];
	let ti = 0;
	for (const p of params) {
		let pType = unknownType();
		if (ti < paramTypes.length && paramTypes[ti] !== "") {
			pType = resolveAnnotation(paramTypes[ti], ctx);
		}
		types.push(pType);
		ti += 1;
	}
	if (inferredRet.kind !== TypeKind.Unknown) {
		return createFunction(types, params, inferredRet);
	}
	return createFunction(types, params, unknownType());
}

function checkArrowExpr(ctx: CheckerContext, node: Node): Type {
	const d = node.data as ArrowFunctionData;
	return checkAnonymousFunction(ctx, "<arrow>", d.arrowParams, d.arrowParamTypes, d.arrowBody);
}

function checkFuncExpr(ctx: CheckerContext, node: Node): Type {
	const d = node.data as FunctionExprData;
	return checkAnonymousFunction(ctx, "(anon)", d.funcExprParams, d.funcExprParamTypes, d.funcExprBody);
}

// ===== @emit Backtick Interpolation (reference emit processing parity) =====
// Scans a single string arg for `identifier` patterns, splits into multiple args:
// string literals for raw text, Identifier nodes for resolved symbols.

function processEmitInterpolation(ctx: CheckerContext, md: MacroInvocationData, node: Node): void {
	if (md.macroArgs.length !== 1) return;
	const arg = md.macroArgs[0];
	if (arg.kind !== NodeKind.StringLiteral) return;
	const sd = arg.data as StringLiteralData;
	const str = sd.value;

	// Quick check: any backticks?
	if (findChar(str, "`") < 0) return;

	// Parse backtick-delimited identifiers (reference pattern: `identifier`)
	const newArgs: Node[] = [];
	const line = node.location.line;
	let a = 0;
	while (a < str.length) {
		let b = a;
		// Find next backtick
		while (b < str.length && charAt(str, b) !== "`") {
			b = b + 1;
		}
		// Emit raw text before backtick
		if (b > a) {
			const sub = sliceStr(str, a, b);
			const strNode = createNode(NodeKind.StringLiteral, { value: sub },
				createToken(TokenKind.StringLiteral, sub, line));
			strNode.nodeType = stringType();
			newArgs.push(strNode);
		}
		if (b >= str.length) break;
		// Find closing backtick
		let c = b + 1;
		while (c < str.length && charAt(str, c) !== "`") {
			c = c + 1;
		}
		if (c >= str.length) {
			// Unterminated backtick — emit identifier text without the backtick (reference: substr(str, b+1))
			const rest = sliceStr(str, b + 1, str.length);
			if (rest.length > 0) {
				const restNode = createNode(NodeKind.StringLiteral, { value: rest },
					createToken(TokenKind.StringLiteral, rest, line));
				restNode.nodeType = stringType();
				newArgs.push(restNode);
			}
			break;
		}
		// Extract identifier between backticks
		const ident = sliceStr(str, b + 1, c);
		if (ident.length > 0) {
			const sym = lookupSymbol(ctx.table, ident);
			if (sym !== null) {
				const idNode = createNode(NodeKind.Identifier, { name: ident },
					createToken(TokenKind.Identifier, ident, line));
				idNode.resolvedSym = sym;
				idNode.nodeType = sym.symbolType;
				newArgs.push(idNode);
			} else {
				// Unknown symbol — keep as string literal (reference behavior)
				const strNode = createNode(NodeKind.StringLiteral, { value: ident },
					createToken(TokenKind.StringLiteral, ident, line));
				strNode.nodeType = stringType();
				newArgs.push(strNode);
			}
		} else {
			// Empty backticks `` — emit single backtick (reference parity: $marker)
			const btNode = createNode(NodeKind.StringLiteral, { value: "`" },
				createToken(TokenKind.StringLiteral, "`", line));
			btNode.nodeType = stringType();
			newArgs.push(btNode);
		}
		a = c + 1;
	}
	// Replace macroArgs with the interpolated args
	md.macroArgs = newArgs;
}

// Register callback at module load time
registerCheckExpr((ctx: CheckerContext, node: Node, expectedType: Type): Type => { return checkExpr(ctx, node, expectedType); });
