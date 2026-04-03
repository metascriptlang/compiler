// Expression Checker — type inference for all expression kinds
// Extracted from checkPass.ms. Uses checkerCallbacks for mutual recursion with checkStmt.

import { Node, NodeKind, NodeData, createNode, createNodeAt, NodeFlag, DeclKind, SourceLocation, IdentifierData, BinaryExprData, UnaryExprData, UpdateExprData, NumberLiteralData, CallExprData, MemberExprData, ArrayAccessData, ObjectLiteralData, ArrayLiteralData, ConditionalExprData, TypeAssertionData, SpreadExprData, NewExprData, TryExprData, AwaitExprData, YieldExprData, MoveExprData, OutExprData, SizeofExprData, HiddenDerefData, HiddenStdConvData, MacroInvocationData, StringLiteralData, ArrowFunctionData, FunctionExprData, MatchCaseData, MatchExprData, FunctionDeclData, ClassDeclData, BlockStmtData, ExprStmtData, ReturnStmtData, IfStmtData, Type, TypeKind, CallingConvention, Symbol, SymbolKind, SymbolState, BooleanLiteralData, collectConcatParts } from "../ast/node";
import { TokenKind, Token, createToken } from "../lexer/token";
import { unknownType, numberType, int32Type, float64Type, isFloatType, stringType, booleanType, charType, voidType, nullType, errorType, createArray, createSpan, createFunction, createTypeRef, createStruct, createResult, createPrimitive, substituteType, instantiateGeneric, anonStructName, isNumeric, isIntegerType, getReturnType, getElementType, getProperty, sizeOfType, typeNameOf, unwrapRef, isDiscriminatedUnion, getDiscriminantName, findVariantByDiscriminant, findFieldInVariant, findUnionVariant, isAmbiguousVariant, unifyType, createUnifyBindings, hasGenericParams, getMinArity, setMinArity, isNarrowingIntConv, integerRank, skipModifier, createPromise, isPromise, getPromiseInner, isResult, getResultOkType, createGenericParam, instantiateGenericBody, isStringLike, isPrimitiveKind, isStructType } from "./types";
import { ScopeKind, SymbolFlag, defineSymbol, lookupSymbol, makeSymbol, makeSymbolState, openScope, closeScope, hasOverloads, hasFlag, markUsed } from "./symbol";
import { CheckerContext, ExportedSymInfo, addError, addErrorRange, addWarning, findAllExtensionsByName, ExtensionMethod, isCancelled, filterExtsByReceiverType, findFirstMatchingExt, getExtFnType, stripReceiverParam, sgRecordSym, isInAsyncPromiseResult, findExportedSymbol } from "./context";
import {
	isAssignable, needsStdConv, findFirstMismatch,
	scoreCandidatePriority, isNoMatch, emptyCandidateScore, cmpCandidates,
} from "./compat";
import { callCheckStmt, registerCheckExpr } from "./checkerCallbacks";
import { resolveAnnotation, resolveTypeExpr, resolveTypeExprs, ensureShaped, recordGenericTypeInstantiation, buildTypeArgKey } from "./resolvePass";
import { findChar, splitTopLevel } from "../utils/string";
import { findCallTypeArg, getExplicitTypeArg, getGenericDecl } from "../parser/context";
import {
	markInitialized, isInitialized, impliesNotNull, getDeclBlock,
	saveInitState, restoreInitState, collectNewInits, mergeInitBranches, breaksBlock, BreakState,
} from "./initTracker";
import { callInstantiateGeneric } from "./checkerCallbacks";

// Extension receiver matching functions imported from context.ms (shared with LSP)

// ===== Definite Assignment Helpers (sempass2 parity) =====

// Reference parity: invalidateFacts — when a variable is reassigned, remove
// any narrowing facts about it (e.g., `x !== null` becomes stale after `x = ...`).
function invalidateFacts(ctx: CheckerContext, name: string): void {
	let i = ctx.narrowFacts.length - 1;
	while (i >= 0) {
		if (factReferencesVar(ctx.narrowFacts[i], name)) {
			ctx.narrowFacts[i] = ctx.narrowFacts[ctx.narrowFacts.length - 1];
			ctx.narrowFacts.length = ctx.narrowFacts.length - 1;
		}
		i = i - 1;
	}
}

function factReferencesVar(fact: Node, name: string): boolean {
	if (fact === null) return false;
	if (fact.kind === NodeKind.BinaryExpr) {
		const d = fact.data as BinaryExprData;
		if (d.left !== null && d.left.kind === NodeKind.Identifier &&
			(d.left.data as IdentifierData).name === name) return true;
		if (d.right !== null && d.right.kind === NodeKind.Identifier &&
			(d.right.data as IdentifierData).name === name) return true;
	}
	return false;
}

// ===== Generic NewExpr Resolution =====
// Resolves `new Box<number>(42)` — captures type args from side-channel,
// records instantiation, and builds concrete Ref<Struct> type.
// Parity: standard reference object construction → type node captures type args.
function resolveGenericNewExpr(ctx: CheckerContext, callee: Node, calleeType: Type): Type {
	if (callee.kind !== NodeKind.Identifier) return calleeType;
	const calleeName = (callee.data as IdentifierData).name;
	const ltCol = callee.location.column + calleeName.length;
	const typeArgStr = getExplicitTypeArg(callee.location.line, ltCol);
	if (typeArgStr === "") return calleeType;
	const genericParams = getGenericDecl(calleeName);
	if (genericParams === "") return calleeType;
	const args = splitTopLevel(typeArgStr, ",");
	recordGenericTypeInstantiation(calleeName, genericParams, args, ctx);
	const typeArgKey = buildTypeArgKey(args, ctx);
	const mangledName = calleeName + "__" + typeArgKey;
	const baseSym = lookupSymbol(ctx.table, calleeName);
	if (baseSym === null) return calleeType;
	ensureShaped(baseSym, ctx);
	const paramNames = splitTopLevel(genericParams, ",");
	const trimmedParamNames: string[] = [];
	const concreteTypes: Type[] = [];
	let typeArgCol = ltCol + 1;  // column after '<'
	for (let pi = 0; pi < paramNames.length; pi += 1) {
		trimmedParamNames.push(paramNames[pi].trim());
		const argName = pi < args.length ? args[pi].trim() : "";
		const resolved = resolveAnnotation(argName, ctx, callee.location.line, typeArgCol);
		concreteTypes.push(resolved);
		// Record type arg symbol for hover/go-to-definition
		if (argName !== "") {
			const typeArgSym = lookupSymbol(ctx.table, argName);
			if (typeArgSym !== null) {
				sgRecordSym(ctx, callee.location.line, typeArgCol, typeArgCol + argName.length, typeArgSym, typeArgSym.symbolType, typeArgSym.symbolKind, argName, "", false);
			}
			typeArgCol = typeArgCol + argName.length + 2;  // skip "T, " for next arg
		}
	}
	const instType = instantiateGeneric(baseSym.symbolType, trimmedParamNames, concreteTypes);
	const instInner = (instType.kind === TypeKind.Ref && instType.typeReturn !== null) ? instType.typeReturn : instType;
	instInner.typeName = mangledName;
	// On-demand constructor instantiation: if class has constructor, generate ClassName_new()
	if (hasFlag(baseSym, SymbolFlag.HasConstructor)) {
		instantiateClassConstructor(baseSym, trimmedParamNames, concreteTypes, ctx);
	}
	return instType;
}

// Resolve the defining module info for a type by name.
// Tries scope lookup first, then searches the export registry.
// Returns a symbol with modulePath + location, or null if not found.
function resolveContainerModule(ctx: CheckerContext, typeName: string): Symbol {
	const sym = lookupSymbol(ctx.table, typeName);
	if (sym !== null && sym.modulePath !== "") return sym;
	// Fallback: search export registry for types not directly in scope (e.g. nested struct fields)
	for (const entry of ctx.exportRegistry.entries) {
		for (const exp of entry.symbols) {
			if (exp.name === typeName) {
				const synth = makeSymbolState(typeName, exp.kind, exp.symType, false, SymbolState.Shaped);
				synth.modulePath = exp.definingModule !== "" ? exp.definingModule : entry.modulePath;
				if (exp.location !== null && exp.location.line > 0) synth.location = exp.location;
				return synth;
			}
		}
	}
	return null;
}

// Inherit modulePath + location from a container type onto a synthetic field symbol.
// Used for cross-file go-to-definition on object literal keys and member access properties.
function inheritContainerInfo(fieldSym: Symbol, ctx: CheckerContext, typeName: string): void {
	if (typeName === "") return;
	const cSym = resolveContainerModule(ctx, typeName);
	if (cSym !== null) {
		fieldSym.modulePath = cSym.modulePath;
		if (cSym.location !== null) fieldSym.location = cSym.location;
	}
}

// ===== Expression Checker =====

// Public API: check expression, store type on node. Callers read node.nodeType.
// Returns void — reference parity (standard checker returns the node, type accessed via field).
// No Type return eliminates DRC borrowed-ref-as-fresh use-after-free.
export function checkExpr(ctx: CheckerContext, node: Node, expectedType: Type): void {
	if (node === null) return;
	if ((node.flags & NodeFlag.Sem) !== 0 && node.nodeType !== null) return;
	if (isCancelled(ctx.cancelCtx, ctx.cancelVersion)) { node.nodeType = unknownType(); return; }
	node.nodeType = checkExprInner(ctx, node, expectedType);
	node.flags = node.flags | NodeFlag.Sem;
}

