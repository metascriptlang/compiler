// Expression Checker — type inference for all expression kinds
// Extracted from checkPass.ms. Uses checkerCallbacks for mutual recursion with checkStmt.

import { Node, NodeKind, NodeData, createNode, NodeFlag, DeclKind, SourceLocation, IdentifierData, BinaryExprData, UnaryExprData, UpdateExprData, NumberLiteralData, CallExprData, MemberExprData, ArrayAccessData, ObjectLiteralData, ArrayLiteralData, ConditionalExprData, TypeAssertionData, SpreadExprData, NewExprData, TryExprData, AwaitExprData, YieldExprData, MoveExprData, OutExprData, SizeofExprData, HiddenDerefData, HiddenStdConvData, MacroInvocationData, StringLiteralData, ArrowFunctionData, FunctionExprData, MatchCaseData, MatchExprData, FunctionDeclData, ClassDeclData, ActorDeclData, PropertyDeclData, DecoratedDeclData, BlockStmtData, ExprStmtData, ReturnStmtData, IfStmtData, Type, TypeKind, CallingConvention, Symbol, SymbolKind, SymbolState, BooleanLiteralData, collectConcatParts } from "../ast/node";
import { TokenKind, Token, createToken } from "../lexer/token";
import { unknownType, numberType, int32Type, float64Type, isFloatType, stringType, booleanType, charType, voidType, nullType, errorType, createArray, createRef, createSpan, createFunction, createTypeRef, createStruct, createResult, createPrimitive, substituteType, instantiateGeneric, createGenericInstance, anonStructName, isNumeric, isIntegerType, getReturnType, getElementType, getProperty, sizeOfType, typeNameOf, isIndexableMapType, unwrapRef, unwrapRefNullUnion, isDiscriminatedUnion, findVariantByDiscriminant, findVariantByStringDiscriminant, findSharedStringDiscriminant, detectUnionDiscriminant, collectStringDiscriminantValues, findFieldInVariant, findUnionVariant, isAmbiguousVariant, unifyType, createUnifyBindings, UnifyBindings, hasGenericParams, getMinArity, setMinArity, isNarrowingIntConv, integerRank, skipModifier, createPromise, createSpawnHandle, isAwaitable, isAffineAwaitable, awaitedType, isResult, getResultOkType, createGenericParam, instantiateGenericBody, isStringLike, isPrimitiveKind, isStructType, createEnumLiteral, typeDisplayName, booleanLiteralValue, peelToStructOrUnion } from "./types";
import { ScopeKind, SymbolFlag, defineSymbol, lookupSymbol, makeSymbol, makeSymbolState, openScope, closeScope, addSymbolToScope, hasOverloads, hasFlag, setFlag, markUsed, markConsumed } from "./symbol";
import { CheckerContext, ExportedSymInfo, addError, addErrorRange, addWarning, findAllExtensionsByName, ExtensionMethod, isCancelled, filterExtsByReceiverType, findFirstMatchingExt, getExtFnType, stripReceiverParam, sgRecordSym, findExportedSymbol, extractGenericNames } from "./context";
import {
	isAssignable, needsStdConv, findFirstMismatch,
	scoreCandidatePriority, scoreCandidateWithSkip, isNoMatch, emptyCandidateScore, cmpCandidates,
	CandidateScore,
} from "./compat";
import { callCheckStmt, registerCheckExpr } from "./checkerCallbacks";
import { resolveAnnotation, resolveTypeExpr, resolveTypeExprs, ensureShaped, recordGenericTypeInstantiation } from "./resolvePass";
import { mangleMonoName } from "../monomorphize/registry";
import { cloneNodeForCheck } from "../monomorphize/clone";
import { expandMacroInvocation } from "../compiler/meta/expand";
import { findChar, splitTopLevel } from "../utils/string";
import { findCallTypeArg, getExplicitTypeArg, getGenericDecl } from "../parser/context";
import { markConsumedName, isConsumedName, symbolConsumeKey } from "./spawnAffinity";
import {
	markInitialized, isInitialized, getDeclBlock,
	saveInitState, restoreInitState, collectNewInits, mergeInitBranches, breaksBlock, BreakState,
} from "./initTracker";
import { callInstantiateGeneric } from "./checkerCallbacks";
import { getFlowTypeOfReference, isDefinitelyNonNullAt } from "./flow";
import { isContextSensitive } from "./speculate";
import { isTemplateSym, expandTemplate } from "./template";

// Extension receiver matching functions imported from context.ms (shared with LSP)

// Phase 4: invalidateFacts / factReferencesVar deleted.
// Assignments that invalidate narrowing now flow through the binder's
// FlowAssignment node + getFlowTypeOfReference. Per-use-site queries see
// the post-assignment flow state naturally — no fact stack to purge.

// ===== Generic NewExpr Resolution =====
// Resolves `new Box<number>(42)` — captures type args from side-channel,
// records instantiation, and builds concrete Ref<Struct> type.
// Parity: standard reference object construction → type node captures type args.
function resolveGenericNewExpr(ctx: CheckerContext, callee: Node, calleeType: Type, astTypeArg: string): Type {
	if (callee.kind !== NodeKind.Identifier) return calleeType;
	const calleeName = (callee.data as IdentifierData).name;
	const ltCol = callee.location.column + calleeName.length;
	// Prefer the AST-resident typeArg (survives clone + substitution) over the
	// location-keyed side channel (stale for cloned generic bodies because the
	// cloned source location still points at the original "K, V" strings).
	let typeArgStr = astTypeArg;
	if (typeArgStr === "") {
		typeArgStr = getExplicitTypeArg(callee.location.line, ltCol);
	}
	if (typeArgStr === "") return calleeType;
	const genericParams = getGenericDecl(calleeName);
	if (genericParams === "") return calleeType;
	const args = splitTopLevel(typeArgStr, ",");
	recordGenericTypeInstantiation(calleeName, genericParams, args, ctx);
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
	// Build GenericInstance — same structure as type annotation path in resolvePass.
	// Avoids instantiateGeneric which creates shared type references that cause DRC
	// use-after-free when the original base type is freed (substituteType shallow copies).
	const isRefBase = baseSym.symbolType.kind === TypeKind.Ref;
	let baseType = baseSym.symbolType;
	if (isRefBase && baseType.typeReturn !== null) baseType = baseType.typeReturn;
	const instType = createGenericInstance(baseType, concreteTypes);
	instantiateGenericBody(instType, genericParams);
	// On-demand constructor instantiation: if class has constructor, generate ClassName_new()
	if (hasFlag(baseSym, SymbolFlag.HasConstructor)) {
		instantiateClassConstructor(baseSym, trimmedParamNames, concreteTypes, ctx);
	}
	return isRefBase ? createRef(instType) : instType;
}

