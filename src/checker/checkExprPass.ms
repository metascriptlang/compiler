// Expression Checker — type inference for all expression kinds
// Extracted from checkPass.ms. Uses checkerCallbacks for mutual recursion with checkStmt.

import {
	Node, NodeKind, createNode,
	IdentifierData, BinaryExprData, UnaryExprData, UpdateExprData,
	CallExprData, MemberExprData, ArrayAccessData,
	ObjectLiteralData, ArrayLiteralData, ConditionalExprData,
	TypeAssertionData, SpreadExprData, NewExprData, TryExprData,
	AwaitExprData, YieldExprData, MoveExprData, OutExprData,
	ArrowFunctionData, FunctionExprData, MatchCaseData, MatchExprData,
} from "../ast/node";
import { TokenKind, createToken } from "../lexer/token";
import {
	Type, TypeKind,
	unknownType, numberType, stringType, booleanType,
	voidType, nullType, errorType,
	createArray, createFunction, substituteType, instantiateGeneric,
	isNumeric, isStringType, isCallable, getReturnType, getElementType, getProperty,
	typeNameOf,
	unifyType, createUnifyBindings, hasGenericParams,
	getMinArity,
} from "./types";
import {
	Symbol, SymbolKind, ScopeKind,
	defineSymbol, lookupSymbol, makeSymbol, openScope, closeScope, hasOverloads,
} from "./symbol";
import { CheckerContext, addError, findAllExtensionsByName, ExtensionMethod } from "./context";
import {
	scoreCandidate, isAssignable, resolveOverloadIdx,
	findFirstMismatch, typeRelation, TypeRelation,
	scoreCandidatePriority, isNoMatch, emptyCandidateScore, cmpCandidates,
} from "./compat";
import { callCheckStmt, registerCheckExpr } from "./checkerCallbacks";
import { getDefaultText } from "../parser/context";

// ===== Nim-Aligned Extension Receiver Matching =====
// Nim's isAttachableRoutineTo() compares nominal types by identity.
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
	// Generic extensions: try unification on receiver param (Nim-aligned selective match).
	// e.g. map<T>(this arr: T[]) should match number[] but NOT string.
	if (hasGenericParams(ext.fnType)) {
		const eb = createUnifyBindings();
		unifyType(receiverType, objType, eb);
		return eb.names.length > 0;
	}
	// Concrete: check type compatibility
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

