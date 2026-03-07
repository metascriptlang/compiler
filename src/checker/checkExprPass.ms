// Expression Checker — type inference for all expression kinds
// Extracted from checkPass.ms. Uses checkerCallbacks for mutual recursion with checkStmt.

import {
	Node, NodeKind, NodeData, createNode, NodeFlag,
	IdentifierData, BinaryExprData, UnaryExprData, UpdateExprData,
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
	createArray, createSpan, createFunction, createTypeRef, substituteType, instantiateGeneric,
	isNumeric, isStringType, isCallable, getReturnType, getElementType, getProperty, sizeOfType,
	typeNameOf, unwrapRef,
	unifyType, createUnifyBindings, hasGenericParams,
	getMinArity,
} from "./types";
import {
	Symbol, SymbolKind, ScopeKind, SymbolState,
	defineSymbol, lookupSymbol, makeSymbol, openScope, closeScope, hasOverloads,
} from "./symbol";
import { CheckerContext, addError, findAllExtensionsByName, ExtensionMethod, isCancelled } from "./context";
import {
	scoreCandidate, isAssignable, needsStdConv, resolveOverloadIdx,
	findFirstMismatch, typeRelation, TypeRelation,
	scoreCandidatePriority, isNoMatch, emptyCandidateScore, cmpCandidates,
} from "./compat";
import { callCheckStmt, registerCheckExpr } from "./checkerCallbacks";
import { resolveAnnotation, ensureShaped } from "./resolvePass";
import { parseNumberLiteral, sliceStr, findChar } from "../utils/string";

// ===== Standard-Aligned Extension Receiver Matching =====
// Standard reference pattern for extension matching compares nominal types by identity.
// We use isAssignable on the extension's receiver param type (fnType.typeChildren[0])
// instead of string-based receiverTypeName comparison, which breaks for parameterized
// types like number[] (parser produces "number [ ]" but typeNameOf returns "Array").

function isReceiverMatch(ext: ExtensionMethod, objType: Type): boolean {
	// Static extensions: string-based matching (receiver not in typeChildren)
	if (ext.isStatic) {
		return ext.receiverTypeName === typeNameOf(objType);
	}
	// Instance extensions: type-based matching on first param
	if (ext.fnType.kind !== TypeKind.Function) return false;
	if (ext.fnType.typeChildren.length === 0) return false;
	const receiverType = ext.fnType.typeChildren[0];
	// Unknown receiver: match any (conservative — unresolved type)
	if (receiverType.kind === TypeKind.Unknown) return true;
	// Generic extensions: try unification on receiver param (standard-aligned selective match).
	// e.g. map<T>(this arr: T[]) should match number[] but NOT string.
	if (hasGenericParams(receiverType)) {
		const eb = createUnifyBindings();
		unifyType(receiverType, objType, eb);
		return eb.names.length > 0;
	}
	// Concrete array extensions: match only when element types are directly compatible.
	// Strict check prevents push(this arr: number[]) from falsely matching Node[] or Type[].
	// Unknown elements fall through to isAssignable (preserves inference-pending behavior).
	if (receiverType.kind === TypeKind.Array && objType.kind === TypeKind.Array) {
		const recvElem = receiverType.typeReturn;
		const objElem = objType.typeReturn;
		if (recvElem === null || objElem === null) return false;
		if (recvElem.kind !== TypeKind.Unknown && objElem.kind !== TypeKind.Unknown) {
			return isAssignable(objElem, recvElem);
		}
	}
	return isAssignable(objType, receiverType);
}

function findFirstMatchingExt(exts: ExtensionMethod[], objType: Type): ExtensionMethod {
	let i = 0;
	while (i < exts.length) {
		if (isReceiverMatch(exts[i], objType)) return exts[i];
		i = i + 1;
	}
	return null as unknown as ExtensionMethod;
}

