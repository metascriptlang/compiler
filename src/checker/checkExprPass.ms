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

// Extension receiver matching functions imported from context.ms (shared with LSP)

// Phase 4: invalidateFacts / factReferencesVar deleted.
// Assignments that invalidate narrowing now flow through the binder's
// FlowAssignment node + getFlowTypeOfReference. Per-use-site queries see
// the post-assignment flow state naturally — no fact stack to purge.

// Peel through Ref/Ptr to find a GenericInstance carrying type args.
// Used by `resolveGenericNewExpr` to read concrete type args from a contextual
// type annotation (`const m: Map<K, V> = new Map()`) when the user didn't
// spell `<K, V>` on the `new` itself.
function peelToGenericInstance(t: Type | null): Type | null {
	if (t === null) return null;
	let cur: Type = t;
	let depth: int32 = 0;
	while (cur !== null && depth < 8) {
		if (cur.kind === TypeKind.GenericInstance) return cur;
		if ((cur.kind === TypeKind.Ref || cur.kind === TypeKind.Ptr) && cur.typeReturn !== null) {
			cur = cur.typeReturn;
			depth = (depth + 1) as int32;
			continue;
		}
		break;
	}
	return null as unknown as Type;
}

// ===== Generic NewExpr Resolution =====
// Resolves `new Box<number>(42)` — captures type args from side-channel,
// records instantiation, and builds concrete Ref<Struct> type.
// Parity: standard reference object construction → type node captures type args.
//
// Type args come from one of three sources, in priority order:
//   1. Explicit `<...>` on the `new` expression itself.
//   2. The AST-resident `typeArg` (cloned bodies preserve this through
//      mono substitution; the location-keyed side channel can go stale).
//   3. Contextual type from a declaration annotation
//      (`const m: Map<K, V> = new Map()`) — TypeScript-style inference.
//      Without this, the user is forced to repeat type args on both
//      sides of the assignment, which is awkward for the common
//      Map/Set/Box patterns.
function resolveGenericNewExpr(ctx: CheckerContext, callee: Node, calleeType: Type, astTypeArg: string, expectedType: Type | null): Type {
	if (callee.kind !== NodeKind.Identifier) return calleeType;
	const calleeName = (callee.data as IdentifierData).name;
	const ltCol = callee.location.column + calleeName.length;
	const genericParams = getGenericDecl(calleeName);
	if (genericParams === "") return calleeType;
	// Try explicit type args first (sources 1 + 2 in priority comment above).
	let typeArgStr = astTypeArg;
	if (typeArgStr === "") {
		typeArgStr = getExplicitTypeArg(callee.location.line, ltCol);
	}
	let args: string[] = [];
	const paramNames = splitTopLevel(genericParams, ",");
	const trimmedParamNames: string[] = [];
	const concreteTypes: Type[] = [];
	let typeArgCol = ltCol + 1;
	if (typeArgStr !== "") {
		// Source 1/2 — explicit type args spelled by user.
		args = splitTopLevel(typeArgStr, ",");
		for (let pi = 0; pi < paramNames.length; pi += 1) {
			trimmedParamNames.push(paramNames[pi].trim());
			const argName = pi < args.length ? args[pi].trim() : "";
			const resolved = resolveAnnotation(argName, ctx, callee.location.line, typeArgCol);
			concreteTypes.push(resolved);
			if (argName !== "") {
				const typeArgSym = lookupSymbol(ctx.table, argName);
				if (typeArgSym !== null) {
					sgRecordSym(ctx, callee.location.line, typeArgCol, typeArgCol + argName.length, typeArgSym, typeArgSym.symbolType, typeArgSym.symbolKind, argName, "", false);
				}
				typeArgCol = typeArgCol + argName.length + 2;
			}
		}
	} else {
		// Source 3 — contextual inference. Peel `expectedType` (e.g.
		// `Ref<GenericInstance Map(string, Handler)>` from a `const m:
		// Map<string, Handler> = ...` annotation) and pull the concrete
		// type args out of `typeChildren`. Round-trip the names through
		// `monoConcreteTypeName` so the parser-side
		// `recordGenericTypeInstantiation` registry sees the same string
		// form it would have if the user had written `<...>` explicitly.
		const giCtx = peelToGenericInstance(expectedType);
		if (giCtx === null
				|| giCtx.typeName !== calleeName
				|| giCtx.typeChildren === null
				|| giCtx.typeChildren.length !== paramNames.length) {
			return calleeType;
		}
		for (let pi = 0; pi < paramNames.length; pi += 1) {
			trimmedParamNames.push(paramNames[pi].trim());
			concreteTypes.push(giCtx.typeChildren[pi]);
			args.push(monoConcreteTypeName(giCtx.typeChildren[pi]));
		}
	}
	recordGenericTypeInstantiation(calleeName, genericParams, args, ctx);
	const baseSym = lookupSymbol(ctx.table, calleeName);
	if (baseSym === null) return calleeType;
	ensureShaped(baseSym, ctx);
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
function retypeEmptyArrayBranch(branch: Node, otherType: Type | null): void {
	if (otherType === null || branch.kind !== NodeKind.ArrayLiteral) return;
	const d = branch.data as ArrayLiteralData;
	if (d.elements.length !== 0) return;
	let own = branch.nodeType;
	if (own !== null && own.kind === TypeKind.Ref) own = own.typeReturn;
	if (own === null || own.kind !== TypeKind.Array || own.typeReturn === null || own.typeReturn.kind !== TypeKind.Inferred) return;
	let other = otherType;
	if (other.kind === TypeKind.Ref && other.typeReturn !== null) other = other.typeReturn;
	if (other.kind !== TypeKind.Array || other.typeReturn === null || isUnresolvedType(other.typeReturn)) return;
	branch.nodeType = otherType;
}

// A macro builds its nodes without a position, and a `static` slot's C name is
// mangled from the declaration's line and column (codegen/c/names.ms) — so two
// expansions of the same macro would claim one slot and the C would not compile.
// The call site is what separates them, and it is also where a diagnostic about
// the hoisted statement should point.
export function stampCallSite(stmt: Node, loc: SourceLocation): void {
	if (stmt === null || loc === null) return;
	if (stmt.location !== null && stmt.location.line !== 0) return;
	stmt.location = loc;
	if (stmt.kind === NodeKind.VariableDecl) {
		const vd = stmt.data as VariableDeclData;
		vd.nameLocation = loc;
	}
}

// Last element is the value that replaces the call site; the ones before it are
// checked here (so the value can see what they declare) and hoisted into the
// enclosing statement list. Refusing a conditionally evaluated position is
// load-bearing: hoisting moves the prefix out of the guard that decides whether
// it runs at all. Returns null once an error has been reported.
function unwrapSpliceManyAtExpr(ctx: CheckerContext, node: Node, expanded: Node): Node {
	const d = expanded.data as SpliceManyData;
	if (d.spliceNodes.length === 0) {
		addError(ctx, "macro expanded to no value here: at an expression position the last element of SpliceMany is the value, and none was emitted",
			node.location.line, node.location.column);
		return null as unknown as Node;
	}
	if (ctx.condEvalDepth > 0) {
		addError(ctx, "macro emits statements at a conditionally evaluated position: they would run even when this branch does not — give the call its own statement",
			node.location.line, node.location.column);
		return null as unknown as Node;
	}
	const lastIdx = d.spliceNodes.length - 1;
	let i = 0;
	while (i < lastIdx) {
		const stmt = d.spliceNodes[i];
		stampCallSite(stmt, node.location);
		callCheckStmt(ctx, stmt);
		ctx.pendingHoisted.push(stmt);
		i = i + 1;
	}
	return d.spliceNodes[lastIdx];
}

export function checkExpr(ctx: CheckerContext, node: Node, expectedType: Type | null): void {
	if (node === null) return;
	if ((node.flags & NodeFlag.Sem) !== 0 && node.nodeType !== null) return;
	if (isCancelled(ctx.cancelCtx, ctx.cancelVersion)) { node.nodeType = errorType(); return; }
	checkExprInner(ctx, node, expectedType);
	node.flags = node.flags | NodeFlag.Sem;
}

// Walk `nodes` with the unconsumed-JSX leak check suppressed. A raw JSX node is legal as a
// macro argument (the macro consumes it) or as a child of a JSX node already accounted for by
// its parent — jsxMacroArgDepth > 0 marks both, so reportUnconsumedJsx stays silent inside.
function checkJsxConsumed(ctx: CheckerContext, nodes: Node[]): void {
	ctx.jsxMacroArgDepth = ctx.jsxMacroArgDepth + 1;
	// nodeTypeAst is only ever set from a node that was typed before a macro
	// round-trip (bridge valueToNode); re-checking such an arg re-infers from
	// scratch and types a collapsed null witness as bare `null`. Expansion
	// reads nodeTypeAst directly, and arg-position nodes die with the call
	// node once the macro expands — skipping loses nothing. Guard: bug092.
	for (const n of nodes) {
		if (n.nodeTypeAst !== null) continue;
		checkExpr(ctx, n, null);
	}
	ctx.jsxMacroArgDepth = ctx.jsxMacroArgDepth - 1;
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

function foldComptimeNodeAliasArgs(ctx: CheckerContext, args: Node[]): void {
	let i = 0;
	while (i < args.length) {
		const a = args[i];
		if (a.kind === NodeKind.Identifier) {
			const sym = lookupSymbol(ctx.table, (a.data as IdentifierData).name);
			if (sym !== null && hasFlag(sym, SymbolFlag.ComptimeNodeAlias) && sym.declNode !== null) {
				markUsed(sym);
				args[i] = cloneNodeForCheck(sym.declNode);
			}
		}
		i += 1;
	}
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
			// The literal is typed Int64, so a value outside int64 has no type to
			// live in. Rejecting it here keeps the C backend from forwarding the
			// `n` suffix to the C compiler as a syntax error in generated code.
			const bd = node.data as BigIntLiteralData;
			const digits = bd.bigintValue.slice(0, bd.bigintValue.byteLength - 1);
			if (!fitsInt64Decimal(digits, false)) {
				addError(ctx, "bigint literal " + digits + " does not fit int64 (arbitrary-precision bigint is not implemented yet)", node.location.line, node.location.column);
			}
			node.nodeType = createPrimitive(TypeKind.Int64);
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
			node.nodeType = getFlowTypeOfReference(node, sym.symbolType); return;
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
			if (d.updateArg.nodeType !== null && isNumeric(d.updateArg.nodeType)) { node.nodeType = d.updateArg.nodeType; return; }
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
			node.nodeType = inferredType(); return;
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

// True iff any arg's nodeType still carries a GenericParam — the marker
// for "this call lives inside an un-instantiated generic body". Drives
// the SERIALIZE A3 defer convention: macro invocations with parametric
// args wait for monomorphization to substitute concrete types, then
// re-check eagerly expands.
function anyArgIsParametric(args: Node[]): boolean {
	for (const arg of args) {
		if (arg.nodeType !== null && hasGenericParams(arg.nodeType)) return true;
	}
	return false;
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
	if (a.kind === TypeKind.Float32 && b.kind === TypeKind.Float32) return createPrimitive(TypeKind.Float32);
	return float64Type();
}

function widenBranchLiteral(t: Type): Type {
	if (t.kind === TypeKind.StringLiteral) return stringType();
	if (t.kind === TypeKind.BooleanLiteral) return booleanType();
	return t;
}

function branchContributesToJoin(t: Type | null): boolean {
	return t !== null && !isUnresolvedType(t)
		&& t.kind !== TypeKind.Never && t.kind !== TypeKind.Void
		&& t.kind !== TypeKind.Error;
}

function isNonOwningPointerKind(k: TypeKind): boolean {
	return k === TypeKind.Ptr || k === TypeKind.Cursor;
}

function isPointerKindJoinPair(a: Type, b: Type): boolean {
	if (a === null || b === null) return false;
	const cross = (a.kind === TypeKind.Ref && isNonOwningPointerKind(b.kind))
		|| (isNonOwningPointerKind(a.kind) && b.kind === TypeKind.Ref)
		|| (isNonOwningPointerKind(a.kind) && isNonOwningPointerKind(b.kind) && a.kind !== b.kind);
	if (!cross) return false;
	if (isAtomicRef(a) || isAtomicRef(b)) return false;
	if (a.typeReturn === null || b.typeReturn === null) return false;
	const pa = peelToStructOrUnion(a);
	const pb = peelToStructOrUnion(b);
	if (pa === null || pb === null) return false;
	if (pa.kind !== TypeKind.Struct && pa.kind !== TypeKind.Union) return false;
	return pa === pb || sameType(pa, pb);
}

function joinedPointerMember(existing: Type, incoming: Type): Type {
	return isNonOwningPointerKind(existing.kind) && incoming.kind === TypeKind.Ref ? incoming : existing;
}

export function joinBranchTypes(types: Type[]): Type {
	const prepared: Type[] = [];
	for (const t of types) {
		if (!branchContributesToJoin(t)) continue;
		const w = widenBranchLiteral(t);
		let dup = false;
		for (let pi = 0; pi < prepared.length; pi++) {
			const p = prepared[pi];
			if (p === w || sameType(p, w)) { dup = true; break; }
			if (isPointerKindJoinPair(p, w)) {
				prepared[pi] = joinedPointerMember(p, w);
				dup = true;
				break;
			}
		}
		if (!dup) prepared.push(w);
	}
	if (prepared.length === 0) return inferredType();
	if (prepared.length === 1) return prepared[0];
	let allNumeric = true;
	for (const p of prepared) {
		if (!isNumeric(p) && p.kind !== TypeKind.Enum) { allNumeric = false; break; }
	}
	if (allNumeric) {
		let acc = prepared[0].kind === TypeKind.Enum ? int32Type() : prepared[0];
		let ni = 1;
		while (ni < prepared.length) {
			let b = prepared[ni];
			if (b.kind === TypeKind.Enum) b = int32Type();
			acc = (isIntegerType(acc) && isIntegerType(b)) ? widenIntegers(acc, b) : promoteNumeric(acc, b);
			ni = ni + 1;
		}
		return acc;
	}
	return canonicalizeBranchJoin(unionOfTypes(prepared, null));
}

function canonicalizeBranchJoin(t: Type): Type {
	if (t === null || t.kind !== TypeKind.Union) return t;
	let sawNull = false;
	const nonNull: Type[] = [];
	for (const m of t.typeChildren) {
		if (m === null) continue;
		if (m.kind === TypeKind.Null) { sawNull = true; continue; }
		let member = m;
		if (isMaybeType(m) && m.typeReturn !== null) {
			sawNull = true;
			member = m.typeReturn;
		}
		let dup = false;
		for (let pi = 0; pi < nonNull.length; pi++) {
			const p = nonNull[pi];
			if (p === member || sameType(p, member)) { dup = true; break; }
			if (isPointerKindJoinPair(p, member)) {
				nonNull[pi] = joinedPointerMember(p, member);
				dup = true;
				break;
			}
		}
		if (!dup) nonNull.push(member);
	}
	if (!sawNull) return t;
	if (nonNull.length === 0) return nullType();
	if (nonNull.length === 1) {
		if (isMaybeWrappable(nonNull[0])) return createMaybeType(nonNull[0]);
		return createUnion([nonNull[0], nullType()]);
	}
	let allPrim = true;
	for (const m of nonNull) {
		if (!isPrimitiveUnionMember(m)) { allPrim = false; break; }
	}
	if (allPrim) return createMaybeType(createUnion(nonNull));
	const rebuilt: Type[] = [];
	for (const m of nonNull) rebuilt.push(m);
	rebuilt.push(nullType());
	return createUnion(rebuilt);
}

export function fitJoinedBranch(ctx: CheckerContext, expr: Node, joined: Type | null): Node {
	if (expr === null || joined === null || isUnresolvedType(joined)) return expr;
	const bt = expr.nodeType;
	if (bt === null || bt.kind === TypeKind.Never || bt.kind === TypeKind.Void || isUnresolvedType(bt)) return expr;
	if (bt === joined || sameType(bt, joined)) return expr;
	return fitNode(ctx, expr, joined, bt);
}

// Reference parity (sigmatch.nim:2596 `localConvMatch`, :2179 `implicitConv`): a
// stringification the call site needs is planted DURING checking, so it is bound
// by the same overload resolution a hand-written `x.toString()` gets and reaches
// codegen carrying its symbol. Returns null when nothing real binds — primitives
// and enums have no declaration and stay on the builtin-lowering path.
function synthStringify(ctx: CheckerContext, expr: Node): Node | null {
	const t = expr.nodeType;
	if (t === null) return null;
	const peeled = peelToStructOrUnion(t);
	if (peeled === null || peeled.kind !== TypeKind.Struct) return null;
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
	checkExpr(ctx, synthCall, null);
	const fits = ctx.errors.length === errMark;
	while (ctx.errors.length > errMark) { ctx.errors.pop(); }
	if (!fits) return null;
	if (synthCall.nodeType === null || !isStringLike(synthCall.nodeType)) return null;
	// The universal `.toString()` fallback mints a symbol with no declaration; it
	// is the shape that used to reach C codegen as a struct member call.
	if (synthCall.resolvedSym === null || synthCall.resolvedSym.declNode === null) return null;
	return synthCall;
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
			return inferredType();
		},
		"-" => {
			if (leftType !== null && leftType.kind === TypeKind.Ptr && rightType !== null && rightType.kind === TypeKind.Ptr) return int32Type();
			if (leftType !== null && leftType.kind === TypeKind.Ptr) return leftType;
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
			if (isMaybeType(leftType) && leftType.typeReturn !== null) {
				const joined = joinBranchTypes([leftType.typeReturn, rightType]);
				return isUnresolvedType(joined) ? leftType.typeReturn : joined;
			}
			if (leftType !== null && leftType.kind === TypeKind.Union) {
				const ptrMember = unwrapRefNullUnion(leftType);
				if (ptrMember !== null) {
					const joined = joinBranchTypes([ptrMember, rightType]);
					return isUnresolvedType(joined) ? leftType : joined;
				}
			}
			return leftType;
		},
		_ => inferredType(),
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
		_ => inferredType(),
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
function synthCStringConv(expr: Node, cstr: Type): Node {
	const tok = createToken(TokenKind.Ident, "", expr.location.line);
	const conv = createNode(NodeKind.HiddenStdConv, { convExpr: expr, convType: cstr } as unknown as NodeData, tok);
	conv.nodeType = cstr;
	conv.flags = conv.flags | NodeFlag.Sem;
	return conv;
}

function synthMaybeWrap(expr: Node, formal: Type, exprType: Type): Node {
	if (expr.kind === NodeKind.NullLiteral || exprType.kind === TypeKind.Null) {
		expr.nodeType = formal;
		return expr;
	}
	const wrapTok = createToken(TokenKind.Ident, "", expr.location.line);
	const presentLit = createNode(NodeKind.BooleanLiteral, { boolValue: true } as NodeData, wrapTok);
	presentLit.nodeType = booleanType();
	presentLit.flags = presentLit.flags | NodeFlag.Sem;
	const wrapped = createNode(NodeKind.ObjectLiteral, {
		properties: [expr, presentLit],
		keys: ["value", "present"],
		keyLocations: [expr.location, expr.location],
	} as NodeData, wrapTok);
	wrapped.nodeType = formal;
	wrapped.flags = wrapped.flags | NodeFlag.Sem;
	return wrapped;
}

// ===== Bitwise Operator Validation =====
// Reference parity: bitwise ops only have integer overloads. No float/double variants.
// Enums are integer-backed → allowed (Standard reference parity: enums can use bitwise ops).
// number (float64) → warning + implicit int32 cast (TypeScript ergonomics).

function isBitwiseBinaryOp(op: string): boolean {
	return op === "&" || op === "|" || op === "^" || op === "<<" || op === ">>" || op === ">>>";
}

function isBitwiseAllowed(t: Type | null): boolean {
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

// INT64_MIN is the one int64 that is its own negation.
function isInt64Min(v: int64): boolean {
	return v < 0 && ((0 - (v as uint64)) as int64) === v;
}

// Nim splits this in two. A BIT-PATTERN literal may fill the whole UNSIGNED
// width of its target and still be legal — `0x80` as int8 is -128, deliberately
// (lexer.nim:494-509). A DECIMAL literal is held to the target's SIGNED range
// (lexer.nim:536-548). `negated` is the unary minus the caller folded in: the
// token itself is always a magnitude, because the lexer never eats the sign.
function literalFitsInType(node: Node, target: Type, negated: boolean): boolean {
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
		TypeKind.Uint64 => !negated || mag === 0,
		_ => false,
	};
}

// The parser decides this on the digits: at the boundary the double in `value`
// cannot separate 2^64-1 from 2^64, and the position the diagnostic needs only
// exists here (parse errors carry line 0).
function reportLiteralRange(ctx: CheckerContext, node: Node): void {
	const text = (node.data as NumberLiteralData).outOfRangeText;
	if (text !== "") {
		addError(ctx, "number out of range: '" + text + "'", node.location.line, node.location.column);
	}
}

// A minus directly in front of a number literal belongs to that literal's range
// rule — Nim folds it onto the token in the lexer (lexer.nim:333). Checked here
// because the operand on its own is a magnitude and cannot tell the legal
// -9223372036854775808 from an int64 overflow.
function checkNegatedIntLiteral(ctx: CheckerContext, lit: Node, target: Type): void {
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
		_ => t.typeName !== ""
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
function trySynthesizeAsCoercion(ctx: CheckerContext, expr: Node, srcType: Type, targetType: Type): Node {
	if (ctx.extensionRegistry === null) return null as unknown as Node;
	// Nullable-ref target (`X | null`): coerce to the non-null member — the
	// synthesized X then flows into X|null via the normal member rule. Interface
	// members sit behind an unnamed Ref wrapper — peel it for the method name.
	if (targetType.kind === TypeKind.Union) {
		let nn = nonNullMemberOfNullable(targetType);
		if (nn !== null && (nn.kind === TypeKind.Ref || nn.kind === TypeKind.Ptr) && nn.typeReturn !== null) {
			nn = nn.typeReturn;
		}
		if (nn !== null && !isUnresolvedType(nn)) targetType = nn;
	}
	const methodName = coercionMethodName(targetType);
	if (methodName === "") return null as unknown as Node;
	const exts = findAllExtensionsByName(ctx.extensionRegistry, methodName);
	if (exts.length === 0) return null as unknown as Node;
	// Receiver and declared return may sit behind unnamed Ref wrappers
	// (interface values) — peel for matching, same as the target peel above.
	let srcForMatch = srcType;
	if ((srcForMatch.kind === TypeKind.Ref || srcForMatch.kind === TypeKind.Ptr) && srcForMatch.typeReturn !== null) {
		srcForMatch = srcForMatch.typeReturn;
	}
	const ext = findFirstMatchingExt(exts, srcForMatch);
	if (ext === null) return null as unknown as Node;
	// Verify return type matches target exactly (asInt32 vs asInt64 disambiguation).
	const extFnT = getExtFnType(ext);
	let extRet = extFnT.typeReturn;
	if (extRet !== null && (extRet.kind === TypeKind.Ref || extRet.kind === TypeKind.Ptr) && extRet.typeReturn !== null) {
		extRet = extRet.typeReturn;
	}
	if (extRet === null) return null as unknown as Node;
	if (extRet.kind !== targetType.kind) return null as unknown as Node;
	if (targetType.typeName !== "" && extRet.typeName !== targetType.typeName) {
		return null as unknown as Node;
	}
	const loc = expr.location;
	const memberNode = createNodeAt(NodeKind.MemberExpr,
		{ object: expr, property: methodName, isOptional: false }, loc);
	const synthCall = createNodeAt(NodeKind.CallExpr,
		{ callee: memberNode, arguments: [], isDirectCall: true, resolvedOverloadIdx: -1 }, loc);
	checkExpr(ctx, synthCall, null);
	if (synthCall.nodeType === null) return null as unknown as Node;
	if (synthCall.nodeType.kind === TypeKind.Error) return null as unknown as Node;
	if (isUnresolvedType(synthCall.nodeType)) return null as unknown as Node;
	return synthCall;
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

// ===== deriveCallBindings — Shared explicit+backward binding derivation =====
//
// Pre-arg-walk helper for generic calls. Computes Sources 1+2 only:
//   1. Explicit type args from the call node (`f<int32>(...)`).
//   2. Backward inference from caller's expectedType (return-type unify).
//
// Source 3 (forward inference from concrete arg types) stays at each
// call site since it accumulates during the arg loop.
//
// Used by checkCallExpr's non-overload arg-walk and resolveOverloadCall's
// Pass-2 winnerType substitution. Constructor path (checkNewExpr) uses
// a different shape (class generic decl, no return-unify) and stays
// inlined there.
function deriveCallBindings(
	ctx: CheckerContext,
	callNode: Node,
	calleeSym: Symbol | null,
	calleeType: Type,
	expectedType: Type | null,
): UnifyBindings {
	const bindings = createUnifyBindings();
	if (calleeSym !== null
		&& calleeSym.declNode !== null
		&& calleeSym.declNode.kind === NodeKind.FunctionDecl) {
		const names = extractGenericNames(getGenericDeclFlags(calleeSym.declNode));
		if (names.length > 0) {
			mergeUnifyBindings(bindings, bindFromExplicitTypeArgs(callNode, names, ctx));
		}
	}
	if (expectedType !== null && calleeType !== null && calleeType.typeReturn !== null) {
		const backBindings = createUnifyBindings();
		unifyType(calleeType.typeReturn, expectedType, backBindings);
		mergeUnifyBindings(bindings, backBindings);
	}
	return bindings;
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
	if (inner !== null && inner.kind === TypeKind.Ref) inner = inner.typeReturn;
	if (inner !== null && (inner.kind === TypeKind.Array || inner.kind === TypeKind.Span
			|| inner.kind === TypeKind.Ptr || inner.kind === TypeKind.SizedArray)) {
		return arrayDisplay(inner.typeReturn) + "[]";
	}
	return typeDisplayName(t);
}

// Index of `exprType` among a discriminated union's variants, or -1. Matches
// codegen's own rule (expressions.ms, "Variant struct → discriminated union")
// so the checker and the emitter agree on which slot a value belongs in.
// Non-struct member match. Refuses unions with a Null member (those are the
// Maybe/nilable family — synthMaybeWrap and nullableLower own them, and their C
// repr is not a tagged union) and all-string-literal unions (repr = msString).
function primitiveMemberIndexInUnion(formal: Type, exprType: Type): int32 {
	if (formal.kind !== TypeKind.Union || formal.typeChildren === null) return -1;
	const ek = exprType.kind;
	if (ek === TypeKind.Struct || ek === TypeKind.Union || ek === TypeKind.Null) return -1;
	let allStrLit = true;
	for (const child of formal.typeChildren) {
		if (child === null || child.kind === TypeKind.Null) return -1;
		if (child.kind !== TypeKind.StringLiteral) allStrLit = false;
	}
	if (allStrLit) return -1;
	let found: int32 = -1;
	let vi: int32 = 0;
	for (const child of formal.typeChildren) {
		let hit = child === exprType;
		if (!hit && child.kind !== TypeKind.Struct && child.kind !== TypeKind.Ref) {
			hit = child.kind === ek
				|| (child.kind === TypeKind.String && ek === TypeKind.StringLiteral);
		}
		if (hit) {
			if (found >= 0) return -1;
			found = vi;
		}
		vi += 1;
	}
	return found;
}

function variantIndexInUnion(formal: Type, exprType: Type): int32 {
	if (formal.kind !== TypeKind.Union || formal.typeChildren === null) return -1;
	if (exprType.kind !== TypeKind.Struct) return primitiveMemberIndexInUnion(formal, exprType);
	// Identity/name first; a named variant resolves there. Union variants are
	// often ANONYMOUS object types while the value carries a type ALIAS name
	// (`NodeData`'s variants vs `TypeUnionData`), so fall back to the same
	// structural match the object-literal path uses to pick its variant.
	const byIdentity = duVariantIndexOfType(formal, exprType) as int32;
	if (byIdentity >= 0) return byIdentity;
	const names = exprType.typeNames;
	if (names === null || names.length === 0) return -1;
	// EXACT field-set match only. findUnionVariant accepts a superset, which
	// picks the wrong slot when one variant's fields contain another's
	// (`{typExprMembers, …}` vs `{typExprMembers}` → tagged 76, held 77).
	// Two candidates that survive the type comparison are ambiguous: refuse
	// rather than guess a slot.
	const types = exprType.typeChildren;
	let found: int32 = -1;
	let vi: int32 = 0;
	for (const child of formal.typeChildren) {
		if (child !== null && child.typeNames !== null && child.typeNames.length === names.length) {
			let same = true;
			for (let fi = 0; fi < names.length; fi += 1) {
				if (child.typeNames[fi] !== names[fi]) { same = false; break; }
			}
			if (same && types !== null && child.typeChildren !== null
					&& child.typeChildren.length === types.length) {
				for (let fi = 0; fi < types.length; fi += 1) {
					const want = types[fi];
					const have = child.typeChildren[fi];
					if (want === null || have === null) continue;
					if (want.kind !== have.kind || want.typeName !== have.typeName) { same = false; break; }
				}
			}
			if (same) {
				if (found >= 0) return -1;
				found = vi;
			}
		}
		vi += 1;
	}
	return found;
}

// A variant value meeting a union formal needs a real conversion: the C layouts
// differ (variant = plain struct, union = tag + variant slots), and codegen
// picks a temp's type from the STATIC type — so without this node it passes a
// bare variant struct where the union is expected and clang only warns.
// Reference: sigmatch.nim implicitConv(nkHiddenSubConv, ...).
function widenVariantToUnion(expr: Node, formal: Type, exprType: Type): Node {
	if (unwrapRefNullUnion(formal) !== null) return null as unknown as Node;
	const valueType = unwrapRef(exprType);
	const vi = variantIndexInUnion(formal, valueType);
	if (vi < 0) return null as unknown as Node;
	const convTok = createToken(TokenKind.Ident, "", expr.location.line);
	// A union slot holds the variant BY VALUE, so a ref operand is READ and
	// copied, never consumed: handing the pointer to the conversion makes the
	// analyzer sink it (wasMoved) and the heap cell is then destroyed by
	// nobody. Spelling the deref keeps the ref owned by its own scope and
	// routes the payload through the ordinary value-copy path.
	let operand = expr;
	if (valueType !== exprType) {
		const drefNode = createNode(NodeKind.HiddenDeref, { expr: expr }, convTok);
		drefNode.nodeType = valueType;
		operand = drefNode;
	}
	const convNode = createNode(NodeKind.HiddenSubConv, { convExpr: operand, convType: formal }, convTok);
	convNode.nodeType = formal;
	// Same stamp convention as the object-literal path: codegen reads the slot,
	// it never re-derives one (+1 so 0 keeps meaning "not set").
	convNode.flags = convNode.flags | NodeFlag.Sem | (((vi + 1) as int32) << 16);
	return convNode;
}

// Declared (pre-narrowing) tagged union of a reference — the checker-side twin
// of codegen's duDeclaredUnionOfObject. Null-member and all-strlit unions are
// excluded for the same repr reasons as primitiveMemberIndexInUnion.
function declaredTagUnionOf(expr: Node): Type | null {
	let walk: Node = expr;
	while (walk !== null && walk.kind === NodeKind.TypeAssertion) {
		walk = (walk.data as TypeAssertionData).asExpr;
	}
	if (walk === null || walk.kind !== NodeKind.Identifier || walk.resolvedSym === null) return null;
	const t = walk.resolvedSym.symbolType;
	if (t === null || t.kind !== TypeKind.Union || t.typeChildren === null) return null;
	if (unwrapRefNullUnion(t) !== null) return null;
	let allStrLit = true;
	for (const child of t.typeChildren) {
		if (child === null || child.kind === TypeKind.Null) return null;
		if (child.kind !== TypeKind.StringLiteral) allStrLit = false;
	}
	if (allStrLit) return null;
	return t;
}

// The projection twin of widenVariantToUnion: a flow-narrowed reference whose
// DECLARED type is a tagged union types as the member, but its C storage is
// still the union struct — codegen needs a node selecting the active slot.
// Same stamp convention (+1 so 0 means "not set"); the emitter tells the two
// directions apart by convType: union = inject, member = project.
function narrowUnionToVariant(expr: Node, exprType: Type): Node {
	if (exprType.kind === TypeKind.Union) return null as unknown as Node;
	const declared = declaredTagUnionOf(expr);
	if (declared === null) return null as unknown as Node;
	let vi: int32 = -1;
	let ci: int32 = 0;
	for (const child of declared.typeChildren) {
		if (child === exprType) { vi = ci; break; }
		ci += 1;
	}
	if (vi < 0) {
		const value = unwrapRef(exprType);
		vi = value !== null && value.kind === TypeKind.Struct
			? variantIndexInUnion(declared, value)
			: primitiveMemberIndexInUnion(declared, exprType);
	}
	if (vi < 0) return null as unknown as Node;
	const member = declared.typeChildren[vi];
	const convTok = createToken(TokenKind.Ident, "", expr.location.line);
	const convNode = createNode(NodeKind.HiddenSubConv, { convExpr: expr, convType: member }, convTok);
	convNode.nodeType = member;
	convNode.flags = convNode.flags | NodeFlag.Sem | (((vi + 1) as int32) << 16);
	return convNode;
}

// Adoption action for isAnonStructAdoption pairs: re-construct the frozen
// anonymous value member-wise as the named struct. Identifier sources only —
// anything else would need single-eval temp machinery. Returns null when the
// pair does not adopt; callers fall through to their existing reject path.
export function tryAdoptAnonStruct(expr: Node, formalIn: Type | null, exprTypeIn: Type | null): Node {
	const formal = skipModifier(formalIn);
	const exprType = skipModifier(exprTypeIn);
	if (formal === null || exprType === null) return null as unknown as Node;
	if (expr.kind !== NodeKind.Identifier) return null as unknown as Node;
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
		objNode.flags = objNode.flags | NodeFlag.Sem;
		objNode.location = expr.location;
		const mem = createNode(NodeKind.MemberExpr, { object: objNode, property: formal.typeNames[i], isOptional: false } as NodeData, tok);
		mem.nodeType = formal.typeChildren[i];
		mem.flags = mem.flags | NodeFlag.Sem;
		mem.location = expr.location;
		props.push(mem);
		keys.push(formal.typeNames[i]);
		keyLocs.push(expr.location);
	}
	const lit = createNode(NodeKind.ObjectLiteral, { properties: props, keys: keys, keyLocations: keyLocs } as NodeData, tok);
	lit.nodeType = formal;
	lit.flags = lit.flags | NodeFlag.Sem;
	lit.location = expr.location;
	return lit;
}

export function fitNode(ctx: CheckerContext, expr: Node, formal: Type | null, exprType: Type | null): Node {
	if (formal === null || exprType === null) return expr;
	if (formal.kind === TypeKind.Unknown || isUnresolvedType(formal)) {
		if (isUnknownType(formal)) {
			let srcT = exprType;
			let probe = expr;
			while (probe.kind === NodeKind.TypeAssertion) {
				probe = (probe.data as TypeAssertionData).asExpr;
				if (probe !== null && probe.nodeType !== null) srcT = probe.nodeType;
			}
			// Explicit cast chains reinterpret pointer-SIZED scalars (Nim isCastable,
			// semexprs.nim:320: dstSize >= srcSize / integral); fat values stay illegal.
			const castReinterpretOk = probe !== expr && srcT !== null
				&& (isIntegerType(srcT) || srcT.kind === TypeKind.Boolean || srcT.kind === TypeKind.Char || srcT.kind === TypeKind.Enum);
			if (!isPointerShapedForUnknown(srcT) && !castReinterpretOk) {
				addError(ctx, "cannot pass value type " + typeDisplayName(srcT) + " as unknown — no void* representation (box it or pass a Ref/Ptr)", expr.location.line, expr.location.column);
			}
		}
		return expr;
	}
	if (exprType.kind === TypeKind.Unknown || isUnresolvedType(exprType)) {
		const collapsed = formal.kind === TypeKind.Union ? unwrapRefNullUnion(formal) : null;
		const unknownFamilyFormal = formal.kind === TypeKind.GenericParam
			|| (collapsed !== null && (collapsed.kind === TypeKind.Unknown || isUnresolvedType(collapsed)));
		if (isUnknownType(exprType) && !unknownFamilyFormal) {
			addError(ctx, "unknown is not assignable to " + typeDisplayName(formal) + " — narrow with an explicit cast", expr.location.line, expr.location.column);
		}
		return expr;
	}
	if (exprType.kind === TypeKind.Never) return expr;
	const adopted = tryAdoptAnonStruct(expr, formal, exprType);
	if (adopted !== null as unknown as Node) return adopted;
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
	// Implicit T → Maybe<T> coercion (Nim-parity `some(val)` / `none(T)`).
	// MUST run BEFORE the same-kind early return below — both Token and
	// Maybe<Token> have kind=Struct, so kind-equality alone wouldn't distinguish
	// them. Skip when expr is already Maybe-typed (passthrough like
	// `return otherMaybeFn()`).
	if (isMaybeType(formal) && formal.typeReturn !== null && !isMaybeType(exprType)) {
		return synthMaybeWrap(expr, formal, exprType);
	}
	// A variant value meeting a union formal converts HERE so every fit
	// position (var init, assign, return, ternary, call arg) shares the one
	// wrap — no position can forget it. Nilable pointer unions collapse to a
	// bare pointer and take no tag.
	if (formal.kind === TypeKind.Union && exprType.kind !== TypeKind.Union
		&& unwrapRefNullUnion(formal) === null) {
		const widened = widenVariantToUnion(expr, formal, exprType);
		if (widened !== null as unknown as Node) return widened;
	}
	if (formal.kind !== TypeKind.Union && exprType.kind !== TypeKind.Union) {
		const projected = narrowUnionToVariant(expr, exprType);
		if (projected !== null as unknown as Node) return projected;
	}
	if (formal.kind === exprType.kind && !isReinterpretUnsafe(exprType, formal)) return expr;
	if ((exprType.kind === TypeKind.CString && formal.kind === TypeKind.String)
		|| ((exprType.kind === TypeKind.String || exprType.kind === TypeKind.StringLiteral)
			&& formal.kind === TypeKind.CString)) {
		const convTok = createToken(TokenKind.Ident, "", expr.location.line);
		const convNode = createNode(NodeKind.HiddenStdConv, { convExpr: expr, convType: formal }, convTok);
		convNode.nodeType = formal;
		convNode.flags = convNode.flags | NodeFlag.Sem;
		return convNode;
	}
	// Narrowing integer conversion: wrap in HiddenStdConv
	if (isNarrowingIntConv(exprType, formal)) {
		const convTok = createToken(TokenKind.Ident, "", expr.location.line);
		const convNode = createNode(NodeKind.HiddenStdConv, { convExpr: expr, convType: formal }, convTok);
		convNode.nodeType = formal;
		convNode.flags = convNode.flags | NodeFlag.Sem;
		return convNode;
	}
	// Convention-based coercion protocol: try `expr.as<TargetType>()` synthesis.
	// Opt-in for any type via extension methods named asString/asNumber/asBoolean/asInt32/etc.
	const coercionCall = trySynthesizeAsCoercion(ctx, expr, exprType, formal);
	if (coercionCall !== null as unknown as Node) {
		return coercionCall;
	}
	// Scope: the memory-safety class only — container element-repr and pointer vs
	// scalar. General `!isAssignable` rejection is intentionally NOT applied — see
	// NIM-REF.md "Container element assignability + enforcement site" (terminal;
	// two intentional divergences: TS non-null types + Ref→Ptr cursor).
	if (isReinterpretUnsafe(exprType, formal)) {
		addError(ctx, "Type '" + arrayDisplay(exprType) + "' is not assignable to type '" + arrayDisplay(formal) + "' — memory layout differs (pointer vs scalar, array element, shared field, or function signature repr); a raw cast would reinterpret, not convert (convert explicitly or provide an as" + (formal.typeName !== "" ? formal.typeName.slice(0, 1).toUpperCase() + formal.typeName.slice(1, formal.typeName.length) : "X") + " extension)", expr.location.line, expr.location.column);
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
	totalParams: number, defaultOffset: number, paramTypes: Type[], definingModulePath: string = ""): void {
	if (defaults === null) return;
	// A default expression's free identifiers belong to the callee's module (where
	// the function is defined), not the caller's. Resolve it in the defining
	// module's ctx so an imported/private helper referenced by the default (e.g.
	// `x = defaultResolveSection()`) is visible at cross-module call sites — same
	// mechanism as generic-body re-check (reference: `graph.ifaces[module]`).
	// Same-module calls get `ctx` back, preserving existing behavior.
	const defCtx = pickBodyCtx(definingModulePath, ctx);
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
		// hint (e.g. `[]` for `string[]` param → msStringArray). `argIdx + defaultOffset`
		// mirrors the `defaults[]` indexing two lines above — both arrays include the
		// receiver slot for non-static methods (collectPass.ms:378-385 aligns them), so
		// the same offset skips it.
		const expectedType = paramTypes !== null && argIdx + defaultOffset < paramTypes.length ? paramTypes[argIdx + defaultOffset] : null;
		checkExpr(defCtx, cloned, expectedType);
		const fitted = expectedType !== null ? fitNode(defCtx, cloned, expectedType, cloned.nodeType) : cloned;
		args.push(fitted);
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
	const definingModulePath = defSym !== null ? defSym.modulePath : "";
	fillDefaults(ctx, cd.arguments, fnDefaults, totalParams, defaultOffset, paramTypes, definingModulePath);
}

// ===== NewExpr =====

function checkNewArgs(ctx: CheckerContext, args: Node[]): void {
	for (const arg of args) { checkExpr(ctx, arg, null); }
}

function checkNewExpr(ctx: CheckerContext, node: Node, expected: Type | null): Type {
	const d = node.data as NewExprData;
	// new BuiltinType<...>() — construct value types (Map, Set) and Promise
	if (d.newCallee.kind === NodeKind.Identifier) {
		const id = d.newCallee.data as IdentifierData;
		// new Arc(value): atomic-refcounted shared box. Pointee type is the explicit
		// <T> if present, else inferred from the single argument. Represented as a
		// Ref with the IsAtomic flag — codegen boxes the value via msAllocArc.
		if (id.name === "Arc" && d.newArguments.length === 1) {
			const ltCol = d.newCallee.location.column + id.name.length;
			const typeArgStr = getExplicitTypeArg(d.newCallee.location.line, ltCol);
			let pointee = null as unknown as Type;
			if (typeArgStr !== "") {
				pointee = resolveAnnotation(typeArgStr.trim(), ctx, d.newCallee.location.line, ltCol + 1);
			} else if (expected !== null && isAtomicRef(expected) && expected.typeReturn !== null) {
				pointee = expected.typeReturn;
			}
			checkExpr(ctx, d.newArguments[0], pointee);
			if (pointee === null) { pointee = d.newArguments[0].nodeType; }
			const arcType = createArc(pointee);
			node.nodeType = arcType;
			return arcType;
		}
		// Interface/value type: new HashMap() / new Array(32) with type from variable annotation
		// Also handle Ref<Struct> and Ref<GenericInstance> (interface types are Ref-wrapped)
		if (expected !== null && (expected.kind === TypeKind.Struct || expected.kind === TypeKind.GenericInstance)) {
			node.nodeType = expected;
			checkNewArgs(ctx, d.newArguments);
			return expected;
		}
		// Array with expected element type: new Array(32) in typed context.
		// After the reference-array flip `expected` is Ref<Array>; accept both —
		// the result keeps `expected` (Ref<Array>) and nativeLower boxes the value.
		const expectedArrInner = (expected !== null && expected.kind === TypeKind.Ref
			&& expected.typeReturn !== null && expected.typeReturn.kind === TypeKind.Array)
			? expected.typeReturn : expected;
		if (expected !== null && expectedArrInner !== null && expectedArrInner.kind === TypeKind.Array && id.name === "Array") {
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
				const arrType = createRef(createArray(elemType));
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
	// Also pass `expected` so that `const m: Map<K, V> = new Map();` (no type
	// args on the `new`) can pull K/V from the contextual annotation.
	const resolvedType = resolveGenericNewExpr(ctx, d.newCallee, calleeType!, node.typeArg, expected);
	// Error: generic type without type args AND no inferable contextual type.
	// `resolveGenericNewExpr` returns the bare `calleeType` (still
	// `Ref<GenericInstance>` with un-substituted GenericParam children) when
	// it couldn't resolve type args from any source — that's the signal
	// that we should report.
	if (d.newCallee.kind === NodeKind.Identifier) {
		const calleeName2 = (d.newCallee.data as IdentifierData).name;
		const genericParams2 = getGenericDecl(calleeName2);
		if (genericParams2 !== "") {
			const ltCol2 = d.newCallee.location.column + calleeName2.length;
			const typeArgStr2 = getExplicitTypeArg(d.newCallee.location.line, ltCol2);
			const noExplicit = typeArgStr2 === "" && (node.typeArg === null || node.typeArg === "");
			// Treat the contextual-inference path as "satisfied" iff the
			// peeled expected type matched the callee's name. Without this
			// guard a contextual mismatch (`const m: Map<K,V> = new Set()`)
			// would silently slip through; with it, the error still fires
			// for genuinely under-specified `new`s.
			const giCtxOk = peelToGenericInstance(expected) !== null
				&& peelToGenericInstance(expected).typeName === calleeName2;
			if (noExplicit && !giCtxOk) {
				addError(ctx, `'new ${calleeName2}()' requires explicit type arguments: new ${calleeName2}<...>()`, node.location.line, node.location.column);
			}
		}
	}
	// Resolve inner struct type for field type propagation
	const innerType = (resolvedType !== null && resolvedType.kind === TypeKind.Ref && resolvedType.typeReturn !== null)
		? resolvedType.typeReturn : resolvedType;
	// Type-check constructor arguments.
	// If class has constructor, use constructor's param types as argExpected
	// (with class generic params substituted from explicit `<T,U>` so
	// closure args see concrete types — Phase C parity with checkCallExpr).
	// Otherwise use struct field types as expected (positional initialization).
	const hasCtor = d.newCallee.resolvedSym !== null && hasFlag(d.newCallee.resolvedSym, SymbolFlag.HasConstructor);
	let ctorFormalTypes: Type[] = null as unknown as Type[];
	if (hasCtor && d.newCallee.resolvedSym !== null) {
		const rawCtorTypes = getCtorParamTypes(d.newCallee.resolvedSym);
		if (rawCtorTypes !== null && rawCtorTypes.length > 0) {
			ctorFormalTypes = rawCtorTypes;
			// Substitute class generic params (T, U, ...) with explicit type
			// args from `new X<int32, string>(...)`. Class generic param names
			// come from the parser-recorded `getGenericDecl(className)`.
			const className = d.newCallee.resolvedSym.name;
			const classGenericDecl = getGenericDecl(className);
			if (classGenericDecl !== "") {
				// Format: "T:Constraint,U" — strip constraints, split by comma
				const classGenericNames: string[] = [];
				const segs = splitTopLevel(classGenericDecl, ",");
				for (const seg of segs) {
					const trimmed = seg.trim();
					const colonAt = findChar(trimmed, ":");
					classGenericNames.push(colonAt > 0 ? trimmed.slice(0, colonAt).trim() : trimmed);
				}
				const explicitBindings = bindFromExplicitTypeArgs(node, classGenericNames, ctx);
				if (explicitBindings.names.length > 0) {
					const substituted: Type[] = [];
					for (const t of rawCtorTypes) {
						substituted.push(instantiateGeneric(t, explicitBindings.names, explicitBindings.types));
					}
					ctorFormalTypes = substituted;
				}
			}
		}
	}
	let ai = 0;
	while (ai < d.newArguments.length) {
		let argExpected: Type | null = null;
		if (hasCtor && ctorFormalTypes !== null && ai < ctorFormalTypes.length) {
			argExpected = ctorFormalTypes[ai];
		} else if (!hasCtor && innerType !== null && innerType.typeChildren !== null && ai < innerType.typeChildren.length) {
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
	return inferredType();
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
		const okT = getResultOkType(argType);
		if (d.hasCatch && d.catchVal !== null && okT !== null) {
			const joined = joinBranchTypes([okT, d.catchVal.nodeType]);
			if (!isUnresolvedType(joined) && isNullableWideningOf(joined, okT)) {
				d.catchVal = fitJoinedBranch(ctx, d.catchVal, joined);
				node.nodeType = joined;
				return joined;
			}
		}
		return okT;
	}
	return argType;
}

function isNullableWideningOf(joined: Type | null, okT: Type | null): boolean {
	if (joined === null || okT === null) return false;
	if (sameType(joined, okT)) return true;
	if (isMaybeType(joined) && joined.typeReturn !== null && sameType(joined.typeReturn, okT)) return true;
	const ptrMember = unwrapRefNullUnion(joined);
	if (ptrMember !== null && sameType(ptrMember, okT)) return true;
	return false;
}

// ===== Call Expression + Overload Resolution =====

function checkCallExpr(ctx: CheckerContext, node: Node, expectedType: Type | null): Type {
	const d = node.data as CallExprData;
	checkExpr(ctx, d.callee, null);
	// Phase 5: super(args) call — type-check args against parent class
	// constructor signature. resolveSuper set callee.resolvedSym to the parent
	// class symbol. Reuse getCtorParamTypes which returns user-only params (no
	// synthetic "this" prepended — that's symbol-scope only, not on Type).
	if (d.callee.kind === NodeKind.Identifier
			&& (d.callee.data as IdentifierData).name === "super"
			&& d.callee.resolvedSym !== null) {
		const parentSym = d.callee.resolvedSym;
		const ctorParamTypes = getCtorParamTypes(parentSym);
		const expectedCount = ctorParamTypes !== null ? ctorParamTypes.length : 0;
		if (d.arguments.length !== expectedCount) {
			addError(ctx, "super() expects " + expectedCount.toString() + " arguments, got " + d.arguments.length.toString(), node.location.line, node.location.column);
		}
		for (let ai = 0; ai < d.arguments.length; ai += 1) {
			const expected = (ctorParamTypes !== null && ai < ctorParamTypes.length) ? ctorParamTypes[ai] : null;
			checkExpr(ctx, d.arguments[ai], expected);
		}
		node.nodeType = voidType();
		return voidType();
	}
	let calleeType = d.callee.nodeType;
	// Detect overloaded paths early — these need argTypes for scoring
	let needsOverloadScoring = false;
	let overloadSym: Symbol | null = null;
	// Extension pre-resolution state (set in MemberExpr branch, used after arg checking)
	let extPreResolved = false;
	let extMultiFiltered: ExtensionMethod[] = [];
	let extMultiObjType: Type | null = null;
	let extMultiMethodName = "";
	let isActorMethodCall = false;
	// Check for overloads + set resolvedSym for direct calls
	if (d.callee.kind === NodeKind.Identifier) {
		const calleeName = (d.callee.data as IdentifierData).name;
		const sym = (d.callee.flags & NodeFlag.BoundSym) !== 0 && d.callee.resolvedSym !== null
			? d.callee.resolvedSym
			: lookupSymbol(ctx.table, calleeName);
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
				node.nodeType = errorType();
				return errorType();
			}
			// Type-check args first (errors inside them are reported)
			foldComptimeNodeAliasArgs(ctx, d.arguments);
			const macroArgsRef = d.arguments;
			checkJsxConsumed(ctx, macroArgsRef);
			// Mutate node to MacroInvocation form so expandMacroInvocation can read it
			// bindSym'd macro: read the bound symbol BEFORE node.data is replaced —
			// the replacement destroys the old CallExprData and d.callee with it.
			const boundCalleeSym = (d.callee.flags & NodeFlag.BoundSym) !== 0
				? d.callee.resolvedSym
				: null as unknown as Symbol;
			node.kind = NodeKind.MacroInvocation;
			node.data = { macroName: calleeName, macroArgs: macroArgsRef };
			if (boundCalleeSym !== null) {
				node.resolvedSym = boundCalleeSym;
				node.flags = node.flags | NodeFlag.BoundSym;
			}
			// SERIALIZE A3 — Defer convention: if any arg has parametric type
			// (contains GenericParam), DON'T eager-expand. The MacroInvocation
			// persists through monomorphize (clone.ms:191 preserves it), where
			// generic type params get substituted. The post-mono expandMacros
			// pass (compile.ms:934) then fires the macro with concrete types.
			//
			// This unblocks the codec pattern:
			//   function save<T>(t: T) { bson.encode(t); }   // defers
			//   save<User>(u);                                // post-mono: fires with t: User
			if (anyArgIsParametric(macroArgsRef)) {
				// Defer expansion until post-mono. Use inferredType (not void)
				// so the deferred MacroInvocation doesn't break declared return
				// types of enclosing generic functions: e.g.,
				//   function wrap<T>(x: T): string { return macro(x); }
				// The body return-stmt check sees `return <unknown>` against
				// declared `string`, which assignability rules allow. After
				// monomorphize substitutes T → concrete and re-checks the
				// cloned body, the macro expands and produces the real type.
				node.nodeType = inferredType();
				return inferredType();
			}
			// Eagerly expand right now via the Raiser VM. Track depth across the
			// re-check below so recursive macros hit the limit cleanly.
			ctx.macroExpansionDepth = ctx.macroExpansionDepth + 1;
			const expanded = callExpandMacroInvocation(node, ctx, 0);
			// See checkExpr MacroInvocation branch for full rationale.
			// Sentinel/VM errors leave node.kind = MacroInvocation; skip re-check
			// to avoid duplicating diagnostics + spurious recursive-macro warning.
			if (expanded.kind === NodeKind.MacroInvocation) {
				ctx.macroExpansionDepth = ctx.macroExpansionDepth - 1;
				node.nodeType = errorType();
				return errorType();
			}
			let expandedValue = expanded;
			if (expanded.kind === NodeKind.SpliceMany && node !== ctx.stmtPosExpr) {
				expandedValue = unwrapSpliceManyAtExpr(ctx, node, expanded);
				if (expandedValue === null) {
					ctx.macroExpansionDepth = ctx.macroExpansionDepth - 1;
					node.nodeType = errorType();
					return errorType();
				}
			}
			// Replace current node contents with the expanded result.
			// Identity is preserved — the parent (e.g. VariableDecl) still references this node.
			node.kind = expandedValue.kind;
			node.data = expandedValue.data;
			if (expandedValue.location !== null) node.location = expandedValue.location;
			node.nodeType = null as unknown as Type;
			node.resolvedSym = null;
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
			if (objType !== null) {
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
							// Array methods are Ref-agnostic (matchesExt parity): the receiver is
							// declared `T[]` (Ref<Array<T>>) but a value Vec<T> call site is a bare
							// Array — unwrap the Ref<Array> envelope on both sides so T binds to the
							// element type, else the param stays generic and an object-literal arg
							// never coerces to the element type.
							let recvP = extType.typeChildren[0];
							let objP = objType;
							if (recvP.kind === TypeKind.Ref && recvP.typeReturn !== null && recvP.typeReturn.kind === TypeKind.Array) recvP = recvP.typeReturn;
							if (objP !== null && objP.kind === TypeKind.Ref && objP.typeReturn !== null && objP.typeReturn.kind === TypeKind.Array) objP = objP.typeReturn;
							unifyType(recvP, objP, eb);
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
					const receiverSym = winner.receiverTypeName !== "" ? lookupSymbol(ctx.table, winner.receiverTypeName) : null;
					const isActorReceiver = !isStaticAccess && (
						(me.object.resolvedSym !== null && me.object.resolvedSym.symbolKind === SymbolKind.Actor)
						|| (objType !== null && objType.kind === TypeKind.Ref && objType.sym !== null && objType.sym.symbolKind === SymbolKind.Actor)
						|| (objType !== null && objType.sym !== null && objType.sym.symbolKind === SymbolKind.Actor)
						|| (receiverSym !== null && receiverSym.symbolKind === SymbolKind.Actor)
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
	// Pre-arg binding derivation. Three sources accumulate into _argBindings,
	// in priority order (explicit beats inferred):
	//   1. Explicit type args (`f<int32>(...)`) — applied pre-loop.
	//   2. Backward inference from caller's expectedType — applied pre-loop.
	//   3. Forward inference from each concrete arg's type — applied DURING
	//      the loop below. After arg[i] checks, unify its formal with the
	//      actual arg type to extract new bindings; subsequent args see those
	//      bindings via on-demand formal substitution.
	//
	// Bindings drive each arg's expectedType via on-demand instantiateGeneric.
	// Kept SEPARATE from calleeType so the existing arg-mismatch check at
	// line ~1831 still sees GenericParam and correctly skips — a concrete-arg
	// call nested in an incompatible outer context (e.g. `console.log(max(3, 7))`
	// where max's T backward-binds to string) would otherwise false-positive
	// here instead of surfacing the real error at the outer call.
	//
	// MS 3-pass spirit: bidirectional checking with eager concrete substitution
	// at the call-expression boundary. No re-check, no inference vars, no
	// backtracking. Sources 1+2 via deriveCallBindings helper (shared with
	// resolveOverloadCall); Source 3 inline below.
	const _isGenericCall = !needsOverloadScoring
		&& calleeType !== null
		&& calleeType.kind === TypeKind.Function
		&& hasGenericParams(calleeType);
	const _argBindings = _isGenericCall
		? deriveCallBindings(ctx, node, node.resolvedSym, calleeType, expectedType)
		: createUnifyBindings();
	// Overloaded direct calls — delegate arg checking to resolveOverloadCall
	// which re-checks per candidate with speculative rollback (Phase 5).
	// Affine-Promise consumption also happens inside, during the commit step.
	if (needsOverloadScoring) {
		return resolveOverloadCall(ctx, overloadSym!, node, expectedType);
	}
	// Non-overload path: check args once with callee-derived expected types.
	// For generic callees, derive paramExpected by substituting current
	// bindings into the formal type — bindings accumulate left-to-right as
	// concrete args feed forward inference (Source 3).
	const argTypes: Type[] = [];
	for (let ai = 0; ai < d.arguments.length; ai += 1) {
		let paramExpected: Type | null = null;
		const _formal: Type | null = (calleeType !== null
			&& calleeType.kind === TypeKind.Function
			&& calleeType.typeChildren !== null
			&& ai < calleeType.typeChildren.length)
			? calleeType.typeChildren[ai]
			: null as unknown as Type;
		if (_formal !== null) {
			if (_isGenericCall && _argBindings.names.length > 0) {
				paramExpected = instantiateGeneric(_formal, _argBindings.names, _argBindings.types);
			} else {
				paramExpected = _formal;
			}
			// Limitation case (Phase D): if paramExpected still contains
			// GenericParam after substitution (no binding source covered it)
			// AND the arg is a closure literal, substitute remaining
			// GenericParam with Unknown. Prevents closure params from
			// inheriting `T` as their declared type — a silent corruption
			// that downstream lifting carries into codegen.
			//
			// 3-pass spirit: this is a LOCAL fallback, not a re-check. The
			// closure body still infers types from its own body if possible;
			// we just stop propagating GenericParam as expectedType. If T
			// truly cannot be inferred, the closure's params resolve to
			// Unknown — a benign "I don't know" that downstream tolerates.
			if (_isGenericCall && hasGenericParams(paramExpected)
				&& (d.arguments[ai].kind === NodeKind.ArrowFunction
					|| d.arguments[ai].kind === NodeKind.FunctionExpr)
				&& node.resolvedSym !== null
				&& node.resolvedSym.declNode !== null
				&& node.resolvedSym.declNode.kind === NodeKind.FunctionDecl) {
				const declParams = extractGenericNames(getGenericDeclFlags(node.resolvedSym.declNode));
				for (const declParam of declParams) {
					let alreadyBound = false;
					for (const bn of _argBindings.names) { if (bn === declParam) { alreadyBound = true; break; } }
					if (!alreadyBound) {
						paramExpected = substituteType(paramExpected, declParam, inferredType());
					}
				}
			}
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
		// Source 3: forward inference. Single-walk — subsequent args see
		// the updated bindings, prior args are never re-checked.
		if (_isGenericCall && _formal !== null && argType !== null
			&& hasGenericParams(_formal) && !hasGenericParams(argType)) {
			const fwd = createUnifyBindings();
			unifyType(_formal, argType, fwd);
			mergeUnifyBindings(_argBindings, fwd);
		}
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
		// Arity gates — Varargs-aware (reference parity: tyVarargs allows 0+ trailing args).
		const extLastCT = calleeType.typeChildren.length > 0
			? calleeType.typeChildren[calleeType.typeChildren.length - 1] : null;
		const extHasRest = extLastCT !== null && extLastCT.kind === TypeKind.Varargs;
		const extMinArDeclared = getMinArity(calleeType);
		const extMinAr = extHasRest && extMinArDeclared >= calleeType.typeChildren.length
			? calleeType.typeChildren.length - 1 : extMinArDeclared;
		if (d.arguments.length < extMinAr) {
			const me = d.callee.data as MemberExprData;
			addError(ctx, `Too few arguments to '${me.property}': expected at least ${extMinAr}, got ${d.arguments.length}`, node.location.line, node.location.column);
		} else if (!extHasRest && d.arguments.length > calleeType.typeChildren.length) {
			const me = d.callee.data as MemberExprData;
			addError(ctx, `Too many arguments to '${me.property}': expected at most ${calleeType.typeChildren.length}, got ${d.arguments.length}`, node.location.line, node.location.column);
		}
		// FFI: implicit string→cstring at the call boundary (msStringToCString
		// on C; none on JS) — mirrors an explicit `as cstring` cast.
		for (let ci = 0; ci < d.arguments.length && ci < calleeType.typeChildren.length; ci += 1) {
			const cpt = calleeType.typeChildren[ci];
			if (cpt !== null && cpt.kind === TypeKind.CString && ci < argTypes.length && argTypes[ci] !== null
					&& (argTypes[ci].kind === TypeKind.String || argTypes[ci].kind === TypeKind.StringLiteral)) {
				d.arguments[ci] = synthCStringConv(d.arguments[ci], cpt);
				argTypes[ci] = cpt;
			}
		}
		// Static class methods need mono-instantiation
		// for both explicit `<T>` AND arg-driven inference (e.g.
		// `JSON.stringify(person)` without `<T>` should infer T=Person from
		// the arg). The shared `tryInstantiateGenericCallee` helper handles
		// both binding sources. Runs BEFORE the explicit-arg branch so the
		// typed mono path is uniform regardless of `<T>` presence.
		if (hasGenericParams(calleeType)
				&& node.resolvedSym !== null && node.resolvedSym.declNode !== null
				&& node.resolvedSym.declNode.kind === NodeKind.MethodDecl
				&& (node.resolvedSym.declNode.data as MethodDeclData).methodIsStatic) {
			const methodFlags = getGenericDeclFlags(node.resolvedSym.declNode);
			const newCalleeType = tryInstantiateGenericCallee(ctx, node, calleeType!, argTypes, methodFlags, expectedType);
			if (newCalleeType !== null) {
				calleeType = newCalleeType;
				return inferGenericReturn(ctx, calleeType, argTypes, expectedType, node);
			}
		}
		// Explicit type arg resolution for generic methods (e.g. JSON.parse<Person>)
		if (hasGenericParams(calleeType)) {
			const explicitArg = findCallTypeArg(node);
			if (explicitArg !== "") {
				// Static class method mono is handled at the top of the
				// extPreResolved block (uniform for both explicit `<T>` and
				// arg-driven inference). If we reach here, mono didn't fire —
				// fall through to standard explicit-arg return type computation.
				return inferGenericReturnWithExplicit(calleeType!, argTypes, expectedType, explicitArg, ctx, node);
			}
		}
		// Sendable check for extension-resolved actor method calls
		if (isActorMethodCall) {
			for (let pi = 0; pi < d.arguments.length; pi += 1) {
				checkActorArgSendable(ctx, d.arguments[pi], pi);
			}
		}
		return inferGenericReturn(ctx, calleeType!, argTypes, expectedType, node);
	}
	// Multi-overload extension — needs argTypes for scoring
	if (extMultiFiltered.length > 1) {
		return resolveExtensionOverloadCall(ctx, extMultiFiltered, argTypes, extMultiObjType, extMultiMethodName, node);
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
	// A nullable function is a carrier struct, not something callable. Without this the
	// call falls past the Function branch below undiagnosed and codegen emits the struct
	// in call position ("called object type ... is not a function"). tsc rejects the same
	// shape (ts2722), so the payload must be unwrapped at the call site.
	if (calleeType !== null && isMaybeType(calleeType)
		&& calleeType.typeReturn !== null && calleeType.typeReturn.kind === TypeKind.Function) {
		addError(ctx, "callee is possibly null (" + typeDisplayName(calleeType.typeReturn) + " | null) — unwrap with '!' or a null check first",
			node.location.line, node.location.column);
		const nullableRet = calleeType.typeReturn.typeReturn !== null ? calleeType.typeReturn.typeReturn : inferredType();
		node.nodeType = nullableRet;
		return nullableRet;
	}

	// Check argument types + infer generic return
	// @builtin("Echo"): accept any number of args of any type (reference echo parity)
	const isEchoBuiltin = node.resolvedSym !== null && node.resolvedSym.builtinKind === "Echo";
	if (calleeType.kind === TypeKind.Function && !isEchoBuiltin) {
		// Rest param detection: last typeChildren entry is wrapped in TypeKind.Varargs
		// (reference parity: tyVarargs). createFunction installs the wrapper from
		// the legacy "..." name-prefix; the marker is the single source of truth.
		const lastCT = calleeType.typeChildren.length > 0
			? calleeType.typeChildren[calleeType.typeChildren.length - 1] : null;
		const hasRest = lastCT !== null && lastCT.kind === TypeKind.Varargs;
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
				const restArr = unwrapRef(unwrapVarargs(lastCT));
				const restElem = getElementType(restArr);
				paramType = restElem.kind === TypeKind.Inferred ? restArr : restElem;
			} else if (pi < calleeType.typeChildren.length) {
				paramType = calleeType.typeChildren[pi];
			} else {
				continue;
			}
			if (argTypes[pi] === null || argTypes[pi] === null) continue;
			if (isUnknownType(paramType)) {
				let argSrcT = argTypes[pi];
				let argProbe = d.arguments[pi];
				while (argProbe.kind === NodeKind.TypeAssertion) {
					argProbe = (argProbe.data as TypeAssertionData).asExpr;
					if (argProbe !== null && argProbe.nodeType !== null) argSrcT = argProbe.nodeType;
				}
				const argCastOk = argProbe !== d.arguments[pi] && argSrcT !== null
					&& (isIntegerType(argSrcT) || argSrcT.kind === TypeKind.Boolean || argSrcT.kind === TypeKind.Char || argSrcT.kind === TypeKind.Enum);
				if (!isPointerShapedForUnknown(argSrcT) && !argCastOk) {
					addError(ctx, "Argument " + String(pi) + ": cannot pass value type " + typeDisplayName(argSrcT) + " as unknown — no void* representation (box it or pass a Ref/Ptr)", node.location.line, node.location.column);
				}
			} else if (isUnknownType(argTypes[pi]) && paramType.kind !== TypeKind.Unknown && !isUnresolvedType(paramType) && paramType.kind !== TypeKind.GenericParam) {
				const collapsedParam = paramType.kind === TypeKind.Union ? unwrapRefNullUnion(paramType) : null;
				if (collapsedParam === null || (collapsedParam.kind !== TypeKind.Unknown && !isUnresolvedType(collapsedParam))) {
					addError(ctx, "Argument " + String(pi) + ": unknown is not assignable to " + typeDisplayName(paramType) + " — narrow with an explicit cast", node.location.line, node.location.column);
				}
			}
			// Function-typed args ARE relation-checked (Nim paramTypesMatch checks
			// every arg) EXCEPT literal lambdas — their params/return are typed
			// CONTEXTUALLY from this formal at their own check site, and re-checking
			// against a generic-containing formal false-positives (ec38c20 family).
			const argIsFnValue = argTypes[pi].kind === TypeKind.Function
				&& pi < d.arguments.length && d.arguments[pi] !== null
				&& d.arguments[pi].kind !== NodeKind.ArrowFunction
				&& d.arguments[pi].kind !== NodeKind.FunctionExpr;
			const fnPairCheckable = argIsFnValue
				&& paramType.kind === TypeKind.Function
				&& !hasGenericParams(paramType);
			const fnKindMismatch = argIsFnValue
				&& paramType.kind !== TypeKind.Function && !isUnresolvedType(paramType)
				&& paramType.kind !== TypeKind.GenericParam && !isMaybeType(paramType)
				&& !hasGenericParams(paramType);
			if (fnKindMismatch) {
				const calleeName = getCalleeName(d.callee);
				addError(ctx, "Argument type mismatch in '" + calleeName + "' arg " + String(pi) + ": got " + typeDisplayName(argTypes[pi]) + ", expected " + typeDisplayName(paramType) + explainStructuralPrefix(argTypes[pi], paramType), node.location.line, node.location.column);
			}
			if ((!isUnresolvedType(paramType) && paramType.kind !== TypeKind.GenericParam
				&& paramType.kind !== TypeKind.Function
				&& !isUnresolvedType(argTypes[pi]) && argTypes[pi].kind !== TypeKind.Error
				&& (argTypes[pi].kind !== TypeKind.Function
					|| (isMaybeType(paramType) && findFirstGenericParamName(paramType) === "")))
				|| fnPairCheckable) {
				// Maybe<T> coercion: f(42) / f(null) where f: (number | null) → ...
				// Mirrors the fitNode wrap rule used for var-decl/return/assignment;
				// call args go through this site instead of fitNode. Applied
				// independently of isAssignable because (a) null IS assignable
				// to struct (so isAssignable would skip the wrap), but codegen
				// still needs a typed null to emit {0}, and (b) inner T is
				// not directly assignable to Maybe<T> — we want a struct literal.
				// Generic-containing formals never wrap here — deferred to the
				// post-binding reconciliation (Nim implicitConv, sigmatch.nim:2179).
				if (isMaybeType(paramType) && paramType.typeReturn !== null
						&& !isMaybeType(argTypes[pi])
						&& (d.arguments[pi].kind === NodeKind.NullLiteral
							|| argTypes[pi].kind === TypeKind.Null
							|| isAssignable(argTypes[pi], paramType.typeReturn))) {
					d.arguments[pi] = synthMaybeWrap(d.arguments[pi], paramType, argTypes[pi]);
					argTypes[pi] = paramType;
				}
				const adoptedArg = tryAdoptAnonStruct(d.arguments[pi], paramType, argTypes[pi]);
				if (adoptedArg !== null as unknown as Node) {
					d.arguments[pi] = adoptedArg;
					argTypes[pi] = paramType;
				}
				if (paramType.kind === TypeKind.CString
						&& (argTypes[pi].kind === TypeKind.String || argTypes[pi].kind === TypeKind.StringLiteral)) {
					d.arguments[pi] = synthCStringConv(d.arguments[pi], paramType);
					argTypes[pi] = paramType;
				}
				if (!isAssignable(argTypes[pi], paramType)) {
					if (needsStdConv(argTypes[pi], paramType)) {
						// Implicit numeric conversion — warn for float/number → integer narrowing
						if ((argTypes[pi].kind === TypeKind.Number || isFloatType(argTypes[pi])) && isIntegerType(paramType)) {
							const calleeName = getCalleeName(d.callee);
							addWarning(ctx, `implicit ${typeDisplayName(argTypes[pi])} → ${typeDisplayName(paramType)} narrowing in '${calleeName}' arg ${pi}`, node.location.line, node.location.column);
						}
					} else {
						// Try `as<TargetType>` protocol coercion before erroring.
						const coerced = trySynthesizeAsCoercion(ctx, d.arguments[pi], argTypes[pi], paramType);
						if (coerced !== null as unknown as Node) {
							d.arguments[pi] = coerced;
							argTypes[pi] = coerced.nodeType;
						} else {
							const calleeName = getCalleeName(d.callee);
							addError(ctx, "Argument type mismatch in '" + calleeName + "' arg " + String(pi) + ": got " + typeDisplayName(argTypes[pi]) + ", expected " + typeDisplayName(paramType) + explainStructuralPrefix(argTypes[pi], paramType), node.location.line, node.location.column);
						}
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
				if (paramType.kind === TypeKind.Union && pi < d.arguments.length && argTypes[pi] !== null) {
					const uw = widenVariantToUnion(d.arguments[pi], paramType, argTypes[pi]);
					if (uw !== null as unknown as Node) d.arguments[pi] = uw;
				}
				if (paramType.kind !== TypeKind.Union && pi < d.arguments.length && argTypes[pi] !== null) {
					const pj = narrowUnionToVariant(d.arguments[pi], argTypes[pi]);
					if (pj !== null as unknown as Node) d.arguments[pi] = pj;
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
			const genericParamNames = extractGenericNames(getGenericDeclFlags(node.resolvedSym.declNode));
			const explicitBindings = bindFromExplicitTypeArgs(node, genericParamNames, ctx);
			if (explicitBindings.names.length > 0) {
				const boundFnType = instantiateGeneric(calleeType, explicitBindings.names, explicitBindings.types);
				if (boundFnType !== null && boundFnType.kind === TypeKind.Function) {
					// Reference parity (tyVarargs): trailing args check against the
					// element type of the rest param, not the Varargs wrapper itself.
					const bLastIdx = boundFnType.typeChildren.length - 1;
					const bLast = bLastIdx >= 0 ? boundFnType.typeChildren[bLastIdx] : null;
					const bHasRest = bLast !== null && bLast.kind === TypeKind.Varargs;
					const bRestArr = bHasRest ? unwrapRef(unwrapVarargs(bLast)) : null;
					const bRestElemT = bRestArr !== null ? getElementType(bRestArr) : null;
					const bRestElem = bRestElemT !== null && bRestElemT.kind !== TypeKind.Inferred ? bRestElemT : null;
					for (let pi = 0; pi < argTypes.length; pi += 1) {
						const argT = argTypes[pi];
						let paramT: Type = null as unknown as Type;
						if (bHasRest && pi >= bLastIdx) {
							paramT = bRestElem;
						} else if (pi < boundFnType.typeChildren.length) {
							paramT = boundFnType.typeChildren[pi];
						} else {
							continue;
						}
						if (argT === null || paramT === null) continue;
						if (isUnresolvedType(argT) || argT.kind === TypeKind.Error) continue;
						if (paramT.kind === TypeKind.GenericParam || isUnresolvedType(paramT)) continue;
						if (!isAssignable(argT, paramT)) {
							const calleeName = getCalleeName(d.callee);
							addError(ctx, `Argument type mismatch in '${calleeName}' arg ${pi}: got ${typeDisplayName(argT)}, expected ${typeDisplayName(paramT)}${explainStructuralPrefix(argT, paramT)}`, d.arguments[pi].location.line, d.arguments[pi].location.column);
						}
					}
				}
			}
		}
		// On-demand generic instantiation for direct calls (transitive
		// instantiation). Handles both regular FunctionDecl and STATIC class
		// MethodDecl — non-static methods on generic classes go through the
		// class-instantiation path. See `tryInstantiateGenericCallee` for the
		// shared arg-unify + explicit-type-arg merge + sym/nodeType update.
		if (node.resolvedSym !== null) {
			const directFlags = getGenericDeclFlags(node.resolvedSym.declNode);
			if (directFlags !== "") {
				const newCalleeType = tryInstantiateGenericCallee(ctx, node, calleeType!, argTypes, directFlags, expectedType);
				if (newCalleeType !== null) calleeType = newCalleeType;
			}
		}
		// If explicit type args (<T>) and generic params, resolve type args at checker time
		if (hasGenericParams(calleeType)) {
			const explicitArg = findCallTypeArg(node);
			if (explicitArg !== "") {
				return inferGenericReturnWithExplicit(calleeType!, argTypes, expectedType, explicitArg, ctx, node);
			}
		}
		// Assertion function narrowing: `asserts x is T`. Applied on the
		// general return path (not just extensions) so direct calls like
		// `assertString(val)` narrow `val` for subsequent statements.
		if (calleeType !== null && calleeType.kind === TypeKind.Function
				&& calleeType.typeExtra !== null
				&& calleeType.typeExtra.kind === TypeKind.None
				&& calleeType.typeExtra.typeName.length > 8
				&& calleeType.typeExtra.typeName.slice(0, 8) === "asserts:") {
			applyAssertionNarrowing(calleeType, d.arguments);
		}
		return inferGenericReturn(ctx, calleeType!, argTypes, expectedType, node);
	}
	return getReturnType(calleeType!);
}

// Resolve generic return type using explicit type arg (e.g. parse<Person>)
function inferGenericReturnWithExplicit(fnType: Type, argTypes: Type[], expectedType: Type | null, explicitArg: string, ctx: CheckerContext, node: Node): Type {
	let returnType = fnType.typeReturn;
	if (returnType === null) return inferredType();
	// Resolve the explicit type arg to an actual type
	const resolvedSym = lookupSymbol(ctx.table, explicitArg);
	if (resolvedSym === null) return inferGenericReturn(ctx, fnType, argTypes, expectedType, node);
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
	if (ctx.inGenericContext === 0 && hasGenericParams(returnType)) {
		const unbound = findFirstGenericParamName(returnType);
		addError(ctx, "cannot instantiate: '" + unbound + "' — annotate the destination type or pass an explicit type argument", node.location.line, node.location.column);
		return errorType();
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

export function inferGenericReturn(ctx: CheckerContext, fnType: Type, argTypes: Type[], expectedType: Type | null, callNode: Node | null): Type {
	let returnType = fnType.typeReturn;
	if (returnType === null) return inferredType();

	const hasExpected = expectedType !== null && !isUnresolvedType(expectedType);
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
		if (isUnresolvedType(at) || at.kind === TypeKind.Error) continue;
		if (skipNullArg && at.kind === TypeKind.Null) continue;
		unifyType(fnType.typeChildren[i], at, argBindings);
	}

	// Pass 2: combine contextual return type bindings with arg-bindings.
	// GATED on non-naked-T to match TS naked-T rule (see `isNakedGenericReturn`).
	//   - T unbound by args   → contextual fills the gap.
	//   - T bound by args AND argType assignable to contextualType (contextual
	//     is the SUPERTYPE) → prefer contextual. Mirrors TS contextual typing:
	//     `let x: Result<number, string> = ok(int32_var)` must infer T=number
	//     so the int32 arg widens via stdConv; otherwise the call emits
	//     Result<int32, string> and fails at the assignment despite the types
	//     being legitimately compatible via numeric widening.
	//   - T bound by args AND NOT a subtype of contextual → keep arg-binding;
	//     the assignment site surfaces the real type error.
	if (hasExpected && !isNakedGenericReturn) {
		const expBindings = createUnifyBindings();
		unifyType(returnType, expectedType, expBindings);
		for (let k = 0; k < expBindings.names.length; k += 1) {
			const name = expBindings.names[k];
			const expType = expBindings.types[k];
			const idx = findBindingIndex(argBindings, name);
			if (idx === -1) {
				argBindings.names.push(name);
				argBindings.types.push(expType);
			} else if (isAssignable(argBindings.types[idx], expType)) {
				argBindings.types[idx] = expType;
			}
		}
	}

	returnType = applySubstitutions(returnType, argBindings);
	// With bindings final, a variant arg meeting a now-concrete union formal
	// gets its conversion here — same wrap every other fit position takes.
	if (callNode !== null && callNode.kind === NodeKind.CallExpr) {
		const cd = callNode.data as CallExprData;
		const lim = cd.arguments.length < fnType.typeChildren.length ? cd.arguments.length : fnType.typeChildren.length;
		for (let ai = 0; ai < lim; ai += 1) {
			const arg = cd.arguments[ai];
			if (arg === null || arg.nodeType === null) continue;
			const formal = applySubstitutions(fnType.typeChildren[ai], argBindings);
			if (formal !== null && formal.kind === TypeKind.Union) {
				const uw = widenVariantToUnion(arg, formal, arg.nodeType);
				if (uw !== null as unknown as Node) cd.arguments[ai] = uw;
			}
			const adoptedGen = tryAdoptAnonStruct(arg, formal, arg.nodeType);
			if (adoptedGen !== null as unknown as Node) cd.arguments[ai] = adoptedGen;
		}
	}
	// Eagerly instantiate body for concrete GenericInstance — mirrors
	// inferGenericReturnWithExplicit. Without this, downstream peelToStructOrUnion
	// falls back to the un-substituted typeExtra and `r.value.field` access
	// leaks GenericParam (synthesizes getDynamicField against JsonValue).
	// Built-in Result/Promise/Iterator get param names via the
	// `getGenericDecl` fallback in `parser/context.ms`.
	if (returnType.kind === TypeKind.GenericInstance && returnType.typeReturn === null) {
		const declParams = getGenericDecl(returnType.typeName);
		if (declParams !== "") {
			instantiateGenericBody(returnType, declParams);
		}
	}
	if (ctx.inGenericContext === 0 && hasGenericParams(returnType)) {
		const unbound = findFirstGenericParamName(returnType);
		const errLine = callNode !== null ? callNode.location.line : 0;
		const errCol = callNode !== null ? callNode.location.column : 0;
		addError(ctx, "cannot instantiate: '" + unbound + "' — annotate the destination type or pass an explicit type argument", errLine, errCol);
		return errorType();
	}
	return returnType;
}

function findBindingIndex(b: UnifyBindings, name: string): number {
	for (let i = 0; i < b.names.length; i += 1) {
		if (b.names[i] === name) return i;
	}
	return -1;
}

// Apply every binding in `b` to type `t` via substituteType. Used by callers
// that need to convert a formal type containing GenericParam(s) into its
// concrete substituted form after Pass 1/2/3 binding.
function applySubstitutions(t: Type, b: UnifyBindings): Type {
	let result = t;
	for (let i = 0; i < b.names.length; i += 1) {
		result = substituteType(result, b.names[i], b.types[i]);
	}
	return result;
}

function hasBindingName(b: UnifyBindings, name: string): boolean {
	return findBindingIndex(b, name) !== -1;
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
// Try to instantiate a generic callee for the call `node`. Combines two
// binding sources:
//   1. Argument-driven: unify each `argTypes[i]` against `calleeType.typeChildren[i]`
//      to derive `T → ConcreteArg` bindings.
//   2. Explicit type args: parse `f<Person, int32>(...)` syntax via
//      `bindFromExplicitTypeArgs` to derive `T → Person` bindings even when
//      args alone don't constrain T (e.g. `parseAs<T>(input: string)`).
//
// On success, mutates `node.resolvedSym`, `cd.callee.resolvedSym`, and
// `cd.callee.nodeType` to point at the instantiated symbol. Codegen reads
// `cd.callee.nodeType.typeReturn` (codegen/c/types.ms:440) for NRVO temp
// typing, so updating it is required — without it, the call temp keeps
// the generic `Result<unknown, …>` shape and the C build fails.
//
// Returns the new instantiated callee type, or null if instantiation
// didn't fire (no bindings, builtin, instantiation refused, etc.). Caller
// keeps `calleeType` unchanged on null return.
//
// Extract the per-decl "generic flags" segment used by mono dispatch.
// Centralizes the FunctionDecl/MethodDecl fork that previously appeared at
// 4+ call sites (ext static path, direct call mono, explicit-type-arg
// validation, overload winner). Returns "" when declNode is null or of an
// unsupported kind; callers should treat that as "no mono path applies".
function getGenericDeclFlags(declNode: Node): string {
	if (declNode === null) return "";
	if (declNode.kind === NodeKind.FunctionDecl) return (declNode.data as FunctionDeclData).fnFlags;
	if (declNode.kind === NodeKind.MethodDecl) return (declNode.data as MethodDeclData).methodFlags;
	return "";
}

function tryInstantiateGenericCallee(ctx: CheckerContext, node: Node, calleeType: Type, argTypes: Type[], flags: string, expectedType: Type | null = null as unknown as Type): Type {
	if (!isGenericFn(flags)) return null as unknown as Type;
	const sym = node.resolvedSym;
	if (sym === null || sym.builtinKind !== "" || sym.declNode === null) {
		return null as unknown as Type;
	}
	const cd = node.data as CallExprData;

	// Pass 1: unify args against params to derive bindings.
	const eb = createUnifyBindings();
	const limit = argTypes.length < calleeType.typeChildren.length ? argTypes.length : calleeType.typeChildren.length;
	for (let i = 0; i < limit; i += 1) {
		if (argTypes[i] !== null) {
			// Per-arg filter: a binding whose bound type still CONTAINS generic
			// params is unusable (instantiateGenericFunction refuses it) but under
			// first-wins merge it would shadow a clean binding from a later arg —
			// e.g. `createComponent(For, props)`: arg0 (the unapplied generic fn)
			// binds P to For's own T-containing param type, masking arg1's
			// concrete object literal.
			const ab = createUnifyBindings();
			unifyType(calleeType.typeChildren[i], argTypes[i], ab);
			const fb = createUnifyBindings();
			for (let bi = 0; bi < ab.names.length; bi += 1) {
				if (!hasGenericParams(ab.types[bi])) {
					fb.names.push(ab.names[bi]);
					fb.types.push(ab.types[bi]);
				}
			}
			mergeUnifyBindings(eb, fb);
		}
	}
	// Pass 2: merge explicit type args. Required when args don't bind T
	// (e.g., `parseAs<T>(input: string): Result<T, …>` — `string` doesn't
	// constrain T, only the explicit `<Person>` does).
	const genericNames = extractGenericNames(flags);
	mergeUnifyBindings(eb, bindFromExplicitTypeArgs(node, genericNames, ctx));
	// Pass 3: contextual return-type binding (Nim parity — `inheritBindings` in
	// semcall.nim:777-859). When args + explicit <T> together don't bind all
	// generic params, walk return type vs expected type to derive bindings from
	// caller context. Mirrors local pattern in `inferGenericReturn`:
	// gated on !isNakedGenericReturn to preserve TS-flavored naked-T rule.
	// `mergeUnifyBindings` preserves earlier bindings so Pass 3
	// only fills gaps — no overwrite risk.
	//
	// Fixes Bug 3 V2: macro emit `_jsonToIntArray(jv, null)` with caller-side
	// `const colors: Color[] = ...` context. Args alone don't bind T (null is
	// weak), explicit <T> not present in macro emit. Pass 3 binds T=Color from
	// return Array<T> vs expected Array<Color>.
	if (expectedType !== null && calleeType.typeReturn !== null
			&& calleeType.typeReturn.kind !== TypeKind.GenericParam) {
		const ctxBindings = createUnifyBindings();
		unifyType(calleeType.typeReturn, expectedType, ctxBindings);
		mergeUnifyBindings(eb, ctxBindings);
	}
	if (eb.names.length === 0) return null as unknown as Type;

	// Post-mono arg reconciliation: substitute generic params in formal types
	// and apply Maybe-wrap for null literal args against value-type Maybe<T>
	// formals. Mirrors Nim's match-as-you-go pattern (sigmatch.nim:2395+
	// paramTypesMatchAux substitutes T progressively per arg) via deferred
	// substitute. MS's checkArg-then-bind ordering leaves null arg typed as
	// Null primitive while formal becomes Maybe<T-concrete> after mono — C
	// codegen rejects void* vs struct mismatch. Re-coerce here.
	//
	// Fires for NullLiteral args and for Maybe-coercible args deferred by the
	// coercion loop (Nim implicitConv: conversions use the instantiated formal,
	// never a generic-containing one — sigmatch.nim:2179).
	const reconcileLimit = cd.arguments.length < calleeType.typeChildren.length
		? cd.arguments.length : calleeType.typeChildren.length;

	// A generic function passed as a VALUE argument (unapplied — the Neon flow
	// tags: `createComponent(For, props)`): the outer call's bindings make the
	// substituted formal `(p: Concrete) => R` a concrete signature. Unify the
	// generic's own signature against it, instantiate, rebind the arg node so
	// codegen references the emitted instance — and then IMPROVE the outer
	// bindings from the instance's signature: a P first bound to a props
	// literal's own anon type (2 fields) must widen to the instance's declared
	// param struct (3 fields with the optional ones), or the literal emits a
	// truncated struct and the instance reads past its end. Runs BEFORE the
	// reconciliation loop below so the literal restamp sees the improved P.
	for (let ai = 0; ai < reconcileLimit; ai += 1) {
		const argN = cd.arguments[ai];
		if (argN === null || argN.resolvedSym === null) continue;
		const argSym = argN.resolvedSym;
		if (argSym.declNode === null || argSym.declNode.kind !== NodeKind.FunctionDecl) continue;
		const afd = argSym.declNode.data as FunctionDeclData;
		if (!isGenericFn(afd.fnFlags)) continue;
		if (argSym.symbolType === null) continue;
		const substFormal = applySubstitutions(calleeType.typeChildren[ai], eb);
		if (substFormal === null || substFormal.kind !== TypeKind.Function || hasGenericParams(substFormal)) continue;
		const gb = createUnifyBindings();
		const gLimit = argSym.symbolType.typeChildren.length < substFormal.typeChildren.length ? argSym.symbolType.typeChildren.length : substFormal.typeChildren.length;
		for (let gi = 0; gi < gLimit; gi += 1) {
			unifyType(argSym.symbolType.typeChildren[gi], substFormal.typeChildren[gi], gb);
		}
		unifyType(argSym.symbolType.typeReturn, substFormal.typeReturn, gb);
		if (gb.names.length === 0) continue;
		const argInst = callInstantiateGeneric(argSym, gb.names, gb.types, ctx, argN.location);
		if (argInst === null) continue;
		argN.resolvedSym = argInst;
		argN.nodeType = argInst.symbolType;
		if (argInst.symbolType === null) continue;
		const ib = createUnifyBindings();
		unifyType(calleeType.typeChildren[ai], argInst.symbolType, ib);
		for (let ii = 0; ii < ib.names.length; ii += 1) {
			if (hasGenericParams(ib.types[ii])) continue;
			let found = false;
			for (let ei = 0; ei < eb.names.length; ei += 1) {
				if (eb.names[ei] === ib.names[ii]) {
					eb.types[ei] = ib.types[ii];
					found = true;
					break;
				}
			}
			if (!found) {
				eb.names.push(ib.names[ii]);
				eb.types.push(ib.types[ii]);
			}
		}
	}
	for (let pi = 0; pi < reconcileLimit; pi += 1) {
		const arg = cd.arguments[pi];
		if (arg === null) continue;
		const substituted = applySubstitutions(calleeType.typeChildren[pi], eb);
		if (substituted === null) continue;
		// An object-literal arg that self-typed under the generic-adoption gate
		// (checkExpr ObjectLiteral: a generic-containing formal is never stamped)
		// now gets the instantiated formal: codegen must emit the same struct
		// identity the instance's parameter uses, not the literal's own anon name.
		if (arg.kind === NodeKind.ObjectLiteral && substituted.kind === TypeKind.Struct
				&& !hasGenericParams(substituted)) {
			arg.nodeType = substituted;
		}
		if (substituted.kind === TypeKind.Union && arg.nodeType !== null) {
			const uw = widenVariantToUnion(arg, substituted, arg.nodeType);
			if (uw !== null as unknown as Node) cd.arguments[pi] = uw;
			continue;
		}
		if (!isMaybeType(substituted) || substituted.typeReturn === null) continue;
		if (arg.kind === NodeKind.NullLiteral) {
			cd.arguments[pi] = synthMaybeWrap(arg, substituted, arg.nodeType!);
		} else if (arg.nodeType !== null && !isMaybeType(arg.nodeType)
				&& isAssignable(arg.nodeType, substituted.typeReturn)) {
			cd.arguments[pi] = synthMaybeWrap(arg, substituted, arg.nodeType);
		}
	}

	const instSym = callInstantiateGeneric(sym, eb.names, eb.types, ctx, node.location);
	if (instSym === null) return null as unknown as Type;

	node.resolvedSym = instSym;
	cd.callee.resolvedSym = instSym;
	cd.callee.nodeType = instSym.symbolType;
	return instSym.symbolType;
}

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
		if (resolved !== null && !isUnresolvedType(resolved)) {
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
	return argType!;
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

// Phase 5: two-pass overload resolution (ref parity: `chooseOverload`).
//
// Pass 1 (scoring): check each arg once with `null` expected type. Object
// literals become anonymous structs (`checkObjectLiteral` anon-synthesis
// path). Enum member accesses rewrite `K.A` to Identifier
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
function resolveOverloadCall(ctx: CheckerContext, sym: Symbol, callNode: Node, expectedType: Type | null = null as unknown as Type): Type {
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
	// matches the reference's `CheckModeSkipContextSensitive`.
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
		// Fall through to Pass 2 with the first matching candidate (ref parity:
		// `chooseOverload` picks the first applicable candidate when scores
		// are tied). Only report ambiguity when at least one non-skipped arg
		// actually discriminates but two candidates still tie.
		let allSkipped = true;
		for (const s of skipMask) {
			if (!s) { allSkipped = false; break; }
		}
		if (!allSkipped) {
			let hasJsxArg = false;
			for (const a of args) {
				if (a.kind === NodeKind.JSXElement || a.kind === NodeKind.JSXFragment) { hasJsxArg = true; break; }
			}
			if (hasJsxArg) {
				addError(ctx, `Ambiguous call to overloaded function '${sym.name}' — a converter never disambiguates an overloaded call; call the converter explicitly on the JSX argument`,
					callNode.location.line, callNode.location.column);
				return getReturnType(sym.symbolType);
			}
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

	let winnerType = candidates[bestIdx];

	// Phase C parity: if the winner is generic, apply Sources 1+2 (explicit
	// type args + backward inference) BEFORE rechecking context-sensitive
	// args, so closure params don't inherit GenericParam from the
	// un-substituted formal type. Reuses the shared deriveCallBindings
	// helper used by checkCallExpr's non-overload path.
	if (winnerType.kind === TypeKind.Function && hasGenericParams(winnerType)) {
		const winnerSym = candSyms[bestIdx];
		const bindings = deriveCallBindings(ctx, callNode, winnerSym, winnerType, expectedType);
		if (bindings.names.length > 0) {
			winnerType = instantiateGeneric(winnerType, bindings.names, bindings.types);
		}
	}

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
	if (winnerType.kind === TypeKind.Function && winnerType.typeChildren !== null
			&& d.arguments.length === winnerType.typeChildren.length) {
		for (let wi = 0; wi < d.arguments.length; wi += 1) {
			const wpt = winnerType.typeChildren[wi];
			const wat = d.arguments[wi].nodeType;
			if (wpt === null || wat === null) continue;
			if (wpt.kind === TypeKind.CString
					&& (wat.kind === TypeKind.String || wat.kind === TypeKind.StringLiteral)) {
				d.arguments[wi] = synthCStringConv(d.arguments[wi], wpt);
				argTypes[wi] = wpt;
			} else if (needsStdConv(wat, wpt)) {
				const wTok = createToken(TokenKind.Ident, "", d.arguments[wi].location.line);
				const wConv = createNode(NodeKind.HiddenStdConv, { convExpr: d.arguments[wi], convType: wpt }, wTok);
				wConv.nodeType = wpt;
				wConv.flags = wConv.flags | NodeFlag.Sem;
				d.arguments[wi] = wConv;
				argTypes[wi] = wpt;
			}
		}
	}
	d.resolvedOverloadIdx = bestIdx;
	callNode.resolvedSym = sym;
	// Signature → implementation reconciliation. Codegen mangles the call to
	// the body-bearing impl, so an argument that satisfied a body-LESS signature
	// must also satisfy the impl's parameter type. Load-bearing for DUs: the
	// per-variant sigs (`data: TypeUnionData`) all redirect to one impl taking
	// the union (`data: NodeData`), and handing it a bare variant struct
	// corrupts memory — clang only warns on the pointer mismatch.
	if (impl !== null && impl.symbolType !== null && impl.symbolType.typeChildren !== null
			&& d.arguments.length === impl.symbolType.typeChildren.length) {
		const implParams = impl.symbolType.typeChildren;
		for (let ri = 0; ri < d.arguments.length; ri += 1) {
			const implArgType = d.arguments[ri].nodeType;
			if (implArgType === null) continue;
			const reconciled = widenVariantToUnion(d.arguments[ri], implParams[ri], implArgType);
			if (reconciled !== null as unknown as Node) d.arguments[ri] = reconciled;
		}
	}
	if (d.callee !== null && d.callee.kind === NodeKind.Identifier) {
		d.callee.resolvedSym = sym;
		if (sym.symbolType !== null) d.callee.nodeType = sym.symbolType;
	}

	// Generic-overload mono: if the winning overload is generic, instantiate
	// it now and redirect `node.resolvedSym` to the specialized symbol. The
	// existing `tryInstantiateGenericCallee` helper handles the unify +
	// explicit-type-arg merge + sym redirect — temporarily set callNode.resolvedSym
	// to the winner sym (not primary) so the helper instantiates the right one,
	// then let it overwrite to instSym on success.
	//
	// Why this is needed: codegen's overload-tag path (TAG_CALL_OVERLOAD) mangles
	// the call name by slot index (`g__module_u${idx}`), which points at the
	// un-substituted generic body. The instSym has zero overloads, so after
	// redirect the codegen naturally falls into direct-call path and emits the
	// mangled mono name (e.g. `g__ref_Post`).
	const winnerSym: Symbol = bestIdx === 0
		? sym
		: (bestIdx - 1 < sym.overloads.length ? sym.overloads[bestIdx - 1] : (null as unknown as Symbol));
	if (winnerSym !== null && winnerSym.declNode !== null) {
		const winnerFlags = getGenericDeclFlags(winnerSym.declNode);
		if (isGenericFn(winnerFlags)) {
			// Swap callNode.resolvedSym to winner so the helper instantiates
			// the picked overload, not the primary. Helper writes instSym
			// back into resolvedSym on success.
			const savedSym = callNode.resolvedSym;
			callNode.resolvedSym = winnerSym;
			if (d.callee !== null && d.callee.kind === NodeKind.Identifier) {
				d.callee.resolvedSym = winnerSym;
				d.callee.nodeType = winnerSym.symbolType;
			}
			const newCalleeType = tryInstantiateGenericCallee(ctx, callNode, winnerType, argTypes, winnerFlags, expectedType);
			if (newCalleeType !== null) {
				// Mono fired. callNode.resolvedSym now points to instSym (no
				// overloads → codegen takes direct path). Keep d.resolvedOverloadIdx
				// at bestIdx so LSP hover/sig-help still reports which overload
				// the user matched against, even though codegen ignores it.
				if (newCalleeType.kind === TypeKind.Function && argTypes.length < newCalleeType.typeChildren.length) {
					fillDefaultArgsForNode(ctx, callNode, sym.name, newCalleeType.typeChildren.length, 0);
				}
				return newCalleeType.typeReturn !== null ? newCalleeType.typeReturn : inferredType();
			}
			// Mono didn't fire — restore primary sym for normal fall-through.
			callNode.resolvedSym = savedSym;
			if (d.callee !== null && d.callee.kind === NodeKind.Identifier) {
				d.callee.resolvedSym = savedSym;
				d.callee.nodeType = sym.symbolType;
			}
		}
	}

	if (winnerType.kind === TypeKind.Function && argTypes.length < winnerType.typeChildren.length) {
		fillDefaultArgsForNode(ctx, callNode, sym.name, winnerType.typeChildren.length, 0);
	}
	return inferGenericReturn(ctx, winnerType, argTypes, null, callNode);
}

// Resolve extension method overloads: multiple extensions match same receiver+method.
// Each extension's fnType includes the receiver as param[0]; strip it before scoring.
function resolveExtensionOverloadCall(ctx: CheckerContext, exts: ExtensionMethod[],
	argTypes: Type[], objType: Type | null, methodName: string, callNode: Node): Type {
	// Receiver specificity: scoring strips the receiver param, so `this string`
	// and `this unknown` would otherwise tie into ambiguity. A catch-all
	// `this unknown` receiver only participates when no concrete-receiver
	// candidate matched (or the object itself is unknown).
	if (objType !== null && !isUnresolvedType(objType) && exts.length > 1) {
		const specific: ExtensionMethod[] = [];
		for (const e of exts) {
			const ft = getExtFnType(e);
			if (!e.isStatic && ft.kind === TypeKind.Function && ft.typeChildren.length > 0
					&& ft.typeChildren[0] !== null && isUnresolvedType(ft.typeChildren[0])) {
				continue;
			}
			specific.push(e);
		}
		if (specific.length > 0 && specific.length < exts.length) { exts = specific; }
	}
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
		// Tiebreaker: an exact receiver beats a widening one — `this uint8[]`
		// wins over `this number[]` on a uint8[] object instead of tying.
		if (objType !== null && !isUnresolvedType(objType)) {
			let exactIdx = -1;
			let exactCount = 0;
			let xi = 0;
			while (xi < exts.length) {
				const xft = getExtFnType(exts[xi]);
				if (!exts[xi].isStatic && xft.kind === TypeKind.Function && xft.typeChildren.length > 0
						&& sameType(xft.typeChildren[0], objType)) {
					exactIdx = xi;
					exactCount = exactCount + 1;
				}
				xi = xi + 1;
			}
			if (exactCount === 1) {
				idx = exactIdx;
			}
		}
		// Tiebreaker: prefer concrete extension over generic
		if (idx === -2) {
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
	const extWinnerSym = idx >= 0 && idx < exts.length ? exts[idx].sym : null;
	if (extWinnerSym !== null) {
		callNode.resolvedSym = extWinnerSym;
		// Mark for transform: skip registry re-lookup (reference resolves UFCS in sem)
		if (!hasFlag(extWinnerSym, SymbolFlag.NativeMethod)) {
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
	return inferGenericReturn(ctx, winnerType, argTypes, null, callNode);
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
	setFlag(sym, SymbolFlag.Imported);
	sym.modulePath = expInfo.definingModule !== "" ? expInfo.definingModule : sourcePath;
	if (expInfo.originalName !== "") sym.originalName = expInfo.originalName;
	if (expInfo.nativeName !== "") sym.nativeName = expInfo.nativeName;
	if (expInfo.builtinKind !== "") sym.builtinKind = expInfo.builtinKind;
	if (expInfo.headerPath !== "") sym.headerPath = expInfo.headerPath;
	if (expInfo.jsModulePath !== "") sym.jsModulePath = expInfo.jsModulePath;
	sym.defaultParams = expInfo.defaultParams;
	// Cross-module generic mono — carry original AST so tryInstantiateGenericCallee
	// can fire at `ns.f<T>(...)` namespace-access call sites (mirrors the
	// importSymFromRegistry path for direct imports). Without this, namespace
	// member access keeps the un-substituted Result<T, _> shape and codegen fails.
	if (expInfo.declNode !== null) sym.declNode = expInfo.declNode;
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
			// Cross-module mono parity with primary path.
			if (expInfo.overloadDeclNodes !== null
					&& oi < expInfo.overloadDeclNodes.length
					&& expInfo.overloadDeclNodes[oi] !== null) {
				overSym.declNode = expInfo.overloadDeclNodes[oi];
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
	if (unionType === null) return inferredType();
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
		return node.nodeType!;
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
	if (objType === null) return inferredType();
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
		if (!memberExists) {
			addError(ctx, `Property '${propName}' does not exist on type '${enumName}'. Available: ${objType.typeNames.join(", ")}`, node.location.line, node.location.column);
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
			return inferredType();
		}
	}
	// reference parity: strip Ref/Ptr BEFORE field resolution, insert deref AFTER
	// reference: skip pointer types → lookup field → make dereference
	const needsDeref = isPointerInC(objType, ctx);
	let resolvedObjType = objType;
	if (needsDeref) {
		if (objType.typeReturn !== null) {
			resolvedObjType = objType.typeReturn;
			if (resolvedObjType.kind === TypeKind.Ref && resolvedObjType.typeReturn !== null) {
				resolvedObjType = resolvedObjType.typeReturn;
			}
		}
	}
	if (isBrandDistinct(resolvedObjType) && resolvedObjType.typeReturn !== null) {
		resolvedObjType = resolvedObjType.typeReturn;
	}
	// Generic match-type alias: peel GenericInstance through typeReturn/typeExtra
	// to reach the underlying Union body. Required for field resolution +
	// narrowing on `Result<T, E> = Ref<ResultData<T, E>>` style types.
	//
	// Eagerly instantiate GI body BEFORE peeling so that
	// `peelToStructOrUnion` reaches the substituted typeReturn rather than
	// falling back to the un-substituted typeExtra. Without this, accessing
	// `.value` / `.error` on `Result<T, _>` leaks GenericParam("T") to the
	// field type — downstream MemberExpr code then falls through to the
	// `getDynamicField` synthesis path and matches stray protocol exts
	// (manifested as `_rxBuf: Array ≠ JsonValueData...` after a fix
	// removed the bake-in workaround). Mirrors the same fix at
	// `inferGenericReturn` which handles call-return paths.
	//
	// Guard: only instantiate when typeChildren are CONCRETE (no GenericParam).
	// Instantiating with un-substituted GenericParam args caches an identity-
	// substituted body in typeReturn that later mono'd instances cannot
	// overwrite (the guard `if (typeReturn !== null) return` in
	// instantiateGenericBody skips repeat calls), producing cross-instance
	// type mismatches like `HashSetEntry__stringArray vs __numberArray`.
	if (resolvedObjType.kind === TypeKind.GenericInstance && resolvedObjType.typeReturn === null) {
		let allConcrete = true;
		for (const tc of resolvedObjType.typeChildren) {
			if (tc !== null && hasGenericParams(tc)) { allConcrete = false; break; }
		}
		if (allConcrete) {
			const declParams = getGenericDecl(resolvedObjType.typeName);
			if (declParams !== "") {
				instantiateGenericBody(resolvedObjType, declParams);
			}
		}
	}
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
	let propType = isStaticClassAccess ? inferredType() : getProperty(resolvedObjType, d.property);
	// Engine (macro-body) view of Node.nodeType: the VM wire carries a type-AST
	// Node tree (mapTypeToAst), not the checker Type the class declares. Type
	// the member as Node so flat reads on it resolve via the NodeData
	// unique-field-name rule below — same contract as reads on the node itself.
	if (isEngineCheckMode() && d.property === "nodeType"
			&& resolvedObjType.typeName === "Node" && !isUnresolvedType(propType)) {
		// objType, not resolvedObjType: a Node-typed VALUE is Ref<Node> everywhere
		// else (isPointerInC peels it above only to resolve the field). Handing back
		// the peeled Struct makes `detectUnionDisc(tt)` fail against its Ref<Node>
		// parameter with the nonsensical "got Node, expected Node".
		propType = objType;
	}
	// Actor isolation: block external field access (only message-passing allowed).
	// Allow access from inside the actor's own methods (ctx.currentActorName matches).
	// Allow @nonisolated fields for read access (Swift parity).
	if (!isStaticClassAccess && !isUnresolvedType(propType) && resolvedObjType.typeName !== "") {
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
	if (isStaticClassAccess && isUnresolvedType(propType) && d.object.resolvedSym !== null) {
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
	if (isUnresolvedType(propType) && !isStaticClassAccess && resolvedObjType.typeName !== "") {
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
				if (!isUnresolvedType(propType)) {
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
		// 1-based union variant slot when the access is pinned to a single C offset;
		// stamped on the per-site property sym so codegen routes `.v<slot-1>.field`
		// instead of guessing by field name (which is offset-blind).
		let narrowedSlot = 0;
		if (narrowedObjType !== null && narrowedObjType !== resolvedObjType
				&& narrowedObjType.kind === TypeKind.Struct) {
			const fieldInVariant = findFieldInVariant(narrowedObjType, d.property);
			if (fieldInVariant === null) {
				// Field not in narrowed variant — only error if we ALSO didn't find
				// it via the union-wide getProperty above. Otherwise propType is
				// already valid (a union of variant field types), and the user's
				// intent is to use it without further narrowing — let it through.
				if (isUnresolvedType(propType)) {
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
				narrowedSlot = duVariantIndexOfType(resolvedObjType, narrowedObjType) + 1;
				narrowedSym.duVariantSlot = narrowedSlot;
				node.resolvedSym = narrowedSym;
				sgRecordSym(ctx, node.location.line, node.location.column + 1, node.location.column + 1 + d.property.length, narrowedSym, fieldInVariant, SymbolKind.Property, d.property, resolvedObjType.typeName, false);
			}
		} else if (narrowedObjType !== null && narrowedObjType !== resolvedObjType
				&& narrowedObjType.kind === TypeKind.Union
				&& !duSharedFieldOffsetDiffers(narrowedObjType, d.property)) {
			// Narrowed to a sub-union whose remaining variants lay the field at ONE
			// offset — any of their slots in the full union is byte-correct; use the first.
			const subIdx = findVariantByFieldName(narrowedObjType, d.property);
			if (subIdx >= 0) {
				const fullIdx = duVariantIndexOfType(resolvedObjType, narrowedObjType.typeChildren[subIdx]);
				if (fullIdx >= 0) {
					const subSym = makeSymbol(d.property, SymbolKind.Property, propType, false);
					subSym.state = SymbolState.Shaped;
					inheritContainerInfo(subSym, ctx, resolvedObjType.typeName);
					narrowedSlot = fullIdx + 1;
					subSym.duVariantSlot = narrowedSlot;
					node.resolvedSym = subSym;
					sgRecordSym(ctx, node.location.line, node.location.column + 1, node.location.column + 1 + d.property.length, subSym, propType, SymbolKind.Property, d.property, resolvedObjType.typeName, false);
				}
			}
		}
		// Un-narrowed access to a field that variants lay at DIFFERENT offsets has no
		// single correct read — reject instead of silently reading another variant's
		// bytes. Same-offset shared fields (identical type prefix) stay legal. No
		// disc gate: structural no-disc unions route through v<N> in C just the same,
		// and the helper only fires on a real cross-variant layout conflict.
		if (narrowedSlot === 0 && !isUnresolvedType(propType)
				&& duSharedFieldOffsetDiffers(resolvedObjType, d.property)) {
			addError(ctx, `field '${d.property}' sits at different offsets across variants of '${typeDisplayName(resolvedObjType)}' — narrow with match/if on the discriminant before accessing it`,
				node.location.line, node.location.column);
		}
		// A DU-typed field must carry a per-site property sym whose symbolType is the
		// DECLARED field type: a chained access (x.f.g where f is a DU) recovers its
		// v<N> index space from this sym at codegen, while the node's own nodeType may
		// be flow-narrowed to a single variant below. Scoped to DU-typed fields only —
		// blanket syms shift analyzer/DCE aliveness (self-host link regression).
		if (node.resolvedSym === null && !isUnresolvedType(propType)) {
			const peeledProp = peelToStructOrUnion(propType);
			if (peeledProp !== null && peeledProp.kind === TypeKind.Union) {
				const unionFieldSym = makeSymbol(d.property, SymbolKind.Property, propType, false);
				unionFieldSym.state = SymbolState.Shaped;
				inheritContainerInfo(unionFieldSym, ctx, resolvedObjType.typeName);
				node.resolvedSym = unionFieldSym;
			}
		}
	}
	if (!isUnresolvedType(propType)) {
		// reference parity: insert HiddenDeref AFTER field resolution succeeds
		if (needsDeref && d.object.kind !== NodeKind.HiddenDeref) {
			const tok = createToken(TokenKind.Ident, "", node.location.line);
			const derefNode = createNode(NodeKind.HiddenDeref, { expr: d.object }, tok);
			derefNode.nodeType = resolvedObjType;
			d.object = derefNode;
		}
		// Resolve property symbol: search symbol table for TypeName_propName (named types).
		// Keep a duVariantSlot-stamped sym — the table sym is SHARED across sites and
		// must never carry (or replace) a per-site variant slot.
		const hasVariantStamp = node.resolvedSym !== null && node.resolvedSym.duVariantSlot > 0;
		if (resolvedObjType.typeName !== "" && !hasVariantStamp) {
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
		// Assignment LHS: the declared type, not the flow-narrowed one — the
		// identifier arm's leftPartOfAsgn rule, applied to the member write.
		// Inside `if (x.f === null) { x.f = [] }` the RHS otherwise gets `null`
		// as its contextual type and the literal never finds its donor.
		if (ctx.initTracker.leftPartOfAsgn > 0) {
			return propType;
		}
		const narrowed = getFlowTypeOfReference(node, propType);
		return narrowed !== null ? narrowed : propType;
	}

	// Builtin properties: .length on array/string
	if (d.property === "length" && (resolvedObjType.kind === TypeKind.Array || resolvedObjType.kind === TypeKind.SizedArray || resolvedObjType.kind === TypeKind.Span || isStringLike(resolvedObjType) || resolvedObjType.kind === TypeKind.CString)) {
		// Create a synthetic symbol for 'length' to satisfy the validator
		const lengthSym = makeSymbol("length", SymbolKind.Property, int32Type(), false);
		lengthSym.state = SymbolState.Shaped;
		node.resolvedSym = lengthSym;
		if (needsDeref && resolvedObjType.kind === TypeKind.Array) {
			const tok = createToken(TokenKind.Ident, "", node.location.line);
			const derefNode = createNode(NodeKind.HiddenDeref, { expr: d.object }, tok);
			derefNode.nodeType = resolvedObjType;
			d.object = derefNode;
		}
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
				// Generic class instance method: monomorphize the method body with the
				// discovered bindings and point the call at the mono'd symbol (mirrors the
				// extension-method instantiation path below).
				if (eb.names.length > 0 && classMethSym.builtinKind === "" && classMethSym.declNode !== null) {
					const instSym = callInstantiateGeneric(classMethSym, eb.names, eb.types, ctx, node.location);
					if (instSym !== null) {
						ensureShaped(instSym, ctx);
						node.resolvedSym = instSym;
					}
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
		let extObjType = objType;
		// reference array: UFCS methods (push/slice/...) are declared on the value
		// Array receiver; a Ref<Array> must deref before the lookup matches. Insert a
		// HiddenDeref so codegen sees through the Ref, and unify generics on the
		// unwrapped Array so T binds (mirrors the class-method deref path above).
		if (ext === null && needsDeref && (resolvedObjType.kind === TypeKind.Array || resolvedObjType.kind === TypeKind.SizedArray || resolvedObjType.kind === TypeKind.Span)) {
			const derefExt = findFirstMatchingExt(allByName, resolvedObjType);
			if (derefExt !== null) {
				ext = derefExt;
				extObjType = resolvedObjType;
				const tok = createToken(TokenKind.Ident, "", node.location.line);
				const derefNode = createNode(NodeKind.HiddenDeref, { expr: d.object }, tok);
				derefNode.nodeType = resolvedObjType;
				d.object = derefNode;
			}
		}
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
				const symHasGenerics = hasGenericParams(srcType) || (ext.sym !== null && ext.sym.declNode !== null && ext.sym.declNode.kind === NodeKind.FunctionDecl && isGenericFn((ext.sym.declNode.data as FunctionDeclData).fnFlags));
				if (symHasGenerics) {
					const eb = createUnifyBindings();
					// GenericInstance unification — structural matching, no string parsing.
					// Array methods are Ref-agnostic (matchesExt parity, context.ms): the
					// receiver is declared `T[]` (Ref<Array<T>>) but the call site may be a
					// value Vec<T> (bare Array) — unwrap the Ref<Array> envelope on both sides
					// so T binds to the element type either way (else the bare-Array param
					// stays generic and an object-literal arg never coerces to the element).
					let recvParam = srcType.typeChildren[0];
					let unifyObj = extObjType;
					if (recvParam.kind === TypeKind.Ref && recvParam.typeReturn !== null && recvParam.typeReturn.kind === TypeKind.Array) recvParam = recvParam.typeReturn;
					if (unifyObj.kind === TypeKind.Ref && unifyObj.typeReturn !== null && unifyObj.typeReturn.kind === TypeKind.Array) unifyObj = unifyObj.typeReturn;
					unifyType(recvParam, unifyObj, eb);
					if (eb.names.length > 0) {
						// On-demand instantiation (generateInstance pattern)
						// Clone the generic function, substitute types, register specialized version
						if (ext.sym !== null && ext.sym.declNode !== null && ext.sym.builtinKind === "") {
							const instSym = callInstantiateGeneric(ext.sym, eb.names, eb.types, ctx, node.location);
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
	// Convention-based dynamic field access protocol:
	//   obj.foo  →  obj.getDynamicField("foo")
	// when:
	//   - foo is not a real field of obj's declared type, AND
	//   - foo is not a registered extension method on obj's type, AND
	//   - obj's type has an extension `getDynamicField(this T, key: string): U`.
	// Mirrors the toItems / toString synthesis pattern (see checkPass.ms:770-790).
	// Type opts in by declaring the extension; non-opt-in types remain strict.
	if (isUnresolvedType(propType)
			&& !isUnresolvedType(resolvedObjType)
			&& resolvedObjType.kind !== TypeKind.Error
			&& !unionVariantHasProperty(resolvedObjType, d.property)
			&& d.property !== "getDynamicField"
			&& ctx.initTracker.leftPartOfAsgn === 0
			&& !d.isOptional
			&& ctx.extensionRegistry !== null) {
		// Fast-fail: O(1) registry lookup — skip synthesis if no `getDynamicField` extension exists for this type.
		const dynExts = findAllExtensionsByName(ctx.extensionRegistry, "getDynamicField");
		if (dynExts.length > 0) {
			const dynExt = findFirstMatchingExt(dynExts, objType);
			if (dynExt !== null) {
				const loc = node.location;
				const memberNode = createNodeAt(NodeKind.MemberExpr,
					{ object: d.object, property: "getDynamicField", isOptional: false }, loc);
				const keyLit = createNodeAt(NodeKind.StringLiteral,
					{ value: d.property }, loc);
				const synthCall = createNodeAt(NodeKind.CallExpr,
					{ callee: memberNode, arguments: [keyLit], isDirectCall: true, resolvedOverloadIdx: -1 }, loc);
				checkExpr(ctx, synthCall, null);
				if (synthCall.nodeType !== null
						&& synthCall.nodeType.kind !== TypeKind.Error
						&& !isUnresolvedType(synthCall.nodeType)) {
					// Rewrite this MemberExpr in-place to the synthesized CallExpr.
					// Caller holds a reference to `node`; we mutate kind/data/type/flags so they see the call.
					// Flags carry NodeFlag.ExtCall set by checkCallExpr — codegen reads it to emit
					// extension-method calling convention instead of closure dispatch.
					node.kind = NodeKind.CallExpr;
					node.data = synthCall.data;
					node.nodeType = synthCall.nodeType;
					node.flags = synthCall.flags;
					if (synthCall.resolvedSym !== null) {
						node.resolvedSym = synthCall.resolvedSym;
					}
					return synthCall.nodeType;
				}
			}
		}
	}

	// Universal .toString() — every type has a compiler-provided default.
	// builtinLower resolves to the correct C function per type.
	// Return the function type (not string) so CallExpr extracts the return type.
	// Numeric types accept optional radix: .toString() or .toString(36)
	if (d.property === "toString" && isUnresolvedType(propType)) {
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
	if (isUnresolvedType(propType) && !isUnresolvedType(resolvedObjType) && !propertyActuallyExists) {
		// Suppress error in LHS-of-assignment context when type opts into the
		// `setDynamicField` write protocol. The enclosing BinaryExpr handler
		// rewrites the assignment as `obj.setDynamicField("key", value)`.
		// Counterpart of the getDynamicField synthesis for reads.
		// Receiver match uses the un-peeled object type (Ref<T> intact) — the
		// extension is declared on the wrapping reference type, not the inner
		// variant Union. Mirrors the getDynamicField synthesis below.
		//
		// Defense in depth: before suppressing the error, mirror the class-aware
		// fallback — type aliases over records are only shaped after
		// a read primes them, so the initial `getProperty` on the alias may
		// return Unknown even though the underlying record owns the field. Walk
		// the type's name via `lookupSymbol`+`ensureShaped` to surface the real
		// field. Without this, writes on alias-typed receivers (e.g.
		// `MacroInvocationData.macroArgs`) would silently route through the
		// protocol and surface a confusing setDynamicField type error.
		let realFieldOnAlias = !isUnresolvedType(getProperty(resolvedObjType, d.property));
		if (!realFieldOnAlias && resolvedObjType.typeName !== "") {
			const aliasSym = lookupSymbol(ctx.table, resolvedObjType.typeName);
			if (aliasSym !== null) {
				ensureShaped(aliasSym, ctx);
				let inner = aliasSym.symbolType;
				let _h = 0;
				while (inner !== null && _h < 4) {
					_h = _h + 1;
					if (inner.kind === TypeKind.Alias && inner.typeReturn !== null) { inner = inner.typeReturn; continue; }
					if (inner.kind === TypeKind.Ref && inner.typeReturn !== null) { inner = inner.typeReturn; continue; }
					break;
				}
				if (inner !== null && (inner.kind === TypeKind.Struct || inner.kind === TypeKind.Union)
						&& !isUnresolvedType(getProperty(inner, d.property))) {
					realFieldOnAlias = true;
				}
			}
		}
		// Also try `objType.sym` (the un-resolved receiver) — alias parameters
		// often expose the declaration via this back-pointer even when typeName
		// was lost during peeling above.
		if (!realFieldOnAlias && objType.sym !== null) {
			ensureShaped(objType.sym, ctx);
			let symType = objType.sym.symbolType;
			let _h2 = 0;
			while (symType !== null && _h2 < 4) {
				_h2 = _h2 + 1;
				if (symType.kind === TypeKind.Alias && symType.typeReturn !== null) { symType = symType.typeReturn; continue; }
				if (symType.kind === TypeKind.Ref && symType.typeReturn !== null) { symType = symType.typeReturn; continue; }
				break;
			}
			if (symType !== null && (symType.kind === TypeKind.Struct || symType.kind === TypeKind.Union)
					&& !isUnresolvedType(getProperty(symType, d.property))) {
				realFieldOnAlias = true;
			}
		}
		let suppressDynWrite = false;
		if (!realFieldOnAlias
				&& ctx.initTracker.leftPartOfAsgn > 0
				&& d.property !== "setDynamicField"
				&& ctx.extensionRegistry !== null) {
			const setExts = findAllExtensionsByName(ctx.extensionRegistry, "setDynamicField");
			// Strict receiver-name match (mirrors the BinaryExpr synthesis path):
			// `findFirstMatchingExt` is too lenient when the ext's declared
			// receiver type is parameterized (e.g. `Ref<JsonValueData>`), so we
			// compare `receiverTypeName` directly against the actual receiver's
			// type name + alias-sym name. Without this guard, an unrelated ext
			// (e.g. JsonValue's setDynamicField) would suppress legitimate
			// "Property does not exist" errors on alias-typed receivers like
			// `MacroInvocationData`.
			if (setExts.length > 0) {
				const recvNames: string[] = [];
				if (objType.typeName !== "") recvNames.push(objType.typeName);
				if (resolvedObjType.typeName !== "" && resolvedObjType.typeName !== objType.typeName) {
					recvNames.push(resolvedObjType.typeName);
				}
				if (objType.sym !== null && objType.sym.name !== "") {
					let already = false;
					for (const n of recvNames) { if (n === objType.sym.name) already = true; }
					if (!already) recvNames.push(objType.sym.name);
				}
				for (const e of setExts) {
					if (e.receiverTypeName === "") continue;
					for (const rn of recvNames) {
						if (e.receiverTypeName === rn) { suppressDynWrite = true; break; }
					}
					if (suppressDynWrite) break;
				}
			}
		}
		// Disc re-read on a positively-narrowed DU variant: the object's flow
		// type is a bare variant Struct, and enum-disc match-type variants never
		// carry the disc field — resolve it against the DECLARED union's
		// discriminant contract instead of erroring.
		if (d.object.resolvedSym !== null && d.object.resolvedSym.symbolType !== null) {
			const declaredDu = peelToStructOrUnion(d.object.resolvedSym.symbolType);
			if (declaredDu !== null && isDiscriminatedUnion(declaredDu)
					&& getDiscriminantName(declaredDu) === d.property
					&& declaredDu.typeExtra !== null) {
				return declaredDu.typeExtra;
			}
		}
		const engineVirtual = resolveEngineNodeVirtualProp(ctx, resolvedObjType, d.property, node);
		if (engineVirtual !== null) return engineVirtual;
		if (!suppressDynWrite) {
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
	}
	return propType;
}

// The macro VM's wire format flattens NodeData payload fields onto the Node
// object (expand.ms nodeToASTLiteral / bridge.ms). Inside engine compiles,
// resolve those flat reads against the NodeData union declaration: a field
// name unique across variants (or shared with one type) types directly;
// same name with different types must be narrowed first (LANG.md "unique
// field name" DU access rule).
function engineNodeHasVirtualKey(recvType: Type | null, key: string): boolean {
	if (!isEngineCheckMode()) return false;
	if (recvType === null || recvType.typeName !== "Node") return false;
	if (key === "line" || key === "column" || key === "endLine" || key === "endColumn") return true;
	// bindSym bake splices Identifier literals carrying the bound-symbol handle;
	// valueToNode consumes it — never a real Node field.
	if (key === "symHandle") return true;
	if (recvType.typeNames === null || recvType.typeChildren === null) return false;
	let dataType: Type | null = null;
	let fi = 0;
	while (fi < recvType.typeNames.length) {
		if (recvType.typeNames[fi] === "data" && fi < recvType.typeChildren.length) {
			dataType = recvType.typeChildren[fi];
			break;
		}
		fi = fi + 1;
	}
	if (dataType === null) return false;
	const dataUnion = peelToStructOrUnion(dataType);
	if (dataUnion === null || dataUnion.kind !== TypeKind.Union || dataUnion.typeChildren === null) return false;
	for (const variantRaw of dataUnion.typeChildren) {
		const variant = peelToStructOrUnion(variantRaw);
		if (variant === null || variant.typeNames === null) continue;
		for (const fn of variant.typeNames) {
			if (fn === key) return true;
		}
	}
	return false;
}

function resolveEngineNodeVirtualProp(ctx: CheckerContext, recvType: Type, prop: string, node: Node): Type | null {
	if (!isEngineCheckMode()) return null;
	if (recvType.typeName !== "Node") return null;
	if (prop === "line" || prop === "column" || prop === "endLine" || prop === "endColumn") return numberType();
	if (recvType.typeNames === null || recvType.typeChildren === null) return null;
	let dataType: Type | null = null;
	let fi = 0;
	while (fi < recvType.typeNames.length) {
		if (recvType.typeNames[fi] === "data" && fi < recvType.typeChildren.length) {
			dataType = recvType.typeChildren[fi];
			break;
		}
		fi = fi + 1;
	}
	if (dataType === null) return null;
	const dataUnion = peelToStructOrUnion(dataType);
	if (dataUnion === null || dataUnion.kind !== TypeKind.Union || dataUnion.typeChildren === null) return null;
	let found: Type | null = null;
	let conflict = false;
	for (const variantRaw of dataUnion.typeChildren) {
		const variant = peelToStructOrUnion(variantRaw);
		if (variant === null || variant.typeNames === null || variant.typeChildren === null) continue;
		let vi = 0;
		while (vi < variant.typeNames.length) {
			if (variant.typeNames[vi] === prop && vi < variant.typeChildren.length) {
				const ft = variant.typeChildren[vi];
				if (found === null) {
					found = ft;
				} else if (typeDisplayName(found) !== typeDisplayName(ft)) {
					conflict = true;
				}
			}
			vi = vi + 1;
		}
	}
	if (found === null) return null;
	if (conflict) {
		addError(ctx, `field '${prop}' has different types across Node variants — narrow with a kind check or '.data as <Kind>Data' before accessing it`, node.location.line, node.location.column);
		return inferredType();
	}
	return found;
}

// ===== Match Expression =====

function checkMatchExpr(ctx: CheckerContext, node: Node, expectedType: Type | null): Type {
	const d = node.data as MatchExprData;
	checkExpr(ctx, d.matchDisc, null);
	const discType = d.matchDisc.nodeType;
	let returnType = inferredType();
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
	const branchBodyTypes: Type[] = [];
	for (const c of d.matchCases) {
		const cd = c.data as MatchCaseData;
		restoreInitState(ctx.initTracker, oldState);
		const hasGuard = cd.caseGuard !== null;
		for (const p of cd.casePatterns) {
			if (p.kind === NodeKind.Identifier) {
				const id = p.data as IdentifierData;
				if (id.name !== "_") {
					const sym = lookupSymbol(ctx.table, id.name);
					if (sym !== null && sym.symbolKind === SymbolKind.Variable && !hasFlag(sym, SymbolFlag.Mutable)) {
						p.resolvedSym = sym;
						checkExpr(ctx, p, discType);
						continue;
					}
				}
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
		let bodyType = inferredType();
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
						checkExpr(ctx, rd.argument, expectedType); bodyType = rd.argument.nodeType;
					}
				}
			}
		} else {
			checkExpr(ctx, cd.caseBody, expectedType); bodyType = cd.caseBody.nodeType;
		}

		branchInits.push(collectNewInits(ctx.initTracker, oldState));
		branchBreaks.push(breaksBlock(cd.caseBody));
		branchBodyTypes.push(bodyType);
		if (isUnresolvedType(returnType) && !isUnresolvedType(bodyType)) {
			returnType = bodyType;
		}
	}
	let matchJoined: Type | null = null;
	if (expectedType === null || isUnresolvedType(expectedType)) {
		const j = joinBranchTypes(branchBodyTypes);
		if (!isUnresolvedType(j)) { matchJoined = j; returnType = j; }
	}
	for (const c of d.matchCases) {
		const cd = c.data as MatchCaseData;
		if (cd.caseBody.kind === NodeKind.BlockStmt) {
			const bd = cd.caseBody.data as BlockStmtData;
			if (bd.statements.length > 0) {
				const last = bd.statements[bd.statements.length - 1];
				if (last.kind === NodeKind.ReturnStmt) {
					const rd = last.data as ReturnStmtData;
					if (rd.argument !== null) {
						retypeEmptyArrayBranch(rd.argument, returnType);
						if (matchJoined !== null) rd.argument = fitJoinedBranch(ctx, rd.argument, matchJoined);
					}
				}
			}
		} else {
			retypeEmptyArrayBranch(cd.caseBody, returnType);
			if (matchJoined !== null) cd.caseBody = fitJoinedBranch(ctx, cd.caseBody, matchJoined);
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
		checkEnumExhaustiveness(ctx, discType!, coveredMembers, node.location.line, node.location.column, discEnd);
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
		checkExpr(ctx, body, explicitReturnType);
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
		return createClosureType(types, params, explicitReturnType);
	}
	if (returnTypeAnnotation === "void") {
		return createClosureType(types, params, voidType());
	}
	if (!isUnresolvedType(inferredRet)) {
		return createClosureType(types, params, inferredRet);
	}
	return createClosureType(types, params, voidType());
}

function checkArrowExpr(ctx: CheckerContext, node: Node, expectedType: Type | null): Type {
	const d = node.data as ArrowFunctionData;
	resolveTypeExpr(node.typeExpr, ctx);
	resolveTypeExprs(node.typeExprs, ctx);
	const fnType = checkAnonymousFunction(ctx, "<arrow>", d.arrowParams, d.arrowParamTypes, d.arrowBody, node.paramLocations!, d.arrowReturnType, expectedType);
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
	return checkAnonymousFunction(ctx, "(anon)", d.funcExprParams, d.funcExprParamTypes, d.funcExprBody, node.paramLocations!, d.funcExprReturnType, expectedType);
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

function walkForMutableCaptures(node: Node | null, params: string[], reported: string[], ctx: CheckerContext): void {
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
		if (ctx.currentActorName !== "") {
			const actorReported: string[] = [];
			walkActorSpawnRules(ctx, body, actorReported);
		}
	}
}

// ===== Actor Spawn Thunk Rules (PARALOCK Phase 6: S1/E61, S3/E62) =====
// Inside an actor method, a spawn thunk may borrow `this.f` read-only.
// Bare `this` / `this.<method>` re-enter a suspended actor (S1); writes
// rooted at `this` mutate frozen state (S3, deep — Pony box semantics).
// Descends into nested closures (same `this`); skips nested spawn thunks
// (each spawn call runs its own checkSpawnCaptures).

// The checker wraps ref-typed reads in HiddenDeref/HiddenStdConv during body
// check (which runs before this walk) — `this.n` in read position arrives as
// MemberExpr(HiddenDeref(this), n). Assignment LHS stays unwrapped
// (leftPartOfAsgn). All shape tests must peel, or wrapped `this` reads
// misclassify as bare-this captures.
function peelHidden(n: Node): Node {
	let cur = n;
	while (cur !== null) {
		if (cur.kind === NodeKind.HiddenDeref) { cur = (cur.data as HiddenDerefData).expr; continue; }
		if (cur.kind === NodeKind.HiddenStdConv) { cur = (cur.data as HiddenStdConvData).convExpr; continue; }
		break;
	}
	return cur;
}

function isThisIdent(n: Node): boolean {
	const p = peelHidden(n);
	if (p === null) return false;
	if (p.kind !== NodeKind.Identifier) return false;
	return (p.data as IdentifierData).name === "this";
}

function writeChainRoot(n: Node): Node {
	let cur = peelHidden(n);
	while (cur !== null) {
		if (cur.kind === NodeKind.MemberExpr) { cur = peelHidden((cur.data as MemberExprData).object); continue; }
		if (cur.kind === NodeKind.ArrayAccess) { cur = peelHidden((cur.data as ArrayAccessData).array); continue; }
		break;
	}
	return cur;
}

function thisWriteFieldName(n: Node): string {
	let cur = peelHidden(n);
	while (cur !== null) {
		if (cur.kind === NodeKind.MemberExpr) {
			const d = cur.data as MemberExprData;
			if (isThisIdent(d.object)) return d.property;
			cur = peelHidden(d.object); continue;
		}
		if (cur.kind === NodeKind.ArrayAccess) { cur = peelHidden((cur.data as ArrayAccessData).array); continue; }
		break;
	}
	return "";
}

function pushIfNew(list: string[], key: string): boolean {
	for (const k of list) { if (k === key) return false; }
	list.push(key);
	return true;
}

function actorDeclaresMethod(ctx: CheckerContext, methodName: string): boolean {
	const actorSym = lookupSymbol(ctx.table, ctx.currentActorName);
	if (actorSym === null || actorSym.declNode === null) return false;
	if (actorSym.declNode.kind !== NodeKind.ActorDecl) return false;
	const body = (actorSym.declNode.data as ActorDeclData).actorBody;
	for (const m of body) {
		let mm = m;
		if (mm.kind === NodeKind.DecoratedDecl) {
			const dd = mm.data as DecoratedDeclData;
			if (dd.decoratedNode !== null) mm = dd.decoratedNode;
		}
		if (mm.kind === NodeKind.MethodDecl && (mm.data as MethodDeclData).methodName === methodName) return true;
	}
	return false;
}

function reportThisFieldWrite(ctx: CheckerContext, target: Node, node: Node, reportedKeys: string[], verb: string): void {
	if (!isThisIdent(writeChainRoot(target))) return;
	if (isThisIdent(target)) return;
	const f = thisWriteFieldName(target);
	const label = f !== "" ? "'" + f + "'" : "state";
	if (pushIfNew(reportedKeys, "w:" + f)) {
		addError(ctx, "captured actor field " + label + " is read-only inside a spawn thunk — " + verb + " is not allowed; compute into a local and apply after await (PARALOCK S3/E62)", node.location.line, node.location.column);
	}
}

function walkActorSpawnRules(ctx: CheckerContext, node: Node, reportedKeys: string[]): void {
	if (node === null) return;
	match (node.kind) {
		NodeKind.BinaryExpr => {
			const d = node.data as BinaryExprData;
			const isAsgn = d.operator === "=" || d.operator === "+=" || d.operator === "-=" ||
				d.operator === "*=" || d.operator === "/=" || d.operator === "%=" ||
				d.operator === "&&=" || d.operator === "||=" || d.operator === "??=";
			if (isAsgn) {
				reportThisFieldWrite(ctx, d.left, node, reportedKeys, "assignment");
			}
			walkActorSpawnRules(ctx, d.left, reportedKeys);
			walkActorSpawnRules(ctx, d.right, reportedKeys);
		},
		NodeKind.UpdateExpr => {
			const d = node.data as UpdateExprData;
			reportThisFieldWrite(ctx, d.updateArg, node, reportedKeys, "increment/decrement");
			walkActorSpawnRules(ctx, d.updateArg, reportedKeys);
		},
		NodeKind.MoveExpr => {
			const d = node.data as MoveExprData;
			reportThisFieldWrite(ctx, d.moveArg, node, reportedKeys, "'move'");
			walkActorSpawnRules(ctx, d.moveArg, reportedKeys);
		},
		NodeKind.OutExpr => {
			const d = node.data as OutExprData;
			reportThisFieldWrite(ctx, d.outArg, node, reportedKeys, "'out' argument");
			walkActorSpawnRules(ctx, d.outArg, reportedKeys);
		},
		NodeKind.MemberExpr => {
			const d = node.data as MemberExprData;
			if (isThisIdent(d.object)) {
				if (actorDeclaresMethod(ctx, d.property) && pushIfNew(reportedKeys, "m:" + d.property)) {
					addError(ctx, "spawn thunk cannot use method '" + d.property + "' of 'this' — the actor is suspended while spawn children run (PARALOCK S1/E61)", node.location.line, node.location.column);
				}
				return;
			}
			walkActorSpawnRules(ctx, d.object, reportedKeys);
		},
		NodeKind.Identifier => {
			if ((node.data as IdentifierData).name === "this" && pushIfNew(reportedKeys, "this")) {
				addError(ctx, "spawn thunk inside an actor method cannot capture 'this' — borrow individual fields instead (PARALOCK S1/E61)", node.location.line, node.location.column);
			}
		},
		NodeKind.CallExpr => {
			const d = node.data as CallExprData;
			const nestedSpawn = node.resolvedSym !== null && node.resolvedSym.builtinKind === "PromiseSpawn";
			walkActorSpawnRules(ctx, d.callee, reportedKeys);
			let ai = 0;
			for (const arg of d.arguments) {
				if (!(nestedSpawn && ai === 0)) { walkActorSpawnRules(ctx, arg, reportedKeys); }
				ai = ai + 1;
			}
		},
		_ => { forEachChild(node, (child: Node): void => { walkActorSpawnRules(ctx, child, reportedKeys); }); },
	};
}

// ===== JSON Typed Specialization (reference-aligned: generate + check during sem) =====

import { callCheckFunctionBody } from "./checkerCallbacks";
import { addPendingInstance, instantiateClassConstructor, lookupCtorDefaults, pickBodyCtx } from "./instantiate";
import { getIdentId } from "./idents";

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