// Internal: compute type for node. All match arms and sub-functions return Type.
function checkExprInner(ctx: CheckerContext, node: Node, expectedType: Type): Type {
	const result = match (node.kind) {
		NodeKind.NumberLiteral => {
			if (expectedType !== null && isIntegerType(expectedType)) {
				if (literalFitsInType(node, expectedType)) {
					return expectedType;
				} else if (isNodeIntLit(node)) {
					// Reference parity: standard reference's type change diagnostic emits compile-time error for out-of-range literals
					const v = (node.data as NumberLiteralData).value;
					addError(ctx, "cannot convert " + v + " to " + typeNameOf(expectedType), node.location.line, node.location.column);
					return expectedType;
				} else {
					return float64Type();
				}
			} else if (expectedType !== null && (expectedType.kind === TypeKind.Float64 || expectedType.kind === TypeKind.Float32)) {
				return expectedType;
			} else if (expectedType !== null && expectedType.kind === TypeKind.Number) {
				return numberType();
			} else {
				// Default inference: integer literals → int32, float literals → float64
				if (isNodeIntLit(node)) return int32Type();
				return float64Type();
			}
		},
		NodeKind.BigIntLiteral => createPrimitive(TypeKind.Int64),
		NodeKind.StringLiteral => {
			// TypeScript parity: string literals get StringLiteral type when expectedType demands it
			if (expectedType !== null) {
				const sd = node.data as StringLiteralData;
				if (expectedType.kind === TypeKind.StringLiteral && expectedType.typeName === sd.value) {
					return expectedType;
				}
				if (expectedType.kind === TypeKind.Union) {
					for (const child of expectedType.typeChildren) {
						if (child !== null && child.kind === TypeKind.StringLiteral && child.typeName === sd.value) {
							return child;
						}
					}
					// All members are StringLiteral but value not found → type error
					let allStrLit = true;
					for (const child of expectedType.typeChildren) {
						if (child === null || child.kind !== TypeKind.StringLiteral) allStrLit = false;
					}
					if (allStrLit && expectedType.typeChildren.length > 0) {
						addError(ctx, `Type '"${sd.value}"' is not assignable to type '${typeNameOf(expectedType)}'`, node.location.line, node.location.column);
						return stringType();
					}
				}
			}
			return stringType();
		},
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
			markUsed(sym);
			// Ref parity: useVar — only check vars declared in current scope (getDeclBlock >= 0).
			// Imports/globals never varDecl'd → naturally skipped. Matches reference's owner-based scoping.
			if (sym.symbolKind === SymbolKind.Variable && getDeclBlock(ctx.initTracker, d.name) >= 0 &&
				ctx.strictDefs && ctx.initTracker.leftPartOfAsgn <= 0 && ctx.currentFunction !== null) {
				if (!isInitialized(ctx.initTracker, d.name)) {
					addWarning(ctx, "variable '" + d.name + "' may be used before initialization", node.location.line, node.location.column);
					// Suppress repeated warnings (ref: a.init.add s.id)
					markInitialized(ctx.initTracker, d.name);
				}
			}
			sgRecordSym(ctx, node.location.line, node.location.column, node.location.column + d.name.length, sym, sym.symbolType, sym.symbolKind, d.name, "", false);
			return sym.symbolType;
		},
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			// Ref parity: leftPartOfAsgn (sempass2 lines 1286-1288)
			const isAsgn = d.operator === "=" || d.operator === "+=" || d.operator === "-=" ||
				d.operator === "*=" || d.operator === "/=" || d.operator === "%=" ||
				d.operator === "&&=" || d.operator === "||=" || d.operator === "??=";
			if (isAsgn) {
				ctx.initTracker.leftPartOfAsgn = ctx.initTracker.leftPartOfAsgn + 1;
			}
			checkExpr(ctx, d.left, null);
			const leftType = d.left.nodeType;
			if (isAsgn) {
				ctx.initTracker.leftPartOfAsgn = ctx.initTracker.leftPartOfAsgn - 1;
			}
			// Block assignment to read-only properties (e.g., str.length = n)
			if (isAsgn && d.left.kind === NodeKind.MemberExpr) {
				const md = d.left.data as MemberExprData;
				if (md.property === "length" && md.object.nodeType !== null) {
					if (isStringLike(md.object.nodeType) || md.object.nodeType.kind === TypeKind.CString) {
						addError(ctx, "cannot assign to 'length' on string (strings are immutable)", d.left.location.line, d.left.location.column);
					} else if (md.object.nodeType.kind === TypeKind.SizedArray) {
						addError(ctx, "cannot modify 'length' on fixed-size array", d.left.location.line, d.left.location.column);
					} else if (md.object.nodeType.kind === TypeKind.Array && d.operator !== "=") {
						addError(ctx, "compound assignment to 'length' is not allowed; use 'arr.length = arr.length " + d.operator.slice(0, d.operator.length - 1) + " n' instead", d.left.location.line, d.left.location.column);
					}
				}
			}
			// For assignment, pass LHS type as expectedType to RHS
			const rightExpected = (d.operator === "=") ? leftType : null;
			checkExpr(ctx, d.right, rightExpected);
			let rightType = d.right.nodeType;
			// Parity: standard reference node fitting — insert HiddenStdConv for narrowing assignment
			if (d.operator === "=" && leftType !== null) {
				d.right = fitNode(ctx, d.right, leftType, rightType);
			}
			// Ref parity: initVar on assignment LHS (sempass2 line 1284)
			if (isAsgn && d.left.kind === NodeKind.Identifier) {
				const lhsId = d.left.data as IdentifierData;
				// Ref parity: nfFirstWrite — set when first assignment is in same block as declaration
				if (!isInitialized(ctx.initTracker, lhsId.name)) {
					if (getDeclBlock(ctx.initTracker, lhsId.name) === ctx.initTracker.currentBlock) {
						node.flags = node.flags | NodeFlag.FirstWrite;
					}
				}
				markInitialized(ctx.initTracker, lhsId.name);
				// Ref parity: invalidate narrowing facts about reassigned variable
				invalidateFacts(ctx, lhsId.name);
			}
			// Post-hoc literal coercion: if one side is typed integer and other is integer literal that fits, coerce.
			// Example: `h: int64; h * 33` — coerces literal 33 (default int32) to int64.
			let effLeft = leftType;
			let effRight = rightType;
			if (isIntegerType(leftType) && rightType !== null
				&& isNodeIntLit(d.right) && literalFitsInType(d.right, leftType)) {
				effRight = leftType;
				d.right.nodeType = leftType;
			} else if (isIntegerType(rightType) && leftType !== null
				&& isNodeIntLit(d.left) && literalFitsInType(d.left, rightType)) {
				effLeft = rightType;
				d.left.nodeType = rightType;
			}
			// Bitwise ops require integer operands (reference parity: no float overloads)
			// Insert implicit number → int32 cast for C backend
			if (isBitwiseBinaryOp(d.operator)) {
				checkBitwiseOperands(ctx, d.operator, effLeft, effRight, node);
				if (effLeft !== null && effLeft.kind === TypeKind.Number) {
					d.left = wrapInConv(d.left, createPrimitive(TypeKind.Int32));
					effLeft = createPrimitive(TypeKind.Int32);
				}
				if (effRight !== null && effRight.kind === TypeKind.Number) {
					d.right = wrapInConv(d.right, createPrimitive(TypeKind.Int32));
					effRight = createPrimitive(TypeKind.Int32);
				}
			}
			return inferBinaryOp(d.operator, effLeft, effRight);
		},
		NodeKind.UnaryExpr => {
			const d = node.data as UnaryExprData;
			// Propagate expectedType through unary +/- for literal coercion (e.g., -128 → int8)
			const unaryExpected = (d.unaryOp === "-" || d.unaryOp === "+") ? expectedType : null;
			checkExpr(ctx, d.operand, unaryExpected);
			const operandType = d.operand.nodeType;
			// Bitwise NOT: integer/enum = ok, number = warn, other = error
			if (d.unaryOp === "~") {
				if (operandType !== null && operandType.kind === TypeKind.Number) {
					addWarning(ctx, "bitwise NOT '~' on 'number' implicitly casts to int32; prefer explicit integer type", node.location.line, node.location.column);
					d.operand = wrapInConv(d.operand, createPrimitive(TypeKind.Int32));
				} else if (!isBitwiseAllowed(operandType)) {
					const name = operandType !== null ? typeNameOf(operandType) : "unknown";
					addError(ctx, "bitwise NOT '~' requires integer type, got '" + name + "'", node.location.line, node.location.column);
				}
			}
			return inferUnaryOp(d.unaryOp, operandType);
		},
		NodeKind.UpdateExpr => {
			const d = node.data as UpdateExprData;
			checkExpr(ctx, d.updateArg, null);
			if (d.updateArg.kind === NodeKind.MemberExpr) {
				const umd = d.updateArg.data as MemberExprData;
				if (umd.property === "length" && umd.object.nodeType !== null &&
					(umd.object.nodeType.kind === TypeKind.Array || umd.object.nodeType.kind === TypeKind.SizedArray || umd.object.nodeType.kind === TypeKind.Span || isStringLike(umd.object.nodeType) || umd.object.nodeType.kind === TypeKind.CString)) {
					if (umd.object.nodeType.kind === TypeKind.SizedArray) {
						addError(ctx, "cannot modify 'length' on fixed-size array", d.updateArg.location.line, d.updateArg.location.column);
					} else {
						addError(ctx, "cannot use increment/decrement on 'length'; use 'arr.length = n' instead", d.updateArg.location.line, d.updateArg.location.column);
					}
				}
			}
			if (d.updateArg.nodeType !== null && isNumeric(d.updateArg.nodeType)) return d.updateArg.nodeType;
			return int32Type();
		},
		NodeKind.CallExpr => checkCallExpr(ctx, node, expectedType),
		NodeKind.MemberExpr => checkMemberExpr(ctx, node),
		NodeKind.ArrayAccess => {
			const d = node.data as ArrayAccessData;
			checkExpr(ctx, d.array, null);
			const arrType = d.array.nodeType;
			checkExpr(ctx, d.index, null);
			const idxType = d.index.nodeType;
			// Implicit number → int64 cast for array index (C requires integer subscript)
			if (idxType !== null && idxType.kind === TypeKind.Number && d.index.kind !== NodeKind.BinaryExpr) {
				d.index = wrapInConv(d.index, createPrimitive(TypeKind.Int64));
			}
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
			return accessType;
		},
		NodeKind.ObjectLiteral => {
			const d = node.data as ObjectLiteralData;
			// Unwrap ownership modifiers (Sink/Lent/Var) and Ref — transparent wrappers.
			// Reference parity: skipTypes({tySink, tyOwned})
			let objExpected = skipModifier(expectedType);
			// Unwrap Ref for class types — ObjectLiteral constructs the inner struct
			if (objExpected !== null && objExpected.kind === TypeKind.Ref && objExpected.typeReturn !== null) {
				objExpected = objExpected.typeReturn;
			}
			// Unwrap GenericInstance (e.g., Result<T, E>) to inner Struct via typeExtra (base type)
			if (objExpected !== null && objExpected.kind === TypeKind.GenericInstance && objExpected.typeExtra !== null && objExpected.typeExtra.kind === TypeKind.Struct) {
				objExpected = objExpected.typeExtra;
			}
			if (objExpected !== null && objExpected.kind === TypeKind.Struct
				&& objExpected.typeChildren !== null) {
				// Reference parity: stamp literal with expected type, propagate field types
				// For class types, keep Ref wrapper so codegen knows to heap-allocate.
				// Skip ownership modifiers (Sink/Lent/Var) — transparent for codegen.
				const stampType = skipModifier(expectedType);
				node.nodeType = (stampType !== null) ? stampType : objExpected;
				const containerName = objExpected.typeName !== null ? objExpected.typeName : "";
				let fi = 0;
				while (fi < d.properties.length) {
					// Name-based field lookup: match literal key against struct typeNames
					let fieldExpected: Type = null;
					const keyName = fi < d.keys.length ? d.keys[fi] : "";
					if (keyName !== "" && keyName !== "..." && keyName !== "__computed__"
						&& objExpected.typeNames !== null) {
						let ni = 0;
						while (ni < objExpected.typeNames.length) {
							if (objExpected.typeNames[ni] === keyName) {
								if (ni < objExpected.typeChildren.length) {
									fieldExpected = objExpected.typeChildren[ni];
								}
								break;
							}
							ni = ni + 1;
						}
					}
					// Fallback: positional match for spread/computed keys
					if (fieldExpected === null && (keyName === "..." || keyName === "__computed__")
						&& fi < objExpected.typeChildren.length) {
						fieldExpected = objExpected.typeChildren[fi];
					}
					checkExpr(ctx, d.properties[fi], fieldExpected);
					// Record property key as reference to struct field
					if (fi < d.keys.length && d.keyLocations !== null && fi < d.keyLocations.length && fieldExpected !== null) {
						const keyLoc = d.keyLocations[fi];
						if (keyName !== "..." && keyName !== "__computed__" && keyLoc.line > 0) {
							let fieldSym: Symbol = null;
							if (containerName !== "") {
								fieldSym = lookupSymbol(ctx.table, containerName + "_" + keyName);
								if (fieldSym !== null) ensureShaped(fieldSym, ctx);
							}
							if (fieldSym === null) {
								fieldSym = makeSymbolState(keyName, SymbolKind.Property, fieldExpected, false, SymbolState.Shaped);
								inheritContainerInfo(fieldSym, ctx, containerName);
							}
							sgRecordSym(ctx, keyLoc.line, keyLoc.column, keyLoc.column + keyName.length, fieldSym, fieldExpected, SymbolKind.Property, keyName, containerName, false);
						}
					}
					fi = fi + 1;
				}
				// Excess property + duplicate field check
				if (objExpected.typeNames !== null) {
					let ki = 0;
					while (ki < d.keys.length) {
						const key = d.keys[ki];
						if (key !== "..." && key !== "__computed__") {
							// Check field exists in type
							let found = false;
							let ni = 0;
							while (ni < objExpected.typeNames.length) {
								if (objExpected.typeNames[ni] === key) { found = true; break; }
								ni = ni + 1;
							}
							if (!found && d.keyLocations !== null && ki < d.keyLocations.length) {
								const kl = d.keyLocations[ki];
								addErrorRange(ctx, "'" + key + "' does not exist in type '" + containerName + "'", kl.line, kl.column, kl.column + key.length);
							}
							// Check duplicate: same key appeared earlier
							let di = 0;
							while (di < ki) {
								if (d.keys[di] === key && d.keyLocations !== null && ki < d.keyLocations.length) {
									const kl = d.keyLocations[ki];
									addErrorRange(ctx, "field initialized twice: '" + key + "'", kl.line, kl.column, kl.column + key.length);
									break;
								}
								di = di + 1;
							}
						}
						ki = ki + 1;
					}
				}
				return node.nodeType;
			} else if (objExpected !== null && objExpected.kind === TypeKind.Union
				&& isDiscriminatedUnion(objExpected)) {
				// Discriminated union construction validation
				// Pass original expectedType so Ref wrapper is preserved for codegen heap-alloc
				checkDiscriminatedConstruction(ctx, node, d, objExpected, expectedType);
			} else if (objExpected !== null && objExpected.kind === TypeKind.Union) {
				// Non-discriminated union: resolve variant, propagate field types.
				// Reference parity: sem resolves fields then calls fitNode(field.typ, value)
				// once per field. One pass, known types.
				node.nodeType = objExpected;
				// Try name-only matching first (unique for most variants)
				let varIdx = (d.keys.length > 0)
					? findUnionVariant(objExpected, d.keys, [])
					: -1;
				// Ambiguous? (e.g. { value: X } matches both NumberLiteral and StringLiteral)
				// Check properties without expectedType to get actual types, then disambiguate.
				if (varIdx >= 0 && d.keys.length > 0 && isAmbiguousVariant(objExpected, varIdx, d.keys)) {
					const propTypes: Type[] = [];
					let pi = 0;
					while (pi < d.properties.length) {
						checkExpr(ctx, d.properties[pi], null); propTypes.push(d.properties[pi].nodeType);
						pi = pi + 1;
					}
					const refined = findUnionVariant(objExpected, d.keys, propTypes);
					if (refined >= 0) varIdx = refined;
				}
				// Single pass: check properties WITH variant field types as expectedType
				// (reference: fitNode(field.typ, value) — proper literal coercion)
				const variant = (varIdx >= 0 && objExpected.typeChildren !== null
					&& varIdx < objExpected.typeChildren.length)
					? objExpected.typeChildren[varIdx]
					: null;
				let fi = 0;
				while (fi < d.properties.length) {
					const fieldExpected = (variant !== null && fi < d.keys.length)
						? findFieldInVariant(variant, d.keys[fi])
						: null;
					checkExpr(ctx, d.properties[fi], fieldExpected);
					fi = fi + 1;
				}
				// Stamp variant index in high 16 bits of flags.
				// +1 offset so 0 means "not set" (variant 0 becomes 1).
				if (varIdx >= 0) {
					node.flags = node.flags | (((varIdx + 1) as int32) << 16);
				}
				return objExpected;
			} else {
				// No expected type — synthesize anonymous struct from literal fields
				const fieldNames: string[] = [];
				const fieldTypes: Type[] = [];
				let pi = 0;
				while (pi < d.properties.length) {
					checkExpr(ctx, d.properties[pi], null);
					const ft = d.properties[pi].nodeType;
					if (pi < d.keys.length) { fieldNames.push(d.keys[pi]); }
					fieldTypes.push(ft);
					pi = pi + 1;
				}
				const anonName = anonStructName(fieldNames, fieldTypes);
				const anonType = createStruct(anonName, fieldNames, fieldTypes, false);
				node.nodeType = anonType;
				return anonType;
			}
		},
		NodeKind.ArrayLiteral => {
			const d = node.data as ArrayLiteralData;
			// Reference parity: semArrayConstr does expectedType.skipTypes(abstractRange)
			// which strips Sink/Lent/Var wrappers before checking Array kind
			const arrExpected = skipModifier(expectedType);
			const elemExpected = (arrExpected !== null
				&& (arrExpected.kind === TypeKind.Array || arrExpected.kind === TypeKind.SizedArray)
				&& arrExpected.typeReturn !== null)
				? arrExpected.typeReturn
				: null;
			if (d.elements.length === 0) {
				if (arrExpected !== null && (arrExpected.kind === TypeKind.SizedArray || arrExpected.kind === TypeKind.Array)) {
					return arrExpected;
				} else {
					return createArray(unknownType());
				}
			} else {
				checkExpr(ctx, d.elements[0], elemExpected);
				const elemType = d.elements[0].nodeType;
				let i = 1;
				while (i < d.elements.length) { checkExpr(ctx, d.elements[i], elemExpected); i += 1; }
				// Reference parity (semArrayConstr): error only on too-many elements.
				// Too-few is allowed at literal level; type compatibility catches mismatches.
				if (arrExpected !== null && arrExpected.kind === TypeKind.SizedArray) {
					const expectedLen = arrExpected.typeFlags;
					if (d.elements.length > expectedLen) {
						addError(ctx, `Fixed-size array expects at most ${expectedLen} element(s), got ${d.elements.length}`, node.location.line, node.location.column);
					}
					return arrExpected;
				} else if (arrExpected !== null && arrExpected.kind === TypeKind.Array) {
					return arrExpected;
				} else {
					return createArray(elemType);
				}
			}
		},
		NodeKind.ArrowFunction => checkArrowExpr(ctx, node),
		NodeKind.FunctionExpr => checkFuncExpr(ctx, node),
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			checkExpr(ctx, d.ternaryCondition, null);
			checkExpr(ctx, d.ternaryConsequent, expectedType);
			const consequentType = d.ternaryConsequent.nodeType;
			checkExpr(ctx, d.ternaryAlternate, expectedType);
			return consequentType;
		},
		NodeKind.TypeAssertion => {
			let d = node.data as TypeAssertionData;
			checkExpr(ctx, d.asExpr, null);
			let srcType = d.asExpr.nodeType;
			const asLoc = node.typeExpr !== null ? node.typeExpr.location : node.location;
			const targetType = (d.asType !== "") ? resolveAnnotation(d.asType, ctx, asLoc.line, asLoc.column) : unknownType();
			// Record type annotation position for LSP
			resolveTypeExpr(node.typeExpr, ctx);
			// General rule: `expr as unknown as T` → collapse to `expr as T`.
			// `as unknown` is a TS type-system escape hatch with zero runtime meaning.
			// Unwrap it so downstream handlers see the real source expression/type.
			if (targetType.kind !== TypeKind.Unknown) {
				const innerExpr = unwrapAsUnknown(d.asExpr);
				if (innerExpr !== null) {
					node.data = { asExpr: innerExpr, asType: d.asType };
					d = node.data as TypeAssertionData;
					srcType = innerExpr.nodeType;
				}
			}
			// Nil typing: collapse `null as T` into typed NullLiteral.
			if (targetType.kind !== TypeKind.Unknown && targetType.kind !== TypeKind.Null
				&& d.asExpr !== null && d.asExpr.kind === NodeKind.NullLiteral) {
				node.kind = NodeKind.NullLiteral;
				node.data = { nullPlaceholder: true };
				node.nodeType = targetType;
				node.flags = node.flags | NodeFlag.Sem;
				return targetType;
			}
			// JsonValue as string/number/boolean/int32 → HiddenStdConv (lowered by jsonDynAccessLower)
			else if (isJsonValueType(srcType) && isJsonConvertibleTarget(targetType)) {
				node.nodeType = targetType;
				node.kind = NodeKind.HiddenStdConv;
				node.data = { convExpr: d.asExpr, convType: targetType };
				node.flags = node.flags | NodeFlag.Sem;
			}
			// Reference parity: when narrowing a Union, resolve to the actual variant type.
			else if (srcType !== null && srcType.kind === TypeKind.Union
				&& targetType.kind === TypeKind.Struct && targetType.typeNames !== null) {
				const varIdx = findUnionVariant(srcType, targetType.typeNames, targetType.typeChildren);
				if (varIdx >= 0 && varIdx < srcType.typeChildren.length) {
					node.nodeType = srcType.typeChildren[varIdx];
				} else {
					node.nodeType = targetType;
				}
			} else {
				node.nodeType = targetType;
			}
			return node.nodeType;
		},
		NodeKind.SpreadExpr => {
			const d = node.data as SpreadExprData;
			checkExpr(ctx, d.spreadArg, null);
			return unknownType();
		},
		NodeKind.NewExpr => checkNewExpr(ctx, node, expectedType),
		NodeKind.TryExpr => checkTryExpr(ctx, node),
		NodeKind.MatchExpr => checkMatchExpr(ctx, node),
		NodeKind.AwaitExpr => {
			const d = node.data as AwaitExprData;
			checkExpr(ctx, d.awaitArg, null);
			const argType = d.awaitArg.nodeType;
			if (argType !== null && isPromise(argType)) {
				const promiseInner = getPromiseInner(argType);
				node.nodeType = promiseInner !== null ? promiseInner : unknownType();
				// V2: in async fn returning Promise<Result<T,E>>, bare await on non-Result promise is error
				if (!ctx.inTryExpr
					&& isInAsyncPromiseResult(ctx)
					&& (argType.typeReturn === null || !isResult(argType.typeReturn))) {
					addError(ctx, "await on non-Result Promise must be guarded with 'try await ... catch ...' in function returning Promise<Result<T,E>>", node.location.line, node.location.column);
				}
				return node.nodeType;
			}
			return unknownType();
		},
		NodeKind.YieldExpr => {
			const d = node.data as YieldExprData;
			checkExpr(ctx, d.yieldArg, null);
			return unknownType();
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
			checkExpr(ctx, d.moveArg, null); return d.moveArg.nodeType;
		},
		NodeKind.OutExpr => {
			const d = node.data as OutExprData;
			checkExpr(ctx, d.outArg, null);
			return unknownType();
		},
		NodeKind.SizeofExpr => {
			const d = node.data as SizeofExprData;
			const resolved = resolveAnnotation(d.sizeofType, ctx, 0, 0);
			resolveTypeExpr(node.typeExpr, ctx);
			const size = sizeOfType(resolved);
			node.kind = NodeKind.NumberLiteral;
			node.data = { value: size } as unknown as NodeData;
			return int32Type();
		},
		NodeKind.HiddenDeref | NodeKind.HiddenAddr => {
			const d = node.data as HiddenDerefData;
			checkExpr(ctx, d.expr, null); return d.expr.nodeType;
		},
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => {
			const d = node.data as HiddenStdConvData;
			checkExpr(ctx, d.convExpr, null);
			return d.convType;
		},
		NodeKind.MacroInvocation => {
			// Implementation parity: pragma/macro args are type-checked
			const md = node.data as MacroInvocationData;
			// reference parity: @emit backtick interpolation (reference emit processing)
			if (md.macroName === "emit") {
				processEmitInterpolation(ctx, md, node);
			}
			// @import args are pure syntax (not evaluated) — skip type-checking
			if (md.macroName !== "import") {
				let ai = 0;
				while (ai < md.macroArgs.length) {
					checkExpr(ctx, md.macroArgs[ai], null);
					ai = ai + 1;
				}
			}
			return voidType();
		},
		_ => unknownType(),
	};
	return result;
}