export function checkExpr(ctx: CheckerContext, node: Node): Type {
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
				addError(ctx, `Undefined variable '${d.name}'`);
				return errorType();
			}
			sym.symbolType;
		},
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			const leftType = checkExpr(ctx, d.left);
			const rightType = checkExpr(ctx, d.right);
			inferBinaryOp(d.operator, leftType, rightType);
		},
		NodeKind.UnaryExpr => {
			const d = node.data as UnaryExprData;
			checkExpr(ctx, d.operand);
			inferUnaryOp(d.unaryOp);
		},
		NodeKind.UpdateExpr => {
			const d = node.data as UpdateExprData;
			checkExpr(ctx, d.updateArg);
			numberType();
		},
		NodeKind.CallExpr => checkCallExpr(ctx, node),
		NodeKind.MemberExpr => checkMemberExpr(ctx, node),
		NodeKind.ArrayAccess => {
			const d = node.data as ArrayAccessData;
			const arrType = checkExpr(ctx, d.array);
			checkExpr(ctx, d.index);
			getElementType(arrType);
		},
		NodeKind.ObjectLiteral => {
			const d = node.data as ObjectLiteralData;
			for (const prop of d.properties) {
				checkExpr(ctx, prop);
			}
			unknownType();
		},
		NodeKind.ArrayLiteral => {
			const d = node.data as ArrayLiteralData;
			if (d.elements.length === 0) {
				createArray(unknownType());
			} else {
				const elemType = checkExpr(ctx, d.elements[0]);
				let i = 1;
				while (i < d.elements.length) { checkExpr(ctx, d.elements[i]); i += 1; }
				createArray(elemType);
			}
		},
		NodeKind.ArrowFunction => checkArrowExpr(ctx, node),
		NodeKind.FunctionExpr => checkFuncExpr(ctx, node),
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			checkExpr(ctx, d.ternaryCondition);
			const consequentType = checkExpr(ctx, d.ternaryConsequent);
			checkExpr(ctx, d.ternaryAlternate);
			consequentType;
		},
		NodeKind.TypeAssertion => {
			const d = node.data as TypeAssertionData;
			checkExpr(ctx, d.asExpr);
			unknownType();
		},
		NodeKind.SpreadExpr => {
			const d = node.data as SpreadExprData;
			checkExpr(ctx, d.spreadArg);
			unknownType();
		},
		NodeKind.NewExpr => {
			const d = node.data as NewExprData;
			const calleeType = checkExpr(ctx, d.newCallee);
			for (const arg of d.newArguments) {
				checkExpr(ctx, arg);
			}
			if (calleeType.kind === TypeKind.Object) {
				calleeType;
			} else {
				unknownType();
			}
		},
		NodeKind.TryExpr => {
			const d = node.data as TryExprData;
			checkExpr(ctx, d.tryArg);
			unknownType();
		},
		NodeKind.MatchExpr => checkMatchExpr(ctx, node),
		NodeKind.AwaitExpr => {
			const d = node.data as AwaitExprData;
			checkExpr(ctx, d.awaitArg);
			unknownType();
		},
		NodeKind.YieldExpr => {
			const d = node.data as YieldExprData;
			checkExpr(ctx, d.yieldArg);
			unknownType();
		},
		NodeKind.MoveExpr => {
			const d = node.data as MoveExprData;
			// Validate operand: only identifiers, member access, array access, and calls allowed
			if (d.moveArg.kind !== NodeKind.Identifier
				&& d.moveArg.kind !== NodeKind.MemberExpr
				&& d.moveArg.kind !== NodeKind.ArrayAccess
				&& d.moveArg.kind !== NodeKind.CallExpr) {
				addError(ctx, "invalid 'move' operand: expected identifier, field access, array access, or call expression");
			}
			checkExpr(ctx, d.moveArg);
		},
		NodeKind.OutExpr => {
			const d = node.data as OutExprData;
			checkExpr(ctx, d.outArg);
			unknownType();
		},
		_ => unknownType(),
	};
	node.nodeType = result ;
	return result;
}

// ===== Operator Inference =====

