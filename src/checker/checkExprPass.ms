// Expression Checker — type inference for all expression kinds
// Extracted from checkPass.ms. Uses checkerCallbacks for mutual recursion with checkStmt.

import { Node, NodeKind, NodeData, createNode, createNodeAt, NodeFlag, SourceLocation, IdentifierData, BinaryExprData, UnaryExprData, UpdateExprData, NumberLiteralData, CallExprData, MemberExprData, ArrayAccessData, ObjectLiteralData, ArrayLiteralData, ConditionalExprData, TypeAssertionData, SpreadExprData, NewExprData, TryExprData, AwaitExprData, YieldExprData, MoveExprData, OutExprData, SizeofExprData, HiddenDerefData, HiddenStdConvData, MacroInvocationData, StringLiteralData, BigIntLiteralData, ArrowFunctionData, FunctionExprData, MatchCaseData, MatchExprData, FunctionDeclData, MethodDeclData, ClassDeclData, ActorDeclData, PropertyDeclData, DecoratedDeclData, BlockStmtData, ExprStmtData, ReturnStmtData, IfStmtData, SpliceManyData, VariableDeclData, Type, TypeKind, CallingConvention, Symbol, SymbolKind, SymbolState, BooleanLiteralData, collectConcatParts, JSXElementData, JSXFragmentData, JSXExpressionContainerData, JSXAttributeData, JSXSpreadAttributeData } from "../ast/node";
import { TokenKind, Token, createToken } from "../lexer/token";
import { inferredType, noneType, numberType, int32Type, float64Type, isFloatType, stringType, booleanType, charType, voidType, nullType, errorType, createArray, createRef, createArc, isAtomicRef, createSpan, createFunction, createClosureType, createTypeRef, createStruct, createPrimitive, createUnion, createMaybeType, isMaybeWrappable, isPrimitiveUnionMember, substituteType, instantiateGeneric, createGenericInstance, anonStructName, isNumeric, isIntegerType, getReturnType, getElementType, getProperty, sizeOfType, typeNameOf, isIndexableMapType, unwrapRef, unwrapVarargs, unwrapRefNullUnion, isDiscriminatedUnion, getDiscriminantName, findVariantByDiscriminant, findVariantByStringDiscriminant, findSharedStringDiscriminant, detectUnionDiscriminant, collectStringDiscriminantValues, findFieldInVariant, unionVariantHasProperty, findUnionVariant, isAmbiguousVariant, findVariantByFieldName, duVariantIndexOfType, duSharedFieldOffsetDiffers, unifyType, createUnifyBindings, mergeUnifyBindings, UnifyBindings, hasGenericParams, getMinArity, setMinArity, isNarrowingIntConv, integerRank, skipModifier, createPromise, createSpawnHandle, isAwaitable, isAffineAwaitable, awaitedType, isResult, getResultOkType, instantiateGenericBody, isStringLike, isPrimitiveKind, isStructType, isMaybeType, createEnumLiteral, typeDisplayName, booleanLiteralValue, peelToStructOrUnion, isPointerShapedForUnknown, isUnknownType, isUnresolvedType, isBrandDistinct } from "./types";
import { ScopeKind, SymbolFlag, defineSymbol, lookupSymbol, makeSymbol, makeSymbolState, openScope, closeScope, addSymbolToScope, hasOverloads, hasFlag, setFlag, markUsed, markConsumed, getCtorParamTypes } from "./symbol";
import { CheckerContext, ExportedSymInfo, addError, addErrorRange, addWarning, findAllExtensionsByName, resolveOperatorCall, ExtensionMethod, isCancelled, filterExtsByReceiverType, findFirstMatchingExt, getExtFnType, stripReceiverParam, sgRecordSym, findExportedSymbol, extractGenericNames, isGenericFn, isEngineCheckMode } from "./context";
import {
	isAssignable, isReinterpretUnsafe, nonNullMemberOfNullable, needsStdConv, findFirstMismatch,
	scoreCandidatePriority, scoreCandidateWithSkip, isNoMatch, emptyCandidateScore, cmpCandidates,
	CandidateScore, sameType, explainStructuralPrefix, isObjectShapeMismatch, isAnonStructAdoption,
} from "./compat";
import { callCheckStmt, registerCheckExpr } from "./checkerCallbacks";
import { resolveAnnotation, resolveTypeExpr, resolveTypeExprs, ensureShaped, recordGenericTypeInstantiation } from "./resolvePass";
import { mangleMonoName } from "../monomorphize/registry";
import { cloneNodeForCheck, monoConcreteTypeName } from "../monomorphize/clone";
import { callExpandMacroInvocation, callEvalComptimeBlock } from "./checkerCallbacks";
import { findChar, splitTopLevel, fitsInt64Decimal, int64ToDecimal } from "../utils/string";
import { findCallTypeArg, getExplicitTypeArg, getGenericDecl } from "../parser/context";
import { markConsumedName, isConsumedName, symbolConsumeKey } from "./spawnAffinity";
import { forEachChild } from "../ast/visitor";
import {
	markInitialized, isInitialized, getDeclBlock,
	saveInitState, restoreInitState, collectNewInits, mergeInitBranches, breaksBlock, BreakState,
} from "./initTracker";
import { callInstantiateGeneric } from "./checkerCallbacks";
import { getFlowTypeOfReference, isDefinitelyNonNullAt, unionOfTypes } from "./flow";
import { isContextSensitive } from "./speculate";
import { isTemplateSym, expandTemplate } from "./template";
import { checkBitwiseOperands, checkNegatedIntLiteral, fitJoinedBranch, fitNode, inferBinaryOp, inferUnaryOp, isBitwiseAllowed, isBitwiseBinaryOp, isNodeIntLit, joinBranchTypes, literalFitsInType, narrowUnionToVariant, rejectBigIntMix, reportLiteralRange, synthCStringConv, synthMaybeWrap, synthStringify, tryAdoptAnonStruct, trySynthesizeAsCoercion, unwrapAsUnknown, widenVariantToUnion, wrapInConv } from "./fit";

// Extension receiver matching functions imported from context.ms (shared with LSP)

// PARALOCK Amendment I — SHARE is immutable: no write may reach through an
// Arc<T> handle. Peels the member/index chain of a write target; the write
// passes through every prefix's deref, so an Arc at ANY prefix position (the
// root receiver `a.f = 1`, an interior field `holder.box.n = 1`, an indexed
// element `a.arr[i] = 1`) makes the whole write shared-state mutation.
// Writing the handle SLOT itself (`holder.box = otherArc`) is not affected —
// its prefixes stop at `holder`. Member access through a Ref inserts
// HiddenDeref (the deref node's type is the pointee), so the Arc test is
// applied to the deref's inner expression, not the deref node.
function writeThroughArc(target: Node): boolean {
	let cur: Node | null = target;
	while (cur !== null) {
		if (cur.kind === NodeKind.MemberExpr) {
			const o = (cur.data as MemberExprData).object;
			if (o !== null && o.nodeType !== null && isAtomicRef(o.nodeType)) return true;
			cur = o;
		} else if (cur.kind === NodeKind.ArrayAccess) {
			const a = (cur.data as ArrayAccessData).array;
			if (a !== null && a.nodeType !== null && isAtomicRef(a.nodeType)) return true;
			cur = a;
		} else if (cur.kind === NodeKind.HiddenDeref) {
			const e = (cur.data as HiddenDerefData).expr;
			if (e !== null && e.nodeType !== null && isAtomicRef(e.nodeType)) return true;
			cur = e;
		} else {
			break;
		}
	}
	return false;
}

function reportArcWrite(ctx: CheckerContext, target: Node): void {
	addError(ctx, "cannot write through 'Arc<T>' — SHARE is immutable; shared mutable state is Locked<T> (PARALOCK Amendment I)",
		target.location.line, target.location.column);
}

// Phase 4: invalidateFacts / factReferencesVar deleted.
// Assignments that invalidate narrowing now flow through the binder's
// FlowAssignment node + getFlowTypeOfReference. Per-use-site queries see
// the post-assignment flow state naturally — no fact stack to purge.





// ===== Expression Checker =====




export function checkExpr(ctx: CheckerContext, node: Node, expectedType: Type | null): void {
	if (node === null) return;
	if ((node.flags & NodeFlag.Sem) !== 0 && node.nodeType !== null) return;
	if (isCancelled(ctx.cancelCtx, ctx.cancelVersion)) { node.nodeType = errorType(); return; }
	checkExprInner(ctx, node, expectedType);
	node.flags = node.flags | NodeFlag.Sem;
}


function reportUnconsumedJsx(ctx: CheckerContext, node: Node, what: string, expectedType: Type | null): void {
	if (ctx.jsxMacroArgDepth === 0) {
		let msg = what + " must be consumed by a macro (it produces a compile-time Node)";
		if (expectedType !== null && !isUnresolvedType(expectedType)) {
			msg = msg + "; import a converter targeting '" + typeDisplayName(expectedType) + "' to lower it at this boundary";
		}
		addError(ctx, msg, node.location.line, node.location.column);
	}
}

// Converter boundary lowering (LANG-JSX.md): JSX at a settled expected-runtime-type position
// rewrites in place into a MacroInvocation of the in-scope converter for that target, then
// re-checks — the eager-expansion branch expands and re-checks against the same expected type.
// Never fires inside macro args (jsxMacroArgDepth) or where no expected type is settled.
function tryConverterAtBoundary(ctx: CheckerContext, node: Node, expectedType: Type | null): boolean {
	if (expectedType === null) return false;
	if (isUnresolvedType(expectedType) || expectedType.kind === TypeKind.GenericParam) return false;
	if (ctx.jsxMacroArgDepth > 0) return false;
	const targetName = typeDisplayName(expectedType);
	let convName: string | null = null;
	if (ctx.converterTargets.has(targetName)) {
		convName = ctx.converterTargets.get(targetName);
	} else {
		// Name fast-path missed (non-nominal target: alias of function/union/
		// primitive). Nim's dest-side rule is resolved-type identity — typeRel
		// in {isEqual} (userConvMatch, sigmatch.nim:2316) — so walk the
		// registered targets in order and compare with sameType.
		for (const key of ctx.converterTargetKeys) {
			const cand = ctx.converterTargets.get(key);
			if (cand === null) continue;
			const targetType = ctx.converterTargetTypes.get(cand);
			if (targetType === null) continue;
			if (sameType(targetType, expectedType)) { convName = cand; break; }
		}
	}
	if (convName === null) return false;
	if (!ctx.macroBodyRegistry.has(convName)) return false;
	const jsxArg = createNodeAt(node.kind, node.data, node.location);
	jsxArg.typeExpr = node.typeExpr;
	node.kind = NodeKind.MacroInvocation;
	node.data = { macroName: convName, macroArgs: [jsxArg] };
	node.nodeType = null as unknown as Type;
	node.resolvedSym = null;
	node.flags = 0;
	checkExpr(ctx, node, expectedType);
	return true;
}