// ===== Operator Inference =====

// Integer widening: promote to the wider of two integer types (C-style integer promotion).
function widenIntegers(a: Type, b: Type): Type {
	if (a.kind === b.kind) return a;
	return integerRank(a) >= integerRank(b) ? a : b;
}

// Mixed numeric promotion: number stays number, otherwise float64.
function promoteNumeric(a: Type, b: Type): Type {
	if (a.kind === TypeKind.Number || b.kind === TypeKind.Number) return numberType();
	return float64Type();
}

function inferBinaryOp(op: string, leftType: Type, rightType: Type): Type {
	return match (op) {
		"===" | "!==" | "==" | "!=" | "<" | ">" | "<=" | ">=" => booleanType(),
		"&&" | "||" => leftType,
		"+" => {
			if (isStringLike(leftType) || isStringLike(rightType)) return stringType();
			if (leftType !== null && leftType.kind === TypeKind.Ptr) return leftType;
			if (rightType !== null && rightType.kind === TypeKind.Ptr) return rightType;
			if (isIntegerType(leftType) && isIntegerType(rightType)) return widenIntegers(leftType, rightType);
			if (isNumeric(leftType) && isNumeric(rightType)) return promoteNumeric(leftType, rightType);
			return unknownType();
		},
		"-" => {
			if (leftType !== null && leftType.kind === TypeKind.Ptr && rightType !== null && rightType.kind === TypeKind.Ptr) return int32Type();
			if (leftType !== null && leftType.kind === TypeKind.Ptr) return leftType;
			if (isIntegerType(leftType) && isIntegerType(rightType)) return widenIntegers(leftType, rightType);
			if (isNumeric(leftType) && isNumeric(rightType)) return promoteNumeric(leftType, rightType);
			return unknownType();
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
			if (isFloatType(operandType)) return operandType;
			return numberType();
		},
		"~" => {
			// Reference parity: ~int32 → int32
			if (isIntegerType(operandType)) return operandType;
			return int32Type();
		},
		"typeof" => stringType(),
		_ => unknownType(),
	};
}

// Wrap an expression in HiddenStdConv to a target type. Used for implicit numeric casts.
function wrapInConv(expr: Node, targetType: Type): Node {
	const convTok = createToken(TokenKind.Ident, "", expr.location.line);
	const convNode = createNode(NodeKind.HiddenStdConv, { convExpr: expr, convType: targetType }, convTok);
	convNode.nodeType = targetType;
	convNode.flags = convNode.flags | NodeFlag.Sem;
	return convNode;
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
	if (d.isFloat) return false;  // 0.0, 1e5 etc. — developer wrote float syntax
	return d.value % 1 === 0;
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
	// JsonValue → primitive implicit conversion (lowered by jsonDynAccessLower)
	if (isJsonValueType(exprType) && isJsonConvertibleTarget(formal)) {
		const convTok = createToken(TokenKind.Ident, "", expr.location.line);
		const convNode = createNode(NodeKind.HiddenStdConv, { convExpr: expr, convType: formal }, convTok);
		convNode.nodeType = formal;
		convNode.flags = convNode.flags | NodeFlag.Sem;
		return convNode;
	}
	return expr;
}

// Walk through TypeAssertion chain to check if core expression is NullLiteral.
// Matches: null, null as unknown, null as unknown as T, etc.
function isNullAssertion(node: Node): boolean {
	if (node === null) return false;
	if (node.kind === NodeKind.NullLiteral) return true;
	if (node.kind === NodeKind.TypeAssertion) {
		return isNullAssertion((node.data as TypeAssertionData).asExpr);
	}
	return false;
}

// Unwrap `expr as unknown` chains — returns inner expr if found, null otherwise.
// General: collapses TS-specific double-cast before downstream handlers run.
function unwrapAsUnknown(node: Node): Node {
	if (node === null) return null;
	if (node.kind === NodeKind.TypeAssertion) {
		const d = node.data as TypeAssertionData;
		if (d.asType === "unknown") return d.asExpr;
		// Nested: `expr as unknown as unknown` (unlikely but safe)
		return unwrapAsUnknown(d.asExpr);
	}
	return null;
}

function isJsonValueType(t: Type): boolean {
	if (t === null) return false;
	const inner = unwrapRef(t);
	return inner.kind === TypeKind.Struct && inner.typeName === "JsonValue";
}

