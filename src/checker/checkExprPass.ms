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
	createArray, createFunction, substituteType,
	isNumeric, isStringType, isCallable, getReturnType, getElementType, getProperty,
	typeNameOf,
} from "./types";
import {
	Symbol, SymbolKind, ScopeKind,
	defineSymbol, lookupSymbol, makeSymbol, openScope, closeScope, hasOverloads,
} from "./symbol";
import { CheckerContext, addError, findExtension } from "./context";
import { scoreCandidate, isAssignable } from "./compat";
import { callCheckStmt, registerCheckExpr } from "./checkerCallbacks";

// ===== Expression Checker =====

export function checkExpr(ctx: CheckerContext, node: Node): Type {
	const result = match (node.kind) {
		NodeKind.NumberLiteral | NodeKind.BigIntLiteral => numberType(),
		NodeKind.StringLiteral => stringType(),
		NodeKind.BooleanLiteral => booleanType(),
		NodeKind.NullLiteral => nullType(),
		NodeKind.RegexLiteral | NodeKind.QuoteExpr => unknownType(),
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
			return resolveOverloadCall(sym, argTypes);
		}
	}
	// Check argument types + infer generic return
	if (calleeType.kind === TypeKind.Function) {
		let pi = 0;
		while (pi < calleeType.typeChildren.length && pi < argTypes.length) {
			const paramType = calleeType.typeChildren[pi];
			if (paramType.kind !== TypeKind.Unknown && paramType.kind !== TypeKind.GenericParam
				&& argTypes[pi].kind !== TypeKind.Unknown && argTypes[pi].kind !== TypeKind.Error) {
				if (!isAssignable(argTypes[pi], paramType)) {
					addError(ctx, "Argument type mismatch in function call");
				}
			}
			pi += 1;
		}
		return inferGenericReturn(calleeType, argTypes);
	}
	return getReturnType(calleeType);
}

export function inferGenericReturn(fnType: Type, argTypes: Type[]): Type {
	let returnType = fnType.typeReturn;
	if (returnType === null) return unknownType();
	let i = 0;
	while (i < fnType.typeChildren.length && i < argTypes.length) {
		const formal = fnType.typeChildren[i];
		if (formal.kind === TypeKind.GenericParam && argTypes[i].kind !== TypeKind.Unknown) {
			returnType = substituteType(returnType, formal.typeName, argTypes[i]);
		}
		i += 1;
	}
	return returnType;
}

function resolveOverloadCall(sym: Symbol, argTypes: Type[]): Type {
	let bestScore = -1;
	let bestType = sym.symbolType;
	if (sym.symbolType.kind === TypeKind.Function) {
		const score = scoreCandidate(sym.symbolType.typeChildren, argTypes);
		if (score > bestScore) {
			bestScore = score;
			bestType = sym.symbolType;
		}
	}
	for (const overload of sym.overloads) {
		if (overload.symbolType.kind === TypeKind.Function) {
			const score = scoreCandidate(overload.symbolType.typeChildren, argTypes);
			if (score > bestScore) {
				bestScore = score;
				bestType = overload.symbolType;
			}
		}
	}
	return getReturnType(bestType);
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
	// Fall back to extension registry
	if (ctx.extensionRegistry !== null) {
		const typeName = typeNameOf(objType);
		if (typeName !== "") {
			const ext = findExtension(ctx.extensionRegistry, typeName, d.property);
			if (ext !== null) return ext.fnType;
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