// Record the JSX tag's base name as a symbol reference for LSP go-to-def / rename. An uppercase
// tag is a component reference (binds to the function symbol); a lowercase tag is a platform
// string (no binding). node.typeExpr is the positioned Identifier the parser stored for the tag.
function recordJsxTagSym(ctx: CheckerContext, node: Node): void {
	if (node.typeExpr === null) return;
	const base = (node.typeExpr.data as IdentifierData).name;
	if (base.byteLength === 0 || base.byteAt(0) < "A".code || base.byteAt(0) > "Z".code) return;
	const sym = lookupSymbol(ctx.table, base);
	if (sym === null) return;
	node.typeExpr.resolvedSym = sym;
	const loc = node.typeExpr.location;
	sgRecordSym(ctx, loc.line, loc.column, loc.column + base.byteLength, sym, sym.symbolType, sym.symbolKind, base, "", false);
}


// Internal: compute type for node. All match arms and sub-functions return Type.
function checkExprInner(ctx: CheckerContext, node: Node, expectedType: Type | null): void {
	const result = match (node.kind) {
		NodeKind.NumberLiteral => {
			reportLiteralRange(ctx, node);
			if (expectedType !== null && isIntegerType(expectedType)) {
				if (literalFitsInType(node, expectedType, false)) {
					node.nodeType = expectedType; return;
				} else if (isNodeIntLit(node)) {
					// Reference parity: standard reference's type change diagnostic emits compile-time error for out-of-range literals
					const nd = node.data as NumberLiteralData;
					const shown = nd.outOfRangeText !== "" ? nd.outOfRangeText : int64ToDecimal(nd.intVal);
					addError(ctx, "cannot convert " + shown + " to " + typeDisplayName(expectedType), node.location.line, node.location.column);
					node.nodeType = expectedType; return;
				} else {
					node.nodeType = float64Type(); return;
				}
			} else if (expectedType !== null && (expectedType.kind === TypeKind.Float64 || expectedType.kind === TypeKind.Float32)) {
				node.nodeType = expectedType; return;
			} else if (expectedType !== null && expectedType.kind === TypeKind.Number) {
				node.nodeType = numberType(); return;
			} else if (expectedType !== null && expectedType.kind === TypeKind.Union) {
				// Mirror the StringLiteral/BooleanLiteral arms below: a numeric
				// member of the expected union types the literal, so `width: 400.0`
				// fits `float32 | string | null` (first numeric member wins).
				for (const child of expectedType.typeChildren) {
					if (child === null) continue;
					if (isIntegerType(child) && literalFitsInType(node, child, false)) {
						node.nodeType = child; return;
					}
					if (child.kind === TypeKind.Float64 || child.kind === TypeKind.Float32
						|| child.kind === TypeKind.Number) {
						node.nodeType = child; return;
					}
				}
				if (isNodeIntLit(node)) { node.nodeType = int32Type(); return; }
				node.nodeType = float64Type(); return;
			} else {
				// Default inference: integer literals → int32, float literals → float64
				if (isNodeIntLit(node)) { node.nodeType = int32Type(); return; }
				node.nodeType = float64Type(); return;
			}
		},
		NodeKind.BigIntLiteral => {
			node.nodeType = createPrimitive(TypeKind.BigInt);
			return;
		},
		NodeKind.StringLiteral => {
			// TypeScript parity: string literals get StringLiteral type when expectedType demands it
			if (expectedType !== null) {
				const sd = node.data as StringLiteralData;
				if (expectedType.kind === TypeKind.StringLiteral && expectedType.typeName === sd.value) {
					node.nodeType = expectedType; return;
				}
				if (expectedType.kind === TypeKind.Union) {
					for (const child of expectedType.typeChildren) {
						if (child !== null && child.kind === TypeKind.StringLiteral && child.typeName === sd.value) {
							node.nodeType = child; return;
						}
					}
					// All members are StringLiteral but value not found → type error
					let allStrLit = true;
					for (const child of expectedType.typeChildren) {
						if (child === null || child.kind !== TypeKind.StringLiteral) allStrLit = false;
					}
					if (allStrLit && expectedType.typeChildren.length > 0) {
						addError(ctx, `Type '"${sd.value}"' is not assignable to type '${typeDisplayName(expectedType)}'`, node.location.line, node.location.column);
						node.nodeType = stringType(); return;
					}
				}
			}
			node.nodeType = stringType(); return;
		},
		NodeKind.BooleanLiteral => {
			// TypeScript parity: boolean literals get BooleanLiteral type when expectedType demands it.
			// Required for discriminated union narrowing on `ok: true | false` discriminants.
			if (expectedType !== null) {
				const bd = node.data as BooleanLiteralData;
				if (expectedType.kind === TypeKind.BooleanLiteral
					&& booleanLiteralValue(expectedType) === bd.boolValue) {
					node.nodeType = expectedType; return;
				}
				if (expectedType.kind === TypeKind.Union) {
					for (const child of expectedType.typeChildren) {
						if (child !== null && child.kind === TypeKind.BooleanLiteral
							&& booleanLiteralValue(child) === bd.boolValue) {
							node.nodeType = child; return;
						}
					}
				}
			}
			node.nodeType = booleanType(); return;
		},
		NodeKind.NullLiteral => nullType(),
		NodeKind.RegexLiteral | NodeKind.QuoteExpr | NodeKind.JSXText => noneType(),
		// JSX is a compile-time `Node` (like quote {}) — typed unknown, consumed by a macro before
		// codegen. Still walk the embedded expressions/attribute values so their symbols resolve.
		NodeKind.JSXElement => {
			const d = node.data as JSXElementData;
			recordJsxTagSym(ctx, node);
			if (tryConverterAtBoundary(ctx, node, expectedType)) { return; }
			reportUnconsumedJsx(ctx, node, "JSX expression", expectedType);
			checkJsxConsumed(ctx, d.jsxAttrs);
			checkJsxConsumed(ctx, d.jsxChildren);
			node.nodeType = noneType(); return;
		},
		NodeKind.JSXFragment => {
			const d = node.data as JSXFragmentData;
			if (tryConverterAtBoundary(ctx, node, expectedType)) { return; }
			reportUnconsumedJsx(ctx, node, "JSX fragment", expectedType);
			checkJsxConsumed(ctx, d.jsxFragChildren);
			node.nodeType = noneType(); return;
		},
		NodeKind.JSXExpressionContainer => {
			const d = node.data as JSXExpressionContainerData;
			checkExpr(ctx, d.jsxExpr, null);
			node.nodeType = noneType(); return;
		},
		NodeKind.JSXAttribute => {
			const d = node.data as JSXAttributeData;
			checkExpr(ctx, d.jsxAttrValue, null);
			node.nodeType = noneType(); return;
		},
		NodeKind.JSXSpreadAttribute => {
			const d = node.data as JSXSpreadAttributeData;
			checkExpr(ctx, d.jsxSpreadArg, null);
			node.nodeType = noneType(); return;
		},
		NodeKind.ComptimeBlock => {
			// Eagerly fold @comptime block — mirrors Phase B+ macro eager
			// expansion below. Without this, `const X = @comptime { ... }`
			// fossilizes X's symbol type as `unknown`, emitting `void* X` in C
			// codegen, because the post-check evaluateComptimeBlocks pass
			// replaces the AST node AFTER the variable's symbol type is set.
			const expanded = callEvalComptimeBlock(node, ctx);
			let expandedValue = expanded;
			if (expanded.kind === NodeKind.SpliceMany && node !== ctx.stmtPosExpr) {
				expandedValue = unwrapSpliceManyAtExpr(ctx, node, expanded);
				if (expandedValue === null) { node.nodeType = errorType(); return; }
			}
			node.kind = expandedValue.kind;
			node.data = expandedValue.data;
			if (expandedValue.location !== null) node.location = expandedValue.location;
			node.nodeType = null as unknown as Type;
			node.resolvedSym = null;
			node.flags = 0;
			checkExpr(ctx, node, expectedType);
			node.nodeType = node.nodeType; return;
		},
		NodeKind.Identifier => {
			const d = node.data as IdentifierData;
			// Phase 5: `super` resolves to parent class via enclosing `this`'s
			// classType.typeExtra chain. Special-cased BEFORE lookupSymbol because
			// `super` is never a regular declared symbol.
			if (d.name === "super") {
				node.nodeType = resolveSuper(ctx, node); return;
			}
			// Enum member access is rewritten to a mangled Identifier ("E_M")
			// whose name is deliberately never bound in scope — its resolution
			// lives only on the inline resolvedSym. A re-check of injected
			// comptime/macro decls (resolvedSym preserved by cloneNodeForCheck)
			// must trust it rather than look the mangled name up and fail. A
			// normal identifier never arrives pre-tagged EnumMember.
			if (node.resolvedSym !== null && node.resolvedSym.symbolKind === SymbolKind.EnumMember) {
				node.nodeType = node.resolvedSym.symbolType; return;
			}
			// bindSym: the macro pre-bound this identifier in its own module's
			// scope — the user's scope must not re-resolve (or hijack) it.
			const sym = (node.flags & NodeFlag.BoundSym) !== 0 && node.resolvedSym !== null
				? node.resolvedSym
				: lookupSymbol(ctx.table, d.name);
			if (sym === null) {
					addError(ctx, `Undefined variable '${d.name}'`, node.location.line, node.location.column);
				node.nodeType = errorType(); return;
			}
			// Demand-driven: ensure the symbol's signature is resolved before using its type
			ensureShaped(sym, ctx);
			node.resolvedSym = sym;
			markUsed(sym);
			if (hasFlag(sym, SymbolFlag.ComptimeNodeAlias)) {
				addError(ctx, `'${d.name}' binds a compile-time JSX/Node and can only be consumed by a macro (e.g. element(${d.name})), not used as a runtime value`, node.location.line, node.location.column);
				node.nodeType = errorType(); return;
			}
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
			// Assignment LHS: return the declared type, not the flow-narrowed
			// one. Inside `if (x === null) { x = {...} }` the RHS otherwise
			// gets `null` as contextualType and falls through to anon-struct
			// synthesis instead of widening to x's declared type.
			if (ctx.initTracker.leftPartOfAsgn > 0) {
				node.nodeType = sym.symbolType;
				node.nodeType = sym.symbolType; return;
			}
			// Var (out/ref) params auto-deref on reads (reference parity: tyVar use).
			let readType = sym.symbolType;
			if (readType !== null && readType.kind === TypeKind.Var && readType.typeReturn !== null) {
				readType = readType.typeReturn;
			}
			node.nodeType = getFlowTypeOfReference(node, readType); return;
		},
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			// Ref parity: leftPartOfAsgn
			const isAsgn = d.operator === "=" || d.operator === "+=" || d.operator === "-=" ||
				d.operator === "*=" || d.operator === "/=" || d.operator === "%=" ||
				d.operator === "&&=" || d.operator === "||=" || d.operator === "??=";
			if (isAsgn && node !== ctx.stmtPosExpr) {
				addError(ctx, "assignment is a statement, not an expression - assign first, then use the variable: 'x = f(); while (x !== null) { ... }'", node.location.line, node.location.column);
			}
			if (isAsgn) {
				ctx.initTracker.leftPartOfAsgn = ctx.initTracker.leftPartOfAsgn + 1;
			}
			checkExpr(ctx, d.left, null);
			const leftType = d.left.nodeType;
			if (isAsgn) {
				ctx.initTracker.leftPartOfAsgn = ctx.initTracker.leftPartOfAsgn - 1;
			}
			// SHARE immutability (PARALOCK I): block writes reaching through an Arc handle
			if (isAsgn && writeThroughArc(d.left)) {
				reportArcWrite(ctx, d.left);
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
			const rhsGuarded = d.operator === "&&" || d.operator === "||" || d.operator === "??";
			if (rhsGuarded) ctx.condEvalDepth = ctx.condEvalDepth + 1;
			checkExpr(ctx, d.right, rightExpected);
			if (rhsGuarded) ctx.condEvalDepth = ctx.condEvalDepth - 1;
			let rightType = d.right.nodeType;
			if (d.operator === "=" && isObjectShapeMismatch(rightType, leftType)) {
				addError(ctx,
					"Type '" + typeDisplayName(rightType) + "' is not assignable to type '" + typeDisplayName(leftType) + "'"
						+ explainStructuralPrefix(rightType, leftType),
					d.right.location.line, d.right.location.column);
			}
			// Parity: standard reference node fitting — insert HiddenStdConv for narrowing assignment
			if (d.operator === "=" && leftType !== null) {
				d.right = fitNode(ctx, d.right, leftType, rightType);
			}
			// Null RHS routes through the same relation as literal-field init
			// (semAsgn→fitNode→typeRel parity, scoped to Null: no flow-narrowing
			// dependency, so the terminal fitNode scope is not re-opened).
			if (d.operator === "=" && leftType !== null && d.right.nodeType !== null
					&& d.right.nodeType.kind === TypeKind.Null
					&& !isUnresolvedType(leftType)
					&& leftType.kind !== TypeKind.Error
					&& !isAssignable(d.right.nodeType, leftType)) {
				addError(ctx,
					"Type 'null' is not assignable to type '" + typeDisplayName(leftType) + "'",
					d.right.location.line, d.right.location.column);
			}
			// Convention-based dynamic field write protocol:
			//   obj.foo = x  →  obj.setDynamicField("foo", x)
			// when:
			//   - foo is not a real field of obj's declared type, AND
			//   - obj's type has a registered extension `setDynamicField(this T, key: string, value: U): void`.
			// Mirrors the getDynamicField synthesis for reads and the
			// HashMap `m[k]=v` rewrite below. Compound ops (`+=`, etc.) are rejected
			// with a clear error since they need a read-modify-write cycle that the
			// protocol does not express.
			if (isAsgn && d.left.kind === NodeKind.MemberExpr
					&& d.left.nodeType !== null
					&& isUnresolvedType(d.left.nodeType)
					&& ctx.extensionRegistry !== null) {
				const md = d.left.data as MemberExprData;
				if (md.object.nodeType !== null && md.property !== "setDynamicField") {
					// Receiver-match against the un-peeled type (preserves Ref<T>
					// wrapping for reference types like JsonValue). Property-lookup
					// mirrors `checkMember`'s full chain: peel Alias/Ref/Struct/Union,
					// try `getProperty`, fall back to `lookupSymbol`+shape on the
					// type's name (the same "class-aware field delegation" path).
					// Skipping the fallback would mis-fire synthesis
					// on real fields like `MacroInvocationData.macroArgs` whose
					// alias isn't shaped until a read primes it.
					const recvType = md.object.nodeType;
					let probeType = recvType;
					let _peelHops = 0;
					while (_peelHops < 4) {
						_peelHops = _peelHops + 1;
						if (probeType.kind === TypeKind.Alias && probeType.typeReturn !== null) {
							probeType = probeType.typeReturn;
							continue;
						}
						if (probeType.kind === TypeKind.Ref && probeType.typeReturn !== null) {
							probeType = probeType.typeReturn;
							continue;
						}
						break;
					}
					const peeled = peelToStructOrUnion(probeType);
					if (peeled !== null) probeType = peeled;
					let propertyExists = !isUnresolvedType(getProperty(probeType, md.property))
						|| (probeType.typeNames !== null && probeType.typeNames.indexOf(md.property) >= 0);
					if (!propertyExists && probeType.typeName !== "") {
						const classSym = lookupSymbol(ctx.table, probeType.typeName);
						if (classSym !== null) {
							ensureShaped(classSym, ctx);
							let classStruct = classSym.symbolType;
							if (classStruct !== null && classStruct.kind === TypeKind.Alias && classStruct.typeReturn !== null) {
								classStruct = classStruct.typeReturn;
							}
							if (classStruct !== null && classStruct.kind === TypeKind.Ref && classStruct.typeReturn !== null) {
								classStruct = classStruct.typeReturn;
							}
							if (classStruct !== null && (classStruct.kind === TypeKind.Struct || classStruct.kind === TypeKind.Union)) {
								if (!isUnresolvedType(getProperty(classStruct, md.property))) {
									propertyExists = true;
								}
							}
						}
					}
					// Last-resort fallback: shape the receiver's source symbol if reachable.
					// `recvType.sym` carries the declaration site for alias parameters even
					// when typeName was lost. This shapes `MacroInvocationData` to its inner
					// record BEFORE we declare the field missing — matching how a prior read
					// would have primed the alias on the same parameter.
					if (!propertyExists && recvType.sym !== null) {
						ensureShaped(recvType.sym, ctx);
						let symType = recvType.sym.symbolType;
						let _h = 0;
						while (symType !== null && _h < 4) {
							_h = _h + 1;
							if (symType.kind === TypeKind.Alias && symType.typeReturn !== null) { symType = symType.typeReturn; continue; }
							if (symType.kind === TypeKind.Ref && symType.typeReturn !== null) { symType = symType.typeReturn; continue; }
							break;
						}
						if (symType !== null && (symType.kind === TypeKind.Struct || symType.kind === TypeKind.Union)
								&& !isUnresolvedType(getProperty(symType, md.property))) {
							propertyExists = true;
						}
					}
					if (!propertyExists) {
						const setExts = findAllExtensionsByName(ctx.extensionRegistry, "setDynamicField");
						// Stricter receiver match: a `setDynamicField` ext only matches
						// when its declared `receiverTypeName` lines up with the actual
						// receiver's name (or its un-peeled alias). The generic
						// `findFirstMatchingExt` is too permissive — when the ext's
						// receiver type is parameterized (Ref<...>), unification can bind
						// against unrelated types and yield false positives that would
						// route ordinary field writes through the protocol.
						let extMatch = false;
						if (setExts.length > 0) {
							const recvNames: string[] = [];
							if (recvType.typeName !== "") recvNames.push(recvType.typeName);
							if (probeType.typeName !== "" && probeType.typeName !== recvType.typeName) recvNames.push(probeType.typeName);
							if (recvType.sym !== null && recvType.sym.name !== "") {
								let alreadyIn = false;
								for (const n of recvNames) { if (n === recvType.sym.name) alreadyIn = true; }
								if (!alreadyIn) recvNames.push(recvType.sym.name);
							}
							for (const e of setExts) {
								if (e.receiverTypeName === "") continue;
								for (const rn of recvNames) {
									if (e.receiverTypeName === rn) { extMatch = true; break; }
								}
								if (extMatch) break;
							}
						}
						if (extMatch) {
							if (d.operator !== "=") {
								const lhsRead = d.operator.slice(0, d.operator.length - 1);
								addError(ctx,
									`compound assignment '${d.operator}' is not supported on dynamic field '${md.property}'; rewrite as 'expr.${md.property} = expr.${md.property} ${lhsRead} value'`,
									node.location.line, node.location.column);
								node.nodeType = errorType(); return;
							}
							const keyLit = createNodeAt(NodeKind.StringLiteral, { value: md.property }, node.location);
							const wargs: Node[] = [];
							wargs.push(keyLit);
							wargs.push(d.right);
							node.nodeType = rewriteAsMethodCall(ctx, node, md.object, "setDynamicField", wargs); return;
						}
					}
				}
			}
			// Strings are immutable at the surface (docs/STRING-CONTRACT.md);
			// the byte-mutation story is the uint8[] buffer tier.
			if (isAsgn && d.left.kind === NodeKind.ArrayAccess) {
				const sad = d.left.data as ArrayAccessData;
				let strObjType = sad.array.nodeType;
				if (strObjType !== null && strObjType.kind === TypeKind.Ref && strObjType.typeReturn !== null) {
					strObjType = strObjType.typeReturn;
				}
				if (strObjType !== null && isStringLike(strObjType)) {
					addError(ctx, "strings are immutable - mutate bytes via uint8[] (asBytes/asString) instead",
						node.location.line, node.location.column);
					node.nodeType = errorType(); return;
				}
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
				// cstring is an immutable FFI bridge — caller must materialise a
				// `string` before mutating bytes. Nim parity (jsgen.nim:1285).
				if (setObjType !== null && setObjType.kind === TypeKind.CString) {
					addError(ctx, "cstring doesn't support `[]=` operator — convert to string first",
						node.location.line, node.location.column);
					node.nodeType = errorType(); return;
				}
				if (setObjType !== null && setObjType.kind === TypeKind.GenericInstance
					&& isIndexableMapType(setObjType)) {
					const wargs: Node[] = [];
					wargs.push(ad.index);
					wargs.push(d.right);
					node.nodeType = rewriteAsMethodCall(ctx, node, ad.array, "set", wargs); return;
				}
			}
			// Ref parity: initVar on assignment LHS
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
				&& isNodeIntLit(d.right) && literalFitsInType(d.right, leftType!, false)) {
				effRight = leftType;
				d.right.nodeType = leftType;
			} else if (isIntegerType(rightType) && leftType !== null
				&& isNodeIntLit(d.left) && literalFitsInType(d.left, rightType!, false)) {
				effLeft = rightType;
				d.left.nodeType = rightType;
			}
			// Bitwise ops require integer operands (reference parity: no float overloads)
			// Insert implicit number → int32 cast for C backend
			if ((isUnknownType(effLeft) || isUnknownType(effRight))
				&& d.operator !== "=" && d.operator !== "===" && d.operator !== "!=="
				&& d.operator !== "==" && d.operator !== "!="
				&& d.operator !== "&&" && d.operator !== "||" && d.operator !== "??"
				&& d.operator !== "&&=" && d.operator !== "||=" && d.operator !== "??=") {
				addError(ctx, "operator '" + d.operator + "' cannot be applied to 'unknown' — narrow with an explicit cast", node.location.line, node.location.column);
			}
			if (isBitwiseBinaryOp(d.operator)) {
				checkBitwiseOperands(ctx, d.operator, effLeft!, effRight!, node);
				if (effLeft !== null && effLeft.kind === TypeKind.Number) {
					d.left = wrapInConv(d.left, createPrimitive(TypeKind.Int32));
					effLeft = createPrimitive(TypeKind.Int32);
				}
				if (effRight !== null && effRight.kind === TypeKind.Number) {
					d.right = wrapInConv(d.right, createPrimitive(TypeKind.Int32));
					effRight = createPrimitive(TypeKind.Int32);
				}
			}
			if (d.operator === "+" && effLeft !== null && effRight !== null) {
				if (effLeft.kind === TypeKind.CString && isStringLike(effRight)) {
					d.left = wrapInConv(d.left, stringType());
					effLeft = stringType();
				}
				if (effRight.kind === TypeKind.CString && isStringLike(effLeft)) {
					d.right = wrapInConv(d.right, stringType());
					effRight = stringType();
				}
			}
			if ((d.operator === "+" || d.operator === "+=") && effLeft !== null && effRight !== null) {
				if (isStringLike(effLeft) && !isStringLike(effRight)) {
					const convRight = synthStringify(ctx, d.right);
					if (convRight !== null) {
						d.right = convRight;
						effRight = stringType();
					}
				} else if (d.operator === "+" && isStringLike(effRight) && !isStringLike(effLeft)) {
					const convLeft = synthStringify(ctx, d.left);
					if (convLeft !== null) {
						d.left = convLeft;
						effLeft = stringType();
					}
				}
			}
			const isArithmeticOp = d.operator === "+" || d.operator === "-" || d.operator === "*"
				|| d.operator === "/" || d.operator === "%" || d.operator === "**";
			if (isArithmeticOp && effLeft !== null && effRight !== null
				&& (!isNumeric(effLeft) || !isNumeric(effRight))
				&& !isStringLike(effLeft) && !isStringLike(effRight)
				&& ctx.extensionRegistry !== null) {
				const opExt = resolveOperatorCall(ctx.table, ctx.extensionRegistry, d.operator, [effLeft, effRight]);
				if (opExt !== null) {
					const opFnType = getExtFnType(opExt);
					if (opFnType !== null && opFnType.typeReturn !== null) {
						node.nodeType = opFnType.typeReturn; return;
					}
				}
			}
			const isRelational = d.operator === "<" || d.operator === ">" || d.operator === "<=" || d.operator === ">=";
			const isConcat = d.operator === "+" && (isStringLike(effLeft) || isStringLike(effRight));
			if ((isArithmeticOp || isRelational) && !isConcat
				&& (isMaybeType(effLeft) || isMaybeType(effRight))) {
				const maybeSide = isMaybeType(effLeft) ? effLeft : effRight;
				const innerName = maybeSide.typeReturn !== null ? typeDisplayName(maybeSide.typeReturn) : "T";
				addError(ctx, "operand of '" + d.operator + "' is possibly null (" + innerName + " | null) — unwrap with '!', '??', or a null check first", node.location.line, node.location.column);
				node.nodeType = isRelational ? booleanType() : ((maybeSide.typeReturn !== null) ? maybeSide.typeReturn : inferredType());
				return;
			}
			if (rejectBigIntMix(ctx, d.operator, effLeft, effRight, node)) { node.nodeType = errorType(); return; }
			node.nodeType = inferBinaryOp(d.operator, effLeft!, effRight!);
			if (d.operator === "??" && node.nodeType !== null && isMaybeType(node.nodeType)) {
				d.right = fitJoinedBranch(ctx, d.right, node.nodeType);
			}
			return;
		},
		NodeKind.UnaryExpr => {
			const d = node.data as UnaryExprData;
			// Propagate expectedType through unary +/- for literal coercion (e.g., -128 → int8)
			const unaryExpected = (d.unaryOp === "-" || d.unaryOp === "+") ? expectedType : null;
			if (d.unaryOp === "-" && isNodeIntLit(d.operand)
				&& unaryExpected !== null && isIntegerType(unaryExpected)) {
				checkNegatedIntLiteral(ctx, d.operand, unaryExpected);
				node.nodeType = unaryExpected;
				return;
			}
			checkExpr(ctx, d.operand, unaryExpected);
			const operandType = d.operand.nodeType;
			if (d.unaryOp === "+" && operandType !== null && operandType.kind === TypeKind.BigInt) {
				addError(ctx, "unary '+' is not allowed on bigint — use Number(b) to convert", node.location.line, node.location.column);
				node.nodeType = errorType(); return;
			}
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
			if ((d.unaryOp === "-" || d.unaryOp === "+" || d.unaryOp === "!" || d.unaryOp === "~")
				&& operandType !== null && !isNumeric(operandType) && !isStringLike(operandType)
				&& ctx.extensionRegistry !== null) {
				const unExt = resolveOperatorCall(ctx.table, ctx.extensionRegistry, d.unaryOp, [operandType]);
				if (unExt !== null) {
					const unFnType = getExtFnType(unExt);
					if (unFnType !== null && unFnType.typeReturn !== null) {
						node.nodeType = unFnType.typeReturn; return;
					}
				}
			}
			node.nodeType = inferUnaryOp(d.unaryOp, operandType!); return;
		},
		NodeKind.UpdateExpr => {
			const d = node.data as UpdateExprData;
			checkExpr(ctx, d.updateArg, null);
			if (writeThroughArc(d.updateArg)) {
				reportArcWrite(ctx, d.updateArg);
			}
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
			if (d.updateArg.nodeType !== null && (isNumeric(d.updateArg.nodeType) || d.updateArg.nodeType.kind === TypeKind.BigInt)) { node.nodeType = d.updateArg.nodeType; return; }
			node.nodeType = int32Type(); return;
		},
		NodeKind.CallExpr => checkCallExpr(ctx, node, expectedType),
		NodeKind.MemberExpr => checkMemberExpr(ctx, node, expectedType),
		NodeKind.ArrayAccess => {
			const d = node.data as ArrayAccessData;
			// Defensive: malformed ArrayAccess may have null d.array (e.g. macro
			// VM round-trip lost the field). Convert null deref into diagnostic.
			if (d.array === null) {
				addError(ctx, "internal: ArrayAccess with null array sub-expression", node.location.line, node.location.column);
				node.nodeType = errorType(); return;
			}
			checkExpr(ctx, d.array, null);
			let arrType = d.array.nodeType;
			// The index is a READ even when the ArrayAccess is on an assignment
			// LHS (`a[i] = v`). leftPartOfAsgn suppresses flow narrowing for the
			// assignment target, but the index sub-expression must still narrow
			// (else a value-Maybe index keeps its carrier type → codegen mixes
			// struct and payload). Reset around the index check only.
			if (d.index !== null) {
				const savedLpa = ctx.initTracker.leftPartOfAsgn;
				ctx.initTracker.leftPartOfAsgn = 0;
				checkExpr(ctx, d.index, null);
				ctx.initTracker.leftPartOfAsgn = savedLpa;
			}
			// Array sub-expr may have null nodeType when a macro expansion
			// returns an Identifier whose lookup hasn't repopulated the
			// symbol's type yet. Diagnostic instead of null deref.
			if (arrType === null) {
				addError(ctx, "internal: array type unresolved in ArrayAccess (child kind=" + d.array.kind + ")", node.location.line, node.location.column);
				node.nodeType = errorType(); return;
			}
			// Enum reverse index E[v]: TS numeric-enum reverse mapping, value → member-name string.
			// Base must be the enum TYPE symbol itself (not a value of enum type).
			if (d.array.kind === NodeKind.Identifier && d.array.resolvedSym !== null
					&& d.array.resolvedSym.symbolKind === SymbolKind.Enum) {
				const revIdxType = d.index !== null ? d.index.nodeType : null;
				if (revIdxType === null || !(isNumeric(revIdxType) || revIdxType.kind === TypeKind.Enum)) {
					addError(ctx, "enum reverse index '" + typeDisplayName(arrType) + "[...]' expects a numeric or enum operand", node.location.line, node.location.column);
					node.nodeType = errorType(); return;
				}
				node.nodeType = stringType(); return;
			}
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
				const memberData: NodeData = { object: d.array, property: "get", isOptional: false };
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
				node.nodeType = checkCallExpr(ctx, node, null); return;
			}
			// reference array: deref Ref<Array> so element-type + nativeLower/codegen see the value array
			if (arrType.kind === TypeKind.Ref && arrType.typeReturn !== null && arrType.typeReturn.kind === TypeKind.Array) {
				const drefTok = createToken(TokenKind.Ident, "", node.location.line);
				const drefNode = createNode(NodeKind.HiddenDeref, { expr: d.array }, drefTok);
				drefNode.nodeType = arrType.typeReturn;
				d.array = drefNode;
				arrType = arrType.typeReturn;
			}
			const idxType = d.index.nodeType;
			// Implicit number → int64 cast for array index (C requires integer subscript)
			if (idxType !== null && idxType.kind === TypeKind.Number && d.index.kind !== NodeKind.BinaryExpr) {
				d.index = wrapInConv(d.index, createPrimitive(TypeKind.Int64));
			}
			// Range access: arr[start..end] returns Span<elemType>
			let accessType: Type = inferredType();
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
			} else if (arrType.kind === TypeKind.Tuple && d.index.kind === NodeKind.NumberLiteral
					&& arrType.typeChildren !== null) {
				const idx = (d.index.data as NumberLiteralData).value;
				accessType = (idx >= 0 && idx < arrType.typeChildren.length)
					? arrType.typeChildren[idx] : inferredType();
			} else {
				accessType = getElementType(arrType);
			}
			node.nodeType = accessType;
			node.nodeType = accessType; return;
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
			// Unwrap Maybe<T> for inner shape matching — `{ kind: 7 }` flowing into
			// a `Token | null` slot matches Token's fields, not Maybe<Token>'s
			// `{ value, present }` wrapper. fitNode at the call site inserts the
			// wrap after this node is shape-checked. Mirrors the Ref/Union peels above.
			if (objExpected !== null && isMaybeType(objExpected) && objExpected.typeReturn !== null) {
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
				keysArr.nodeType = createRef(createArray(mapKeyType));
				keysArr.flags = keysArr.flags | NodeFlag.Sem;
				// 3. Build values array — reuse the already-checked property nodes.
				const valNodes: Node[] = [];
				let vi = 0;
				while (vi < d.properties.length) {
					valNodes.push(d.properties[vi]);
					vi = vi + 1;
				}
				const valsArr = createNode(NodeKind.ArrayLiteral, { elements: valNodes }, mtok);
				valsArr.nodeType = createRef(createArray(mapValType));
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
				node.nodeType = checkCallExpr(ctx, node, objExpected); return;
			}
			// Unwrap GenericInstance (e.g., Result<T, E>) to inner Struct or Union.
			// Walk through typeReturn (eagerly instantiated body) or typeExtra
			// (unsubstituted base) until we reach a Struct or Union. Handle nested
			// GenericInstance (e.g., MyResult<T, E> = Ref<MyData<T, E>> where MyData
			// is itself generic) by recursing through GI/Ref wrappers.
			objExpected = peelToStructOrUnion(objExpected);
			// A generic-containing expected type (un-instantiated formal like
			// `{ v: T }` at a call site whose T is still unbound) must NOT be
			// adopted: stamping it makes the literal's type identical to the
			// formal, so unifyType's identity check derives zero bindings and
			// the generic is never instantiated (loud missing-symbol C error),
			// while the literal's fields emit as void*. Fall through to the
			// self-synthesized anonymous struct — unification against the formal
			// then binds T from the literal's own concrete field types.
			if (objExpected !== null && objExpected.kind === TypeKind.Struct
				&& objExpected.typeChildren !== null
				&& !hasGenericParams(objExpected)) {
				// Reference parity: stamp literal with expected type, propagate field types
				// For class types, keep Ref wrapper so codegen knows to heap-allocate.
				// Skip ownership modifiers (Sink/Lent/Var) — transparent for codegen.
				let stampType = skipModifier(expectedType);
				// Maybe<T> override: when expected is Maybe<T>, the literal's natural
				// shape is the inner T (matched against T's fields above via the peel).
				// Stamp the inner T so fitNode at the call site detects the T → Maybe<T>
				// gap and inserts the wrap. Without this, node.nodeType = Maybe<T>
				// short-circuits fitNode's same-kind check and no wrap is emitted —
				// codegen then writes the literal's T-shape fields into Maybe<T>'s slot.
				if (stampType !== null && isMaybeType(stampType)) {
					stampType = objExpected;
				}
				node.nodeType = (stampType !== null) ? stampType : objExpected;
				// Pin to consts so the inner while-loop body sees non-null typeNames/
				// typeChildren — flow narrowing on `let objExpected` doesn't reach
				// inside nested loops via the binder's current narrowing rules.
				const objE = objExpected;
				const objNames = objE.typeNames;
				const objChildren = objE.typeChildren;
				const containerName = objE.typeName !== null ? objE.typeName : "";
				// Record the literal's own contextual type so the LSP can complete its
				// fields wherever it sits — argument, return, nested — instead of
				// climbing to an annotated VariableDecl that may not exist.
				sgRecordSym(ctx, node.location.line, node.location.column, node.location.column + 1,
					null, objE, SymbolKind.Interface, "", containerName, false);
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
					// Engine (macro-body) view of Node.nodeType, write position: macros
					// stamp type-AST Nodes into emitted literals (`nodeType: ft`), so the
					// slot expects a Node VALUE — Ref<Node>, matching the read override in
					// checkMemberExpr — not the checker Type the class declares.
					if (fieldExpected !== null && isEngineCheckMode()
							&& keyName === "nodeType" && containerName === "Node") {
						fieldExpected = (expectedType !== null && typeNameOf(expectedType) === "Node")
							? expectedType
							: objE;
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
						if (!isUnresolvedType(fe)
								&& !isUnresolvedType(propActual)
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
							let found = false;
							let ni = 0;
							while (ni < objNames.length) {
								if (objNames[ni] === key) { found = true; break; }
								ni = ni + 1;
							}
							if (!found && engineNodeHasVirtualKey(objE, key)) found = true;
							if (!found) {
								if (d.keyLocations !== null && ki < d.keyLocations.length) {
									const kl = d.keyLocations[ki];
									addErrorRange(ctx, "'" + key + "' does not exist in type '" + containerName + "'", kl.line, kl.column, kl.column + key.length);
								} else {
									addError(ctx, "'" + key + "' does not exist in type '" + containerName + "'", node.location.line, node.location.column);
								}
							}
							// Check duplicate: same key appeared earlier
							let di = 0;
							while (di < ki) {
								if (d.keys[di] === key) {
									if (d.keyLocations !== null && ki < d.keyLocations.length) {
										const kl = d.keyLocations[ki];
										addErrorRange(ctx, "field initialized twice: '" + key + "'", kl.line, kl.column, kl.column + key.length);
									} else {
										addError(ctx, "field initialized twice: '" + key + "'", node.location.line, node.location.column);
									}
									break;
								}
								di = di + 1;
							}
						}
						ki = ki + 1;
					}
				}
				// Nim parity (semobjconstr.nim collectMissingFields): a missing field is
				// default-initialized UNLESS its type requiresInit. A function field's zero
				// is NULL, and calling NULL is a segfault, so it has no valid default —
				// declare it `T | null` to opt out and handle the null.
				if (objNames !== null) {
					let hasDynamicKey = false;
					for (const k of d.keys) {
						if (k === "..." || k === "__computed__") hasDynamicKey = true;
					}
					if (!hasDynamicKey) {
						let mi = 0;
						while (mi < objNames.length) {
							const wantT = mi < objChildren.length ? objChildren[mi] : null as unknown as Type;
							if (wantT !== null && wantT.kind === TypeKind.Function) {
								const want = objNames[mi];
								let present = false;
								for (const k of d.keys) { if (k === want) { present = true; break; } }
								if (!present) {
									addError(ctx, `field '${want}' must be initialized: type '${typeDisplayName(wantT)}' has no default value`, node.location.line, node.location.column);
								}
							}
							mi = mi + 1;
						}
					}
				}
				node.nodeType = node.nodeType; return;
			} else if (objExpected !== null && objExpected.kind === TypeKind.Union
				&& isDiscriminatedUnion(objExpected)) {
				// Discriminated union construction validation
				// Pass original expectedType so Ref wrapper is preserved for codegen heap-alloc
				node.nodeType = checkDiscriminatedConstruction(ctx, node, d, objExpected, expectedType); return;
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
					// Check property CLONES without expectedType to get actual types — purely
					// for variant selection. Original properties stay unchecked so the
					// contextual second pass (line ~795) types them cleanly with the
					// variant's field expected type. Same `cloneNodeForCheck` pattern as
					// `cloneDefaultNode` (line ~1356): exploratory check on a clone leaves
					// the live AST untouched, avoiding double-insert of HiddenDeref /
					// coercion nodes that `checkExpr` is not idempotent against.
					if (varIdx >= 0 && d.keys.length > 0 && isAmbiguousVariant(objExpected, varIdx, d.keys)) {
						const propTypes: Type[] = [];
						let pi = 0;
						while (pi < d.properties.length) {
							const probe = cloneNodeForCheck(d.properties[pi]);
							checkExpr(ctx, probe, null);
							propTypes.push(probe.nodeType);
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
				node.nodeType = objExpected; return;
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
				node.nodeType = anonType; return;
			}
		},
		NodeKind.ArrayLiteral => {
			const d = node.data as ArrayLiteralData;
			// Reference parity: semArrayConstr does expectedType.skipTypes(abstractRange)
			// which strips Sink/Lent/Var wrappers before checking Array kind
			let arrExpected = skipModifier(expectedType);
			// `T[] | null` (TS nullable array): the literal checks against the array
			// member and the surrounding fit wraps it — the union counterpart of the
			// Ref<Array> peel below, so it runs first and hands that peel its member.
			// Without it an empty [] keeps an inferred element type all the way into
			// the emission gate.
			if (arrExpected !== null && arrExpected.kind === TypeKind.Union
					&& arrExpected.typeChildren !== null && arrExpected.typeChildren.length === 2) {
				const ua = arrExpected.typeChildren[0];
				const ub = arrExpected.typeChildren[1];
				const uNonNull = (ua !== null && ub !== null && ub.kind === TypeKind.Null) ? ua
					: ((ua !== null && ub !== null && ua.kind === TypeKind.Null) ? ub : null);
				if (uNonNull !== null
						&& (uNonNull.kind === TypeKind.Array || uNonNull.kind === TypeKind.SizedArray
							|| (uNonNull.kind === TypeKind.Ref && uNonNull.typeReturn !== null
								&& uNonNull.typeReturn.kind === TypeKind.Array))) {
					arrExpected = uNonNull;
				}
			}
			// reference array: an expected Ref<Array<T>> checks the literal against the
			// inner value array, but tags the result Ref so nativeLower boxes it onto the heap.
			let refArrayWrap: Type | null = null;
			if (arrExpected !== null && arrExpected.kind === TypeKind.Ref && arrExpected.typeReturn !== null
					&& arrExpected.typeReturn.kind === TypeKind.Array) {
				refArrayWrap = arrExpected;
				arrExpected = arrExpected.typeReturn;
			}
			// Tuple context: a bracket literal in tuple position is a tuple, not an array.
			// Type each element against its positional type and tag the node Tuple — else it
			// defaults to Ref<Array> and mismatches the expected tuple (e.g. `return [a, b]`
			// for a `[T, U]` return type errors "expected Tuple, got Array"). Sibling of the
			// Array / SizedArray / Ref<Array> contextual cases below.
			if (arrExpected !== null && arrExpected.kind === TypeKind.Tuple && arrExpected.typeChildren !== null) {
				for (let ti = 0; ti < d.elements.length; ti += 1) {
					const te = ti < arrExpected.typeChildren.length ? arrExpected.typeChildren[ti] : null;
					checkExpr(ctx, d.elements[ti], te);
					if (te !== null) d.elements[ti] = fitNode(ctx, d.elements[ti], te, d.elements[ti].nodeType);
				}
				node.nodeType = arrExpected;
				return;
			}
			const elemExpected = (arrExpected !== null
				&& (arrExpected.kind === TypeKind.Array || arrExpected.kind === TypeKind.SizedArray
					|| arrExpected.kind === TypeKind.Span)
				&& arrExpected.typeReturn !== null)
				? arrExpected.typeReturn
				: null;
			if (d.elements.length === 0) {
				if (arrExpected !== null && (arrExpected.kind === TypeKind.SizedArray || arrExpected.kind === TypeKind.Array)) {
					node.nodeType = refArrayWrap !== null ? refArrayWrap : arrExpected; return;
				} else if (elemExpected !== null) {
					node.nodeType = createRef(createArray(elemExpected)); return;
				} else {
					node.nodeType = createRef(createArray(inferredType())); return;
				}
			} else {
				for (let i = 0; i < d.elements.length; i += 1) {
					checkExpr(ctx, d.elements[i], elemExpected);
					if (elemExpected !== null) {
						if (isObjectShapeMismatch(d.elements[i].nodeType, elemExpected)) {
							addError(ctx,
								"Type '" + typeDisplayName(d.elements[i].nodeType) + "' is not assignable to element type '" + typeDisplayName(elemExpected) + "'"
									+ explainStructuralPrefix(d.elements[i].nodeType, elemExpected),
								d.elements[i].location.line, d.elements[i].location.column);
						}
						d.elements[i] = fitNode(ctx, d.elements[i], elemExpected, d.elements[i].nodeType);
					}
				}
				let elemType = d.elements[0].nodeType;
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
				if (elemExpected === null && d.elements.length > 1
					&& !(elemType !== null && isAwaitable(elemType))) {
					const elemJoinTypes: Type[] = [];
					for (const el of d.elements) elemJoinTypes.push(el.nodeType);
					const joinedElem = joinBranchTypes(elemJoinTypes);
					if (!isUnresolvedType(joinedElem)) {
						let fi = 0;
						while (fi < d.elements.length) {
							d.elements[fi] = fitJoinedBranch(ctx, d.elements[fi], joinedElem);
							fi = fi + 1;
						}
						elemType = joinedElem;
					}
				}
				// Reference parity (semArrayConstr): error only on too-many elements.
				// Too-few is allowed at literal level; type compatibility catches mismatches.
				if (arrExpected !== null && arrExpected.kind === TypeKind.SizedArray) {
					const expectedLen = arrExpected.typeFlags;
					if (d.elements.length > expectedLen) {
						addError(ctx, `Fixed-size array expects at most ${expectedLen} element(s), got ${d.elements.length}`, node.location.line, node.location.column);
					}
					node.nodeType = refArrayWrap !== null ? refArrayWrap : arrExpected; return;
				} else if (arrExpected !== null && arrExpected.kind === TypeKind.Array && !hasGenericParams(arrExpected)) {
					node.nodeType = refArrayWrap !== null ? refArrayWrap : arrExpected; return;
				} else {
					// No array context: a bare `[...]` literal is a reference array (T[] = Ref<Array>),
					// so nativeLower boxes it and it matches T[] params/returns post-flip.
					node.nodeType = refArrayWrap !== null ? refArrayWrap : createRef(createArray(elemType)); return;
				}
			}
		},
		NodeKind.ArrowFunction => checkArrowExpr(ctx, node, expectedType),
		NodeKind.FunctionExpr => checkFuncExpr(ctx, node, expectedType),
		NodeKind.ConditionalExpr => {
			const d = node.data as ConditionalExprData;
			checkExpr(ctx, d.ternaryCondition, null);
			ctx.condEvalDepth = ctx.condEvalDepth + 1;
			checkExpr(ctx, d.ternaryConsequent, expectedType);
			checkExpr(ctx, d.ternaryAlternate, expectedType);
			ctx.condEvalDepth = ctx.condEvalDepth - 1;
			if (expectedType !== null) {
				d.ternaryConsequent = fitNode(ctx, d.ternaryConsequent, expectedType, d.ternaryConsequent.nodeType);
				d.ternaryAlternate = fitNode(ctx, d.ternaryAlternate, expectedType, d.ternaryAlternate.nodeType);
			} else {
				retypeEmptyArrayBranch(d.ternaryConsequent, d.ternaryAlternate.nodeType);
				retypeEmptyArrayBranch(d.ternaryAlternate, d.ternaryConsequent.nodeType);
				const joined = joinBranchTypes([d.ternaryConsequent.nodeType, d.ternaryAlternate.nodeType]);
				if (!isUnresolvedType(joined)) {
					d.ternaryConsequent = fitJoinedBranch(ctx, d.ternaryConsequent, joined);
					d.ternaryAlternate = fitJoinedBranch(ctx, d.ternaryAlternate, joined);
					node.nodeType = joined; return;
				}
			}
			node.nodeType = d.ternaryConsequent.nodeType; return;
		},
		NodeKind.TypeAssertion => {
			let d = node.data as TypeAssertionData;
			// Non-null assertion `expr!` (sentinel asType "!"): strip the nullable
			// from the operand type; nullableLower rule 1c reads `.value` at codegen.
			if (d.asType === "!") {
				checkExpr(ctx, d.asExpr, null);
				const st0 = d.asExpr.nodeType;
				if (st0 !== null && isMaybeType(st0) && st0.typeReturn !== null) {
					node.nodeType = st0.typeReturn;
				} else if (st0 !== null && st0.kind === TypeKind.Union && unwrapRefNullUnion(st0) !== null) {
					node.nodeType = unwrapRefNullUnion(st0);
				} else {
					node.nodeType = st0 !== null ? st0 : inferredType();
				}
				node.flags = node.flags | NodeFlag.Sem;
				return;
			}
			const asLoc = node.typeExpr !== null ? node.typeExpr.location : node.location;
			const targetType = (d.asType !== "") ? resolveAnnotation(d.asType, ctx, asLoc.line, asLoc.column) : inferredType();
			// TS parity: `expr as T` propagates T as contextual type to expr.
			// Critical for object literals: `{ a: 1 } as Foo` must construct a Foo
			// (not an anonymous struct that codegen then can't cast to Foo).
			// `as unknown` is a type-system escape hatch — don't use it as context.
			const innerExpected = (!isUnresolvedType(targetType)) ? targetType : null;
			checkExpr(ctx, d.asExpr, innerExpected);
			let srcType = d.asExpr.nodeType;
			// Record type annotation position for LSP
			resolveTypeExpr(node.typeExpr, ctx);
			// General rule: `expr as unknown as T` → collapse to `expr as T`.
			// `as unknown` is a TS type-system escape hatch with zero runtime meaning.
			// Unwrap it so downstream handlers see the real source expression/type.
			if (!isUnresolvedType(targetType)) {
				const innerExpr = unwrapAsUnknown(d.asExpr);
				if (innerExpr !== null) {
					node.data = { asExpr: innerExpr, asType: d.asType };
					d = node.data as TypeAssertionData;
					srcType = innerExpr.nodeType;
				}
			}
			// Nil typing: collapse `null as T` into typed NullLiteral.
			if (!isUnresolvedType(targetType) && targetType.kind !== TypeKind.Null
				&& d.asExpr !== null && d.asExpr.kind === NodeKind.NullLiteral) {
				node.kind = NodeKind.NullLiteral;
				node.data = { nullPlaceholder: true };
				node.nodeType = targetType;
				node.flags = node.flags | NodeFlag.Sem;
				node.nodeType = targetType; return;
			}
			// String↔CString needs runtime conversion at the FFI boundary, not erasure.
			else if (srcType !== null
				&& ((targetType.kind === TypeKind.CString
						&& (srcType.kind === TypeKind.String || srcType.kind === TypeKind.StringLiteral))
					|| (targetType.kind === TypeKind.String && srcType.kind === TypeKind.CString))) {
				node.kind = NodeKind.HiddenStdConv;
				node.data = { convExpr: d.asExpr, convType: targetType };
				node.nodeType = targetType;
				node.flags = node.flags | NodeFlag.Sem;
				node.nodeType = targetType; return;
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
			const castSrcUnknown = (srcType !== null && srcType.kind === TypeKind.Union) ? unwrapRefNullUnion(srcType) : srcType;
			if (castSrcUnknown !== null && isUnknownType(castSrcUnknown)
				&& !isUnresolvedType(targetType) && !isPointerShapedForUnknown(targetType)) {
				addError(ctx, "cannot cast unknown to value type " + typeDisplayName(targetType) + " — no void* representation to reinterpret", asLoc.line, asLoc.column);
			}
			node.nodeType = node.nodeType; return;
		},
		NodeKind.SpreadExpr => {
			const d = node.data as SpreadExprData;
			checkExpr(ctx, d.spreadArg, null);
			node.nodeType = inferredType(); return;
		},
		NodeKind.NewExpr => checkNewExpr(ctx, node, expectedType),
		NodeKind.TryExpr => checkTryExpr(ctx, node),
		NodeKind.MatchExpr => checkMatchExpr(ctx, node, expectedType),
		NodeKind.AwaitExpr => {
			const d = node.data as AwaitExprData;
			checkExpr(ctx, d.awaitArg, null);
			const argType = d.awaitArg.nodeType;
			if (argType !== null && isAwaitable(argType)) {
				const promiseInner = awaitedType(argType);
				node.nodeType = promiseInner !== null ? promiseInner : inferredType();
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
				node.nodeType = node.nodeType; return;
			}
			node.nodeType = inferredType(); return;
		},
		NodeKind.YieldExpr => {
			const d = node.data as YieldExprData;
			checkExpr(ctx, d.yieldArg, null);
			node.nodeType = inferredType(); return;
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
			node.nodeType = d.moveArg.nodeType; return;
		},
		NodeKind.OutExpr => {
			const d = node.data as OutExprData;
			checkExpr(ctx, d.outArg, null);
			node.nodeType = d.outArg.nodeType; return;
		},
		NodeKind.SizeofExpr => {
			const d = node.data as SizeofExprData;
			const resolved = resolveAnnotation(d.sizeofType, ctx, 0, 0);
			resolveTypeExpr(node.typeExpr, ctx);
			// Generic operand: leave unfolded so mono substitutes sizeofType→concrete, then the instance re-check folds the real size.
			if (resolved.kind === TypeKind.GenericParam) { node.nodeType = int32Type(); return; }
			const size = sizeOfType(resolved);
			node.kind = NodeKind.NumberLiteral;
			node.data = { value: size } as unknown as NodeData;
			node.nodeType = int32Type(); return;
		},
		NodeKind.HiddenDeref => {
			const d = node.data as HiddenDerefData;
			checkExpr(ctx, d.expr, null);
			if (node.nodeType === null) {
				const inner = d.expr.nodeType;
				node.nodeType = (inner !== null && inner.kind === TypeKind.Ref && inner.typeReturn !== null)
					? inner.typeReturn
					: inner;
			}
			return;
		},
		NodeKind.HiddenAddr => {
			const d = node.data as HiddenDerefData;
			checkExpr(ctx, d.expr, null); node.nodeType = d.expr.nodeType; return;
		},
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => {
			const d = node.data as HiddenStdConvData;
			checkExpr(ctx, d.convExpr, null);
			node.nodeType = d.convType; return;
		},
		NodeKind.MacroInvocation => {
			// Implementation parity: pragma/macro args are type-checked
			const md = node.data as MacroInvocationData;
			// reference parity: @emit backtick interpolation (reference emit processing)
			if (md.macroName === "emit") {
				processEmitInterpolation(ctx, node);
			}
			// @import args are pure syntax (not evaluated) — skip type-checking
			foldComptimeNodeAliasArgs(ctx, md.macroArgs);
			if (md.macroName !== "import") { checkJsxConsumed(ctx, md.macroArgs); }
			// SERIALIZE Bug 8: deferred user macros expand eagerly when re-checked
			// with concrete types. After mono clones a generic body, replaceTypeVars
			// substitutes T→concrete in arg.nodeType. The re-check then hits this
			// MacroInvocation with concrete args and must expand — otherwise the
			// surrounding ReturnStmt/VariableDecl gets voidType, breaking the
			// declared-return-type assignability check.
			//
			// Mirrors the CallExpr eager path. Only fires for
			// user macros (in registry); builtin directives (emit, include, ...)
			// keep the voidType behavior. If args still contain GenericParam
			// (defer convention), return inferredType — let the next mono level
			// or post-mono expand pass handle it.
			if (ctx.macroBodyRegistry.has(md.macroName)) {
				if (ctx.macroExpansionDepth >= 16) {
					addError(ctx, "macro expansion depth limit (16) exceeded for '" + md.macroName + "' — possible recursive macro",
						node.location.line, node.location.column);
					node.nodeType = errorType(); return;
				}
				if (anyArgIsParametric(md.macroArgs)) { node.nodeType = inferredType(); return; }
				ctx.macroExpansionDepth = ctx.macroExpansionDepth + 1;
				const expanded = callExpandMacroInvocation(node, ctx, 0);
				// When a user macro emits a sentinel error (or VM fails),
				// expandMacroInvocation returns the SAME MacroInvocation node and
				// has already called addError. Re-checking would route back into
				// this same branch and re-fire the macro, multiplying the error
				// up to the depth limit and finally emitting a misleading
				// "possible recursive macro" warning. Detect by kind preservation.
				if (expanded.kind === NodeKind.MacroInvocation) {
					ctx.macroExpansionDepth = ctx.macroExpansionDepth - 1;
					node.nodeType = errorType(); return;
				}
				let expandedValue = expanded;
				if (expanded.kind === NodeKind.SpliceMany && node !== ctx.stmtPosExpr) {
					expandedValue = unwrapSpliceManyAtExpr(ctx, node, expanded);
					if (expandedValue === null) {
						ctx.macroExpansionDepth = ctx.macroExpansionDepth - 1;
						node.nodeType = errorType(); return;
					}
				}
				node.kind = expandedValue.kind;
				node.data = expandedValue.data;
				if (expandedValue.location !== null) node.location = expandedValue.location;
				node.nodeType = null as unknown as Type;
				node.resolvedSym = null;
				node.flags = 0;
				checkExpr(ctx, node, expectedType);
				ctx.macroExpansionDepth = ctx.macroExpansionDepth - 1;
				node.nodeType = node.nodeType; return;
			}
			node.nodeType = voidType(); return;
		},
		_ => inferredType(),
	};
	node.nodeType = result;
}