function isJsonConvertibleTarget(t: Type): boolean {
	if (t === null) return false;
	return t.kind === TypeKind.String || t.kind === TypeKind.Number
		|| t.kind === TypeKind.Boolean || t.kind === TypeKind.Int32;
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

// Reference parity: clone a default expression node for insertion into call.
// Shallow clone suffices for literals; deep clone would be needed for complex exprs.
function cloneDefaultNode(node: Node): Node {
	const clone = createNodeAt(node.kind, node.data, node.location);
	clone.resolvedSym = node.resolvedSym;
	// Prelude defaults are parsed but not semchecked — infer type from kind
	if (node.nodeType !== null) {
		clone.nodeType = node.nodeType;
	} else {
		match (node.kind) {
			NodeKind.NumberLiteral => { if (isNodeIntLit(node)) { clone.nodeType = int32Type(); } else { clone.nodeType = float64Type(); } },
			NodeKind.BigIntLiteral => { clone.nodeType = createPrimitive(TypeKind.Int64); },
			NodeKind.StringLiteral => { clone.nodeType = stringType(); },
			NodeKind.BooleanLiteral => { clone.nodeType = booleanType(); },
			NodeKind.NullLiteral => { clone.nodeType = nullType(); },
			_ => {},
		};
	}
	return clone;
}

// Shared default-filling logic: clone defaults into args array.
// Used by both function calls (fillDefaultArgsForNode) and constructor calls (checkNewExpr).
function fillDefaults(ctx: CheckerContext, args: Node[], defaults: Node[],
	totalParams: number, defaultOffset: number, paramTypes: Type[]): void {
	if (defaults === null) return;
	let argIdx = args.length;
	while (argIdx < totalParams) {
		const defIdx = argIdx + defaultOffset;
		let defNode: Node = null;
		if (defIdx < defaults.length) {
			defNode = defaults[defIdx];
		}
		if (defNode === null) break;
		const cloned = cloneDefaultNode(defNode);
		// Type-check with expected param type so empty containers get correct type
		const expectedType = paramTypes !== null && argIdx < paramTypes.length ? paramTypes[argIdx] : null;
		checkExpr(ctx, cloned, expectedType);
		args.push(cloned);
		argIdx = argIdx + 1;
	}
}

// Reference parity: fill missing call arguments from parameter defaults.
// defaultOffset accounts for receiver param in extension methods:
// fnDefaults[0] = receiver (no default), so call arg index N maps to fnDefaults[N + offset].
function fillDefaultArgsForNode(ctx: CheckerContext, callNode: Node, fnName: string,
	totalParams: number, defaultOffset: number): void {
	const cd = callNode.data as CallExprData;
	// Get defaults from Symbol (Reference: defaults stored on symbol)
	let fnDefaults: Node[] = null as unknown as Node[];
	// Check callee.resolvedSym first, then callNode.resolvedSym (extension methods set sym on CallExpr)
	const defSym = cd.callee.resolvedSym !== null ? cd.callee.resolvedSym : callNode.resolvedSym;
	if (defSym !== null) {
		if (defSym.defaultParams !== null && defSym.defaultParams.length > 0) {
			fnDefaults = defSym.defaultParams;
		} else if (defSym.declNode !== null && defSym.declNode.kind === NodeKind.FunctionDecl) {
			const declData = defSym.declNode.data as FunctionDeclData;
			if (declData.fnDefaults !== null) fnDefaults = declData.fnDefaults;
		}
	}
	fillDefaults(ctx, cd.arguments, fnDefaults, totalParams, defaultOffset, null as unknown as Type[]);
}

// ===== NewExpr =====

function getCtorParamTypes(classSym: Symbol): Type[] {
	if (classSym.declNode !== null && classSym.declNode.kind === NodeKind.ClassDecl) {
		const classData = classSym.declNode.data as ClassDeclData;
		for (const member of classData.classBody) {
			if (member.kind === NodeKind.ConstructorDecl && member.nodeType !== null
					&& member.nodeType.kind === TypeKind.Function) {
				return member.nodeType.typeChildren;
			}
		}
	}
	return null as unknown as Type[];
}

function checkNewArgs(ctx: CheckerContext, args: Node[]): void {
	for (const arg of args) { checkExpr(ctx, arg, null); }
}

function checkNewExpr(ctx: CheckerContext, node: Node, expected: Type): Type {
	const d = node.data as NewExprData;
	// new BuiltinType<...>() — construct value types (Map, Set) and Promise
	if (d.newCallee.kind === NodeKind.Identifier) {
		const id = d.newCallee.data as IdentifierData;
		// Interface/value type: new Map() / new Array(32) with type from variable annotation
		if (expected !== null && (expected.kind === TypeKind.Struct || expected.kind === TypeKind.GenericInstance)) {
			node.nodeType = expected;
			checkNewArgs(ctx, d.newArguments);
			return expected;
		}
		// Array with expected element type: new Array(32) in typed context
		if (expected !== null && expected.kind === TypeKind.Array && id.name === "Array") {
			node.nodeType = expected;
			checkNewArgs(ctx, d.newArguments);
			return expected;
		}
		// new Array<T>() or new Array<T>(size) — resolve element type from explicit type arg
		if (id.name === "Array") {
			// Record Array symbol for hover/go-to-definition consistency
			const arraySym = lookupSymbol(ctx.table, "Array");
			if (arraySym !== null) {
				sgRecordSym(ctx, d.newCallee.location.line, d.newCallee.location.column, d.newCallee.location.column + 5, arraySym, arraySym.symbolType, arraySym.symbolKind, "Array", "", false);
			}
			const ltCol = d.newCallee.location.column + id.name.length;
			const typeArgStr = getExplicitTypeArg(d.newCallee.location.line, ltCol);
			if (typeArgStr !== "") {
				const trimmed = typeArgStr.trim();
				const elemType = resolveAnnotation(trimmed, ctx, d.newCallee.location.line, ltCol + 1);
				// Record type arg symbol for hover/go-to-definition
				const typeArgSym = lookupSymbol(ctx.table, trimmed);
				if (typeArgSym !== null) {
					sgRecordSym(ctx, d.newCallee.location.line, ltCol + 1, ltCol + 1 + trimmed.length, typeArgSym, typeArgSym.symbolType, typeArgSym.symbolKind, trimmed, "", false);
				}
				const arrType = createArray(elemType);
				node.nodeType = arrType;
				checkNewArgs(ctx, d.newArguments);
				return arrType;
			}
		}
		// Promise, Map, Set all resolve through resolveGenericNewExpr below
	}
	checkExpr(ctx, d.newCallee, null);
	const calleeType = d.newCallee.nodeType;
	const resolvedType = resolveGenericNewExpr(ctx, d.newCallee, calleeType);
	// Resolve inner struct type for field type propagation
	const innerType = (resolvedType !== null && resolvedType.kind === TypeKind.Ref && resolvedType.typeReturn !== null)
		? resolvedType.typeReturn : resolvedType;
	// Type-check constructor arguments.
	// If class has constructor, let args self-infer (constructor function handles param types).
	// Otherwise use struct field types as expected types (positional field initialization).
	const hasCtor = d.newCallee.resolvedSym !== null && hasFlag(d.newCallee.resolvedSym, SymbolFlag.HasConstructor);
	let ai = 0;
	while (ai < d.newArguments.length) {
		let argExpected: Type = null;
		if (!hasCtor && innerType !== null && innerType.typeChildren !== null && ai < innerType.typeChildren.length) {
			argExpected = innerType.typeChildren[ai];
		}
		checkExpr(ctx, d.newArguments[ai], argExpected);
		ai = ai + 1;
	}
	// Fill default args for constructor calls — unified with fillDefaults (same as functions).
	if (hasCtor) {
		// Path 1: monomorphized generic constructors (Set__string_new) via _ctorRegistry
		const mangledName = innerType !== null ? innerType.typeName : "";
		const ctorFnName = mangledName + "_new";
		const ctorEntry = mangledName !== "" ? lookupCtorDefaults(ctorFnName) : null;
		if (ctorEntry !== null && ctorEntry.fnType !== null && ctorEntry.fnType.typeChildren !== null) {
			fillDefaults(ctx, d.newArguments, ctorEntry.defaults,
				ctorEntry.fnType.typeChildren.length, 0, ctorEntry.fnType.typeChildren);
		} else if (d.newCallee.resolvedSym !== null && d.newCallee.resolvedSym.defaultParams !== null
				&& d.newCallee.resolvedSym.defaultParams.length > 0) {
			// Path 2: non-generic constructors — defaults on class sym
			const defaults = d.newCallee.resolvedSym.defaultParams;
			const ctorParamTypes = getCtorParamTypes(d.newCallee.resolvedSym);
			fillDefaults(ctx, d.newArguments, defaults, defaults.length, 0, ctorParamTypes);
		}
	}
	if (resolvedType !== null && (resolvedType.kind === TypeKind.Struct || resolvedType.kind === TypeKind.Ref || resolvedType.kind === TypeKind.GenericInstance)) {
		return resolvedType;
	}
	return unknownType();
}

// ===== TryExpr =====

function checkTryExpr(ctx: CheckerContext, node: Node): Type {
	const d = node.data as TryExprData;
	const oldInTry = ctx.inTryExpr;
	ctx.inTryExpr = true;
	checkExpr(ctx, d.tryArg, null);
	const argType = d.tryArg.nodeType;
	ctx.inTryExpr = oldInTry;
	// tryArg.nodeType = Result<T,E> (set by checkExpr on the CallExpr)
	// resultDesugar reads tryArg.nodeType for the full Result type.
	// TryExpr itself evaluates to T (the unwrapped value).
	if (d.hasCatch) {
		checkExpr(ctx, d.catchVal, null);
	}
	if (argType !== null && isResult(argType) && getResultOkType(argType) !== null) {
		return getResultOkType(argType);
	}
	return argType;
}

// ===== Call Expression + Overload Resolution =====

function checkCallExpr(ctx: CheckerContext, node: Node, expectedType: Type): Type {
	const d = node.data as CallExprData;
	checkExpr(ctx, d.callee, null);
	let calleeType = d.callee.nodeType;
	// Detect overloaded paths early — these need argTypes for scoring
	let needsOverloadScoring = false;
	let overloadSym: Symbol = null as unknown as Symbol;
	// Extension pre-resolution state (set in MemberExpr branch, used after arg checking)
	let extPreResolved = false;
	let extMultiFiltered: ExtensionMethod[] = [];
	let extMultiObjType: Type = null;
	let extMultiMethodName = "";
	let isActorMethodCall = false;
	// Check for overloads + set resolvedSym for direct calls
	if (d.callee.kind === NodeKind.Identifier) {
		const calleeName = (d.callee.data as IdentifierData).name;
		const sym = lookupSymbol(ctx.table, calleeName);
		if (sym !== null) {
			// Demand-driven: ensure callee signature is ready
			ensureShaped(sym, ctx);
			node.resolvedSym = sym;
			markUsed(sym);
			sgRecordSym(ctx, d.callee.location.line, d.callee.location.column, d.callee.location.column + calleeName.length, sym, sym.symbolType, sym.symbolKind, calleeName, "", false);
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
		// Method call: copy resolvedSym from callee (set by class method lookup in checkMemberExpr)
		if (d.callee.resolvedSym !== null) {
			node.resolvedSym = d.callee.resolvedSym;
		}
		// Extension resolution for method calls.
		if (ctx.extensionRegistry !== null) {
			const me = d.callee.data as MemberExprData;
			const objType = me.object.nodeType;
			if (objType !== null && objType.kind !== TypeKind.Unknown) {
				const allByName = findAllExtensionsByName(ctx.extensionRegistry, me.property);
				let filtered = filterExtsByReceiverType(allByName, objType);
				// Type-level access (e.g., Buffer.method()) — only static extensions apply.
				const isStaticAccess = me.object.resolvedSym !== null
					&& (me.object.resolvedSym.symbolKind === SymbolKind.TypeAlias
						|| me.object.resolvedSym.symbolKind === SymbolKind.Class
						|| me.object.resolvedSym.symbolKind === SymbolKind.Actor
						|| me.object.resolvedSym.symbolKind === SymbolKind.Interface);
				if (isStaticAccess && filtered.length > 1) {
					const staticOnly: ExtensionMethod[] = [];
					for (const ext of filtered) {
						if (ext.isStatic) staticOnly.push(ext);
					}
					if (staticOnly.length > 0) filtered = staticOnly;
				}
				if (filtered.length === 1) {
					const winner = filtered[0];
					if (winner.sym !== null) {
						ensureShaped(winner.sym, ctx);
						if (node.resolvedSym === null || node.resolvedSym.name.indexOf("__", 0) < 0) {
							node.resolvedSym = winner.sym;
							d.callee.resolvedSym = winner.sym;
						}
						sgRecordSym(ctx, d.callee.location.line, d.callee.location.column + 1, d.callee.location.column + 1 + me.property.length, winner.sym, getExtFnType(winner), SymbolKind.Method, me.property, winner.receiverTypeName, false);
						if (!hasFlag(winner.sym, SymbolFlag.NativeMethod)) {
							node.flags = node.flags | NodeFlag.ExtCall;
						}
						if (winner.isStatic) node.flags = node.flags | NodeFlag.ExtStatic;
					}
					let extType = getExtFnType(winner);
					if (!winner.isStatic && extType.typeChildren.length > 0) {
						if (hasGenericParams(extType)) {
							const eb = createUnifyBindings();
							unifyType(extType.typeChildren[0], objType, eb);
							if (eb.names.length > 0) extType = instantiateGeneric(extType, eb.names, eb.types);
						}
						calleeType = stripReceiverParam(extType);
					} else {
						calleeType = extType;
					}
					extPreResolved = true;
					// Actor: flag for Sendable checking + Promise<T> wrapping for non-void returns
					// Check both direct Actor symbols (e.g. Worker.staticMethod) and
					// variables holding actor instances (e.g. w.method where w: Ref<Worker>)
					const isActorReceiver = !isStaticAccess && (
						(me.object.resolvedSym !== null && me.object.resolvedSym.symbolKind === SymbolKind.Actor)
						|| (objType !== null && objType.kind === TypeKind.Ref && objType.sym !== null && objType.sym.symbolKind === SymbolKind.Actor)
						|| (objType !== null && objType.sym !== null && objType.sym.symbolKind === SymbolKind.Actor)
					);
					if (isActorReceiver) {
						isActorMethodCall = true;
						if (calleeType !== null
							&& calleeType.typeReturn !== null
							&& calleeType.typeReturn.kind !== TypeKind.Void) {
							calleeType = createFunction(
								calleeType.typeChildren,
								calleeType.typeNames,
								createPromise(calleeType.typeReturn)
							);
						}
					}
				} else if (filtered.length > 1) {
					// Multi-overload: defer to post-arg scoring (needs argTypes)
					extMultiFiltered = filtered;
					extMultiObjType = objType;
					extMultiMethodName = me.property;
				}
			}
		}
	}
	// Backwards type inference: resolve generic params from expectedType before checking args.
	// e.g. Result.ok({...}) with expected Result<ParsedResponse, HttpError> → T=ParsedResponse
	// so arg expected type becomes ParsedResponse instead of GenericParam("T").
	if (!needsOverloadScoring && calleeType !== null && calleeType.kind === TypeKind.Function
		&& expectedType !== null && calleeType.typeReturn !== null
		&& hasGenericParams(calleeType)) {
		const backBindings = createUnifyBindings();
		unifyType(calleeType.typeReturn, expectedType, backBindings);
		if (backBindings.names.length > 0) {
			calleeType = instantiateGeneric(calleeType, backBindings.names, backBindings.types);
		}
	}
	// Check args — with expectedType from callee params (Reference parity: signature match formal type)
	const argTypes: Type[] = [];
	for (let ai = 0; ai < d.arguments.length; ai += 1) {
		let paramExpected: Type = null;
		if (!needsOverloadScoring && calleeType !== null && calleeType.kind === TypeKind.Function
			&& calleeType.typeChildren !== null
			&& ai < calleeType.typeChildren.length) {
			paramExpected = calleeType.typeChildren[ai];
		}
		checkExpr(ctx, d.arguments[ai], paramExpected);
		const argType = d.arguments[ai].nodeType;
		argTypes.push(argType);
	}
	// Overloaded direct calls — use argTypes for scoring
	if (needsOverloadScoring) {
		return resolveOverloadCall(ctx, overloadSym, argTypes, node);
	}
	// Pre-resolved single extension — return type inference (needs argTypes)
	if (extPreResolved) {
		// Fill default args (calleeType already has receiver stripped for non-static)
		// defaultOffset = 1 for non-static (fnDefaults[0] is receiver slot), 0 for static (receiver stripped in parser)
		const extDefaultOffset = (node.flags & NodeFlag.ExtStatic) !== 0 ? 0 : 1;
		if (argTypes.length < calleeType.typeChildren.length) {
			const me = d.callee.data as MemberExprData;
			fillDefaultArgsForNode(ctx, node, me.property, calleeType.typeChildren.length, extDefaultOffset);
		}
		// Explicit type arg resolution for generic methods (e.g. JSON.parse<Person>)
		if (hasGenericParams(calleeType)) {
			const explicitArg = findCallTypeArg(node);
			if (explicitArg !== "") {
				// JSON.parse<T> / JSON.stringify<T> — generate specialized function during checker
				// (reference-aligned: generateInstance + semProcBody pattern)
				if (node.resolvedSym !== null && node.resolvedSym.builtinKind === "JsonParse") {
					const result = generateJsonParseInstance(ctx, node, d, explicitArg, node.location);
					if (result !== null) return result;
				}
				if (node.resolvedSym !== null && node.resolvedSym.builtinKind === "JsonStringify") {
					const result = generateJsonStringifyInstance(ctx, node, d, node.location);
					if (result !== null) return result;
				}
				return inferGenericReturnWithExplicit(calleeType, argTypes, expectedType, explicitArg, ctx, node);
			}
			// JSON.parse() without <T> → returns Result<JsonValue, string> (untyped)
			if (node.resolvedSym !== null && node.resolvedSym.builtinKind === "JsonParse") {
				const jvSym = lookupSymbol(ctx.table, "JsonValue");
				if (jvSym !== null && jvSym.symbolType !== null && jvSym.symbolType.kind !== TypeKind.Unknown) {
					const resultType = createResult(jvSym.symbolType, stringType());
					node.nodeType = resultType;
					return resultType;
				}
			}
			// JSON.stringify(value) without <T> → infer T from argument, generate specialization
			if (node.resolvedSym !== null && node.resolvedSym.builtinKind === "JsonStringify") {
				const result = generateJsonStringifyInstance(ctx, node, d, node.location);
				if (result !== null) return result;
			}
		}
		// Sendable check for extension-resolved actor method calls
		if (isActorMethodCall) {
			for (let pi = 0; pi < d.arguments.length; pi += 1) {
				checkActorArgSendable(ctx, d.arguments[pi], pi);
			}
		}
		return inferGenericReturn(calleeType, argTypes, expectedType);
	}
	// Multi-overload extension — needs argTypes for scoring
	if (extMultiFiltered.length > 1) {
		return resolveExtensionOverloadCall(ctx, extMultiFiltered, argTypes, extMultiObjType, extMultiMethodName, node);
	}
	// @builtin("JsonStringify"): generate specialized function for struct/anon args
	// Reference parity: magicsAfterOverloadResolution runs for ALL magic calls,
	// not just generic/extension ones. Must check here for direct non-generic calls.
	if (node.resolvedSym !== null && node.resolvedSym.builtinKind === "JsonStringify") {
		const result = generateJsonStringifyInstance(ctx, node, d, node.location);
		if (result !== null) return result;
	}
	// @builtin("PromiseSpawn"): infer Promise<T> from closure's return type
	if (node.resolvedSym !== null && node.resolvedSym.builtinKind === "PromiseSpawn"
		&& argTypes.length >= 1 && argTypes[0] !== null && argTypes[0].kind === TypeKind.Function) {
		const spawnInner = argTypes[0].typeReturn !== null ? argTypes[0].typeReturn : voidType();
		const spawnRet = createPromise(spawnInner);
		node.nodeType = spawnRet;
		// Spawn borrow checker: detect mutable variable captures
		if (d.arguments.length >= 1) {
			checkSpawnCaptures(ctx, d.arguments[0], node);
		}
		return spawnRet;
	}
	// Check argument types + infer generic return
	// @builtin("Echo"): accept any number of args of any type (reference echo parity)
	const isEchoBuiltin = node.resolvedSym !== null && node.resolvedSym.builtinKind === "Echo";
	if (calleeType.kind === TypeKind.Function && !isEchoBuiltin) {
		// Rest param detection: last typeNames entry starts with "..." (reference parity: tyVarargs)
		const lastPN = calleeType.typeNames.length > 0 ? calleeType.typeNames[calleeType.typeNames.length - 1] : "";
		const hasRest = lastPN.length > 3 && lastPN.slice(0, 3) === "...";
		// Fill default arguments if too few args provided
		const minAr = getMinArity(calleeType);
		// Rest param is optional (accepts 0+ args), so effective min excludes it
		const effectiveMin = hasRest && minAr >= calleeType.typeChildren.length
			? calleeType.typeChildren.length - 1 : minAr;
		if (argTypes.length < effectiveMin) {
			addError(ctx, `Too few arguments: expected at least ${effectiveMin}, got ${argTypes.length}`, node.location.line, node.location.column);
		} else if (!hasRest && argTypes.length > calleeType.typeChildren.length) {
			addError(ctx, `Too many arguments: expected at most ${calleeType.typeChildren.length}, got ${argTypes.length}`, node.location.line, node.location.column);
		} else if (argTypes.length < calleeType.typeChildren.length) {
			const calleeNameForDef = getCalleeNameForDefaults(node);
			if (calleeNameForDef !== "") {
				fillDefaultArgsForNode(ctx, node, calleeNameForDef, calleeType.typeChildren.length, 0);
			}
		}
		// Type-check provided args (rest args check against element type of rest param)
		const restParamIdx = hasRest ? calleeType.typeChildren.length - 1 : -1;
		for (let pi = 0; pi < argTypes.length; pi += 1) {
			let paramType: Type = null as unknown as Type;
			if (hasRest && pi >= restParamIdx) {
				// Args at or beyond rest param position: check against element type
				const restType = calleeType.typeChildren[restParamIdx];
				paramType = restType.typeReturn !== null ? restType.typeReturn : restType;
			} else if (pi < calleeType.typeChildren.length) {
				paramType = calleeType.typeChildren[pi];
			} else {
				continue;
			}
			if (argTypes[pi] === null || argTypes[pi] === null) continue;
			if (paramType.kind !== TypeKind.Unknown && paramType.kind !== TypeKind.GenericParam
				&& paramType.kind !== TypeKind.Function
				&& argTypes[pi].kind !== TypeKind.Unknown && argTypes[pi].kind !== TypeKind.Error
				&& argTypes[pi].kind !== TypeKind.Function) {
				if (!isAssignable(argTypes[pi], paramType)) {
					if (needsStdConv(argTypes[pi], paramType)) {
						// Implicit numeric conversion — warn for float/number → integer narrowing
						if ((argTypes[pi].kind === TypeKind.Number || isFloatType(argTypes[pi])) && isIntegerType(paramType)) {
							const calleeName = getCalleeName(d.callee);
							addWarning(ctx, `implicit ${typeNameOf(argTypes[pi])} → ${typeNameOf(paramType)} narrowing in '${calleeName}' arg ${pi}`, node.location.line, node.location.column);
						}
					} else {
						const calleeName = getCalleeName(d.callee);
						addError(ctx, "Argument type mismatch in '" + calleeName + "' arg " + String(pi) + ": got " + typeNameOf(argTypes[pi]) + ", expected " + typeNameOf(paramType), node.location.line, node.location.column);
					}
				}
				// Reference parity: var/out params require lvalue argument
				if (paramType.kind === TypeKind.Var && pi < d.arguments.length) {
					const argKind = d.arguments[pi].kind;
					if (argKind !== NodeKind.Identifier && argKind !== NodeKind.MemberExpr && argKind !== NodeKind.ArrayAccess) {
						const calleeName = getCalleeName(d.callee);
						addError(ctx, "'" + calleeName + "' arg " + String(pi) + ": out parameter requires a variable, not an expression", node.location.line, node.location.column);
					}
				}
				if (needsStdConv(argTypes[pi], paramType)) {
					// Implementation parity: insert HiddenStdConv for numeric widening/narrowing OR Span coercion
					const convTok = createToken(TokenKind.Ident, "", d.arguments[pi].location.line);
					const convNode = createNode(NodeKind.HiddenStdConv, { convExpr: d.arguments[pi], convType: paramType }, convTok);
					convNode.nodeType = paramType;
					convNode.flags = convNode.flags | NodeFlag.Sem;
					d.arguments[pi] = convNode;
				}
				// Sendable check: actor method args must be safe to cross boundary
				if (isActorMethodCall && pi < d.arguments.length) {
					checkActorArgSendable(ctx, d.arguments[pi], pi);
				}
			}
		}
		// On-demand generic instantiation for direct calls (transitive instantiation)
		// When a generic function is called with concrete arg types, instantiate it.
		if (node.resolvedSym !== null && node.resolvedSym.declNode !== null
			&& node.resolvedSym.declNode.kind === NodeKind.FunctionDecl
			&& node.resolvedSym.builtinKind === "") {  // skip builtins — they're rewritten, not instantiated
			const directFlags = (node.resolvedSym.declNode.data as FunctionDeclData).fnFlags;
			if (directFlags.indexOf("gen:", 0) >= 0) {
				const deb = createUnifyBindings();
				const dLimit = argTypes.length < calleeType.typeChildren.length ? argTypes.length : calleeType.typeChildren.length;
				for (let di = 0; di < dLimit; di += 1) {
					if (argTypes[di] !== null) {
						unifyType(calleeType.typeChildren[di], argTypes[di], deb);
					}
				}
				if (deb.names.length > 0) {
					const directInstSym = callInstantiateGeneric(node.resolvedSym, deb.names, deb.types, ctx);
					if (directInstSym !== null) {
						node.resolvedSym = directInstSym;
						d.callee.resolvedSym = directInstSym;
						calleeType = directInstSym.symbolType;
					}
				}
			}
		}
		// If explicit type args (<T>) and generic params, resolve type args at checker time
		if (hasGenericParams(calleeType)) {
			const explicitArg = findCallTypeArg(node);
			if (explicitArg !== "") {
				return inferGenericReturnWithExplicit(calleeType, argTypes, expectedType, explicitArg, ctx, node);
			}
		}
		return inferGenericReturn(calleeType, argTypes, expectedType);
	}
	return getReturnType(calleeType);
}

// Resolve generic return type using explicit type arg (e.g. parse<Person>)
function inferGenericReturnWithExplicit(fnType: Type, argTypes: Type[], expectedType: Type, explicitArg: string, ctx: CheckerContext, node: Node): Type {
	let returnType = fnType.typeReturn;
	if (returnType === null) return unknownType();
	// Resolve the explicit type arg to an actual type
	const resolvedSym = lookupSymbol(ctx.table, explicitArg);
	if (resolvedSym === null) return inferGenericReturn(fnType, argTypes, expectedType);
	ensureShaped(resolvedSym, ctx);
	const concreteType = resolvedSym.symbolType;
	// Record the type arg as a symbol reference for LSP hover/goto-def
	if (node !== null) {
		const typeArgCol = computeTypeArgCol(node);
		if (typeArgCol > 0) {
			const symKind = resolvedSym.symbolKind === SymbolKind.Interface ? SymbolKind.Interface
				: resolvedSym.symbolKind === SymbolKind.Class ? SymbolKind.Class
				: resolvedSym.symbolKind === SymbolKind.Actor ? SymbolKind.Actor
				: resolvedSym.symbolKind === SymbolKind.TypeAlias ? SymbolKind.TypeAlias
				: SymbolKind.Interface;
			sgRecordSym(ctx, node.location.line, typeArgCol, typeArgCol + explicitArg.length, resolvedSym, concreteType, symKind, explicitArg, "", false);
		}
	}
	// Find first generic param name in the return type and substitute
	const genericParamName = findFirstGenericParamName(returnType);
	// Single type arg → bind to first generic param found
	if (genericParamName !== "") {
		returnType = substituteType(returnType, genericParamName, concreteType);
		// Reference parity: eagerly instantiate body for concrete GenericInstance
		if (returnType.kind === TypeKind.GenericInstance && returnType.typeReturn === null) {
			const declParams = getGenericDecl(returnType.typeName);
			instantiateGenericBody(returnType, declParams);
		}
	}
	return returnType;
}

// Compute the column where the type arg name starts (after '<') in a call expression.
// For `foo<T>(...)`: callee.col + "foo".length + 1 (skip '<')
// For `obj.method<T>(...)`: callee.col + 1 + "method".length + 1 (skip '.' and '<')
function computeTypeArgCol(node: Node): number {
	const cd = node.data as CallExprData;
	if (cd.callee === null) return 0;
	if (cd.callee.kind === NodeKind.Identifier) {
		const name = (cd.callee.data as IdentifierData).name;
		return cd.callee.location.column + name.length + 1;  // +1 for '<'
	}
	if (cd.callee.kind === NodeKind.MemberExpr) {
		const me = cd.callee.data as MemberExprData;
		// callee location points to property start (after dot)
		return cd.callee.location.column + 1 + me.property.length + 1;  // +1 col offset, +propLen, +1 for '<'
	}
	return 0;
}

// Find the first GenericParam name in a type tree (non-recursive to avoid array-by-value bug)
function findFirstGenericParamName(t: Type): string {
	if (t === null) return "";
	if (t.kind === TypeKind.GenericParam) return t.typeName;
	// Check typeReturn (Result.okType, Array.elemType, Function.returnType, etc.)
	if (t.typeReturn !== null) {
		const name = findFirstGenericParamName(t.typeReturn);
		if (name !== "") return name;
	}
	// Check typeExtra (Result.errType, Map.valueType, etc.)
	if (t.typeExtra !== null) {
		const name = findFirstGenericParamName(t.typeExtra);
		if (name !== "") return name;
	}
	// Check typeChildren (Function params, Union members, etc.)
	for (let i = 0; i < t.typeChildren.length; i += 1) {
		const name = findFirstGenericParamName(t.typeChildren[i]);
		if (name !== "") return name;
	}
	return "";
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
					msg = msg + "\n      first mismatch at position " + String(mpos + 1) + ": expected '" + typeNameOf(candidates[ci].typeChildren[mpos]) + "', got '" + typeNameOf(argTypes[mpos]) + "'";
				} else if (candidates[ci].typeChildren.length !== argTypes.length) {
					msg = msg + "\n      expected " + String(candidates[ci].typeChildren.length) + " argument(s), got " + String(argTypes.length);
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
		fillDefaultArgsForNode(ctx, callNode, sym.name, winner.typeChildren.length, 0);
	}
	return inferGenericReturn(winner, argTypes, null);
}

// Resolve extension method overloads: multiple extensions match same receiver+method.
// Each extension's fnType includes the receiver as param[0]; strip it before scoring.
function resolveExtensionOverloadCall(ctx: CheckerContext, exts: ExtensionMethod[],
	argTypes: Type[], objType: Type, methodName: string, callNode: Node): Type {
	// Dedup handled at registration (registerExtension rejects duplicate syms).
	// Build candidate list: getExtFnType for authoritative type, stripReceiverParam for scoring.
	const candidates: Type[] = [];
	let ei = 0;
	while (ei < exts.length) {
		let srcType = getExtFnType(exts[ei]);
		if (hasGenericParams(srcType)) {
			const eb = createUnifyBindings();
			unifyType(srcType.typeChildren[0], objType, eb);
			if (eb.names.length > 0) {
				srcType = instantiateGeneric(srcType, eb.names, eb.types);
			}
		}
		if (!exts[ei].isStatic && srcType.typeChildren.length > 0) {
			candidates.push(stripReceiverParam(srcType));
		} else {
			candidates.push(srcType);
		}
		ei = ei + 1;
	}
	// Score and resolve — ext.scopeDepth as calleeScope
	// (0 = imported/prelude, 1 = current module; higher wins in cmpCandidates)
	const scopeDepths: number[] = [];
	let di = 0;
	while (di < candidates.length) {
		scopeDepths.push(exts[di].scopeDepth);
		di = di + 1;
	}
	let idx = resolveOverloadIdxWithInheritance(ctx, candidates, argTypes, scopeDepths);
	if (idx === -2) {
		// Tiebreaker: prefer concrete extension over generic
		let concreteIdx = -1;
		let concreteCount = 0;
		let ti = 0;
		while (ti < exts.length) {
			if (!hasGenericParams(getExtFnType(exts[ti]))) {
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
	if (idx >= 0 && idx < exts.length && exts[idx].sym !== null) {
		callNode.resolvedSym = exts[idx].sym;
		// Mark for transform: skip registry re-lookup (reference resolves UFCS in sem)
		if (!hasFlag(exts[idx].sym, SymbolFlag.NativeMethod)) {
			callNode.flags = callNode.flags | NodeFlag.ExtCall;
		}
		if (exts[idx].isStatic) callNode.flags = callNode.flags | NodeFlag.ExtStatic;
	}
	// Fill default args for extension overloads
	// defaultOffset: 0 for static (parser stripped receiver from fnDefaults), 1 for non-static
	const winnerType = candidates[idx];
	if (winnerType.kind === TypeKind.Function && argTypes.length < winnerType.typeChildren.length) {
		const ovDefaultOffset = (idx >= 0 && idx < exts.length && exts[idx].isStatic) ? 0 : 1;
		fillDefaultArgsForNode(ctx, callNode, methodName, winnerType.typeChildren.length, ovDefaultOffset);
	}
	return inferGenericReturn(winnerType, argTypes, null);
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
	let bestType: Type = null;
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
// Build a one-off Symbol from ExportedSymInfo for namespace member access.
// Same metadata as importSymFromRegistry, but NOT defined in any scope.
function createSymFromExport(expInfo: ExportedSymInfo, sourcePath: string): Symbol {
	const sym = makeSymbolState(expInfo.name, expInfo.kind, expInfo.symType, false, SymbolState.Shaped);
	sym.modulePath = expInfo.definingModule !== "" ? expInfo.definingModule : sourcePath;
	if (expInfo.originalName !== "") sym.originalName = expInfo.originalName;
	if (expInfo.nativeName !== "") sym.nativeName = expInfo.nativeName;
	if (expInfo.builtinKind !== "") sym.builtinKind = expInfo.builtinKind;
	if (expInfo.headerPath !== "") sym.headerPath = expInfo.headerPath;
	if (expInfo.jsModulePath !== "") sym.jsModulePath = expInfo.jsModulePath;
	sym.defaultParams = expInfo.defaultParams;
	if (expInfo.overloadTypes.length > 0) {
		sym.overloads = [];
		let oi = 0;
		while (oi < expInfo.overloadTypes.length) {
			const overSym = makeSymbolState(expInfo.name, expInfo.kind, expInfo.overloadTypes[oi], false, SymbolState.Shaped);
			overSym.modulePath = sym.modulePath;
			if (oi < expInfo.overloadNativeNames.length && expInfo.overloadNativeNames[oi] !== "") {
				overSym.nativeName = expInfo.overloadNativeNames[oi];
			}
			if (oi < expInfo.overloadBuiltinKinds.length && expInfo.overloadBuiltinKinds[oi] !== "") {
				overSym.builtinKind = expInfo.overloadBuiltinKinds[oi];
			}
			if (oi < expInfo.overloadDefaultParamsCounts.length) {
				const cnt = expInfo.overloadDefaultParamsCounts[oi];
				if (cnt > 0) {
					overSym.defaultParams = [];
					let startIdx = 0;
					let ci = 0;
					while (ci < oi) { startIdx = startIdx + expInfo.overloadDefaultParamsCounts[ci]; ci = ci + 1; }
					let di = 0;
					while (di < cnt) { overSym.defaultParams.push(expInfo.overloadDefaultParamsFlat[startIdx + di]); di = di + 1; }
				}
			}
			sym.overloads.push(overSym);
			oi = oi + 1;
		}
	}
	return sym;
}

function isPointerInC(t: Type, ctx: CheckerContext): boolean {
	if (t === null) return false;
	return t.kind === TypeKind.Ref || t.kind === TypeKind.Ptr || t.kind === TypeKind.Borrow;
}

// Validate object literal construction against a discriminated union type.
// Finds the discriminant field in the literal, resolves the variant, and validates fields.
function checkDiscriminatedConstruction(ctx: CheckerContext, node: Node, d: ObjectLiteralData, unionType: Type, stampType: Type): Type {
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
			checkExpr(ctx, prop, null);
		}
		addError(ctx, "Object literal for discriminated union '" + unionType.typeName + "' missing discriminant field '" + discName + "'", node.location.line, node.location.column);
		node.nodeType = stampType !== null ? stampType : unionType;
		return node.nodeType;
	}

	// Check the discriminant expression first to get its value
	const discExpr = d.properties[discIdx];
	checkExpr(ctx, discExpr, unionType.typeExtra);
	const discType = discExpr.nodeType;

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
				const ch = discValue.charAt(ci);
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
		// Use stampType (preserves Ref wrapper) so codegen knows to heap-allocate
		node.nodeType = stampType !== null ? stampType : unionType;
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
				checkExpr(ctx, d.properties[fi], null);
				addError(ctx, "Field '" + key + "' does not exist on variant " + unionType.typeNames[variantIdx + 1] + " of '" + unionType.typeName + "'", node.location.line, node.location.column);
			}
			fi = fi + 1;
		}
		return node.nodeType;
	}

	// Could not resolve variant — check properties without validation
	let pi = 0;
	while (pi < d.properties.length) {
		if (pi !== discIdx) {
			checkExpr(ctx, d.properties[pi], null);
		}
		pi = pi + 1;
	}
	node.nodeType = stampType !== null ? stampType : unionType;
	return node.nodeType;
}