// Resolve the defining module info for a type by name.
// Tries scope lookup first, then searches the export registry.
// Returns a symbol with modulePath + location, or null if not found.
function resolveContainerModule(ctx: CheckerContext, typeName: string): Symbol | null {
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
export function checkExpr(ctx: CheckerContext, node: Node, expectedType: Type | null): void {
	if (node === null) return;
	if ((node.flags & NodeFlag.Sem) !== 0 && node.nodeType !== null) return;
	if (isCancelled(ctx.cancelCtx, ctx.cancelVersion)) { node.nodeType = unknownType(); return; }
	node.nodeType = checkExprInner(ctx, node, expectedType);
	node.flags = node.flags | NodeFlag.Sem;
}

// Internal: compute type for node. All match arms and sub-functions return Type.
function checkExprInner(ctx: CheckerContext, node: Node, expectedType: Type | null): Type {
	const result = match (node.kind) {
		NodeKind.NumberLiteral => {
			if (expectedType !== null && isIntegerType(expectedType)) {
				if (literalFitsInType(node, expectedType)) {
					return expectedType;
				} else if (isNodeIntLit(node)) {
					// Reference parity: standard reference's type change diagnostic emits compile-time error for out-of-range literals
					const v = (node.data as NumberLiteralData).value;
					addError(ctx, "cannot convert " + v + " to " + typeDisplayName(expectedType), node.location.line, node.location.column);
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
						addError(ctx, `Type '"${sd.value}"' is not assignable to type '${typeDisplayName(expectedType)}'`, node.location.line, node.location.column);
						return stringType();
					}
				}
			}
			return stringType();
		},
		NodeKind.BooleanLiteral => {
			// TypeScript parity: boolean literals get BooleanLiteral type when expectedType demands it.
			// Required for discriminated union narrowing on `ok: true | false` discriminants.
			if (expectedType !== null) {
				const bd = node.data as BooleanLiteralData;
				if (expectedType.kind === TypeKind.BooleanLiteral
					&& booleanLiteralValue(expectedType) === bd.boolValue) {
					return expectedType;
				}
				if (expectedType.kind === TypeKind.Union) {
					for (const child of expectedType.typeChildren) {
						if (child !== null && child.kind === TypeKind.BooleanLiteral
							&& booleanLiteralValue(child) === bd.boolValue) {
							return child;
						}
					}
				}
			}
			return booleanType();
		},
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
			// PARALOCK Phase 1 R2/E3: affine-Promise bindings are single-use.
			// Reuse check is keyed by symbolConsumeKey (name + declaration site) so
			// shadowed bindings don't false-positive. First-await is OK because the
			// AwaitExpr handler marks the key AFTER its inner checkExpr returns.
			if (sym.symbolType !== null && isAffineAwaitable(sym.symbolType)
				&& isConsumedName(ctx.affineTracker, symbolConsumeKey(sym))
				&& ctx.initTracker.leftPartOfAsgn <= 0) {
				addError(ctx,
					"affine Promise '" + d.name + "' has already been awaited and cannot be reused (PARALOCK R2/E3)",
					node.location.line, node.location.column);
			}
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
			// Phase 4: narrow via the flow graph per use site. For identifiers
			// with no flowNode (non-reference positions) this is a no-op;
			// otherwise it walks back through TrueCondition/FalseCondition
			// edges to compute the refined type at this program point.
			return getFlowTypeOfReference(node, sym.symbolType);
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
			// Block assignment to read-only properties
			if (isAsgn && d.left.kind === NodeKind.MemberExpr) {
				const md = d.left.data as MemberExprData;
				// Check readonly fields: user-declared `readonly` properties + actor `pid`
				if (md.object.nodeType !== null) {
					let ownerType = md.object.nodeType;
					if (ownerType.kind === TypeKind.Ref && ownerType.typeReturn !== null) ownerType = ownerType.typeReturn;
					if (ownerType.sym !== null) {
						// Actor pid is always readonly (synthetic, not in source body)
						if (ownerType.sym.symbolKind === SymbolKind.Actor && md.property === "pid") {
							addError(ctx, `cannot assign to 'pid' because it is a read-only property`,
								d.left.location.line, d.left.location.column);
						}
						// User-declared readonly fields
						if (ownerType.sym.declNode !== null) {
							let bodyMembers: Node[] = null as unknown as Node[];
							if (ownerType.sym.declNode.kind === NodeKind.ClassDecl) {
								bodyMembers = (ownerType.sym.declNode.data as ClassDeclData).classBody;
							} else if (ownerType.sym.declNode.kind === NodeKind.ActorDecl) {
								bodyMembers = (ownerType.sym.declNode.data as ActorDeclData).actorBody;
							}
							if (bodyMembers !== null) {
								for (const m of bodyMembers) {
									let prop = m;
									if (prop.kind === NodeKind.DecoratedDecl) {
										const dd = prop.data as DecoratedDeclData;
										if (dd.decoratedNode !== null) prop = dd.decoratedNode;
									}
									if (prop.kind === NodeKind.PropertyDecl) {
										const pd = prop.data as PropertyDeclData;
										if (pd.propName === md.property && pd.propIsReadonly === true) {
											addError(ctx, `cannot assign to '${md.property}' because it is a read-only property`,
												d.left.location.line, d.left.location.column);
										}
									}
								}
							}
						}
					}
				}
				// Built-in readonly: str.length, sized-array.length
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
			// HashMap<K,V> subscript write: `m[k] = v` → `m.set(k, v)`. Mutate the
			// whole BinaryExpr into a method call so the existing extension
			// resolution + lowering path handles it. Counterpart of the read-case
			// mutation in the ArrayAccess arm above.
			if (d.operator === "=" && d.left.kind === NodeKind.ArrayAccess) {
				const ad = d.left.data as ArrayAccessData;
				let setObjType = ad.array.nodeType;
				if (setObjType !== null && setObjType.kind === TypeKind.Ref && setObjType.typeReturn !== null) {
					setObjType = setObjType.typeReturn;
				}
				if (setObjType !== null && setObjType.kind === TypeKind.GenericInstance
					&& isIndexableMapType(setObjType)) {
					const wloc = node.location;
					const wtok = createToken(TokenKind.Ident, "", wloc.line);
					const wmember: MemberExprData = { object: ad.array, property: "set", isOptional: false };
					const wmemberNode = createNode(NodeKind.MemberExpr, wmember, wtok);
					const wargs: Node[] = [];
					wargs.push(ad.index);
					wargs.push(d.right);
					// Mutate in place. Assign literal directly to node.data: NodeData (the
					// union type) — a typed intermediate like `const x: CallExprData = ...`
					// confuses C codegen into typing the local as the variant struct, which
					// then fails the union assignment.
					node.kind = NodeKind.CallExpr;
					node.data = {
						callee: wmemberNode,
						arguments: wargs,
						isDirectCall: true,
						resolvedOverloadIdx: -1,
					};
					node.flags = node.flags & ~NodeFlag.Sem;
					node.nodeType = null;
					return checkCallExpr(ctx, node, null);
				}
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
				// Phase 4: reassignment invalidation now flows through the
				// binder's FlowAssignment node — no fact stack to purge.
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
					const name = operandType !== null ? typeDisplayName(operandType) : "unknown";
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
		NodeKind.MemberExpr => checkMemberExpr(ctx, node, expectedType),
		NodeKind.ArrayAccess => {
			const d = node.data as ArrayAccessData;
			checkExpr(ctx, d.array, null);
			const arrType = d.array.nodeType;
			checkExpr(ctx, d.index, null);
			// HashMap<K,V> subscript: mutate `m[k]` into the method-call form `m.get(k)`
			// so the existing extension resolution (checkMemberExpr → checkCallExpr)
			// sets up NodeFlag.ExtCall + resolvedSym, and extensionMethodLower later
			// rewrites it to the flat UFCS form. This makes `{ [key: K]: V }` and
			// HashMap<K,V> subscripts work transparently at runtime.
			//
			// Only handles READ here. Write case (`m[k] = v`) is handled in the
			// BinaryExpr assignment check — see below — because we need to know if
			// the ArrayAccess is on the LHS of an assignment to emit `.set` instead
			// of `.get`. The leftPartOfAsgn counter tells us that.
			let mapObjType = arrType;
			if (mapObjType !== null && mapObjType.kind === TypeKind.Ref && mapObjType.typeReturn !== null) {
				mapObjType = mapObjType.typeReturn;
			}
			if (mapObjType !== null && mapObjType.kind === TypeKind.GenericInstance
				&& isIndexableMapType(mapObjType)
				&& ctx.initTracker.leftPartOfAsgn === 0) {
				const loc = node.location;
				const memberTok = createToken(TokenKind.Ident, "", loc.line);
				const memberData: MemberExprData = { object: d.array, property: "get", isOptional: false };
				const memberNode = createNode(NodeKind.MemberExpr, memberData, memberTok);
				const callArgs: Node[] = [];
				callArgs.push(d.index);
				// Mutate in place — same node identity, different kind.
				// Assign literal directly to node.data: NodeData (union) — typed
				// intermediate confuses codegen variant handling.
				node.kind = NodeKind.CallExpr;
				node.data = {
					callee: memberNode,
					arguments: callArgs,
					isDirectCall: true,
					resolvedOverloadIdx: -1,
				};
				node.flags = node.flags & ~NodeFlag.Sem;
				node.nodeType = null;
				return checkCallExpr(ctx, node, null);
			}
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
			// Union(Ref<T>, Null) — pick the Ref member for context propagation.
			// Source-level nullable type is preserved on node.nodeType below; this
			// only affects how field-types flow into the literal's properties.
			if (objExpected !== null) {
				const refMember = unwrapRefNullUnion(objExpected);
				if (refMember !== null) objExpected = refMember;
			}
			// Unwrap Ref for class types — ObjectLiteral constructs the inner struct
			if (objExpected !== null && objExpected.kind === TypeKind.Ref && objExpected.typeReturn !== null) {
				objExpected = objExpected.typeReturn;
			}
			// Map<K,V> literal (the insertion-ordered one — matches JS object literal
			// key order): `{ "foo": 1 }` assigned to an ordered Map target is rewritten
			// in-place to `mapFromPairs<K,V>([keys], [values])` — a call to a std
			// helper that constructs a populated Map. The rewrite happens DURING
			// checking so monomorphization (which runs after checking) sees the
			// call with typed arguments and properly specializes it.
			//
			// This covers both `Map<K,V>` and `{ [key: K]: V }` — the index signature
			// is normalized to Map<K,V> during resolveAnnotation. Also supports an
			// explicit `HashMap<K,V>` target: the object literal provides keys/values
			// in declared order; HashMap simply drops the ordering guarantee. The
			// only difference is which builder we emit (mapFromPairs vs hashMapFromPairs).
			if (objExpected !== null && objExpected.kind === TypeKind.GenericInstance
				&& isIndexableMapType(objExpected)
				&& objExpected.typeChildren !== null && objExpected.typeChildren.length === 2) {
				const mapKeyType = objExpected.typeChildren[0];
				const mapValType = objExpected.typeChildren[1];
				// 1. Validate every value against V and emit errors on mismatch.
				let mli = 0;
				while (mli < d.properties.length) {
					checkExpr(ctx, d.properties[mli], mapValType);
					const vt = d.properties[mli].nodeType;
					if (vt !== null && mapValType !== null && !isAssignable(vt, mapValType)) {
						const keyName = mli < d.keys.length ? d.keys[mli] : "";
						addError(ctx, "Map value for key '" + keyName + "' has type that is not assignable to V", node.location.line, node.location.column);
					}
					mli = mli + 1;
				}
				// 2. Build keys array — StringLiterals stamped with K.
				const mtok = createToken(TokenKind.Ident, "", node.location.line);
				const keyNodes: Node[] = [];
				let ki = 0;
				while (ki < d.keys.length) {
					const kNode = createNode(NodeKind.StringLiteral, { value: d.keys[ki] }, mtok);
					kNode.nodeType = mapKeyType;
					kNode.flags = kNode.flags | NodeFlag.Sem;
					keyNodes.push(kNode);
					ki = ki + 1;
				}
				const keysArr = createNode(NodeKind.ArrayLiteral, { elements: keyNodes }, mtok);
				keysArr.nodeType = createArray(mapKeyType);
				keysArr.flags = keysArr.flags | NodeFlag.Sem;
				// 3. Build values array — reuse the already-checked property nodes.
				const valNodes: Node[] = [];
				let vi = 0;
				while (vi < d.properties.length) {
					valNodes.push(d.properties[vi]);
					vi = vi + 1;
				}
				const valsArr = createNode(NodeKind.ArrayLiteral, { elements: valNodes }, mtok);
				valsArr.nodeType = createArray(mapValType);
				valsArr.flags = valsArr.flags | NodeFlag.Sem;
				// 4. Build the builder callee (mapFromPairs for ordered Map,
				// hashMapFromPairs for HashMap) + mutate this node into the call.
				const builderName = objExpected.typeName === "HashMap" ? "hashMapFromPairs" : "mapFromPairs";
				const calleeIdent = createNode(NodeKind.Identifier, { name: builderName }, mtok);
				const mCallArgs: Node[] = [];
				mCallArgs.push(keysArr);
				mCallArgs.push(valsArr);
				// Assign literal directly to node.data: NodeData (union) — typed
				// intermediate confuses codegen variant handling.
				node.kind = NodeKind.CallExpr;
				node.data = {
					callee: calleeIdent,
					arguments: mCallArgs,
					isDirectCall: true,
					resolvedOverloadIdx: -1,
				};
				node.flags = node.flags & ~NodeFlag.Sem;
				node.nodeType = null;
				// 5. Re-check as a call. Generic inference on mapFromPairs<K,V>
				// binds K and V from the typed array arguments, and the #29 fix
				// ensures the internal m.set(...) calls get monomorphized.
				return checkCallExpr(ctx, node, objExpected);
			}
			// Unwrap GenericInstance (e.g., Result<T, E>) to inner Struct or Union.
			// Walk through typeReturn (eagerly instantiated body) or typeExtra
			// (unsubstituted base) until we reach a Struct or Union. Handle nested
			// GenericInstance (e.g., MyResult<T, E> = Ref<MyData<T, E>> where MyData
			// is itself generic) by recursing through GI/Ref wrappers.
			objExpected = peelToStructOrUnion(objExpected);
			if (objExpected !== null && objExpected.kind === TypeKind.Struct
				&& objExpected.typeChildren !== null) {
				// Reference parity: stamp literal with expected type, propagate field types
				// For class types, keep Ref wrapper so codegen knows to heap-allocate.
				// Skip ownership modifiers (Sink/Lent/Var) — transparent for codegen.
				const stampType = skipModifier(expectedType);
				node.nodeType = (stampType !== null) ? stampType : objExpected;
				// Pin to consts so the inner while-loop body sees non-null typeNames/
				// typeChildren — flow narrowing on `let objExpected` doesn't reach
				// inside nested loops via the binder's current narrowing rules.
				const objE = objExpected;
				const objNames = objE.typeNames;
				const objChildren = objE.typeChildren;
				const containerName = objE.typeName !== null ? objE.typeName : "";
				let fi = 0;
				while (fi < d.properties.length) {
					// Name-based field lookup: match literal key against struct typeNames
					let fieldExpected: Type | null = null;
					const keyName = fi < d.keys.length ? d.keys[fi] : "";
					if (keyName !== "" && keyName !== "..." && keyName !== "__computed__"
						&& objNames !== null) {
						let ni = 0;
						while (ni < objNames.length) {
							if (objNames[ni] === keyName) {
								if (ni < objChildren.length) {
									fieldExpected = objChildren[ni];
								}
								break;
							}
							ni = ni + 1;
						}
					}
					// Fallback: positional match for spread/computed keys
					if (fieldExpected === null && (keyName === "..." || keyName === "__computed__")
						&& fi < objChildren.length) {
						fieldExpected = objChildren[fi];
					}
					checkExpr(ctx, d.properties[fi], fieldExpected);
					// Auto-wrap directFn → closure when field type is closure (Reference parity)
					if (fieldExpected !== null) {
						d.properties[fi] = fitNode(ctx, d.properties[fi], fieldExpected, d.properties[fi].nodeType);
					}
					// Validate field type assignability against expected struct field type.
					// checkExpr propagates expectedType for inference but doesn't enforce assignability.
					const propActual = d.properties[fi].nodeType;
					const fe = fieldExpected;
					if (fe !== null && propActual !== null) {
						if (fe.kind !== TypeKind.Unknown
								&& propActual.kind !== TypeKind.Unknown
								&& propActual.kind !== TypeKind.Error
								&& !(typeNameOf(propActual) !== "" && typeNameOf(propActual) === typeNameOf(fe))
								&& !isAssignable(propActual, fe)) {
							const propTypeName = typeDisplayName(d.properties[fi].nodeType);
							const expectedTypeName = typeDisplayName(fieldExpected);
							if (d.keyLocations !== null && fi < d.keyLocations.length) {
								const kl = d.keyLocations[fi];
								addErrorRange(ctx, `Type '${propTypeName}' is not assignable to type '${expectedTypeName}' for field '${keyName}'`, kl.line, kl.column, kl.column + keyName.length);
							} else {
								addError(ctx, `Type '${propTypeName}' is not assignable to type '${expectedTypeName}' for field '${keyName}'`, node.location.line, node.location.column);
							}
						}
					}
					// Record property key as reference to struct field
					if (fi < d.keys.length && d.keyLocations !== null && fi < d.keyLocations.length && fieldExpected !== null) {
						const keyLoc = d.keyLocations[fi];
						if (keyName !== "..." && keyName !== "__computed__" && keyLoc.line > 0) {
							let fieldSym: Symbol | null = null;
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
				if (objNames !== null) {
					let ki = 0;
					while (ki < d.keys.length) {
						const key = d.keys[ki];
						if (key !== "..." && key !== "__computed__") {
							// Check field exists in type
							let found = false;
							let ni = 0;
							while (ni < objNames.length) {
								if (objNames[ni] === key) { found = true; break; }
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
				return checkDiscriminatedConstruction(ctx, node, d, objExpected, expectedType);
			} else if (objExpected !== null && objExpected.kind === TypeKind.Union) {
				// Non-discriminated union: resolve variant, propagate field types.
				// Reference parity: sem resolves fields then calls fitNode(field.typ, value)
				// once per field. One pass, known types.
				node.nodeType = objExpected;

				// Tier 2: string-literal discriminant narrowing.
				// When every variant is a struct with a shared field whose type is StringLiteral
				// (the TypeScript pattern: type Shape = {kind:"a",...} | {kind:"b",...}),
				// find the shared field, read the literal value from the object literal, and
				// pick the variant that way. This catches wrong-field-in-variant bugs that
				// pure name-based findUnionVariant misses.
				let varIdx = -1;
				const stringDiscName = findSharedStringDiscriminant(objExpected);
				if (stringDiscName !== "") {
					// Look for the discriminant field in the literal
					let litDiscIdx = -1;
					for (let ki = 0; ki < d.keys.length; ki += 1) {
						if (d.keys[ki] === stringDiscName) { litDiscIdx = ki; break; }
					}
					if (litDiscIdx >= 0 && litDiscIdx < d.properties.length) {
						const discProp = d.properties[litDiscIdx];
						if (discProp.kind === NodeKind.StringLiteral) {
							const sd = discProp.data as StringLiteralData;
							varIdx = findVariantByStringDiscriminant(objExpected, stringDiscName, sd.value);
							if (varIdx < 0) {
								addError(ctx, `No variant of union has ${stringDiscName} = "${sd.value}"`,
									node.location.line, node.location.column);
							}
						}
					} else {
						addError(ctx, `Object literal missing discriminant field '${stringDiscName}' for union`,
							node.location.line, node.location.column);
					}
				}
				// Fallback: name-only matching (legacy path for non-string-discriminant unions)
				if (varIdx < 0 && stringDiscName === "") {
					varIdx = (d.keys.length > 0)
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
				}
				// Single pass: check properties WITH variant field types as expectedType
				// (reference: fitNode(field.typ, value) — proper literal coercion).
				// Under Tier 2 string-discriminant mode, also report fields missing from the
				// chosen variant as errors (caller asked for a specific variant, extra fields
				// are wrong).
				const variant = (varIdx >= 0 && objExpected.typeChildren !== null
					&& varIdx < objExpected.typeChildren.length)
					? objExpected.typeChildren[varIdx]
					: null;
				for (let fi = 0; fi < d.properties.length; fi += 1) {
					const key = fi < d.keys.length ? d.keys[fi] : "";
					const fieldExpected = (variant !== null && key !== "")
						? findFieldInVariant(variant, key)
						: null;
					checkExpr(ctx, d.properties[fi], fieldExpected);
					if (stringDiscName !== "" && variant !== null && key !== "" && key !== stringDiscName && fieldExpected === null) {
						// Resolved to a specific variant via string discriminant, but this field
						// doesn't belong to it — report.
						addError(ctx, `Field '${key}' does not exist on the ${stringDiscName}-matched variant`,
							node.location.line, node.location.column);
					}
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
				let elemType = d.elements[0].nodeType;
				let i = 1;
				while (i < d.elements.length) { checkExpr(ctx, d.elements[i], elemExpected); i += 1; }
				// PARALOCK: an array literal with affine-Promise identifier elements
				// consumes those handles — the array is the new owner (typically
				// passed to Promise.all or similar homogeneous consumer). The individual
				// handles cannot be awaited again because the array itself will be.
				// This covers the `await Promise.all([h1, h2])` pattern.
				let ei = 0;
				while (ei < d.elements.length) {
					const el = d.elements[ei];
					const elType = el.nodeType;
					if (elType !== null && isAffineAwaitable(elType) && el.kind === NodeKind.Identifier) {
						const elSym = el.resolvedSym;
						if (elSym !== null) {
							markConsumedName(ctx.affineTracker, symbolConsumeKey(elSym));
							markConsumed(elSym);
						}
					}
					ei = ei + 1;
				}
				// PARALOCK §5.4 — mixed awaitable elements: if the first element is an
				// affine Promise (from spawn) but any other element is a plain Promise
				// (from async function, actor CALL, etc.), unify the element type to the
				// plain Promise — strip affine flags via implicit upcast. Without this,
				// downstream lowering treats the array as affine-homogeneous and
				// misinterprets the plain-Promise element (runtime misaligned-address
				// crash observed in `[spawn(f), fetchData()]`). Only applies when no
				// contextual element type is forcing a specific shape.
				if (elemExpected === null && elemType !== null && isAwaitable(elemType)) {
					const inner0 = awaitedType(elemType);
					let hasAffine = isAffineAwaitable(elemType);
					let hasPlain = isAwaitable(elemType) && !hasAffine;
					let ej = 1;
					while (ej < d.elements.length) {
						const ejType = d.elements[ej].nodeType;
						if (ejType !== null && isAwaitable(ejType)) {
							if (isAffineAwaitable(ejType)) hasAffine = true;
							else hasPlain = true;
						}
						ej = ej + 1;
					}
					if (hasAffine && hasPlain && inner0 !== null) {
						elemType = createPromise(inner0);
						addWarning(ctx,
							"affine Promise flags stripped in mixed array — affine tracking dropped (PARALOCK §5.4)",
							node.location.line, node.location.column);
					}
				}
				// Reference parity (semArrayConstr): error only on too-many elements.
				// Too-few is allowed at literal level; type compatibility catches mismatches.
				if (arrExpected !== null && arrExpected.kind === TypeKind.SizedArray) {
					const expectedLen = arrExpected.typeFlags;
					if (d.elements.length > expectedLen) {
						addError(ctx, `Fixed-size array expects at most ${expectedLen} element(s), got ${d.elements.length}`, node.location.line, node.location.column);
					}
					return arrExpected;
				} else if (arrExpected !== null && arrExpected.kind === TypeKind.Array && !hasGenericParams(arrExpected)) {
					return arrExpected;
				} else {
					return createArray(elemType);
				}
			}
		},
		NodeKind.ArrowFunction => checkArrowExpr(ctx, node, expectedType),
		NodeKind.FunctionExpr => checkFuncExpr(ctx, node, expectedType),
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
			const asLoc = node.typeExpr !== null ? node.typeExpr.location : node.location;
			const targetType = (d.asType !== "") ? resolveAnnotation(d.asType, ctx, asLoc.line, asLoc.column) : unknownType();
			// TS parity: `expr as T` propagates T as contextual type to expr.
			// Critical for object literals: `{ a: 1 } as Foo` must construct a Foo
			// (not an anonymous struct that codegen then can't cast to Foo).
			// `as unknown` is a type-system escape hatch — don't use it as context.
			const innerExpected = (targetType.kind !== TypeKind.Unknown) ? targetType : null;
			checkExpr(ctx, d.asExpr, innerExpected);
			let srcType = d.asExpr.nodeType;
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
			if (argType !== null && isAwaitable(argType)) {
				const promiseInner = awaitedType(argType);
				node.nodeType = promiseInner !== null ? promiseInner : unknownType();
				// PARALOCK Phase 1: consuming an affine-awaitable identifier records on
				// TWO channels:
				//   1. Branch-aware tracker (markConsumedName) — drives reuse detection
				//      (R2/E3) path-sensitively, so `if { await h; return; } await h`
				//      correctly sees h as free on the fall-through path.
				//   2. Monotonic symbol flag (markConsumed) — ensures scope-exit check
				//      passes for handles consumed on any branch, including exiting
				//      branches whose tracker state gets rolled back by the merge.
				if (isAffineAwaitable(argType) && d.awaitArg.kind === NodeKind.Identifier) {
					const idSym = d.awaitArg.resolvedSym;
					if (idSym !== null) {
						markConsumedName(ctx.affineTracker, symbolConsumeKey(idSym));
						markConsumed(idSym);
					}
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
			checkExpr(ctx, d.moveArg, null);
			// PARALOCK Phase 1: `move h` on an affine Promise counts as consumption.
			// Ownership transfers out of the current scope, so the binding must
			// not be awaited again — same consumption semantics as `await h`.
			const moveArgType = d.moveArg.nodeType;
			if (moveArgType !== null && isAffineAwaitable(moveArgType) && d.moveArg.kind === NodeKind.Identifier) {
				const idSym = d.moveArg.resolvedSym;
				if (idSym !== null) {
					markConsumedName(ctx.affineTracker, symbolConsumeKey(idSym));
					markConsumed(idSym);
				}
			}
			return d.moveArg.nodeType;
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
		"===" | "!==" | "==" | "!=" | "<" | ">" | "<=" | ">=" | "instanceof" | "in" => booleanType(),
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
	// number → warn (TypeScript users), allow with implicit int32 cast.
	// Combined into a single emit so `n1 | n2` (both number) doesn't fire twice
	// — the message refers to the operator, not which operand is numeric.
	if (leftNum || rightNum) {
		addWarning(ctx, "bitwise operator '" + op + "' on 'number' implicitly casts to int32; prefer explicit integer type", node.location.line, node.location.column);
	}
	// Reject non-integer, non-number, non-enum types (string, boolean, etc.)
	if (!leftInt && !leftNum) {
		const name = leftType !== null ? typeDisplayName(leftType) : "unknown";
		addError(ctx, "bitwise operator '" + op + "' requires integer type, got '" + name + "'", node.location.line, node.location.column);
	}
	if (!rightInt && !rightNum) {
		const name = rightType !== null ? typeDisplayName(rightType) : "unknown";
		addError(ctx, "bitwise operator '" + op + "' requires integer type, got '" + name + "'", node.location.line, node.location.column);
	}
	// Reference parity: both operands must be the same integer size (skip if either is number/enum)
	if (leftInt && rightInt && isIntegerType(leftType) && isIntegerType(rightType) && leftType.kind !== rightType.kind) {
		addError(ctx, "bitwise operator '" + op + "' requires same integer size, got '" + typeDisplayName(leftType) + "' and '" + typeDisplayName(rightType) + "'", node.location.line, node.location.column);
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

export function fitNode(ctx: CheckerContext, expr: Node, formal: Type | null, exprType: Type | null): Node {
	if (formal === null || exprType === null) return expr;
	if (formal.kind === TypeKind.Unknown || exprType.kind === TypeKind.Unknown) return expr;
	// Direct function → closure auto-wrap (Reference parity: nkHiddenSubConv → nkClosure).
	// When a named function (CcDefault) flows into a closure-typed slot (CcClosure),
	// wrap as `{fn: expr, env: null}` ObjectLiteral with NodeFlag.Closure.
	// Catches: var init, return, object field with closure type — `closureCallMarker.ms`
	// already handles the call-arg case via wrapFuncArgsAsThunks.
	if (formal.kind === TypeKind.Function && exprType.kind === TypeKind.Function
		&& formal.callConv === CallingConvention.CcClosure
		&& exprType.callConv !== CallingConvention.CcClosure
		&& expr.kind === NodeKind.Identifier
		&& expr.resolvedSym !== null
		&& expr.resolvedSym.symbolKind === SymbolKind.Function) {
		const wrapTok = createToken(TokenKind.Ident, "", expr.location.line);
		const nullNode = createNode(NodeKind.NullLiteral, { nullPlaceholder: true } as NodeData, wrapTok);
		nullNode.nodeType = nullType();
		nullNode.flags = nullNode.flags | NodeFlag.Sem;
		const wrapped = createNode(NodeKind.ObjectLiteral, {
			properties: [expr, nullNode],
			keys: ["fn", "env"],
			keyLocations: [expr.location, expr.location],
		} as NodeData, wrapTok);
		wrapped.nodeType = formal;
		wrapped.flags = wrapped.flags | NodeFlag.Closure | NodeFlag.Sem;
		return wrapped;
	}
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
function unwrapAsUnknown(node: Node): Node | null {
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

// Reference parity: deep clone a default expression node for insertion into call.
// Reference uses copyTree (recursive deep copy). We use cloneNodeForCheck from monomorphize.
// Deep clone is required because defaults may be complex expressions (object literals,
// function calls) and each call site needs its own independent AST to type-check.
function cloneDefaultNode(node: Node): Node {
	const clone = cloneNodeForCheck(node);
	// Prelude defaults are parsed but not semchecked — infer type from kind
	if (clone.nodeType === null) {
		match (clone.kind) {
			NodeKind.NumberLiteral => { clone.nodeType = isNodeIntLit(clone) ? int32Type() : float64Type(); },
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
		let defNode: Node | null = null;
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
	// Pass parameter types so default expressions get correct type hints
	// (e.g., empty array [] for string[] param → msStringArray, not msRefArray).
	let paramTypes: Type[] = null as unknown as Type[];
	if (defSym !== null && defSym.symbolType !== null && defSym.symbolType.typeChildren !== null) {
		paramTypes = defSym.symbolType.typeChildren;
	}
	fillDefaults(ctx, cd.arguments, fnDefaults, totalParams, defaultOffset, paramTypes);
}

// ===== NewExpr =====

function getCtorParamTypes(classSym: Symbol): Type[] {
	if (classSym.declNode === null) return null as unknown as Type[];
	let body: Node[] = null as unknown as Node[];
	if (classSym.declNode.kind === NodeKind.ClassDecl) {
		body = (classSym.declNode.data as ClassDeclData).classBody;
	} else if (classSym.declNode.kind === NodeKind.ActorDecl) {
		body = (classSym.declNode.data as ActorDeclData).actorBody;
	}
	if (body !== null) {
		for (const member of body) {
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

function checkNewExpr(ctx: CheckerContext, node: Node, expected: Type | null): Type {
	const d = node.data as NewExprData;
	// new BuiltinType<...>() — construct value types (Map, Set) and Promise
	if (d.newCallee.kind === NodeKind.Identifier) {
		const id = d.newCallee.data as IdentifierData;
		// Interface/value type: new HashMap() / new Array(32) with type from variable annotation
		// Also handle Ref<Struct> and Ref<GenericInstance> (interface types are Ref-wrapped)
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
	// Pass the NewExpr's AST-resident typeArg so resolveGenericNewExpr can prefer
	// it over the stale location-keyed side channel (important for cloned bodies).
	const resolvedType = resolveGenericNewExpr(ctx, d.newCallee, calleeType, node.typeArg);
	// Error: generic type without type args and no inferable context
	if (d.newCallee.kind === NodeKind.Identifier) {
		const calleeName2 = (d.newCallee.data as IdentifierData).name;
		const genericParams2 = getGenericDecl(calleeName2);
		if (genericParams2 !== "") {
			const ltCol2 = d.newCallee.location.column + calleeName2.length;
			const typeArgStr2 = getExplicitTypeArg(d.newCallee.location.line, ltCol2);
			if (typeArgStr2 === "") {
				addError(ctx, `'new ${calleeName2}()' requires explicit type arguments: new ${calleeName2}<...>()`, node.location.line, node.location.column);
			}
		}
	}
	// Resolve inner struct type for field type propagation
	const innerType = (resolvedType !== null && resolvedType.kind === TypeKind.Ref && resolvedType.typeReturn !== null)
		? resolvedType.typeReturn : resolvedType;
	// Type-check constructor arguments.
	// If class has constructor, let args self-infer (constructor function handles param types).
	// Otherwise use struct field types as expected types (positional field initialization).
	const hasCtor = d.newCallee.resolvedSym !== null && hasFlag(d.newCallee.resolvedSym, SymbolFlag.HasConstructor);
	let ai = 0;
	while (ai < d.newArguments.length) {
		let argExpected: Type | null = null;
		if (!hasCtor && innerType !== null && innerType.typeChildren !== null && ai < innerType.typeChildren.length) {
			argExpected = innerType.typeChildren[ai];
		}
		checkExpr(ctx, d.newArguments[ai], argExpected);
		ai = ai + 1;
	}
	// Fill default args for constructor calls — unified with fillDefaults (same as functions).
	if (hasCtor) {
		// Path 1: monomorphized generic constructors (Set__string_new) via _ctorRegistry
		// For GenericInstance types, compute mangled name from structure (typeName + type args).
		// The GenericInstance keeps bare typeName ("Map") for type matching/unification;
		// the mangled name ("Map__string_int64") is computed on-demand here.
		let mangledName = "";
		if (innerType !== null) {
			if (innerType.kind === TypeKind.GenericInstance && innerType.typeChildren.length > 0) {
				mangledName = mangleMonoName(innerType.typeName, innerType.typeChildren);
			} else {
				mangledName = innerType.typeName;
			}
		}
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

function checkTryExpr(ctx: CheckerContext, node: Node): Type | null {
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

function checkCallExpr(ctx: CheckerContext, node: Node, expectedType: Type | null): Type {
	const d = node.data as CallExprData;
	checkExpr(ctx, d.callee, null);
	let calleeType = d.callee.nodeType;
	// Detect overloaded paths early — these need argTypes for scoring
	let needsOverloadScoring = false;
	let overloadSym: Symbol = null as unknown as Symbol;
	// Extension pre-resolution state (set in MemberExpr branch, used after arg checking)
	let extPreResolved = false;
	let extMultiFiltered: ExtensionMethod[] = [];
	let extMultiObjType: Type | null = null;
	let extMultiMethodName = "";
	let isActorMethodCall = false;
	// Check for overloads + set resolvedSym for direct calls
	if (d.callee.kind === NodeKind.Identifier) {
		const calleeName = (d.callee.data as IdentifierData).name;
		const sym = lookupSymbol(ctx.table, calleeName);
		// Phase B+ eager: Bare-call macro invocation with inline expansion.
		//
		// When the callee resolves to a Macro symbol, run the macro RIGHT NOW
		// (semMacroExpr → semAfterMacroCall model) and replace this node
		// with the expansion result. This is essential for type inference:
		// without it, `const x = answer()` would have x typed as `unknown`
		// (because macro return types can't be predicted), and C codegen would
		// emit `void* x = 42` instead of `double x = 42`.
		//
		// The depth counter prevents infinite recursion when a macro returns
		// a call to another macro that returns another, etc.
		if (sym !== null && sym.symbolKind === SymbolKind.Macro) {
			if (ctx.macroExpansionDepth >= 16) {
				addError(ctx, "macro expansion depth limit (16) exceeded for '" + calleeName + "' — possible recursive macro",
					node.location.line, node.location.column);
				node.nodeType = unknownType();
				return unknownType();
			}
			// Type-check args first (errors inside them are reported)
			const macroArgsRef = d.arguments;
			let mai = 0;
			while (mai < macroArgsRef.length) {
				checkExpr(ctx, macroArgsRef[mai], null);
				mai = mai + 1;
			}
			// Mutate node to MacroInvocation form so expandMacroInvocation can read it
			node.kind = NodeKind.MacroInvocation;
			node.data = { macroName: calleeName, macroArgs: macroArgsRef };
			// Eagerly expand right now via the Raiser VM. Track depth across the
			// re-check below so recursive macros hit the limit cleanly.
			ctx.macroExpansionDepth = ctx.macroExpansionDepth + 1;
			const expanded = expandMacroInvocation(node, ctx, 0);
			// Replace current node contents with the expanded result.
			// Identity is preserved — the parent (e.g. VariableDecl) still references this node.
			node.kind = expanded.kind;
			node.data = expanded.data;
			if (expanded.location !== null) node.location = expanded.location;
			node.nodeType = null as unknown as Type;
			node.resolvedSym = null as unknown as Symbol;
			node.flags = 0;
			// Re-check the mutated node so its nodeType is set. This drives correct
			// type inference for the parent (e.g., the VariableDecl declaring `x`).
			// If the expanded result is itself a macro call, this recurses through
			// checkCallExpr → eager expand again, bounded by macroExpansionDepth.
			checkExpr(ctx, node, expectedType);
			ctx.macroExpansionDepth = ctx.macroExpansionDepth - 1;
			return node.nodeType;
		}
		if (sym !== null) {
			// Demand-driven: ensure callee signature is ready
			ensureShaped(sym, ctx);
			node.resolvedSym = sym;
			markUsed(sym);
			sgRecordSym(ctx, d.callee.location.line, d.callee.location.column, d.callee.location.column + calleeName.length, sym, sym.symbolType, sym.symbolKind, calleeName, "", false);
			// Template: inline AST substitution (reference parity). Expand the
			// template body at the call site — no function call emitted.
			if (sym.symbolKind === SymbolKind.Function && isTemplateSym(sym)) {
				return expandTemplate(ctx, sym, node, d, expectedType);
			}
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
	// Backwards type inference: derive bindings from expectedType as HINTS for arg checking.
	// Stored in a separate `paramHints` array rather than substituted into `calleeType`, so
	// the arg-mismatch check at line ~1831 still sees GenericParam and correctly skips —
	// otherwise a concrete-arg call nested in an incompatible outer context
	// (e.g. `console.log(max(3, 7))`: max's T backward-binds to string → 3:int32 false-errors)
	// would false-positive here instead of surfacing the real error at the outer call
	// (int32 return not assignable to console.log's string param).
	//
	// The hint still flows to args that NEED context to type-check:
	//   Result.ok({...}) with expected Result<ParsedResponse, HttpError>
	//     → paramHints[0] = ParsedResponse → object literal types as ParsedResponse
	//
	// Forward inference from actual arg types (line ~1871) then drives instantiation,
	// and inferGenericReturn (line ~1910) combines arg+expected bindings for the return type.
	let paramHints: Type[] = null as unknown as Type[];
	if (!needsOverloadScoring && calleeType !== null && calleeType.kind === TypeKind.Function
		&& expectedType !== null && calleeType.typeReturn !== null
		&& hasGenericParams(calleeType)) {
		const backBindings = createUnifyBindings();
		unifyType(calleeType.typeReturn, expectedType, backBindings);
		if (backBindings.names.length > 0) {
			const hinted = instantiateGeneric(calleeType, backBindings.names, backBindings.types);
			paramHints = hinted.typeChildren;
		}
	}
	// Overloaded direct calls — delegate arg checking to resolveOverloadCall
	// which re-checks per candidate with speculative rollback (Phase 5).
	// Affine-Promise consumption also happens inside, during the commit step.
	if (needsOverloadScoring) {
		return resolveOverloadCall(ctx, overloadSym, node);
	}
	// Non-overload path: check args once with callee-derived expected types.
	const argTypes: Type[] = [];
	for (let ai = 0; ai < d.arguments.length; ai += 1) {
		let paramExpected: Type | null = null;
		if (paramHints !== null && ai < paramHints.length) {
			paramExpected = paramHints[ai];
		} else if (calleeType !== null && calleeType.kind === TypeKind.Function
			&& calleeType.typeChildren !== null
			&& ai < calleeType.typeChildren.length) {
			paramExpected = calleeType.typeChildren[ai];
		}
		checkExpr(ctx, d.arguments[ai], paramExpected);
		let argType = d.arguments[ai].nodeType;
		// Tier 1: narrow direct enum member access to its EnumLiteral form for call checking.
		if (argType !== null && argType.kind === TypeKind.Enum) {
			const argNode = d.arguments[ai];
			if (argNode.resolvedSym !== null
					&& argNode.resolvedSym.symbolKind === SymbolKind.EnumMember
					&& argNode.resolvedSym.symbolType !== null
					&& argNode.resolvedSym.symbolType.kind === TypeKind.EnumLiteral) {
				argType = argNode.resolvedSym.symbolType;
			}
		}
		argTypes.push(argType);
		// PARALOCK Phase 1: passing an affine-Promise identifier as a function argument
		// counts as consumption. For overloaded calls this happens inside the
		// overload resolver's commit step instead (see resolveOverloadCall).
		if (argType !== null && isAffineAwaitable(argType) && d.arguments[ai].kind === NodeKind.Identifier) {
			const argSym = d.arguments[ai].resolvedSym;
			if (argSym !== null) {
				markConsumedName(ctx.affineTracker, symbolConsumeKey(argSym));
				markConsumed(argSym);
			}
		}
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
	// @builtin("PromiseSpawn"): infer affine `Promise<T>` from closure's return type.
	// PARALOCK: spawn produces `Promise<T>` tagged with AwaitableAffine +
	// AwaitableScopeBound flags. Same surface type as a plain Promise, with
	// structurally identical (typeChildren[0] = inner type), so downstream transforms
	// that call isAwaitable() still recognize it, and compat.ms upcasts it to Promise<T>
	// for assignability so existing code (Promise.all, explicit Promise<T> annotations) works.
	if (node.resolvedSym !== null && node.resolvedSym.builtinKind === "PromiseSpawn"
		&& argTypes.length >= 1 && argTypes[0] !== null && argTypes[0].kind === TypeKind.Function) {
		const spawnInner = argTypes[0].typeReturn !== null ? argTypes[0].typeReturn : voidType();
		const spawnRet = createSpawnHandle(spawnInner);
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
							addWarning(ctx, `implicit ${typeDisplayName(argTypes[pi])} → ${typeDisplayName(paramType)} narrowing in '${calleeName}' arg ${pi}`, node.location.line, node.location.column);
						}
					} else {
						const calleeName = getCalleeName(d.callee);
						addError(ctx, "Argument type mismatch in '" + calleeName + "' arg " + String(pi) + ": got " + typeDisplayName(argTypes[pi]) + ", expected " + typeDisplayName(paramType), node.location.line, node.location.column);
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
		// Explicit type arg validation (TS-aligned). When the user wrote
		// `f<int32>(null)`, the explicit `<int32>` binds T=int32. The standard
		// arg-vs-param check at line ~1845 skips GenericParam to avoid
		// false-positives in nested generic calls (see ec38c20). Here we
		// already KNOW T's binding from the explicit type arg, so we can
		// safely strict-check args against the bound param types — matching
		// TS error TS2345 "Argument of type 'X' is not assignable to parameter
		// of type 'Y'".
		if (calleeType !== null && calleeType.kind === TypeKind.Function
			&& hasGenericParams(calleeType)
			&& node.resolvedSym !== null
			&& node.resolvedSym.declNode !== null
			&& node.resolvedSym.declNode.kind === NodeKind.FunctionDecl) {
			const fnDeclData = node.resolvedSym.declNode.data as FunctionDeclData;
			const genericParamNames = extractGenericNames(fnDeclData.fnFlags);
			const explicitBindings = bindFromExplicitTypeArgs(node, genericParamNames, ctx);
			if (explicitBindings.names.length > 0) {
				const boundFnType = instantiateGeneric(calleeType, explicitBindings.names, explicitBindings.types);
				if (boundFnType !== null && boundFnType.kind === TypeKind.Function) {
					for (let pi = 0; pi < argTypes.length && pi < boundFnType.typeChildren.length; pi += 1) {
						const argT = argTypes[pi];
						const paramT = boundFnType.typeChildren[pi];
						if (argT === null || paramT === null) continue;
						if (argT.kind === TypeKind.Unknown || argT.kind === TypeKind.Error) continue;
						if (paramT.kind === TypeKind.GenericParam || paramT.kind === TypeKind.Unknown) continue;
						if (!isAssignable(argT, paramT)) {
							const calleeName = getCalleeName(d.callee);
							addError(ctx, "Argument type mismatch in '" + calleeName + "' arg " + String(pi) + ": got " + typeDisplayName(argT) + ", expected " + typeDisplayName(paramT), d.arguments[pi].location.line, d.arguments[pi].location.column);
						}
					}
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
		// Assertion function narrowing: `asserts x is T`. Applied on the
		// general return path (not just extensions) so direct calls like
		// `assertString(val)` narrow `val` for subsequent statements.
		if (calleeType !== null && calleeType.kind === TypeKind.Function
				&& calleeType.typeExtra !== null
				&& calleeType.typeExtra.kind === TypeKind.Unknown
				&& calleeType.typeExtra.typeName.length > 8
				&& calleeType.typeExtra.typeName.slice(0, 8) === "asserts:") {
			applyAssertionNarrowing(calleeType, d.arguments);
		}
		return inferGenericReturn(calleeType, argTypes, expectedType);
	}
	return getReturnType(calleeType);
}

// Resolve generic return type using explicit type arg (e.g. parse<Person>)
function inferGenericReturnWithExplicit(fnType: Type, argTypes: Type[], expectedType: Type | null, explicitArg: string, ctx: CheckerContext, node: Node): Type {
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

// Apply assertion narrowing: `asserts paramName is TargetType`. Mutates the
// argument's Symbol.symbolType so all subsequent checker references see the
// narrowed type. Safe because assertion functions are contracts — if they
// pass, the type holds unconditionally; if they fail, they throw/abort.
function applyAssertionNarrowing(calleeType: Type, args: Node[]): void {
	const sentinel = calleeType.typeExtra;
	if (sentinel === null) return;
	const assertParamName = sentinel.typeName.slice(8, sentinel.typeName.length);
	const targetType = sentinel.typeReturn;
	if (targetType === null || assertParamName === "") return;
	// Find the matching parameter index.
	if (calleeType.typeNames === null) return;
	let paramIdx: int32 = -1;
	let pi: int32 = 0;
	while (pi < calleeType.typeNames.length) {
		if (calleeType.typeNames[pi] === assertParamName) { paramIdx = pi; break; }
		pi = pi + 1;
	}
	if (paramIdx < 0 || paramIdx >= args.length) return;
	const arg = args[paramIdx];
	if (arg === null || arg.kind !== NodeKind.Identifier) return;
	const argSym = arg.resolvedSym;
	if (argSym === null) return;
	argSym.symbolType = targetType;
}

export function inferGenericReturn(fnType: Type, argTypes: Type[], expectedType: Type | null): Type {
	let returnType = fnType.typeReturn;
	if (returnType === null) return unknownType();

	const hasExpected = expectedType !== null && expectedType.kind !== TypeKind.Unknown;
	// TS rule: when the return type is a NAKED generic param `T`, contextual type
	// does NOT drive inference — args are the sole source. `function id<T>(x:T):T`
	// called as `id(null)` infers T=null from the arg; the later assignment to a
	// declared `int32` then errors at the assignment site, not at the call.
	// Wrapped returns like `Result<T,E>` or `Box<T>` use contextual inference
	// (TS-quirk: null arg is accepted when T was bound from contextual via wrapper).
	const isNakedGenericReturn = returnType.kind === TypeKind.GenericParam;

	// Pass 1: argument-driven inference.
	// Skip weak inference sources:
	//   - Unknown / Error: failed checks must not poison bindings.
	//   - Null literal (only when contextual inference is enabled, i.e. wrapped
	//     return types). TS treats `null` as a weak inference source there so
	//     contextual T wins. For naked-T returns, args ALWAYS drive — including
	//     null — to mirror TS behavior of erroring later at assignment.
	const argBindings = createUnifyBindings();
	const skipNullArg = hasExpected && !isNakedGenericReturn;
	for (let i = 0; i < fnType.typeChildren.length && i < argTypes.length; i += 1) {
		const at = argTypes[i];
		if (at === null) continue;
		if (at.kind === TypeKind.Unknown || at.kind === TypeKind.Error) continue;
		if (skipNullArg && at.kind === TypeKind.Null) continue;
		unifyType(fnType.typeChildren[i], at, argBindings);
	}

	// Pass 2: contextual return type fills GAPS only (Nim's `inheritBindings`
	// parity, semcall.nim:777-831). Args win — expected only binds generic
	// params left unbound by Pass 1. GATED on non-naked-T to match TS naked-T
	// rule: see comment above `isNakedGenericReturn`.
	if (hasExpected && !isNakedGenericReturn) {
		const expBindings = createUnifyBindings();
		unifyType(returnType, expectedType, expBindings);
		for (let k = 0; k < expBindings.names.length; k += 1) {
			if (!hasBindingName(argBindings, expBindings.names[k])) {
				argBindings.names.push(expBindings.names[k]);
				argBindings.types.push(expBindings.types[k]);
			}
		}
	}

	for (let j = 0; j < argBindings.names.length; j += 1) {
		returnType = substituteType(returnType, argBindings.names[j], argBindings.types[j]);
	}
	return returnType;
}

function hasBindingName(b: UnifyBindings, name: string): boolean {
	for (let i = 0; i < b.names.length; i += 1) {
		if (b.names[i] === name) return true;
	}
	return false;
}

// Resolve explicit type args from a CallExpr `f<T1, T2>(...)` against the
// supplied generic parameter names (in declaration order). Returns empty
// bindings when no explicit args present, names list empty, or types fail to
// resolve.
//
// Source-agnostic: the caller is responsible for extracting paramNames from
// the appropriate source — `extractGenericNames(fnFlags)` for FunctionDecl,
// `getGenericDecl(className)` split-on-comma for classes/interfaces. Keeps
// this helper free of declaration-kind branching.
//
// DRY anchor: any call-pipeline code that needs to honor explicit type args
// (per-arg validation, mono pre-binding, return-type substitution) routes
// through this helper instead of re-parsing/re-resolving.
function bindFromExplicitTypeArgs(node: Node, paramNames: string[], ctx: CheckerContext): UnifyBindings {
	const result = createUnifyBindings();
	if (paramNames.length === 0) return result;
	const explicitStr = findCallTypeArg(node);
	if (explicitStr === "") return result;
	const argNames = splitTopLevel(explicitStr, ",");
	const limit = paramNames.length < argNames.length ? paramNames.length : argNames.length;
	for (let i = 0; i < limit; i += 1) {
		const paramName = paramNames[i].trim();
		const argTypeStr = argNames[i].trim();
		if (paramName === "" || argTypeStr === "") continue;
		const resolved = resolveAnnotation(argTypeStr, ctx, node.location.line, node.location.column);
		if (resolved !== null && resolved.kind !== TypeKind.Unknown) {
			result.names.push(paramName);
			result.types.push(resolved);
		}
	}
	return result;
}

// Tier 1: locate the implementation symbol in an overload set.
// The implementation is the unique member without the OverloadSig flag.
// Returns null if no implementation exists (all candidates are sigs).
function findOverloadImpl(sym: Symbol): Symbol {
	if (!hasFlag(sym, SymbolFlag.OverloadSig)) return sym;
	for (const o of sym.overloads) {
		if (!hasFlag(o, SymbolFlag.OverloadSig)) return o;
	}
	return null as unknown as Symbol;
}

// Validate every overload sig against the implementation. Runs once per
// overload set (flagged by `SymbolFlag.OverloadValidated` on the impl).
// Rules:
//   1. sig arity must equal impl arity
//   2. each sig param type must be assignable to the impl's corresponding param
//   3. sig return type must be assignable to impl return type
// Emits errors and returns false if any rule is violated.
function validateOverloadSigs(ctx: CheckerContext, sym: Symbol, impl: Symbol, callNode: Node): boolean {
	if (hasFlag(impl, SymbolFlag.OverloadValidated)) return true;
	setFlag(impl, SymbolFlag.OverloadValidated);
	const implFnType = impl.symbolType;
	if (implFnType === null || implFnType.kind !== TypeKind.Function) return true;
	const implRet = implFnType.typeReturn;
	const implParams = implFnType.typeChildren;
	const allSyms: Symbol[] = [sym];
	for (const o of sym.overloads) allSyms.push(o);
	for (const s of allSyms) {
		if (s === impl) continue;
		if (!hasFlag(s, SymbolFlag.OverloadSig)) continue;
		const sigType = s.symbolType;
		if (sigType === null || sigType.kind !== TypeKind.Function) continue;
		if (sigType.typeChildren.length !== implParams.length) {
			addError(ctx, `Overload signature for '${sym.name}' has ${sigType.typeChildren.length} parameter(s) but implementation has ${implParams.length}`,
				callNode.location.line, callNode.location.column);
			return false;
		}
		let paramMismatch = -1;
		for (let pi = 0; pi < sigType.typeChildren.length; pi += 1) {
			if (!isAssignable(sigType.typeChildren[pi], implParams[pi])) {
				paramMismatch = pi;
				break;
			}
		}
		if (paramMismatch >= 0) {
			addError(ctx, `Overload signature for '${sym.name}' param ${paramMismatch + 1} type '${typeDisplayName(sigType.typeChildren[paramMismatch])}' not assignable to implementation param type '${typeDisplayName(implParams[paramMismatch])}'`,
				callNode.location.line, callNode.location.column);
			return false;
		}
		const sRet = sigType.typeReturn;
		if (sRet !== null && implRet !== null && !isAssignable(sRet, implRet)) {
			addError(ctx, `Overload signature for '${sym.name}' has return type '${typeDisplayName(sRet)}' incompatible with implementation return type '${typeDisplayName(implRet)}'`,
				callNode.location.line, callNode.location.column);
			return false;
		}
	}
	return true;
}

// Check one argument with a specific expected type, then extract its nodeType
// (with EnumLiteral narrowing for direct enum-member accesses).
function checkArgWithExpected(ctx: CheckerContext, arg: Node, expected: Type | null): Type {
	checkExpr(ctx, arg, expected);
	let argType = arg.nodeType;
	if (argType !== null && argType.kind === TypeKind.Enum
			&& arg.resolvedSym !== null
			&& arg.resolvedSym.symbolKind === SymbolKind.EnumMember
			&& arg.resolvedSym.symbolType !== null
			&& arg.resolvedSym.symbolType.kind === TypeKind.EnumLiteral) {
		argType = arg.resolvedSym.symbolType;
	}
	return argType;
}

// Check all arguments against a candidate's parameter types. Returns the
// list of inferred argument types. For arity < params, unfilled positions
// are skipped (defaults are filled later in the commit step).
function checkArgsAgainstCandidate(ctx: CheckerContext, args: Node[], candType: Type): Type[] {
	const argTypes: Type[] = [];
	for (let ai = 0; ai < args.length; ai += 1) {
		let expected: Type | null = null;
		if (candType !== null && candType.kind === TypeKind.Function
				&& candType.typeChildren !== null
				&& ai < candType.typeChildren.length) {
			expected = candType.typeChildren[ai];
		}
		argTypes.push(checkArgWithExpected(ctx, args[ai], expected));
	}
	return argTypes;
}

// Phase 5: two-pass overload resolution (ref: typescript-go
// `internal/checker/checker.go:8682-8903`, `chooseOverload`).
//
// Pass 1 (scoring): check each arg once with `null` expected type. Object
// literals become anonymous structs (`checkObjectLiteral` anon-synthesis
// path at ~line 762). Enum member accesses rewrite `K.A` to Identifier
// `K_A` once, with `resolvedSym.symbolType` set to `EnumLiteral(K, A)` —
// `checkArgWithExpected` narrows via resolvedSym even when `nodeType`
// remains the wider `Enum(K)`. Score candidates via the existing
// `scoreCandidatePriority` / `cmpCandidates` machinery.
//
// Pass 2 (commit): for context-sensitive args only (ObjectLiteral,
// ArrowFunction), reset and re-check with the winning candidate's param
// type so they get precise variant typing + codegen flag stamping.
// Non-context-sensitive args (identifiers, member accesses, literals,
// calls) keep their Pass 1 state.
//
// No per-candidate snapshot/rewind. TS doesn't do it either: PR #57421
// (Wigham, 2024) proposed formal speculation, was marked Experimental,
// closed unmerged. Known leakage bugs microsoft/TypeScript#49820, #13430
// are accepted.
function resolveOverloadCall(ctx: CheckerContext, sym: Symbol, callNode: Node): Type {
	const impl = findOverloadImpl(sym);
	if (impl === null) {
		addError(ctx, `Overloaded function '${sym.name}' has no implementation — at least one definition must have a body`,
			callNode.location.line, callNode.location.column);
		return getReturnType(sym.symbolType);
	}
	if (!validateOverloadSigs(ctx, sym, impl, callNode)) {
		return getReturnType(sym.symbolType);
	}

	const d = callNode.data as CallExprData;
	const args = d.arguments;

	// Build candidate arrays: primary at [0], overloads at [1..n]
	const candSyms: Symbol[] = [sym];
	for (const o of sym.overloads) candSyms.push(o);
	const candidates: Type[] = [];
	for (const cs of candSyms) candidates.push(cs.symbolType);

	// Pass 1: check non-context-sensitive args with null expected type.
	// Context-sensitive args (object literals, arrow functions) are SKIPPED
	// entirely — Pass 2 checks them against the winner's param type. This
	// matches TypeScript-go's `CheckModeSkipContextSensitive` (checker.go:8682-8686).
	// Skipping (rather than null-checking) avoids stamping cached types on the
	// literal's children that would survive into Pass 2 and defeat inference.
	const argTypes: Type[] = [];
	const skipMask: boolean[] = [];
	for (const arg of args) {
		if (isContextSensitive(arg)) {
			argTypes.push(null as unknown as Type);
			skipMask.push(true);
		} else {
			argTypes.push(checkArgWithExpected(ctx, arg, null as unknown as Type));
			skipMask.push(false);
		}
	}

	// Score each candidate using the shared priority machinery, detecting
	// ambiguity (two candidates with equal top scores).
	let bestIdx: int32 = -1;
	let bestScore: CandidateScore = null as unknown as CandidateScore;
	let ambiguous = false;
	let ci: int32 = 0;
	while (ci < candidates.length) {
		const candType = candidates[ci];
		if (candType === null || candType.kind !== TypeKind.Function) { ci = ci + 1; continue; }
		const score = scoreCandidateWithSkip(candType.typeChildren, argTypes, getMinArity(candType), skipMask);
		if (score.exactMatches < 0) { ci = ci + 1; continue; }
		if (bestIdx < 0) {
			bestIdx = ci;
			bestScore = score;
			ambiguous = false;
		} else {
			const cmp = cmpCandidates(score, bestScore, candType, candidates[bestIdx]);
			if (cmp > 0) {
				bestIdx = ci;
				bestScore = score;
				ambiguous = false;
			} else if (cmp === 0) {
				ambiguous = true;
			}
		}
		ci = ci + 1;
	}

	if (ambiguous) {
		// When ALL args are context-sensitive (skipMask all-true), every
		// candidate gets the same score (N subtypeMatches). This is not a
		// real ambiguity — it's the degenerate "no discriminating args" case.
		// Fall through to Pass 2 with the first matching candidate (TS-go
		// `chooseOverload` picks the first applicable candidate when scores
		// are tied). Only report ambiguity when at least one non-skipped arg
		// actually discriminates but two candidates still tie.
		let allSkipped = true;
		for (const s of skipMask) {
			if (!s) { allSkipped = false; break; }
		}
		if (!allSkipped) {
			addError(ctx, `Ambiguous call to overloaded function '${sym.name}'`,
				callNode.location.line, callNode.location.column);
			return getReturnType(sym.symbolType);
		}
	}

	if (bestIdx < 0) {
		// No candidate matched — detailed error with per-candidate mismatch.
		let msg = `No matching overload for '${sym.name}'\n  Expected one of:`;
		for (const candType of candidates) {
			if (candType === null || candType.kind !== TypeKind.Function) continue;
			msg = `${msg}\n    ${formatCandidateSig(sym.name, candType)}`;
			const mpos = findFirstMismatch(candType.typeChildren, argTypes, getMinArity(candType));
			if (mpos >= 0 && mpos < argTypes.length && mpos < candType.typeChildren.length) {
				const gotName = argTypes[mpos] !== null ? typeDisplayName(argTypes[mpos]) : "<skipped>";
				msg = `${msg}\n      first mismatch at position ${mpos + 1}: expected '${typeDisplayName(candType.typeChildren[mpos])}', got '${gotName}'`;
			} else if (candType.typeChildren.length !== argTypes.length) {
				msg = `${msg}\n      expected ${candType.typeChildren.length} argument(s), got ${argTypes.length}`;
			}
		}
		addError(ctx, msg, callNode.location.line, callNode.location.column);
		return getReturnType(sym.symbolType);
	}

	const winnerType = candidates[bestIdx];

	// Pass 2: check context-sensitive args for the first time, using the
	// winner's param types. Object literals get stamped with the specific
	// variant / struct type; arrow functions get their parameter types
	// inferred from the candidate. Pass 1 skipped these (so no Sem flag is
	// set) — no reset needed.
	if (winnerType.kind === TypeKind.Function && winnerType.typeChildren !== null) {
		for (let ai = 0; ai < args.length; ai += 1) {
			if (ai >= winnerType.typeChildren.length) break;
			if (!isContextSensitive(args[ai])) continue;
			checkExpr(ctx, args[ai], winnerType.typeChildren[ai]);
			argTypes[ai] = args[ai].nodeType;
		}
	}

	// Consume affine-Promise arguments now that arg checking has settled.
	// Done AFTER Pass 2 so we only consume once (not once per pass).
	for (const arg of args) {
		const at = arg.nodeType;
		if (at !== null && isAffineAwaitable(at) && arg.kind === NodeKind.Identifier) {
			const argSym = arg.resolvedSym;
			if (argSym !== null) {
				markConsumedName(ctx.affineTracker, symbolConsumeKey(argSym));
				markConsumed(argSym);
			}
		}
	}

	// Store the RAW winner slot (pre sig→impl redirect). This is the
	// semantic fact "overload resolution picked candidate N" and is what
	// hover/sig-help/rename/LSP views want to read. Codegen applies the
	// sig→impl redirect locally when emitting the mangled call name —
	// body-less sigs don't emit C functions, so the C backend walks from
	// the winner sym to the body-bearing impl before mangling. Keeping
	// the redirect localized to codegen avoids conflating "which overload
	// matched" with "which symbol gets emitted".
	d.resolvedOverloadIdx = bestIdx;
	callNode.resolvedSym = sym;
	if (d.callee !== null && d.callee.kind === NodeKind.Identifier) {
		d.callee.resolvedSym = sym;
		if (sym.symbolType !== null) d.callee.nodeType = sym.symbolType;
	}
	if (winnerType.kind === TypeKind.Function && argTypes.length < winnerType.typeChildren.length) {
		fillDefaultArgsForNode(ctx, callNode, sym.name, winnerType.typeChildren.length, 0);
	}
	return inferGenericReturn(winnerType, argTypes, null);
}

// Resolve extension method overloads: multiple extensions match same receiver+method.
// Each extension's fnType includes the receiver as param[0]; strip it before scoring.
function resolveExtensionOverloadCall(ctx: CheckerContext, exts: ExtensionMethod[],
	argTypes: Type[], objType: Type | null, methodName: string, callNode: Node): Type {
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
		sig = sig + typeDisplayName(fnType.typeChildren[pi]);
		pi = pi + 1;
	}
	sig = sig + ")";
	if (fnType.typeReturn !== null) {
		sig = sig + ": " + typeDisplayName(fnType.typeReturn);
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
	let bestType: Type | null = null;
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
	// Preserve OverloadSig flag on the primary sym for namespace access paths.
	if ((expInfo.primaryFlags & SymbolFlag.OverloadSig) !== 0) {
		setFlag(sym, SymbolFlag.OverloadSig);
	}
	if (expInfo.overloadTypes.length > 0) {
		sym.overloads = [];
		let oi = 0;
		while (oi < expInfo.overloadTypes.length) {
			const overSym = makeSymbolState(expInfo.name, expInfo.kind, expInfo.overloadTypes[oi], false, SymbolState.Shaped);
			overSym.overloadIdx = oi + 1;
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
			if (expInfo.overloadFlags !== null && oi < expInfo.overloadFlags.length
					&& (expInfo.overloadFlags[oi] & SymbolFlag.OverloadSig) !== 0) {
				setFlag(overSym, SymbolFlag.OverloadSig);
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
function checkDiscriminatedConstruction(ctx: CheckerContext, node: Node, d: ObjectLiteralData, unionType: Type | null, stampType: Type | null): Type {
	if (unionType === null) return unknownType();
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

	// Extract the discriminant value, normalised to whatever `findVariantByDiscriminant`
	// matches against the union's `typeNames[1+]`:
	//   - Enum disc (`kind: NodeKind.Foo`): checker has rewritten the member access to
	//     an Identifier `"NodeKind_Foo"`. Read the identifier name (the existing path).
	//   - Boolean disc (`ok: true`/`ok: false` from match-type Union with boolean disc,
	//     produced by Result migration): the discriminant prop is a BooleanLiteral.
	//     The variant key in `typeNames` is the literal `"true"` or `"false"`.
	//   - String disc (`kind: "circle"`/`"square"`): the discriminant prop is a
	//     StringLiteral. The variant key in `typeNames` is the literal value itself
	//     (e.g. `"circle"`).
	let discValue = "";
	if (discExpr.kind === NodeKind.Identifier) {
		const id = discExpr.data as IdentifierData;
		discValue = id.name;
	} else if (discExpr.kind === NodeKind.BooleanLiteral) {
		const bd = discExpr.data as BooleanLiteralData;
		discValue = bd.boolValue ? "true" : "false";
	} else if (discExpr.kind === NodeKind.StringLiteral) {
		const sd = discExpr.data as StringLiteralData;
		discValue = sd.value;
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

function checkMemberExpr(ctx: CheckerContext, node: Node, expectedType: Type | null): Type {
	const d = node.data as MemberExprData;
	checkExpr(ctx, d.object, null);
	const objType = d.object.nodeType;
	if (objType === null) return unknownType();
	// Ref parity: strictNotNil — warn on unguarded class (heap pointer) member access.
	// Phase 4: uses the flow graph's isDefinitelyNonNullAt walker (replaced the
	// fact-stack-based impliesNotNull).
	if (ctx.strictNullChecks && objType.kind === TypeKind.Ref && d.object.kind === NodeKind.Identifier) {
		if (!isDefinitelyNonNullAt(d.object)) {
			const objName = (d.object.data as IdentifierData).name;
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
		let memberExists = false;
		for (const m of objType.typeNames) {
			if (m === propName) { memberExists = true; break; }
		}
		// Tier 1: narrow to EnumLiteral when the context directly expects the literal form
		// (return type, variable annotation, etc). Union<EnumLiteral...> narrowing is deferred
		// to Tier 2 (discriminated union narrowing at call sites). The literal type is also
		// stored on resolvedSym.symbolType so call-argument narrowing can pick it up even
		// when no expectedType flows down.
		const wantsLiteral = expectedType !== null
			&& expectedType.kind === TypeKind.EnumLiteral
			&& expectedType.typeName === enumName
			&& expectedType.typeNames.length > 0
			&& expectedType.typeNames[0] === propName;
		const litType = (memberExists) ? createEnumLiteral(objType, propName) : objType;
		const reportedType = wantsLiteral ? litType : objType;
		// Create synthetic symbol for the enum member (no scope lookup needed).
		// Enum member mangled names are NOT in scope — resolved here at use site.
		const enumSym = lookupSymbol(ctx.table, enumName);
		const memberSym = makeSymbolState(propName, SymbolKind.EnumMember, reportedType, false, SymbolState.Shaped);
		if (enumSym !== null && enumSym.location !== null) {
			memberSym.location = enumSym.location;
			memberSym.modulePath = enumSym.modulePath;
		}
		sgRecordSym(ctx, node.location.line, node.location.column + 1, node.location.column + 1 + propName.length, memberSym, reportedType, SymbolKind.EnumMember, propName, enumName, false);
		// Rewrite entire node to Identifier (keeps codegen path identical to pre-Tier-1 behavior)
		node.kind = NodeKind.Identifier;
		node.data = { name: mangledName };
		node.resolvedSym = memberSym;
		// Always store the LITERAL type on resolvedSym so call-argument narrowing can read it
		// even when no expectedType flowed through. (See checkCallExpr arg loop.)
		if (memberExists) memberSym.symbolType = litType;
		node.nodeType = reportedType;
		return reportedType;
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
	// Generic match-type alias: peel GenericInstance through typeReturn/typeExtra
	// to reach the underlying Union body. Required for field resolution +
	// narrowing on `Result<T, E> = Ref<ResultData<T, E>>` style types.
	//
	// Snapshot the pre-peel form so we can recover concrete type args when
	// resolving generic class field types (e.g. `b.items: T[]` where b: Box<T>
	// and the receiver instance is Box<string>). The peeled struct loses the
	// type arg slot — without this snapshot, generic field substitution falls
	// through to GenericParam → `void*` in env structs.
	const objTypeBeforePeel = resolvedObjType;
	resolvedObjType = peelToStructOrUnion(resolvedObjType);
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
	// Generic class field substitution: `b.items` where `b: Box<string>` and the
	// class declares `items: T[]`. After `peelToStructOrUnion`, resolvedObjType is
	// the un-parameterized inner Struct, so getProperty returns `Array<T>` with
	// `T` as a GenericParam. Recover the concrete type args from the pre-peel GI
	// snapshot and substitute. Without this, downstream passes (env-field typing
	// in lambda lifting) see GenericParam → emit `void*`.
	if (!isStaticClassAccess && propType.kind !== TypeKind.Unknown && hasGenericParams(propType)
		&& objTypeBeforePeel !== null && objTypeBeforePeel.kind === TypeKind.GenericInstance) {
		const genericStr = getGenericDecl(objTypeBeforePeel.typeName);
		if (genericStr !== "") {
			const genericNames = splitTopLevel(genericStr, ",");
			for (let gi = 0; gi < genericNames.length && gi < objTypeBeforePeel.typeChildren.length; gi += 1) {
				propType = substituteType(propType, genericNames[gi].trim(), objTypeBeforePeel.typeChildren[gi]);
			}
		}
	}
	// Actor isolation: block external field access (only message-passing allowed).
	// Allow access from inside the actor's own methods (ctx.currentActorName matches).
	// Allow @nonisolated fields for read access (Swift parity).
	if (!isStaticClassAccess && propType.kind !== TypeKind.Unknown && resolvedObjType.typeName !== "") {
		const fieldOwnerSym = lookupSymbol(ctx.table, resolvedObjType.typeName);
		if (fieldOwnerSym !== null && fieldOwnerSym.symbolKind === SymbolKind.Actor
			&& ctx.currentActorName !== resolvedObjType.typeName
			&& d.property !== "pid"
			&& !hasNonisolatedField(fieldOwnerSym, d.property)) {
			addError(ctx, `cannot access actor field '${d.property}' directly — use actor methods`,
				node.location.line, node.location.column);
		}
	}
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
	// Phase 4: Flow-graph discriminated union narrowing.
	// When the object reference's flow type is narrower than its declared
	// union type (e.g. `if (s.kind === "a") { s.y }` inside the narrowed
	// block), resolve the property against the narrowed variant instead of
	// the full union. Errors if the field doesn't exist on the narrowed
	// variant, even though it exists on some other variant.
	//
	// `resolvedObjType` already passed through `peelToStructOrUnion` above,
	// so for generic match-type aliases (`Result<T, E> = Ref<ResultData<T, E>>`)
	// we already see the underlying Union here.
	if (resolvedObjType.kind === TypeKind.Union) {
		const narrowedObjType = getFlowTypeOfReference(d.object, resolvedObjType);
		if (narrowedObjType !== null && narrowedObjType !== resolvedObjType
				&& narrowedObjType.kind === TypeKind.Struct) {
			const fieldInVariant = findFieldInVariant(narrowedObjType, d.property);
			if (fieldInVariant === null) {
				// Field not in narrowed variant — only error if we ALSO didn't find
				// it via the union-wide getProperty above. Otherwise propType is
				// already valid (a union of variant field types), and the user's
				// intent is to use it without further narrowing — let it through.
				if (propType.kind === TypeKind.Unknown) {
					addError(ctx, `Property '${d.property}' does not exist on type '${typeDisplayName(narrowedObjType)}'. Available: ${narrowedObjType.typeNames.join(", ")}`,
						node.location.line, node.location.column);
					return propType;
				}
			} else {
				propType = fieldInVariant;
				// Record synthetic sym for LSP hover/go-to-definition on narrowed DU fields.
				// The normal sym-recording paths search resolvedObjType (the full union) whose
				// typeNames holds discriminant metadata, not field names — so they miss.
				const narrowedSym = makeSymbol(d.property, SymbolKind.Property, fieldInVariant, false);
				narrowedSym.state = SymbolState.Shaped;
				inheritContainerInfo(narrowedSym, ctx, resolvedObjType.typeName);
				node.resolvedSym = narrowedSym;
				sgRecordSym(ctx, node.location.line, node.location.column + 1, node.location.column + 1 + d.property.length, narrowedSym, fieldInVariant, SymbolKind.Property, d.property, resolvedObjType.typeName, false);
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
		// Phase 4 (root-cause for member-expr narrowing): walk the flow graph for
		// the MemberExpr node itself. After `if (x.field !== null) { x.field.foo }`
		// the binder records a TrueCondition on x.field; here we narrow propType.
		// Without this, accessing fields on a checked-non-null member-expr fails
		// with "Property 'foo' does not exist on type 'T | null'".
		const narrowed = getFlowTypeOfReference(node, propType);
		return narrowed !== null ? narrowed : propType;
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
		let toStrFnType: Type | null = null;
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
		const typeName = typeDisplayName(resolvedObjType);
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
	// Handles both enum-based DUs (isDiscriminatedUnion) and string-literal DUs (Tier 2).
	let narrowBase: Symbol | null = null;
	let narrowUnion: Type | null = null;
	let narrowIsStringDU = false;
	let narrowDiscField = "";
	if (d.matchDisc.kind === NodeKind.MemberExpr) {
		const discMd = d.matchDisc.data as MemberExprData;
		if (discMd.object !== null && discMd.object.kind === NodeKind.Identifier) {
			const baseSym = lookupSymbol(ctx.table, (discMd.object.data as IdentifierData).name);
			if (baseSym !== null && baseSym.symbolType !== null) {
				const di = detectUnionDiscriminant(baseSym.symbolType, discMd.property);
				if (di.discField !== "") {
					narrowBase = baseSym;
					narrowUnion = baseSym.symbolType;
					narrowIsStringDU = di.isStringDU;
					narrowDiscField = di.discField;
				}
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
				// Tier 2: collect string literal patterns for exhaustiveness
				if (p.kind === NodeKind.StringLiteral && !hasGuard) {
					const sd = p.data as StringLiteralData;
					coveredMembers.push(sd.value);
				}
				checkExpr(ctx, p, discType);
			}
		}
		// Phase 4: per-arm variant narrowing flows through the binder's
		// synthesizeMatchArmFlow → TrueCondition → getFlowTypeOfReference path.
		// The checker no longer needs to push/pop narrowing state here.

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

		branchInits.push(collectNewInits(ctx.initTracker, oldState));
		branchBreaks.push(breaksBlock(cd.caseBody));
		if (returnType.kind === TypeKind.Unknown && bodyType.kind !== TypeKind.Unknown) {
			returnType = bodyType;
		}
	}
	checkDuplicatePatterns(ctx, d.matchCases);

	// Match is exhaustive if has wildcard (_) or covers all enum members / string DU variants
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
	// Tier 2: string-literal DU exhaustiveness
	if (!isExhaustive && narrowIsStringDU && narrowUnion !== null) {
		const variantValues = collectStringDiscriminantValues(narrowUnion, narrowDiscField);
		if (variantValues.length > 0) {
			let allCovered = true;
			for (const v of variantValues) {
				let found = false;
				for (const c of coveredMembers) {
					if (c === v) { found = true; break; }
				}
				if (!found) { allCovered = false; break; }
			}
			if (allCovered) isExhaustive = true;
		}
	}
	mergeInitBranches(ctx.initTracker, oldState, branchInits, branchBreaks, isExhaustive);
	if (discType.kind === TypeKind.Enum && !hasWildcard) {
		const discEnd = estimateExprEndCol(d.matchDisc) + 1;
		checkEnumExhaustiveness(ctx, discType, coveredMembers, node.location.line, node.location.column, discEnd);
	}
	// Tier 2: report missing string DU variants
	if (narrowIsStringDU && narrowUnion !== null && !hasWildcard) {
		const variantValues = collectStringDiscriminantValues(narrowUnion, narrowDiscField);
		for (const v of variantValues) {
			let found = false;
			for (const c of coveredMembers) {
				if (c === v) { found = true; break; }
			}
			if (!found) {
				addError(ctx, `Non-exhaustive match: missing variant '${v}'`,
					node.location.line, node.location.column);
			}
		}
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

export function checkAnonymousFunction(ctx: CheckerContext, name: string, params: string[], paramTypes: string[], body: Node, paramLocs: SourceLocation[], returnTypeAnnotation: string, expectedType: Type | null): Type {
	const savedReturn = ctx.inferredReturn;
	ctx.inferredReturn = unknownType();
	const savedMatchDepth = ctx.matchExprDepth;
	ctx.matchExprDepth = 0;

	// Contextual param types from expectedType (e.g. callback signature at the call site).
	// Used when the user wrote untyped params: `arr.forEach(n => f(n))` — `n` typed by callee.
	// IMPORTANT: only param types are contextually inferred. Return type is still inferred
	// from body, because contextual return types may be generic (`() => T`) and would shadow
	// the concrete inference from the body that downstream passes (lambda lifting) rely on.
	let ctxParamTypes: Type[] = null as unknown as Type[];
	if (expectedType !== null && expectedType.kind === TypeKind.Function && expectedType.typeChildren !== null) {
		ctxParamTypes = expectedType.typeChildren;
	}

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
		} else if (ctxParamTypes !== null && pi < ctxParamTypes.length && ctxParamTypes[pi] !== null) {
			// Contextual fallback: untyped param inherits expected param type
			pType = ctxParamTypes[pi];
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
		} else if (ctxParamTypes !== null && ti < ctxParamTypes.length && ctxParamTypes[ti] !== null) {
			pType = ctxParamTypes[ti];
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

function checkArrowExpr(ctx: CheckerContext, node: Node, expectedType: Type | null): Type {
	const d = node.data as ArrowFunctionData;
	resolveTypeExpr(node.typeExpr, ctx);
	resolveTypeExprs(node.typeExprs, ctx);
	return checkAnonymousFunction(ctx, "<arrow>", d.arrowParams, d.arrowParamTypes, d.arrowBody, node.paramLocations, d.arrowReturnType, expectedType);
}

function checkFuncExpr(ctx: CheckerContext, node: Node, expectedType: Type | null): Type {
	const d = node.data as FunctionExprData;
	resolveTypeExpr(node.typeExpr, ctx);
	resolveTypeExprs(node.typeExprs, ctx);
	return checkAnonymousFunction(ctx, "(anon)", d.funcExprParams, d.funcExprParamTypes, d.funcExprBody, node.paramLocations, d.funcExprReturnType, expectedType);
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

// ===== Actor Isolation Helpers =====

function hasNonisolatedField(actorSym: Symbol, fieldName: string): boolean {
	if (actorSym.declNode === null || actorSym.declNode.kind !== NodeKind.ActorDecl) return false;
	const actorBody = (actorSym.declNode.data as ActorDeclData).actorBody;
	for (const m of actorBody) {
		if (m.kind !== NodeKind.DecoratedDecl) continue;
		const dd = m.data as DecoratedDeclData;
		if (dd.decoratedNode === null || dd.decoratedNode.kind !== NodeKind.PropertyDecl) continue;
		if ((dd.decoratedNode.data as PropertyDeclData).propName !== fieldName) continue;
		for (const dec of dd.decorators) {
			if (dec.kind === NodeKind.MacroInvocation
				&& (dec.data as MacroInvocationData).macroName === "nonisolated") return true;
		}
	}
	return false;
}

// ===== Actor Sendable Checker =====
// Enforces safe data transfer at actor method boundaries.
// Reuses: isPrimitiveKind, isStructType, SymbolFlag.Mutable, NodeKind.MoveExpr.

// Type-level check: is the type safe to send (no mutable refs anywhere)?
// Follows reference isolation check: containsDangerousRefAux — recurse into structure.
function isTypeSendable(t: Type | null): boolean {
	if (t === null) return true;
	if (isPrimitiveKind(t.kind)) return true;
	return match (t.kind) {
		TypeKind.String => true,
		TypeKind.Struct when (isStructType(t)) => {
			for (const ft of t.typeChildren) {
				if (!isTypeSendable(ft)) return false;
			}
			return true;
		},
		TypeKind.Tuple => {
			for (const et of t.typeChildren) {
				if (!isTypeSendable(et)) return false;
			}
			return true;
		},
		TypeKind.GenericInstance => {
			if (t.typeReturn !== null && !isTypeSendable(t.typeReturn)) return false;
			for (const ta of t.typeChildren) {
				if (!isTypeSendable(ta)) return false;
			}
			return true;
		},
		TypeKind.Array => {
			return t.typeReturn !== null ? isTypeSendable(t.typeReturn) : true;
		},
		TypeKind.Ref | TypeKind.Function => false,
		_ => false,
	};
}

// Call-site check: combines type analysis with expression-level rules (move, const binding).
function isSendable(t: Type, argNode: Node): boolean {
	if (t === null) return true;
	// move always transfers ownership safely
	if (argNode !== null && argNode.kind === NodeKind.MoveExpr) return true;
	// If the type itself contains no refs, it's always sendable (value copy)
	if (isTypeSendable(t)) return true;
	// Ref<T> with const binding → SHARE rule (immutable, safe to share)
	if (t.kind === TypeKind.Ref) {
		if (argNode !== null && argNode.resolvedSym !== null
			&& !hasFlag(argNode.resolvedSym, SymbolFlag.Mutable)) return true;
		return false;
	}
	return false;
}

function checkActorArgSendable(ctx: CheckerContext, argNode: Node, pi: number): void {
	const t = argNode.nodeType;
	if (t === null) return;
	if (isSendable(t, argNode)) return;
	const argLabel = argNode.kind === NodeKind.Identifier
		? "'" + (argNode.data as IdentifierData).name + "'"
		: `arg ${pi}`;
	const typedesc = typeDisplayName(t);
	const hint = match (t.kind) {
		TypeKind.Ref => {
			const varName = argNode.kind === NodeKind.Identifier ? " " + (argNode.data as IdentifierData).name : "";
			return ` — use \`move${varName}\` to transfer ownership`;
		},
		TypeKind.Function => " — closures may capture mutable state",
		_ => "",
	};
	addError(ctx, `actor methods only accept value types, \`move\`, or \`const\` references\n${typedesc} ${argLabel} is a mutable reference${hint}`,
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
	let body: Node | null = null;
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

// Lower-level: register a freshly-synthesized FunctionDecl as a root-scope symbol,
// re-check its body, and queue it for the next instantiation drain. Returns the
// symbol. No call-site rewrite — callers that need to wire up `d.callee` should
// use `registerJsonInstance`. ensureJsonValueOf/FromValue helpers use this
// directly because they aren't tied to a specific call site (they're called by
// the parent helper at re-check time).
function registerSynthesizedFunction(
	ctx: CheckerContext, helperName: string, params: string[], paramTypes: Type[],
	body: Node, fnReturnType: Type, fnNode: Node
): Symbol {
	const fnType = createFunction(paramTypes, params, fnReturnType);
	const instSym = makeSymbol(helperName, SymbolKind.Function, fnType, false);
	instSym.state = SymbolState.Shaped;
	instSym.modulePath = "";
	instSym.originalName = helperName;
	instSym.nameId = getIdentId(ctx.table.identCache, helperName);
	let rootScope = ctx.table.current;
	while (rootScope.parent !== null) rootScope = rootScope.parent;
	addSymbolToScope(rootScope, instSym);
	fnNode.resolvedSym = instSym;
	fnNode.nodeType = fnType;
	callCheckFunctionBody(ctx, instSym, params, body, null as unknown as SourceLocation[]);
	addPendingInstance(fnNode);
	return instSym;
}

// Shared: register a generated JSON instance (symbol + checker + pending + callee rewrite)
function registerJsonInstance(
	ctx: CheckerContext, helperName: string, params: string[], paramTypes: Type[],
	body: Node, fnReturnType: Type, fnNode: Node, node: Node, d: CallExprData, loc: SourceLocation
): Symbol {
	const syntheticTok = createSyntheticToken(loc);
	const instSym = registerSynthesizedFunction(ctx, helperName, params, paramTypes, body, fnReturnType, fnNode);

	const callIdent = createNode(NodeKind.Identifier, { name: helperName }, syntheticTok);
	callIdent.resolvedSym = instSym;
	callIdent.nodeType = instSym.symbolType;
	d.callee = callIdent;
	node.resolvedSym = instSym;
	return instSym;
}

// JSON.parse<Person>(input) → generate __jsonParse_Person, run checker on it, return call
function generateJsonParseInstance(ctx: CheckerContext, node: Node, d: CallExprData, typeArgStr: string, loc: SourceLocation): Type | null {
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
	//   if (!$r.ok) { return { ok: false, error: $r.error }; }
	//   const $v = $r.value;
	//   return { ok: true, value: { name: get($v, "name").strVal, ... } };
	// Result migrated to a boolean-discriminated match-type — variants have
	// disjoint fields (`{ok, value}` vs `{ok, error}`), so the synthesized
	// literals must NOT include the inactive variant's field.
	const stmts: Node[] = [];

	// const $r = parseJson(input)
	stmts.push(createNode(NodeKind.VariableDecl, {
		declName: "$r", declType: "", initializer: createNode(NodeKind.CallExpr, {
			callee: createNode(NodeKind.Identifier, { name: "parseJson" }, syntheticTok),
			arguments: [createNode(NodeKind.Identifier, { name: "input" }, syntheticTok)],
			isDirectCall: true,
		}, syntheticTok), declKind: DeclKind.Const, nameLocation: loc,
	}, syntheticTok));

	// if (!$r.ok) { return { ok: false, error: $r.error }; }
	const errObj = createNode(NodeKind.ObjectLiteral, {
		keys: ["ok", "error"],
		properties: [
			createNode(NodeKind.BooleanLiteral, { boolValue: false }, syntheticTok),
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

		// Use the shared dispatcher: jsonExtractExprFor handles primitive
		// accessors + sized-int casts + nested struct recursion via
		// `__jsonFromValue_<inner>(getCall)`. No silent fallback — unsupported
		// field types report an explicit error and abort synthesis.
		const fieldVal = jsonExtractExprFor(getCall, ftype, ctx, loc);
		if (fieldVal === null) {
			addError(ctx, "JSON deserialization: unsupported field type for '" + fname + "' in struct '" + typeArgStr + "' (kind " + (ftype !== null ? ftype.kind.toString() : "?") + ")",
				loc.line, loc.column);
			return null;
		}

		fieldProps.push(fieldVal);
		fi = fi + 1;
	}

	// return { ok: true, value: { fields... } }
	// Result migrated to a boolean-discriminated match-type — the ok=true
	// variant has only `value`; emitting `error` here would access a field
	// that doesn't exist on the v0 variant struct.
	const resultObj = createNode(NodeKind.ObjectLiteral, {
		keys: ["ok", "value"],
		properties: [
			createNode(NodeKind.BooleanLiteral, { boolValue: true }, syntheticTok),
			createNode(NodeKind.ObjectLiteral, { keys: fieldKeys, properties: fieldProps, keyLocations: [] }, syntheticTok),
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

// Lookup the JsonValue type symbol — return type of __jsonValueOf_T helpers.
// Returns null when stdlib `std/core/json` hasn't been loaded into scope (e.g.
// a check pass that doesn't import json — caller short-circuits gracefully).
function getJsonValueType(ctx: CheckerContext): Type | null {
	const sym = lookupSymbol(ctx.table, "JsonValue");
	if (sym === null || sym.symbolType === null) return null;
	if (sym.symbolType.kind === TypeKind.Unknown) return null;
	return sym.symbolType;
}

// Single source of truth for "what does the JSON system know about this
// primitive type". Returned shape carries BOTH directions (builder for
// stringify, accessor for parse) so adding a new primitive type kind requires
// exactly one edit here — keeps the two dispatch sites in sync.
interface JsonPrimDispatch {
	builder: string;       // jsonString / jsonBool / jsonNumber / jsonInt
	accessor: string;      // strVal / boolVal / numVal / intVal
	needsCast: boolean;    // intVal is int64 — sized-int field reads need a cast
}

function classifyJsonPrimitive(t: Type): JsonPrimDispatch | null {
	if (t === null) return null;
	if (t.kind === TypeKind.String) return { builder: "jsonString", accessor: "strVal", needsCast: false };
	if (t.kind === TypeKind.Boolean) return { builder: "jsonBool", accessor: "boolVal", needsCast: false };
	if (t.kind === TypeKind.Number || t.kind === TypeKind.Float64 || t.kind === TypeKind.Float32) {
		return { builder: "jsonNumber", accessor: "numVal", needsCast: false };
	}
	if (t.kind === TypeKind.Int8 || t.kind === TypeKind.Int16 || t.kind === TypeKind.Int32 || t.kind === TypeKind.Int64
		|| t.kind === TypeKind.Uint8 || t.kind === TypeKind.Uint16 || t.kind === TypeKind.Uint32 || t.kind === TypeKind.Uint64
		|| t.kind === TypeKind.Enum) {
		return { builder: "jsonInt", accessor: "intVal", needsCast: true };
	}
	return null;
}

// Build a `JsonValue`-producing AST expression for a struct field of type
// `fieldType`. Returns null on UNSUPPORTED types — caller MUST emit a clear
// compiler error (no silent fallback, that was the prior bug). Recursive:
// nested struct fields trigger sub-helper synthesis via
// `ensureJsonValueOfHelper`, so deep struct trees compose without losing type
// fidelity.
function jsonValueExprFor(fieldAccess: Node, fieldType: Type | null, ctx: CheckerContext, loc: SourceLocation): Node | null {
	if (fieldType === null) return null;
	const t = unwrapRef(fieldType);
	if (t === null) return null;
	const syntheticTok = createSyntheticToken(loc);

	const prim = classifyJsonPrimitive(t);
	if (prim !== null) {
		return createNode(NodeKind.CallExpr, {
			callee: createNode(NodeKind.Identifier, { name: prim.builder }, syntheticTok),
			arguments: [fieldAccess],
			isDirectCall: true,
		}, syntheticTok);
	}

	// Nested struct: synthesize sibling helper, call it. The helper returns
	// JsonValue, so it composes inside `jsonObject(keys, values)` like any
	// other element — no `jsonRaw` / re-stringify intermediary needed.
	if (t.kind === TypeKind.Struct && t.typeName !== "") {
		const innerSym = ensureJsonValueOfHelper(t, ctx, loc);
		if (innerSym === null) return null;
		const helperName = "__jsonValueOf_" + t.typeName;
		const callIdent = createNode(NodeKind.Identifier, { name: helperName }, syntheticTok);
		callIdent.resolvedSym = innerSym;
		callIdent.nodeType = innerSym.symbolType;
		return createNode(NodeKind.CallExpr, {
			callee: callIdent,
			arguments: [fieldAccess],
			isDirectCall: true,
		}, syntheticTok);
	}

	return null;
}

// Synthesize `__jsonValueOf_<TypeName>(value: T): JsonValue` if not cached.
// Returns the helper's Symbol, or null on failure (unsupported field type or
// missing JsonValue stdlib). Failures emit a compiler error before returning.
function ensureJsonValueOfHelper(structType: Type, ctx: CheckerContext, loc: SourceLocation): Symbol | null {
	const typeName = structType.typeName;
	if (typeName === "") return null;
	const helperName = "__jsonValueOf_" + typeName;

	// Cache: already synthesized → reuse.
	const existing = lookupSymbol(ctx.table, helperName);
	if (existing !== null) return existing;

	if (structType.typeNames === null || structType.typeChildren === null) return null;
	// JsonValue may not be in scope when this is invoked from a minimal-prelude
	// test harness. Fall back to `unknown` for the return slot — the body's
	// re-check below will surface real type errors when stdlib IS present, while
	// keeping the symbol registered so the parent's callee rename still works.
	const jvLookup = getJsonValueType(ctx);
	const jvType = jvLookup !== null ? jvLookup : unknownType();

	const syntheticTok = createSyntheticToken(loc);

	// Pre-pass: synthesize sub-helpers depth-first. The body's re-check below
	// resolves identifier symbols by name — they must already be in scope.
	let fi = 0;
	while (fi < structType.typeNames.length && fi < structType.typeChildren.length) {
		const ftype = unwrapRef(structType.typeChildren[fi]);
		if (ftype !== null && ftype.kind === TypeKind.Struct && ftype.typeName !== "") {
			const sub = ensureJsonValueOfHelper(ftype, ctx, loc);
			if (sub === null) return null;
		}
		fi = fi + 1;
	}

	// Build body: return jsonObject([k1, k2, ...], [expr1, expr2, ...]);
	const keyNodes: Node[] = [];
	const valNodes: Node[] = [];
	fi = 0;
	while (fi < structType.typeNames.length && fi < structType.typeChildren.length) {
		const fname = structType.typeNames[fi];
		const ftype = structType.typeChildren[fi];
		keyNodes.push(createNode(NodeKind.StringLiteral, { value: fname }, syntheticTok));

		const fieldAccess = createNode(NodeKind.MemberExpr, {
			object: createNode(NodeKind.Identifier, { name: "value" }, syntheticTok),
			property: fname,
		}, syntheticTok);

		const expr = jsonValueExprFor(fieldAccess, ftype, ctx, loc);
		if (expr === null) {
			addError(ctx, "JSON serialization: unsupported field type for '" + fname + "' in struct '" + typeName + "' (kind " + (ftype !== null ? ftype.kind.toString() : "?") + ")",
				loc.line, loc.column);
			return null;
		}
		valNodes.push(expr);
		fi = fi + 1;
	}

	const keysArr = createNode(NodeKind.ArrayLiteral, { elements: keyNodes }, syntheticTok);
	const valsArr = createNode(NodeKind.ArrayLiteral, { elements: valNodes }, syntheticTok);
	const objCall = createNode(NodeKind.CallExpr, {
		callee: createNode(NodeKind.Identifier, { name: "jsonObject" }, syntheticTok),
		arguments: [keysArr, valsArr],
		isDirectCall: true,
	}, syntheticTok);

	const body = createNode(NodeKind.BlockStmt, { statements: [
		createNode(NodeKind.ReturnStmt, { argument: objCall }, syntheticTok),
	] }, syntheticTok);

	const fnNode = createNode(NodeKind.FunctionDecl, {
		fnName: helperName,
		params: ["value"],
		fnParamTypes: [typeName],
		fnBody: body,
		fnFlags: "",
		fnReturnType: "JsonValue",
		fnDefaults: [],
		nativeName: "",
		nameLocation: loc,
	}, syntheticTok);

	return registerSynthesizedFunction(ctx, helperName, ["value"], [structType], body, jvType, fnNode);
}

// Mirror of `jsonValueExprFor` for the parse direction — pulls a typed field
// value out of a JsonValue subexpression. Primitive fields read JsonValue's
// kind-specific accessor (`.strVal`, `.boolVal`, `.numVal`, `.intVal`) plus a
// type cast for sized integers; nested struct fields recurse through
// `__jsonFromValue_<inner>(jvExpr)`. No silent fallback — unsupported types
// return null and the caller emits an explicit error.
function jsonExtractExprFor(jvExpr: Node, fieldType: Type | null, ctx: CheckerContext, loc: SourceLocation): Node | null {
	if (fieldType === null) return null;
	const t = unwrapRef(fieldType);
	if (t === null) return null;
	const syntheticTok = createSyntheticToken(loc);

	const prim = classifyJsonPrimitive(t);
	if (prim !== null) {
		let expr: Node = createNode(NodeKind.MemberExpr, {
			object: jvExpr, property: prim.accessor,
		}, syntheticTok);
		if (prim.needsCast) {
			expr = createNode(NodeKind.TypeAssertion, {
				asExpr: expr, asType: typeNameOf(t),
			}, syntheticTok);
		}
		return expr;
	}

	// Nested struct: `__jsonFromValue_<inner>(jvExpr)` returns the typed inner.
	if (t.kind === TypeKind.Struct && t.typeName !== "") {
		const innerSym = ensureJsonFromValueHelper(t, ctx, loc);
		if (innerSym === null) return null;
		const helperName = "__jsonFromValue_" + t.typeName;
		const callIdent = createNode(NodeKind.Identifier, { name: helperName }, syntheticTok);
		callIdent.resolvedSym = innerSym;
		callIdent.nodeType = innerSym.symbolType;
		return createNode(NodeKind.CallExpr, {
			callee: callIdent,
			arguments: [jvExpr],
			isDirectCall: true,
		}, syntheticTok);
	}

	return null;
}

// Synthesize `__jsonFromValue_<TypeName>(jv: JsonValue): T` if not cached.
// T is the *plain* struct (Ref-handling lives at the top-level
// `__jsonParse_T` only — for now nested Ref<Struct> fields are unsupported).
// Returns the helper Symbol or null on failure (failures emit an error first).
function ensureJsonFromValueHelper(structType: Type, ctx: CheckerContext, loc: SourceLocation): Symbol | null {
	const typeName = structType.typeName;
	if (typeName === "") return null;
	const helperName = "__jsonFromValue_" + typeName;

	const existing = lookupSymbol(ctx.table, helperName);
	if (existing !== null) return existing;

	if (structType.typeNames === null || structType.typeChildren === null) return null;

	const jvLookup = getJsonValueType(ctx);
	const jvType = jvLookup !== null ? jvLookup : unknownType();

	const syntheticTok = createSyntheticToken(loc);

	// Depth-first synthesis of nested helpers so symbols are in scope when this
	// helper's body re-checks.
	let fi = 0;
	while (fi < structType.typeNames.length && fi < structType.typeChildren.length) {
		const ftype = unwrapRef(structType.typeChildren[fi]);
		if (ftype !== null && ftype.kind === TypeKind.Struct && ftype.typeName !== "") {
			const sub = ensureJsonFromValueHelper(ftype, ctx, loc);
			if (sub === null) return null;
		}
		fi = fi + 1;
	}

	// Build body: return { f1: extract(get(jv, "f1")), f2: extract(get(jv, "f2")), ... };
	const fieldKeys: string[] = [];
	const fieldProps: Node[] = [];
	fi = 0;
	while (fi < structType.typeNames.length && fi < structType.typeChildren.length) {
		const fname = structType.typeNames[fi];
		const ftype = structType.typeChildren[fi];
		fieldKeys.push(fname);

		const getCall = createNode(NodeKind.CallExpr, {
			callee: createNode(NodeKind.Identifier, { name: "get" }, syntheticTok),
			arguments: [
				createNode(NodeKind.Identifier, { name: "jv" }, syntheticTok),
				createNode(NodeKind.StringLiteral, { value: fname }, syntheticTok),
			],
			isDirectCall: true,
		}, syntheticTok);

		const expr = jsonExtractExprFor(getCall, ftype, ctx, loc);
		if (expr === null) {
			addError(ctx, "JSON deserialization: unsupported field type for '" + fname + "' in struct '" + typeName + "' (kind " + (ftype !== null ? ftype.kind.toString() : "?") + ")",
				loc.line, loc.column);
			return null;
		}
		fieldProps.push(expr);
		fi = fi + 1;
	}

	const resultObj = createNode(NodeKind.ObjectLiteral, {
		keys: fieldKeys, properties: fieldProps, keyLocations: [],
	}, syntheticTok);
	resultObj.nodeType = structType;

	const body = createNode(NodeKind.BlockStmt, { statements: [
		createNode(NodeKind.ReturnStmt, { argument: resultObj }, syntheticTok),
	] }, syntheticTok);

	const fnNode = createNode(NodeKind.FunctionDecl, {
		fnName: helperName,
		params: ["jv"],
		fnParamTypes: ["JsonValue"],
		fnBody: body,
		fnFlags: "",
		fnReturnType: typeName,
		fnDefaults: [],
		nativeName: "",
		nameLocation: loc,
	}, syntheticTok);

	return registerSynthesizedFunction(ctx, helperName, ["jv"], [jvType], body, structType, fnNode);
}

// JSON.stringify(person) → wraps `__jsonValueOf_Person(value)` with `stringify(...)`.
// The recursive-helper structure (`__jsonValueOf_T` returning JsonValue) means
// nested struct fields just call sibling helpers and compose into the parent's
// `jsonObject(keys, values)` array — no special-casing per nesting depth.
function generateJsonStringifyInstance(ctx: CheckerContext, node: Node, d: CallExprData, loc: SourceLocation): Type | null {
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

	// Cache: a prior call site already synthesized — rewire and return.
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

	// Drive the recursive synthesis. `null` means an unsupported field type
	// was encountered — `ensureJsonValueOfHelper` already reported the error.
	if (ensureJsonValueOfHelper(structType, ctx, loc) === null) return null;

	// Body: return stringify(__jsonValueOf_T(value), false);
	const valueOfCall = createNode(NodeKind.CallExpr, {
		callee: createNode(NodeKind.Identifier, { name: "__jsonValueOf_" + typeName }, syntheticTok),
		arguments: [createNode(NodeKind.Identifier, { name: "value" }, syntheticTok)],
		isDirectCall: true,
	}, syntheticTok);
	const strCall = createNode(NodeKind.CallExpr, {
		callee: createNode(NodeKind.Identifier, { name: "stringify" }, syntheticTok),
		arguments: [valueOfCall, createNode(NodeKind.BooleanLiteral, { boolValue: false }, syntheticTok)],
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