// Phase 5: resolve `super` identifier to the parent class symbol.
// `super` is only valid inside an instance method (where "this" is in scope).
// Walks: this → enclosing class type → typeExtra → parent class.
// Sets node.resolvedSym to the parent class symbol so codegen can emit the
// correct `ParentClassName_new` call. Returns parent class type.
// Errors if used outside a method, in a static method, or if the enclosing
// class has no `extends` clause.
function resolveSuper(ctx: CheckerContext, node: Node): Type {
	const thisSym = lookupSymbol(ctx.table, "this");
	if (thisSym === null || thisSym.symbolType === null) {
		addError(ctx, "'super' is only valid inside an instance method or constructor", node.location.line, node.location.column);
		return errorType();
	}
	let classType = thisSym.symbolType;
	if (classType.kind === TypeKind.Ref && classType.typeReturn !== null) {
		classType = classType.typeReturn;
	}
	if (classType.kind !== TypeKind.Struct || classType.typeExtra === null) {
		addError(ctx, "'super' requires the enclosing class to have an 'extends' clause", node.location.line, node.location.column);
		return errorType();
	}
	let parentType = classType.typeExtra;
	if (parentType.kind === TypeKind.Ref && parentType.typeReturn !== null) {
		parentType = parentType.typeReturn;
	}
	const parentName = parentType.typeName;
	if (parentName === "") {
		addError(ctx, "'super' parent class has no resolvable name", node.location.line, node.location.column);
		return errorType();
	}
	const parentSym = lookupSymbol(ctx.table, parentName);
	if (parentSym === null) {
		addError(ctx, "'super' parent class '" + parentName + "' not found", node.location.line, node.location.column);
		return errorType();
	}
	ensureShaped(parentSym, ctx);
	node.resolvedSym = parentSym;
	return parentSym.symbolType;
}
// ===== rewriteAsMethodCall — In-place rewrite to method call =====
// Mutates `node` to a CallExpr that invokes `receiver.methodName(args)`. Used
// by commit-style desugaring sites that have already verified the rewrite
// should happen (e.g., `m[k]=v` → `m.set(k, v)` and `obj.foo=x` →
// `obj.setDynamicField("foo", x)`). After mutation, checkCallExpr resolves
// the extension method and validates argument types. Returns the call's
// inferred type.
function rewriteAsMethodCall(ctx: CheckerContext, node: Node, receiver: Node, methodName: string, args: Node[]): Type {
	const tok = createToken(TokenKind.Ident, "", node.location.line);
	const member: NodeData = { object: receiver, property: methodName, isOptional: false };
	const memberNode = createNode(NodeKind.MemberExpr, member, tok);
	node.kind = NodeKind.CallExpr;
	node.data = {
		callee: memberNode,
		arguments: args,
		isDirectCall: true,
		resolvedOverloadIdx: -1,
	};
	node.flags = node.flags & ~NodeFlag.Sem;
	node.nodeType = null;
	return checkCallExpr(ctx, node, null);
}