function hasThisParam(sym: Symbol): boolean {
	return sym.symbolType !== null && sym.symbolType.typeNames !== null
		&& sym.symbolType.typeNames.length > 0 && sym.symbolType.typeNames[0] === "this";
}

function checkMemberExpr(ctx: CheckerContext, node: Node): Type {
	const d = node.data as MemberExprData;
	checkExpr(ctx, d.object, null);
	const objType = d.object.nodeType;
	if (objType === null) return unknownType();
	// Ref parity: strictNotNil — warn on unguarded class (heap pointer) member access
	if (ctx.strictNullChecks && objType.kind === TypeKind.Ref && d.object.kind === NodeKind.Identifier) {
		const objName = (d.object.data as IdentifierData).name;
		if (impliesNotNull(ctx.narrowFacts, objName) === 0) {
			addWarning(ctx, "accessing member '" + d.property + "' on potentially null class '" + objName + "'",
				node.location.line, node.location.column);
		}
	}
	// Enum member access: Color.Red → rewrite to Identifier "Color_Red" (standard reference pattern)
	// This rewrites the AST so codegen never sees enum-specific MemberExpr.
	// Skip "toString" — that's a method call, not a member access.
	// builtinLower handles enum .toString() → EnumName_toString(value).
	if (objType.kind === TypeKind.Enum && d.property !== "toString") {
		const enumName = objType.typeName;
		const propName = d.property;
		// Extern C enums: member names are already full C identifiers (e.g. WGPUCullMode_Back)
		const enumSym0 = lookupSymbol(ctx.table, enumName);
		const isExternEnum = enumSym0 !== null && hasFlag(enumSym0, SymbolFlag.ImportC);
		const mangledName = isExternEnum ? propName : enumName + "_" + propName;
		// Create synthetic symbol for the enum member (no scope lookup needed).
		// Enum member mangled names are NOT in scope — resolved here at use site.
		const enumSym = lookupSymbol(ctx.table, enumName);
		const memberSym = makeSymbolState(propName, SymbolKind.EnumMember, objType, false, SymbolState.Shaped);
		if (enumSym !== null && enumSym.location !== null) {
			memberSym.location = enumSym.location;
			memberSym.modulePath = enumSym.modulePath;
		}
		sgRecordSym(ctx, node.location.line, node.location.column + 1, node.location.column + 1 + propName.length, memberSym, objType, SymbolKind.EnumMember, propName, enumName, false);
		// Rewrite entire node to Identifier
		node.kind = NodeKind.Identifier;
		node.data = { name: mangledName };
		node.resolvedSym = memberSym;
		node.nodeType = objType;
		return objType;
	}
	// Module namespace access: ns.X where ns is import * as ns
	// Resolve directly from the module's export table — never from local scope.
	// Keep MemberExpr (don't rewrite to Identifier):
	//   C codegen: handles Module MemberExpr → emits mangled name
	//   JS codegen: emits ns.X naturally (standard ES6 namespace access)
	if (d.object.resolvedSym !== null && d.object.resolvedSym.symbolKind === SymbolKind.Module) {
		const nsModPath = d.object.resolvedSym.modulePath;
		if (nsModPath !== "") {
			const expInfo = findExportedSymbol(ctx.exportRegistry, nsModPath, d.property);
			if (expInfo !== null) {
				const memSym = createSymFromExport(expInfo, nsModPath);
				node.resolvedSym = memSym;
				node.nodeType = expInfo.symType;
				return expInfo.symType;
			}
			addError(ctx, `Module '${d.object.resolvedSym.name}' has no export '${d.property}'`, node.location.line, node.location.column);
			return unknownType();
		}
	}
	// reference parity: strip Ref/Ptr BEFORE field resolution, insert deref AFTER
	// reference: skip pointer types → lookup field → make dereference
	const needsDeref = isPointerInC(objType, ctx);
	let resolvedObjType = objType;
	if (needsDeref && objType.typeReturn !== null) {
		resolvedObjType = objType.typeReturn;
		// Ptr<Ref<T>>: unwrap both layers to reach the underlying Struct.
		// Ptr wraps Ref for class pointer fields — a single HiddenDeref dereferences both.
		if (resolvedObjType.kind === TypeKind.Ref && resolvedObjType.typeReturn !== null) {
			resolvedObjType = resolvedObjType.typeReturn;
		}
	}
	// Static access detection: when the object is a type name (class, type alias, interface, struct),
	// skip instance field resolution — go to static method lookup.
	// Allows field/method name coexistence: result.ok (field) vs Result.ok() (static method).
	// TypeAlias included for patterns like Buffer.alloc() where Buffer is `type Buffer = string`.
	const isStaticClassAccess = d.object.resolvedSym !== null
		&& (d.object.resolvedSym.symbolKind === SymbolKind.Class
			|| d.object.resolvedSym.symbolKind === SymbolKind.Actor
			|| d.object.resolvedSym.symbolKind === SymbolKind.TypeAlias
			|| d.object.resolvedSym.symbolKind === SymbolKind.Interface
			|| d.object.resolvedSym.symbolKind === SymbolKind.Struct);
	let propType = isStaticClassAccess ? unknownType() : getProperty(resolvedObjType, d.property);
	// Static property lookup: check class symbol's staticFields
	if (isStaticClassAccess && propType.kind === TypeKind.Unknown && d.object.resolvedSym !== null) {
		const staticField = findStaticField(d.object.resolvedSym, d.property);
		if (staticField !== null) {
			node.resolvedSym = staticField;
			return staticField.symbolType;
		}
	}
	// Class-aware field delegation (system module symbol lookup):
	// When a built-in TypeKind (Promise, Result, etc.) has a typeName but getProperty() can't
	// find the field, look up the class symbol by name and try field resolution on its struct.
	// For generic classes, substitute class-level generic params (T, E) with concrete types
	// from the actual object (e.g. Result<string, number> → T=string, E=number).
	// Skip for static class access — static methods are found via class method lookup below.
	if (propType.kind === TypeKind.Unknown && !isStaticClassAccess && resolvedObjType.typeName !== "") {
		const classSym = lookupSymbol(ctx.table, resolvedObjType.typeName);
		if (classSym !== null) {
			ensureShaped(classSym, ctx);
			let classStruct = classSym.symbolType;
			if (classStruct.kind === TypeKind.Ref && classStruct.typeReturn !== null) {
				classStruct = classStruct.typeReturn;
			}
			if (classStruct.kind === TypeKind.Struct) {
				propType = getProperty(classStruct, d.property);
				// Substitute generic params: build a formal type with GenericParam placeholders,
				// unify with the concrete object type to discover bindings, then substitute.
				if (propType.kind !== TypeKind.Unknown && hasGenericParams(propType)) {
					const genericStr = getGenericDecl(resolvedObjType.typeName);
					if (genericStr !== "") {
						const genericNames = splitTopLevel(genericStr, ",");
						const genericParams: Type[] = [];
						for (const gn of genericNames) {
							genericParams.push(createGenericParam(gn.trim()));
						}
						let formalType: Type = null as unknown as Type;
						if (formalType !== null) {
							const eb = createUnifyBindings();
							unifyType(formalType, resolvedObjType, eb);
							for (let gi = 0; gi < eb.names.length; gi += 1) {
								propType = substituteType(propType, eb.names[gi], eb.types[gi]);
							}
						}
					}
				}
				// Create synthetic resolvedSym for the field (needed by codegen/analyzer)
				if (propType.kind !== TypeKind.Unknown) {
					const fieldSym = makeSymbol(d.property, SymbolKind.Property, propType, false);
					fieldSym.state = SymbolState.Shaped;
					inheritContainerInfo(fieldSym, ctx, resolvedObjType.typeName);
					node.resolvedSym = fieldSym;
					sgRecordSym(ctx, node.location.line, node.location.column + 1, node.location.column + 1 + d.property.length, fieldSym, propType, SymbolKind.Property, d.property, resolvedObjType.typeName, false);
				}
			}
		}
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
				sgRecordSym(ctx, node.location.line, node.location.column + 1, node.location.column + 1 + d.property.length, propSym, propType, SymbolKind.Property, d.property, resolvedObjType.typeName, false);
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
					inheritContainerInfo(synthSym, ctx, resolvedObjType.typeName);
					node.resolvedSym = synthSym;
					sgRecordSym(ctx, node.location.line, node.location.column + 1, node.location.column + 1 + mName.length, synthSym, resolvedObjType.typeChildren[mi], SymbolKind.Property, mName, resolvedObjType.typeName, false);
					break;
				}
				mi = mi + 1;
			}
		}
		return propType;
	}

	// Builtin properties: .length on array/string
	if (d.property === "length" && (resolvedObjType.kind === TypeKind.Array || resolvedObjType.kind === TypeKind.SizedArray || resolvedObjType.kind === TypeKind.Span || isStringLike(resolvedObjType) || resolvedObjType.kind === TypeKind.CString)) {
		// Create a synthetic symbol for 'length' to satisfy the validator
		const lengthSym = makeSymbol("length", SymbolKind.Property, int32Type(), false);
		lengthSym.state = SymbolState.Shaped;
		node.resolvedSym = lengthSym;
		return int32Type();
	}
	// String .code — compile-time char code, folded by constantFolding transform
	if (d.property === "code" && resolvedObjType.kind === TypeKind.String) {
		const codeSym = makeSymbol("code", SymbolKind.Property, int32Type(), false);
		codeSym.state = SymbolState.Shaped;
		node.resolvedSym = codeSym;
		return int32Type();
	}
	// String-specific properties: .byteLength, .unicodeLength
	// Skip when accessed on a TYPE (e.g., Buffer.byteLength(json)) — that's a static extension call.
	// Only resolve as property when accessed on an instance (e.g., str.byteLength).
	if ((d.property === "byteLength" || d.property === "unicodeLength") && resolvedObjType.kind === TypeKind.String) {
		const isTypeAccess = d.object.resolvedSym !== null
			&& (d.object.resolvedSym.symbolKind === SymbolKind.TypeAlias
				|| d.object.resolvedSym.symbolKind === SymbolKind.Class
				|| d.object.resolvedSym.symbolKind === SymbolKind.Actor
				|| d.object.resolvedSym.symbolKind === SymbolKind.Interface);
		if (!isTypeAccess) {
			const propSym = makeSymbol(d.property, SymbolKind.Property, int32Type(), false);
			propSym.state = SymbolState.Shaped;
			node.resolvedSym = propSym;
			return int32Type();
		}
	}
	// Map/Set methods — resolved via class-aware field delegation bridge below.
	// No hardcoded dispatch: Map and Set classes declare @builtin methods in std/core/structure.

	// Class method lookup: ClassName_methodName in symbol table (methods are standalone procs).
	// Filters by static/instance: static access (SymbolKind.Class) only matches static methods,
	// instance access only matches instance methods. Checks overloads if primary doesn't match.
	if (resolvedObjType.typeName !== "") {
		const classMethName = resolvedObjType.typeName + "_" + d.property;
		let classMethSym = lookupSymbol(ctx.table, classMethName);
		// Filter: instance methods have "this" as first param, static methods don't.
		// If the found symbol doesn't match the access type, check overloads for one that does.
		if (classMethSym !== null && classMethSym.symbolKind === SymbolKind.Function) {
			const wantInstance = !isStaticClassAccess;
			if (hasThisParam(classMethSym) !== wantInstance) {
				let found = false;
				for (const ov of classMethSym.overloads) {
					if (hasThisParam(ov) === wantInstance) { classMethSym = ov; found = true; break; }
				}
				if (!found) classMethSym = null as unknown as Symbol;
			}
		}
		if (classMethSym !== null && classMethSym.symbolKind === SymbolKind.Function) {
			ensureShaped(classMethSym, ctx);
			node.resolvedSym = classMethSym;
			sgRecordSym(ctx, node.location.line, node.location.column + 1, node.location.column + 1 + d.property.length, classMethSym, classMethSym.symbolType, SymbolKind.Method, d.property, resolvedObjType.typeName, false);
			if (needsDeref) {
				const tok = createToken(TokenKind.Ident, "", node.location.line);
				const derefNode = createNode(NodeKind.HiddenDeref, { expr: d.object }, tok);
				derefNode.nodeType = resolvedObjType;
				d.object = derefNode;
			}
			// Strip receiver param (index 0) for instance methods only — static methods have no "this"
			const methType = classMethSym.symbolType;
			if (methType.kind === TypeKind.Function && methType.typeChildren.length > 0 && methType.typeNames.length > 0 && methType.typeNames[0] === "this") {
				// Generic class method substitution: unify receiver (e.g. Promise<T>) with
				// actual object type (e.g. Promise<string>) to discover T → string,
				// then substitute in parameter/return types.
				const receiverType = methType.typeChildren[0];
				const eb = createUnifyBindings();
				if (hasGenericParams(receiverType)) {
					unifyType(receiverType, objType, eb);
				}
				let callParams: Type[] = [];
				const callNames: string[] = [];
				for (let ci = 1; ci < methType.typeChildren.length; ci += 1) {
					let paramType = methType.typeChildren[ci];
					for (let gi = 0; gi < eb.names.length; gi += 1) {
						paramType = substituteType(paramType, eb.names[gi], eb.types[gi]);
					}
					callParams.push(paramType);
				}
				for (let ci = 1; ci < methType.typeNames.length; ci += 1) {
					callNames.push(methType.typeNames[ci]);
				}
				let retType = methType.typeReturn;
				for (let gi = 0; gi < eb.names.length; gi += 1) {
					retType = substituteType(retType, eb.names[gi], eb.types[gi]);
				}
				return createFunction(callParams, callNames, retType);
			}
			return methType;
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
		if (ext === null && objType.typeName === "") {
			const tn = typeNameOf(objType);
			if (tn !== "") {
				const staticType = createTypeRef("typeof " + tn);
				ext = findFirstMatchingExt(allByName, staticType);
			}
		}
		// Static extension on type alias: try the symbol name directly (e.g., Buffer.alloc
		// where Buffer is `type Buffer = string` — objType resolves to string, but
		// the extension is registered as `this typeof Buffer`).
		if (ext === null && isStaticClassAccess && d.object.resolvedSym !== null) {
			const symName = d.object.resolvedSym.name;
			const aliasType = createTypeRef(symName);
			ext = findFirstMatchingExt(allByName, aliasType);
		}
		if (ext !== null) {
			// Direct sym link — no name-based lookup needed
			if (ext.sym !== null) {
				ensureShaped(ext.sym, ctx);
				node.resolvedSym = ext.sym;
				markUsed(ext.sym);
				// Also mark the imported symbol (may be a different object than ext.sym)
				const importedSym = lookupSymbol(ctx.table, ext.sym.name);
				if (importedSym !== null) markUsed(importedSym);
				sgRecordSym(ctx, node.location.line, node.location.column + 1, node.location.column + 1 + d.property.length, ext.sym, getExtFnType(ext), SymbolKind.Method, d.property, ext.receiverTypeName, false);
			}
			// Instance extension: strip receiver param (index 0) so checkCallExpr
			// sees only user-visible params. The receiver is already in MemberExpr.object.
			const extFnT = getExtFnType(ext);
			if (!ext.isStatic && extFnT.typeChildren.length > 0) {
				let srcType = extFnT;
				// Check for generics: either type-level (hasGenericParams) or flag-level (gen: in fnFlags)
				const symHasGenerics = hasGenericParams(srcType) || (ext.sym !== null && ext.sym.declNode !== null && ext.sym.declNode.kind === NodeKind.FunctionDecl && (ext.sym.declNode.data as FunctionDeclData).fnFlags.indexOf("gen:", 0) >= 0);
				if (symHasGenerics) {
					const eb = createUnifyBindings();
					// GenericInstance unification — structural matching, no string parsing
					unifyType(srcType.typeChildren[0], objType, eb);
					if (eb.names.length > 0) {
						// On-demand instantiation (generateInstance pattern)
						// Clone the generic function, substitute types, register specialized version
						if (ext.sym !== null && ext.sym.declNode !== null && ext.sym.builtinKind === "") {
							const instSym = callInstantiateGeneric(ext.sym, eb.names, eb.types, ctx);
							if (instSym !== null) {
								node.resolvedSym = instSym;
							}
						}
						srcType = instantiateGeneric(srcType, eb.names, eb.types);
					}
				}
				return stripReceiverParam(srcType);
			}
			return extFnT;
		}
	}
	// JsonValue dynamic member access: any unknown property returns JsonValue (null-propagating)
	// Placed AFTER extension registry so asString/asNumber/etc. resolve as extensions first.
	// No HiddenDeref — get() extension takes JsonValue (pointer), not dereferenced value.
	if (propType.kind === TypeKind.Unknown && (resolvedObjType.typeName === "JsonValue" || resolvedObjType.typeName === "JsonValueData")) {
		const dynSym = makeSymbol(d.property, SymbolKind.Property, objType, false);
		dynSym.state = SymbolState.Shaped;
		dynSym.nativeName = "__jsonDynAccess";
		node.resolvedSym = dynSym;
		return objType;
	}
	// Universal .toString() — every type has a compiler-provided default.
	// builtinLower resolves to the correct C function per type.
	// Return the function type (not string) so CallExpr extracts the return type.
	// Numeric types accept optional radix: .toString() or .toString(36)
	if (d.property === "toString" && propType.kind === TypeKind.Unknown) {
		let toStrFnType: Type = null;
		if (isNumeric(resolvedObjType)) {
			toStrFnType = createFunction([int32Type()], ["radix"], stringType());
			setMinArity(toStrFnType, 0);
		} else {
			toStrFnType = createFunction([], [], stringType());
		}
		const toStrSym = makeSymbol("toString", SymbolKind.Function, toStrFnType, false);
		toStrSym.state = SymbolState.Shaped;
		node.resolvedSym = toStrSym;
		return toStrFnType;
	}
	// Unresolved member access — emit error with field suggestion if available
	const propertyActuallyExists = resolvedObjType.typeNames !== null && resolvedObjType.typeNames.indexOf(d.property) >= 0;
	if (propType.kind === TypeKind.Unknown && resolvedObjType.kind !== TypeKind.Unknown && !propertyActuallyExists) {
		const typeName = typeNameOf(resolvedObjType) !== "" ? typeNameOf(resolvedObjType) : "object";
		let suggestion = "";
		if (resolvedObjType.typeNames !== null) {
			for (const fn of resolvedObjType.typeNames) {
				if (fn !== d.property && fn.length > 0) {
					if (suggestion === "") { suggestion = fn; }
					else { suggestion = suggestion + ", " + fn; }
				}
			}
		}
		if (suggestion !== "") {
			addError(ctx, `Property '${d.property}' does not exist on type '${typeName}'. Available: ${suggestion}`, node.location.line, node.location.column);
		} else {
			addError(ctx, `Property '${d.property}' does not exist on type '${typeName}'`, node.location.line, node.location.column);
		}
	}
	return propType;
}