function inferBinaryOp(op: string, leftType: Type, rightType: Type): Type {
	return match (op) {
		"===" | "!==" | "==" | "!=" | "<" | ">" | "<=" | ">=" => booleanType(),
		"&&" | "||" => leftType,
		"+" => {
			if (isStringType(leftType) || isStringType(rightType)) return stringType();
			if (isNumeric(leftType) && isNumeric(rightType)) return numberType();
			unknownType();
		},
		"-" | "*" | "/" | "%" | "**" => numberType(),
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
	const num = parseFloat(text);
	if (num === num) return makeNumberDefault(num);
	// Empty array — use identifier fallback
	// Identifier (enum member, variable, etc.)
	return makeIdentDefault(text);
}

function fillDefaultArgsForNode(ctx: CheckerContext, callNode: Node, fnName: string,
	totalParams: number): void {
	const cd = callNode.data as CallExprData;
	let argIdx = cd.arguments.length;
	while (argIdx < totalParams) {
		const text = getDefaultText(fnName, argIdx);
		if (text === "") { argIdx = argIdx + 1; continue; }
		const defNode = defaultTextToNode(text);
		cd.arguments.push(defNode);
		argIdx = argIdx + 1;
	}
}

// ===== Call Expression + Overload Resolution =====

function checkCallExpr(ctx: CheckerContext, node: Node): Type {
	const d = node.data as CallExprData;
	const argTypes: Type[] = [];
	for (const arg of d.arguments) {
		const argType = checkExpr(ctx, arg);
		argTypes.push(argType);
	}
	const calleeType = checkExpr(ctx, d.callee);
	// Check for overloads
	if (d.callee.kind === NodeKind.Identifier) {
		const calleeName = (d.callee.data as IdentifierData).name;
		const sym = lookupSymbol(ctx.table, calleeName);
		if (sym !== null && hasOverloads(sym)) {
			return resolveOverloadCall(ctx, sym, argTypes, node);
		}
	}
	// Extension method overloads: obj.method(args) where multiple extensions match
	// Nim-aligned: collect all extensions by name, then filter by receiver type compatibility
	if (d.callee.kind === NodeKind.MemberExpr && ctx.extensionRegistry !== null) {
		const me = d.callee.data as MemberExprData;
		const objType = me.object.nodeType;
		if (objType !== null) {
			const allByName = findAllExtensionsByName(ctx.extensionRegistry, me.property);
			const filtered = filterExtsByReceiverType(allByName, objType);
			if (filtered.length > 1) {
				return resolveExtensionOverloadCall(ctx, filtered, argTypes, objType, me.property);
			}
		}
	}
	// Check argument types + infer generic return
	if (calleeType.kind === TypeKind.Function) {
		// Fill default arguments if too few args provided
		const minAr = getMinArity(calleeType);
		if (argTypes.length < minAr) {
			addError(ctx, "Too few arguments: expected at least " + intToString(minAr) + ", got " + intToString(argTypes.length));
		} else if (argTypes.length > calleeType.typeChildren.length) {
			addError(ctx, "Too many arguments: expected at most " + intToString(calleeType.typeChildren.length) + ", got " + intToString(argTypes.length));
		} else if (argTypes.length < calleeType.typeChildren.length) {
			const calleeNameForDef = getCalleeNameForDefaults(node);
			if (calleeNameForDef !== "") {
				fillDefaultArgsForNode(ctx, node, calleeNameForDef, calleeType.typeChildren.length);
			}
		}
		// Type-check only provided args (defaults are trusted)
		// Skip for member expression calls — extension method overload resolution may pick
		// wrong overload in single-module mode (missing cross-module type info)
		const skipArgCheck = d.callee.kind === NodeKind.MemberExpr;
		if (!skipArgCheck) {
			for (let pi = 0; pi < calleeType.typeChildren.length && pi < argTypes.length; pi += 1) {
				const paramType = calleeType.typeChildren[pi];
				if (paramType.kind !== TypeKind.Unknown && paramType.kind !== TypeKind.GenericParam
					&& paramType.kind !== TypeKind.Function
					&& argTypes[pi].kind !== TypeKind.Unknown && argTypes[pi].kind !== TypeKind.Error
					&& argTypes[pi].kind !== TypeKind.Function) {
					if (!isAssignable(argTypes[pi], paramType)) {
						const calleeName = getCalleeName(d.callee);
						addError(ctx, "Argument type mismatch in '" + calleeName + "' arg " + intToString(pi) + ": got " + typeNameOf(argTypes[pi]) + ", expected " + typeNameOf(paramType));
					}
				}
			}
		}
		return inferGenericReturn(calleeType, argTypes);
	}
	return getReturnType(calleeType);
}

export function inferGenericReturn(fnType: Type, argTypes: Type[]): Type {
	let returnType = fnType.typeReturn;
	if (returnType === null) return unknownType();
	// Collect all bindings from all params via unification (handles nested generics)
	const b = createUnifyBindings();
	for (let i = 0; i < fnType.typeChildren.length && i < argTypes.length; i += 1) {
		if (argTypes[i].kind !== TypeKind.Unknown) {
			unifyType(fnType.typeChildren[i], argTypes[i], b);
		}
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
		addError(ctx, "Ambiguous call to overloaded function '" + sym.name + "'");
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
		addError(ctx, msg);
		return getReturnType(sym.symbolType);
	}
	// Success — fill default args if needed, then infer generic return
	const winner = candidates[idx];
	if (winner.kind === TypeKind.Function && argTypes.length < winner.typeChildren.length) {
		fillDefaultArgsForNode(ctx, callNode, sym.name, winner.typeChildren.length);
	}
	return inferGenericReturn(winner, argTypes);
}

// Resolve extension method overloads: multiple extensions match same receiver+method.
// Each extension's fnType includes the receiver as param[0]; strip it before scoring.
function resolveExtensionOverloadCall(ctx: CheckerContext, exts: ExtensionMethod[],
	argTypes: Type[], objType: Type, methodName: string): Type {
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
	const idx = resolveOverloadIdxWithInheritance(ctx, candidates, argTypes, scopeDepths);
	if (idx === -2) {
		addError(ctx, "Ambiguous call to overloaded extension method '" + methodName + "'");
		return getReturnType(candidates[0]);
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
		addError(ctx, msg);
		return getReturnType(candidates[0]);
	}
	return inferGenericReturn(candidates[idx], argTypes);
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
	if (sourceType.typeName === "" || targetType.typeName === "") return -1;
	let current = sourceType;
	let depth = 0;
	while (current !== null) {
		depth = depth + 1;
		if (current.typeExtra === null) return -1;
		if (current.typeExtra.typeName === "") return -1;
		if (current.typeExtra.typeName === targetType.typeName) return depth;
		const baseSym = lookupSymbol(ctx.table, current.typeExtra.typeName);
		if (baseSym === null) return -1;
		if (baseSym.symbolKind !== SymbolKind.Class) return -1;
		current = baseSym.symbolType;
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

// Check if a type maps to a pointer in C (class, ref, ptr — NOT interface)
function isPointerInC(t: Type, ctx: CheckerContext): boolean {
	if (t === null) return false;
	if (t.kind === TypeKind.Ref || t.kind === TypeKind.Ptr) return true;
	if (t.kind !== TypeKind.Object) return false;
	// Interface = value type in C, Class = pointer type
	const isInterface = (t.typeFlags & 1) !== 0;
	if (isInterface) return false;
	if (t.typeName === "") return false;
	const sym = lookupSymbol(ctx.table, t.typeName);
	if (sym === null) return false;
	return sym.symbolKind === SymbolKind.Class;
}

function checkMemberExpr(ctx: CheckerContext, node: Node): Type {
	const d = node.data as MemberExprData;
	const objType = checkExpr(ctx, d.object);
	// Insert HiddenDeref for pointer types (class, ref, ptr) — generates (*obj).field in C
	if (isPointerInC(objType, ctx)) {
		const tok = createToken(TokenKind.Ident, "", node.location.line);
		const derefNode = createNode(NodeKind.HiddenDeref, { expr: d.object }, tok);
		derefNode.nodeType = objType ;
		d.object = derefNode;
	}
	const propType = getProperty(objType, d.property);
	if (propType.kind !== TypeKind.Unknown) return propType;
	// Fall back to extension registry — Nim-aligned type-based lookup
	if (ctx.extensionRegistry !== null) {
		const allByName = findAllExtensionsByName(ctx.extensionRegistry, d.property);
		const ext = findFirstMatchingExt(allByName, objType);
		if (ext !== null) {
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
	const discType = checkExpr(ctx, d.matchDisc);
	let returnType = unknownType();
	let hasWildcard = false;
	const coveredMembers: string[] = [];
	for (const c of d.matchCases) {
		const cd = c.data as MatchCaseData;
		for (const p of cd.casePatterns) {
			if (p.kind === NodeKind.Identifier) { hasWildcard = true; }
			if (p.kind === NodeKind.MemberExpr) {
				const pmd = p.data as MemberExprData;
				coveredMembers.push(pmd.property);
			}
		}
		const bodyType = checkExpr(ctx, cd.caseBody);
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
			addError(ctx, "Non-exhaustive match: missing '" + enumType.typeName + "." + member + "'");
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
		const exprType = checkExpr(ctx, body);
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

// Register callback at module load time
registerCheckExpr((ctx: CheckerContext, node: Node): Type => { return checkExpr(ctx, node); });