// ===== Callee Name Extraction =====


// ===== Default Parameter Filling =====





// ===== NewExpr =====



// ===== TryExpr =====



// ===== Call Expression + Overload Resolution =====




















// ===== Inheritance Depth (inline — avoids importing symbol.ms in compat.ms) =====



// ===== Member Expression + Extension Method Resolution =====








// ===== Match Expression =====





// ===== Anonymous Functions =====

export function checkAnonymousFunction(ctx: CheckerContext, name: string, params: string[], paramTypes: string[], body: Node, paramLocs: SourceLocation[], returnTypeAnnotation: string, expectedType: Type | null, fnFlags: string): Type {
	const isAsync = fnFlags === "async" || fnFlags === "async_generator" || (fnFlags !== "" && fnFlags.indexOf("async") >= 0);
	const savedReturn = ctx.inferredReturn;
	ctx.inferredReturn = inferredType();
	const savedReturnStmts = ctx.inferredReturnStmts;
	ctx.inferredReturnStmts = [];
	const savedMatchDepth = ctx.matchExprDepth;
	ctx.matchExprDepth = 0;

	// Contextual param types from expectedType (e.g. callback signature at the call site).
	// Used when the user wrote untyped params: `arr.forEach(n => f(n))` — `n` typed by callee.
	// IMPORTANT: only param types are contextually inferred. Return type is still inferred
	// from body, because contextual return types may be generic (`() => T`) and would shadow
	// the concrete inference from the body that downstream passes (lambda lifting) rely on.
	let ctxParamTypes: Type[] = null as unknown as Type[];
	// A `fn | null` formal is a Maybe struct — peel it so the arrow is typed from the inner fn.
	let fnExpected = expectedType;
	if (fnExpected !== null && isMaybeType(fnExpected) && fnExpected.typeReturn !== null) {
		fnExpected = fnExpected.typeReturn;
	}
	if (fnExpected !== null && fnExpected.kind === TypeKind.Function && fnExpected.typeChildren !== null) {
		ctxParamTypes = fnExpected.typeChildren;
	}

	// Body's expected return type. Sources, in priority order:
	//   1. Explicit annotation on the arrow (`(): T => ...`)
	//   2. Bug G — contextual fallback from caller's expectedType when concrete
	//   3. None (null) — body inference drives the result
	// Var stays named `explicitReturnType` for historical reasons; treat it as
	// "body-expected return" past this point (drives ReturnStmt check via
	// ctx.currentFunction.symType.typeReturn at line ~4297 below).
	let explicitReturnType: Type = null as unknown as Type;
	// Source 1: semProcAux parity — annotation takes precedence.
	if (returnTypeAnnotation !== "" && returnTypeAnnotation !== "void") {
		explicitReturnType = resolveAnnotation(returnTypeAnnotation, ctx, 0, 0);
	}
	// Source 2: Bug G — contextual return-type fallback. When the user writes
	// neither an explicit annotation nor `: void`, and the call site
	// (expectedType) gives us a CONCRETE function type with a fully-resolved
	// return type (no GenericParam children), use that as the body's expected
	// type so calls like `Result.ok(42)` in a field of type
	// `() => Result<int32, string>` get BOTH generic args bound from context.
	// Without this, only T gets bound from the argument (`42` → int32) while
	// E is left as GenericParam("E"), producing a half-resolved
	// `Result<int32, E>` that the lifter copies into the lifted FunctionDecl.
	// Codegen then bails at `hasGenericParams(fnType)` in declarations.ms and
	// the body is silently dropped, surfacing as a link error against
	// `dollarfn_<scope>_N_`.
	//
	// Guard: only when expectedType.typeReturn is itself concrete. If the
	// caller is generic and passing `() => T`, body inference must still
	// produce the concrete T from the body — propagating GenericParam back
	// in would defeat that.
	//
	// Divergence note: TS-parity, not Nim-parity. Nim's semProcAux
	// (semstmts.nim:2628) uses the lambda's OWN return type for body check
	// and relies on overload resolution at the call site to bind generic
	// args. MS uses contextual typing here for symmetry with how param
	// types are inferred from expectedType just above.
	if (explicitReturnType === null && returnTypeAnnotation === ""
		&& fnExpected !== null
		&& fnExpected.kind === TypeKind.Function
		&& fnExpected.typeReturn !== null
		&& !isUnresolvedType(fnExpected.typeReturn)
		&& !hasGenericParams(fnExpected.typeReturn)) {
		explicitReturnType = fnExpected.typeReturn;
	}

	const savedFunction = ctx.currentFunction;
	// Set explicit return type on function symbol BEFORE checking body, so return
	// statements can use it as expectedType (semProcAux parity: annotation propagates)
	const fnSymType = explicitReturnType !== null ? createFunction([], [], explicitReturnType) : inferredType();
	const sym = makeSymbol(name, SymbolKind.Function, fnSymType, false);
	if (isAsync) setFlag(sym, SymbolFlag.Async);
	ctx.currentFunction = sym;
	openScope(ctx.table, ScopeKind.Function);
	let pi = 0;
	for (const p of params) {
		let pType = inferredType();
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
		let bodyExpected = explicitReturnType;
		if (isAsync && bodyExpected !== null) {
			const unwrapped = awaitedType(bodyExpected);
			if (unwrapped !== null) bodyExpected = unwrapped;
		}
		checkExpr(ctx, body, bodyExpected);
		const exprType = body.nodeType;
		if (ctx.inferredReturn.kind === TypeKind.Inferred) {
			ctx.inferredReturn = exprType;
		}
	}
	closeScope(ctx.table);
	ctx.currentFunction = savedFunction;
	ctx.matchExprDepth = savedMatchDepth;

	const inferredRet = ctx.inferredReturn;
	for (const rs of ctx.inferredReturnStmts) {
		const rsd = rs.data as ReturnStmtData;
		if (rsd.argument !== null) rsd.argument = fitJoinedBranch(ctx, rsd.argument, inferredRet);
	}
	ctx.inferredReturn = savedReturn;
	ctx.inferredReturnStmts = savedReturnStmts;

	const types: Type[] = [];
	let ti = 0;
	for (const p of params) {
		let pType = inferredType();
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
	//
	// Use `createClosureType` (callConv = CcClosure) — Arrow/FunctionExpr in
	// expression position are *value-form* function literals: the runtime
	// representation is a closure pair {fn, env} (msClosure), not a raw
	// function pointer. Without the CcClosure flag, a downstream
	// `const cb = () => ...; cb()` call site reads the variable's Function
	// type with callConv=CcDefault, the checker's "is this a closure call?"
	// check (line ~1971) bails out, codegen emits a direct call against the
	// msClosure struct, and C rejects it with "called object type 'msClosure'
	// is not a function or function pointer". `fitNode`'s named-fn → closure
	// auto-wrap only fires for Identifier callees with SymbolKind.Function,
	// so it doesn't catch this case for inline expression-form functions.
	if (explicitReturnType !== null) {
		if (isAsync && returnTypeAnnotation !== "" && explicitReturnType.kind !== TypeKind.Void
			&& !isAwaitable(explicitReturnType)) {
			const got = typeDisplayName(explicitReturnType);
			addError(ctx,
				"async " + name + " must declare return type as Promise<" + got
					+ ">, not bare '" + got + "'",
				body.location.line, body.location.column);
		}
		return createClosureType(types, params, explicitReturnType);
	}
	if (returnTypeAnnotation === "void") {
		return createClosureType(types, params, isAsync ? createPromise(voidType()) : voidType());
	}
	if (!isUnresolvedType(inferredRet)) {
		const retT = isAsync && !isAwaitable(inferredRet) ? createPromise(inferredRet) : inferredRet;
		return createClosureType(types, params, retT);
	}
	return createClosureType(types, params, isAsync ? createPromise(voidType()) : voidType());
}

// TS-parity arity subsumption for LITERAL lambdas: a written arrow may declare
// FEWER params than the fn-typed slot it flows into (`fire(() => {...})` where
// fire: (h: (e: Ev) => void) => void). Nim rejects this (procTypeRel,
// sigmatch.nim:813 exact signatureLen) — DIVERGE-INTENTIONAL for TS semantics,
// literals only. Without padding the literal keeps its own short type, no
// conversion is ever materialized, and the C call site casts fn to the
// DECLARED slot signature (fnSlotReprMismatch invariant) → ABI mismatch,
// garbage frame, double-free in by-value struct destructors (bug118).
// Pad the literal's OWN param list with synthetic names left un-annotated so
// the ctxParamTypes fallback in checkAnonymousFunction types them from the
// formal — scope, lifter and codegen then all see the slot's full signature.
// Fn VALUES keep the strict isFunctionAssignable relation — loud mismatch.
// Only concrete tails pad: a generic/unresolved extra formal leaves the
// literal untouched (ec38c20 family — never bake half-resolved types).
function padLiteralParams(params: string[], paramTypes: string[], node: Node, expectedType: Type | null): void {
	if (expectedType === null) return;
	let fnExpected = expectedType;
	if (isMaybeType(fnExpected) && fnExpected.typeReturn !== null) {
		fnExpected = fnExpected.typeReturn;
	}
	if (fnExpected.kind !== TypeKind.Function || fnExpected.typeChildren === null) return;
	if (params.length >= fnExpected.typeChildren.length) return;
	let i = params.length;
	while (i < fnExpected.typeChildren.length) {
		const pt = fnExpected.typeChildren[i];
		if (pt === null || isUnresolvedType(pt) || pt.kind === TypeKind.GenericParam || hasGenericParams(pt)) return;
		i += 1;
	}
	while (paramTypes.length < params.length) {
		paramTypes.push("");
	}
	i = params.length;
	while (i < fnExpected.typeChildren.length) {
		params.push("__msPad" + String(i));
		paramTypes.push("");
		if (node.paramLocations !== null) {
			node.paramLocations.push(node.location);
		}
		i += 1;
	}
}

function checkArrowExpr(ctx: CheckerContext, node: Node, expectedType: Type | null): Type {
	const d = node.data as ArrowFunctionData;
	resolveTypeExpr(node.typeExpr, ctx);
	resolveTypeExprs(node.typeExprs, ctx);
	padLiteralParams(d.arrowParams, d.arrowParamTypes, node, expectedType);
	const fnType = checkAnonymousFunction(ctx, "<arrow>", d.arrowParams, d.arrowParamTypes, d.arrowBody, node.paramLocations!, d.arrowReturnType, expectedType, d.arrowFlags);
	// The implicit return of an expression body is a fit position like any
	// ReturnStmt (checkReturnStmt:1229) — reseat the body through fitNode so
	// no coercion (Maybe wrap, closure wrap) is forgotten.
	if (d.arrowBody !== null && d.arrowBody.kind !== NodeKind.BlockStmt
		&& fnType.typeReturn !== null && !isUnresolvedType(fnType.typeReturn)) {
		let returnExpected = fnType.typeReturn;
		if (d.arrowFlags === "async" || d.arrowFlags === "async_generator") {
			const unwrapped = awaitedType(returnExpected);
			if (unwrapped !== null) returnExpected = unwrapped;
		}
		d.arrowBody = fitNode(ctx, d.arrowBody, returnExpected, d.arrowBody.nodeType);
	}
	return fnType;
}

function checkFuncExpr(ctx: CheckerContext, node: Node, expectedType: Type | null): Type {
	const d = node.data as FunctionExprData;
	resolveTypeExpr(node.typeExpr, ctx);
	resolveTypeExprs(node.typeExprs, ctx);
	padLiteralParams(d.funcExprParams, d.funcExprParamTypes, node, expectedType);
	return checkAnonymousFunction(ctx, "(anon)", d.funcExprParams, d.funcExprParamTypes, d.funcExprBody, node.paramLocations!, d.funcExprReturnType, expectedType, d.funcExprFlags);
}

// ===== @emit Backtick Interpolation (reference emit processing parity) =====
// Scans a single string arg for `identifier` patterns, splits into multiple args:
// string literals for raw text, Identifier nodes for resolved symbols.


function processEmitInterpolation(ctx: CheckerContext, node: Node): void {
	const md = node.data as MacroInvocationData;
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


// ===== Actor Sendable Checker =====
// Enforces safe data transfer at actor method boundaries.
// Reuses: isPrimitiveKind, isStructType, SymbolFlag.Mutable, NodeKind.MoveExpr.




// ===== Spawn Borrow Checker =====
// Detects mutable variable captures in spawn closures — borrowed captures may dangle.



// ===== Actor Spawn Thunk Rules (PARALOCK Phase 6: S1/E61, S3/E62) =====
// Inside an actor method, a spawn thunk may borrow `this.f` read-only.
// Bare `this` / `this.<method>` re-enter a suspended actor (S1); writes
// rooted at `this` mutate frozen state (S3, deep — Pony box semantics).
// Descends into nested closures (same `this`); skips nested spawn thunks
// (each spawn call runs its own checkSpawnCaptures).









// ===== JSON Typed Specialization (reference-aligned: generate + check during sem) =====

import { callCheckFunctionBody } from "./checkerCallbacks";
import { addPendingInstance, instantiateClassConstructor, lookupCtorDefaults, pickBodyCtx } from "./instantiate";
import { getIdentId } from "./idents";
import { anyArgIsParametric, checkCallExpr, checkDiscriminatedConstruction, checkJsxConsumed, checkMatchExpr, checkMemberExpr, checkNewExpr, checkTryExpr, engineNodeHasVirtualKey, foldComptimeNodeAliasArgs, inheritContainerInfo, retypeEmptyArrayBranch, unwrapSpliceManyAtExpr } from "./callResolve";

// Lower-level: register a freshly-synthesized FunctionDecl as a root-scope symbol,
// re-check its body, and queue it for the next instantiation drain. Returns the
// symbol. No call-site rewrite — callers wire up `d.callee` themselves.
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


function createSyntheticToken(loc: SourceLocation): Token {
	return createToken(TokenKind.Ident, "", loc.line);
}


// Register callback at module load time
registerCheckExpr((ctx: CheckerContext, node: Node, expectedType: Type): void => { checkExpr(ctx, node, expectedType); });