// ===== Match Expression =====

function checkMatchExpr(ctx: CheckerContext, node: Node): Type {
	const d = node.data as MatchExprData;
	checkExpr(ctx, d.matchDisc, null);
	const discType = d.matchDisc.nodeType;
	let returnType = unknownType();
	let hasWildcard = false;
	const coveredMembers: string[] = [];

	// Detect discriminated union narrowing: match (base.discriminantField)
	// Use symbol lookup (not node.nodeType which may not be set by checkExpr's return path)
	let narrowBase: Symbol = null;
	let narrowUnion: Type = null;
	if (d.matchDisc.kind === NodeKind.MemberExpr) {
		const discMd = d.matchDisc.data as MemberExprData;
		if (discMd.object !== null && discMd.object.kind === NodeKind.Identifier) {
			const baseName = (discMd.object.data as IdentifierData).name;
			const baseSym = lookupSymbol(ctx.table, baseName);
			if (baseSym !== null && baseSym.symbolType !== null && isDiscriminatedUnion(baseSym.symbolType) && getDiscriminantName(baseSym.symbolType) === discMd.property) {
				narrowBase = baseSym;
				narrowUnion = baseSym.symbolType;
			}
		}
	}

	// Ref parity: trackCase — init tracking for match expression arms
	const oldState = saveInitState(ctx.initTracker);
	const branchInits: string[][] = [];
	const branchBreaks: BreakState[] = [];
	for (const c of d.matchCases) {
		const cd = c.data as MatchCaseData;
		restoreInitState(ctx.initTracker, oldState);
		const hasGuard = cd.caseGuard !== null;
		for (const p of cd.casePatterns) {
			if (p.kind === NodeKind.Identifier) {
				// Wildcard/binding — Standard reference's else has no pattern nodes at all.
				// Guarded wildcard/binding does NOT count as exhaustive coverage.
				if (!hasGuard) hasWildcard = true;
				p.nodeType = discType;
			} else {
				// Extract enum member name — only unguarded arms count for exhaustiveness
				if (p.kind === NodeKind.MemberExpr && !hasGuard) {
					const pmd = p.data as MemberExprData;
					coveredMembers.push(pmd.property);
				}
				checkExpr(ctx, p, discType);
			}
		}
		// Variant narrowing: temporarily narrow base symbol to the matched variant
		let savedNarrowType: Type = null;
		if (narrowBase !== null && cd.casePatterns.length === 1) {
			const pat = cd.casePatterns[0];
			let patEnumName = "";
			if (pat.kind === NodeKind.MemberExpr) {
				patEnumName = (pat.data as MemberExprData).property;
			} else if (pat.kind === NodeKind.Identifier && pat.resolvedSym !== null) {
				patEnumName = pat.resolvedSym.name;
			}
			if (patEnumName !== "") {
				const variantIdx = findVariantByDiscriminant(narrowUnion, patEnumName);
				if (variantIdx >= 0 && narrowUnion.typeChildren !== null && variantIdx < narrowUnion.typeChildren.length) {
					savedNarrowType = narrowBase.symbolType;
					narrowBase.symbolType = narrowUnion.typeChildren[variantIdx];
				}
			}
		}

		// Type-check guard expression with narrowing active
		if (cd.caseGuard !== null) {
			checkExpr(ctx, cd.caseGuard, null);
		}
		let bodyType = unknownType();
		if (cd.caseBody.kind === NodeKind.BlockStmt) {
			ctx.matchExprDepth = ctx.matchExprDepth + 1;
			callCheckStmt(ctx, cd.caseBody);
			ctx.matchExprDepth = ctx.matchExprDepth - 1;
			const bd = cd.caseBody.data as BlockStmtData;
			if (bd.statements.length > 0) {
				const last = bd.statements[bd.statements.length - 1];
				if (last.kind === NodeKind.ReturnStmt) {
					const rd = last.data as ReturnStmtData;
					if (rd.argument !== null) {
						checkExpr(ctx, rd.argument, null); bodyType = rd.argument.nodeType;
					}
				}
			}
		} else {
			checkExpr(ctx, cd.caseBody, null); bodyType = cd.caseBody.nodeType;
		}

		// Restore narrowed type
		if (savedNarrowType !== null) {
			narrowBase.symbolType = savedNarrowType;
		}
		branchInits.push(collectNewInits(ctx.initTracker, oldState));
		branchBreaks.push(breaksBlock(cd.caseBody));
		if (returnType.kind === TypeKind.Unknown && bodyType.kind !== TypeKind.Unknown) {
			returnType = bodyType;
		}
	}
	checkDuplicatePatterns(ctx, d.matchCases);

	// Match is exhaustive if has wildcard (_) or covers all enum members
	let isExhaustive = hasWildcard;
	if (!isExhaustive && discType.kind === TypeKind.Enum) {
		let allCovered = true;
		for (const member of discType.typeNames) {
			let found = false;
			for (const c of coveredMembers) {
				if (c === member) { found = true; }
			}
			if (!found) { allCovered = false; }
		}
		if (allCovered && discType.typeNames.length > 0) isExhaustive = true;
	}
	mergeInitBranches(ctx.initTracker, oldState, branchInits, branchBreaks, isExhaustive);
	if (discType.kind === TypeKind.Enum && !hasWildcard) {
		// Range covers `match (disc)` — from match keyword to closing paren
		const discEnd = estimateExprEndCol(d.matchDisc) + 1; // +1 for ")"
		checkEnumExhaustiveness(ctx, discType, coveredMembers, node.location.line, node.location.column, discEnd);
	}
	return returnType;
}