function filterExtsByReceiverType(exts: ExtensionMethod[], objType: Type): ExtensionMethod[] {
	const results: ExtensionMethod[] = [];
	let i = 0;
	while (i < exts.length) {
		if (isReceiverMatch(exts[i], objType)) {
			results.push(exts[i]);
		}
		i = i + 1;
	}
	return results;
}

// ===== Expression Checker =====

export function checkExpr(ctx: CheckerContext, node: Node, expectedType: Type): Type {
	// Implementation parity: skip already-checked nodes (nfSem guard)
	if ((node.flags & NodeFlag.Sem) !== 0 && node.nodeType !== null) return node.nodeType;
	if (isCancelled(ctx.cancelCtx, ctx.cancelVersion)) return unknownType();

	const result = match (node.kind) {
		NodeKind.NumberLiteral | NodeKind.BigIntLiteral => numberType(),
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
			const rightType = checkExpr(ctx, d.right, rightExpected);
			inferBinaryOp(d.operator, leftType, rightType);
		},
		NodeKind.UnaryExpr => {
			const d = node.data as UnaryExprData;
			checkExpr(ctx, d.operand, null as unknown as Type);
			inferUnaryOp(d.unaryOp);
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
			if (expectedType !== null && expectedType.kind === TypeKind.Object
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
			// reference parity: resolve as-cast target to actual union variant type.
			// If source is Union and target matches a variant by first field name,
			// use the variant type (preserves identity for codegen variant access).
			if (srcType !== null && srcType.kind === TypeKind.Union && targetType.kind === TypeKind.Object && srcType.typeChildren !== null && targetType.typeNames !== null && targetType.typeNames.length > 0) {
				const firstField = targetType.typeNames[0];
				let vi = 0;
				while (vi < srcType.typeChildren.length) {
					const variant = srcType.typeChildren[vi];
					if (variant !== null && variant.typeNames !== null && variant.typeNames.length > 0 && variant.typeNames[0] === firstField) {
						node.nodeType = variant;
						break;
					}
					vi = vi + 1;
				}
				if (node.nodeType === null) node.nodeType = targetType;
			} else {
				node.nodeType = targetType;
			}
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
			for (const arg of d.newArguments) {
				checkExpr(ctx, arg, null as unknown as Type);
			}
			if (calleeType.kind === TypeKind.Object || calleeType.kind === TypeKind.Ref) {
				calleeType;
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
			if (isNumeric(leftType) && isNumeric(rightType)) return numberType();
			unknownType();
		},
		"-" => {
			if (leftType !== null && leftType.kind === TypeKind.Ptr && rightType !== null && rightType.kind === TypeKind.Ptr) return numberType();
			if (leftType !== null && leftType.kind === TypeKind.Ptr) return leftType;
			numberType();
		},
		"*" | "/" | "%" | "**" => numberType(),
		"&" | "|" | "^" | "<<" | ">>" | ">>>" => numberType(),
		"??" => leftType,
		_ => unknownType(),
	};
}

function inferUnaryOp(op: string): Type {
	return match (op) {
		"!" => booleanType(),
		"-" | "+" | "~" => numberType(),
		"typeof" => stringType(),
		_ => unknownType(),
	};
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
			if (objType !== null && objType.typeName !== "") {
				const allByName = findAllExtensionsByName(ctx.extensionRegistry, me.property);
				const staticType = createTypeRef("typeof " + objType.typeName);
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
			const allByName = findAllExtensionsByName(ctx.extensionRegistry, me.property);
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
		return inferGenericReturn(calleeType, argTypes, expectedType);
	}
	return getReturnType(calleeType);
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
			if (pType.kind === TypeKind.Object && aType.kind === TypeKind.Object) {
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
	// Nim parity: strip Ref/Ptr BEFORE field resolution, insert deref AFTER
	// Nim: skipTypes(ty, {tyRef, tyPtr, ...}) → lookup field → makeDeref
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
		// Nim parity: insert HiddenDeref AFTER field resolution succeeds
		if (needsDeref) {
			const tok = createToken(TokenKind.Ident, "", node.location.line);
			const derefNode = createNode(NodeKind.HiddenDeref, { expr: d.object }, tok);
			derefNode.nodeType = resolvedObjType;
			d.object = derefNode;
		}
		// Resolve property symbol: search symbol table for ClassName_propName
		if (resolvedObjType.typeName !== "") {
			const propSymName = resolvedObjType.typeName + "_" + d.property;
			const propSym = lookupSymbol(ctx.table, propSymName);
			if (propSym !== null) {
				ensureShaped(propSym, ctx);
				node.resolvedSym = propSym;
			} else {
				// Search within the object type's own members if not found in top-level table
				// (e.g. for members of classes defined in the same module)
				let mi = 0;
				for (const mName of resolvedObjType.typeNames) {
					if (mName === d.property) {
						// Create a synthetic symbol for this member to satisfy the validator
						const synthSym = makeSymbol(mName, SymbolKind.Method, resolvedObjType.typeChildren[mi], false);
						synthSym.state = SymbolState.Shaped;
						// Transfer nativeName metadata from Type to Symbol
						// (collectPass stores nativeName in Type.typeName for class methods)
						if (resolvedObjType.typeChildren[mi].typeName !== "") {
							synthSym.nativeName = resolvedObjType.typeChildren[mi].typeName;
						}
						node.resolvedSym = synthSym;
						break;
					}
					mi = mi + 1;
				}
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
	// Fall back to extension registry — standard-aligned type-based lookup
	if (ctx.extensionRegistry !== null) {
		const allByName = findAllExtensionsByName(ctx.extensionRegistry, d.property);
		let ext = findFirstMatchingExt(allByName, objType);
		// Static extension fallback: match 'typeof Type'
		if (ext === null && objType.typeName !== "") {
			const staticType = createTypeRef("typeof " + objType.typeName);
			ext = findFirstMatchingExt(allByName, staticType);
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
				// Wildcard/binding — Nim's else has no pattern nodes at all.
				// We set nodeType for validator; no symbol needed (never referenced).
				hasWildcard = true;
				p.nodeType = discType;
			} else {
				// Extract enum member name before checkExpr (which rewrites MemberExpr → Identifier)
				if (p.kind === NodeKind.MemberExpr) {
					const pmd = p.data as MemberExprData;
					coveredMembers.push(pmd.property);
				}
				// All pattern expressions: semConstExpr + fitNode (Nim parity)
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

export function checkAnonymousFunction(ctx: CheckerContext, name: string, params: string[], body: Node): Type {
	const savedReturn = ctx.inferredReturn;
	ctx.inferredReturn = unknownType();

	const savedFunction = ctx.currentFunction;
	const sym = makeSymbol(name, SymbolKind.Function, unknownType(), false);
	ctx.currentFunction = sym;
	openScope(ctx.table, ScopeKind.Function);
	for (const p of params) {
		defineSymbol(ctx.table, makeSymbol(p, SymbolKind.Parameter, unknownType(), false));
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
	for (const p of params) { types.push(unknownType()); }
	if (inferredRet.kind !== TypeKind.Unknown) {
		return createFunction(types, params, inferredRet);
	}
	return createFunction(types, params, unknownType());
}

function checkArrowExpr(ctx: CheckerContext, node: Node): Type {
	const d = node.data as ArrowFunctionData;
	return checkAnonymousFunction(ctx, "<arrow>", d.arrowParams, d.arrowBody);
}

function checkFuncExpr(ctx: CheckerContext, node: Node): Type {
	const d = node.data as FunctionExprData;
	return checkAnonymousFunction(ctx, "(anon)", d.funcExprParams, d.funcExprBody);
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
		while (b < str.length && str.charAt(b) !== "`") {
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
		while (c < str.length && str.charAt(c) !== "`") {
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
				idNode.nodeType = sym.symType;
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