export function checkEnumExhaustiveness(ctx: CheckerContext, enumType: Type, covered: string[], matchLine: number, matchCol: number, discEndCol: number): void {
	for (const member of enumType.typeNames) {
		let found = false;
		for (const c of covered) {
			if (c === member) { found = true; }
		}
		if (!found) {
			// Range: from `match` keyword to closing `)` after discriminant
			addErrorRange(ctx, `Non-exhaustive match: missing '${enumType.typeName}.${member}'`, matchLine, matchCol, discEndCol);
		}
	}
}

// Estimate end column of an expression node (for diagnostic ranges)
export function estimateExprEndCol(node: Node): number {
	const col = node.location.column;
	return match (node.kind) {
		NodeKind.Identifier => col + (node.data as IdentifierData).name.length,
		NodeKind.MemberExpr => {
			const md = node.data as MemberExprData;
			return estimateExprEndCol(md.object) + 1 + md.property.length;
		},
		NodeKind.CallExpr => {
			// f(args) — estimate callee end + "()"
			const cd = node.data as CallExprData;
			return estimateExprEndCol(cd.callee) + 2;
		},
		NodeKind.ArrayAccess => {
			// arr[idx] — estimate array end + "[]"
			const ad = node.data as ArrayAccessData;
			return estimateExprEndCol(ad.array) + 3;
		},
		_ => col + 1,
	};
}

// Detect duplicate unguarded match patterns (reference parity: checkForOverlap).
// Shared by checkMatchExpr and checkMatchStmt.
export function checkDuplicatePatterns(ctx: CheckerContext, cases: Node[]): void {
	const seen: string[] = [];
	for (const c of cases) {
		const cd = c.data as MatchCaseData;
		if (cd.caseGuard !== null) continue;
		for (const p of cd.casePatterns) {
			let patKey = "";
			if (p.kind === NodeKind.NumberLiteral) {
				patKey = "n:" + (p.data as NumberLiteralData).value.toString();
			} else if (p.kind === NodeKind.MemberExpr) {
				const pmd = p.data as MemberExprData;
				if (pmd.object !== null && pmd.object.nodeType !== null && pmd.object.nodeType.kind === TypeKind.Enum) {
					patKey = "e:" + pmd.property;
				}
			} else if (p.kind === NodeKind.StringLiteral) {
				patKey = "s:" + (p.data as StringLiteralData).value;
			} else if (p.kind === NodeKind.BooleanLiteral) {
				patKey = "b:" + (p.data as BooleanLiteralData).boolValue.toString();
			}
			if (patKey !== "") {
				for (const s of seen) {
					if (s === patKey) {
						addError(ctx, "Duplicate match pattern", p.location.line, p.location.column);
					}
				}
				seen.push(patKey);
			}
		}
	}
}

// ===== Anonymous Functions =====

export function checkAnonymousFunction(ctx: CheckerContext, name: string, params: string[], paramTypes: string[], body: Node, paramLocs: SourceLocation[], returnTypeAnnotation: string): Type {
	const savedReturn = ctx.inferredReturn;
	ctx.inferredReturn = unknownType();
	const savedMatchDepth = ctx.matchExprDepth;
	ctx.matchExprDepth = 0;

	// Resolve explicit return type annotation (semProcAux parity: annotation takes precedence)
	let explicitReturnType: Type = null as unknown as Type;
	if (returnTypeAnnotation !== "" && returnTypeAnnotation !== "void") {
		explicitReturnType = resolveAnnotation(returnTypeAnnotation, ctx, 0, 0);
	}

	const savedFunction = ctx.currentFunction;
	// Set explicit return type on function symbol BEFORE checking body, so return
	// statements can use it as expectedType (semProcAux parity: annotation propagates)
	const fnSymType = explicitReturnType !== null ? createFunction([], [], explicitReturnType) : unknownType();
	const sym = makeSymbol(name, SymbolKind.Function, fnSymType, false);
	ctx.currentFunction = sym;
	openScope(ctx.table, ScopeKind.Function);
	let pi = 0;
	for (const p of params) {
		let pType = unknownType();
		if (pi < paramTypes.length && paramTypes[pi] !== "") {
			pType = resolveAnnotation(paramTypes[pi], ctx, 0, 0);
		}
		const paramSym = makeSymbol(p, SymbolKind.Parameter, pType, false);
		if (paramLocs !== null && pi < paramLocs.length && paramLocs[pi] !== null) {
			paramSym.location = paramLocs[pi];
		}
		defineSymbol(ctx.table, paramSym);
		if (paramLocs !== null && pi < paramLocs.length && paramLocs[pi] !== null) {
			sgRecordSym(ctx, paramLocs[pi].line, paramLocs[pi].column,
				paramLocs[pi].column + p.length,
				paramSym, pType, SymbolKind.Parameter, p, "", true);
		}
		pi += 1;
	}
	if (body.kind === NodeKind.BlockStmt) {
		callCheckStmt(ctx, body);
	} else {
		checkExpr(ctx, body, explicitReturnType);
		const exprType = body.nodeType;
		if (ctx.inferredReturn.kind === TypeKind.Unknown) {
			ctx.inferredReturn = exprType;
		}
	}
	closeScope(ctx.table);
	ctx.currentFunction = savedFunction;
	ctx.matchExprDepth = savedMatchDepth;

	const inferredRet = ctx.inferredReturn;
	ctx.inferredReturn = savedReturn;

	const types: Type[] = [];
	let ti = 0;
	for (const p of params) {
		let pType = unknownType();
		if (ti < paramTypes.length && paramTypes[ti] !== "") {
			pType = resolveAnnotation(paramTypes[ti], ctx, 0, 0);
		}
		types.push(pType);
		ti += 1;
	}
	// Explicit return type annotation takes precedence over inferred (semProcAux parity).
	// This ensures Result<Node, string> gets concrete types, not GenericParam("T") from
	// inference of Result.err() which can't determine T without context.
	if (explicitReturnType !== null && explicitReturnType.kind !== TypeKind.Unknown) {
		return createFunction(types, params, explicitReturnType);
	}
	if (returnTypeAnnotation === "void") {
		return createFunction(types, params, voidType());
	}
	if (inferredRet.kind !== TypeKind.Unknown) {
		return createFunction(types, params, inferredRet);
	}
	return createFunction(types, params, unknownType());
}

function checkArrowExpr(ctx: CheckerContext, node: Node): Type {
	const d = node.data as ArrowFunctionData;
	resolveTypeExpr(node.typeExpr, ctx);
	resolveTypeExprs(node.typeExprs, ctx);
	return checkAnonymousFunction(ctx, "<arrow>", d.arrowParams, d.arrowParamTypes, d.arrowBody, node.paramLocations, d.arrowReturnType);
}

function checkFuncExpr(ctx: CheckerContext, node: Node): Type {
	const d = node.data as FunctionExprData;
	resolveTypeExpr(node.typeExpr, ctx);
	resolveTypeExprs(node.typeExprs, ctx);
	return checkAnonymousFunction(ctx, "(anon)", d.funcExprParams, d.funcExprParamTypes, d.funcExprBody, node.paramLocations, d.funcExprReturnType);
}

// ===== @emit Backtick Interpolation (reference emit processing parity) =====
// Scans a single string arg for `identifier` patterns, splits into multiple args:
// string literals for raw text, Identifier nodes for resolved symbols.


function processEmitInterpolation(ctx: CheckerContext, md: MacroInvocationData, node: Node): void {
	if (md.macroArgs.length !== 1) return;
	const arg = md.macroArgs[0];

	// Template literal form: @emit(`foo ${bar} baz`) — desugared to BinaryExpr(+) chain
	if (arg.kind === NodeKind.BinaryExpr) {
		const parts = collectConcatParts(arg);
		// Filter empty string literals (from template coercion prefix "" + ...)
		const newArgs: Node[] = [];
		for (const p of parts) {
			if (p.kind === NodeKind.StringLiteral && (p.data as StringLiteralData).value === "") continue;
			newArgs.push(p);
		}
		if (newArgs.length > 0) { md.macroArgs = newArgs; }
		return;
	}

	if (arg.kind !== NodeKind.StringLiteral) return;
	const sd = arg.data as StringLiteralData;
	const str = sd.value;

	// Quick check: any backticks?
	if (findChar(str, "`") < 0) return;

	// Parse backtick-delimited identifiers (reference pattern: `identifier`)
	const newArgs: Node[] = [];
	const line = node.location.line;
	let a = 0;
	while (a < str.byteLength) {
		let b = a;
		// Find next backtick
		while (b < str.byteLength && str.charAt(b) !== "`") {
			b = b + 1;
		}
		// Emit raw text before backtick
		if (b > a) {
			const sub = str.slice(a, b);
			const strNode = createNode(NodeKind.StringLiteral, { value: sub },
				createToken(TokenKind.String, sub, line));
			strNode.nodeType = stringType();
			newArgs.push(strNode);
		}
		if (b >= str.byteLength) break;
		// Find closing backtick
		let c = b + 1;
		while (c < str.byteLength && str.charAt(c) !== "`") {
			c = c + 1;
		}
		if (c >= str.byteLength) {
			// Unterminated backtick — emit identifier text without the backtick (reference: substr(str, b+1))
			const rest = str.slice(b + 1, str.byteLength);
			if (rest.byteLength > 0) {
				const restNode = createNode(NodeKind.StringLiteral, { value: rest },
					createToken(TokenKind.String, rest, line));
				restNode.nodeType = stringType();
				newArgs.push(restNode);
			}
			break;
		}
		// Extract identifier between backticks
		const ident = str.slice(b + 1, c);
		if (ident.length > 0) {
			const sym = lookupSymbol(ctx.table, ident);
			if (sym !== null) {
				const idNode = createNode(NodeKind.Identifier, { name: ident },
					createToken(TokenKind.Ident, ident, line));
				idNode.resolvedSym = sym;
				idNode.nodeType = sym.symbolType;
				newArgs.push(idNode);
			} else {
				// Unknown symbol — keep as string literal (reference behavior)
				const strNode = createNode(NodeKind.StringLiteral, { value: ident },
					createToken(TokenKind.String, ident, line));
				strNode.nodeType = stringType();
				newArgs.push(strNode);
			}
		} else {
			// Empty backticks `` — emit single backtick (reference parity: $marker)
			const btNode = createNode(NodeKind.StringLiteral, { value: "`" },
				createToken(TokenKind.String, "`", line));
			btNode.nodeType = stringType();
			newArgs.push(btNode);
		}
		a = c + 1;
	}
	// Replace macroArgs with the interpolated args
	md.macroArgs = newArgs;
}

// ===== Actor Sendable Checker =====
// Enforces safe data transfer at actor method boundaries.
// Reuses: isPrimitiveKind, isStructType, SymbolFlag.Mutable, NodeKind.MoveExpr.

function isSendable(t: Type, argNode: Node): boolean {
	if (t === null) return true;
	if (isPrimitiveKind(t.kind)) return true;
	if (t.kind === TypeKind.String) return true;
	if (argNode !== null && argNode.kind === NodeKind.MoveExpr) return true;
	if (isStructType(t)) {
		for (const ft of t.typeChildren) {
			if (!isSendable(ft, argNode)) return false;
		}
		return true;
	}
	if (t.kind === TypeKind.Ref) {
		if (argNode !== null && argNode.resolvedSym !== null
			&& !hasFlag(argNode.resolvedSym, SymbolFlag.Mutable)) return true;
		return false;
	}
	if (t.kind === TypeKind.Function) return false;
	return false;
}

function checkActorArgSendable(ctx: CheckerContext, argNode: Node, pi: number): void {
	const t = argNode.nodeType;
	if (t === null) return;
	if (isSendable(t, argNode)) return;
	let argLabel = "arg " + pi.toString();
	if (argNode.kind === NodeKind.Identifier) {
		argLabel = "'" + (argNode.data as IdentifierData).name + "'";
	}
	const typedesc = typeNameOf(t);
	let hint = "";
	if (t.kind === TypeKind.Ref) {
		let varName = "";
		if (argNode.kind === NodeKind.Identifier) { varName = " " + (argNode.data as IdentifierData).name; }
		hint = " — use `move" + varName + "` to transfer ownership";
	} else if (t.kind === TypeKind.Function) {
		hint = " — closures may capture mutable state";
	}
	addError(ctx, "actor methods only accept value types, `move`, or `const` references\n" + typedesc + " " + argLabel + " is a mutable reference" + hint,
		argNode.location.line, argNode.location.column);
}

// ===== Spawn Borrow Checker =====
// Detects mutable variable captures in spawn closures — borrowed captures may dangle.

function walkForMutableCaptures(node: Node, params: string[], reported: string[], ctx: CheckerContext): void {
	if (node === null) return;
	if (node.kind === NodeKind.FunctionDecl || node.kind === NodeKind.FunctionExpr || node.kind === NodeKind.ArrowFunction) return;
	match (node.kind) {
		NodeKind.Identifier => {
			const d = node.data as IdentifierData;
			let skip = false;
			for (const p of params) { if (p === d.name) skip = true; }
			for (const r of reported) { if (r === d.name) skip = true; }
			if (!skip) {
				const sym = lookupSymbol(ctx.table, d.name);
				if (sym !== null && hasFlag(sym, SymbolFlag.Mutable)) {
					addError(ctx, "mutable variable '" + d.name + "' cannot be captured by spawn — use const or move", node.location.line, node.location.column);
					reported.push(d.name);
				}
			}
		},
		NodeKind.BlockStmt => {
			for (const stmt of (node.data as BlockStmtData).statements) {
				walkForMutableCaptures(stmt, params, reported, ctx);
			}
		},
		NodeKind.ExprStmt => { walkForMutableCaptures((node.data as ExprStmtData).expr, params, reported, ctx); },
		NodeKind.ReturnStmt => { walkForMutableCaptures((node.data as ReturnStmtData).argument, params, reported, ctx); },
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			walkForMutableCaptures(d.left, params, reported, ctx);
			walkForMutableCaptures(d.right, params, reported, ctx);
		},
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			walkForMutableCaptures(d.callee, params, reported, ctx);
			for (const arg of d.arguments) { walkForMutableCaptures(arg, params, reported, ctx); }
		},
		NodeKind.MemberExpr => { walkForMutableCaptures((node.data as MemberExprData).object, params, reported, ctx); },
		NodeKind.IfStmt | NodeKind.ConditionalExpr => {
			const d = node.data as IfStmtData;
			walkForMutableCaptures(d.condition, params, reported, ctx);
			walkForMutableCaptures(d.consequent, params, reported, ctx);
			walkForMutableCaptures(d.alternate, params, reported, ctx);
		},
		NodeKind.UnaryExpr => { walkForMutableCaptures((node.data as UnaryExprData).operand, params, reported, ctx); },
		_ => {},
	};
}

function checkSpawnCaptures(ctx: CheckerContext, closureNode: Node, spawnNode: Node): void {
	if (closureNode === null) return;
	let params: string[] = [];
	let body: Node = null;
	if (closureNode.kind === NodeKind.ArrowFunction) {
		const ad = closureNode.data as ArrowFunctionData;
		params = ad.arrowParams;
		body = ad.arrowBody;
	} else if (closureNode.kind === NodeKind.FunctionExpr) {
		const fd = closureNode.data as FunctionExprData;
		params = fd.funcExprParams;
		body = fd.funcExprBody;
	}
	const reported: string[] = [];
	if (body !== null) {
		walkForMutableCaptures(body, params, reported, ctx);
	}
}

// ===== JSON Typed Specialization (reference-aligned: generate + check during sem) =====

import { callCheckFunctionBody } from "./checkerCallbacks";
import { addPendingInstance, instantiateClassConstructor, lookupCtorDefaults } from "./instantiate";
import { getIdentId } from "./idents";

// Shared: register a generated JSON instance (symbol + checker + pending + callee rewrite)
function registerJsonInstance(
	ctx: CheckerContext, helperName: string, params: string[], paramTypes: Type[],
	body: Node, fnReturnType: Type, fnNode: Node, node: Node, d: CallExprData, loc: SourceLocation
): Symbol {
	const syntheticTok = createSyntheticToken(loc);
	const fnType = createFunction(paramTypes, params, fnReturnType);
	const instSym = makeSymbol(helperName, SymbolKind.Function, fnType, false);
	instSym.state = SymbolState.Shaped;
	instSym.modulePath = "";
	instSym.originalName = helperName;
	instSym.nameId = getIdentId(ctx.table.identCache, helperName);
	let rootScope = ctx.table.current;
	while (rootScope.parent !== null) rootScope = rootScope.parent;
	rootScope.symbols.push(instSym);
	fnNode.resolvedSym = instSym;
	fnNode.nodeType = fnType;

	callCheckFunctionBody(ctx, instSym, params, body, null as unknown as SourceLocation[]);
	addPendingInstance(fnNode);

	const callIdent = createNode(NodeKind.Identifier, { name: helperName }, syntheticTok);
	callIdent.resolvedSym = instSym;
	callIdent.nodeType = fnType;
	d.callee = callIdent;
	node.resolvedSym = instSym;
	return instSym;
}

// JSON.parse<Person>(input) → generate __jsonParse_Person, run checker on it, return call
function generateJsonParseInstance(ctx: CheckerContext, node: Node, d: CallExprData, typeArgStr: string, loc: SourceLocation): Type {
	const sym = lookupSymbol(ctx.table, typeArgStr);
	if (sym === null || sym.symbolType === null) return null;
	const structType = unwrapRef(sym.symbolType);
	if (structType.kind !== TypeKind.Struct || structType.typeNames === null || structType.typeChildren === null) return null;

	const isRef = sym.symbolType.kind === TypeKind.Ref;
	const resultOkType = isRef ? sym.symbolType : structType;
	const resultType = createResult(resultOkType, stringType());
	const helperName = "__jsonParse_" + typeArgStr;
	const syntheticTok = createSyntheticToken(loc);

	// Cache check — skip if already generated
	const existing = lookupSymbol(ctx.table, helperName);
	if (existing !== null) {
		const callIdent = createNode(NodeKind.Identifier, { name: helperName }, syntheticTok);
		callIdent.resolvedSym = existing;
		callIdent.nodeType = existing.symbolType;
		d.callee = callIdent;
		node.nodeType = resultType;
		return resultType;
	}

	// Generate function body AST:
	//   const $r = parseJson(input);
	//   if (!$r.ok) { return { ok: false, value: null, error: $r.error }; }
	//   const $v = $r.value;
	//   return { ok: true, value: { name: get($v, "name").strVal, ... }, error: "" };
	const stmts: Node[] = [];

	// const $r = parseJson(input)
	stmts.push(createNode(NodeKind.VariableDecl, {
		declName: "$r", declType: "", initializer: createNode(NodeKind.CallExpr, {
			callee: createNode(NodeKind.Identifier, { name: "parseJson" }, syntheticTok),
			arguments: [createNode(NodeKind.Identifier, { name: "input" }, syntheticTok)],
			isDirectCall: true,
		}, syntheticTok), declKind: DeclKind.Const, nameLocation: loc,
	}, syntheticTok));

	// if (!$r.ok) { return { ok: false, value: null, error: $r.error }; }
	const errObj = createNode(NodeKind.ObjectLiteral, {
		keys: ["ok", "value", "error"],
		properties: [
			createNode(NodeKind.BooleanLiteral, { boolValue: false }, syntheticTok),
			createNode(NodeKind.NullLiteral, {}, syntheticTok),
			createNode(NodeKind.MemberExpr, { object: createNode(NodeKind.Identifier, { name: "$r" }, syntheticTok), property: "error" }, syntheticTok),
		],
		keyLocations: [],
	}, syntheticTok);
	errObj.nodeType = resultType;
	stmts.push(createNode(NodeKind.IfStmt, {
		condition: createNode(NodeKind.UnaryExpr, {
			unaryOp: "!",
			operand: createNode(NodeKind.MemberExpr, { object: createNode(NodeKind.Identifier, { name: "$r" }, syntheticTok), property: "ok" }, syntheticTok),
		}, syntheticTok),
		consequent: createNode(NodeKind.BlockStmt, { statements: [
			createNode(NodeKind.ReturnStmt, { argument: errObj }, syntheticTok),
		] }, syntheticTok),
		alternate: createNode(NodeKind.BlockStmt, { statements: [] }, syntheticTok),
	}, syntheticTok));

	// const $v = $r.value
	stmts.push(createNode(NodeKind.VariableDecl, {
		declName: "$v", declType: "", initializer: createNode(NodeKind.MemberExpr, {
			object: createNode(NodeKind.Identifier, { name: "$r" }, syntheticTok), property: "value",
		}, syntheticTok), declKind: DeclKind.Const, nameLocation: loc,
	}, syntheticTok));

	// Build field extraction: { name: get($v, "name").strVal, age: get($v, "age").numVal }
	const fieldKeys: string[] = [];
	const fieldProps: Node[] = [];
	let fi = 0;
	while (fi < structType.typeNames.length && fi < structType.typeChildren.length) {
		const fname = structType.typeNames[fi];
		const ftype = structType.typeChildren[fi];
		fieldKeys.push(fname);

		// get($v, "fieldName")
		const getCall = createNode(NodeKind.CallExpr, {
			callee: createNode(NodeKind.Identifier, { name: "get" }, syntheticTok),
			arguments: [
				createNode(NodeKind.Identifier, { name: "$v" }, syntheticTok),
				createNode(NodeKind.StringLiteral, { value: fname }, syntheticTok),
			],
			isDirectCall: true,
		}, syntheticTok);

		// .strVal / .numVal / .intVal / .boolVal — match JsonValueData variant fields
		const accessor = match (ftype.kind) {
			TypeKind.String => "strVal",
			TypeKind.Boolean => "boolVal",
			TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64
				| TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Uint64 => "intVal",
			_ => "numVal",
		};
		let fieldVal: Node = createNode(NodeKind.MemberExpr, {
			object: getCall, property: accessor,
		}, syntheticTok);

		// Integer cast: numVal is double → cast to int32/int64/etc.
		if (ftype.kind !== TypeKind.Number && ftype.kind !== TypeKind.Float64 && ftype.kind !== TypeKind.String && ftype.kind !== TypeKind.Boolean) {
			fieldVal = createNode(NodeKind.TypeAssertion, {
				asExpr: fieldVal, asType: typeNameOf(ftype),
			}, syntheticTok);
		}

		fieldProps.push(fieldVal);
		fi = fi + 1;
	}

	// return { ok: true, value: { fields... }, error: "" }
	const resultObj = createNode(NodeKind.ObjectLiteral, {
		keys: ["ok", "value", "error"],
		properties: [
			createNode(NodeKind.BooleanLiteral, { boolValue: true }, syntheticTok),
			createNode(NodeKind.ObjectLiteral, { keys: fieldKeys, properties: fieldProps, keyLocations: [] }, syntheticTok),
			createNode(NodeKind.StringLiteral, { value: "" }, syntheticTok),
		],
		keyLocations: [],
	}, syntheticTok);
	resultObj.nodeType = resultType;
	// Also stamp the inner value object with the target struct type
	resultObj.data.properties[1].nodeType = resultOkType;
	stmts.push(createNode(NodeKind.ReturnStmt, { argument: resultObj }, syntheticTok));

	const body = createNode(NodeKind.BlockStmt, { statements: stmts }, syntheticTok);
	const fnNode = createNode(NodeKind.FunctionDecl, {
		fnName: helperName, params: ["input"], fnParamTypes: ["string"],
		fnBody: body, fnFlags: "", fnReturnType: "",
		fnDefaults: [], nativeName: "", nameLocation: loc,
	}, syntheticTok);

	registerJsonInstance(ctx, helperName, ["input"], [stringType()], body, resultType, fnNode, node, d, loc);
	node.nodeType = resultType;
	return resultType;
}

// JSON.stringify(person) → generate __jsonStringify_Person, run checker on it, return call
function generateJsonStringifyInstance(ctx: CheckerContext, node: Node, d: CallExprData, loc: SourceLocation): Type {
	if (d.arguments.length < 1) return null;
	const argType = d.arguments[0].nodeType;
	if (argType === null) return null;
	const structType = unwrapRef(argType);
	if (structType.kind !== TypeKind.Struct || structType.typeNames === null || structType.typeChildren === null) return null;
	const typeName = structType.typeName;
	if (typeName === "") return null;

	const isRef = argType.kind === TypeKind.Ref;
	const helperName = "__jsonStringify_" + typeName;
	const syntheticTok = createSyntheticToken(loc);

	// Cache check
	const existing = lookupSymbol(ctx.table, helperName);
	if (existing !== null) {
		const callIdent = createNode(NodeKind.Identifier, { name: helperName }, syntheticTok);
		callIdent.resolvedSym = existing;
		callIdent.nodeType = existing.symbolType;
		d.callee = callIdent;
		node.resolvedSym = existing;
		node.nodeType = stringType();
		return stringType();
	}

	// Generate: return stringify(jsonObject(["f1","f2"], [jsonString(value.f1), jsonNumber(value.f2)]))
	const keyNodes: Node[] = [];
	const valNodes: Node[] = [];
	let fi = 0;
	while (fi < structType.typeNames.length && fi < structType.typeChildren.length) {
		const fname = structType.typeNames[fi];
		const ftype = structType.typeChildren[fi];
		keyNodes.push(createNode(NodeKind.StringLiteral, { value: fname }, syntheticTok));

		const fieldAccess = createNode(NodeKind.MemberExpr, {
			object: createNode(NodeKind.Identifier, { name: "value" }, syntheticTok), property: fname,
		}, syntheticTok);

		const wrapper = match (ftype.kind) {
			TypeKind.String => "jsonString",
			TypeKind.Boolean => "jsonBool",
			TypeKind.Number | TypeKind.Float64 | TypeKind.Float32 => "jsonNumber",
			TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64
				| TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Uint64
				| TypeKind.Enum => "jsonInt",
			_ => "jsonNumber",
		};
		valNodes.push(createNode(NodeKind.CallExpr, {
			callee: createNode(NodeKind.Identifier, { name: wrapper }, syntheticTok),
			arguments: [fieldAccess],
			isDirectCall: true,
		}, syntheticTok));
		fi = fi + 1;
	}

	const keysArr = createNode(NodeKind.ArrayLiteral, { elements: keyNodes }, syntheticTok);
	const valsArr = createNode(NodeKind.ArrayLiteral, { elements: valNodes }, syntheticTok);
	const objCall = createNode(NodeKind.CallExpr, {
		callee: createNode(NodeKind.Identifier, { name: "jsonObject" }, syntheticTok),
		arguments: [keysArr, valsArr],
		isDirectCall: true,
	}, syntheticTok);
	const strCall = createNode(NodeKind.CallExpr, {
		callee: createNode(NodeKind.Identifier, { name: "stringify" }, syntheticTok),
		arguments: [objCall, createNode(NodeKind.BooleanLiteral, { boolValue: false }, syntheticTok)],
		isDirectCall: true,
	}, syntheticTok);

	const body = createNode(NodeKind.BlockStmt, { statements: [
		createNode(NodeKind.ReturnStmt, { argument: strCall }, syntheticTok),
	] }, syntheticTok);

	const fnNode = createNode(NodeKind.FunctionDecl, {
		fnName: helperName, params: ["value"], fnParamTypes: [typeName],
		fnBody: body, fnFlags: "", fnReturnType: "string",
		fnDefaults: [], nativeName: "", nameLocation: loc,
	}, syntheticTok);

	const paramType = isRef ? argType : structType;
	registerJsonInstance(ctx, helperName, ["value"], [paramType], body, stringType(), fnNode, node, d, loc);
	node.nodeType = stringType();
	return stringType();
}

function createSyntheticToken(loc: SourceLocation): Token {
	return createToken(TokenKind.Ident, "", loc.line);
}

// Static field lookup — searches class symbol's staticFields
function findStaticField(classSym: Symbol, fieldName: string): Symbol {
	if (classSym === null) return null as unknown as Symbol;
	const qualifiedName = classSym.name + "." + fieldName;
	for (const sf of classSym.staticFields) {
		if (sf.name === qualifiedName) return sf;
	}
	// Walk parent chain for inherited static fields
	let inner = classSym.symbolType;
	if (inner !== null && inner.kind === TypeKind.Ref && inner.typeReturn !== null) inner = inner.typeReturn;
	if (inner !== null && inner.typeExtra !== null && inner.typeExtra.sym !== null) {
		return findStaticField(inner.typeExtra.sym, fieldName);
	}
	return null as unknown as Symbol;
}

// Register callback at module load time
registerCheckExpr((ctx: CheckerContext, node: Node, expectedType: Type): void => { checkExpr(ctx, node, expectedType); });
