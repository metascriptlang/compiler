// Call / member / new resolution, overloads and generic instantiation.
// Reaches the expression dispatcher only through the checkerCallbacks door.

import { refuseUnassignedRead, requiresInit, noDefaultReason, hiddenHolder, refuseMemberAccess, refuseHiddenConstructor, isSuperReceiver, declaringSymOf, refuseHiddenMethodCall, refuseHookCall, befriend, unfriend, expansionOf, markExpansion } from "./visibility";
import { AwaitExprData, UnaryExprData, ArrayAccessData, ArrayLiteralData, ArrowFunctionData, BlockStmtData, BooleanLiteralData, CallExprData, TypeGenericData, CallingConvention, ClassDeclData, DecoratedDeclData, PropertyDeclData, FunctionDeclData, FunctionExprData, IdentifierData, MacroDeclData, MacroInvocationData, MatchCaseData, MatchExprData, MemberExprData, MethodDeclData, NewExprData, SpreadExprData, Node, NodeData, NodeFlag, NodeKind, NumberLiteralData, ObjectLiteralData, OutExprData, ReturnStmtData, SourceLocation, SpliceManyData, StringLiteralData, Symbol, SymbolKind, SymbolState, TryExprData, Type, TypeAssertionData, TypeKind, VariableDeclData, DeclKind, createNode, createNodeAt } from "../ast/node";
import { TokenKind, createToken } from "../lexer/token";
import { cloneNodeForCheck, cloneNodeKeepSem, monoConcreteTypeName } from "../monomorphize/clone";
import { monoBaseName, monoInstanceName } from "../monomorphize/registry";
import { findCallTypeArg } from "../parser/context";
import { findChar, splitTopLevel } from "../utils/string";
import { WriteSite, isLocation, viewRefusal, writeRefusal, readonlyRootType, writeThroughArc } from "./assignable";
import { callCheckStmt, callDemandReturn, callSelfReadType, callEvalComptimeBlock, callExpandMacroInvocation, callInstantiateGeneric, callCheckExpr, checkInTypeSlot } from "./checkerCallbacks";
import { isCompileTimeValue, isUserOperatorConstant } from "./constFold";
import { duVariantIndexOfType, findVariantByEnumMember, CandidateScore, convertsImplicitly, numericConvRefuses, numericRefusalReason, checkGenericSpecialization, cmpCandidates, complexDisambiguation, emptyCandidateScore, explainStructuralPrefix, findFirstMismatch, isAssignable, foldTypeParamCandidates, TypeParamFold, isNoMatch, isNominalMismatch, needsStdConv, promotesToNullablePtr, sameNominal, sameType, scoreCandidatePriority, scoreCandidateWithSkip, takesAddressAtCArg, TypeRelation, countRelation, unmetConstraint, typeRelation, unknownReturnRefusal, returnReprRefusal, arityAdapts, dropsReadonlyView, nonNullMemberOfNullable } from "./compat";
import { macroPreludeKind, markUsedIn, noteImported, shadowedImportOf, refusesTypeAsValue, CheckerContext, ExportedSymInfo, ExtensionMethod, addError, addErrorRange, addWarning, extractGenericNames, filterExtsByReceiverType, findAllExtensionsByName, findExportedSymbol, findFirstMatchingExt, getExtFnType, isEngineCheckMode, isGenericFn, sgRecordSym, stripReceiverParam, errorCount, extDeclaresReceiver, extReceiverDisplay, extReceiverSym, filterStaticExtsByOwner, nominalTypeSym, stampItem, defaultCheckedAtDeclaration, findAccessor, dispatchMethodOf, dispatchEntryFor, findDeclaredExt, declaredKeyHash } from "./context";
import { comparesAtBase, fitUnionIntoUnion, numericUnionRefusal, checkSwitchCase, convertIntoUnknown, fitIntegerConstant, storedTypeOfNullRead, fitJoinedBranch, fitNode, slotRefuses, instantiateGenericFnValue, isFittingNumericConstant, float32ConstantLiteral, widenNumberLiteral, numericConstantForCarrier, fitNumericIntoUnion, reportNumericConvConstAware, isNodeIntLit, intLiteralExactInFloat, joinBranchTypes, literalFitsInType, narrowUnionToVariant, synthCStringConv, synthClosureThunk, synthMaybeWrap, tryAdoptAnonStruct, tryApplyConverter, valueOfInPlace, widenMaybePayload, widenVariantToUnion, declaredTagUnionOf, propagatedErrorConverter, synthStringify, refDerefHint, adoptLiteralArms, adoptLiteralTo, kindArmHandled, distinctText, refuseNamespaceText, distinctTextRefusal, textlessValue, wrappedFnText, wrapInConv, tryStructUpcast, boundCallOf, variantIntoObjectRefusal, offersProtocol, fitSendable, refuseDanglingCString } from "./fit";
import { checkImportCall } from "./importCall";
import { isImportKeyword } from "../module/loader";
import { getFlowTypeOfReference, isDefinitelyNonNullAt } from "./flow";
import { BreakState, breaksBlock, collectNewInits, markInitialized, mergeInitBranches, restoreInitState, saveInitState, unwrittenOutParam } from "./initTracker";
import { instantiateClassConstructor, pickBodyCtx, clearCheckerState, declaresUserHook } from "./instantiate";
import { ctorRoutineOf, ctorRoutineFor, ctorFormalTypes } from "./ctorRoutine";
import { bindFromExplicitTypeArgs, explicitTypeArgs, builtinTypeHead, checkExplicitTypeArgArity, ensureShaped, resolveAnnotation, builtinTypeNamed, thenSignatureOf, thenablePromised } from "./resolvePass";
import { markConsumedName, symbolConsumeKey } from "./spawnAffinity";
import { isContextSensitive, isLiteralTree } from "./speculate";
import { forEachChild } from "../ast/visitor";
import { SymbolFlag, hasFlag, hasOverloads, isTypeSymbol, lookupSymbol, makeSymbol, makeSymbolState, markConsumed, setFlag, symbolCarried, parentClassSymOf, moduleScopeNamed, enumMemberName } from "./symbol";
import { isBuiltinDirective } from "./decoratorHelpers";
import { expandTemplate, isTemplateSym, gensymSplicePrefix, referencedParams, substituteParams } from "./template";
import { TypeVisitSet, typeVisitAdd, isOutParam, widenNumberLiteralType, unionHasMemberOfKind, isArrayType, nonPrimitiveType, isPlainDataType, needsValueCopy, peelTransparentInstance, skipModifier, peelSink, symGenericParams, builtinGenericParams, genericParamsOf, genericParamNamesOf, distinctCallTarget, distinctBody, borrowedDotBase, createVar, UnifyBindings, booleanType, collectStringDiscriminantValues, createArc, isReadonlyView, withoutReadonlyView, createArray, createEnumLiteral, createFunction, createGenericInstance, createLocked, createPrimitive, createPromise, createRef, createSpawnHandle, createUnifyBindings, detectUnionDiscriminant, duFieldRequiresNarrowing, duSharedFieldOffsetDiffers, errorType, findFieldInVariant, enumMemberLiteralOf, findVariantByFieldName, float64Type, getDiscriminantName, getElementType, getMinArity, getProperty, getResultOkType, getReturnType, hasGenericParams, inferredType, instantiateGenericBody, int32Type, isAffineAwaitable, isAtomicRef, isAwaitable, isBrandDistinct, isDiscriminatedUnion, isIntegerType, isLockedRef, isMaybeType, isNumeric, lockedPayloadType, unknownRefusal, unknownRefusalText, UnknownRefusal, isResult, isStringLike, isUnknownType, isUnresolvedType, mergeUnifyBindings, nullType, peelToStructOrUnion, positionalFieldsOf, setMinArity, stringType, typeDisplayName, typeNameOf, unifyType, unionVariantHasProperty, unwrapRef, unwrapRefBase, unwrapRefNullUnion, unwrapVarargs, voidType, findVariantByBooleanDiscriminant, booleanLiteralValue, peelThrough, PEEL_ALL, duSharedFieldSlotDiffers, awaitedType, getResultErrType, isPrimitiveKindName, isTypeofTag, createStringLiteral, callMinArity, functionSlotOf, duVariantIndexOfType, derivesFromClass, matchUnionBehindInstance, isIterator, PEEL_ALIAS, isStdCollection, isPlainObjectType, bindParam, bindAt, boundSlot, substituteBound, substituteParams as substituteTypeParams, declaredTypeParams, declaredParamsOf, isArrayShaped, createTuple, createTypeRef, numberType, PEEL_MAX_DEPTH, isPrimitiveKind, instantiatedUnionBehind, createSink, mappedIsGeneric, primitiveThroughMapped, literalBase, mappedModifiers, MappedModifier, literalUnionBase } from "./types";
import { checkActorArgSendable, checkArcPointeeSendable, checkLockedPayloadSendable, checkMoveSoleOwner, checkSpawnCaptures, hasNonisolatedField, refuseSuspendingLockCallback } from "./sendable";
import { callThroughProxy, checkNewProxy, proxyPartsOf, readThroughProxy } from "./proxy";

// Peel through Ref/Ptr to find a GenericInstance carrying type args.
// Used by `resolveGenericNewExpr` to read concrete type args from a contextual
// type annotation (`const m: Map<K, V> = new Map()`) when the user didn't
// spell `<K, V>` on the `new` itself.
function peelToGenericInstance(t: Type | null): Type | null {
	if (t == null) return null;
	let cur: Type = t;
	let depth: int32 = 0;
	while (cur != null && depth < 8) {
		if (cur.kind == TypeKind.GenericInstance) return cur;
		if ((cur.kind == TypeKind.Ref || cur.kind == TypeKind.Ptr) && cur.typeReturn != null) {
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
function instantiates(instance: Type, generic: Symbol | null, writtenName: string): boolean {
	const base = instance.typeExtra != null ? unwrapRefBase(instance.typeExtra) : null;
	if (generic != null && base != null && base.sym != null) return base.sym == generic;
	return instance.typeName == (generic != null ? generic.name : writtenName);
}

function resolveGenericNewExpr(ctx: CheckerContext, callee: Node, calleeType: Type, astTypeArg: string, expectedType: Type | null): { type: Type, instance: Symbol | null } {
	const member = callee.kind == NodeKind.MemberExpr ? callee.data as MemberExprData : null;
	const bound = callee.resolvedSym != null && callee.resolvedSym.instantiatedFrom != null
		? callee.resolvedSym.instantiatedFrom : callee.resolvedSym;
	const namespaceQualified = member != null && bound != null
		&& member.object.resolvedSym != null && member.object.resolvedSym.symbolKind == SymbolKind.Module;
	if (callee.kind != NodeKind.Identifier && !namespaceQualified) return { type: calleeType, instance: null };
	const calleeName = namespaceQualified ? bound!.name : (callee.data as IdentifierData).name;
	const writtenLength = namespaceQualified ? member!.object.resolvedSym.name.length + 1 + member!.property.length : calleeName.length;
	const ltCol = callee.location.column + writtenLength;
	const calleeSym = bound != null ? bound : lookupSymbol(ctx.table, calleeName);
	const genericParams = calleeSym != null ? symGenericParams(calleeSym) : builtinGenericParams(calleeName);
	if (genericParams == "") return { type: calleeType, instance: null };
	// Try explicit type args first (sources 1 + 2 in priority comment above).
	const typeArgStr = astTypeArg;
	const paramNames = splitTopLevel(genericParamNamesOf(genericParams), ",");
	const trimmedParamNames: string[] = [];
	const concreteTypes: Type[] = [];
	let typeArgCol = ltCol + 1;
	if (typeArgStr != "") {
		// Source 1/2 — explicit type args spelled by user.
		const args = splitTopLevel(typeArgStr, ",");
		for (let pi = 0; pi < paramNames.length; pi += 1) {
			trimmedParamNames.push(paramNames[pi].trim());
			const argName = pi < args.length ? args[pi].trim() : "";
			const resolved = resolveAnnotation(argName, ctx, callee.location.line, typeArgCol);
			concreteTypes.push(resolved);
			if (argName != "") {
				const typeArgSym = lookupSymbol(ctx.table, argName);
				if (typeArgSym != null) {
					sgRecordSym(ctx, callee.location.line, typeArgCol, typeArgCol + argName.length, typeArgSym, typeArgSym.symbolType, typeArgSym.symbolKind, argName, "", false);
				}
				typeArgCol = typeArgCol + argName.length + 2;
			}
		}
	} else {
		// Source 3 — contextual inference. Peel `expectedType` (e.g.
		// `Ref<GenericInstance Map(string, Handler)>` from a `const m:
		// Map<string, Handler> = ...` annotation) and pull the concrete
		// type args out of `typeChildren`.
		const giCtx = peelToGenericInstance(expectedType);
		if (giCtx == null
				|| !instantiates(giCtx, calleeSym, calleeName)
				|| giCtx.typeChildren == null
				|| giCtx.typeChildren.length != paramNames.length) {
			return { type: calleeType, instance: null };
		}
		for (let pi = 0; pi < paramNames.length; pi += 1) {
			trimmedParamNames.push(paramNames[pi].trim());
			concreteTypes.push(giCtx.typeChildren[pi]);
		}
	}
	const declared = calleeSym != null ? declaredTypeParams(calleeSym, trimmedParamNames.length) : [];
	for (let pi = 0; pi < declared.length; pi += 1) {
		const bound = concreteTypes[pi];
		const constraint = unmetConstraint(declared[pi], bound, declared, concreteTypes);
		if (constraint == null) continue;
		addError(ctx, `Type '${typeDisplayName(bound)}' does not satisfy constraint '${typeDisplayName(constraint)}' for type parameter '${trimmedParamNames[pi]}' in '${calleeName}'`,
			callee.location.line, callee.location.column);
	}
	const baseSym = calleeSym;
	if (baseSym == null) return { type: calleeType, instance: null };
	ensureShaped(baseSym, ctx);
	// Build GenericInstance — same structure as type annotation path in resolvePass.
	// Avoids substituting the base type, which creates shared type references that cause DRC
	// use-after-free when the original base type is freed (substitution shallow copies).
	const isRefBase = baseSym.symbolType.kind == TypeKind.Ref;
	let baseType = baseSym.symbolType;
	if (isRefBase && baseType.typeReturn != null) baseType = baseType.typeReturn;
	const instType = createGenericInstance(baseType, concreteTypes);
	const refused = refuseUnhashableKey(ctx, instType, callee);
	instantiateGenericBody(instType, genericParams);
	let instance: Symbol | null = null;
	if (!refused && (baseSym.symbolKind == SymbolKind.Class || hasFlag(baseSym, SymbolFlag.HasConstructor))) {
		instance = instantiateClassConstructor(baseSym, trimmedParamNames, concreteTypes, ctx);
	}
	return { type: isRefBase ? createRef(instType) : instType, instance };
}

// Inherit modulePath + location from a container type onto a synthetic field symbol.
// Used for cross-file go-to-definition on object literal keys and member access properties.
export function inheritContainerInfo(fieldSym: Symbol, container: Symbol | null): void {
	if (container == null || container.modulePath == "") return;
	fieldSym.modulePath = container.modulePath;
	if (container.location != null) fieldSym.location = container.location;
}

// Public API: check expression, store type on node. Callers read node.nodeType.
// Returns void — reference parity (standard checker returns the node, type accessed via field).
// No Type return eliminates DRC borrowed-ref-as-fresh use-after-free.
export function retypeEmptyArrayBranch(branch: Node, otherType: Type | null): void {
	if (otherType == null || branch.kind != NodeKind.ArrayLiteral) return;
	const d = branch.data as ArrayLiteralData;
	if (d.elements.length != 0) return;
	let own = branch.nodeType;
	if (own != null && own.kind == TypeKind.Ref) own = own.typeReturn;
	if (own == null || own.kind != TypeKind.Array || own.typeReturn == null || own.typeReturn.kind != TypeKind.Inferred) return;
	let other = otherType;
	if (other.kind == TypeKind.Ref && other.typeReturn != null) other = other.typeReturn;
	if (other.kind != TypeKind.Array || other.typeReturn == null || isUnresolvedType(other.typeReturn)) return;
	branch.nodeType = otherType;
}

// A macro builds its nodes without a position, and a `static` slot's C name is
// mangled from the declaration's line and column (codegen/c/names.ms) — so two
// expansions of the same macro would claim one slot and the C would not compile.
// The call site is what separates them, and it is also where a diagnostic about
// the hoisted statement should point.
export function stampCallSite(stmt: Node, loc: SourceLocation): void {
	if (stmt == null || loc == null) return;
	if (stmt.location != null && stmt.location.line != 0) return;
	stmt.location = loc;
	if (stmt.kind == NodeKind.VariableDecl) {
		const vd = stmt.data as VariableDeclData;
		vd.nameLocation = loc;
	}
}

// The expansion result takes over the node it replaces. A bindSym identifier or a
// checked enum member keeps its Symbol: its spelling is not declared in any scope.
export function adoptExpansionResult(node: Node, value: Node): void {
	node.kind = value.kind;
	node.data = value.data;
	if (value.location != null) node.location = value.location;
	node.nodeType = null as unknown as Type;
	const carried = symbolCarried(value);
	node.resolvedSym = carried != null ? carried : null as unknown as Symbol;
	node.flags = (carried != null && value.flags.has(NodeFlag.BoundSym) ? NodeFlag.BoundSym : 0) as BitSet<NodeFlag>;
	node.variantSlot = 0;
}

// Last element is the value that replaces the call site; the ones before it are
// checked here (so the value can see what they declare) and hoisted into the
// enclosing statement list. Refusing a conditionally evaluated position is
// load-bearing: hoisting moves the prefix out of the guard that decides whether
// it runs at all. Returns null once an error has been reported.
export function unwrapSpliceManyAtExpr(ctx: CheckerContext, node: Node, expanded: Node): Node {
	const d = expanded.data as SpliceManyData;
	if (d.spliceNodes.length == 0) {
		addError(ctx, "macro expanded to no value here: at an expression position the last element of SpliceMany is the value, and none was emitted",
			node.location.line, node.location.column);
		return null as unknown as Node;
	}
	if (ctx.condEvalDepth > 0) {
		addError(ctx, "macro emits statements at a conditionally evaluated position: they would run even when this branch does not — give the call its own statement",
			node.location.line, node.location.column);
		return null as unknown as Node;
	}
	gensymSplicePrefix(ctx, expanded);
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

export function isHoistingSplice(ctx: CheckerContext, node: Node, expanded: Node): boolean {
	return expanded.kind == NodeKind.SpliceMany && node != ctx.stmtPosExpr;
}

export function spliceEndsInValue(splice: Node): boolean {
	const d = splice.data as SpliceManyData;
	if (d.spliceNodes.length == 0) return false;
	return match (d.spliceNodes[d.spliceNodes.length - 1].kind) {
		NodeKind.VariableDecl | NodeKind.DestructuringDecl | NodeKind.FunctionDecl
		| NodeKind.IfStmt | NodeKind.WhileStmt | NodeKind.DoWhileStmt | NodeKind.ForStmt
		| NodeKind.ForOfStmt | NodeKind.ForInStmt | NodeKind.BlockStmt | NodeKind.ExprStmt
		| NodeKind.ReturnStmt | NodeKind.BreakStmt | NodeKind.ContinueStmt
		| NodeKind.SwitchStmt | NodeKind.MatchStmt | NodeKind.UnreachableStmt
		| NodeKind.ThrowStmt | NodeKind.TryCatchStmt | NodeKind.DeferStmt | NodeKind.AssertStmt
		| NodeKind.ImportDecl | NodeKind.ExportDecl | NodeKind.TypeAliasDecl | NodeKind.EnumDecl
		| NodeKind.InterfaceDecl | NodeKind.StructDecl | NodeKind.ClassDecl | NodeKind.ActorDecl
		| NodeKind.DecoratedDecl | NodeKind.TestDecl | NodeKind.ExternDecl | NodeKind.MacroDecl
		| NodeKind.SpliceMany => false,
		_ => true,
	};
}

export function hoistedPrefixSyms(expanded: Node): Symbol[] {
	const d = expanded.data as SpliceManyData;
	const prefixSyms: Symbol[] = [];
	for (let i = 0; i < d.spliceNodes.length - 1; i += 1) {
		const sym = d.spliceNodes[i].resolvedSym;
		if (d.spliceNodes[i].kind == NodeKind.VariableDecl && sym != null) prefixSyms.push(sym);
	}
	return prefixSyms;
}

export function bindRefsToHoistedPrefix(value: Node, expanded: Node): void {
	bindRefsTo(value, hoistedPrefixSyms(expanded));
}

export function bindRefsTo(node: Node, syms: Symbol[]): void {
	if (node == null || syms.length == 0) return;
	if (node.kind == NodeKind.Identifier && node.resolvedSym != null) {
		for (const s of syms) {
			if (node.resolvedSym == s) { node.flags = node.flags.incl(NodeFlag.BoundSym); break; }
		}
		return;
	}
	forEachChild(node, (child: Node): void => { bindRefsTo(child, syms); });
}

// Walk `nodes` with the unconsumed-JSX leak check suppressed. A raw JSX node is legal as a
// macro argument (the macro consumes it) or as a child of a JSX node already accounted for by
// its parent — jsxMacroArgDepth > 0 marks both, so reportUnconsumedJsx stays silent inside.
export function checkJsxConsumed(ctx: CheckerContext, nodes: Node[]): void {
	ctx.jsxMacroArgDepth = ctx.jsxMacroArgDepth + 1;
	// nodeTypeAst is only ever set from a node that was typed before a macro
	// round-trip (bridge valueToNode); re-checking such an arg re-infers from
	// scratch and types a collapsed null witness as bare `null`. Expansion
	// reads nodeTypeAst directly, and arg-position nodes die with the call
	// node once the macro expands — skipping loses nothing. Guard: bug092.
	for (const n of nodes) {
		if (n.nodeTypeAst != null) continue;
		callCheckExpr(ctx, n, null);
	}
	ctx.jsxMacroArgDepth = ctx.jsxMacroArgDepth - 1;
}

export function foldComptimeNodeAliasArgs(ctx: CheckerContext, args: Node[]): void {
	let i = 0;
	while (i < args.length) {
		const a = args[i];
		if (a.kind == NodeKind.Identifier) {
			const sym = lookupSymbol(ctx.table, (a.data as IdentifierData).name);
			if (sym != null && hasFlag(sym, SymbolFlag.ComptimeNodeAlias) && sym.declNode != null) {
				markUsedIn(ctx, sym);
				args[i] = cloneNodeForCheck(sym.declNode);
			}
		}
		i += 1;
	}
}

export function resolveCalleeIdent(ctx: CheckerContext, callee: Node): Symbol {
	if (callee.flags.has(NodeFlag.BoundSym) && callee.resolvedSym != null) return callee.resolvedSym;
	return lookupSymbol(ctx.table, (callee.data as IdentifierData).name);
}

export function macroDepthExceeded(ctx: CheckerContext, name: string, node: Node): boolean {
	if (ctx.macroExpansionDepth < 16) return false;
	addError(ctx, "macro expansion depth limit (16) exceeded for '" + name + "' — possible recursive macro",
		node.location.line, node.location.column);
	node.nodeType = errorType();
	return true;
}

export function rewriteCallAsMacroInvocation(node: Node, macroSym: Symbol): void {
	const cd = node.data as CallExprData;
	const bound = cd.callee.flags.has(NodeFlag.BoundSym) && cd.callee.resolvedSym == macroSym;
	node.kind = NodeKind.MacroInvocation;
	node.data = { macroName: (cd.callee.data as IdentifierData).name, macroArgs: cd.arguments, macroHasParens: true };
	node.resolvedSym = macroSym;
	if (bound) node.flags = node.flags.incl(NodeFlag.BoundSym);
}

export function macroDeclOf(sym: Symbol | null): MacroDeclData | null {
	if (sym == null || sym.symbolKind != SymbolKind.Macro) return null;
	const decl = sym.declNode;
	if (decl == null || decl.kind != NodeKind.MacroDecl) return null;
	return decl.data as MacroDeclData;
}

export function invokedMacroSym(ctx: CheckerContext, node: Node): Symbol | null {
	const bound = node.flags.has(NodeFlag.BoundSym) && node.resolvedSym != null;
	if (bound || macroDeclOf(node.resolvedSym) != null) return macroDeclOf(node.resolvedSym) != null ? node.resolvedSym : null;
	if (isDirectiveInvocation(node)) return null;
	const sym = lookupSymbol(ctx.table, (node.data as MacroInvocationData).macroName);
	return macroDeclOf(sym) != null ? sym : null;
}

export function markNamesUsed(ctx: CheckerContext, node: Node | null): void {
	if (node == null) return;
	let name = "";
	if (node.kind == NodeKind.Identifier) name = (node.data as IdentifierData).name;
	if (node.kind == NodeKind.CallExpr) {
		const cd = node.data as CallExprData;
		const calleeName = cd.callee.kind == NodeKind.Identifier ? (cd.callee.data as IdentifierData).name : "";
		const callee = calleeName != "" ? lookupSymbol(ctx.table, calleeName) : null;
		const intrinsic = callee != null ? callee.builtinKind : calleeName != "" ? macroPreludeKind(ctx, calleeName) : "";
		if (intrinsic == "MetaBindSym"
				&& cd.arguments.length == 1 && cd.arguments[0].kind == NodeKind.StringLiteral) {
			name = (cd.arguments[0].data as StringLiteralData).value;
		}
	}
	if (name != "") {
		const sym = lookupSymbol(ctx.table, name);
		if (sym != null) markUsedIn(ctx, sym);
	}
	forEachChild(node, (child: Node): void => { markNamesUsed(ctx, child); });
}

export function isDirectiveInvocation(node: Node): boolean {
	return macroDeclOf(node.resolvedSym) == null && isBuiltinDirective((node.data as MacroInvocationData).macroName);
}

// True iff any arg's nodeType still carries a GenericParam — the marker
// for "this call lives inside an un-instantiated generic body". A type named
// as an argument (`m(Box)`) carries its own parameters, not the enclosing
// body's, so it marks only when it is a type parameter itself. Drives
// the SERIALIZE A3 defer convention: macro invocations with parametric
// args wait for monomorphization to substitute concrete types, then
// re-check eagerly expands.
export function anyArgIsParametric(args: Node[]): boolean {
	for (const arg of args) {
		if (arg.nodeType == null) continue;
		const namesType = arg.resolvedSym != null && isTypeSymbol(arg.resolvedSym);
		if (namesType && arg.nodeType.kind != TypeKind.GenericParam) continue;
		if (hasGenericParams(arg.nodeType)) return true;
	}
	return false;
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
	if (calleeSym != null) {
		const names = extractGenericNames(getGenericDeclFlags(calleeSym.declNode));
		mergeUnifyBindings(bindings, bindFromExplicitTypeArgs(callNode, ownTypeParams(calleeSym, names), ctx));
	}
	mergeUnifyBindings(bindings, bindFromExpectedReturn(calleeType, expectedType));
	return bindings;
}

// `Result.ok(v)` and `Result.err(e)` take T and E from the Result the context expects, as the
// reference library's `ok`/`err` templates take them from `typeof(result)`, so a converter
// reaches the value or the error before inference would bind it from the argument.
function contextResultSlot(calleeSym: Symbol | null, formal: Type | null, context: UnifyBindings): Type | null {
	if (calleeSym == null || formal == null || context.names.length == 0) return null;
	if (calleeSym.builtinKind != "ResultOk" && calleeSym.builtinKind != "ResultErr") return null;
	const slot = substituteBound(formal, context);
	return hasGenericParams(slot) ? null : slot;
}

function bindFromExpectedReturn(calleeType: Type, expectedType: Type | null): UnifyBindings {
	const bindings = createUnifyBindings();
	if (expectedType != null && !isUnknownType(expectedType) && calleeType != null && calleeType.typeReturn != null) {
		unifyType(calleeType.typeReturn, expectedType, bindings);
	}
	return bindings;
}

function isShapedByContext(ctx: CheckerContext, arg: Node): boolean {
	return isContextSensitive(arg)
		|| arg.kind == NodeKind.FunctionExpr
		|| arg.kind == NodeKind.ArrayLiteral
		|| isNumberLiteralArg(arg)
		|| isEnumMemberArg(ctx, arg);
}

function takesContext(ctx: CheckerContext, arg: Node): boolean {
	return isShapedByContext(ctx, arg) || arg.kind == NodeKind.CallExpr || arg.kind == NodeKind.NewExpr;
}

function isEnumMemberArg(ctx: CheckerContext, arg: Node): boolean {
	if (arg.kind != NodeKind.MemberExpr) return false;
	const obj = (arg.data as MemberExprData).object;
	if (obj.kind != NodeKind.Identifier) return false;
	const sym = lookupSymbol(ctx.table, (obj.data as IdentifierData).name);
	return sym != null && sym.symbolKind == SymbolKind.Enum;
}

function isNumberLiteralArg(arg: Node): boolean {
	if (arg.kind == NodeKind.NumberLiteral) return true;
	if (arg.kind != NodeKind.UnaryExpr) return false;
	const ud = arg.data as UnaryExprData;
	return (ud.unaryOp == "-" || ud.unaryOp == "+") && ud.operand.kind == NodeKind.NumberLiteral;
}

function genericArgOrder(ctx: CheckerContext, args: Node[], isGeneric: boolean): int32[] {
	const order: int32[] = [];
	for (let ai = 0; ai < args.length; ai += 1) {
		if (!isGeneric || !isShapedByContext(ctx, args[ai])) order.push(ai as int32);
	}
	if (!isGeneric) return order;
	for (let ai = 0; ai < args.length; ai += 1) {
		if (isShapedByContext(ctx, args[ai]) && !literalParamsAwaitFormal(args[ai])) order.push(ai as int32);
	}
	for (let ai = 0; ai < args.length; ai += 1) {
		if (literalParamsAwaitFormal(args[ai])) order.push(ai as int32);
	}
	return order;
}

function isTypeLevelAccess(ctx: CheckerContext, obj: Node, property: string): boolean {
	const sym = obj.resolvedSym;
	if (sym == null) return false;
	if (sym.symbolKind == SymbolKind.Class
		|| sym.symbolKind == SymbolKind.Actor
		|| sym.symbolKind == SymbolKind.TypeAlias
		|| sym.symbolKind == SymbolKind.Interface
		|| sym.symbolKind == SymbolKind.Struct
		|| sym.symbolKind == SymbolKind.Enum) return true;
	if (sym.symbolKind != SymbolKind.Function) return false;
	if (obj.kind != NodeKind.Identifier) return false;
	if (findStaticField(sym, property) != null) return true;
	if (ctx.extensionRegistry == null) return false;
	return staticExtsOwnedBy(ctx, findAllExtensionsByName(ctx.extensionRegistry, property), sym, null).length > 0;
}

function parentClassSym(classSym: Symbol): Symbol {
	let inner = classSym.symbolType;
	if (inner != null && inner.kind == TypeKind.Ref && inner.typeReturn != null) inner = inner.typeReturn;
	if (inner != null && inner.typeExtra != null && inner.typeExtra.sym != null) return inner.typeExtra.sym;
	return null as unknown as Symbol;
}

function declaredUnionOfNarrowed(obj: Node): Type | null {
	if (obj.resolvedSym == null || obj.resolvedSym.symbolType == null || obj.resolvedSym.symbolType == obj.nodeType) return null;
	const declared = peelToStructOrUnion(obj.resolvedSym.symbolType);
	return declared != null && declared.kind == TypeKind.Union ? obj.resolvedSym.symbolType : null;
}

function staticExtsOwnedBy(ctx: CheckerContext, exts: ExtensionMethod[], owner: Symbol, objType: Type | null): ExtensionMethod[] {
	for (const e of exts) {
		if (e.isStatic && e.sym != null) ensureShaped(e.sym, ctx);
	}
	const owned = filterStaticExtsByOwner(exts, owner);
	if (owned.length > 0) return owned;
	if (owner.symbolKind == SymbolKind.Class) {
		let base = parentClassSym(owner);
		for (let hops = 0; base != null && hops < 64; hops += 1) {
			const inherited = filterStaticExtsByOwner(exts, base);
			if (inherited.length > 0) return inherited;
			base = parentClassSym(base);
		}
	}
	if (owner.symbolKind != SymbolKind.TypeAlias || objType == null) return owned;
	const denoted = nominalTypeSym(objType);
	return denoted != null && denoted != owner ? filterStaticExtsByOwner(exts, denoted) : owned;
}

function getCalleeName(callee: Node): string {
	if (callee.kind == NodeKind.Identifier) {
		return (callee.data as IdentifierData).name;
	}
	if (callee.kind == NodeKind.MemberExpr) {
		return (callee.data as MemberExprData).property;
	}
	return "<unknown>";
}

function getCalleeNameForDefaults(callNode: Node): string {
	const cd = callNode.data as CallExprData;
	if (cd.callee.kind == NodeKind.Identifier) {
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
	if (clone.nodeType == null) {
		match (clone.kind) {
			NodeKind.NumberLiteral => { clone.nodeType = !isNodeIntLit(clone) ? float64Type() : (literalFitsInType(clone, int32Type(), false) ? int32Type() : createPrimitive(TypeKind.Int64)); },
			NodeKind.BigIntLiteral => { clone.nodeType = createPrimitive(TypeKind.Int64); },
			NodeKind.StringLiteral => { clone.nodeType = stringType(); },
			NodeKind.BooleanLiteral => { clone.nodeType = booleanType(); },
			NodeKind.NullLiteral => { clone.nodeType = nullType(); },
			_ => {},
		};
	}
	return clone;
}

let defaultArgTemps: int32 = 0;

function readEarlierParams(ctx: CheckerContext, cloned: Node, paramNames: string[], defIdx: number, args: Node[],
	defaultOffset: number, paramTypes: Type[], receiverSlot: Node | null, reads: Node[]): Node {
	const earlier: string[] = [];
	for (let k = 0; k < defIdx && k < paramNames.length; k += 1) earlier.push(paramNames[k]);
	const used = referencedParams(cloned, earlier);
	let anyUsed = false;
	for (const u of used) { if (u) anyUsed = true; }
	if (!anyUsed) return cloned;
	const subs: Node[] = [];
	for (let k = 0; k < earlier.length; k += 1) {
		const read = used[k] ? readOfParam(ctx, k, earlier[k], args, defaultOffset, paramTypes, receiverSlot, reads) : null;
		subs.push(read != null ? read : createNodeAt(NodeKind.Identifier, { name: earlier[k] }, cloned.location));
	}
	return substituteParams(cloned, earlier, subs);
}

function readOfParam(ctx: CheckerContext, k: int32, name: string, args: Node[], defaultOffset: number, paramTypes: Type[],
	receiverSlot: Node | null, reads: Node[]): Node | null {
	while (reads.length <= k) reads.push(null as unknown as Node);
	if (reads[k] != null) return cloneNodeKeepSem(reads[k]);
	const argPos = k - defaultOffset;
	let source: Node | null = null;
	if (argPos >= 0 && argPos < args.length) {
		source = args[argPos];
	} else if (argPos < 0 && receiverSlot != null) {
		source = (receiverSlot.data as MemberExprData).object;
	}
	if (source == null || source.nodeType == null) return null;
	if (readsWithoutEffect(source)) {
		reads[k] = source;
		return cloneNodeKeepSem(source);
	}
	const formal = paramTypes != null && k < paramTypes.length ? paramTypes[k] : null;
	if (formal != null && formal.kind == TypeKind.Var) {
		addError(ctx, "a default value reads the ref parameter '" + name + "', so its argument must be a variable",
			source.location.line, source.location.column);
		return cloneNodeKeepSem(source);
	}
	const read = bindArgumentOnce(ctx, source);
	if (argPos >= 0) {
		args[argPos] = read.assign;
	} else {
		(receiverSlot!.data as MemberExprData).object = read.assign;
	}
	reads[k] = read.value;
	return cloneNodeKeepSem(read.value);
}

function readsWithoutEffect(n: Node): boolean {
	if (n.kind == NodeKind.Identifier) return n.resolvedSym != null;
	return n.kind == NodeKind.NumberLiteral || n.kind == NodeKind.StringLiteral
		|| n.kind == NodeKind.BooleanLiteral || n.kind == NodeKind.NullLiteral;
}

interface ArgumentBinding { assign: Node; value: Node; }

function bindArgumentOnce(ctx: CheckerContext, source: Node): ArgumentBinding {
	defaultArgTemps += 1;
	const t = source.nodeType!;
	const loc = source.location;
	const name = "__dflt_" + String(defaultArgTemps);
	const sym = makeSymbol(name, SymbolKind.Variable, t, true);
	setFlag(sym, SymbolFlag.Used);
	if (ctx.currentFunction == null) setFlag(sym, SymbolFlag.Global);
	sym.modulePath = ctx.modulePath;
	sym.location = loc;
	const decl = createNodeAt(NodeKind.VariableDecl, { declName: name, declType: "", initializer: null as unknown as Node, declKind: DeclKind.Let, nameLocation: loc }, loc);
	decl.resolvedSym = sym;
	decl.nodeType = t;
	decl.flags = decl.flags.incl(NodeFlag.Sem);
	sym.declNode = decl;
	ctx.pendingHoisted.push(decl);
	const assign = createNodeAt(NodeKind.BinaryExpr, { operator: "=", left: boundRead(sym, loc), right: source }, loc);
	assign.nodeType = t;
	assign.flags = assign.flags.incl(NodeFlag.Sem);
	return { assign, value: boundRead(sym, loc) };
}

export function takeDefaultArgTemps(ctx: CheckerContext, mark: int32): Node[] {
	const taken: Node[] = [];
	const kept: Node[] = [];
	for (let i = mark; i < ctx.pendingHoisted.length; i += 1) {
		const n = ctx.pendingHoisted[i];
		if (isDefaultArgTemp(n)) taken.push(n); else kept.push(n);
	}
	ctx.pendingHoisted.shrink(mark);
	for (const n of kept) ctx.pendingHoisted.push(n);
	return taken;
}

function isDefaultArgTemp(n: Node): boolean {
	if (n.kind != NodeKind.VariableDecl || n.resolvedSym == null || n.resolvedSym.declNode != n) return false;
	const d = n.data as VariableDeclData;
	return d.initializer == null && d.declType == "";
}

function boundRead(sym: Symbol, loc: SourceLocation): Node {
	const id = createNodeAt(NodeKind.Identifier, { name: sym.name }, loc);
	id.resolvedSym = sym;
	id.nodeType = sym.symbolType;
	id.flags = id.flags.incl(NodeFlag.Sem).incl(NodeFlag.BoundSym);
	return id;
}

// Shared default-filling logic: clone defaults into args array.
// Used by both function calls (fillDefaultArgsForNode) and constructor calls (checkNewExpr).
function fillDefaults(ctx: CheckerContext, args: Node[], defaults: Node[] | null,
	totalParams: number, defaultOffset: number, paramTypes: Type[], definingModulePath: string = "",
	paramNames: string[] | null = null, receiverSlot: Node | null = null): void {
	if (defaults == null) return;
	const reads: Node[] = [];
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
		if (defNode == null) break;
		let cloned = cloneDefaultNode(defNode);
		if (paramNames != null && defIdx > 0) {
			cloned = readEarlierParams(ctx, cloned, paramNames, defIdx, args, defaultOffset, paramTypes, receiverSlot, reads);
		}
		// Type-check with expected param type so empty containers get correct type
		// hint (e.g. `[]` for `string[]` param → msStringArray). `argIdx + defaultOffset`
		// mirrors the `defaults[]` indexing two lines above — both arrays include the
		// receiver slot for non-static methods (collectPass.ms:378-385 aligns them), so
		// the same offset skips it.
		const expectedType = paramTypes != null && argIdx + defaultOffset < paramTypes.length ? paramTypes[argIdx + defaultOffset] : null;
		const diagnosticMark = defCtx.errors.length;
		callCheckExpr(defCtx, cloned, expectedType);
		const fitted = expectedType != null && !hasGenericParams(expectedType) ? fitNode(defCtx, cloned, expectedType, cloned.nodeType) : cloned;
		if (defaultCheckedAtDeclaration(defNode)) defCtx.errors.shrink(diagnosticMark);
		args.push(fitted);
		argIdx = argIdx + 1;
	}
}

// A callee with no declaration (a value of function type) has no default nodes, so an
// omitted optional argument is the null its nullable parameter type carries.
function fillNullableTail(ctx: CheckerContext, args: Node[], paramTypes: Type[], loc: SourceLocation): void {
	while (args.length < paramTypes.length) {
		const expected = paramTypes[args.length];
		if (expected.kind != TypeKind.Null && !isMaybeType(expected) && !unionHasMemberOfKind(expected, TypeKind.Null)) return;
		const lit = createNodeAt(NodeKind.NullLiteral, { nullPlaceholder: true }, loc);
		callCheckExpr(ctx, lit, expected);
		args.push(fitNode(ctx, lit, expected, lit.nodeType));
	}
}

// Reference parity: fill missing call arguments from parameter defaults.
// defaultOffset accounts for receiver param in extension methods:
// fnDefaults[0] = receiver (no default), so call arg index N maps to fnDefaults[N + offset].
function declaredDefaults(defSym: Symbol | null): Node[] | null {
	if (defSym == null) return null;
	if (defSym.defaultParams.length > 0) return defSym.defaultParams;
	if (defSym.declNode != null && defSym.declNode.kind == NodeKind.FunctionDecl) {
		const declData = defSym.declNode.data as FunctionDeclData;
		if (declData.fnDefaults != null) return declData.fnDefaults;
	}
	return null;
}

function fillDefaultArgsForNode(ctx: CheckerContext, callNode: Node, fnName: string,
	totalParams: number, defaultOffset: number, chosen: Symbol | null = null): void {
	const cd = callNode.data as CallExprData;
	// Check callee.resolvedSym first, then callNode.resolvedSym (extension methods set sym on CallExpr)
	const defSym = chosen != null ? chosen : (cd.callee.resolvedSym != null ? cd.callee.resolvedSym : callNode.resolvedSym);
	const fnDefaults = declaredDefaults(defSym);
	// Pass parameter types so default expressions get correct type hints
	// (e.g., empty array [] for string[] param → msStringArray, not msRefArray).
	let paramTypes: Type[] = [];
	let paramNames: string[] | null = null;
	if (defSym != null && defSym.symbolType != null && defSym.symbolType.typeChildren != null) {
		paramTypes = defSym.symbolType.typeChildren;
		paramNames = defSym.symbolType.typeNames;
	}
	const definingModulePath = defSym != null ? defSym.modulePath : "";
	const receiverSlot = defaultOffset > 0 && cd.callee.kind == NodeKind.MemberExpr ? cd.callee : null;
	fillDefaults(ctx, cd.arguments, fnDefaults, totalParams, defaultOffset, paramTypes, definingModulePath, paramNames, receiverSlot);
}

function instanceBindings(params: Type[], args: Type[]): UnifyBindings {
	const b = createUnifyBindings();
	for (let i = 0; i < params.length; i += 1) bindParam(b, params[i], args[i]);
	return b;
}

function checkNewArgs(ctx: CheckerContext, args: Node[]): void {
	for (const arg of args) { callCheckExpr(ctx, arg, null); }
}

function fitPositionalArgs(ctx: CheckerContext, args: Node[], fields: Type | null): void {
	for (let ai = 0; ai < args.length; ai += 1) {
		const formal = fields != null && ai < fields.typeChildren.length ? fields.typeChildren[ai] : null;
		callCheckExpr(ctx, args[ai], formal);
		if (formal != null && args[ai].nodeType != null) args[ai] = fitNode(ctx, args[ai], formal, args[ai].nodeType);
	}
}

function typeNewCallee(ctx: CheckerContext, callee: Node): void {
	const sym = lookupSymbol(ctx.table, (callee.data as IdentifierData).name);
	if (sym == null) return;
	callee.resolvedSym = sym;
	callee.nodeType = sym.symbolType;
}

function soleMethodCandidate(ctx: CheckerContext, method: Symbol, me: MemberExprData): boolean {
	if (method.overloads.length > 0 || method.overloadIdx > 0) return false;
	if (ctx.extensionRegistry == null || me.object.nodeType == null) return true;
	return filterExtsByReceiverType(findAllExtensionsByName(ctx.extensionRegistry, me.property), peelTransparentInstance(me.object.nodeType)).length <= 1;
}

function isStdPromise(sym: Symbol | null): boolean {
	return sym != null && sym.builtinKind == "Promise";
}

function refuseThenable(ctx: CheckerContext, site: string, operand: Node, reason: string): void {
	addError(ctx, `${site} must either be a valid promise or must not contain a callable 'then' member: ${reason}`, operand.location.line, operand.location.column);
}

type ThenableAdoption = { call: Node, promised: Type };

function thenableAdoption(ctx: CheckerContext, operand: Node, site: string): ThenableAdoption | null {
	const t = operand.nodeType;
	if (t == null || isAwaitable(t) || isUnresolvedType(t)) return null;
	const then = thenSignatureOf(ctx, t);
	if (then == null) return null;
	const owner = typeDisplayName(t);
	const onFulfilled = then.typeChildren.length > 0 ? functionSlotOf(then.typeChildren[0]) : null;
	if (onFulfilled == null) {
		refuseThenable(ctx, site, operand, `the first parameter of '${owner}.then' must be a callback`);
		return null;
	}
	const promised = onFulfilled.typeChildren.length > 0 ? onFulfilled.typeChildren[0] : voidType();
	if (hasGenericParams(promised)) {
		refuseThenable(ctx, site, operand, `'${owner}.then' delivers the type parameter '${typeDisplayName(promised)}': declare the type its callback receives`);
		return null;
	}
	if (isAwaitable(promised) || thenSignatureOf(ctx, promised) != null) {
		refuseThenable(ctx, site, operand, `'${owner}.then' delivers '${typeDisplayName(promised)}', which is awaitable itself, and a promise never holds a promise: settle it with the inner value`);
		return null;
	}
	const passesReject = then.typeChildren.length > 1;
	if (passesReject) {
		const onRejected = functionSlotOf(then.typeChildren[1]);
		const reason = onRejected != null && onRejected.typeChildren.length > 0 ? onRejected.typeChildren[0] : null;
		const errorSym = lookupSymbol(ctx.table, "Error");
		if (reason == null || errorSym == null || !derivesFromClass(reason, errorSym)) {
			const got = reason != null ? `, not '${typeDisplayName(reason)}'` : "";
			refuseThenable(ctx, site, operand, `the second parameter of '${owner}.then' must be a callback taking an Error${got}, the reason an awaited promise rejects with`);
			return null;
		}
	}
	const loc = operand.location;
	const thenArgs: Node[] = [createNodeAt(NodeKind.Identifier, { name: "fulfil" }, loc)];
	if (passesReject) thenArgs.push(createNodeAt(NodeKind.Identifier, { name: "reject" }, loc));
	const thenee = createNodeAt(NodeKind.MemberExpr, { object: createNodeAt(NodeKind.Identifier, { name: "thenable" }, loc), property: "then", isOptional: false }, loc);
	const thenCall = createNodeAt(NodeKind.CallExpr, { callee: thenee, arguments: thenArgs, isDirectCall: true, resolvedOverloadIdx: -1 }, loc);
	const callThen = createNodeAt(NodeKind.ArrowFunction, {
		arrowParams: ["thenable", "fulfil", "reject"], arrowParamTypes: ["", "", ""],
		arrowBody: createNodeAt(NodeKind.BlockStmt, { statements: [createNodeAt(NodeKind.ExprStmt, { expr: thenCall }, loc)] }, loc),
		arrowFlags: "", arrowReturnType: "", arrowDefaults: [null as unknown as Node, null as unknown as Node, null as unknown as Node],
	}, loc);
	const call = createNodeAt(NodeKind.CallExpr, { callee: createNodeAt(NodeKind.Identifier, { name: "promiseFromThenable" }, loc), arguments: [operand, callThen], isDirectCall: true, resolvedOverloadIdx: -1 }, loc);
	return { call, promised };
}

export function adoptThenable(ctx: CheckerContext, operand: Node, site: string): Node {
	const adoption = thenableAdoption(ctx, operand, site);
	if (adoption == null) return operand;
	callCheckExpr(ctx, adoption.call, createPromise(adoption.promised));
	return adoption.call;
}

export function adoptAwaitedThenable(ctx: CheckerContext, d: AwaitExprData): void {
	d.awaitArg = adoptThenable(ctx, d.awaitArg, "Type of 'await' operand");
}

export function awaitReturnedThenable(ctx: CheckerContext, value: Node): Node {
	const adopted = adoptThenable(ctx, value, "The value an async function returns");
	if (adopted == value) return value;
	if (ctx.tryGuardedFunction != null && ctx.tryGuardedFunction == ctx.currentFunction) {
		addError(ctx, "a returned thenable is not awaited inside try — write `return await …` so catch and finally see its result", value.location.line, value.location.column);
	}
	const awaited = createNodeAt(NodeKind.AwaitExpr, { awaitArg: adopted }, value.location);
	callCheckExpr(ctx, awaited, null);
	return awaited;
}

export function raisedOperand(ctx: CheckerContext, operand: Node): Node | null {
	callCheckExpr(ctx, operand, null);
	const argType = operand.nodeType;
	if (argType == null || argType.kind == TypeKind.Error || isUnresolvedType(argType) || hasGenericParams(argType)) return operand;
	const errSym = lookupSymbol(ctx.table, "Error");
	if (errSym == null || errSym.symbolType == null) {
		addError(ctx, "throw needs the std 'Error' class in scope", operand.location.line, operand.location.column);
		return null;
	}
	const opaque = isUnknownType(argType);
	if (!opaque && isAssignable(argType, errSym.symbolType)) return operand;
	if (opaque || !isAssignable(argType, stringType())) {
		addError(ctx, "only an 'Error' or a 'string' can be thrown, got '" + typeDisplayName(argType) + "'", operand.location.line, operand.location.column);
		return null;
	}
	const loc = operand.location;
	const callee = createNodeAt(NodeKind.Identifier, { name: "Error" }, loc);
	ensureShaped(errSym, ctx);
	markUsedIn(ctx, errSym);
	callee.resolvedSym = errSym;
	callee.nodeType = errSym.symbolType;
	callee.flags = callee.flags.incl(NodeFlag.BoundSym).incl(NodeFlag.Sem);
	const boxed = createNodeAt(NodeKind.NewExpr, { newCallee: callee, newArguments: [operand] }, loc);
	callCheckExpr(ctx, boxed, null);
	return boxed;
}

const PROMISE_COMBINATORS = ["all", "race", "any", "allSettled"];

function promiseStaticOf(ctx: CheckerContext, callee: Node): string {
	if (callee.kind != NodeKind.MemberExpr) return "";
	const m = callee.data as MemberExprData;
	if (m.object.kind != NodeKind.Identifier || (m.object.data as IdentifierData).name != "Promise") return "";
	return isStdPromise(lookupSymbol(ctx.table, "Promise")) ? m.property : "";
}

function takesContext(n: Node): boolean {
	return n.kind == NodeKind.ArrowFunction || n.kind == NodeKind.FunctionExpr;
}

function resolvedValueContext(ctx: CheckerContext, node: Node, expected: Type | null): Type | null {
	const spelled = explicitTypeArgs(node, ctx, 1);
	if (spelled.length > 0 && spelled[0] != null) return spelled[0];
	return expected != null && isAwaitable(expected) ? awaitedType(expected) : null;
}

function adoptPromiseInputs(ctx: CheckerContext, node: Node, expected: Type | null): Type | null {
	if (node.kind != NodeKind.CallExpr) return expected;
	const d = node.data as CallExprData;
	const name = promiseStaticOf(ctx, d.callee);
	if (name == "" || d.arguments.length != 1 || takesContext(d.arguments[0])) return expected;
	const arg = d.arguments[0];
	if (name == "reject") {
		const raised = raisedOperand(ctx, arg);
		if (raised != null) d.arguments[0] = raised;
		else arg.nodeType = errorType();
		return expected;
	}
	if (name == "resolve") {
		callCheckExpr(ctx, arg, resolvedValueContext(ctx, node, expected));
		const adoption = thenableAdoption(ctx, arg, "The value 'Promise.resolve' takes");
		if (adoption == null) return expected;
		node.data = adoption.call.data;
		return createPromise(adoption.promised);
	}
	if (PROMISE_COMBINATORS.indexOf(name) < 0 || arg.kind != NodeKind.ArrayLiteral) return expected;
	const elements = (arg.data as ArrayLiteralData).elements;
	for (let i = 0; i < elements.length; i += 1) {
		const el = elements[i];
		if (el == null || takesContext(el) || el.kind == NodeKind.SpreadExpr) continue;
		callCheckExpr(ctx, el, null);
		elements[i] = adoptThenable(ctx, el, `An element of 'Promise.${name}'`);
	}
	return expected;
}

function refusePromiseOfThenable(ctx: CheckerContext, node: Node, result: Type): void {
	if (node.kind != NodeKind.CallExpr || !isAwaitable(result)) return;
	const held = awaitedType(result);
	const promised = thenablePromised(ctx, held);
	if (held == null || promised == null) return;
	addError(ctx, `this call makes '${typeDisplayName(result)}', a promise of a thenable, which is refused: a promise adopts what a thenable delivers, so it holds '${typeDisplayName(promised)}'`, node.location.line, node.location.column);
}

function checkPromiseConstruction(ctx: CheckerContext, node: Node, expected: Type | null): Type {
	const d = node.data as NewExprData;
	const factory = ctx.compilerFuncs.get("promiseFromExecutor");
	if (factory == null) throw new Error("internal: the prelude declares no @compilerFunc promiseFromExecutor");
	const call = boundCallOf(factory, d.newArguments, d.newCallee.location);
	node.kind = NodeKind.CallExpr;
	node.data = call.data;
	const promise = checkCallExpr(ctx, node, expected);
	const held = isAwaitable(promise) ? awaitedType(promise) : null;
	if (held != null && isAwaitable(held)) {
		addError(ctx, "'new Promise<" + typeDisplayName(held) + ">' is refused: its resolve would receive a promise, and a synchronous executor cannot await it; resolve the value itself", node.location.line, node.location.column);
	}
	return promise;
}

// `new S(a, b)` on a struct is its object constructor, the literal `{ f0: a, f1: b }`:
// checked as that literal, an omitted field takes its zero value under the literal's rules.
function checkStructConstruction(ctx: CheckerContext, node: Node, structType: Type): Type | null {
	const d = node.data as NewExprData;
	const fields = positionalFieldsOf(structType);
	if (fields == null || d.newArguments.length > fields.typeNames.length) return null;
	for (const arg of d.newArguments) { if (arg.kind == NodeKind.SpreadExpr) return null; }
	node.kind = NodeKind.ObjectLiteral;
	node.data = { properties: d.newArguments, keys: fields.typeNames.slice(0, d.newArguments.length), keyLocations: [] } as ObjectLiteralData;
	callCheckExpr(ctx, node, structType);
	return node.nodeType!;
}

export function checkNewExpr(ctx: CheckerContext, node: Node, expected: Type | null): Type {
	const d = node.data as NewExprData;
	d.newArguments = expandTupleSpreads(ctx, inlineLiteralSpreads(d.newArguments));
	// new BuiltinType<...>() — construct value types (Map, Set) and Promise
	if (d.newCallee.kind == NodeKind.Identifier) {
		const id = d.newCallee.data as IdentifierData;
		if (isStdPromise(lookupSymbol(ctx.table, id.name))) return checkPromiseConstruction(ctx, node, expected);
		// new Arc(value): atomic-refcounted shared box. Pointee type is the explicit
		// <T> if present, else inferred from the single argument. Represented as a
		// Ref with the IsAtomic flag — codegen boxes the value via msAllocArc.
		const head = builtinTypeHead(ctx, id.name);
		if (head == "Arc" && d.newArguments.length == 1) {
			const ltCol = d.newCallee.location.column + id.name.length;
			const typeArgStr = node.typeArg;
			let pointee = null as unknown as Type;
			if (typeArgStr != "") {
				pointee = resolveAnnotation(typeArgStr.trim(), ctx, d.newCallee.location.line, ltCol + 1);
			} else if (expected != null && isAtomicRef(expected) && !isLockedRef(expected) && expected.typeReturn != null) {
				pointee = expected.typeReturn;
			}
		callCheckExpr(ctx, d.newArguments[0], pointee);
		const pointeeArgType = d.newArguments[0].nodeType;
		if (pointee == null && pointeeArgType != null) { pointee = pointeeArgType; }
		// SHARE pointee rule (PARALOCK Amendment I): the pointee is aliased
		// across threads, so it must be deep-immutable data.
		if (pointee != null && pointee.kind != TypeKind.Error) {
			checkArcPointeeSendable(ctx, pointee, (owner: Type): boolean => declaresUserHook(owner, ctx), d.newCallee.location.line, d.newCallee.location.column);
		}
		const arcType = createArc(pointee);
			typeNewCallee(ctx, d.newCallee);
			node.nodeType = arcType;
			return arcType;
		}
		// new Locked(value): the one shared-MUTABLE cell (PARALOCK I22). One
		// allocation — atomic-rc header + inline ticket lock + typed payload —
		// so the handle is an atomic Ref like Arc and rides every mechanism Arc
		// already drives. nativeLower boxes it via msBoxLocked.
		if (checkNewProxy(ctx, node, expected)) return node.nodeType!;
		if (head == "Locked" && d.newArguments.length == 1) {
			const ltCol = d.newCallee.location.column + id.name.length;
			const typeArgStr = node.typeArg;
			let payload = null as unknown as Type;
			if (typeArgStr != "") {
				payload = resolveAnnotation(typeArgStr.trim(), ctx, d.newCallee.location.line, ltCol + 1);
			} else if (expected != null && isLockedRef(expected)) {
				payload = lockedPayloadType(expected);
			}
			callCheckExpr(ctx, d.newArguments[0], payload);
			const payloadArgType = d.newArguments[0].nodeType;
			if (payload == null && payloadArgType != null) { payload = payloadArgType; }
			if (payload != null && payload.kind != TypeKind.Error) {
				checkLockedPayloadSendable(ctx, payload, (owner: Type): boolean => declaresUserHook(owner, ctx), d.newCallee.location.line, d.newCallee.location.column);
			}
			const lockedType = createLocked(payload);
			typeNewCallee(ctx, d.newCallee);
			node.nodeType = lockedType;
			return lockedType;
		}
		// Interface/value type: new HashMap() / new Array(32) with type from variable annotation
		// Also handle Ref<Struct> and Ref<GenericInstance> (interface types are Ref-wrapped)
		const newSym = lookupSymbol(ctx.table, id.name);
		if (expected != null && (expected.kind == TypeKind.Struct || expected.kind == TypeKind.GenericInstance)
				&& expected.typeName == id.name && (newSym == null || !hasFlag(newSym, SymbolFlag.HasConstructor))) {
			typeNewCallee(ctx, d.newCallee);
			const built = newSym != null ? checkStructConstruction(ctx, node, expected) : null;
			if (built != null) return built;
			node.nodeType = expected;
			fitPositionalArgs(ctx, d.newArguments, newSym != null ? positionalFieldsOf(expected) : null);
			return expected;
		}
		// Array with expected element type: new Array(32) in typed context.
		// After the reference-array flip `expected` is Ref<Array>; accept both —
		// the result keeps `expected` (Ref<Array>) and nativeLower boxes the value.
		const expectedArrInner = (expected != null && expected.kind == TypeKind.Ref
			&& expected.typeReturn != null && expected.typeReturn.kind == TypeKind.Array)
			? expected.typeReturn : expected;
		if (expected != null && expectedArrInner != null && expectedArrInner.kind == TypeKind.Array && id.name == "Array") {
			typeNewCallee(ctx, d.newCallee);
			node.nodeType = expected;
			checkNewArgs(ctx, d.newArguments);
			if (d.newArguments.length > 0 && hiddenHolder(ctx, expectedArrInner.typeReturn, 0) != null) {
				addError(ctx, `new Array(count) would fill the array with default values: ${noDefaultReason(ctx, expectedArrInner.typeReturn)} — push values instead`, node.location.line, node.location.column);
			}
			return expected;
		}
		// new Array<T>() or new Array<T>(size) — resolve element type from explicit type arg
		if (id.name == "Array") {
			// Record Array symbol for hover/go-to-definition consistency
			const arraySym = lookupSymbol(ctx.table, "Array");
			if (arraySym != null) {
				sgRecordSym(ctx, d.newCallee.location.line, d.newCallee.location.column, d.newCallee.location.column + 5, arraySym, arraySym.symbolType, arraySym.symbolKind, "Array", "", false);
			}
			const ltCol = d.newCallee.location.column + id.name.length;
			const typeArgStr = node.typeArg;
			if (typeArgStr != "") {
				const trimmed = typeArgStr.trim();
				const elemType = resolveAnnotation(trimmed, ctx, d.newCallee.location.line, ltCol + 1);
				// Record type arg symbol for hover/go-to-definition
				const typeArgSym = lookupSymbol(ctx.table, trimmed);
				if (typeArgSym != null) {
					sgRecordSym(ctx, d.newCallee.location.line, ltCol + 1, ltCol + 1 + trimmed.length, typeArgSym, typeArgSym.symbolType, typeArgSym.symbolKind, trimmed, "", false);
				}
				const arrType = createRef(createArray(elemType));
				typeNewCallee(ctx, d.newCallee);
				node.nodeType = arrType;
				checkNewArgs(ctx, d.newArguments);
				if (d.newArguments.length > 0 && requiresInit(ctx, elemType)) {
					addError(ctx, `new Array<${trimmed}>(count) would fill the array with default values: ${noDefaultReason(ctx, elemType)} — push values instead`, node.location.line, node.location.column);
				}
				return arrType;
			}
		}
		// Promise, Map, Set all resolve through resolveGenericNewExpr below
	}
	checkInTypeSlot(ctx, d.newCallee);
	const calleeType = d.newCallee.nodeType;
	// Pass the NewExpr's AST-resident typeArg so resolveGenericNewExpr can prefer
	// it over the stale location-keyed side channel (important for cloned bodies).
	// Also pass `expected` so that `const m: Map<K, V> = new Map();` (no type
	// args on the `new`) can pull K/V from the contextual annotation.
	const generic = resolveGenericNewExpr(ctx, d.newCallee, calleeType!, node.typeArg, expected);
	const resolvedType = generic.type;
	// Error: generic type without type args AND no inferable contextual type.
	// `resolveGenericNewExpr` returns the bare `calleeType` (still
	// `Ref<GenericInstance>` with un-substituted GenericParam children) when
	// it couldn't resolve type args from any source — that's the signal
	// that we should report.
	if (d.newCallee.kind == NodeKind.Identifier) {
		const calleeName2 = (d.newCallee.data as IdentifierData).name;
		const genericParams2 = d.newCallee.resolvedSym != null ? symGenericParams(d.newCallee.resolvedSym) : builtinGenericParams(calleeName2);
		if (genericParams2 != "") {
			const noExplicit = node.typeArg == "";
			// Treat the contextual-inference path as "satisfied" iff the
			// peeled expected type matched the callee's name. Without this
			// guard a contextual mismatch (`const m: Map<K,V> = new Set()`)
			// would silently slip through; with it, the error still fires
			// for genuinely under-specified `new`s.
			const giCtx2 = peelToGenericInstance(expected);
			const giCtxOk = giCtx2 != null && instantiates(giCtx2, d.newCallee.resolvedSym, calleeName2);
			if (noExplicit && !giCtxOk) {
				addError(ctx, `'new ${calleeName2}()' requires explicit type arguments: new ${calleeName2}<...>()`, node.location.line, node.location.column);
			}
			if (!noExplicit) checkExplicitTypeArgArity(ctx, node, extractGenericNames("gen:" + genericParams2), calleeName2);
		}
	}
	if (resolvedType != null && (resolvedType.kind == TypeKind.Struct || resolvedType.kind == TypeKind.GenericInstance)
			&& d.newCallee.resolvedSym != null && !hasFlag(d.newCallee.resolvedSym, SymbolFlag.HasConstructor)) {
		const built = checkStructConstruction(ctx, node, resolvedType);
		if (built != null) return built;
	}
	// Resolve inner struct type for field type propagation
	const innerType = (resolvedType != null && resolvedType.kind == TypeKind.Ref && resolvedType.typeReturn != null)
		? resolvedType.typeReturn : resolvedType;
	// Type-check constructor arguments.
	// If class has constructor, use constructor's param types as argExpected
	// (with class generic params substituted from explicit `<T,U>` so
	// closure args see concrete types — Phase C parity with checkCallExpr).
	// Otherwise use struct field types as expected (positional initialization).
	const classSym = d.newCallee.resolvedSym;
	const hasCtor = classSym != null && hasFlag(classSym, SymbolFlag.HasConstructor);
	const declaredCtor = ctorRoutineOf(classSym);
	let ctorFormals: Type[] | null = null;
	if (hasCtor && classSym != null) {
		const rawCtorTypes = ctorFormalTypes(declaredCtor);
		if (rawCtorTypes != null && rawCtorTypes.length > 0) {
			ctorFormals = rawCtorTypes;
			const classGenericDecl = symGenericParams(classSym);
			if (classGenericDecl != "") {
				const classGenericNames: string[] = [];
				const segs = splitTopLevel(classGenericDecl, ",");
				for (const seg of segs) {
					const trimmed = seg.trim();
					const colonAt = findChar(trimmed, ":");
					classGenericNames.push(colonAt > 0 ? trimmed.slice(0, colonAt).trim() : trimmed);
				}
				const classBindings = innerType != null && innerType.kind == TypeKind.GenericInstance
					&& innerType.typeChildren.length == classGenericNames.length
					? instanceBindings(ownTypeParams(classSym, classGenericNames), innerType.typeChildren)
					: bindFromExplicitTypeArgs(node, ownTypeParams(classSym, classGenericNames), ctx);
				if (classBindings.names.length > 0) {
					const substituted: Type[] = [];
					for (const t of rawCtorTypes) {
						substituted.push(substituteBound(t, classBindings));
					}
					ctorFormals = substituted;
				}
			}
		}
	}
	const fields = hasCtor ? null : positionalFieldsOf(innerType);
	const ctorRestIdx = hasCtor && ctorFormals != null && ctorFormals.length > 0
		&& ctorFormals[ctorFormals.length - 1].kind == TypeKind.Varargs ? ctorFormals.length - 1 : -1;
	let ai = 0;
	while (ai < d.newArguments.length) {
		let argExpected: Type | null = null;
		if (ctorRestIdx >= 0 && ai >= ctorRestIdx) {
			const restArr = unwrapRef(unwrapVarargs(ctorFormals![ctorRestIdx]));
			const restElem = getElementType(restArr);
			argExpected = restElem.kind == TypeKind.Inferred || d.newArguments[ai].kind == NodeKind.SpreadExpr ? restArr : restElem;
		} else if (hasCtor && ctorFormals != null && ai < ctorFormals.length) {
			argExpected = ctorFormals[ai];
		} else if (fields != null && ai < fields.typeChildren.length) {
			argExpected = fields.typeChildren[ai];
		}
		callCheckExpr(ctx, d.newArguments[ai], argExpected);
		iterateSpreadSource(ctx, d.newArguments[ai]);
		const argType = d.newArguments[ai].nodeType;
		if (argExpected != null && argType != null) {
			d.newArguments[ai] = fitNode(ctx, d.newArguments[ai], argExpected, argType);
		}
		ai = ai + 1;
	}
	const ctorOwner = generic.instance != null ? generic.instance : classSym;
	const ctorRoutine = ctorOwner != null ? ctorRoutineFor(ctx, ctorOwner) : null;
	const declaring = hasCtor && ctorOwner != null ? constructorDeclaringClass(ctorOwner) : null;
	if (hasCtor && ctorOwner != null) refuseHiddenConstructor(ctx, declaring != null ? declaring : ctorOwner, node.location.line, node.location.column);
	const defaultsFrom = declaring != null ? ctorRoutineOf(declaring) : ctorRoutine;
	const routineFormals = hasCtor && ctorRoutine != null ? ctorFormalTypes(ctorRoutine) : null;
	let ctorSpread: SpreadTake = { spread: null, at: -1, taken: false };
	if (routineFormals != null && defaultsFrom != null) {
		const pd: ParamDefaults = { defaults: defaultsFrom.defaultParams, names: defaultsFrom.symbolType.typeNames.slice(1), offset: 0 };
		ctorSpread = takeOptionalSpread(ctx, d.newArguments, [], pd, routineFormals, firstDefaulted(pd, routineFormals));
	}
	if (classSym != null && (ctorSpread.spread == null || ctorSpread.taken)) {
		checkNewArity(ctx, node, classSym, innerType, ctorRoutine, defaultsFrom);
	}
	if (routineFormals != null && defaultsFrom != null) {
		fillDefaults(ctx, d.newArguments, defaultsFrom.defaultParams, routineFormals.length, 0, routineFormals, defaultsFrom.modulePath, defaultsFrom.symbolType.typeNames.slice(1));
		fillTakenSpread(ctx, d.newArguments, [], ctorSpread, routineFormals);
	}
	node.resolvedSym = ctorRoutine;
	if (!hasCtor && d.newArguments.length == 0 && d.newCallee.resolvedSym != null) {
		const missing = fieldsWithoutDefault(ctx, d.newCallee.resolvedSym, 0);
		if (missing.length > 0) {
			addError(ctx, `'new ${d.newCallee.resolvedSym.name}()' leaves ${missing.map((m) => `'${m}'`).join(", ")} without a value: the class has no constructor and the field's type has no default value — give the field an initializer, add a constructor that assigns it, or declare it optional with '?'`, node.location.line, node.location.column);
		}
	}
	if (generic.instance != null) d.newCallee.resolvedSym = generic.instance;
	if (resolvedType != null && (resolvedType.kind == TypeKind.Struct || resolvedType.kind == TypeKind.Ref || resolvedType.kind == TypeKind.GenericInstance)) {
		return resolvedType;
	}
	return inferredType();
}

function hashesAsItsBase(t: Type): boolean {
	return isIntegerType(t) || t.kind == TypeKind.Char || t.kind == TypeKind.Boolean || t.kind == TypeKind.Enum;
}

export function refuseUnhashableKey(ctx: CheckerContext, collection: Type, at: Node): boolean {
	const owner = collection.kind == TypeKind.Ref && collection.typeReturn != null ? collection.typeReturn : collection;
	if (owner.kind != TypeKind.GenericInstance || owner.typeChildren.length == 0 || !isStdCollection(owner)) return false;
	const key = owner.typeChildren[0];
	const named = peelThrough(key, PEEL_ALIAS);
	if (named == null || distinctBody(named) == null || isBrandDistinct(named) || proxyPartsOf(ctx, named) != null) return false;
	let base: Type | null = named;
	let body = distinctBody(named);
	while (body != null) {
		base = peelThrough(body, PEEL_ALIAS);
		body = distinctBody(base);
	}
	if (base == null || hashesAsItsBase(base) || ctx.extensionRegistry == null) return false;
	const declared = declaredKeyHash(ctx.extensionRegistry, key);
	if (declared != null && hasFlag(declared, SymbolFlag.Exported)) return false;
	const name = typeDisplayName(key);
	addError(ctx, `'${name}' cannot be a ${owner.typeName} key: a distinct type hashes as its base only over an integer, char, boolean or enum, and '${name}' is over '${typeDisplayName(base)}' — declare 'export function hash(this k: ${name}): int64'`, at.location.line, at.location.column);
	return true;
}

function requiredCtorArgs(formals: Type[], defaults: Node[] | null): int32 {
	let required: int32 = 0;
	for (let i = 0; i < formals.length; i += 1) {
		const hasDefault = defaults != null && i < defaults.length && defaults[i] != null;
		if (!hasDefault && formals[i].kind != TypeKind.Varargs) required = i + 1;
	}
	return required;
}

function inlineLiteralSpreads(args: Node[]): Node[] {
	let found = false;
	for (const a of args) { if (isLiteralSpread(a)) { found = true; break; } }
	if (!found) return args;
	const out: Node[] = [];
	for (const a of args) pushEffectiveArg(out, a);
	return out;
}

function isLiteralSpread(a: Node): boolean {
	return a.kind == NodeKind.SpreadExpr && (a.data as SpreadExprData).spreadArg.kind == NodeKind.ArrayLiteral;
}

function pushEffectiveArg(out: Node[], a: Node): void {
	if (!isLiteralSpread(a)) {
		out.push(a);
		return;
	}
	for (const e of ((a.data as SpreadExprData).spreadArg.data as ArrayLiteralData).elements) pushEffectiveArg(out, e);
}

function expandTupleSpreads(ctx: CheckerContext, args: Node[]): Node[] {
	let out: Node[] | null = null;
	for (let i = 0; i < args.length; i += 1) {
		const tuple = spreadTupleType(ctx, args[i]);
		if (tuple == null) {
			if (out != null) out.push(args[i]);
			continue;
		}
		if (out == null) out = args.slice(0, i);
		const source = (args[i].data as SpreadExprData).spreadArg;
		const spread = readSpreadSource(ctx, source);
		for (let e = 0; e < tuple.typeChildren.length; e += 1) {
			out.push(elementRead(e == 0 ? spread.first : cloneNodeKeepSem(spread.again), e, source.location));
		}
	}
	return out != null ? out : args;
}

function spreadTupleType(ctx: CheckerContext, a: Node): Type | null {
	if (a.kind != NodeKind.SpreadExpr) return null;
	const source = (a.data as SpreadExprData).spreadArg;
	callCheckExpr(ctx, source, null);
	const t = bareSpreadSource(source.nodeType);
	return t != null && t.kind == TypeKind.Tuple && t.typeChildren.length > 0 ? t : null;
}

interface SpreadRead { first: Node; again: Node; }

function readSpreadSource(ctx: CheckerContext, source: Node): SpreadRead {
	if (readsWithoutEffect(source)) return { first: source, again: source };
	const bound = bindArgumentOnce(ctx, source);
	return { first: bound.assign, again: bound.value };
}

function elementRead(source: Node, index: int32, loc: SourceLocation): Node {
	return createNodeAt(NodeKind.ArrayAccess, { array: source, index: indexLiteral(index, loc) }, loc);
}

function indexLiteral(index: int32, loc: SourceLocation): Node {
	return createNodeAt(NodeKind.NumberLiteral,
		{ value: index, isFloat: false, intVal: index as int64, outOfRangeText: "", isBitPattern: false }, loc);
}

function optionalSpreadAt(args: Node[], formals: Type[], minArgs: number): int32 {
	const at = args.length - 1;
	if (at < minArgs || at >= fixedCount(formals) || args[at].kind != NodeKind.SpreadExpr) return -1;
	for (let i = 0; i < at; i += 1) { if (args[i].kind == NodeKind.SpreadExpr) return -1; }
	const source = bareSpreadSource((args[at].data as SpreadExprData).spreadArg.nodeType);
	return source != null && source.kind == TypeKind.Array ? at : -1;
}

function fixedCount(formals: Type[]): int32 {
	const n = formals.length;
	return n > 0 && formals[n - 1].kind == TypeKind.Varargs ? n - 1 : n;
}

interface ParamDefaults { defaults: Node[] | null; names: string[]; offset: int32; }

function calleeDefaults(node: Node, chosen: Symbol | null, offset: int32): ParamDefaults {
	const d = node.data as CallExprData;
	const sym = chosen != null ? chosen : (d.callee.resolvedSym != null ? d.callee.resolvedSym : node.resolvedSym);
	const names: string[] = [];
	if (sym != null && sym.symbolType != null) { for (const n of sym.symbolType.typeNames) names.push(n); }
	return { defaults: declaredDefaults(sym), names, offset };
}

function firstDefaulted(pd: ParamDefaults, formals: Type[]): int32 {
	const defaults = pd.defaults;
	let from = fixedCount(formals);
	while (defaults != null && from > 0 && from - 1 + pd.offset < defaults.length
		&& defaults[from - 1 + pd.offset] != null) from -= 1;
	return from;
}

function defaultReadsSpreadSlot(ctx: CheckerContext, spread: Node, pd: ParamDefaults, at: int32, formals: Type[]): boolean {
	const defaults = pd.defaults;
	if (defaults == null) return false;
	const names = pd.names;
	const o = pd.offset;
	for (let k = at + 1; k < fixedCount(formals); k += 1) {
		const def = k + o < defaults.length ? defaults[k + o] : null;
		if (def == null || k + o >= names.length) continue;
		const filled = names.slice(at + o, k + o);
		const used = referencedParams(def, filled);
		for (let u = 0; u < used.length; u += 1) {
			if (!used[u]) continue;
			addError(ctx, `the default value of parameter '${names[k + o]}' reads '${filled[u]}', which the spread argument fills: pass the arguments one by one`,
				spread.location.line, spread.location.column);
			return true;
		}
	}
	return false;
}

function trailingArraySpread(args: Node[]): int32 {
	const at = args.length - 1;
	if (at < 0 || args[at].kind != NodeKind.SpreadExpr) return -1;
	for (let i = 0; i < at; i += 1) { if (args[i].kind == NodeKind.SpreadExpr) return -1; }
	const source = bareSpreadSource((args[at].data as SpreadExprData).spreadArg.nodeType);
	return source != null && source.kind == TypeKind.Array ? at : -1;
}

function hasSpreadArg(args: Node[]): boolean {
	for (const a of args) { if (a.kind == NodeKind.SpreadExpr) return true; }
	return false;
}

function spreadElementType(spread: Node): Type {
	return getElementType(bareSpreadSource((spread.data as SpreadExprData).spreadArg.nodeType)!);
}

function spreadFitsCandidate(candType: Type, at: int32, element: Type, minArgs: number): boolean {
	const formals = candType.typeChildren;
	if (at < minArgs || at >= fixedCount(formals) || fixedCount(formals) != formals.length) return false;
	for (let k = at; k < formals.length; k += 1) {
		if (typeRelation(formals[k], element) == TypeRelation.None) return false;
	}
	return true;
}

interface SpreadTake { spread: Node | null; at: int32; taken: boolean; }

function takeOptionalSpread(ctx: CheckerContext, args: Node[], argTypes: Type[], pd: ParamDefaults, formals: Type[], minArgs: number): SpreadTake {
	const at = optionalSpreadAt(args, formals, minArgs);
	if (at < 0) return { spread: null, at, taken: false };
	const spread = args[at];
	if (defaultReadsSpreadSlot(ctx, spread, pd, at, formals)) return { spread, at, taken: false };
	args.shrink(at);
	if (argTypes.length > at) argTypes.shrink(at);
	return { spread, at, taken: true };
}

function fillTakenSpread(ctx: CheckerContext, args: Node[], argTypes: Type[], take: SpreadTake, formals: Type[]): void {
	if (take.taken) fillFromSpread(ctx, args, argTypes, take.at, take.spread!, formals);
}

function fillFromSpread(ctx: CheckerContext, args: Node[], argTypes: Type[], at: int32, spread: Node, formals: Type[]): void {
	const fixed = fixedCount(formals);
	if (args.length < fixed) return;
	const source = (spread.data as SpreadExprData).spreadArg;
	const loc = spread.location;
	const read = readSpreadSource(ctx, source);
	for (let k = at; k < fixed; k += 1) {
		const i = k - at;
		const array = k == at ? read.first : cloneNodeKeepSem(read.again);
		const length = createNodeAt(NodeKind.MemberExpr, { object: array, property: "length", isOptional: false }, loc);
		const test = createNodeAt(NodeKind.BinaryExpr, { operator: ">", left: length, right: indexLiteral(i, loc) }, loc);
		const slot = createNodeAt(NodeKind.ConditionalExpr, {
			ternaryCondition: test,
			ternaryConsequent: elementRead(cloneNodeKeepSem(read.again), i, loc),
			ternaryAlternate: args[k],
		}, loc);
		callCheckExpr(ctx, slot, formals[k]);
		args[k] = slot;
		if (k < argTypes.length) argTypes[k] = slot.nodeType!; else argTypes.push(slot.nodeType!);
	}
	if (fixed == formals.length) return;
	if (args.length > fixed) args.shrink(fixed);
	if (argTypes.length > fixed) argTypes.shrink(fixed);
	const remainder = fixed == at ? read.first : cloneNodeKeepSem(read.again);
	const callee = createNodeAt(NodeKind.MemberExpr, { object: remainder, property: "slice", isOptional: false }, loc);
	const slice = createNodeAt(NodeKind.CallExpr,
		{ callee, arguments: [indexLiteral(fixed - at, loc)], isDirectCall: true, resolvedOverloadIdx: -1 }, loc);
	const rest = createNodeAt(NodeKind.SpreadExpr, { spreadArg: slice }, loc);
	callCheckExpr(ctx, rest, null);
	args.push(rest);
	argTypes.push(rest.nodeType!);
}

export function iterateSpreadSource(ctx: CheckerContext, spread: Node): void {
	if (spread.kind != NodeKind.SpreadExpr) return;
	const sd = spread.data as SpreadExprData;
	const t = sd.spreadArg.nodeType;
	if (t == null || isUnresolvedType(t) || t.kind == TypeKind.Error || isIndexedSpreadSource(t)) return;
	let source: Node | null = sd.spreadArg;
	if (!isIterator(bareSpreadSource(t))) {
		const protocol = offersProtocol(ctx, t, "toPairs") ? "toPairs" : "toItems";
		source = offersProtocol(ctx, t, protocol) ? protocolCall(ctx, sd.spreadArg, protocol) : null;
	}
	if (source != null && isIterator(bareSpreadSource(source.nodeType)) && offersProtocol(ctx, source.nodeType!, "toItems")) {
		source = protocolCall(ctx, source, "toItems");
	}
	if (source != null) sd.spreadArg = source;
}

function bareSpreadSource(t: Type | null): Type | null {
	return t != null ? unwrapRef(peelTransparentInstance(unwrapRef(t))) : null;
}

function isIndexedSpreadSource(t: Type): boolean {
	const k = bareSpreadSource(t)!.kind;
	return k == TypeKind.Array || k == TypeKind.SizedArray || k == TypeKind.Span || k == TypeKind.String || k == TypeKind.Tuple;
}

function protocolCall(ctx: CheckerContext, object: Node, name: string): Node | null {
	const loc = object.location;
	const callee = createNodeAt(NodeKind.MemberExpr, { object, property: name, isOptional: false }, loc);
	const call = createNodeAt(NodeKind.CallExpr, { callee, arguments: [], isDirectCall: true, resolvedOverloadIdx: -1 }, loc);
	callCheckExpr(ctx, call, null);
	return call.nodeType != null && !isUnresolvedType(call.nodeType) && call.nodeType.kind != TypeKind.Error ? call : null;
}

function spreadIntoOptionalRefusal(spread: Node): string {
	const source = (spread.data as SpreadExprData).spreadArg;
	const named = source.kind == NodeKind.Identifier ? `'${(source.data as IdentifierData).name}'` : "the spread value";
	const bare = bareSpreadSource(source.nodeType);
	if (bare != null && bare.kind != TypeKind.Array) {
		return `a spread argument fills optional parameters only from an array: ${named} is ${typeDisplayName(source.nodeType!)}; pass the arguments one by one`;
	}
	return `an array spread fills optional parameters only as the last argument and the only spread: the length of ${named} is not known, so no later argument has a known parameter; pass the arguments one by one`;
}

function refuseMisplacedSpread(ctx: CheckerContext, args: Node[], formals: Type[], minArgs: number): boolean {
	const restAt = formals.length > 0 && formals[formals.length - 1].kind == TypeKind.Varargs ? formals.length - 1 : -1;
	for (let i = 0; i < args.length; i += 1) {
		const a = args[i];
		if (a.kind != NodeKind.SpreadExpr || (restAt >= 0 && i >= restAt)) continue;
		const source = (a.data as SpreadExprData).spreadArg.nodeType;
		const tuple = source != null && peelTransparentInstance(unwrapRef(source)).kind == TypeKind.Tuple;
		const fixedOnly = i < minArgs || (restAt < 0 && i >= formals.length);
		addError(ctx, !tuple && fixedOnly ? "A spread argument must either have a tuple type or be passed to a rest parameter"
			: !tuple ? spreadIntoOptionalRefusal(a)
			: "a spread argument can fill only the rest parameter: pass the arguments before the rest parameter one by one",
			a.location.line, a.location.column);
		return true;
	}
	return false;
}

function checkNewArity(ctx: CheckerContext, node: Node, classSym: Symbol, innerType: Type | null, routine: Symbol | null, defaultsFrom: Symbol | null): void {
	const args = (node.data as NewExprData).newArguments;
	if (hasFlag(classSym, SymbolFlag.ImportC)) return;
	let required: int32 = 0;
	let allowed: int32 = args.length;
	if (hasFlag(classSym, SymbolFlag.HasConstructor)) {
		const formals = ctorFormalTypes(routine);
		if (formals == null) return;
		required = requiredCtorArgs(formals, defaultsFrom != null ? defaultsFrom.defaultParams : null);
		if (refuseMisplacedSpread(ctx, args, formals, required)) return;
		if (formals.length == 0 || formals[formals.length - 1].kind != TypeKind.Varargs) allowed = formals.length;
	} else {
		if (refuseMisplacedSpread(ctx, args, [], 0)) return;
		if (classSym.symbolKind != SymbolKind.Class && classSym.symbolKind != SymbolKind.Struct) return;
		const fields = positionalFieldsOf(innerType);
		if (fields == null) return;
		allowed = fields.typeNames.length;
	}
	if (args.length < required) {
		addError(ctx, `Too few arguments to 'new ${classSym.name}': expected at least ${required}, got ${args.length}`, node.location.line, node.location.column);
	} else if (args.length > allowed) {
		addError(ctx, `Too many arguments to 'new ${classSym.name}': expected at most ${allowed}, got ${args.length}`, node.location.line, node.location.column);
	}
}

function fieldsWithoutDefault(ctx: CheckerContext, classSym: Symbol, depth: int32): string[] {
	const missing: string[] = [];
	const decl = classSym.declNode;
	if (decl == null || decl.kind != NodeKind.ClassDecl || depth > 16) return missing;
	const cd = decl.data as ClassDeclData;
	if (cd.classExtends != "") {
		const parent = parentClassSymOf(classSym);
		if (parent != null && !hasFlag(parent, SymbolFlag.HasConstructor)) {
			for (const name of fieldsWithoutDefault(ctx, parent, depth + 1)) missing.push(name);
		}
	}
	for (const raw of cd.classBody) {
		let member = raw;
		if (member.kind == NodeKind.DecoratedDecl) {
			const dd = member.data as DecoratedDeclData;
			if (dd.decoratedNode != null) member = dd.decoratedNode;
		}
		if (member.kind != NodeKind.PropertyDecl) continue;
		const pd = member.data as PropertyDeclData;
		if (pd.propIsStatic || pd.propInitializer != null || !requiresInit(ctx, member.nodeType)) continue;
		missing.push(pd.propName);
	}
	return missing;
}

export function checkTryExpr(ctx: CheckerContext, node: Node): Type | null {
	const d = node.data as TryExprData;
	const oldInTry = ctx.inTryExpr;
	ctx.inTryExpr = true;
	callCheckExpr(ctx, d.tryArg, null);
	const argType = d.tryArg.nodeType;
	ctx.inTryExpr = oldInTry;
	if (refuseNonResultOperand(ctx, d, argType)) return errorType();
	// tryArg.nodeType = Result<T,E> (set by checkExpr on the CallExpr)
	// resultDesugar reads tryArg.nodeType for the full Result type.
	// TryExpr itself evaluates to T (the unwrapped value).
	if (d.hasCatch) {
		callCheckExpr(ctx, d.catchVal, null);
	} else {
		checkPropagatedError(ctx, node, argType);
	}
	if (argType != null && isResult(argType) && getResultOkType(argType) != null) {
		const okT = getResultOkType(argType);
		if (d.hasCatch && d.catchVal != null && okT != null && okT.kind != TypeKind.Void && d.catchVal.nodeType != null) {
			if (isNumeric(okT)) adoptLiteralTo(ctx, d.catchVal, okT);
			const joined = joinBranchTypes([okT, d.catchVal.nodeType]);
			if (!isUnresolvedType(joined)) {
				d.catchVal = fitJoinedBranch(ctx, d.catchVal, joined);
				node.nodeType = joined;
				return joined;
			}
		}
		return okT;
	}
	return argType;
}

function refuseNonResultOperand(ctx: CheckerContext, d: TryExprData, argType: Type | null): boolean {
	if (argType == null || isResult(argType) || isUnresolvedType(argType) || hasGenericParams(argType)) return false;
	if (argType.kind == TypeKind.Error || argType.kind == TypeKind.Never) return false;
	if (d.hasCatch && d.tryArg.kind == NodeKind.AwaitExpr) return false;
	addError(ctx, "'try' needs a Result operand, but this is '" + typeDisplayName(argType) + "', not a Result",
		d.tryArg.location.line, d.tryArg.location.column);
	return true;
}

function checkPropagatedError(ctx: CheckerContext, node: Node, argType: Type | null): void {
	const fn = ctx.currentFunction;
	if (argType == null || !isResult(argType)) return;
	if (fn == null || fn.symbolType == null) {
		addError(ctx, "'try' without 'catch' returns its error, but module top-level code cannot return — add 'catch' or move it into a function returning a Result",
			node.location.line, node.location.column);
		return;
	}
	if (fn.symbolType.kind != TypeKind.Function || fn.symbolType.typeReturn == null || isUnresolvedType(fn.symbolType.typeReturn)) {
		ctx.inferredReturnTries.push(node);
		return;
	}
	let retType: Type | null = fn.symbolType.typeReturn;
	if (hasFlag(fn, SymbolFlag.Async)) retType = awaitedType(retType);
	checkPropagatedErrorAgainst(ctx, node, retType, fn.name);
	refuseUnwrittenOut(ctx, node.location, "this 'try' returns its error");
}

export function refuseUnwrittenOut(ctx: CheckerContext, at: SourceLocation, exit: string): void {
	const name = unwrittenOutParam(ctx.initTracker);
	if (name != "") addError(ctx, "'" + name + "' is not assigned on every path: it is an out parameter and must be written before " + exit, at.line, at.column);
}

export function checkPropagatedErrorAgainst(ctx: CheckerContext, node: Node, retType: Type | null, fnName: string): void {
	const argType = (node.data as TryExprData).tryArg.nodeType;
	if (argType == null || !isResult(argType) || retType == null || isUnresolvedType(retType) || retType.kind == TypeKind.Error) return;
	if (!isResult(retType)) {
		addError(ctx, "'try' without 'catch' returns its error, but '" + fnName + "' returns '" + typeDisplayName(retType)
			+ "', not a Result — add 'catch' or make '" + fnName + "' return a Result", node.location.line, node.location.column);
		return;
	}
	const fromErr = getResultErrType(argType);
	const toErr = getResultErrType(retType);
	if (fromErr == null || toErr == null || isUnresolvedType(fromErr) || isUnresolvedType(toErr)
		|| fromErr.kind == TypeKind.Error || toErr.kind == TypeKind.Error
		|| hasGenericParams(fromErr) || hasGenericParams(toErr)) return;
	if (isAssignable(fromErr, toErr)) return;
	const reported = errorCount(ctx);
	const conv = propagatedErrorConverter(ctx, node, fromErr, toErr);
	if (conv != null) {
		node.resolvedSym = conv;
		return;
	}
	if (errorCount(ctx) > reported) return;
	addError(ctx, "'try' propagates error type '" + typeDisplayName(fromErr) + "' but '" + fnName + "' returns error type '"
		+ typeDisplayName(toErr) + "' — declare a converter from '" + typeDisplayName(fromErr) + "' to '" + typeDisplayName(toErr)
		+ "' or handle the error", node.location.line, node.location.column);
}

let _cceCount: float64 = 0;
export function checkCallExprProfile(): float64[] { return [_cceCount]; }
export function checkCallExpr(ctx: CheckerContext, node: Node, expectedType: Type | null): Type {
	_cceCount = _cceCount + 1;
	const tracker = ctx.initTracker;
	const identsFrom = tracker.argIdents.length;
	const readsFrom = tracker.pendingReads.length;
	if (node.kind == NodeKind.CallExpr) {
		const cd = node.data as CallExprData;
		cd.arguments = expandTupleSpreads(ctx, inlineLiteralSpreads(cd.arguments));
		for (const arg of cd.arguments) if (arg.kind == NodeKind.Identifier) tracker.argIdents.push(arg);
	}
	let r = checkCallExprInner(ctx, node, adoptPromiseInputs(ctx, node, expectedType));
	if (node.kind == NodeKind.CallExpr) for (const arg of (node.data as CallExprData).arguments) iterateSpreadSource(ctx, arg);
	refusePromiseOfThenable(ctx, node, r);
	tracker.argIdents.shrink(identsFrom);
	settleUnassignedArgs(ctx, readsFrom);
	const seen = node.kind == NodeKind.CallExpr && isUnresolvedType(r) ? callSelfReadType((node.data as CallExprData).callee) : null;
	if (seen != null) {
		node.nodeType = seen;
		r = seen;
	}
	refuseHiddenMethodCall(ctx, node);
	refuseHookCall(ctx, node);
	refuseSuspendingLockCallback(ctx, node);
	return evalCompileTimeCall(ctx, node, foldTypeTrait(ctx, node, r));
}

function settleUnassignedArgs(ctx: CheckerContext, from: int32): void {
	const reads = ctx.initTracker.pendingReads;
	for (let i = from; i < reads.length; i += 1) {
		const read = reads[i];
		const id = read.data as IdentifierData;
		if (read.resolvedSym != null) refuseUnassignedRead(ctx, read, id.name, read.resolvedSym.symbolType);
	}
	reads.shrink(from);
}

function takesOut(ctx: CheckerContext, arg: Node): void {
	const reads = ctx.initTracker.pendingReads;
	const at = reads.indexOf(arg);
	if (at >= 0) reads.splice(at, 1);
	if (arg.kind == NodeKind.Identifier) markInitialized(ctx.initTracker, (arg.data as IdentifierData).name);
}

export function typeTraitOf(node: Node): Symbol | null {
	if (node.kind != NodeKind.CallExpr) return null;
	const d = node.data as CallExprData;
	const sym = node.resolvedSym != null ? node.resolvedSym : (d.callee != null ? d.callee.resolvedSym : null);
	if (sym == null) return null;
	return sym.builtinKind == "IsPlainData" || sym.builtinKind == "NeedsCopy" || sym.builtinKind == "IsArray"
		|| sym.builtinKind == "IsObject" || sym.builtinKind == "IsPlainObject" ? sym : null;
}

function foldTypeTrait(ctx: CheckerContext, node: Node, callType: Type): Type {
	const trait = typeTraitOf(node);
	if (trait == null) return callType;
	const typeArg = findCallTypeArg(node);
	if (typeArg == "" || (node.data as CallExprData).arguments.length > 0) {
		addError(ctx, `'${trait.name}' asks a type and takes no value: write ${trait.name}<T>()`, node.location.line, node.location.column);
		node.nodeType = errorType();
		return node.nodeType;
	}
	const asked = resolveAnnotation(typeArg, ctx, node.location.line, node.location.column);
	if (asked.kind == TypeKind.GenericParam || hasGenericParams(asked)) {
		node.nodeType = booleanType();
		return node.nodeType;
	}
	const answer = trait.builtinKind == "IsPlainData" ? isPlainDataType(asked, (owner: Type): boolean => declaresUserHook(owner, ctx))
		: trait.builtinKind == "IsArray" ? isArrayType(asked)
		: trait.builtinKind == "IsObject" ? isAssignable(asked, nonPrimitiveType())
		: trait.builtinKind == "IsPlainObject" ? isPlainObjectType(asked)
		: needsValueCopy(asked);
	node.kind = NodeKind.BooleanLiteral;
	node.data = { boolValue: answer } as BooleanLiteralData;
	node.resolvedSym = null;
	node.nodeType = booleanType();
	return node.nodeType;
}

function compileTimeCallee(node: Node): Symbol | null {
	const d = node.data as CallExprData;
	if (d.callee == null) return null;
	const set = node.resolvedSym != null ? node.resolvedSym : d.callee.resolvedSym;
	if (set == null) return null;
	const idx = d.resolvedOverloadIdx;
	const winner = idx > 0 && idx - 1 < set.overloads.length ? set.overloads[idx - 1] : set;
	return hasFlag(winner, SymbolFlag.CompileTime) ? winner : null;
}

function evalCompileTimeCall(ctx: CheckerContext, node: Node, callType: Type): Type {
	if (node.kind != NodeKind.CallExpr || isEngineCheckMode() || ctx.compileTimeBodyDepth > 0) return callType;
	const callee = compileTimeCallee(node);
	if (callee == null) return callType;
	const d = node.data as CallExprData;
	for (let i = 0; i < d.arguments.length; i += 1) {
		const arg = d.arguments[i];
		if (isCompileTimeValue(arg, 0)) continue;
		addError(ctx, `'${callee.name}' is @comptime, so it runs while compiling: argument ${(i + 1).toString()} must be a literal or a module-level const built from literals`, arg.location.line, arg.location.column);
		node.nodeType = errorType();
		return node.nodeType;
	}
	if (!foldAtCompileTime(ctx, node, callType, callType)) {
		node.nodeType = errorType();
		return node.nodeType;
	}
	return node.nodeType!;
}

export function foldUserOperatorConstant(ctx: CheckerContext, expr: Node, expected: Type | null): void {
	if (isEngineCheckMode() || ctx.compileTimeBodyDepth > 0 || !isUserOperatorConstant(expr, 0)) return;
	const mark = ctx.errors.length;
	if (!foldAtCompileTime(ctx, expr, expected, expr.nodeType)) ctx.errors = ctx.errors.slice(0, mark);
}

// The folded value keeps `staticType`, the type of the expression it replaces:
// an enum result folds to its ordinal typed as the enum.
function foldAtCompileTime(ctx: CheckerContext, node: Node, expected: Type | null, staticType: Type | null): boolean {
	const loc = node.location;
	const body = createNodeAt(NodeKind.BlockStmt, { statements: [createNodeAt(NodeKind.ReturnStmt, { argument: cloneNodeForCheck(node) }, loc)] }, loc);
	const errorsBefore = errorCount(ctx);
	const value = callEvalComptimeBlock(createNodeAt(NodeKind.ComptimeBlock, { comptimeBody: body }, loc), ctx);
	if (errorCount(ctx) > errorsBefore) return false;
	node.kind = value.kind;
	node.data = value.data;
	node.nodeType = null as unknown as Type;
	node.resolvedSym = null;
	node.flags = 0 as BitSet<NodeFlag>;
	node.variantSlot = 0;
	keepComptimeNominalType(node, value.nodeType);
	callCheckExpr(ctx, node, expected);
	if (node.kind == NodeKind.NumberLiteral && staticType != null && peelTransparentInstance(staticType).kind == TypeKind.Enum) node.nodeType = staticType;
	node.flags = node.flags.incl(NodeFlag.Folded);
	return true;
}

export function isNominalLiteralType(t: Type | null): boolean {
	return t != null && (t.kind == TypeKind.Char || t.kind == TypeKind.Enum || t.kind == TypeKind.Distinct);
}

export function keepComptimeNominalType(node: Node, staticType: Type | null): void {
	const literal = node.kind == NodeKind.NumberLiteral || node.kind == NodeKind.StringLiteral || node.kind == NodeKind.BooleanLiteral;
	if (!literal || !isNominalLiteralType(staticType)) return;
	node.flags = node.flags.incl(NodeFlag.Folded);
	node.nodeType = staticType!;
}

export function keepFoldedType(node: Node, expanded: Node): void {
	if (!expanded.flags.has(NodeFlag.Folded) || expanded.nodeType == null) return;
	node.flags = node.flags.incl(NodeFlag.Folded);
	node.nodeType = expanded.nodeType;
}
function isBareName(text: string): boolean {
	return text != "" && text.indexOf("<", 0) < 0 && text.indexOf("[", 0) < 0 && text.indexOf(" ", 0) < 0 && text.indexOf(".", 0) < 0;
}

// The name a module-scope type symbol gives `bound` (a private type reached through an exported alias).
function visibleNameOf(ctx: CheckerContext, bound: Type): string {
	for (const entry of moduleScopeNamed(ctx.table)) {
		if (!isTypeSymbol(entry.sym)) continue;
		ensureShaped(entry.sym, ctx);
		if (entry.sym.symbolType != null && sameType(entry.sym.symbolType, bound)) return entry.name;
	}
	return "";
}

// A macro replacement owns its type arguments as bound typed operands: the callee
// `base<operands>` is lowered here to the ordinary explicit generic call `base<T>(...)`.
function lowerTypedCallee(ctx: CheckerContext, node: Node, d: CallExprData): boolean {
	const callee = d.callee;
	if (callee.kind != NodeKind.TypeGeneric) return true;
	const g = callee.data as TypeGenericData;
	const spelled: string[] = [];
	for (const operand of g.typExprArgs) {
		const bound = operand.nodeType;
		if (bound == null) {
			addError(ctx, "a generic callee's type operand carries no bound type (a macro must pass getTypeArg())", operand.location.line, operand.location.column);
			return false;
		}
		const written = monoConcreteTypeName(bound);
		const seen = isBareName(written) && lookupSymbol(ctx.table, written) == null ? visibleNameOf(ctx, bound) : "";
		const name = seen != "" ? seen : written;
		spelled.push(name);
	}
	d.callee = g.typExprBase;
	d.callee.location = callee.location;
	node.typeArg = spelled.join(", ");
	return true;
}

function checkCallExprInner(ctx: CheckerContext, node: Node, expectedType: Type | null): Type {
	const d = node.data as CallExprData;
	if (d.callee != null && isImportKeyword(d.callee)) return checkImportCall(ctx, node);
	if (!lowerTypedCallee(ctx, node, d)) return errorType();
	if (d.callee == null) {
		addError(ctx, "a call has a null callee (a macro returned a CallExpr without one)", node.location.line, node.location.column);
		return errorType();
	}
	const prevCallee = ctx.calleeExpr;
	ctx.calleeExpr = d.callee;
	callCheckExpr(ctx, d.callee, null);
	ctx.calleeExpr = prevCallee;
	if (callThroughProxy(ctx, node, expectedType)) return node.nodeType ?? errorType();
	if (d.callee.kind == NodeKind.Identifier
			&& (d.callee.data as IdentifierData).name == "super"
			&& d.callee.resolvedSym != null) {
		let parentSym = d.callee.resolvedSym;
		const parentInst = superInstance(d.callee.nodeType);
		let substNames: string[] = [];
		if (parentInst != null && !hasGenericParams(parentInst)) {
			const names = splitTopLevel(genericParamNamesOf(symGenericParams(parentSym)), ",").map((n: string): string => n.trim());
			const inst = instantiateClassConstructor(parentSym, names, parentInst.typeChildren, ctx);
			if (inst != null) parentSym = inst;
		} else if (parentInst != null) {
			substNames = splitTopLevel(genericParamNamesOf(symGenericParams(parentSym)), ",").map((n: string): string => n.trim());
		}
		const parentCtor = parentSym.symbolKind == SymbolKind.Function ? parentSym : ctorRoutineFor(ctx, parentSym);
		if (parentCtor == null) {
			addError(ctx, `internal: the parent class '${parentSym.name}' has no constructor routine for super()`, node.location.line, node.location.column);
			return errorType();
		}
		d.callee.resolvedSym = parentCtor;
		let ctorParamTypes = ctorFormalTypes(parentCtor);
		if (substNames.length > 0 && ctorParamTypes != null && parentInst != null) {
			const substParams = declaredTypeParams(parentSym, substNames.length);
			ctorParamTypes = ctorParamTypes.map((t: Type): Type => substituteTypeParams(t, substParams, parentInst.typeChildren));
		}
		const expectedCount = ctorParamTypes != null ? ctorParamTypes.length : 0;
		for (let ai = 0; ai < d.arguments.length; ai += 1) {
			const expected = (ctorParamTypes != null && ai < ctorParamTypes.length) ? ctorParamTypes[ai] : null;
			callCheckExpr(ctx, d.arguments[ai], expected);
		}
		if (d.arguments.length < expectedCount) {
			const owner = constructorDeclaringClass(parentSym) ?? parentSym;
			const defaultsFrom = owner == parentSym ? parentCtor : ctorRoutineOf(owner);
			if (defaultsFrom != null && defaultsFrom.defaultParams.length > 0) {
				fillDefaults(ctx, d.arguments, defaultsFrom.defaultParams, expectedCount, 0, ctorParamTypes!, defaultsFrom.modulePath, defaultsFrom.symbolType.typeNames.slice(1));
			}
		}
		if (d.arguments.length != expectedCount) {
			addError(ctx, "super() expects " + expectedCount.toString() + " arguments, got " + d.arguments.length.toString(), node.location.line, node.location.column);
		}
		node.nodeType = voidType();
		return voidType();
	}
	let calleeType = d.callee.nodeType;
	if (calleeType != null) calleeType = peelTransparentInstance(calleeType);
	const distinctFn = distinctCallTarget(calleeType);
	if (distinctFn != null) {
		const peelTok = createToken(TokenKind.Ident, "", d.callee.location.line);
		const peeled = createNode(NodeKind.HiddenStdConv, { convExpr: d.callee, convType: distinctFn }, peelTok);
		peeled.nodeType = distinctFn;
		peeled.flags = peeled.flags | NodeFlag.Sem;
		d.callee = peeled;
		calleeType = distinctFn;
		if (distinctFn.callConv == CallingConvention.CcClosure) d.isDirectCall = false;
	}
	// Detect overloaded paths early — these need argTypes for scoring
	let needsOverloadScoring = false;
	let overloadSym: Symbol | null = null;
	// Extension pre-resolution state (set in MemberExpr branch, used after arg checking)
	let extPreResolved = false;
	let extRecvBindings = createUnifyBindings();
	let extMultiFiltered: ExtensionMethod[] = [];
	let extMultiObjType: Type | null = null;
	let extMultiMethodName = "";
	let extRecvFormal: Type | null = null;
	let isActorMethodCall = false;
	// Check for overloads + set resolvedSym for direct calls
	if (d.callee.kind == NodeKind.Identifier) {
		const calleeName = (d.callee.data as IdentifierData).name;
		const sym = resolveCalleeIdent(ctx, d.callee);
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
		if (sym != null && sym.symbolKind == SymbolKind.Macro) {
			if (macroDepthExceeded(ctx, calleeName, node)) return errorType();
			// Type-check args first (errors inside them are reported)
			foldComptimeNodeAliasArgs(ctx, d.arguments);
			const macroArgsRef = d.arguments;
			checkJsxConsumed(ctx, macroArgsRef);
			rewriteCallAsMacroInvocation(node, sym);
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
			if (expanded.kind == NodeKind.MacroInvocation) {
				ctx.macroExpansionDepth = ctx.macroExpansionDepth - 1;
				node.nodeType = errorType();
				return errorType();
			}
			const friends = expansionOf(ctx, node, sym.modulePath);
			const friendScope = befriend(ctx, friends);
			let expandedValue = expanded;
			const hoists = isHoistingSplice(ctx, node, expanded);
			if (hoists) {
				expandedValue = unwrapSpliceManyAtExpr(ctx, node, expanded);
				if (expandedValue == null) {
					unfriend(friendScope, friends);
					ctx.macroExpansionDepth = ctx.macroExpansionDepth - 1;
					node.nodeType = errorType();
					return errorType();
				}
			}
			// Replace current node contents with the expanded result.
			// Identity is preserved — the parent (e.g. VariableDecl) still references this node.
			adoptExpansionResult(node, expandedValue);
			node.typeArg = expandedValue.typeArg;
			node.nodeType = null as unknown as Type;
			keepFoldedType(node, expandedValue);
			// Re-check the mutated node so its nodeType is set. This drives correct
			// type inference for the parent (e.g., the VariableDecl declaring `x`).
			// If the expanded result is itself a macro call, this recurses through
			// checkCallExpr → eager expand again, bounded by macroExpansionDepth.
			if (node.kind == NodeKind.SpliceMany) markExpansion(ctx, node, friends);
			callCheckExpr(ctx, node, expectedType);
			unfriend(friendScope, friends);
			if (hoists) bindRefsToHoistedPrefix(node, expanded);
			ctx.macroExpansionDepth = ctx.macroExpansionDepth - 1;
			return node.nodeType;
		}
		if (sym != null) {
			// Demand-driven: ensure callee signature is ready
			ensureShaped(sym, ctx);
			node.resolvedSym = sym;
			markUsedIn(ctx, sym);
			sgRecordSym(ctx, d.callee.location.line, d.callee.location.column, d.callee.location.column + calleeName.length, sym, sym.symbolType, sym.symbolKind, calleeName, "", false);
			// Template: inline AST substitution (reference parity). Expand the
			// template body at the call site — no function call emitted.
			// With overloads present, scoring runs first (concrete wins);
			// a winning template expands after commit.
			if (sym.symbolKind == SymbolKind.Function && isTemplateSym(sym) && !hasOverloads(sym)) {
				return expandTemplate(ctx, sym, node, d, expectedType);
			}
			if (hasOverloads(sym) || shadowedImportOf(ctx, sym) != null) {
				needsOverloadScoring = true;
				overloadSym = sym;
			}
		}
		// Reference parity: detect closure calls by type,
		// not symbol kind. If callee type has callConv == ccClosure, mark as indirect call.
		if (calleeType != null && calleeType.kind == TypeKind.Function
			&& calleeType.callConv == CallingConvention.CcClosure) {
			d.isDirectCall = false;
		}
	} else if (d.callee.kind == NodeKind.MemberExpr) {
		// Method call: copy resolvedSym from callee (set by class method lookup in checkMemberExpr)
		if (d.callee.resolvedSym != null) {
			node.resolvedSym = d.callee.resolvedSym;
		}
		// Extension resolution for method calls.
		const methodSym = node.resolvedSym;
		const methodOrigin = methodSym != null && methodSym.instantiatedFrom != null ? methodSym.instantiatedFrom : methodSym;
		const methodEntry = methodOrigin != null && soleMethodCandidate(ctx, methodOrigin, d.callee.data as MemberExprData) ? dispatchEntryFor(methodOrigin) : null;
		if (methodEntry != null && methodSym != null && methodSym.symbolType != null) {
			node.flags = node.flags.incl(NodeFlag.ExtCall);
			extPreResolved = true;
			extRecvFormal = methodSym.symbolType.typeChildren.length > 0 ? methodSym.symbolType.typeChildren[0] : null;
			isActorMethodCall = methodEntry.classSym.symbolKind == SymbolKind.Actor;
			if (isActorMethodCall && calleeType != null && calleeType.typeReturn != null && calleeType.typeReturn.kind != TypeKind.Void) {
				calleeType = createFunction(calleeType.typeChildren, calleeType.typeNames, createPromise(calleeType.typeReturn));
			}
		} else if (ctx.extensionRegistry != null) {
			const me = d.callee.data as MemberExprData;
			const objType = me.object.nodeType != null ? peelTransparentInstance(me.object.nodeType) : null;
			const isNamespaceQualified = (me.object.resolvedSym != null && me.object.resolvedSym.symbolKind == SymbolKind.Module)
				|| (objType != null && objType.kind == TypeKind.Module);
			const callsOwnFunctionField = objType != null && getProperty(objType, me.property).kind == TypeKind.Function;
			if (objType != null && !isNamespaceQualified && !callsOwnFunctionField) {
				const allByName = boundExtensions(d.callee, findAllExtensionsByName(ctx.extensionRegistry, me.property));
				// Type-level access (e.g., Buffer.method()) — only static extensions apply.
				const isStaticAccess = isTypeLevelAccess(ctx, me.object, me.property);
				let filtered = filterExtsByReceiverType(allByName, objType);
				if (isStaticAccess && me.object.resolvedSym != null) {
					for (const owned of staticExtsOwnedBy(ctx, allByName, me.object.resolvedSym, objType)) {
						if (filtered.indexOf(owned) < 0) filtered.push(owned);
					}
				}
				if (isStaticAccess) {
					const staticOnly: ExtensionMethod[] = [];
					for (const ext of filtered) {
						if (ext.isStatic) staticOnly.push(ext);
					}
					filtered = staticOnly;
				}
				if (filtered.length == 1) {
					const winner = filtered[0];
					if (winner.sym != null) {
						ensureShaped(winner.sym, ctx);
						markUsedIn(ctx, winner.sym);
						if (node.resolvedSym == null || node.resolvedSym.instantiatedFrom != winner.sym) {
							const target = signatureTarget(ctx, winner.sym, node, allByName);
							node.resolvedSym = target;
							d.callee.resolvedSym = target;
						}
						sgRecordSym(ctx, d.callee.location.line, d.callee.location.column + 1, d.callee.location.column + 1 + me.property.length, winner.sym, getExtFnType(winner), SymbolKind.Method, me.property, extReceiverDisplay(winner), false);
						if (!hasFlag(winner.sym, SymbolFlag.NativeMethod)) {
							node.flags = node.flags.incl(NodeFlag.ExtCall);
						}
						if (winner.isStatic) node.flags = node.flags.incl(NodeFlag.ExtStatic);
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
							unifyArrayReceiver(extType.typeChildren[0], objType, eb);
							if (winner.sym != null && winner.sym.declNode != null && winner.sym.declNode.kind == NodeKind.FunctionDecl) {
								for (let ri = 0; ri < eb.names.length; ri += 1) reportUnmetConstraint(ctx, ri, eb, me.property, node.location);
							}
							if (eb.names.length > 0) extType = substituteBound(extType, eb);
							extRecvBindings = eb;
						}
						calleeType = stripReceiverParam(extType);
						extRecvFormal = extType.typeChildren[0];
					} else {
						calleeType = extType;
					}
					extPreResolved = true;
					// Actor: flag for Sendable checking + Promise<T> wrapping for non-void returns
					// Check both direct Actor symbols (e.g. Worker.staticMethod) and
					// variables holding actor instances (e.g. w.method where w: Ref<Worker>)
					const receiverSym = extReceiverSym(winner);
					const isActorReceiver = !isStaticAccess && (
						(me.object.resolvedSym != null && me.object.resolvedSym.symbolKind == SymbolKind.Actor)
						|| (objType != null && objType.kind == TypeKind.Ref && objType.sym != null && objType.sym.symbolKind == SymbolKind.Actor)
						|| (objType != null && objType.sym != null && objType.sym.symbolKind == SymbolKind.Actor)
						|| (receiverSym != null && receiverSym.symbolKind == SymbolKind.Actor)
					);
					if (isActorReceiver) {
						isActorMethodCall = true;
						if (calleeType != null
							&& calleeType.typeReturn != null
							&& calleeType.typeReturn.kind != TypeKind.Void) {
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
		const qualifier = (d.callee.data as MemberExprData).object.resolvedSym;
		if (qualifier != null && qualifier.symbolKind == SymbolKind.Module && methodSym != null && hasOverloads(methodSym)) {
			needsOverloadScoring = true;
			overloadSym = methodSym;
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
	// Bindings drive each arg's expectedType via on-demand substituteBound.
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
		&& calleeType != null
		&& calleeType.kind == TypeKind.Function
		&& hasGenericParams(calleeType);
	const _argBindings = _isGenericCall
		? deriveCallBindings(ctx, node, node.resolvedSym, calleeType, null)
		: createUnifyBindings();
	const _contextBindings = _isGenericCall
		? bindFromExpectedReturn(calleeType, expectedType)
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
	for (let ai = 0; ai < d.arguments.length; ai += 1) { argTypes.push(null as unknown as Type); }
		const spawnCalleeSym = node.resolvedSym != null ? node.resolvedSym : d.callee.resolvedSym;
		let spawnMoveKeys: string[] = [];
		if (spawnCalleeSym != null && spawnCalleeSym.builtinKind == "PromiseSpawn") {
			spawnMoveKeys = desugarSpawnMoveList(ctx, d);
			if (d.arguments.length >= 2 && !awaitedWhereWritten(ctx, node)) {
				addError(ctx, "a spawn with { timeout } must be awaited where it is written, because its deadline is taken at that await; bind the result of 'await spawn(..., { timeout })' instead of the handle", node.location.line, node.location.column);
			}
		}
	const argOrder = genericArgOrder(ctx, d.arguments, _isGenericCall);
	const literalArgs: boolean[] = [];
	for (const arg of d.arguments) literalArgs.push(isLiteralTree(arg));
	for (let oi = 0; oi < argOrder.length; oi += 1) {
		const ai = argOrder[oi];
		let paramExpected: Type | null = null;
		const _formal: Type | null = (calleeType != null
			&& calleeType.kind == TypeKind.Function
			&& calleeType.typeChildren != null)
			? formalAtPosition(calleeType, ai)
			: null as unknown as Type;
		if (_formal != null) {
			if (_isGenericCall && _argBindings.names.length > 0) {
				paramExpected = substituteBound(_formal, _argBindings);
			} else {
				paramExpected = _formal;
			}
			if (_contextBindings.names.length > 0 && hasGenericParams(paramExpected)
				&& takesContext(ctx, d.arguments[ai])) {
				paramExpected = substituteBound(paramExpected, _contextBindings);
			}
			if (_isGenericCall && hasGenericParams(paramExpected)
				&& literalParamsAwaitFormal(d.arguments[ai])
				&& node.resolvedSym != null
				&& node.resolvedSym.declNode != null
				&& node.resolvedSym.declNode.kind == NodeKind.FunctionDecl) {
				mergeUnifyBindings(_argBindings, bindFromLiteralAnnotations(ctx, d.arguments[ai], _formal));
				paramExpected = substituteBound(_formal, _argBindings);
				if (_contextBindings.names.length > 0) paramExpected = substituteBound(paramExpected, _contextBindings);
				refuseUnboundLiteralParam(ctx, d.arguments[ai], paramExpected);
				const declParams = extractGenericNames(getGenericDeclFlags(node.resolvedSym.declNode));
				const declared = declaredTypeParams(node.resolvedSym, declParams.length);
				const unbound = createUnifyBindings();
				for (let di = 0; di < declParams.length; di += 1) {
					const gp = di < declared.length ? declared[di] : null;
					if (gp != null && boundSlot(_argBindings, gp) < 0) bindParam(unbound, gp, inferredType());
				}
				paramExpected = applySubstitutions(paramExpected, unbound);
			}
			// Non-empty array/object literal under a still-generic formal:
			// drop the expected type so the literal infers bottom-up and the
			// forward unify below can bind T (a pushed GenericParam contaminates
			// the literal's type instead). Empty literals keep it — nothing to
			// infer from, the unbound-T gate must stay loud.
			if (_isGenericCall && hasGenericParams(paramExpected)) {
				const nonEmptyArrayLit = d.arguments[ai].kind == NodeKind.ArrayLiteral
					&& (d.arguments[ai].data as ArrayLiteralData).elements.length > 0;
				const nonEmptyObjectLit = d.arguments[ai].kind == NodeKind.ObjectLiteral
					&& (d.arguments[ai].data as ObjectLiteralData).properties.length > 0;
				if (nonEmptyArrayLit || nonEmptyObjectLit) {
					paramExpected = null;
				}
			}
		}
		if (extMultiFiltered.length > 1 && isContextSensitive(d.arguments[ai])) continue;
		const calleeSym = node.resolvedSym != null ? node.resolvedSym : d.callee.resolvedSym;
		if (ai == 0 && calleeSym != null && calleeSym.builtinKind == "PromiseSpawn") ctx.pendingSpawnThunk = true;
		if (extMultiFiltered.length > 1 && literalArgs[ai]) paramExpected = null;
		if (paramExpected != null && paramExpected.kind == TypeKind.Varargs) {
			const restElem = getElementType(unwrapRef(unwrapVarargs(paramExpected)));
			paramExpected = restElem != null && restElem.kind != TypeKind.Inferred && !isUnknownType(restElem) ? restElem : null;
		}
		callCheckExpr(ctx, d.arguments[ai], paramExpected);
		ctx.pendingSpawnThunk = false;
		let argType = d.arguments[ai].nodeType;
		const bindsTypeParam = _isGenericCall && _formal != null && hasGenericParams(_formal);
		if (bindsTypeParam && argType != null) argType = storedTypeOfNullRead(d.arguments[ai], argType, argType);
		// Tier 1: narrow direct enum member access to its EnumLiteral form for call checking.
		if (!bindsTypeParam && argType != null && argType.kind == TypeKind.Enum) {
			const argNode = d.arguments[ai];
			if (argNode.resolvedSym != null
					&& argNode.resolvedSym.symbolKind == SymbolKind.EnumMember
					&& argNode.resolvedSym.symbolType != null
					&& argNode.resolvedSym.symbolType.kind == TypeKind.EnumLiteral) {
				argType = argNode.resolvedSym.symbolType;
			}
		}
		const resultSlot = contextResultSlot(calleeSym, _formal, _contextBindings);
		if (resultSlot != null && argType != null && !hasGenericParams(argType) && !isAssignable(argType, resultSlot)) {
			const converted = tryApplyConverter(ctx, d.arguments[ai], argType, resultSlot);
			if (converted != null && converted.nodeType != null) {
				d.arguments[ai] = converted;
				argType = converted.nodeType;
			}
		}
		argTypes[ai] = argType!;
		// Source 3: forward inference. Single-walk — subsequent args see
		// the updated bindings, prior args are never re-checked.
		if (_isGenericCall && _formal != null && argType != null
			&& hasGenericParams(_formal) && !hasGenericParams(argType)) {
			const fwd = createUnifyBindings();
			unifyType(_formal, argType, fwd);
			mergeUnifyBindings(_argBindings, fwd);
		}
		// PARALOCK Phase 1: passing an affine-Promise identifier as a function argument
		// counts as consumption. For overloaded calls this happens inside the
		// overload resolver's commit step instead (see resolveOverloadCall).
		if (argType != null && isAffineAwaitable(argType) && d.arguments[ai].kind == NodeKind.Identifier) {
			const argSym = d.arguments[ai].resolvedSym;
			if (argSym != null) {
				markConsumedName(ctx.affineTracker, symbolConsumeKey(argSym));
				markConsumed(argSym);
			}
		}
	}
	const textSym = node.resolvedSym != null ? node.resolvedSym : d.callee.resolvedSym;
	if (textSym != null && !isEngineCheckMode()
		&& (ctx.currentFunction == null || !hasFlag(ctx.currentFunction, SymbolFlag.CompileTime))
		&& (textSym.builtinKind == "MetaError" || textSym.builtinKind == "MetaWarning"
			|| textSym.builtinKind == "MetaSplice" || textSym.builtinKind == "MetaGetTypeArg")) {
		addError(ctx, `'${textSym.name}' can only be called at compile time`, node.location.line, node.location.column);
		return errorType();
	}
	if (textSym != null && (textSym.builtinKind == "Echo" || (textSym.builtinKind == "ToString" && d.arguments.length == 1))) {
		for (let ai = 0; ai < d.arguments.length; ai += 1) {
			const text = synthStringify(ctx, d.arguments[ai], textSym.builtinKind == "Echo");
			if (text == null) continue;
			d.arguments[ai] = text;
			argTypes[ai] = text.nodeType!;
		}
	}
	// Pre-resolved single extension — return type inference (needs argTypes)
	if (extPreResolved) {
		// Fill default args (calleeType already has receiver stripped for non-static)
		// defaultOffset = 1 for non-static (fnDefaults[0] is receiver slot), 0 for static (receiver stripped in parser)
		const extDefaultOffset = node.flags.has(NodeFlag.ExtStatic) ? 0 : 1;
		const extDefaults = calleeDefaults(node, null, extDefaultOffset);
		const extSpread = takeOptionalSpread(ctx, d.arguments, argTypes, extDefaults, calleeType.typeChildren,
			firstDefaulted(extDefaults, calleeType.typeChildren));
		if (argTypes.length < calleeType.typeChildren.length) {
			const me = d.callee.data as MemberExprData;
			fillDefaultArgsForNode(ctx, node, me.property, calleeType.typeChildren.length, extDefaultOffset);
		}
		// Arity gates — Varargs-aware (reference parity: tyVarargs allows 0+ trailing args).
		const extLastCT = calleeType.typeChildren.length > 0
			? calleeType.typeChildren[calleeType.typeChildren.length - 1] : null;
		const extHasRest = extLastCT != null && extLastCT.kind == TypeKind.Varargs;
		const extMinArDeclared = callMinArity(calleeType);
		const extMinAr = extHasRest && extMinArDeclared >= calleeType.typeChildren.length
			? calleeType.typeChildren.length - 1 : extMinArDeclared;
		const extRestTuple = restTupleOf(calleeType!);
		if (extSpread.taken) {
			fillTakenSpread(ctx, d.arguments, argTypes, extSpread, calleeType.typeChildren);
		} else if (extSpread.spread != null) {
		} else if (refuseMisplacedSpread(ctx, d.arguments, calleeType.typeChildren, extMinAr)) {
		} else if (extRestTuple != null) {
			fitRestTupleArgs(ctx, node, calleeType!, extRestTuple, extMinArDeclared, d.arguments.length);
		} else if (d.arguments.length < extMinAr) {
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
			if (cpt != null && cpt.kind == TypeKind.CString && ci < argTypes.length && argTypes[ci] != null
					&& (argTypes[ci].kind == TypeKind.String || argTypes[ci].kind == TypeKind.StringLiteral)) {
				refuseDanglingCString(ctx, d.arguments[ci], true);
				d.arguments[ci] = synthCStringConv(d.arguments[ci], cpt);
				argTypes[ci] = cpt;
			} else if (cpt != null && ci < argTypes.length && argTypes[ci] != null && !hasGenericParams(cpt)
					&& (!isAssignable(argTypes[ci], cpt) || isNominalMismatch(argTypes[ci], cpt))
					&& valueOfInPlace(ctx, d.arguments[ci]) && d.arguments[ci].nodeType != null) {
				d.arguments[ci] = fitNode(ctx, d.arguments[ci], cpt, d.arguments[ci].nodeType);
				argTypes[ci] = d.arguments[ci].nodeType!;
			}
		}
		relateMethodCallArgs(ctx, node, calleeType!, extRecvFormal, argTypes, false);
		// Static class methods need mono-instantiation
		// for both explicit `<T>` AND arg-driven inference (e.g.
		// `JSON.stringify(person)` without `<T>` should infer T=Person from
		// the arg). The shared `tryInstantiateGenericCallee` helper handles
		// both binding sources. Runs BEFORE the explicit-arg branch so the
		// typed mono path is uniform regardless of `<T>` presence.
		if (isGenericRoutine(calleeType, node.resolvedSym)
				&& node.resolvedSym != null && node.resolvedSym.declNode != null
				&& node.resolvedSym.declNode.kind == NodeKind.MethodDecl
				&& (node.resolvedSym.declNode.data as MethodDeclData).methodIsStatic) {
			const methodFlags = getGenericDeclFlags(node.resolvedSym.declNode);
			const newCalleeType = tryInstantiateGenericCallee(ctx, node, calleeType!, argTypes, methodFlags, expectedType);
			if (newCalleeType != null) {
				calleeType = newCalleeType;
				return inferGenericReturn(ctx, calleeType, argTypes, expectedType, node);
			}
		}
		if (isGenericRoutine(calleeType, node.resolvedSym) && node.flags.has(NodeFlag.ExtStatic) && node.resolvedSym != null
				&& node.resolvedSym.declNode != null && node.resolvedSym.declNode.kind == NodeKind.FunctionDecl) {
			const staticInst = tryInstantiateGenericCallee(ctx, node, calleeType!, argTypes, getGenericDeclFlags(node.resolvedSym.declNode), expectedType);
			if (staticInst != null) {
				calleeType = staticInst;
				d.callee.nodeType = calleeType;
				return inferGenericReturn(ctx, calleeType, argTypes, expectedType, node);
			}
		}
		if (isGenericRoutine(calleeType, node.resolvedSym) && !node.flags.has(NodeFlag.ExtStatic) && node.resolvedSym != null
				&& node.resolvedSym.declNode != null && (declTakesReceiver(node.resolvedSym.declNode) || isGenericInstanceMethod(node.resolvedSym))) {
			const recvBindings = extRecvBindings.names.length > 0 ? extRecvBindings : classReceiverBindings(node.resolvedSym, d.callee);
			const extInst = tryInstantiateGenericCallee(ctx, node, calleeType!, argTypes, getGenericDeclFlags(node.resolvedSym.declNode), expectedType, recvBindings);
			if (extInst != null) {
				calleeType = stripReceiverParam(extInst);
				d.callee.nodeType = calleeType;
				return inferGenericReturn(ctx, calleeType, argTypes, expectedType, node);
			}
		}
		// Explicit type arg resolution for generic methods (e.g. JSON.parse<Person>)
		if (hasGenericParams(calleeType)) {
			const explicitArg = findCallTypeArg(node);
			if (explicitArg != "") {
				// Static class method mono is handled at the top of the
				// extPreResolved block (uniform for both explicit `<T>` and
				// arg-driven inference). If we reach here, mono didn't fire —
				// fall through to standard explicit-arg return type computation.
				return inferGenericReturnWithExplicit(calleeType!, argTypes, expectedType, explicitArg, ctx, node);
			}
		}
		// Sendable check for extension-resolved actor method calls
		if (isActorMethodCall) {
			// SEND-class (void return — no reply to park on) rejects plain refs;
			// CALL-class borrows them (sound only while awaited — see below).
			const sendClass = calleeType == null || calleeType.typeReturn == null
				|| calleeType.typeReturn.kind == TypeKind.Void;
			let borrowed = false;
			for (let pi = 0; pi < d.arguments.length; pi += 1) {
				if (checkActorArgSendable(ctx, node, d.arguments[pi], pi, sendClass)) borrowed = true;
			}
			if (borrowed && node == ctx.stmtPosExpr) {
				addError(ctx, "discarded actor call borrows a plain reference — the reply is what keeps it alive\nawait the call, or pass `move` / `Arc<T>` (PARALOCK I21)",
					node.location.line, node.location.column);
			}
		}
		return inferGenericReturn(ctx, calleeType!, argTypes, expectedType, node);
	}
	// Multi-overload extension — needs argTypes for scoring
	if (extMultiFiltered.length > 1) {
		return resolveExtensionOverloadCall(ctx, extMultiFiltered, argTypes, literalArgs, extMultiObjType, extMultiMethodName, node, expectedType);
	}
	// @builtin("PromiseSpawn"): infer affine `Promise<T>` from closure's return type.
	// PARALOCK: spawn produces `Promise<T>` tagged with AwaitableAffine +
	// AwaitableScopeBound flags. Same surface type as a plain Promise, with
	// structurally identical (typeChildren[0] = inner type), so downstream transforms
	// that call isAwaitable() still recognize it, and compat.ms upcasts it to Promise<T>
	// for assignability so existing code (Promise.all, explicit Promise<T> annotations) works.
	for (const mk of spawnMoveKeys) markConsumedName(ctx.affineTracker, "mv:" + mk);
	if (node.resolvedSym != null && node.resolvedSym.builtinKind == "PromiseSpawn"
		&& argTypes.length >= 1 && argTypes[0] != null && argTypes[0].kind == TypeKind.Function) {
		const spawnInner = argTypes[0].typeReturn != null ? argTypes[0].typeReturn : voidType();
		if (isAwaitable(spawnInner)) {
			const named = d.arguments.length >= 1 && d.arguments[0].kind == NodeKind.Identifier;
			const fn = named ? (d.arguments[0].data as IdentifierData).name : "";
			const rewrite = named
				? `write 'await ${fn}()', or 'await spawn(() => ${fn}Sync())' with a '${fn}Sync' that does not return a promise`
				: "await the promise the function returns instead of spawning it, or spawn a function that does not return a promise";
			addError(ctx, `spawn of a function that returns '${typeDisplayName(spawnInner)}' makes a promise of a promise, which is refused: ${rewrite}`, node.location.line, node.location.column);
			node.nodeType = errorType();
			return node.nodeType;
		}
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
	if (calleeType != null && isMaybeType(calleeType)
		&& calleeType.typeReturn != null && calleeType.typeReturn.kind == TypeKind.Function) {
		addError(ctx, "callee is possibly null (" + typeDisplayName(calleeType.typeReturn) + " | null) — unwrap with '!' or a null check first",
			node.location.line, node.location.column);
		const nullableRet = calleeType.typeReturn.typeReturn != null ? calleeType.typeReturn.typeReturn : inferredType();
		node.nodeType = nullableRet;
		return nullableRet;
	}
	if (calleeType != null && isValueCallee(d.callee) && !isCallableValueType(calleeType)) {
		addError(ctx, "This expression is not callable: type '" + typeDisplayName(calleeType) + "' has no call signatures" + unionCalleeHint(calleeType) + dynamicFieldCalleeHint(d.callee),
			node.location.line, node.location.column);
		node.nodeType = inferredType();
		return node.nodeType;
	}

	// Check argument types + infer generic return
	// @builtin("Echo"): accept any number of args of any type (reference echo parity)
	const isEchoBuiltin = node.resolvedSym != null && node.resolvedSym.builtinKind == "Echo";
	if (calleeType.kind == TypeKind.Function && !isEchoBuiltin) {
		// Rest param detection: last typeChildren entry is wrapped in TypeKind.Varargs
		// (reference parity: tyVarargs). createFunction installs the wrapper from
		// the legacy "..." name-prefix; the marker is the single source of truth.
		const lastCT = calleeType.typeChildren.length > 0
			? calleeType.typeChildren[calleeType.typeChildren.length - 1] : null;
		const hasRest = lastCT != null && lastCT.kind == TypeKind.Varargs;
		// Fill default arguments if too few args provided
		const minAr = callMinArity(calleeType);
		// Rest param is optional (accepts 0+ args), so effective min excludes it
		const effectiveMin = hasRest && minAr >= calleeType.typeChildren.length
			? calleeType.typeChildren.length - 1 : minAr;
		const restTuple = restTupleOf(calleeType!);
		const spread = takeOptionalSpread(ctx, d.arguments, argTypes, calleeDefaults(node, null, 0), calleeType.typeChildren, effectiveMin);
		if (spread.spread != null && !spread.taken) {
		} else if (refuseMisplacedSpread(ctx, d.arguments, calleeType.typeChildren, effectiveMin)) {
		} else if (restTuple != null) {
			fitRestTupleArgs(ctx, node, calleeType!, restTuple, minAr, argTypes.length);
		} else if (hasRest && restAwaitsInstance(lastCT!)) {
		} else if (argTypes.length < effectiveMin) {
			addError(ctx, `Too few arguments: expected at least ${effectiveMin}, got ${argTypes.length}`, node.location.line, node.location.column);
		} else if (!hasRest && argTypes.length > calleeType.typeChildren.length) {
			addError(ctx, `Too many arguments: expected at most ${calleeType.typeChildren.length}, got ${argTypes.length}`, node.location.line, node.location.column);
		} else if (argTypes.length < calleeType.typeChildren.length) {
			const calleeNameForDef = getCalleeNameForDefaults(node);
			if (calleeNameForDef != "") {
				fillDefaultArgsForNode(ctx, node, calleeNameForDef, calleeType.typeChildren.length, 0);
			}
			fillNullableTail(ctx, d.arguments, calleeType.typeChildren, node.location);
		}
		fillTakenSpread(ctx, d.arguments, argTypes, spread, calleeType.typeChildren);
		relateCallArgs(ctx, node, calleeType!, argTypes, isActorMethodCall);
		// On-demand generic instantiation for direct calls (transitive
		// instantiation). Handles both regular FunctionDecl and STATIC class
		// MethodDecl — non-static methods on generic classes go through the
		// class-instantiation path. See `tryInstantiateGenericCallee` for the
		// shared arg-unify + explicit-type-arg merge + sym/nodeType update.
		if (node.resolvedSym != null) {
			const directFlags = getGenericDeclFlags(node.resolvedSym.declNode);
			if (directFlags != "") {
				const newCalleeType = tryInstantiateGenericCallee(ctx, node, calleeType!, argTypes, directFlags, expectedType);
				if (newCalleeType != null) calleeType = newCalleeType;
			}
			if (!isGenericFn(directFlags) && node.resolvedSym.declNode != null && node.resolvedSym.declNode.kind == NodeKind.FunctionDecl) {
				checkExplicitTypeArgArity(ctx, node, [], getCalleeName(d.callee));
			}
		}
		// If explicit type args (<T>) and generic params, resolve type args at checker time
		if (hasGenericParams(calleeType)) {
			const explicitArg = findCallTypeArg(node);
			if (explicitArg != "") {
				return inferGenericReturnWithExplicit(calleeType!, argTypes, expectedType, explicitArg, ctx, node);
			}
		}
		// Assertion function narrowing: `asserts x is T`. Applied on the
		// general return path (not just extensions) so direct calls like
		// `assertString(val)` narrow `val` for subsequent statements.
		if (calleeType != null && calleeType.kind == TypeKind.Function
				&& calleeType.typeExtra != null
				&& calleeType.typeExtra.kind == TypeKind.None
				&& calleeType.typeExtra.typeName.length > 8
				&& calleeType.typeExtra.typeName.slice(0, 8) == "asserts:") {
			applyAssertionNarrowing(calleeType, d.arguments);
		}
		return inferGenericReturn(ctx, calleeType!, argTypes, expectedType, node);
	}
	return getReturnType(calleeType!);
}

function hasAddress(node: Node): boolean {
	if (node.kind == NodeKind.Identifier) {
		const sym = node.resolvedSym;
		return sym != null && (sym.symbolKind == SymbolKind.Variable || sym.symbolKind == SymbolKind.Parameter || sym.symbolKind == SymbolKind.Temp);
	}
	let base: Node | null = null;
	if (node.kind == NodeKind.MemberExpr) base = (node.data as MemberExprData).object;
	else if (node.kind == NodeKind.ArrayAccess) base = (node.data as ArrayAccessData).array;
	if (base == null) return node.kind == NodeKind.HiddenDeref;
	const baseType = base.nodeType;
	const heapBase = baseType != null && (baseType.kind == TypeKind.Ref || baseType.kind == TypeKind.Ptr
		|| baseType.kind == TypeKind.Array || baseType.kind == TypeKind.Span);
	return heapBase || hasAddress(base);
}

// Resolve generic return type using explicit type arg (e.g. parse<Person>)
function relateCallArgs(ctx: CheckerContext, node: Node, calleeType: Type, argTypes: Type[], isActorMethodCall: boolean): void {
	relateArgs(ctx, node, calleeType, (node.data as CallExprData).arguments, argTypes, isActorMethodCall);
}

function relateMethodCallArgs(ctx: CheckerContext, node: Node, calleeType: Type, recvFormal: Type | null, argTypes: Type[], isActorMethodCall: boolean): void {
	const d = node.data as CallExprData;
	if (recvFormal == null || d.callee.kind != NodeKind.MemberExpr || sharesArrayReceiver(recvFormal)) {
		if (recvFormal != null && d.callee.kind == NodeKind.MemberExpr) reportArrayReceiverWrite(ctx, d.callee.data as MemberExprData, recvFormal);
		relateCallArgs(ctx, node, calleeType, argTypes, isActorMethodCall);
		return;
	}
	const me = d.callee.data as MemberExprData;
	const recvType = me.object.nodeType;
	if (recvType == null) {
		relateCallArgs(ctx, node, calleeType, argTypes, isActorMethodCall);
		return;
	}
	const fullParams: Type[] = [recvFormal];
	const fullNames: string[] = ["this"];
	for (const t of calleeType.typeChildren) fullParams.push(t);
	for (const n of calleeType.typeNames) fullNames.push(n);
	const fullType = createFunction(fullParams, fullNames, calleeType.typeReturn);
	const args: Node[] = [me.object];
	const types: Type[] = [recvType];
	for (const a of d.arguments) args.push(a);
	for (const t of argTypes) types.push(t);
	relateArgs(ctx, node, fullType, args, types, isActorMethodCall, true);
	me.object = args[0];
	for (let ai = 0; ai < d.arguments.length; ai += 1) d.arguments[ai] = args[ai + 1];
	for (let ti = 0; ti < argTypes.length; ti += 1) argTypes[ti] = types[ti + 1];
}

function reportArrayReceiverWrite(ctx: CheckerContext, me: MemberExprData, recvFormal: Type): void {
	const formal = skipModifier(recvFormal) ?? recvFormal;
	const refusal = formal.kind == TypeKind.Span ? viewRefusal(me.object, formal)
		: writesThroughReceiver(formal) ? writeRefusal(me.object, WriteSite.Receiver, me.property) : "";
	if (refusal != "") addError(ctx, refusal, me.object.location.line, me.object.location.column);
}

function writesThroughReceiver(formal: Type): boolean {
	if (isReadonlyView(formal)) return false;
	return formal.kind == TypeKind.Span
		|| (formal.kind == TypeKind.Ref && formal.typeReturn != null && formal.typeReturn.kind == TypeKind.Array);
}

function sharesArrayReceiver(recvFormal: Type): boolean {
	const t = skipModifier(recvFormal) ?? recvFormal;
	const inner = t.kind == TypeKind.Ref && t.typeReturn != null ? t.typeReturn : t;
	return inner.kind == TypeKind.Array || inner.kind == TypeKind.SizedArray || inner.kind == TypeKind.Span;
}

function argLabel(pi: int32, hasReceiver: boolean): string {
	if (!hasReceiver) return "arg " + String(pi);
	return pi == 0 ? "receiver" : "arg " + String(pi - 1);
}

function textOfDistinctArgs(ctx: CheckerContext, args: Node[], argTypes: Type[], hasReceiver: boolean): void {
	for (let ai = hasReceiver ? 1 : 0; ai < args.length; ai += 1) {
		const t = args[ai].nodeType;
		if (refuseNamespaceText(ctx, args[ai])) continue;
		if (t == null || distinctBody(t) == null) continue;
		const text = distinctText(ctx, args[ai], t);
		if (text == null) continue;
		args[ai] = text;
		if (ai < argTypes.length) argTypes[ai] = stringType();
	}
}

function refuseTextlessArgs(ctx: CheckerContext, args: Node[], hasReceiver: boolean): boolean {
	let refused = false;
	for (let ai = hasReceiver ? 1 : 0; ai < args.length; ai += 1) {
		const textless = textlessValue(args[ai].nodeType);
		if (textless == "") continue;
		addError(ctx, textless, args[ai].location.line, args[ai].location.column);
		refused = true;
	}
	return refused;
}

function restTupleOf(calleeType: Type): Type | null {
	const n = calleeType.typeChildren.length;
	return n > 0 ? tupleOfRest(calleeType.typeChildren[n - 1]) : null;
}

function tupleOfRest(rest: Type): Type | null {
	if (rest.kind != TypeKind.Varargs) return null;
	const inner = peelTransparentInstance(unwrapVarargs(rest));
	return inner.kind == TypeKind.Tuple ? inner : null;
}

function formalAtPosition(calleeType: Type, pos: int32): Type | null {
	const restIdx = calleeType.typeChildren.length - 1;
	if (pos < restIdx) return calleeType.typeChildren[pos];
	const rest = restIdx >= 0 ? calleeType.typeChildren[restIdx] : null;
	if (rest != null && rest.kind == TypeKind.Varargs && restAwaitsInstance(rest)) return awaitedRestElement(rest, pos - restIdx);
	const tuple = restTupleOf(calleeType);
	if (tuple == null) return pos == restIdx ? rest : null;
	return pos - restIdx < tuple.typeChildren.length ? tuple.typeChildren[pos - restIdx] : null;
}

function awaitedRestElement(rest: Type, at: int32): Type | null {
	const inner = peelTransparentInstance(unwrapVarargs(rest));
	if (inner.kind != TypeKind.Conditional || inner.typeChildren.length != 4) return null;
	const whenTrue = tupleElementAt(inner.typeChildren[2], at);
	const whenFalse = tupleElementAt(inner.typeChildren[3], at);
	if (whenTrue == null || whenFalse == null) return whenTrue != null ? whenTrue : whenFalse;
	return sameType(whenTrue, whenFalse) ? whenTrue : null;
}

function tupleElementAt(t: Type, at: int32): Type | null {
	const tuple = peelTransparentInstance(t);
	return tuple.kind == TypeKind.Tuple && at < tuple.typeChildren.length ? tuple.typeChildren[at] : null;
}

function restWithoutElements(rest: Type): boolean {
	if (rest.kind != TypeKind.Varargs) return false;
	const inner = peelTransparentInstance(unwrapVarargs(rest));
	if (inner.kind == TypeKind.Conditional) return true;
	if (inner.kind == TypeKind.Tuple || getElementType(unwrapRef(inner)).kind != TypeKind.Inferred) return false;
	return inner.kind == TypeKind.GenericInstance || hasGenericParams(inner);
}

function restAwaitsInstance(rest: Type): boolean {
	const inner = peelTransparentInstance(unwrapVarargs(rest));
	if (isArrayShaped(inner) || inner.kind == TypeKind.Span || inner.kind == TypeKind.Tuple) return false;
	return hasGenericParams(inner);
}

function restArgsTuple(argTypes: Type[], from: int32): Type {
	const elements: Type[] = [];
	for (let i = from; i < argTypes.length; i += 1) elements.push(argTypes[i] != null ? argTypes[i] : inferredType());
	return createTuple(elements);
}

function fitRestTupleArgs(ctx: CheckerContext, node: Node, calleeType: Type, tuple: Type, fixedMin: number, given: int32): void {
	const args = (node.data as CallExprData).arguments;
	const restIdx = calleeType.typeChildren.length - 1;
	for (let i = restIdx; i < args.length; i += 1) {
		if (args[i].kind != NodeKind.SpreadExpr) continue;
		addError(ctx, "a spread argument cannot fill the tuple rest parameter '" + typeDisplayName(tuple) + "': pass its elements one by one",
			args[i].location.line, args[i].location.column);
		return;
	}
	const required = getMinArity(tuple);
	const min = required > 0 ? restIdx + required : (fixedMin < restIdx ? fixedMin : restIdx);
	const max = restIdx + tuple.typeChildren.length;
	if (given < min || given > max) {
		const bound = given < min ? "at least " + String(min) : "at most " + String(max);
		addError(ctx, (given < min ? "Too few" : "Too many") + " arguments: expected " + bound + ", got " + String(given)
			+ " (the rest parameter takes '" + typeDisplayName(tuple) + "')", node.location.line, node.location.column);
		return;
	}
	if (given < restIdx) {
		const calleeNameForDef = getCalleeNameForDefaults(node);
		if (calleeNameForDef != "") fillDefaultArgsForNode(ctx, node, calleeNameForDef, restIdx, 0);
	}
	const expanded: Type[] = calleeType.typeChildren.slice(0, restIdx);
	for (const element of tuple.typeChildren) expanded.push(element);
	fillNullableTail(ctx, args, expanded, node.location);
}

function argLabelCap(pi: int32, hasReceiver: boolean): string {
	if (hasReceiver && pi == 0) return "Receiver";
	return "Argument " + String(hasReceiver ? pi - 1 : pi);
}

function relateArgs(ctx: CheckerContext, node: Node, calleeType: Type, args: Node[], argTypes: Type[], isActorMethodCall: boolean, hasReceiver: boolean = false): void {
	const builtin = node.resolvedSym != null ? node.resolvedSym.builtinKind : "";
	if (builtin == "Echo" || builtin == "ToString") textOfDistinctArgs(ctx, args, argTypes, hasReceiver);
	if (builtin == "Echo") return;
	if (builtin == "ToString" && refuseTextlessArgs(ctx, args, hasReceiver)) return;
	const d = node.data as CallExprData;
	const lastCT = calleeType.typeChildren.length > 0
		? calleeType.typeChildren[calleeType.typeChildren.length - 1] : null;
	const hasRest = lastCT != null && lastCT.kind == TypeKind.Varargs;
	// Type-check provided args (rest args check against element type of rest param)
	const restParamIdx = hasRest ? calleeType.typeChildren.length - 1 : -1;
	const restTuple = restTupleOf(calleeType);
	let actorBorrowReported = false;
	for (let pi = 0; pi < argTypes.length; pi += 1) {
		let paramType: Type = null as unknown as Type;
		if (restTuple != null && pi >= restParamIdx) {
			if (pi - restParamIdx >= restTuple.typeChildren.length) continue;
			paramType = restTuple.typeChildren[pi - restParamIdx];
		} else if (hasRest && pi >= restParamIdx && restWithoutElements(lastCT!)) {
			continue;
		} else if (hasRest && pi >= restParamIdx) {
			const restArr = unwrapRef(unwrapVarargs(lastCT));
			const restElem = getElementType(restArr);
			paramType = restElem.kind == TypeKind.Inferred ? restArr : restElem;
		} else if (pi < calleeType.typeChildren.length) {
			paramType = calleeType.typeChildren[pi];
		} else {
			continue;
		}
		paramType = peelTransparentInstance(paramType);
		if (argTypes[pi] == null || argTypes[pi] == null) continue;
		const foreignVarargs = hasRest && pi >= restParamIdx && node.resolvedSym != null && hasFlag(node.resolvedSym, SymbolFlag.ImportC);
		const formal: Type = skipModifier(paramType) ?? paramType;
		const viewed = viewRefusal(args[pi], formal);
		if (viewed != "") addError(ctx, viewed, args[pi].location.line, args[pi].location.column);
		const formalHeld = formal.kind == TypeKind.Union ? unwrapRefNullUnion(formal) : formal;
		if (isUnknownType(formalHeld) && !foreignVarargs) {
			const refusal = unknownRefusal(argTypes[pi]);
			if (refusal != UnknownRefusal.None) {
				addError(ctx, argLabelCap(pi, hasReceiver) + ": " + unknownRefusalText(argTypes[pi], refusal), node.location.line, node.location.column);
			}
		} else if (isUnknownType(argTypes[pi]) && formal.kind != TypeKind.Unknown && !isUnresolvedType(formal) && formal.kind != TypeKind.GenericParam
				&& !(formal.kind == TypeKind.Mapped && mappedIsGeneric(formal))) {
			const collapsedParam = formal.kind == TypeKind.Union ? unwrapRefNullUnion(formal) : null;
			if (collapsedParam == null || (collapsedParam.kind != TypeKind.Unknown && !isUnresolvedType(collapsedParam))) {
				addError(ctx, argLabelCap(pi, hasReceiver) + ": unknown is not assignable to " + typeDisplayName(formal) + " — narrow with an explicit cast", node.location.line, node.location.column);
				continue;
			}
		}
		const intoUnknown = foreignVarargs ? args[pi] : convertIntoUnknown(args[pi], argTypes[pi], paramType);
		if (intoUnknown != args[pi]) {
			args[pi] = intoUnknown;
			argTypes[pi] = intoUnknown.nodeType!;
		}
		const fnShaped = peelTransparentInstance(argTypes[pi]).kind == TypeKind.Function
			|| peelTransparentInstance(paramType).kind == TypeKind.Function;
		if (!isUnresolvedType(paramType) && paramType.kind != TypeKind.GenericParam
			&& !isUnresolvedType(argTypes[pi]) && argTypes[pi].kind != TypeKind.Error
			&& !(fnShaped && hasGenericParams(paramType))) {
			argTypes[pi] = storedTypeOfNullRead(args[pi], argTypes[pi], paramType);
			const constantArg = fitIntegerConstant(ctx, args[pi], argTypes[pi], paramType);
			if (constantArg != null) {
				args[pi] = constantArg;
				argTypes[pi] = constantArg.nodeType!;
			}
			// Maybe<T> coercion: f(42) / f(null) where f: (number | null) → ...
			// Mirrors the fitNode wrap rule used for var-decl/return/assignment;
			// call args go through this site instead of fitNode. Applied
			// independently of isAssignable because (a) null IS assignable
			// to struct (so isAssignable would skip the wrap), but codegen
			// still needs a typed null to emit {0}, and (b) inner T is
			// not directly assignable to Maybe<T> — we want a struct literal.
			// Generic-containing formals never wrap here — deferred to the
			// post-binding reconciliation (Nim implicitConv, sigmatch.nim:2179).
			const carriedConstant = numericConstantForCarrier(args[pi], argTypes[pi], paramType);
			if (carriedConstant != null) {
				args[pi] = carriedConstant;
				argTypes[pi] = carriedConstant.nodeType!;
			}
			const numericMember = fitNumericIntoUnion(ctx, args[pi], argTypes[pi], paramType);
			if (numericMember != null) {
				args[pi] = numericMember;
				argTypes[pi] = paramType;
			}
			if (isNumeric(peelSink(paramType)) && widenNumberLiteralType(argTypes[pi]) != argTypes[pi]) {
				args[pi] = widenNumberLiteral(args[pi]);
				argTypes[pi] = args[pi].nodeType!;
			}
			const argHeld = peelTransparentInstance(argTypes[pi]);
			const maybeFormal = peelSink(paramType);
			if (isMaybeType(maybeFormal) && maybeFormal.typeReturn != null
					&& !isMaybeType(argHeld)
					&& (args[pi].kind == NodeKind.NullLiteral
						|| argTypes[pi].kind == TypeKind.Null
						|| isAssignable(argTypes[pi], maybeFormal.typeReturn)
						|| arityAdapts(argTypes[pi], maybeFormal.typeReturn))) {
				args[pi] = synthMaybeWrap(args[pi], maybeFormal, argTypes[pi], ctx);
				argTypes[pi] = maybeFormal;
			}
			// `A | null` meeting `A | B | null`. Same reason the wrap above
			// lives here: an argument never reaches fitNode, so the carrier
			// widening has to be applied at this site too.
			if (isMaybeType(maybeFormal)) {
				const widenedArg = widenMaybePayload(args[pi], maybeFormal, argTypes[pi]);
				if (widenedArg != null as unknown as Node) {
					args[pi] = widenedArg;
					argTypes[pi] = maybeFormal;
				}
			}
			const adoptedArg = tryAdoptAnonStruct(ctx, args[pi], paramType, argTypes[pi]);
			if (adoptedArg != null as unknown as Node) {
				args[pi] = adoptedArg;
				argTypes[pi] = paramType;
			}
			const upcastArg = tryStructUpcast(args[pi], paramType, argTypes[pi]);
			if (upcastArg != null as unknown as Node) {
				args[pi] = upcastArg;
				argTypes[pi] = paramType;
			}
			if (instantiateGenericFnValue(ctx, args[pi], paramType)) argTypes[pi] = args[pi].nodeType!;
			const sendableArg = fitSendable(ctx, args[pi], paramType, argTypes[pi]);
			if (sendableArg != null) argTypes[pi] = sendableArg;
			const thunkArg = synthClosureThunk(args[pi], peelSink(paramType), argTypes[pi], ctx);
			if (thunkArg != null as unknown as Node) {
				args[pi] = thunkArg;
				argTypes[pi] = paramType;
			}
			if (paramType.kind == TypeKind.CString
					&& (argTypes[pi].kind == TypeKind.String || argTypes[pi].kind == TypeKind.StringLiteral)) {
				refuseDanglingCString(ctx, args[pi], true);
				args[pi] = synthCStringConv(args[pi], paramType);
				argTypes[pi] = paramType;
			}
			const formalAwaitsBinding = pi < args.length && args[pi] != null
				&& hasGenericParams(paramType);
			let addressAtC = false;
			const unionFit = formalAwaitsBinding ? null : fitUnionIntoUnion(args[pi], argTypes[pi], paramType);
			if (unionFit != null) {
				args[pi] = unionFit;
				argTypes[pi] = paramType;
			}
			if (!formalAwaitsBinding && !isAssignable(argTypes[pi], paramType)) {
				if (takesAddressAtCArg(argTypes[pi], paramType) && (node.resolvedSym == null || !hasFlag(node.resolvedSym, SymbolFlag.ImportC))) {
					addError(ctx, "Argument type mismatch in '" + getCalleeName(d.callee) + "' " + argLabel(pi, hasReceiver) + ": got " + typeDisplayName(argTypes[pi]) + ", expected " + typeDisplayName(paramType)
						+ " — a value is not a pointer, and its address is taken implicitly only for an extern C function; declare the parameter 'ref x: " + typeDisplayName(argTypes[pi]) + "' or 'x: " + typeDisplayName(argTypes[pi]) + "'",
						node.location.line, node.location.column);
				} else if (numericConvRefuses(argTypes[pi], paramType)) {
					if (!isFittingNumericConstant(args[pi], paramType)) {
						reportNumericConvConstAware(ctx, args[pi], argTypes[pi], paramType, " in '" + getCalleeName(d.callee) + "' " + argLabel(pi, hasReceiver));
					} else {
						const rounded = float32ConstantLiteral(args[pi], paramType);
						if (rounded != null) {
							args[pi] = rounded;
							argTypes[pi] = rounded.nodeType!;
						}
					}
				} else if (convertsImplicitly(argTypes[pi], paramType)) {
				} else if (takesAddressAtCArg(argTypes[pi], paramType)) {
					addressAtC = hasAddress(args[pi]);
					if (!addressAtC) {
						addError(ctx, "'" + getCalleeName(d.callee) + "' " + argLabel(pi, hasReceiver) + ": expression has no address — the C parameter " + typeDisplayName(paramType)
							+ " takes the address of a variable, a field or an element; store the " + typeDisplayName(argTypes[pi]) + " in a variable first",
							node.location.line, node.location.column);
					}
				} else {
					const coerced = tryApplyConverter(ctx, args[pi], argTypes[pi], paramType);
					if (coerced != null) {
						args[pi] = coerced;
						if (coerced.nodeType != null) { argTypes[pi] = coerced.nodeType; }
					} else {
						const readAsValue = !hasGenericParams(paramType) && valueOfInPlace(ctx, args[pi]) && args[pi].nodeType != null;
						if (readAsValue) { argTypes[pi] = args[pi].nodeType!; }
						if (readAsValue && (isAssignable(argTypes[pi], paramType) || needsStdConv(argTypes[pi], paramType))) {
							args[pi] = fitNode(ctx, args[pi], paramType, argTypes[pi]);
							argTypes[pi] = args[pi].nodeType!;
						} else {
							const calleeName = getCalleeName(d.callee);
							const variantRefusal = variantIntoObjectRefusal(args[pi], argTypes[pi], paramType);
							addError(ctx, variantRefusal != "" ? variantRefusal : "Argument type mismatch in '" + calleeName + "' " + argLabel(pi, hasReceiver) + ": got " + typeDisplayName(argTypes[pi]) + ", expected " + typeDisplayName(paramType) + numericUnionRefusal(argTypes[pi], paramType) + unknownReturnRefusal(argTypes[pi], paramType) + returnReprRefusal(argTypes[pi], paramType, wrappedFnText(args[pi])) + explainStructuralPrefix(argTypes[pi], paramType) + refDerefHint(args[pi], argTypes[pi], paramType), node.location.line, node.location.column);
						}
					}
				}
			}
			// Reference parity: var/out params require lvalue argument
			if (!isOutParam(paramType) && pi < args.length && args[pi].kind == NodeKind.OutExpr) {
				addError(ctx, "'" + getCalleeName(d.callee) + "' " + argLabel(pi, hasReceiver) + ": 'out' is written only for an out parameter, and this parameter is not one", node.location.line, node.location.column);
			}
			if (paramType.kind == TypeKind.Var && pi < args.length) {
				let lvArg = args[pi];
				if (lvArg.kind == NodeKind.OutExpr) { lvArg = (lvArg.data as OutExprData).outArg; }
				if (isOutParam(paramType)) {
					takesOut(ctx, lvArg);
				}
				if (!isLocation(lvArg)) {
					const calleeName = getCalleeName(d.callee);
					addError(ctx, "'" + calleeName + "' " + argLabel(pi, hasReceiver) + ": out parameter requires a variable, not an expression", node.location.line, node.location.column);
				} else {
					const ro = readonlyRootType(lvArg);
					const refusal = writeThroughArc(lvArg)
						? "cannot pass an argument to a 'ref' or 'out' parameter through 'Arc<T>' — SHARE is immutable; shared mutable state is Locked<T> (PARALOCK Amendment I)"
						: ro != null
						? "cannot pass an argument to a 'ref' or 'out' parameter through " + typeDisplayName(ro) + " — a read-only view never converts back to the mutable type (PARALOCK E24)"
						: writeRefusal(lvArg, WriteSite.RefArg);
					if (refusal != "") addError(ctx, refusal, lvArg.location.line, lvArg.location.column);
					const written = paramType.typeReturn;
					if (written != null && argTypes[pi] != null && needsStdConv(argTypes[pi], written)) {
						addError(ctx, "'" + getCalleeName(d.callee) + "' " + argLabel(pi, hasReceiver) + ": an out parameter of type " + typeDisplayName(written)
							+ " is written in place, so the variable must be " + typeDisplayName(written) + ", not " + typeDisplayName(argTypes[pi])
							+ " — declare it as " + typeDisplayName(written) + " and convert after the call", lvArg.location.line, lvArg.location.column);
					}
				}
			}
			if ((!formalAwaitsBinding && needsStdConv(argTypes[pi], paramType)) || addressAtC) {
				// Implementation parity: insert HiddenStdConv for numeric widening/narrowing OR Span coercion
				const convType = paramType.kind == TypeKind.Sink && paramType.typeReturn != null ? paramType.typeReturn : paramType;
				const convTok = createToken(TokenKind.Ident, "", args[pi].location.line);
				const convNode = createNode(NodeKind.HiddenStdConv, { convExpr: args[pi], convType: convType }, convTok);
				convNode.nodeType = convType;
				convNode.flags = convNode.flags.incl(NodeFlag.Sem);
				args[pi] = convNode;
			}
			const paramValue = skipModifier(paramType);
			if (!formalAwaitsBinding && paramValue != null && instantiatedUnionBehind(paramValue).kind == TypeKind.Union && pi < args.length && argTypes[pi] != null) {
				const argNow = args[pi].nodeType != null ? args[pi].nodeType! : argTypes[pi];
				const uw = widenVariantToUnion(args[pi], paramValue, argNow, ctx);
				if (uw != null as unknown as Node) args[pi] = uw;
			}
			if (paramValue != null && instantiatedUnionBehind(paramValue).kind != TypeKind.Union && pi < args.length && argTypes[pi] != null) {
				const pj = narrowUnionToVariant(args[pi], argTypes[pi]);
				if (pj != null as unknown as Node) args[pi] = pj;
			}
			// Sendable check: actor method args must be safe to cross boundary
			if (isActorMethodCall && pi < args.length) {
				const sendClass = calleeType == null || calleeType.typeReturn == null
					|| calleeType.typeReturn.kind == TypeKind.Void;
				const borrowed = checkActorArgSendable(ctx, node, args[pi], pi, sendClass);
				if (borrowed && !actorBorrowReported && node == ctx.stmtPosExpr) {
					actorBorrowReported = true;
					addError(ctx, "discarded actor call borrows a plain reference — the reply is what keeps it alive\nawait the call, or pass `move` / `Arc<T>` (PARALOCK I21)",
						node.location.line, node.location.column);
				}
			}
		}
	}
}

function inferGenericReturnWithExplicit(fnType: Type, argTypes: Type[], expectedType: Type | null, explicitArg: string, ctx: CheckerContext, node: Node): Type {
	let returnType = fnType.typeReturn;
	if (returnType == null) return inferredType();
	// Multi-arg form `f<A, B>(...)` binds generic params positionally (parity:
	// explicitGenericInstantiation → setGenericParams + matchGenericParams in
	// the reference). The single-arg path below only binds the first generic
	// param found in the return type, so route multi-arg through explicit
	// positional bindings instead — `Result.ok<int32, string>(5)` needs both.
	const argNames = splitTopLevel(explicitArg, ",");
	if (argNames.length > 1) {
		let params: Type[] = [];
		if (node.resolvedSym != null) {
			params = ownTypeParams(node.resolvedSym, extractGenericNames(getGenericDeclFlags(node.resolvedSym.declNode)));
		}
		if (params.length == 0) {
			const cd = node.data as CallExprData;
			if (cd.callee != null && cd.callee.kind == NodeKind.MemberExpr) {
				const me = cd.callee.data as MemberExprData;
				if (me.object != null && me.object.kind == NodeKind.Identifier) {
					const objSym = me.object.resolvedSym;
					const classNames = splitTopLevel(objSym != null ? genericParamNamesOf(symGenericParams(objSym)) : genericParamsOf(me.object.nodeType), ",");
					params = objSym != null ? declaredTypeParams(objSym, classNames.length) : me.object.nodeType != null ? declaredParamsOf(me.object.nodeType, classNames.length) : [];
				}
			}
		}
		if (params.length == 0) {
			return inferGenericReturn(ctx, fnType, argTypes, expectedType, node);
		}
		const eb = createUnifyBindings();
		for (let i = 0; i < argNames.length && i < params.length; i += 1) {
			const argName = argNames[i].trim();
			if (argName == "") continue;
			const resolved = resolveAnnotation(argName, ctx, node.location.line, node.location.column);
			if (resolved != null && !isUnresolvedType(resolved)) bindParam(eb, params[i], resolved);
		}
		if (eb.names.length == 0) {
			return inferGenericReturn(ctx, fnType, argTypes, expectedType, node);
		}
		fitArgsToBoundFormals(ctx, node, fnType, eb);
		returnType = applySubstitutions(returnType, eb);
		if (returnType.kind == TypeKind.GenericInstance && returnType.typeReturn == null) {
			const declParams = genericParamsOf(returnType);
			if (declParams != "") {
				instantiateGenericBody(returnType, declParams);
			}
		}
		if (ctx.inGenericContext == 0 && hasGenericParams(returnType)) {
			const unbound = findFirstGenericParamName(returnType);
			addError(ctx, "cannot instantiate: '" + unbound + "' — annotate the destination type or pass an explicit type argument", node.location.line, node.location.column);
			return errorType();
		}
		return returnType;
	}
	// Resolve the explicit type arg to an actual type
	const resolvedSym = lookupSymbol(ctx.table, explicitArg);
	if (resolvedSym == null) return inferGenericReturn(ctx, fnType, argTypes, expectedType, node);
	ensureShaped(resolvedSym, ctx);
	const concreteType = resolvedSym.symbolType;
	// Record the type arg as a symbol reference for LSP hover/goto-def
	if (node != null) {
		const typeArgCol = computeTypeArgCol(node);
		if (typeArgCol > 0) {
			const symKind = resolvedSym.symbolKind == SymbolKind.Interface ? SymbolKind.Interface
				: resolvedSym.symbolKind == SymbolKind.Class ? SymbolKind.Class
				: resolvedSym.symbolKind == SymbolKind.Actor ? SymbolKind.Actor
				: resolvedSym.symbolKind == SymbolKind.TypeAlias ? SymbolKind.TypeAlias
				: SymbolKind.Interface;
			sgRecordSym(ctx, node.location.line, typeArgCol, typeArgCol + explicitArg.length, resolvedSym, concreteType, symKind, explicitArg, "", false);
		}
	}
	// Single type arg → bind to first generic param found in the return type
	const firstParam = findFirstGenericParam(returnType, new TypeVisitSet());
	if (firstParam != null) {
		const single = createUnifyBindings();
		bindParam(single, firstParam, concreteType);
		fitArgsToBoundFormals(ctx, node, fnType, single);
		returnType = substituteBound(returnType, single);
		// Reference parity: eagerly instantiate body for concrete GenericInstance
		if (returnType.kind == TypeKind.GenericInstance && returnType.typeReturn == null) {
			const declParams = genericParamsOf(returnType);
			instantiateGenericBody(returnType, declParams);
		}
	}
	if (ctx.inGenericContext == 0 && hasGenericParams(returnType)) {
		const unbound = findFirstGenericParamName(returnType);
		addError(ctx, "cannot instantiate: '" + unbound + "' — annotate the destination type or pass an explicit type argument", node.location.line, node.location.column);
		return errorType();
	}
	return returnType;
}

function fitArgsToBoundFormals(ctx: CheckerContext, node: Node, fnType: Type, bindings: UnifyBindings): void {
	const cd = node.data as CallExprData;
	const lim = cd.arguments.length < fnType.typeChildren.length ? cd.arguments.length : fnType.typeChildren.length;
	for (let ai = 0; ai < lim; ai += 1) {
		const arg = cd.arguments[ai];
		if (arg == null || arg.nodeType == null || arg.nodeType.kind == TypeKind.Error) continue;
		const formal = applySubstitutions(fnType.typeChildren[ai], bindings);
		if (formal != null && restWithoutElements(formal)) continue;
		if (formal == null || hasGenericParams(formal)) continue;
		if (!isAssignable(arg.nodeType, formal) && !needsStdConv(arg.nodeType, formal)) {
			addError(ctx, "Argument type mismatch in '" + getCalleeName(cd.callee) + "' arg " + String(ai) + ": got " + typeDisplayName(arg.nodeType) + ", expected " + typeDisplayName(formal) + returnReprRefusal(arg.nodeType, formal, wrappedFnText(arg)) + refDerefHint(arg, arg.nodeType, formal),
				arg.location.line, arg.location.column);
			continue;
		}
		cd.arguments[ai] = fitNode(ctx, arg, formal, arg.nodeType);
	}
}

function argumentsMatchFormals(fnType: Type, argTypes: Type[], bindings: UnifyBindings): boolean {
	const lim = argTypes.length < fnType.typeChildren.length ? argTypes.length : fnType.typeChildren.length;
	for (let ai = 0; ai < lim; ai += 1) {
		const at = argTypes[ai];
		if (at == null || isUnresolvedType(at) || isUnknownType(at) || at.kind == TypeKind.Error || at.kind == TypeKind.Null) continue;
		const formal = fnType.typeChildren[ai];
		if (!hasGenericParams(formal)) continue;
		if (hasGenericParams(applySubstitutions(formal, bindings)) && !isAssignable(at, formal)) return false;
	}
	return true;
}

function bindFromUnfitDestination(fnType: Type, bindings: UnifyBindings, fixed: string[], argTypes: Type[], expectedType: Type | null): boolean {
	const ret = fnType.typeReturn;
	if (expectedType == null || isUnresolvedType(expectedType) || ret == null) return false;
	if (!argumentsMatchFormals(fnType, argTypes, bindings)) return false;
	const context = bindFromExpectedReturn(fnType, expectedType);
	const rebound = createUnifyBindings();
	for (let bi = 0; bi < bindings.names.length; bi += 1) bindAt(rebound, bindings, bi);
	mergeUnifyBindings(rebound, context);
	const current = applySubstitutions(ret, rebound);
	if (hasGenericParams(current) || !slotRefuses(current, expectedType)) return false;
	let moved = false;
	for (let ci = 0; ci < context.names.length; ci += 1) {
		const idx = findBindingIndex(rebound, context.names[ci]);
		if (idx == -1 || hasGenericParams(context.types[ci]) || sameType(rebound.types[idx], context.types[ci])) continue;
		if (fixed.includes(context.names[ci])) return false;
		rebound.types[idx] = context.types[ci];
		moved = true;
	}
	if (!moved || !isAssignable(applySubstitutions(ret, rebound), expectedType)) return false;
	const lim = argTypes.length < fnType.typeChildren.length ? argTypes.length : fnType.typeChildren.length;
	for (let ai = 0; ai < lim; ai += 1) {
		const at = argTypes[ai];
		if (at == null || isUnresolvedType(at) || at.kind == TypeKind.Error || at.kind == TypeKind.Null) continue;
		if (!hasGenericParams(fnType.typeChildren[ai])) continue;
		const formal = applySubstitutions(fnType.typeChildren[ai], rebound);
		if (hasGenericParams(formal) || slotRefuses(at, formal)) return false;
	}
	for (let bi = 0; bi < bindings.types.length; bi += 1) bindings.types[bi] = rebound.types[bi];
	return true;
}

// Compute the column where the type arg name starts (after '<') in a call expression.
// For `foo<T>(...)`: callee.col + "foo".length + 1 (skip '<')
// For `obj.method<T>(...)`: callee.col + 1 + "method".length + 1 (skip '.' and '<')
function computeTypeArgCol(node: Node): int32 {
	const cd = node.data as CallExprData;
	if (cd.callee == null) return 0;
	if (cd.callee.kind == NodeKind.Identifier) {
		const name = (cd.callee.data as IdentifierData).name;
		return cd.callee.location.column + name.length + 1;  // +1 for '<'
	}
	if (cd.callee.kind == NodeKind.MemberExpr) {
		const me = cd.callee.data as MemberExprData;
		// callee location points to property start (after dot)
		return cd.callee.location.column + 1 + me.property.length + 1;  // +1 col offset, +propLen, +1 for '<'
	}
	return 0;
}

function findFirstGenericParam(t: Type | null, seen: TypeVisitSet): Type | null {
	if (t == null) return null;
	if (t.kind == TypeKind.GenericParam) return t;
	if (!typeVisitAdd(seen, t)) return null;
	const viaReturn = findFirstGenericParam(t.typeReturn, seen);
	if (viaReturn != null) return viaReturn;
	const viaExtra = findFirstGenericParam(t.typeExtra, seen);
	if (viaExtra != null) return viaExtra;
	for (const c of t.typeChildren) {
		const found = findFirstGenericParam(c, seen);
		if (found != null) return found;
	}
	return null;
}

function findFirstGenericParamName(t: Type): string {
	const gp = findFirstGenericParam(t, new TypeVisitSet());
	return gp != null ? gp.typeName : "";
}

// Apply assertion narrowing: `asserts paramName is TargetType`. Mutates the
// argument's Symbol.symbolType so all subsequent checker references see the
// narrowed type. Safe because assertion functions are contracts — if they
// pass, the type holds unconditionally; if they fail, they throw/abort.
function applyAssertionNarrowing(calleeType: Type, args: Node[]): void {
	const sentinel = calleeType.typeExtra;
	if (sentinel == null) return;
	const assertParamName = sentinel.typeName.slice(8, sentinel.typeName.length);
	const targetType = sentinel.typeReturn;
	if (targetType == null || assertParamName == "") return;
	// Find the matching parameter index.
	if (calleeType.typeNames == null) return;
	let paramIdx: int32 = -1;
	let pi: int32 = 0;
	while (pi < calleeType.typeNames.length) {
		if (calleeType.typeNames[pi] == assertParamName) { paramIdx = pi; break; }
		pi = pi + 1;
	}
	if (paramIdx < 0 || paramIdx >= args.length) return;
	const arg = args[paramIdx];
	if (arg == null || arg.kind != NodeKind.Identifier) return;
	const argSym = arg.resolvedSym;
	if (argSym == null) return;
	argSym.symbolType = targetType;
}

export function inferGenericReturn(ctx: CheckerContext, fnType: Type, argTypes: Type[], expectedType: Type | null, callNode: Node | null): Type {
	let returnType = fnType.typeReturn;
	if (returnType == null) return inferredType();

	const hasExpected = expectedType != null && !isUnresolvedType(expectedType);

	const argBindings = createUnifyBindings();
	for (let i = 0; i < fnType.typeChildren.length && i < argTypes.length; i += 1) {
		const at = argTypes[i];
		if (at == null) continue;
		if (isUnresolvedType(at) || at.kind == TypeKind.Error) continue;
		if (hasExpected && at.kind == TypeKind.Null) continue;
		unifyType(fnType.typeChildren[i], at, argBindings);
	}

	if (hasExpected && callNode != null && callNode.kind == NodeKind.CallExpr
			&& bindFromUnfitDestination(fnType, argBindings, [], argTypes, expectedType)) {
		fitArgsToBoundFormals(ctx, callNode, fnType, argBindings);
	}
	if (hasExpected && argumentsMatchFormals(fnType, argTypes, argBindings)) {
		mergeUnifyBindings(argBindings, bindFromExpectedReturn(fnType, expectedType));
	}

	returnType = applySubstitutions(returnType, argBindings);
	// With bindings final, a variant arg meeting a now-concrete union formal
	// gets its conversion here — same wrap every other fit position takes.
	if (callNode != null && callNode.kind == NodeKind.CallExpr) {
		const cd = callNode.data as CallExprData;
		const lim = cd.arguments.length < fnType.typeChildren.length ? cd.arguments.length : fnType.typeChildren.length;
		for (let ai = 0; ai < lim; ai += 1) {
			const arg = cd.arguments[ai];
			if (arg == null || arg.nodeType == null) continue;
			const formal = applySubstitutions(fnType.typeChildren[ai], argBindings);
			const formalValue = skipModifier(formal);
			if (formalValue != null && instantiatedUnionBehind(formalValue).kind == TypeKind.Union) {
				const uw = widenVariantToUnion(arg, formalValue, arg.nodeType, ctx);
				if (uw != null as unknown as Node) cd.arguments[ai] = uw;
			}
			const adoptedGen = tryAdoptAnonStruct(ctx, arg, formal, arg.nodeType);
			if (adoptedGen != null as unknown as Node) cd.arguments[ai] = adoptedGen;
			const upcastGen = tryStructUpcast(cd.arguments[ai], formal, cd.arguments[ai].nodeType);
			if (upcastGen != null as unknown as Node) cd.arguments[ai] = upcastGen;
		}
	}
	// Eagerly instantiate body for concrete GenericInstance — mirrors
	// inferGenericReturnWithExplicit. Without this, downstream peelToStructOrUnion
	// falls back to the un-substituted typeExtra and `r.value.field` access
	// leaks GenericParam (synthesizes getDynamicField against JsonValue).
	// Built-in Result/Promise/Iterator get param names via `builtinGenericParams`.
	if (returnType.kind == TypeKind.GenericInstance && returnType.typeReturn == null) {
		const declParams = genericParamsOf(returnType);
		if (declParams != "") {
			instantiateGenericBody(returnType, declParams);
		}
	}
	// A formal that received an argument yet still carries a GenericParam after
	// binding would mono into a call with no emitted body — fail loud here, not
	// at C-compile. Return-type-only checking misses param-only T.
	if (ctx.inGenericContext == 0) {
		const chkLim = argTypes.length < fnType.typeChildren.length ? argTypes.length : fnType.typeChildren.length;
		for (let fi = 0; fi < chkLim; fi += 1) {
			const fFormal = fnType.typeChildren[fi];
			if (fFormal == null || !hasGenericParams(fFormal)) continue;
			const fSub = applySubstitutions(fFormal, argBindings);
			if (hasGenericParams(fSub)) {
				if (callNode != null && callNode.kind == NodeKind.CallExpr && argTypes[fi] != null
						&& refusedThroughMapped(ctx, callNode.data as CallExprData, fi, fFormal, argTypes[fi])) return errorType();
				if (callNode != null && callNode.kind == NodeKind.CallExpr && argTypes[fi] != null
						&& !isAssignable(argTypes[fi], fFormal)
						&& !(fi < (callNode.data as CallExprData).arguments.length && literalShortOfSlot((callNode.data as CallExprData).arguments[fi], fFormal))) {
					const mcd = callNode.data as CallExprData;
					const argLoc = fi < mcd.arguments.length && mcd.arguments[fi] != null ? mcd.arguments[fi].location : callNode.location;
					const hint = fi < mcd.arguments.length && mcd.arguments[fi] != null ? refDerefHint(mcd.arguments[fi], argTypes[fi], fFormal) : "";
					addError(ctx, "Argument type mismatch in '" + getCalleeName(mcd.callee) + "' arg " + String(fi)
						+ ": got " + typeDisplayName(argTypes[fi]) + ", expected " + typeDisplayName(fFormal) + hint, argLoc.line, argLoc.column);
					return errorType();
				}
				const unboundP = findFirstGenericParamName(fSub);
				const pLine = callNode != null ? callNode.location.line : 0;
				const pCol = callNode != null ? callNode.location.column : 0;
				addError(ctx, "cannot instantiate: '" + unboundP + "' — annotate the destination type or pass an explicit type argument", pLine, pCol);
				return errorType();
			}
		}
	}
	if (ctx.inGenericContext == 0 && hasGenericParams(returnType)) {
		const unbound = findFirstGenericParamName(returnType);
		const errLine = callNode != null ? callNode.location.line : 0;
		const errCol = callNode != null ? callNode.location.column : 0;
		addError(ctx, "cannot instantiate: '" + unbound + "' — annotate the destination type or pass an explicit type argument", errLine, errCol);
		return errorType();
	}
	return returnType;
}

function findBindingIndex(b: UnifyBindings, name: string): number {
	for (let i = 0; i < b.names.length; i += 1) {
		if (b.names[i] == name) return i;
	}
	return -1;
}

// Apply every binding in `b` to type `t` by identity. Used by callers
// that need to convert a formal type containing GenericParam(s) into its
// concrete substituted form after Pass 1/2/3 binding.
function applySubstitutions(t: Type, b: UnifyBindings): Type {
	if (b.names.length == 0) return t;
	return substituteBound(t, b);
}

function hasBindingName(b: UnifyBindings, name: string): boolean {
	return findBindingIndex(b, name) != -1;
}

// Resolve explicit type args from a CallExpr `f<T1, T2>(...)` against the
// supplied generic parameter names (in declaration order). Returns empty
// bindings when no explicit args present, names list empty, or types fail to
// resolve.
//
// Source-agnostic: the caller is responsible for extracting paramNames from
// the appropriate source — `extractGenericNames(fnFlags)` for FunctionDecl,
// `symGenericParams(classSym)` split-on-comma for classes/interfaces. Keeps
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
export function rearmLiteralForRecheck(lit: Node, formal: Type | null): void {
	lit.flags = lit.flags.excl(NodeFlag.Sem);
	lit.nodeType = null;
	if (lit.kind != NodeKind.ObjectLiteral) return;
	const od = lit.data as ObjectLiteralData;
	for (let i = 0; i < od.properties.length; i += 1) {
		const v = od.properties[i];
		if (v == null) continue;
		if (v.kind != NodeKind.ObjectLiteral && v.kind != NodeKind.ArrowFunction && v.kind != NodeKind.FunctionExpr) continue;
		let ft: Type | null = null;
		if (formal != null && i < od.keys.length) {
			const got = getProperty(formal, od.keys[i]);
			if (got != null && !isUnresolvedType(got) && got.kind != TypeKind.Error) ft = got;
		}
		if (ft != null && !hasGenericParams(ft)) continue;
		if (v.kind != NodeKind.ObjectLiteral) { clearCheckerState(v); continue; }
		const st = ft == null ? null : peelToStructOrUnion(ft);
		if (st != null && st.kind == TypeKind.Struct) rearmLiteralForRecheck(v, ft);
		else if (ft != null) clearCheckerState(v);
	}
}

function rearmUnfitProperties(ctx: CheckerContext, lit: Node, bound: Type): void {
	const od = lit.data as ObjectLiteralData;
	for (let i = 0; i < od.properties.length && i < od.keys.length; i += 1) {
		const v = od.properties[i];
		if (v == null || v.nodeType == null || !takesContext(ctx, v)) continue;
		const ft = getProperty(bound, od.keys[i]);
		if (ft == null || isUnresolvedType(ft) || ft.kind == TypeKind.Error) continue;
		if (slotRefuses(v.nodeType, ft)) clearCheckerState(v);
	}
}

function bindingsCoverDecl(eb: UnifyBindings, declNode: Node): boolean {
	const names = extractGenericNames(getGenericDeclFlags(declNode));
	if (names.length == 0) return true;
	for (const gn of names) {
		if (findBindingIndex(eb, gn) == -1) return false;
	}
	return true;
}

function classReceiverBindings(sym: Symbol, callee: Node): UnifyBindings {
	const eb = createUnifyBindings();
	const methType = sym.symbolType;
	if (callee.kind != NodeKind.MemberExpr || methType == null || methType.kind != TypeKind.Function) return eb;
	if (methType.typeNames.length == 0 || methType.typeNames[0] != "this") return eb;
	const object = (callee.data as MemberExprData).object;
	if (object != null && object.nodeType != null && hasGenericParams(methType.typeChildren[0])) unifyType(methType.typeChildren[0], object.nodeType, eb);
	return eb;
}

function declTakesReceiver(declNode: Node): boolean {
	if (declNode.kind == NodeKind.FunctionDecl) return true;
	return declNode.kind == NodeKind.MethodDecl && !(declNode.data as MethodDeclData).methodIsStatic;
}

function getGenericDeclFlags(declNode: Node): string {
	let decl = declNode;
	while (decl != null && decl.kind == NodeKind.DecoratedDecl) {
		decl = (decl.data as DecoratedDeclData).decoratedNode;
	}
	if (decl == null) return "";
	if (decl.kind == NodeKind.FunctionDecl) return (decl.data as FunctionDeclData).fnFlags;
	if (decl.kind == NodeKind.MethodDecl) return (decl.data as MethodDeclData).methodFlags;
	return "";
}

function isGenericRoutine(calleeType: Type | null, sym: Symbol | null): boolean {
	if (hasGenericParams(calleeType)) return true;
	return sym != null && sym.declNode != null && isGenericFn(getGenericDeclFlags(sym.declNode));
}

function isGenericInstanceMethod(sym: Symbol): boolean {
	const decl = sym.declNode;
	if (decl == null || decl.kind != NodeKind.MethodDecl) return false;
	const md = decl.data as MethodDeclData;
	return !md.methodIsStatic && isGenericFn(md.methodFlags);
}

function collectArgCandidates(bound: UnifyBindings, raw: UnifyBindings, argIdx: int32, arg: Node, candParams: Type[], candTypes: Type[], candFrom: int32[], candSkip: boolean[], candLiteral: boolean[], candMapped: boolean[] = []): void {
	const literalTypes: Type[] = [];
	if (arg != null && arg.kind == NodeKind.ObjectLiteral) collectLiteralTypes(arg, literalTypes);
	for (let bi = 0; bi < raw.params.length; bi += 1) {
		const t = raw.types[bi];
		if (hasGenericParams(t) || boundSlot(bound, raw.params[bi]) != -1) continue;
		candParams.push(raw.params[bi]);
		candTypes.push(t);
		candFrom.push(argIdx);
		candSkip.push(bindingConflictSkipArg(arg) || isUnresolvedType(t));
		candLiteral.push(literalTypes.indexOf(t) >= 0);
		candMapped.push(raw.fromMapped.indexOf(raw.params[bi]) >= 0);
	}
}

// A type parameter read only through `Readonly<T>` (or another homomorphic mapped type) has
// nothing to infer from a primitive argument; the call names the type argument to write.
function refusePrimitiveThroughMapped(ctx: CheckerContext, cd: CallExprData, calleeType: Type, argTypes: Type[], limit: int32, eb: UnifyBindings, typeParamCount: int32): boolean {
	for (let i = 0; i < limit && i < calleeType.typeChildren.length; i += 1) {
		if (argTypes[i] == null) continue;
		const formal = calleeType.typeChildren[i];
		const param = primitiveThroughMapped(formal, argTypes[i]);
		if (param == null || boundSlot(eb, param) >= 0) continue;
		const given = typeDisplayName(literalBase(argTypes[i]));
		const through = mappedModifiers(formal).has(MappedModifier.IncludeReadonly) ? `Readonly<${param.typeName}>` : typeDisplayName(formal);
		const spelled = typeParamCount == 1 ? `${getCalleeName(cd.callee)}<${given}>(…)` : `${getCalleeName(cd.callee)}<…> with ${param.typeName} = ${given}`;
		addError(ctx, `cannot infer ${param.typeName} from a ${given} through ${through}; write ${spelled}`, cd.arguments[i].location.line, cd.arguments[i].location.column);
		return true;
	}
	return false;
}

function refusedThroughMapped(ctx: CheckerContext, cd: CallExprData, argIdx: int32, formal: Type, arg: Type): boolean {
	if (argIdx >= cd.arguments.length || cd.arguments[argIdx] == null || primitiveThroughMapped(formal, arg) == null) return false;
	const at = cd.arguments[argIdx].location;
	for (const e of ctx.errors) {
		if (e.line == at.line && e.column == at.column && e.message.startsWith("cannot infer ")) return true;
	}
	return false;
}

function collectLiteralTypes(n: Node, out: Type[]): void {
	if (n.kind == NodeKind.ObjectLiteral) {
		if (n.nodeType != null) out.push(n.nodeType);
		for (const v of (n.data as ObjectLiteralData).properties) { if (v != null) collectLiteralTypes(v, out); }
	} else if (n.kind == NodeKind.ArrayLiteral) {
		if (n.nodeType != null) out.push(n.nodeType);
		for (const e of (n.data as ArrayLiteralData).elements) { if (e != null) collectLiteralTypes(e, out); }
	}
}

function reportTypeParamMisfits(ctx: CheckerContext, fold: TypeParamFold, candParams: Type[], candTypes: Type[], candFrom: int32[], cd: CallExprData, conflicted: int32[]): void {
	for (const m of fold.misfits) {
		const argIdx = candFrom[m];
		let reported = false;
		for (const c of conflicted) { if (c == argIdx) { reported = true; break; } }
		if (reported) continue;
		const k = fold.params.indexOf(candParams[m]);
		const arg = cd.arguments[argIdx];
		addError(ctx, "Argument type mismatch in '" + getCalleeName(cd.callee) + "' arg " + String(argIdx)
			+ ": got " + typeDisplayName(candTypes[m]) + ", expected " + typeDisplayName(fold.types[k])
			+ " — '" + candParams[m].typeName + "' was bound by argument " + String(candFrom[fold.chosen[k]]),
			arg.location.line, arg.location.column);
		conflicted.push(argIdx);
	}
}

function bindingConflictSkipArg(arg: Node): boolean {
	if (arg == null) return true;
	if (arg.kind == NodeKind.ArrowFunction || arg.kind == NodeKind.FunctionExpr) return true;
	const t = arg.nodeType;
	if (t == null) return true;
	return t.kind == TypeKind.Error || isUnresolvedType(t) || isUnknownType(t);
}

function literalParamsAwaitFormal(arg: Node): boolean {
	if (arg == null) return false;
	let params: string[] = [];
	let paramTypes: string[] = [];
	if (arg.kind == NodeKind.ArrowFunction) {
		const ad = arg.data as ArrowFunctionData;
		params = ad.arrowParams;
		paramTypes = ad.arrowParamTypes;
	} else if (arg.kind == NodeKind.FunctionExpr) {
		const fd = arg.data as FunctionExprData;
		params = fd.funcExprParams;
		paramTypes = fd.funcExprParamTypes;
	} else {
		return false;
	}
	if (paramTypes.length < params.length) return true;
	for (const pt of paramTypes) {
		if (pt == "") return true;
	}
	return false;
}

function literalShortOfSlot(arg: Node, slot: Type): boolean {
	const fn = functionSlotOf(slot);
	if (fn == null) return false;
	if (arg.kind == NodeKind.ArrowFunction) return (arg.data as ArrowFunctionData).arrowParams.length < fn.typeChildren.length;
	if (arg.kind == NodeKind.FunctionExpr) return (arg.data as FunctionExprData).funcExprParams.length < fn.typeChildren.length;
	return false;
}

function bindFromLiteralAnnotations(ctx: CheckerContext, lit: Node, formal: Type | null): UnifyBindings {
	const out = createUnifyBindings();
	const fn = functionSlotOf(formal);
	if (fn == null) return out;
	const arrow = lit.kind == NodeKind.ArrowFunction;
	const paramTypes = arrow ? (lit.data as ArrowFunctionData).arrowParamTypes : (lit.data as FunctionExprData).funcExprParamTypes;
	const returnType = arrow ? (lit.data as ArrowFunctionData).arrowReturnType : (lit.data as FunctionExprData).funcExprReturnType;
	for (let i = 0; i < paramTypes.length && i < fn.typeChildren.length; i += 1) {
		if (paramTypes[i] == "" || !hasGenericParams(fn.typeChildren[i])) continue;
		unifyType(fn.typeChildren[i], resolveAnnotation(paramTypes[i], ctx, lit.location.line, lit.location.column), out);
	}
	if (returnType != "" && hasGenericParams(fn.typeReturn)) {
		unifyType(fn.typeReturn, resolveAnnotation(returnType, ctx, lit.location.line, lit.location.column), out);
	}
	return out;
}

function refuseUnboundLiteralParam(ctx: CheckerContext, lit: Node, slot: Type | null): void {
	const fn = functionSlotOf(slot);
	if (fn == null || ctx.inGenericContext != 0) return;
	const arrow = lit.kind == NodeKind.ArrowFunction;
	const params = arrow ? (lit.data as ArrowFunctionData).arrowParams : (lit.data as FunctionExprData).funcExprParams;
	const paramTypes = arrow ? (lit.data as ArrowFunctionData).arrowParamTypes : (lit.data as FunctionExprData).funcExprParamTypes;
	for (let i = 0; i < params.length && i < fn.typeChildren.length; i += 1) {
		if (i < paramTypes.length && paramTypes[i] != "") continue;
		if (!hasGenericParams(fn.typeChildren[i])) continue;
		const at = lit.paramLocations != null && i < lit.paramLocations.length && lit.paramLocations[i] != null ? lit.paramLocations[i] : lit.location;
		addError(ctx, "cannot instantiate: '" + findFirstGenericParamName(fn.typeChildren[i]) + "' — no argument binds it before parameter '" + params[i]
			+ "' is typed: annotate the parameter or pass an explicit type argument", at.line, at.column);
		return;
	}
}

function inDeclaredOrder(eb: UnifyBindings, receiverBindings: UnifyBindings | null, own: Type[]): UnifyBindings {
	const out = createUnifyBindings();
	if (receiverBindings != null) {
		for (let ri = 0; ri < receiverBindings.params.length; ri += 1) takeBinding(out, eb, receiverBindings.params[ri]);
	}
	for (const gp of own) takeBinding(out, eb, gp);
	for (let bi = 0; bi < eb.params.length; bi += 1) takeBinding(out, eb, eb.params[bi]);
	return out;
}

function takeBinding(out: UnifyBindings, eb: UnifyBindings, param: Type): void {
	const bi = boundSlot(eb, param);
	if (bi >= 0 && boundSlot(out, eb.params[bi]) < 0) bindAt(out, eb, bi);
}

function ownTypeParams(sym: Symbol, genericNames: string[]): Type[] {
	return sym.typeParams.length == genericNames.length ? sym.typeParams : [];
}

function tryInstantiateGenericCallee(ctx: CheckerContext, node: Node, calleeType: Type, argTypes: Type[], flags: string, expectedType: Type | null = null as unknown as Type, receiverBindings: UnifyBindings | null = null as unknown as UnifyBindings): Type {
	if (!isGenericFn(flags)) return null as unknown as Type;
	const sym = node.resolvedSym;
	if (sym == null || sym.builtinKind != "" || sym.declNode == null) {
		return null as unknown as Type;
	}
	const cd = node.data as CallExprData;

	const genericNames = extractGenericNames(flags);
	checkExplicitTypeArgArity(ctx, node, genericNames, getCalleeName(cd.callee));
	const eb = createUnifyBindings();
	const ebFrom: int32[] = [];
	const conflicted: int32[] = [];
	const own = ownTypeParams(sym, genericNames);
	mergeUnifyBindings(eb, bindFromExplicitTypeArgs(node, own, ctx));
	if (receiverBindings != null) mergeUnifyBindings(eb, receiverBindings);
	while (ebFrom.length < eb.names.length) ebFrom.push(-1);
	// Pass 1: unify args against params to derive bindings.
	const restIdx = calleeType.typeChildren.length - 1;
	const declRest = restIdx >= 0 ? calleeType.typeChildren[restIdx] : null;
	const deferredRest = declRest != null && declRest.kind == TypeKind.Varargs && restAwaitsInstance(declRest);
	const tupleRest = restTupleOf(calleeType) != null;
	const limit = tupleRest ? argTypes.length
		: argTypes.length < calleeType.typeChildren.length ? argTypes.length : calleeType.typeChildren.length;
	const candParams: Type[] = [];
	const candTypes: Type[] = [];
	const candFrom: int32[] = [];
	const candSkip: boolean[] = [];
	const candLiteral: boolean[] = [];
	const candMapped: boolean[] = [];
	for (let i = 0; i < limit; i += 1) {
		if (deferredRest && i == restIdx) {
			const ab = createUnifyBindings();
			unifyType(unwrapVarargs(declRest!), restArgsTuple(argTypes, restIdx), ab);
			collectArgCandidates(eb, ab, i, cd.arguments[i], candParams, candTypes, candFrom, candSkip, candLiteral, candMapped);
		} else if (tupleRest && i >= restIdx) {
			const element = formalAtPosition(calleeType, i);
			if (element == null || argTypes[i] == null) continue;
			const ab = createUnifyBindings();
			unifyType(element, argTypes[i], ab);
			collectArgCandidates(eb, ab, i, cd.arguments[i], candParams, candTypes, candFrom, candSkip, candLiteral, candMapped);
		} else if (argTypes[i] != null) {
			// Per-arg filter: a binding whose bound type still CONTAINS generic
			// params is unusable (instantiateGenericFunction refuses it) but under
			// first-wins merge it would shadow a clean binding from a later arg —
			// e.g. `createComponent(For, props)`: arg0 (the unapplied generic fn)
			// binds P to For's own T-containing param type, masking arg1's
			// concrete object literal.
			const ab = createUnifyBindings();
			unifyType(calleeType.typeChildren[i], argTypes[i], ab);
			collectArgCandidates(eb, ab, i, cd.arguments[i], candParams, candTypes, candFrom, candSkip, candLiteral, candMapped);
		}
	}
	const fold = foldTypeParamCandidates(candParams, candTypes, candSkip, createUnifyBindings(), candLiteral, candMapped);
	for (let k = 0; k < fold.params.length; k += 1) {
		bindParam(eb, fold.params[k], fold.types[k]);
		ebFrom.push(candFrom[fold.chosen[k]]);
	}
	if (refusePrimitiveThroughMapped(ctx, cd, calleeType, argTypes, limit, eb, genericNames.length)) return null as unknown as Type;
	reportTypeParamMisfits(ctx, fold, candParams, candTypes, candFrom, cd, conflicted);
	const fixedNames: string[] = [];
	for (let bi = 0; bi < eb.names.length; bi += 1) {
		if (ebFrom[bi] < 0) fixedNames.push(eb.names[bi]);
	}
	if (bindFromUnfitDestination(calleeType, eb, fixedNames, argTypes, expectedType)) {
		fitArgsToBoundFormals(ctx, node, calleeType, eb);
		for (let ai = 0; ai < argTypes.length && ai < calleeType.typeChildren.length; ai += 1) {
			if (hasGenericParams(calleeType.typeChildren[ai])) argTypes[ai] = applySubstitutions(calleeType.typeChildren[ai], eb);
		}
	}
	// Pass 2: contextual return-type binding (Nim parity — `inheritBindings` in
	// semcall.nim:777-859). When args + explicit <T> together don't bind all
	// generic params, walk return type vs expected type to derive bindings from
	// caller context. Mirrors local pattern in `inferGenericReturn`.
	// `mergeUnifyBindings` preserves earlier bindings so Pass 2
	// only fills gaps — no overwrite risk.
	//
	// Fixes Bug 3 V2: macro emit `_jsonToIntArray(jv, null)` with caller-side
	// `const colors: Color[] = ...` context. Args alone don't bind T (null is
	// weak), explicit <T> not present in macro emit. Pass 2 binds T=Color from
	// return Array<T> vs expected Array<Color>.
	if (argumentsMatchFormals(calleeType, argTypes, eb)) mergeUnifyBindings(eb, bindFromExpectedReturn(calleeType, expectedType));
	if (eb.names.length == 0) return null as unknown as Type;
	if (reportUnmetConstraints(ctx, node, eb, ebFrom, receiverBindings)) return null as unknown as Type;

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
		if (argN == null || argN.resolvedSym == null) continue;
		const argSym = argN.resolvedSym;
		if (argSym.declNode == null || argSym.declNode.kind != NodeKind.FunctionDecl) continue;
		const afd = argSym.declNode.data as FunctionDeclData;
		if (!isGenericFn(afd.fnFlags)) continue;
		if (argSym.symbolType == null) continue;
		const substFormal = applySubstitutions(calleeType.typeChildren[ai], eb);
		if (substFormal == null || substFormal.kind != TypeKind.Function || hasGenericParams(substFormal)) continue;
		const gbRaw = createUnifyBindings();
		const gLimit = argSym.symbolType.typeChildren.length < substFormal.typeChildren.length ? argSym.symbolType.typeChildren.length : substFormal.typeChildren.length;
		for (let gi = 0; gi < gLimit; gi += 1) {
			unifyType(argSym.symbolType.typeChildren[gi], substFormal.typeChildren[gi], gbRaw);
		}
		unifyType(argSym.symbolType.typeReturn, substFormal.typeReturn, gbRaw);
		const gParams: Type[] = [];
		const gTypes: Type[] = [];
		const gFrom: int32[] = [];
		const gSkip: boolean[] = [];
		collectArgCandidates(createUnifyBindings(), gbRaw, ai, argN, gParams, gTypes, gFrom, gSkip, []);
		const gFold = foldTypeParamCandidates(gParams, gTypes, gSkip, createUnifyBindings());
		if (gFold.misfits.length > 0) { reportTypeParamMisfits(ctx, gFold, gParams, gTypes, gFrom, cd, conflicted); continue; }
		if (gFold.names.length == 0) continue;
		const argInst = callInstantiateGeneric(argSym, gFold.params, gFold.types, ctx, argN.location);
		if (argInst == null) continue;
		argN.resolvedSym = argInst;
		argN.nodeType = argInst.symbolType;
		if (argInst.symbolType == null) continue;
		const ib = createUnifyBindings();
		unifyType(calleeType.typeChildren[ai], argInst.symbolType, ib);
		for (let ii = 0; ii < ib.names.length; ii += 1) {
			if (hasGenericParams(ib.types[ii])) continue;
			const ei = boundSlot(eb, ib.params[ii]);
			if (ei >= 0) eb.types[ei] = ib.types[ii]; else bindAt(eb, ib, ii);
		}
	}
	const deferredTuple = deferredRest ? tupleOfRest(applySubstitutions(declRest!, eb)) : null;
	const formalLimit = deferredTuple == null ? reconcileLimit
		: cd.arguments.length < restIdx + deferredTuple.typeChildren.length ? cd.arguments.length : restIdx + deferredTuple.typeChildren.length;
	for (let pi = 0; pi < formalLimit; pi += 1) {
		const arg = cd.arguments[pi];
		if (arg == null) continue;
		const rawFormal = deferredTuple != null && pi >= restIdx ? deferredTuple.typeChildren[pi - restIdx] : calleeType.typeChildren[pi];
		const substituted = applySubstitutions(rawFormal, eb);
		if (substituted == null) continue;
		if (arg.nodeType != null && !hasGenericParams(substituted)) {
			const thunkArg = synthClosureThunk(arg, substituted, arg.nodeType, ctx);
			if (thunkArg != null as unknown as Node) {
				cd.arguments[pi] = thunkArg;
				if (pi < argTypes.length) argTypes[pi] = substituted;
				continue;
			}
		}
		// An object-literal arg that self-typed under the generic-adoption gate
		// (checkExpr ObjectLiteral: a generic-containing formal is never stamped)
		// now gets the instantiated formal: codegen must emit the same struct
		// identity the instance's parameter uses, not the literal's own anon name.
		const carried = isMaybeType(substituted) && substituted.typeReturn != null ? substituted.typeReturn : substituted;
		const substitutedRef = carried.kind == TypeKind.Ref && carried.typeReturn != null ? carried.typeReturn : carried;
		const substitutedObject = substitutedRef.kind == TypeKind.GenericInstance ? peelToStructOrUnion(substitutedRef) : substitutedRef;
		if (arg.kind == NodeKind.ObjectLiteral && substitutedObject != null && substitutedObject.kind == TypeKind.Struct
				&& !hasGenericParams(substituted)) {
			let skipConstruct = false;
			for (const c of conflicted) { if (c == pi) skipConstruct = true; }
			if (!skipConstruct) {
				rearmUnfitProperties(ctx, arg, substitutedObject);
				rearmLiteralForRecheck(arg, rawFormal);
				callCheckExpr(ctx, arg, carried);
			}
			if (arg.nodeType == null) arg.nodeType = carried;
			if (carried != substituted && !isMaybeType(arg.nodeType)) {
				cd.arguments[pi] = synthMaybeWrap(arg, substituted, arg.nodeType, ctx);
				if (pi < argTypes.length) argTypes[pi] = substituted;
				continue;
			}
			if (pi < argTypes.length) argTypes[pi] = arg.nodeType;
			continue;
		}
		if (!hasGenericParams(substituted)) {
			const intoUnknown = convertIntoUnknown(arg, arg.nodeType, substituted);
			if (intoUnknown != arg) {
				cd.arguments[pi] = intoUnknown;
				if (pi < argTypes.length) argTypes[pi] = intoUnknown.nodeType!;
				continue;
			}
		}
		const substitutedValue = skipModifier(substituted);
		if (substitutedValue != null && instantiatedUnionBehind(substitutedValue).kind == TypeKind.Union && arg.nodeType != null) {
			const uw = widenVariantToUnion(arg, substitutedValue, arg.nodeType, ctx);
			if (uw != null as unknown as Node) {
				cd.arguments[pi] = uw;
				if (pi < argTypes.length) argTypes[pi] = substitutedValue;
			}
			continue;
		}
		const maybeSubstituted = peelSink(substituted);
		if (!isMaybeType(maybeSubstituted) || maybeSubstituted.typeReturn == null) {
			const convType = substituted.kind == TypeKind.Sink && substituted.typeReturn != null ? substituted.typeReturn : substituted;
			if (arg.nodeType != null && convType.kind != TypeKind.Var && !hasGenericParams(convType) && needsStdConv(arg.nodeType, convType)) {
				cd.arguments[pi] = wrapInConv(arg, convType);
			}
			continue;
		}
		if (arg.kind == NodeKind.NullLiteral) {
			cd.arguments[pi] = synthMaybeWrap(arg, maybeSubstituted, arg.nodeType!, ctx);
			if (pi < argTypes.length) argTypes[pi] = maybeSubstituted;
		} else if (arg.nodeType != null && !isMaybeType(arg.nodeType)
				&& (isAssignable(arg.nodeType, maybeSubstituted.typeReturn) || arityAdapts(arg.nodeType, maybeSubstituted.typeReturn))) {
			cd.arguments[pi] = synthMaybeWrap(arg, maybeSubstituted, arg.nodeType, ctx);
			if (pi < argTypes.length) argTypes[pi] = maybeSubstituted;
		}
	}

	const lastFormalIdx = calleeType.typeChildren.length - 1;
	const lastFormal = lastFormalIdx >= 0 ? calleeType.typeChildren[lastFormalIdx] : null;
	const restFormal = lastFormal != null && lastFormal.kind == TypeKind.Varargs ? lastFormal : null;
	for (let ai = 0; ai < cd.arguments.length; ai += 1) {
		const argT = ai < argTypes.length ? argTypes[ai] : null;
		if (argT == null || isUnresolvedType(argT) || argT.kind == TypeKind.Error || isUnknownType(argT)) continue;
		let reported = false;
		for (const c of conflicted) { if (c == ai) reported = true; }
		if (reported) continue;
		let rawFormal: Type = null as unknown as Type;
		if (restFormal != null && ai >= lastFormalIdx) {
			rawFormal = restFormal;
		} else if (ai < calleeType.typeChildren.length) {
			rawFormal = calleeType.typeChildren[ai];
		}
		if (rawFormal == null || !hasGenericParams(rawFormal)) continue;
		let formalT: Type = applySubstitutions(rawFormal, eb);
		const restTuple = formalT != null && formalT.kind == TypeKind.Varargs ? peelTransparentInstance(unwrapVarargs(formalT)) : null;
		if (restTuple != null && restTuple.kind == TypeKind.Tuple) {
			if (ai - lastFormalIdx >= restTuple.typeChildren.length) continue;
			formalT = restTuple.typeChildren[ai - lastFormalIdx];
		} else if (formalT != null && restWithoutElements(formalT)) {
			continue;
		} else if (formalT != null && formalT.kind == TypeKind.Varargs) {
			const restArr = unwrapRef(unwrapVarargs(formalT));
			const restElem = restArr != null ? getElementType(restArr) : null;
			if (restElem == null || restElem.kind == TypeKind.Inferred) continue;
			formalT = restElem;
		}
		if (formalT == null || hasGenericParams(formalT) || isUnresolvedType(formalT)) continue;
		let checkedT: Type = argT;
		if ((!isAssignable(checkedT, formalT) && literalParamsAwaitFormal(cd.arguments[ai])) || literalShortOfSlot(cd.arguments[ai], formalT)) {
			clearCheckerState(cd.arguments[ai]);
			callCheckExpr(ctx, cd.arguments[ai], formalT);
			const retyped = cd.arguments[ai].nodeType;
			if (retyped != null) { checkedT = retyped; argTypes[ai] = retyped; }
		}
		if (isAssignable(checkedT, formalT)) continue;
		addError(ctx, "Argument type mismatch in '" + getCalleeName(cd.callee) + "' arg " + String(ai)
			+ ": got " + typeDisplayName(checkedT) + ", expected " + typeDisplayName(formalT) + returnReprRefusal(checkedT, formalT, wrappedFnText(cd.arguments[ai])) + explainStructuralPrefix(checkedT, formalT) + refDerefHint(cd.arguments[ai], checkedT, formalT),
			cd.arguments[ai].location.line, cd.arguments[ai].location.column);
	}

	const declared = inDeclaredOrder(eb, receiverBindings, own);
	const instSym = callInstantiateGeneric(sym, declared.params, declared.types, ctx, node.location);
	if (instSym == null) return null as unknown as Type;

	node.resolvedSym = instSym;
	cd.callee.resolvedSym = instSym;
	cd.callee.nodeType = instSym.symbolType;
	const instCallee = deferredRest && instSym.symbolType != null
		? (receiverBindings != null ? stripReceiverParam(instSym.symbolType) : instSym.symbolType) : null;
	const instRest = instCallee != null ? restTupleOf(instCallee) : null;
	if (instRest != null) fitRestTupleArgs(ctx, node, instCallee!, instRest, callMinArity(instCallee!), argTypes.length);
	return instSym.symbolType;
}

function reportUnmetConstraints(ctx: CheckerContext, node: Node, eb: UnifyBindings, ebFrom: int32[], receiverBindings: UnifyBindings | null): boolean {
	const cd = node.data as CallExprData;
	let unmetAny = false;
	for (let i = 0; i < eb.names.length; i += 1) {
		if (receiverBindings != null && boundSlot(receiverBindings, eb.params[i]) >= 0) continue;
		const from = i < ebFrom.length ? ebFrom[i] : -1;
		const at = from >= 0 && from < cd.arguments.length ? cd.arguments[from].location : node.location;
		if (reportUnmetConstraint(ctx, i, eb, getCalleeName(cd.callee), at)) unmetAny = true;
	}
	return unmetAny;
}

function reportUnmetConstraint(ctx: CheckerContext, i: int32, eb: UnifyBindings, calleeName: string, at: SourceLocation): boolean {
	const unmet = unmetConstraint(eb.params[i], eb.types[i], eb.params, eb.types);
	if (unmet == null) return false;
	addError(ctx, `Type '${typeDisplayName(eb.types[i])}' does not satisfy constraint '${typeDisplayName(unmet)}' for type parameter '${eb.names[i]}' in '${calleeName}'`,
		at.line, at.column);
	return true;
}

// Tier 1: locate the implementation symbol in an overload set.
// The implementation is the unique member without the OverloadSig flag.
// Returns null if no implementation exists (all candidates are sigs).
function signatureTarget(ctx: CheckerContext, winner: Symbol, callNode: Node, named: ExtensionMethod[]): Symbol {
	if (!hasFlag(winner, SymbolFlag.OverloadSig) || hasFlag(winner, SymbolFlag.ImportC)) return winner;
	let set: Symbol | null = winner.overloads.length > 0 ? winner : null;
	for (const e of named) {
		if (set == null && e.sym != null && e.sym.overloads.indexOf(winner) >= 0) set = e.sym;
	}
	const impl = set != null ? findOverloadImpl(set) : null;
	if (set == null || impl == null) {
		addError(ctx, `Overloaded function '${winner.name}' has no implementation — at least one definition must have a body`,
			callNode.location.line, callNode.location.column);
		return winner;
	}
	return validateOverloadSigs(ctx, set, impl, callNode) ? impl : winner;
}

function fitCallToImplementation(callNode: Node, impl: Symbol, takesReceiver: boolean): void {
	const implParams = impl.symbolType != null ? impl.symbolType.typeChildren : [];
	const d = callNode.data as CallExprData;
	const offset = takesReceiver ? 1 : 0;
	if (takesReceiver && implParams.length > 0 && d.callee.kind == NodeKind.MemberExpr) {
		const me = d.callee.data as MemberExprData;
		if (me.object.nodeType != null) {
			const fitted = widenVariantToUnion(me.object, implParams[0], me.object.nodeType);
			if (fitted != null as unknown as Node) me.object = fitted;
		}
	}
	for (let ai = 0; ai < d.arguments.length && ai + offset < implParams.length; ai += 1) {
		const argType = d.arguments[ai].nodeType;
		if (argType == null || hasGenericParams(implParams[ai + offset])) continue;
		const fitted = widenVariantToUnion(d.arguments[ai], implParams[ai + offset], argType);
		if (fitted != null as unknown as Node) d.arguments[ai] = fitted;
	}
}

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
	if (implFnType == null || implFnType.kind != TypeKind.Function) return true;
	const implRet = implFnType.typeReturn;
	const implParams = implFnType.typeChildren;
	const allSyms: Symbol[] = [sym];
	for (const o of sym.overloads) allSyms.push(o);
	for (const s of allSyms) {
		if (s == impl) continue;
		if (!hasFlag(s, SymbolFlag.OverloadSig)) continue;
		const sigType = s.symbolType;
		if (sigType == null || sigType.kind != TypeKind.Function) continue;
		if (sigType.typeChildren.length != implParams.length) {
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
		if (sRet != null && implRet != null && !isAssignable(sRet, implRet)) {
			addError(ctx, `Overload signature for '${sym.name}' has return type '${typeDisplayName(sRet)}' incompatible with implementation return type '${typeDisplayName(implRet)}'`,
				callNode.location.line, callNode.location.column);
			return false;
		}
		const viewParam = sRet != null && implRet != null && dropsReadonlyView(implRet, sRet) ? firstViewParam(sigType.typeChildren) : -1;
		if (viewParam >= 0) {
			addError(ctx, `Overload signature for '${sym.name}' returns the mutable '${typeDisplayName(sRet)}' while its param ${viewParam + 1} is the read-only '${typeDisplayName(sigType.typeChildren[viewParam])}': the implementation returns '${typeDisplayName(implRet)}', which may be that view (PARALOCK E24)`,
				callNode.location.line, callNode.location.column);
			return false;
		}
	}
	return true;
}

function firstViewParam(params: Type[]): int32 {
	for (let pi = 0; pi < params.length; pi += 1) {
		const p = params[pi];
		if (isReadonlyView(p) || isReadonlyView(nonNullMemberOfNullable(p))) return pi;
	}
	return -1;
}

// Check one argument with a specific expected type, then extract its nodeType
// (with EnumLiteral narrowing for direct enum-member accesses).
function checkArgWithExpected(ctx: CheckerContext, arg: Node, expected: Type | null): Type {
	callCheckExpr(ctx, arg, expected);
	let argType = arg.nodeType;
	if (argType != null && expected != null && hasGenericParams(expected)) argType = storedTypeOfNullRead(arg, argType, argType);
	if (argType != null && argType.kind == TypeKind.Enum
			&& arg.resolvedSym != null
			&& arg.resolvedSym.symbolKind == SymbolKind.EnumMember
			&& arg.resolvedSym.symbolType != null
			&& arg.resolvedSym.symbolType.kind == TypeKind.EnumLiteral) {
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
		if (candType != null && candType.kind == TypeKind.Function
				&& candType.typeChildren != null
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
function intLiteralArg(arg: Node): Node | null {
	if (isNodeIntLit(arg)) return arg;
	if (arg.kind == NodeKind.UnaryExpr) {
		const u = arg.data as UnaryExprData;
		if (u.unaryOp == "-" && isNodeIntLit(u.operand)) return u.operand;
	}
	return null;
}

function literalRelations(paramTypes: Type[], args: Node[], argTypes: Type[]): int32[] {
	const rels: int32[] = [];
	for (let i = 0; i < args.length; i += 1) {
		rels.push(literalRelation(args[i], argTypes[i], i < paramTypes.length ? paramTypes[i] : null));
	}
	return rels;
}

function literalRelation(arg: Node, argType: Type | null, slot: Type | null): int32 {
	const formal = skipModifier(slot);
	if (formal == null) return -1;
	if (arg.kind == NodeKind.ArrayLiteral) return isLiteralTree(arg) ? elementsRelation((arg.data as ArrayLiteralData).elements, formal) : -1;
	if (arg.kind == NodeKind.StringLiteral) return stringLiteralRelation((arg.data as StringLiteralData).value, formal);
	const lit = intLiteralArg(arg);
	const floatFormal = formal.kind == TypeKind.Float32 || formal.kind == TypeKind.Float64 || formal.kind == TypeKind.Number;
	if (lit == null || (!isIntegerType(formal) && !floatFormal) || (argType != null && argType.kind == formal.kind)) return -1;
	if (floatFormal) return (intLiteralExactInFloat(lit, formal) ? TypeRelation.Convertible : TypeRelation.None) as int32;
	return (literalFitsInType(lit, formal, lit != arg) ? TypeRelation.FromLiteral : TypeRelation.None) as int32;
}

function stringLiteralRelation(value: string, formal: Type): int32 {
	if (typeRelation(formal, stringType()) != TypeRelation.None) return -1;
	if (typeRelation(formal, createStringLiteral(value)) == TypeRelation.None) return TypeRelation.None as int32;
	return (holdsOnlyStrings(formal) ? TypeRelation.Exact : TypeRelation.FromLiteral) as int32;
}

function holdsOnlyStrings(formal: Type): boolean {
	const base = literalUnionBase(formal);
	return formal.kind == TypeKind.StringLiteral || (base != null && base.kind == TypeKind.String);
}

function elementsRelation(elements: Node[], formal: Type): int32 {
	const arr = withoutArrayEnvelope(peelTransparentInstance(formal));
	const elemFormal = arr.kind == TypeKind.Array || arr.kind == TypeKind.SizedArray || arr.kind == TypeKind.Span ? arr.typeReturn : null;
	if (elements.length == 0 || elemFormal == null) return -1;
	let weakest = TypeRelation.Exact;
	for (const e of elements) {
		const lit = literalRelation(e, e.nodeType, elemFormal);
		const rel = lit >= 0 ? lit as TypeRelation : typeRelation(elemFormal, e.nodeType);
		if (rel < weakest) weakest = rel;
	}
	return weakest as int32;
}

function retypeLiteralArg(ctx: CheckerContext, arg: Node, literal: boolean, formal: Type | null): boolean {
	if (!literal || formal == null || formal.kind == TypeKind.Varargs || hasGenericParams(formal)) return false;
	clearCheckerState(arg);
	callCheckExpr(ctx, arg, formal);
	return true;
}

function noMatchScore(): CandidateScore {
	const score = emptyCandidateScore();
	score.exactMatches = -1;
	return score;
}

const ANNOTATE_CONTEXT_ARG = "a callback or object literal argument fits more than one overload; annotate its parameter types";

interface ContextPick {
	index: int32;
	tie: boolean;
}

// The reference's `chooseOverload`: a context-sensitive argument is checked against each
// candidate's own parameter, and every candidate it fits is ranked with the type it took
// there, so the most specific fitting overload wins and a tie is an error.
function rankContextFits(ctx: CheckerContext, callNode: Node, candSyms: Symbol[], candidates: Type[], scores: CandidateScore[],
	args: Node[], argTypes: Type[], skipMask: boolean[], expectedType: Type | null, signatures: boolean): ContextPick {
	let best: int32 = -1;
	let bestScore = noMatchScore();
	let tie = false;
	const scored = allScored(skipMask);
	const fitScores: CandidateScore[] = [];
	for (let ci = 0; ci < candidates.length && ci < scores.length; ci += 1) {
		if (isNoMatch(scores[ci])) continue;
		const c = candidates[ci];
		const formals = winnerFormals(ctx, callNode, candSyms[ci], c, args, argTypes, skipMask, expectedType);
		if (!contextArgsFit(ctx, args, skipMask, formals.checked)) continue;
		const typed = typedContextArgs(args, argTypes, skipMask);
		const score = scoreCandidateWithSkip(c.typeChildren, typed, getMinArity(c), scored, literalRelations(c.typeChildren, args, typed));
		while (fitScores.length < ci) fitScores.push(noMatchScore());
		fitScores.push(score);
		if (isNoMatch(score)) continue;
		const cmp = best < 0 ? 1 : cmpCandidates(score, bestScore, c, candidates[best]);
		if (cmp > 0) {
			best = ci;
			bestScore = score;
			tie = false;
		} else if (cmp == 0 && !adapterTie(c, candidates[best], typed, scored)) {
			tie = true;
		}
	}
	if (signatures) {
		const first = firstApplicable(fitScores, candSyms);
		if (first >= 0) return { index: first, tie: false };
	}
	return { index: best, tie };
}

function isSignatureSet(sym: Symbol): boolean {
	if (hasFlag(sym, SymbolFlag.OverloadSig)) return true;
	for (const o of sym.overloads) {
		if (hasFlag(o, SymbolFlag.OverloadSig)) return true;
	}
	return false;
}

// TS overload signatures: the reference's `chooseOverload` takes the first signature the
// arguments fit, first by subtype (no numeric or implicit conversion), then by
// assignability; `reorderCandidates` moves a signature with a parameter written as a
// literal type ahead of the rest, each group keeping declaration order.
function firstApplicable(scores: CandidateScore[], syms: Symbol[]): int32 {
	const order = literalSignaturesFirst(syms, scores.length);
	for (const ci of order) {
		if (!isNoMatch(scores[ci]) && fitsWithoutConversion(scores[ci])) return ci;
	}
	for (const ci of order) {
		if (!isNoMatch(scores[ci])) return ci;
	}
	return -1;
}

function literalSignaturesFirst(syms: Symbol[], count: int32): int32[] {
	const order: int32[] = [];
	for (let ci = 0; ci < count; ci += 1) {
		if (ci < syms.length && writesLiteralParam(syms[ci])) order.push(ci);
	}
	for (let ci = 0; ci < count; ci += 1) {
		if (!(ci < syms.length && writesLiteralParam(syms[ci]))) order.push(ci);
	}
	return order;
}

// The reference reads the written annotation, so `x: "a"` counts and an alias of a
// literal type does not.
function writesLiteralParam(sym: Symbol): boolean {
	if (sym.declNode == null || sym.declNode.kind != NodeKind.FunctionDecl) return false;
	for (const text of (sym.declNode.data as FunctionDeclData).fnParamTypes) {
		if (isLiteralTypeText(text.trim())) return true;
	}
	return false;
}

function isLiteralTypeText(t: string): boolean {
	if (t.length == 0 || splitTopLevel(t, "|").length > 1 || splitTopLevel(t, "&").length > 1) return false;
	if (t == "true" || t == "false" || t == "null") return true;
	const first = t.charAt(0);
	if (first == "\"" || first == "'" || first == "`") return t.length >= 2 && t.charAt(t.length - 1) == first && !t.includes("${");
	const digits = first == "-" ? t.slice(1, t.length).trim() : t;
	if (digits.length == 0 || digits.byteAt(0) < "0".code || digits.byteAt(0) > "9".code) return false;
	for (let i = 0; i < digits.length; i += 1) {
		const ch = digits.charAt(i);
		if (!(ch >= "0" && ch <= "9") && !"._xXoObBeEnN+-abcdefABCDEF".includes(ch)) return false;
	}
	return true;
}

function fitsWithoutConversion(score: CandidateScore): boolean {
	return score.intConvMatches % 256 == 0 && score.signWideningMatches == 0 && score.convMatches == 0;
}

interface WinnerFormals {
	checked: Type;
	explicit: Type;
}

function winnerFormals(ctx: CheckerContext, callNode: Node, winnerSym: Symbol, winnerType: Type, args: Node[], argTypes: Type[], skipMask: boolean[], expectedType: Type | null): WinnerFormals {
	if (winnerType.kind != TypeKind.Function || !hasGenericParams(winnerType)) return { checked: winnerType, explicit: winnerType };
	let explicit = winnerType;
	const bindings = deriveCallBindings(ctx, callNode, winnerSym, winnerType, null);
	if (bindings.names.length > 0) explicit = substituteBound(winnerType, bindings);
	const perArg: UnifyBindings[] = [];
	const candParams: Type[] = [];
	const candTypes: Type[] = [];
	const candFrom: int32[] = [];
	const candSkip: boolean[] = [];
	const candLiteral: boolean[] = [];
	const candMapped: boolean[] = [];
	for (const ai of genericArgOrder(ctx, args, true)) {
		if (skipMask[ai] || argTypes[ai] == null || ai >= winnerType.typeChildren.length) continue;
		const fwd = createUnifyBindings();
		unifyType(winnerType.typeChildren[ai], argTypes[ai], fwd);
		collectArgCandidates(bindings, fwd, ai, args[ai], candParams, candTypes, candFrom, candSkip, candLiteral, candMapped);
		perArg.push(fwd);
	}
	const fold = foldTypeParamCandidates(candParams, candTypes, candSkip, createUnifyBindings(), candLiteral, candMapped);
	for (let k = 0; k < fold.params.length; k += 1) bindParam(bindings, fold.params[k], fold.types[k]);
	for (const fwd of perArg) mergeUnifyBindings(bindings, fwd);
	mergeUnifyBindings(bindings, bindFromExpectedReturn(winnerType, expectedType));
	const checked = bindings.names.length > 0 ? substituteBound(winnerType, bindings) : winnerType;
	return { checked, explicit };
}

function contextArgsFit(ctx: CheckerContext, args: Node[], skipMask: boolean[], winnerType: Type): boolean {
	if (winnerType.kind != TypeKind.Function || winnerType.typeChildren == null) return true;
	for (let ai = 0; ai < args.length && ai < winnerType.typeChildren.length; ai += 1) {
		if (!skipMask[ai]) continue;
		const formal = winnerType.typeChildren[ai];
		const mark = ctx.errors.length;
		clearCheckerState(args[ai]);
		callCheckExpr(ctx, args[ai], formal);
		const argType = args[ai].nodeType;
		if (ctx.errors.length > mark || (argType != null && !fitsFormal(argType, formal))) {
			ctx.errors = ctx.errors.slice(0, mark);
			return false;
		}
	}
	return true;
}

function fitsFormal(argType: Type, formal: Type): boolean {
	if (!hasGenericParams(formal)) return isAssignable(argType, formal);
	const bindings = createUnifyBindings();
	unifyType(formal, argType, bindings);
	const bound = bindings.names.length > 0 ? substituteBound(formal, bindings) : formal;
	return isAssignable(argType, bound);
}

function signatureReturn(sigType: Type, argTypes: Type[]): Type | null {
	const ret = sigType.typeReturn;
	if (ret == null || !hasGenericParams(ret)) return ret;
	const bindings = createUnifyBindings();
	for (let ai = 0; ai < argTypes.length && ai < sigType.typeChildren.length; ai += 1) {
		if (argTypes[ai] != null) unifyType(sigType.typeChildren[ai], argTypes[ai], bindings);
	}
	const bound = bindings.names.length > 0 ? substituteBound(ret, bindings) : ret;
	return hasGenericParams(bound) ? null : bound;
}

function isHiddenImplementation(cand: Symbol, set: Symbol): boolean {
	if (hasFlag(cand, SymbolFlag.OverloadSig)) return false;
	if (hasFlag(set, SymbolFlag.OverloadSig)) return true;
	for (const o of set.overloads) {
		if (hasFlag(o, SymbolFlag.OverloadSig)) return true;
	}
	return false;
}

function takesAdaptedArg(cand: Type, argTypes: Type[], skipMask: boolean[]): boolean {
	for (let ai = 0; ai < argTypes.length && ai < cand.typeChildren.length; ai += 1) {
		if (!skipMask[ai] && arityAdapts(argTypes[ai], cand.typeChildren[ai])) return true;
	}
	return false;
}

function adapterTie(a: Type, b: Type, argTypes: Type[], skipMask: boolean[]): boolean {
	return takesAdaptedArg(a, argTypes, skipMask) || takesAdaptedArg(b, argTypes, skipMask);
}

function resolveOverloadCall(ctx: CheckerContext, primary: Symbol, callNode: Node, expectedType: Type | null = null as unknown as Type): Type {
	let sym = primary;
	let impl = findOverloadImpl(sym);
	if (impl == null) {
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
	const ownCount = candSyms.length;
	const gathered = shadowedImportOf(ctx, sym);
	if (gathered != null) {
		candSyms.push(gathered);
		for (const o of gathered.overloads) candSyms.push(o);
	}
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
	const literalArgs: boolean[] = [];
	for (const arg of args) {
		literalArgs.push(isLiteralTree(arg));
		if (isContextSensitive(arg)) {
			argTypes.push(null as unknown as Type);
			skipMask.push(true);
		} else {
			argTypes.push(checkArgWithExpected(ctx, arg, null as unknown as Type));
			skipMask.push(false);
		}
	}

	const spreadAt = trailingArraySpread(args);
	if (spreadAt < 0 && hasSpreadArg(args)) {
		refuseMisplacedSpread(ctx, args, [], 0);
		return getReturnType(sym.symbolType);
	}
	if (spreadAt >= 0) argTypes[spreadAt] = spreadElementType(args[spreadAt]);

	// Score each candidate using the shared priority machinery, detecting
	// ambiguity (two candidates with equal top scores).
	let bestIdx: int32 = -1;
	let bestScore: CandidateScore = null as unknown as CandidateScore;
	let ambiguous = false;
	let scores: CandidateScore[] = [];
	let implAsFallback = false;
	let ci: int32 = 0;
	while (ci < candidates.length) {
		const candType = candidates[ci];
		const score = candType == null || candType.kind != TypeKind.Function || (!implAsFallback && isHiddenImplementation(candSyms[ci], ci < ownCount ? sym : gathered!))
			? noMatchScore()
			: spreadAt >= 0 && !spreadFitsCandidate(candType, spreadAt, argTypes[spreadAt], getMinArity(candType)) ? noMatchScore()
			: scoreCandidateWithSkip(candType.typeChildren, argTypes, getMinArity(candType), skipMask, literalRelations(candType.typeChildren, args, argTypes));
		scores.push(score);
		const cmp = score.exactMatches < 0 ? -1 : bestIdx < 0 ? 1 : cmpCandidates(score, bestScore, candType, candidates[bestIdx]);
		if (cmp > 0) {
			bestIdx = ci;
			bestScore = score;
			ambiguous = false;
		} else if (cmp == 0 && !adapterTie(candType, candidates[bestIdx], argTypes, skipMask)) {
			ambiguous = true;
		}
		ci = ci + 1;
		if (ci == candidates.length && bestIdx < 0 && !implAsFallback) {
			implAsFallback = true;
			scores = [];
			ci = 0;
		}
	}

	const signatures = !implAsFallback && isSignatureSet(sym);
	if (signatures && !skipMask.includes(true)) {
		const first = firstApplicable(scores, candSyms);
		if (first >= 0) {
			bestIdx = first;
			ambiguous = false;
		}
	}
	if (ambiguous) {
		// A context-sensitive argument is typed against each overload below and
		// decides the tie there.
		if (!skipMask.includes(true)) {
			let hasJsxArg = false;
			for (const a of args) {
				if (a.kind == NodeKind.JSXElement || a.kind == NodeKind.JSXFragment) { hasJsxArg = true; break; }
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
			if (candType == null || candType.kind != TypeKind.Function) continue;
			msg = `${msg}\n    ${formatCandidateSig(sym.name, candType)}`;
			const mpos = findFirstMismatch(candType.typeChildren, argTypes, getMinArity(candType));
			if (mpos >= 0 && mpos < argTypes.length && mpos < candType.typeChildren.length) {
				const gotName = argTypes[mpos] != null ? typeDisplayName(argTypes[mpos]) : "<skipped>";
				const why = argTypes[mpos] != null && numericConvRefuses(argTypes[mpos], candType.typeChildren[mpos])
					? " — " + numericRefusalReason(argTypes[mpos], candType.typeChildren[mpos]) + "; write an explicit 'as " + typeDisplayName(candType.typeChildren[mpos]) + "'"
					: "";
				msg = `${msg}\n      first mismatch at position ${mpos + 1}: expected '${typeDisplayName(candType.typeChildren[mpos])}', got '${gotName}'${why}`;
			} else if (candType.typeChildren.length != argTypes.length) {
				msg = `${msg}\n      expected ${candType.typeChildren.length} argument(s), got ${argTypes.length}`;
			}
		}
		addError(ctx, msg, callNode.location.line, callNode.location.column);
		return getReturnType(sym.symbolType);
	}

	let formals = winnerFormals(ctx, callNode, candSyms[bestIdx], candidates[bestIdx], args, argTypes, skipMask, expectedType);
	let settled = false;
	if (skipMask.includes(true)) {
		const pick = rankContextFits(ctx, callNode, candSyms, candidates, scores, args, argTypes, skipMask, expectedType, signatures);
		if (pick.tie) {
			addError(ctx, `Ambiguous call to overloaded function '${sym.name}' — ${ANNOTATE_CONTEXT_ARG}`,
				callNode.location.line, callNode.location.column);
			return getReturnType(sym.symbolType);
		}
		if (pick.index >= 0) {
			bestIdx = pick.index;
			formals = winnerFormals(ctx, callNode, candSyms[bestIdx], candidates[bestIdx], args, argTypes, skipMask, expectedType);
			contextArgsFit(ctx, args, skipMask, formals.checked);
			settled = true;
		}
	}
	let winnerType = formals.checked;
	const explicitWinner = formals.explicit;

	if (winnerType.kind == TypeKind.Function && winnerType.typeChildren != null) {
		for (let ai = 0; ai < args.length; ai += 1) {
			if (ai >= winnerType.typeChildren.length) break;
			if (skipMask[ai]) {
				if (!settled) {
					clearCheckerState(args[ai]);
					callCheckExpr(ctx, args[ai], winnerType.typeChildren[ai]);
				}
			} else if (!retypeLiteralArg(ctx, args[ai], literalArgs[ai], winnerType.typeChildren[ai])) {
				continue;
			}
			const refinedArgType = args[ai].nodeType;
			if (refinedArgType != null) { argTypes[ai] = refinedArgType; }
		}
	}

	// Consume affine-Promise arguments now that arg checking has settled.
	// Done AFTER Pass 2 so we only consume once (not once per pass).
	for (const arg of args) {
		const at = arg.nodeType;
		if (at != null && isAffineAwaitable(at) && arg.kind == NodeKind.Identifier) {
			const argSym = arg.resolvedSym;
			if (argSym != null) {
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
	if (spreadAt >= 0 && winnerType.kind == TypeKind.Function) {
		const picked = candSyms[bestIdx];
		const owner = hasFlag(picked, SymbolFlag.OverloadSig) && declaredDefaults(picked) == null ? impl : picked;
		const take = takeOptionalSpread(ctx, args, argTypes, calleeDefaults(callNode, owner, 0), winnerType.typeChildren, spreadAt);
		if (take.taken) {
			fillDefaultArgsForNode(ctx, callNode, sym.name, winnerType.typeChildren.length, 0, owner);
			fillTakenSpread(ctx, args, argTypes, take, winnerType.typeChildren);
		}
	}
	if (winnerType.kind == TypeKind.Function && winnerType.typeChildren != null) {
		relateCallArgs(ctx, callNode, winnerType, argTypes, false);
	}
	const winnerSymFinal = candSyms[bestIdx];
	if (gathered != null && bestIdx >= ownCount) {
		sym = gathered;
		impl = findOverloadImpl(sym) ?? winnerSymFinal;
		bestIdx = bestIdx - ownCount;
	}
	d.resolvedOverloadIdx = bestIdx;
	callNode.resolvedSym = sym;
	if (winnerSymFinal.symbolKind == SymbolKind.Function && isTemplateSym(winnerSymFinal)) {
		return expandTemplate(ctx, winnerSymFinal, callNode, d, expectedType);
	}
	// Signature → implementation reconciliation. Codegen mangles the call to
	// the body-bearing impl, so an argument that satisfied a body-LESS signature
	// must also satisfy the impl's parameter type. Load-bearing for DUs: the
	// per-variant sigs (`data: TypeUnionData`) all redirect to one impl taking
	// the union (`data: NodeData`), and handing it a bare variant struct
	// corrupts memory — clang only warns on the pointer mismatch.
	const emitted = hasFlag(winnerSymFinal, SymbolFlag.OverloadSig) ? impl : winnerSymFinal;
	if (emitted != null) fitCallToImplementation(callNode, emitted, false);
	if (d.callee != null && d.callee.kind == NodeKind.Identifier) {
		d.callee.resolvedSym = sym;
		if (sym.symbolType != null) d.callee.nodeType = sym.symbolType;
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
	const pickedSym: Symbol = bestIdx == 0
		? sym
		: (bestIdx - 1 < sym.overloads.length ? sym.overloads[bestIdx - 1] : (null as unknown as Symbol));
	const runsImpl = pickedSym != null && hasFlag(pickedSym, SymbolFlag.OverloadSig) && impl != null;
	const winnerSym: Symbol = runsImpl ? impl : pickedSym;
	if (winnerSym != null && winnerSym.declNode != null) {
		const winnerFlags = getGenericDeclFlags(winnerSym.declNode);
		if (isGenericFn(winnerFlags)) {
			const callReturn = runsImpl ? signatureReturn(winnerType, argTypes) : null;
			// Swap callNode.resolvedSym to winner so the helper instantiates
			// the picked overload, not the primary. Helper writes instSym
			// back into resolvedSym on success.
			const savedSym = callNode.resolvedSym;
			callNode.resolvedSym = winnerSym;
			if (d.callee != null && d.callee.kind == NodeKind.Identifier) {
				d.callee.resolvedSym = winnerSym;
				d.callee.nodeType = winnerSym.symbolType;
			}
			const newCalleeType = tryInstantiateGenericCallee(ctx, callNode, runsImpl ? impl.symbolType : explicitWinner, argTypes, winnerFlags, expectedType);
			if (newCalleeType != null) {
				// Mono fired. callNode.resolvedSym now points to instSym (no
				// overloads → codegen takes direct path). Keep d.resolvedOverloadIdx
				// at bestIdx so LSP hover/sig-help still reports which overload
				// the user matched against, even though codegen ignores it.
				if (newCalleeType.kind == TypeKind.Function && argTypes.length < newCalleeType.typeChildren.length) {
					fillDefaultArgsForNode(ctx, callNode, sym.name, newCalleeType.typeChildren.length, 0);
				}
				if (callReturn != null) return callReturn;
				return newCalleeType.typeReturn != null ? newCalleeType.typeReturn : inferredType();
			}
			// Mono didn't fire — restore primary sym for normal fall-through.
			callNode.resolvedSym = savedSym;
			if (d.callee != null && d.callee.kind == NodeKind.Identifier) {
				d.callee.resolvedSym = savedSym;
				d.callee.nodeType = sym.symbolType;
			}
		}
	}

	if (winnerType.kind == TypeKind.Function && argTypes.length < winnerType.typeChildren.length) {
		const defaultsOwner = hasFlag(winnerSymFinal, SymbolFlag.OverloadSig) && declaredDefaults(winnerSymFinal) == null ? impl : winnerSymFinal;
		fillDefaultArgsForNode(ctx, callNode, sym.name, winnerType.typeChildren.length, 0, defaultsOwner);
	}
	return inferGenericReturn(ctx, winnerType, argTypes, null, callNode);
}

export function resolveBorrow(ctx: CheckerContext, sym: Symbol, name: string, at: SourceLocation): void {
	const fnType = sym.symbolType;
	const baseArgs: Type[] = [];
	let hasDistinct = false;
	for (const param of fnType.typeChildren) {
		const isVar = param.kind == TypeKind.Var && param.typeReturn != null;
		const inner: Type = isVar ? param.typeReturn : param;
		const base = distinctBody(inner);
		if (base != null) hasDistinct = true;
		const arg = base != null ? base : inner;
		baseArgs.push(isVar ? createVar(arg) : arg);
	}
	if (!hasDistinct) {
		addError(ctx, `@delegate '${name}' has no distinct parameter, so there is nothing to borrow`, at.line, at.column);
		return;
	}
	const shown = `${name}(${baseArgs.map((t: Type): string => typeDisplayName(t)).join(", ")})`;
	const set = lookupSymbol(ctx.table, name);
	const cands: Symbol[] = [];
	if (set != null) {
		if (set != sym) cands.push(set);
		for (const o of set.overloads) {
			if (o != sym) cands.push(o);
		}
		const gathered = shadowedImportOf(ctx, set);
		if (gathered != null) {
			cands.push(gathered);
			for (const o of gathered.overloads) cands.push(o);
		}
	}
	let best: Symbol | null = null;
	let bestScore: CandidateScore = null as unknown as CandidateScore;
	let ambiguous = false;
	for (const cand of cands) {
		const candType = cand.symbolType;
		if (candType == null || candType.kind != TypeKind.Function) continue;
		const score = scoreCandidateWithSkip(candType.typeChildren, baseArgs, getMinArity(candType));
		if (score.exactMatches < 0) continue;
		const cmp = best == null ? 1 : cmpCandidates(score, bestScore, candType, best.symbolType);
		if (cmp > 0) {
			best = cand;
			bestScore = score;
			ambiguous = false;
		} else if (cmp == 0) {
			ambiguous = true;
		}
	}
	if (best == null) {
		const text = builtinTextFor(ctx, name, baseArgs, fnType.typeReturn);
		if (text != null) {
			sym.borrowedFrom = text;
			return;
		}
		if (comparesAtBase(ctx, sym)) {
			if (fnType.typeReturn == null || fnType.typeReturn.kind != TypeKind.Boolean) {
				addError(ctx, `@delegate '${name}' returns '${typeDisplayName(fnType.typeReturn)}' but ${shown} returns 'boolean'`, at.line, at.column);
			}
			return;
		}
		addError(ctx, `@delegate '${name}': no ${shown} to delegate to`, at.line, at.column);
		return;
	}
	if (ambiguous) {
		addError(ctx, `@delegate '${name}': more than one ${shown} to delegate to`, at.line, at.column);
		return;
	}
	if (hasGenericParams(best.symbolType) && !hasFlag(best, SymbolFlag.Borrow)) {
		addError(ctx, `@delegate '${name}' cannot borrow from a generic function: its base type must not mention a type parameter`, at.line, at.column);
		return;
	}
	const own = fnType.typeReturn;
	const theirs = best.symbolType.typeReturn;
	if (!sameType(peelDistinctReturn(own), peelDistinctReturn(theirs))) {
		addError(ctx, `@delegate '${name}' returns '${typeDisplayName(own)}' but ${shown} returns '${typeDisplayName(theirs)}'`, at.line, at.column);
		return;
	}
	sym.borrowedFrom = best;
	markUsedIn(ctx, best);
}

function builtinTextFor(ctx: CheckerContext, name: string, baseArgs: Type[], ret: Type | null): Symbol | null {
	if (name != "toString" || baseArgs.length != 1 || ret == null || !isStringLike(ret)) return null;
	const text = lookupSymbol(ctx.table, "String");
	return text != null && text.builtinKind == "ToString" ? text : null;
}

function peelDistinctReturn(t: Type | null): Type | null {
	const base = distinctBody(t);
	return base != null ? peelDistinctReturn(base) : t;
}

// Resolve extension method overloads: multiple extensions match same receiver+method.
// Each extension's fnType includes the receiver as param[0]; strip it before scoring.
function isValueCallee(callee: Node): boolean {
	if (callee.kind != NodeKind.Identifier && callee.kind != NodeKind.MemberExpr) return true;
	const sym = callee.resolvedSym;
	if (sym == null) return callee.kind == NodeKind.MemberExpr;
	return sym.symbolKind == SymbolKind.Variable || sym.symbolKind == SymbolKind.Parameter
		|| sym.symbolKind == SymbolKind.Property || sym.symbolKind == SymbolKind.Temp;
}

// Reference (semIndirectOp, semexprs.nim): a value is called only through a
// procedure type; every other type in call position is refused. A type not
// known yet is left to the code that settles it.
// The node whose value a match arm yields: its expression, or the argument of
// the return that ends its block.
function matchArmValue(cd: MatchCaseData, asStatement: boolean): Node {
	const none = null as unknown as Node;
	if (cd.caseBody.kind != NodeKind.BlockStmt) return cd.caseBody;
	if (asStatement) return none;
	const bd = cd.caseBody.data as BlockStmtData;
	if (bd.statements.length == 0) return none;
	const last = bd.statements[bd.statements.length - 1];
	return last.kind == NodeKind.ReturnStmt ? (last.data as ReturnStmtData).argument ?? none : none;
}

function unionCalleeHint(t: Type): string {
	if (t.kind != TypeKind.Union) return "";
	for (const m of t.typeChildren) {
		if (m.kind == TypeKind.Function) return " — a union is called only after narrowing it to a single function type";
	}
	return "";
}

function isCallableValueType(t: Type): boolean {
	return match (t.kind) {
		TypeKind.Function => true,
		TypeKind.Inferred | TypeKind.Unknown | TypeKind.Pending | TypeKind.Error | TypeKind.Never
			| TypeKind.GenericParam | TypeKind.TypeReference | TypeKind.Conditional | TypeKind.IndexedAccess | TypeKind.KeyOf | TypeKind.Mapped => true,
		TypeKind.GenericInstance => isCallableInstance(t),
		TypeKind.Ref | TypeKind.Var | TypeKind.Lent | TypeKind.Sink | TypeKind.Borrow | TypeKind.Alias | TypeKind.Distinct =>
			t.typeReturn == null || isCallableValueType(t.typeReturn),
		_ => false,
	};
}

function isCallableInstance(t: Type): boolean {
	if (t.typeReturn == null) instantiateGenericBody(t, genericParamsOf(t));
	const body = t.typeReturn ?? distinctBody(t);
	return body == null || isCallableValueType(body);
}

function dynamicFieldCalleeHint(callee: Node): string {
	if (callee.kind != NodeKind.CallExpr) return "";
	const inner = (callee.data as CallExprData).callee;
	if (inner.kind != NodeKind.MemberExpr || (inner.data as MemberExprData).property != "getDynamicField") return "";
	const args = (callee.data as CallExprData).arguments;
	const key = args.length > 0 && args[0].kind == NodeKind.StringLiteral ? (args[0].data as StringLiteralData).value : "";
	return ` — '${key}' is read as a dynamic field here, not a method; a free function is called as '${key}(value, …)'`;
}

// Declared types, not `candidates`: those have the receiver stripped, and the receiver is what differs.
function mostSpecificGenericExt(exts: ExtensionMethod[]): int32 {
	let winner = -1;
	for (let i = 0; i < exts.length; i += 1) {
		let beatsAll = true;
		for (let j = 0; j < exts.length; j += 1) {
			if (i == j) continue;
			const a = getExtFnType(exts[i]);
			const b = getExtFnType(exts[j]);
			let s = checkGenericSpecialization(a, b);
			if (s == 0) s = complexDisambiguation(a, b);
			if (s <= 0) { beatsAll = false; break; }
		}
		if (beatsAll) {
			if (winner >= 0) return -1;
			winner = i;
		}
	}
	return winner;
}

function rankExtensionOverloads(ctx: CheckerContext, exts: ExtensionMethod[], candidates: Type[], args: Node[], argTypes: Type[],
	scopeDepths: number[], recvRelations: TypeRelation[], objType: Type | null, skipMask: boolean[], rejected: boolean[], typedPer: Type[][] | null = null): number {
	let idx = resolveExtensionOverloadIdx(ctx, candidates, args, argTypes, scopeDepths, recvRelations, exts, skipMask, rejected, typedPer);
	if (idx == -2) {
		// Tiebreaker: an exact receiver beats a widening one — `this uint8[]`
		// wins over `this number[]` on a uint8[] object instead of tying.
		if (objType != null && !isUnresolvedType(objType)) {
			let exactIdx = -1;
			let exactCount = 0;
			let xi = 0;
			while (xi < exts.length) {
				const xft = getExtFnType(exts[xi]);
				if (!exts[xi].isStatic && xft.kind == TypeKind.Function && xft.typeChildren.length > 0
						&& sameType(xft.typeChildren[0], objType)) {
					exactIdx = xi;
					exactCount = exactCount + 1;
				}
				xi = xi + 1;
			}
			if (exactCount == 1) {
				idx = exactIdx;
			}
		}
		// Tiebreaker: prefer concrete extension over generic
		if (idx == -2) {
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
			const specificIdx = concreteCount == 0 ? mostSpecificGenericExt(exts) : -1;
			if (concreteCount == 1) {
				idx = concreteIdx;
			} else if (specificIdx >= 0) {
				idx = specificIdx;
			}
		}
	}
	return idx;
}

function resolveExtensionOverloadCall(ctx: CheckerContext, exts: ExtensionMethod[],
	argTypes: Type[], literalArgs: boolean[], objType: Type | null, methodName: string, callNode: Node, expectedType: Type | null): Type {
	// Receiver specificity: scoring strips the receiver param, so `this string`
	// and `this unknown` would otherwise tie into ambiguity. A catch-all
	// `this unknown` receiver only participates when no concrete-receiver
	// candidate matched (or the object itself is unknown).
	if (objType != null && !isUnresolvedType(objType) && exts.length > 1) {
		const specific: ExtensionMethod[] = [];
		for (const e of exts) {
			const ft = getExtFnType(e);
			if (!e.isStatic && ft.kind == TypeKind.Function && ft.typeChildren.length > 0
					&& ft.typeChildren[0] != null && isUnresolvedType(ft.typeChildren[0])) {
				continue;
			}
			specific.push(e);
		}
		if (specific.length > 0 && specific.length < exts.length) { exts = specific; }
		if (unknownRefusal(objType) != UnknownRefusal.None) {
			const shaped: ExtensionMethod[] = [];
			for (const e of exts) {
				const ft = getExtFnType(e);
				if (!e.isStatic && ft.kind == TypeKind.Function && ft.typeChildren.length > 0
						&& ft.typeChildren[0] != null && ft.typeChildren[0].kind == TypeKind.Unknown) {
					continue;
				}
				shaped.push(e);
			}
			if (shaped.length > 0 && shaped.length < exts.length) { exts = shaped; }
		}
	}
	// Dedup handled at registration (registerExtension rejects duplicate syms).
	// Build candidate list: getExtFnType for authoritative type, stripReceiverParam for scoring.
	const candidates: Type[] = [];
	const recvFormals: (Type | null)[] = [];
	const recvRelations: TypeRelation[] = [];
	let ei = 0;
	while (ei < exts.length) {
		const declType = getExtFnType(exts[ei]);
		let srcType = declType;
		if (hasGenericParams(srcType)) {
			const eb = createUnifyBindings();
			unifyArrayReceiver(srcType.typeChildren[0], objType, eb);
			if (eb.names.length > 0) {
				srcType = substituteBound(srcType, eb);
			}
		}
		if (!exts[ei].isStatic && srcType.typeChildren.length > 0) {
			candidates.push(stripReceiverParam(srcType));
			recvFormals.push(srcType.typeChildren[0]);
			recvRelations.push(receiverRelation(declType.typeChildren[0], objType));
		} else {
			candidates.push(srcType);
			recvFormals.push(null);
			recvRelations.push(TypeRelation.None);
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
	const args = (callNode.data as CallExprData).arguments;
	const spreadAt = trailingArraySpread(args);
	if (spreadAt < 0 && hasSpreadArg(args)) {
		refuseMisplacedSpread(ctx, args, [], 0);
		return getReturnType(candidates[0]);
	}
	if (spreadAt >= 0) argTypes[spreadAt] = spreadElementType(args[spreadAt]);
	const skipMask: boolean[] = [];
	const rejected: boolean[] = [];
	for (let ai = 0; ai < args.length; ai += 1) skipMask.push(ai < argTypes.length && argTypes[ai] == null && isContextSensitive(args[ai]));
	for (let ci = 0; ci < candidates.length; ci += 1) {
		const offset: int32 = exts[ci].isStatic ? 0 : 1;
		const minArgs = firstDefaulted(calleeDefaults(callNode, exts[ci].sym, offset), candidates[ci].typeChildren);
		rejected.push(spreadAt >= 0 && !spreadFitsCandidate(candidates[ci], spreadAt, argTypes[spreadAt], minArgs));
	}
	let idx = rankExtensionOverloads(ctx, exts, candidates, args, argTypes, scopeDepths, recvRelations, objType, skipMask, rejected);
	const contextFormals: Type[] = [];
	for (const c of candidates) contextFormals.push(boundByExpectedReturn(c, expectedType));
	let settled = false;
	if (idx != -1 && skipMask.includes(true)) {
		const typedPer: Type[][] = [];
		const unfit = rejected.slice(0);
		for (let ci = 0; ci < candidates.length; ci += 1) {
			if (!unfit[ci] && contextArgsFit(ctx, args, skipMask, contextFormals[ci])) typedPer.push(typedContextArgs(args, argTypes, skipMask));
			else { unfit[ci] = true; typedPer.push(argTypes); }
		}
		const fitIdx = rankExtensionOverloads(ctx, exts, candidates, args, argTypes, scopeDepths, recvRelations, objType, allScored(skipMask), unfit, typedPer);
		if (fitIdx == -2) {
			addError(ctx, "Ambiguous call to overloaded extension method '" + methodName + "' — " + ANNOTATE_CONTEXT_ARG, callNode.location.line, callNode.location.column);
			return getReturnType(candidates[0]);
		}
		if (fitIdx >= 0) {
			idx = fitIdx;
			contextArgsFit(ctx, args, skipMask, contextFormals[idx]);
			settled = true;
		}
	}
	if (idx == -2) {
		addError(ctx, "Ambiguous call to overloaded extension method '" + methodName + "'", callNode.location.line, callNode.location.column);
		return getReturnType(candidates[0]);
	}
	if (idx == -1) {
		let msg = "No matching overload for extension method '" + methodName + "'\n  Expected one of:";
		let ci = 0;
		while (ci < candidates.length) {
			if (candidates[ci].kind == TypeKind.Function) {
				msg = msg + "\n    " + formatCandidateSig(methodName, candidates[ci]);
			}
			ci = ci + 1;
		}
		addError(ctx, msg, callNode.location.line, callNode.location.column);
		return getReturnType(candidates[0]);
	}
	const extWinnerSym = idx >= 0 && idx < exts.length ? exts[idx].sym : null;
	if (extWinnerSym != null) {
		markUsedIn(ctx, extWinnerSym);
		const looked = callNode.resolvedSym;
		callNode.resolvedSym = looked != null && looked.instantiatedFrom == extWinnerSym ? looked : signatureTarget(ctx, extWinnerSym, callNode, findAllExtensionsByName(ctx.extensionRegistry!, methodName));
		// Mark for transform: skip registry re-lookup (reference resolves UFCS in sem)
		if (!hasFlag(extWinnerSym, SymbolFlag.NativeMethod)) {
			callNode.flags = callNode.flags.incl(NodeFlag.ExtCall);
		}
		if (exts[idx].isStatic) callNode.flags = callNode.flags.incl(NodeFlag.ExtStatic);
	}
	// Fill default args for extension overloads
	// defaultOffset: 0 for static (parser stripped receiver from fnDefaults), 1 for non-static
	let winnerType = candidates[idx];
	for (let ai = 0; ai < skipMask.length; ai += 1) {
		if (!skipMask[ai]) continue;
		if (!settled) {
			const formal = contextFormals[idx];
			clearCheckerState(args[ai]);
			callCheckExpr(ctx, args[ai], ai < formal.typeChildren.length ? formal.typeChildren[ai] : null);
		}
		argTypes[ai] = args[ai].nodeType!;
	}
	const ovDefaultOffset: int32 = (idx >= 0 && idx < exts.length && exts[idx].isStatic) ? 0 : 1;
	const defaultsOwner = extWinnerSym != null && hasFlag(extWinnerSym, SymbolFlag.OverloadSig) && declaredDefaults(extWinnerSym) == null ? callNode.resolvedSym : extWinnerSym;
	const ovSpread = spreadAt >= 0 && winnerType.kind == TypeKind.Function
		? takeOptionalSpread(ctx, args, argTypes, calleeDefaults(callNode, defaultsOwner, ovDefaultOffset), winnerType.typeChildren, spreadAt)
		: { spread: null, at: -1, taken: false } as SpreadTake;
	if (winnerType.kind == TypeKind.Function && argTypes.length < winnerType.typeChildren.length) {
		fillDefaultArgsForNode(ctx, callNode, methodName, winnerType.typeChildren.length, ovDefaultOffset, defaultsOwner);
	}
	if (winnerType.kind == TypeKind.Function) fillTakenSpread(ctx, args, argTypes, ovSpread, winnerType.typeChildren);
	if (winnerType.kind == TypeKind.Function) {
		for (let ai = 0; ai < literalArgs.length && ai < winnerType.typeChildren.length; ai += 1) {
			if (retypeLiteralArg(ctx, args[ai], literalArgs[ai], winnerType.typeChildren[ai]) && args[ai].nodeType != null) argTypes[ai] = args[ai].nodeType!;
		}
		relateMethodCallArgs(ctx, callNode, winnerType, recvFormals[idx], argTypes, false);
	}
	if (extWinnerSym != null && callNode.resolvedSym != extWinnerSym && hasFlag(extWinnerSym, SymbolFlag.OverloadSig)) {
		fitCallToImplementation(callNode, callNode.resolvedSym!, !exts[idx].isStatic);
	}
	if (extWinnerSym != null && !exts[idx].isStatic && objType != null && extWinnerSym.declNode != null
			&& extWinnerSym.builtinKind == "" && extWinnerSym.declNode.kind == NodeKind.FunctionDecl
			&& isGenericFn((extWinnerSym.declNode.data as FunctionDeclData).fnFlags)) {
		const recvBindings = createUnifyBindings();
		unifyArrayReceiver(getExtFnType(exts[idx]).typeChildren[0], objType, recvBindings);
		if (recvBindings.names.length > 0 && bindingsCoverDecl(recvBindings, extWinnerSym.declNode)) {
			const instSym = callInstantiateGeneric(extWinnerSym, recvBindings.params, recvBindings.types, ctx, callNode.location);
			if (instSym != null) {
				callNode.resolvedSym = instSym;
				winnerType = stripReceiverParam(instSym.symbolType);
			}
		}
	} else if (extWinnerSym != null && !exts[idx].isStatic && objType != null && extWinnerSym.builtinKind == ""
			&& extWinnerSym.declNode != null && extWinnerSym.declNode.kind == NodeKind.MethodDecl && winnerType.kind == TypeKind.Function) {
		const recvBindings = createUnifyBindings();
		unifyArrayReceiver(getExtFnType(exts[idx]).typeChildren[0], objType, recvBindings);
		if (isGenericInstanceMethod(extWinnerSym)) {
			const methodInst = tryInstantiateGenericCallee(ctx, callNode, winnerType, argTypes, getGenericDeclFlags(extWinnerSym.declNode), null, recvBindings);
			if (methodInst != null) winnerType = stripReceiverParam(methodInst);
		} else if (recvBindings.names.length > 0) {
			const instSym = callInstantiateGeneric(extWinnerSym, recvBindings.params, recvBindings.types, ctx, callNode.location);
			if (instSym != null) {
				ensureShaped(instSym, ctx);
				callNode.resolvedSym = instSym;
			}
		}
	}
	if (extWinnerSym != null && !exts[idx].isStatic && callNode.resolvedSym == extWinnerSym && extWinnerSym.builtinKind == ""
			&& extWinnerSym.declNode != null && declTakesReceiver(extWinnerSym.declNode) && isGenericRoutine(winnerType, extWinnerSym)) {
		const recvBindings = createUnifyBindings();
		unifyArrayReceiver(getExtFnType(exts[idx]).typeChildren[0], objType, recvBindings);
		const inst = tryInstantiateGenericCallee(ctx, callNode, winnerType, argTypes, getGenericDeclFlags(extWinnerSym.declNode), null, recvBindings);
		if (inst != null) winnerType = stripReceiverParam(inst);
	}
	const callee = (callNode.data as CallExprData).callee;
	callee.resolvedSym = callNode.resolvedSym;
	callee.nodeType = winnerType;
	return inferGenericReturn(ctx, winnerType, argTypes, null, callNode);
}

function typedContextArgs(args: Node[], argTypes: Type[], skipMask: boolean[]): Type[] {
	const typed = argTypes.slice(0);
	for (let ai = 0; ai < skipMask.length; ai += 1) {
		if (skipMask[ai]) typed[ai] = withBodyReturn(args[ai], args[ai].nodeType!);
	}
	return typed;
}

// An expression-bodied arrow checked against a `void` callback drops its value; it ranks
// with the type its body gives, so `(v) => v + 1` relates to `(v) => U` and not to `(v) => void`.
function withBodyReturn(arg: Node, typed: Type): Type {
	if (arg.kind != NodeKind.ArrowFunction || typed == null || typed.kind != TypeKind.Function) return typed;
	const ret = typed.typeReturn;
	const body = (arg.data as ArrowFunctionData).arrowBody;
	if (ret == null || ret.kind != TypeKind.Void || body == null || body.kind == NodeKind.BlockStmt) return typed;
	const value = body.nodeType;
	if (value == null || value.kind == TypeKind.Void || isUnresolvedType(value)) return typed;
	return createFunction(typed.typeChildren, typed.typeNames, value);
}

function allScored(skipMask: boolean[]): boolean[] {
	return skipMask.map((s) => false);
}

function boundByExpectedReturn(candidate: Type, expectedType: Type | null): Type {
	if (candidate.kind != TypeKind.Function || !hasGenericParams(candidate)) return candidate;
	const bindings = bindFromExpectedReturn(candidate, expectedType);
	return bindings.names.length > 0 ? substituteBound(candidate, bindings) : candidate;
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
	if (fnType.typeReturn != null) {
		sig = sig + ": " + typeDisplayName(fnType.typeReturn);
	}
	return sig;
}

function constructorDeclaringClass(classSym: Symbol): Symbol | null {
	if (!hasFlag(classSym, SymbolFlag.InheritsConstructor)) return null;
	let owner = classSym;
	let depth = 0;
	while (owner != null && hasFlag(owner, SymbolFlag.InheritsConstructor) && depth < 64) {
		owner = parentClassSymOf(owner);
		depth += 1;
	}
	return owner;
}

function superInstance(t: Type | null): Type | null {
	const body = t != null && t.kind == TypeKind.Ref ? t.typeReturn : t;
	return body != null && body.kind == TypeKind.GenericInstance ? body : null;
}

function withoutArrayEnvelope(t: Type): Type {
	return t.kind == TypeKind.Ref && t.typeReturn != null && t.typeReturn.kind == TypeKind.Array ? t.typeReturn : t;
}

function unifyArrayReceiver(formal: Type, objType: Type | null, eb: UnifyBindings): void {
	unifyType(withoutArrayEnvelope(formal), objType != null ? withoutArrayEnvelope(objType) : objType, eb);
}

function receiverRelation(formal: Type, objType: Type | null): TypeRelation {
	if (objType == null) return TypeRelation.None;
	const recvT = withoutArrayEnvelope(formal);
	const objT = withoutArrayEnvelope(objType);
	const rel = typeRelation(recvT, objT);
	if (rel == TypeRelation.None && hasGenericParams(recvT)) return TypeRelation.Generic;
	return rel;
}

function resolveExtensionOverloadIdx(ctx: CheckerContext, candidates: Type[], args: Node[],
	argTypes: Type[], scopeDepths: number[], recvRelations: TypeRelation[], exts: ExtensionMethod[], skipMask: boolean[], rejected: boolean[], typedPer: Type[][] | null = null): number {
	let bestIdx = -1;
	let bestScore = emptyCandidateScore();
	let ambiguous = false;
	const sigScores: CandidateScore[] = [];
	const onlySkipped = skipMask.includes(true) && !skipMask.includes(false);
	let i = 0;
	while (i < candidates.length) {
		if (candidates[i].kind != TypeKind.Function || rejected[i]) { i = i + 1; continue; }
		const at = typedPer != null ? typedPer[i] : argTypes;
		const score = scoreCandidateWithSkip(candidates[i].typeChildren, at, getMinArity(candidates[i]), skipMask, literalRelations(candidates[i].typeChildren, args, at));
		if (isNoMatch(score)) { i = i + 1; continue; }
		if (i < recvRelations.length) countRelation(score, recvRelations[i]);
		if (i < scopeDepths.length) {
			score.calleeScope = scopeDepths[i];
		}
		const extSym = exts[i].sym;
		if (extSym != null && hasFlag(extSym, SymbolFlag.OverloadSig)) {
			while (sigScores.length < i) sigScores.push(noMatchScore());
			sigScores.push(score);
		}
		if (bestIdx == -1) {
			bestIdx = i;
			bestScore = score;
			ambiguous = false;
		} else {
			const cmp = cmpCandidates(score, bestScore, getExtFnType(exts[i]), getExtFnType(exts[bestIdx]));
			if (cmp > 0) {
				bestIdx = i;
				bestScore = score;
				ambiguous = false;
			} else if (cmp == 0 && !onlySkipped && !adapterTie(candidates[i], candidates[bestIdx], at, skipMask)) {
				ambiguous = true;
			}
		}
		i = i + 1;
	}
	if (sigScores.length > 0) {
		const extSyms: Symbol[] = [];
		for (const e of exts) {
			const es = e.sym;
			if (es == null) break;
			extSyms.push(es);
		}
		const first = firstApplicable(sigScores, extSyms);
		if (first >= 0) return first;
	}
	if (ambiguous) return -2;
	return bestIdx;
}

// Check if a type maps to a pointer in C (Ref, Ptr, Borrow — NOT Object/interface)
function isPointerInC(t: Type, ctx: CheckerContext): boolean {
	if (t == null) return false;
	if (t.kind == TypeKind.Cursor) {
		const inner = t.typeReturn;
		return inner != null && isPointerInC(inner, ctx);
	}
	return t.kind == TypeKind.Ref || t.kind == TypeKind.Ptr || t.kind == TypeKind.Borrow || t.kind == TypeKind.Var;
}

// Validate object literal construction against a discriminated union type.
// Finds the discriminant field in the literal, resolves the variant, and validates fields.
export function checkDiscriminatedConstruction(ctx: CheckerContext, node: Node, d: ObjectLiteralData, unionType: Type | null, stampType: Type | null, spreadDisc: Type | null): Type {
	if (unionType == null) return inferredType();
	const discName = unionType.typeNames[0]; // discriminant field name (e.g. "kind")

	// Find the discriminant field in the object literal keys
	let discIdx = -1;
	let ki = 0;
	while (ki < d.keys.length) {
		if (d.keys[ki] == discName) {
			discIdx = ki;
			ki = d.keys.length; // break
		}
		ki = ki + 1;
	}

	if (discIdx < 0 && spreadDisc == null) {
		// No discriminant field — fall back to checking all properties without validation
		for (const prop of d.properties) {
			callCheckExpr(ctx, prop, null);
		}
		addError(ctx, "Object literal for discriminated union '" + unionType.typeName + "' missing discriminant field '" + discName + "'", node.location.line, node.location.column);
		node.nodeType = stampType != null ? stampType : unionType;
		return node.nodeType;
	}

	let variantIdx = -1;
	let discExpr: Node | null = null;
	if (spreadDisc != null) {
		if (spreadDisc.kind == TypeKind.BooleanLiteral) variantIdx = findVariantByBooleanDiscriminant(unionType, discName, booleanLiteralValue(spreadDisc));
		else if (spreadDisc.kind == TypeKind.EnumLiteral) variantIdx = findVariantByEnumMember(unionType, spreadDisc);
		if (variantIdx < 0) {
			addError(ctx, `the spread gives '${discName}' as ${typeDisplayName(spreadDisc)}, which names no member of '${unionType.typeName}': give '${discName}' after the spread`, node.location.line, node.location.column);
		}
	} else {
		// Check the discriminant expression first to get its value
		const written = d.properties[discIdx];
		callCheckExpr(ctx, written, unionType.typeExtra);
		discExpr = written;
		if (written.kind == NodeKind.BooleanLiteral) {
			variantIdx = findVariantByBooleanDiscriminant(unionType, discName, (written.data as BooleanLiteralData).boolValue);
		} else {
			const lit = enumMemberLiteralOf(written);
			if (lit != null) variantIdx = findVariantByEnumMember(unionType, lit);
		}
	}

	if (variantIdx >= 0 && variantIdx < unionType.typeChildren.length) {
		const variant = unionType.typeChildren[variantIdx];
		if (variant.kind == TypeKind.Ref) {
			const discField = findFieldInVariant(variant, discName);
			if (discField != null && discExpr != null) discExpr.nodeType = discField;
			rearmLiteralForRecheck(node, variant);
			callCheckExpr(ctx, node, variant);
			const retyped = node.nodeType as Type | null;
			return retyped != null ? retyped : variant;
		}
		// Validate remaining fields match this variant
		// Use stampType (preserves Ref wrapper) so codegen knows to heap-allocate
		node.nodeType = stampType != null ? stampType : unionType;
		node.variantSlot = variantIdx + 1;
		let fi = 0;
		while (fi < d.keys.length) {
			if (fi == discIdx && discExpr != null) {
				// Discriminant already checked
				fi = fi + 1;
				continue;
			}
			const key = d.keys[fi];
			const fieldType = findFieldInVariant(variant, key);
			if (fieldType != null) {
				callCheckExpr(ctx, d.properties[fi], fieldType);
			} else {
				callCheckExpr(ctx, d.properties[fi], null);
				addError(ctx, "Field '" + key + "' does not exist on variant " + unionType.typeNames[variantIdx + 1] + " of '" + unionType.typeName + "'", node.location.line, node.location.column);
			}
			fi = fi + 1;
		}
		return node.nodeType!;
	}

	// Could not resolve variant — check properties without validation
	let pi = 0;
	while (pi < d.properties.length) {
		if (pi != discIdx || discExpr == null) {
			callCheckExpr(ctx, d.properties[pi], null);
		}
		pi = pi + 1;
	}
	node.nodeType = stampType != null ? stampType : unionType;
	return node.nodeType;
}

function hasThisParam(sym: Symbol): boolean {
	return sym.symbolType != null && sym.symbolType.typeNames != null
		&& sym.symbolType.typeNames.length > 0 && sym.symbolType.typeNames[0] == "this";
}

// A timed spawn's deadline is taken at the await written around it: the spawn is
// that await's operand, or an element of the array literal of the Promise.all it
// awaits, which the group lowering waits on with the deadline.
function awaitedWhereWritten(ctx: CheckerContext, spawnCall: Node): boolean {
	const a = ctx.awaitedCall;
	if (a === spawnCall) return true;
	if (a == null || a.kind != NodeKind.CallExpr) return false;
	const ad = a.data as CallExprData;
	if (ad.arguments.length != 1 || ad.arguments[0].kind != NodeKind.ArrayLiteral) return false;
	if (ad.callee.kind != NodeKind.MemberExpr) return false;
	const md = ad.callee.data as MemberExprData;
	if (md.property != "all" || md.object.kind != NodeKind.Identifier || (md.object.data as IdentifierData).name != "Promise") return false;
	for (const el of (ad.arguments[0].data as ArrayLiteralData).elements) {
		if (el === spawnCall) return true;
	}
	return false;
}

function desugarSpawnMoveList(ctx: CheckerContext, d: CallExprData): string[] {
	const movedKeys: string[] = [];
	const args: Node[] = d.arguments;
	if (args.length < 2) return movedKeys;
	const optsNode = args[1];
	if (optsNode.kind != NodeKind.ObjectLiteral) {
		addError(ctx, "spawn options must be an object literal, e.g. spawn(fn, { timeout: 500, move: [x] })", optsNode.location.line, optsNode.location.column);
		return movedKeys;
	}
	const opts = optsNode.data as ObjectLiteralData;
	let moveIdx = -1;
	for (let ki = 0; ki < opts.keys.length; ki += 1) {
		if (opts.keys[ki] == "move") moveIdx = ki;
		else if (opts.keys[ki] != "timeout") addError(ctx, "unknown spawn option '" + opts.keys[ki] + "' — spawn accepts { timeout, move }", opts.keyLocations[ki].line, opts.keyLocations[ki].column);
	}
	if (moveIdx < 0) return movedKeys;
	const moveList = opts.properties[moveIdx];
	opts.keys.splice(moveIdx, 1);
	opts.properties.splice(moveIdx, 1);
	opts.keyLocations.splice(moveIdx, 1);
	if (opts.keys.length == 0) args.pop();
	if (moveList.kind != NodeKind.ArrayLiteral) {
		addError(ctx, "spawn { move } takes an array of local names, e.g. { move: [buf, tbl] }", moveList.location.line, moveList.location.column);
		return movedKeys;
	}
	const names: string[] = [];
	const paramTypes: Type[] = [];
	const paramAnnots: string[] = [];
	const paramDefaults: Node[] = [];
	const moveArgs: Node[] = [];
	const thunk = args[0];
	const listNodes: Node[] = (moveList.data as ArrayLiteralData).elements;
	const moveNames: string[] = [];
	for (const el of listNodes) {
		if (el.kind == NodeKind.Identifier) moveNames.push((el.data as IdentifierData).name);
	}
	for (const el of listNodes) {
		if (el.kind != NodeKind.Identifier) {
			addError(ctx, "spawn { move } entries must be plain local names — bind a field first (const part = obj.part) and move that", el.location.line, el.location.column);
			continue;
		}
		const name = (el.data as IdentifierData).name;
		const sym = lookupSymbol(ctx.table, name);
		if (sym == null) {
			addError(ctx, "cannot move '" + name + "': no such binding in scope", el.location.line, el.location.column);
			continue;
		}
		ensureShaped(sym, ctx);
		if (sym.symbolType == null) continue;
		checkMoveSoleOwner(ctx, sym, moveNames, thunk, el.location);
		names.push(name);
		paramTypes.push(sym.symbolType);
		paramAnnots.push("");
		paramDefaults.push(null as unknown as Node);
		moveArgs.push(createNodeAt(NodeKind.MoveExpr, { moveArg: el }, el.location));
		movedKeys.push(symbolConsumeKey(sym));
	}
	if (names.length == 0) return movedKeys;
	const outer = createNodeAt(NodeKind.ArrowFunction, {
		arrowParams: names, arrowParamTypes: paramAnnots, arrowBody: thunk,
		arrowFlags: "", arrowReturnType: "", arrowDefaults: paramDefaults,
	}, thunk.location);
	ctx.pendingSpawnThunk = true;
	callCheckExpr(ctx, outer, createFunction(paramTypes, names, inferredType()));
	if (outer.nodeType != null && outer.nodeType.kind == TypeKind.Function) {
		outer.nodeType.typeChildren = outer.nodeType.typeChildren.map((t: Type): Type => createSink(t));
	}
	args[0] = createNodeAt(NodeKind.CallExpr, { callee: outer, arguments: moveArgs, isDirectCall: false, resolvedOverloadIdx: -1 }, thunk.location);
	return movedKeys;
}

function refuseReadonlyViewCall(ctx: CheckerContext, node: Node, property: string, objType: Type, receiverName: string): void {
	addError(ctx, "cannot call '" + property + "' on " + typeDisplayName(objType) + " — a read-only view; a method callable through the view declares its receiver read-only: '" + property + "(this: Readonly<" + receiverName + ">)' on the class, or 'function " + property + "(this x: Readonly<" + receiverName + ">)' as an extension (PARALOCK E24)", node.location.line, node.location.column);
}

function boundExtensions(member: Node, byName: ExtensionMethod[]): ExtensionMethod[] {
	if (!member.flags.has(NodeFlag.BoundSym) || member.resolvedSym == null) return byName;
	const origin = member.resolvedSym.instantiatedFrom != null ? member.resolvedSym.instantiatedFrom : member.resolvedSym;
	const bound: ExtensionMethod[] = [];
	for (const e of byName) {
		if (e.sym == origin) bound.push(e);
	}
	return bound;
}

export function checkMemberExpr(ctx: CheckerContext, node: Node, expectedType: Type | null): Type {
	const d = node.data as MemberExprData;
	checkInTypeSlot(ctx, d.object);
	const declaredUnion = d.object.nodeType != null && d.object.nodeType.kind != TypeKind.Union ? declaredTagUnionOf(d.object) : null;
	if (declaredUnion != null && unionVariantHasProperty(declaredUnion, d.property)
			&& !(isDiscriminatedUnion(declaredUnion) && getDiscriminantName(declaredUnion) == d.property)) {
		const projected = narrowUnionToVariant(d.object, d.object.nodeType!);
		if (projected != null as unknown as Node) d.object = projected;
	}
	const objType = d.object.nodeType != null ? peelTransparentInstance(d.object.nodeType) : null;
	if (objType == null) return inferredType();
	if (objType.kind == TypeKind.Never) {
		addError(ctx, `Property '${d.property}' does not exist on type 'never': the conditions that lead here leave no value for the object`, node.location.line, node.location.column);
		node.nodeType = errorType();
		return node.nodeType;
	}
	// Ref parity: strictNotNil — warn on unguarded class (heap pointer) member access.
	// Phase 4: uses the flow graph's isDefinitelyNonNullAt walker (replaced the
	// fact-stack-based impliesNotNull).
	if (ctx.strictNullChecks && unwrapRefNullUnion(objType) != null && d.object.kind == NodeKind.Identifier) {
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
	if (objType.kind == TypeKind.Enum && d.property != "toString"
			&& objType.typeNames.indexOf(d.property) >= 0) {
		const enumName = objType.typeName;
		const propName = d.property;
		const enumSym = objType.sym;
		const mangledName = enumMemberName(enumSym, enumName, propName);
		// Tier 1: narrow to EnumLiteral when the context directly expects the literal form
		// (return type, variable annotation, etc). Union<EnumLiteral...> narrowing is deferred
		// to Tier 2 (discriminated union narrowing at call sites). The literal type is also
		// stored on resolvedSym.symbolType so call-argument narrowing can pick it up even
		// when no expectedType flows down.
		const wantsLiteral = expectedType != null
			&& expectedType.kind == TypeKind.EnumLiteral
			&& expectedType.typeReturn != null && sameNominal(expectedType.typeReturn, objType)
			&& expectedType.typeNames.length > 0
			&& expectedType.typeNames[0] == propName;
		const litType = createEnumLiteral(objType, propName);
		const reportedType = wantsLiteral ? litType : objType;
		// Create synthetic symbol for the enum member (no scope lookup needed).
		// Enum member mangled names are NOT in scope — resolved here at use site.
		const memberSym = makeSymbolState(propName, SymbolKind.EnumMember, reportedType, false, SymbolState.Shaped);
		if (enumSym != null && enumSym.location != null) {
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
		memberSym.symbolType = litType;
		node.nodeType = reportedType;
		return reportedType;
	}
	// Module namespace access: ns.X where ns is import * as ns
	// Resolve directly from the module's export table — never from local scope.
	// Keep MemberExpr (don't rewrite to Identifier):
	//   C codegen: handles Module MemberExpr → emits mangled name
	//   JS codegen: emits ns.X naturally (standard ES6 namespace access)
	const nsObject = d.object.resolvedSym != null && d.object.resolvedSym.symbolKind == SymbolKind.Module;
	if (nsObject || objType.kind == TypeKind.Module) {
		const nsModPath = nsObject ? d.object.resolvedSym.modulePath : objType.typeName;
		if (nsModPath != "") {
			const expInfo = findExportedSymbol(ctx.exportRegistry, nsModPath, d.property);
			if (expInfo != null) {
				const memSym = expInfo.sym;
				noteImported(ctx, memSym);
				if (refusesTypeAsValue(ctx, node, memSym, d.property)) return errorType();
				node.resolvedSym = memSym;
				node.nodeType = memSym.symbolType;
				return memSym.symbolType;
			}
			addError(ctx, `Module '${nsObject ? d.object.resolvedSym.name : typeDisplayName(objType)}' has no export '${d.property}'`, node.location.line, node.location.column);
			return inferredType();
		}
	}
	const proxyParts = proxyPartsOf(ctx, objType);
	if (proxyParts != null) return ctx.calleeExpr == node ? inferredType() : readThroughProxy(ctx, node, proxyParts, expectedType);
	// reference parity: strip Ref/Ptr BEFORE field resolution, insert deref AFTER
	// reference: skip pointer types → lookup field → make dereference
	const nullablePtr = objType.kind == TypeKind.Union ? unwrapRefNullUnion(objType) : null;
	let ptrType = (nullablePtr != null && isPointerInC(nullablePtr, ctx)) ? nullablePtr : objType;
	while (ptrType.kind == TypeKind.Cursor && ptrType.typeReturn != null) ptrType = ptrType.typeReturn;
	const needsDeref = isPointerInC(ptrType, ctx);
	let resolvedObjType = objType;
	if (needsDeref) {
		if (ptrType.typeReturn != null) {
			resolvedObjType = ptrType.typeReturn;
			if (resolvedObjType.kind == TypeKind.Ref && resolvedObjType.typeReturn != null) {
				resolvedObjType = resolvedObjType.typeReturn;
			}
		}
	}
	if (resolvedObjType.kind == TypeKind.GenericParam && resolvedObjType.typeExtra != null && !isUnresolvedType(resolvedObjType.typeExtra)) {
		resolvedObjType = resolvedObjType.typeExtra;
	}
	if (isBrandDistinct(resolvedObjType) && resolvedObjType.typeReturn != null) {
		resolvedObjType = resolvedObjType.typeReturn;
	}
	const dotBase = borrowedDotField(resolvedObjType, d.property);
	if (dotBase != null) resolvedObjType = dotBase;
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
	if (resolvedObjType.kind == TypeKind.GenericInstance && resolvedObjType.typeReturn == null) {
		let allConcrete = true;
		for (const tc of resolvedObjType.typeChildren) {
			if (tc != null && hasGenericParams(tc)) { allConcrete = false; break; }
		}
		if (allConcrete) {
			const declParams = genericParamsOf(resolvedObjType);
			if (declParams != "") {
				instantiateGenericBody(resolvedObjType, declParams);
			}
		}
	}
	const fieldOwnerSym = declaringSymOf(resolvedObjType);
	const peeledObjType = peelToStructOrUnion(resolvedObjType);
	if (peeledObjType != null) { resolvedObjType = peeledObjType; }
	const memberOwner = fieldOwnerSym != null ? fieldOwnerSym : resolvedObjType.sym;
	// Static access detection: when the object is a type name (class, type alias, interface, struct),
	// skip instance field resolution — go to static method lookup.
	// Allows field/method name coexistence: result.ok (field) vs Result.ok() (static method).
	// TypeAlias included for patterns like Buffer.alloc() where Buffer is `type Buffer = string`.
	const isStaticClassAccess = isTypeLevelAccess(ctx, d.object, d.property);
	let propType = isStaticClassAccess ? inferredType() : getProperty(resolvedObjType, d.property);
	// Engine (macro-body) view of Node.nodeType: the VM wire carries a type-AST
	// Node tree (mapTypeToAst), not the checker Type the class declares. Type
	// the member as Node so flat reads on it resolve via the NodeData
	// unique-field-name rule below — same contract as reads on the node itself.
	if (isEngineCheckMode() && d.property == "nodeType"
			&& resolvedObjType.typeName == "Node" && !isUnresolvedType(propType)) {
		// objType, not resolvedObjType: a Node-typed VALUE is Ref<Node> everywhere
		// else (isPointerInC peels it above only to resolve the field). Handing back
		// the peeled Struct makes `detectUnionDisc(tt)` fail against its Ref<Node>
		// parameter with the nonsensical "got Node, expected Node".
		propType = objType;
	}
	// Actor isolation: block external field access (only message-passing allowed).
	// Allow access from inside the actor's own methods (ctx.currentActor is its symbol).
	// Allow @nonisolated fields for read access (Swift parity).
	if (!isStaticClassAccess && !isUnresolvedType(propType)) {
		if (fieldOwnerSym != null && fieldOwnerSym.symbolKind == SymbolKind.Actor
			&& ctx.currentActor != fieldOwnerSym
			&& d.property != "pid"
			&& !hasNonisolatedField(fieldOwnerSym, d.property)) {
			addError(ctx, `cannot access actor field '${d.property}' directly — use actor methods`,
				node.location.line, node.location.column);
		}
	}
	if (!isStaticClassAccess && !isUnresolvedType(propType)) {
		const receiver = isSuperReceiver(d.object) ? null : memberOwner;
		refuseMemberAccess(ctx, memberOwner, d.property, receiver, node.location.line, node.location.column);
	}
	// Static property lookup: check class symbol's staticFields
	if (isStaticClassAccess && isUnresolvedType(propType) && d.object.resolvedSym != null) {
		const staticField = findStaticField(d.object.resolvedSym, d.property);
		if (staticField != null) {
			if (ctx.currentFunction == null) {
				for (const pending of ctx.staticBlockPending) {
					if (pending == staticField.declNode) {
						addError(ctx, `property '${d.property}' is used before its initialization`, node.location.line, node.location.column);
					}
				}
			}
			node.resolvedSym = staticField;
			return staticField.symbolType;
		}
	}
	// Class-aware field delegation (system module symbol lookup):
	// When a built-in TypeKind (Promise, Result, etc.) has a typeName but getProperty() can't
	// find the field, look up the global class symbol by name and try field resolution on its struct.
	// For generic classes, substitute class-level generic params (T, E) with concrete types
	// from the actual object (e.g. Result<string, number> → T=string, E=number).
	// Skip for static class access — static methods are found via class method lookup below.
	if (isUnresolvedType(propType) && !isStaticClassAccess && resolvedObjType.typeName != "") {
		const globals = ctx.preludeCtx != null ? ctx.preludeCtx.table : ctx.table;
		const classSym = fieldOwnerSym != null ? fieldOwnerSym : lookupSymbol(globals, resolvedObjType.typeName);
		if (classSym != null) {
			ensureShaped(classSym, ctx);
			let classStruct = classSym.symbolType;
			if (classStruct.kind == TypeKind.Ref && classStruct.typeReturn != null) {
				classStruct = classStruct.typeReturn;
			}
			if (classStruct.kind == TypeKind.Struct) {
				propType = getProperty(classStruct, d.property);
				// Create synthetic resolvedSym for the field (needed by codegen/analyzer)
				if (!isUnresolvedType(propType)) {
					const fieldSym = makeSymbol(d.property, SymbolKind.Property, propType, false);
					fieldSym.state = SymbolState.Shaped;
					inheritContainerInfo(fieldSym, classSym);
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
	if (resolvedObjType.kind == TypeKind.Union) {
		const narrowedObjType = getFlowTypeOfReference(d.object, resolvedObjType);
		// 1-based union variant slot when the access is pinned to a single C offset;
		// stamped on the per-site property sym so codegen routes `.v<slot-1>.field`
		// instead of guessing by field name (which is offset-blind).
		let narrowedSlot = 0;
		const pinnedVariant = narrowedObjType != null && narrowedObjType.kind == TypeKind.Ref && narrowedObjType.typeReturn != null
			? narrowedObjType.typeReturn : narrowedObjType;
		if (narrowedObjType != null && narrowedObjType != resolvedObjType
				&& pinnedVariant != null && pinnedVariant.kind == TypeKind.Struct) {
			const fieldInVariant = findFieldInVariant(pinnedVariant, d.property);
			if (fieldInVariant == null) {
				// The flow graph pinned the reference to ONE variant. Reading a
				// payload field of some OTHER variant through the pinned reference
				// reinterprets bytes — reject. The discriminant itself stays
				// readable: variant structs do not re-declare it (it lives in the
				// union's metadata at a fixed offset), and disc re-reads inside a
				// narrowed block were always legal.
				if (getDiscriminantName(resolvedObjType) != d.property && unionVariantHasProperty(resolvedObjType, d.property)) {
					addError(ctx, `Property '${d.property}' does not exist on type '${typeDisplayName(narrowedObjType)}'. Available: ${pinnedVariant.typeNames.join(", ")}`,
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
				inheritContainerInfo(narrowedSym, memberOwner);
				narrowedSlot = duVariantIndexOfType(resolvedObjType, narrowedObjType) + 1;
				narrowedSym.duVariantSlot = narrowedSlot;
				node.resolvedSym = narrowedSym;
				sgRecordSym(ctx, node.location.line, node.location.column + 1, node.location.column + 1 + d.property.length, narrowedSym, fieldInVariant, SymbolKind.Property, d.property, resolvedObjType.typeName, false);
			}
		} else if (narrowedObjType != null && narrowedObjType != resolvedObjType
				&& narrowedObjType.kind == TypeKind.Union
				&& !duFieldRequiresNarrowing(narrowedObjType, d.property)) {
			// Narrowed to a sub-union whose remaining variants lay the field at ONE
			// offset — any of their slots in the full union is byte-correct; use the first.
			const subIdx = findVariantByFieldName(narrowedObjType, d.property);
			if (subIdx >= 0) {
				const fullIdx = duVariantIndexOfType(resolvedObjType, narrowedObjType.typeChildren[subIdx]);
				if (fullIdx >= 0) {
					const subSym = makeSymbol(d.property, SymbolKind.Property, propType, false);
					subSym.state = SymbolState.Shaped;
					inheritContainerInfo(subSym, memberOwner);
					narrowedSlot = fullIdx + 1;
					subSym.duVariantSlot = narrowedSlot;
					node.resolvedSym = subSym;
					sgRecordSym(ctx, node.location.line, node.location.column + 1, node.location.column + 1 + d.property.length, subSym, propType, SymbolKind.Property, d.property, resolvedObjType.typeName, false);
				}
			}
		}
		// Un-narrowed access has no single correct read unless EVERY variant
		// declares the field with an identical layout: differing offsets across
		// declaring variants, or a field only a strict subset declares, both
		// reinterpret the active variant's bytes. Reject instead of reading
		// another variant's storage. No disc gate: structural no-disc unions
		// route through v<N> in C just the same.
		//
		// flowNode gate: a reference that was never flow-bound has no program
		// point to judge narrowing at — this is the signature of nodes the
		// macro bridge deserialized into a macro expansion (valueToNode
		// rebuilds fresh nodes; their flowNode is null while the ORIGINAL arg,
		// checked at its source site, carried the binding). Synthetic
		// checker-built nodes likewise. Real source references are always
		// bound by src/binder/, so the gate never silences a genuine read.
		if (narrowedSlot == 0 && !isUnresolvedType(propType)
				&& d.object.flowNode != null
				&& duFieldRequiresNarrowing(resolvedObjType, d.property)) {
			if (duSharedFieldOffsetDiffers(resolvedObjType, d.property)) {
				addError(ctx, `field '${d.property}' sits at different offsets across variants of '${typeDisplayName(resolvedObjType)}' — narrow with match/if on the discriminant before accessing it`,
					node.location.line, node.location.column);
			} else if (duSharedFieldSlotDiffers(resolvedObjType, d.property)) {
				addError(ctx, `field '${d.property}' is stored inline in some variants of '${typeDisplayName(resolvedObjType)}' and behind a reference in others — narrow with match/if on the discriminant before accessing it`,
					node.location.line, node.location.column);
			} else {
				addError(ctx, `field '${d.property}' exists only on some variants of '${typeDisplayName(resolvedObjType)}' — narrow with match/if on the discriminant before accessing it`,
					node.location.line, node.location.column);
			}
		}
		// A DU-typed field must carry a per-site property sym whose symbolType is the
		// DECLARED field type: a chained access (x.f.g where f is a DU) recovers its
		// v<N> index space from this sym at codegen, while the node's own nodeType may
		// be flow-narrowed to a single variant below. Scoped to DU-typed fields only —
		// blanket syms shift analyzer/DCE aliveness (self-host link regression).
		if (node.resolvedSym == null && !isUnresolvedType(propType)) {
			const peeledProp = peelToStructOrUnion(propType);
			if (peeledProp != null && peeledProp.kind == TypeKind.Union) {
				const unionFieldSym = makeSymbol(d.property, SymbolKind.Property, propType, false);
				unionFieldSym.state = SymbolState.Shaped;
				inheritContainerInfo(unionFieldSym, memberOwner);
				node.resolvedSym = unionFieldSym;
			}
		}
	}
	if (!isUnresolvedType(propType)) {
		// reference parity: insert HiddenDeref AFTER field resolution succeeds
		if (needsDeref && d.object.kind != NodeKind.HiddenDeref) {
			const tok = createToken(TokenKind.Ident, "", node.location.line);
			const derefNode = createNode(NodeKind.HiddenDeref, { expr: d.object }, tok);
			if (ptrType.typeReturn != null) {
				const pointee = ptrType.typeReturn;
				derefNode.nodeType = ptrType.kind == TypeKind.Ptr && pointee.kind == TypeKind.Ref && pointee.typeReturn != null ? pointee.typeReturn : pointee;
			} else {
				derefNode.nodeType = resolvedObjType;
			}
			d.object = derefNode;
		}
		// Standard reference parity: search the type's field list
		// (lookupInRecordAndBuildCheck pattern).
		if (node.resolvedSym == null && resolvedObjType.typeNames != null) {
			let mi = 0;
			for (const mName of resolvedObjType.typeNames) {
				if (mName == d.property) {
					const isUnionMeta = resolvedObjType.kind == TypeKind.Union;
					const symTy = isUnionMeta ? propType : resolvedObjType.typeChildren[mi];
					const synthSym = makeSymbol(mName, SymbolKind.Property, symTy, false);
					synthSym.state = SymbolState.Shaped;
					if (!isUnionMeta && symTy.typeName != "") {
						synthSym.nativeName = symTy.typeName;
					}
					inheritContainerInfo(synthSym, memberOwner);
					node.resolvedSym = synthSym;
					sgRecordSym(ctx, node.location.line, node.location.column + 1, node.location.column + 1 + mName.length, synthSym, symTy, SymbolKind.Property, mName, resolvedObjType.typeName, false);
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
		// identifier arm's definiteTarget rule, applied to the member write.
		// Inside `if (x.f === null) { x.f = [] }` the RHS otherwise gets `null`
		// as its contextual type and the literal never finds its donor.
		if (node == ctx.initTracker.definiteTarget) {
			return propType;
		}
		const narrowed = getFlowTypeOfReference(node, propType);
		return narrowed != null ? narrowed : propType;
	}

	// Builtin properties: .length on array/string
	if (d.property == "length" && (resolvedObjType.kind == TypeKind.Array || resolvedObjType.kind == TypeKind.SizedArray || resolvedObjType.kind == TypeKind.Span || isStringLike(resolvedObjType) || resolvedObjType.kind == TypeKind.CString)) {
		// Create a synthetic symbol for 'length' to satisfy the validator
		const lengthSym = makeSymbol("length", SymbolKind.Property, int32Type(), false);
		lengthSym.state = SymbolState.Shaped;
		node.resolvedSym = lengthSym;
		if (needsDeref && resolvedObjType.kind == TypeKind.Array) {
			const tok = createToken(TokenKind.Ident, "", node.location.line);
			const derefNode = createNode(NodeKind.HiddenDeref, { expr: d.object }, tok);
			derefNode.nodeType = resolvedObjType;
			d.object = derefNode;
		}
		return int32Type();
	}
	// String .code — compile-time char code, folded by constantFolding transform
	if (d.property == "code" && resolvedObjType.kind == TypeKind.String) {
		const codeSym = makeSymbol("code", SymbolKind.Property, int32Type(), false);
		codeSym.state = SymbolState.Shaped;
		node.resolvedSym = codeSym;
		return int32Type();
	}
	// String-specific properties: .byteLength, .unicodeLength
	// Skip when accessed on a TYPE (e.g., Buffer.byteLength(json)) — that's a static extension call.
	// Only resolve as property when accessed on an instance (e.g., str.byteLength).
	if ((d.property == "byteLength" || d.property == "unicodeLength") && resolvedObjType.kind == TypeKind.String) {
		const isTypeAccess = d.object.resolvedSym != null
			&& (d.object.resolvedSym.symbolKind == SymbolKind.TypeAlias
				|| d.object.resolvedSym.symbolKind == SymbolKind.Class
				|| d.object.resolvedSym.symbolKind == SymbolKind.Actor
				|| d.object.resolvedSym.symbolKind == SymbolKind.Interface);
		if (!isTypeAccess) {
			const propSym = makeSymbol(d.property, SymbolKind.Property, int32Type(), false);
			propSym.state = SymbolState.Shaped;
			node.resolvedSym = propSym;
			return int32Type();
		}
	}
	// Map/Set methods — resolved via class-aware field delegation bridge below.
	// No hardcoded dispatch: Map and Set classes declare @builtin methods in std/core/structure.

	if (isUnresolvedType(propType) && ctx.inGenericContext > 0 && resolvedObjType.kind == TypeKind.GenericParam) return propType;
	// Class method lookup: the method the class Symbol declares under this name.
	// Filters by static/instance: static access (SymbolKind.Class) only matches static methods,
	// instance access only matches instance methods. Checks overloads if primary doesn't match.
	if (resolvedObjType.typeName != "") {
		const declaredMethod = fieldOwnerSym != null ? dispatchMethodOf(fieldOwnerSym, d.property) : null;
		let classMethSym: Symbol | null = declaredMethod != null ? declaredMethod.sym : null;
		// Filter: instance methods have "this" as first param, static methods don't.
		// If the found symbol doesn't match the access type, check overloads for one that does.
		if (classMethSym != null && classMethSym.symbolKind == SymbolKind.Function) {
			const wantInstance = !isStaticClassAccess;
			if (hasThisParam(classMethSym) != wantInstance) {
				let found = false;
				for (const ov of classMethSym.overloads) {
					if (hasThisParam(ov) == wantInstance) { classMethSym = ov; found = true; break; }
				}
				if (!found) classMethSym = null as unknown as Symbol;
			}
		}
		if (classMethSym != null && classMethSym.symbolKind == SymbolKind.Function) {
			ensureShaped(classMethSym, ctx);
			callDemandReturn(ctx, classMethSym, node);
			node.resolvedSym = classMethSym;
			sgRecordSym(ctx, node.location.line, node.location.column + 1, node.location.column + 1 + d.property.length, classMethSym, classMethSym.symbolType, SymbolKind.Method, d.property, resolvedObjType.typeName, false);
			// Strip receiver param (index 0) for instance methods only — static methods have no "this"
			const methType = classMethSym.symbolType;
			if (methType.kind == TypeKind.Function && methType.typeChildren.length > 0 && methType.typeNames.length > 0 && methType.typeNames[0] == "this") {
				// Generic class method substitution: unify receiver (e.g. Promise<T>) with
				// actual object type (e.g. Promise<string>) to discover T → string,
				// then substitute in parameter/return types.
				const receiverType = methType.typeChildren[0];
				if ((isReadonlyView(objType) || isReadonlyView(resolvedObjType)) && !isReadonlyView(receiverType)) {
					refuseReadonlyViewCall(ctx, node, d.property, objType, typeNameOf(receiverType));
				}
				const eb = createUnifyBindings();
				if (hasGenericParams(receiverType)) {
					unifyType(receiverType, objType, eb);
				}
				// Generic class instance method: monomorphize the method body with the
				// discovered bindings and point the call at the mono'd symbol (mirrors the
				// extension-method instantiation path below).
				if (eb.names.length > 0 && classMethSym.builtinKind == "" && classMethSym.declNode != null && !isGenericInstanceMethod(classMethSym)) {
					const instSym = callInstantiateGeneric(classMethSym, eb.params, eb.types, ctx, node.location);
					if (instSym != null) {
						ensureShaped(instSym, ctx);
						node.resolvedSym = instSym;
					}
				}
				let callParams: Type[] = [];
				const callNames: string[] = [];
				for (let ci = 1; ci < methType.typeChildren.length; ci += 1) {
					callParams.push(substituteBound(methType.typeChildren[ci], eb));
				}
				for (let ci = 1; ci < methType.typeNames.length; ci += 1) {
					callNames.push(methType.typeNames[ci]);
				}
				return createFunction(callParams, callNames, substituteBound(methType.typeReturn, eb));
			}
			return methType;
		}
	}
	// Fall back to extension registry — standard-aligned type-based lookup
	if (ctx.extensionRegistry != null) {
		const allByName = boundExtensions(node, findAllExtensionsByName(ctx.extensionRegistry, d.property));
		const recvLookupType = withoutReadonlyView(objType);
		let ext = isStaticClassAccess ? null as unknown as ExtensionMethod : findFirstMatchingExt(allByName, recvLookupType);
		let extObjType = recvLookupType;
		const narrowedDeclared = ext == null ? declaredUnionOfNarrowed(d.object) : null;
		if (narrowedDeclared != null) {
			ext = findFirstMatchingExt(allByName, narrowedDeclared);
			if (ext != null) {
				extObjType = narrowedDeclared;
				d.object.nodeType = narrowedDeclared;
			}
		}
		// reference array: UFCS methods (push/slice/...) are declared on the value
		// Array receiver; a Ref<Array> must deref before the lookup matches. Insert a
		// HiddenDeref so codegen sees through the Ref, and unify generics on the
		// unwrapped Array so T binds (mirrors the class-method deref path above).
		if (ext == null && !isStaticClassAccess && needsDeref && (resolvedObjType.kind == TypeKind.Array || resolvedObjType.kind == TypeKind.SizedArray || resolvedObjType.kind == TypeKind.Span)) {
			const derefExt = findFirstMatchingExt(allByName, resolvedObjType);
			if (derefExt != null) {
				ext = derefExt;
				extObjType = resolvedObjType;
				const tok = createToken(TokenKind.Ident, "", node.location.line);
				const derefNode = createNode(NodeKind.HiddenDeref, { expr: d.object }, tok);
				derefNode.nodeType = resolvedObjType;
				d.object = derefNode;
			}
		}
		if (ext == null && isStaticClassAccess && d.object.resolvedSym != null) {
			const owned = staticExtsOwnedBy(ctx, allByName, d.object.resolvedSym, objType);
			if (owned.length > 0) ext = owned[0];
		}
		if (ext != null) {
			// Direct sym link — no name-based lookup needed
			if (ext.sym != null) {
				ensureShaped(ext.sym, ctx);
				callDemandReturn(ctx, ext.sym, node);
				node.resolvedSym = ext.sym;
				markUsedIn(ctx, ext.sym);
				sgRecordSym(ctx, node.location.line, node.location.column + 1, node.location.column + 1 + d.property.length, ext.sym, getExtFnType(ext), SymbolKind.Method, d.property, extReceiverDisplay(ext), false);
			}
			// Instance extension: strip receiver param (index 0) so checkCallExpr
			// sees only user-visible params. The receiver is already in MemberExpr.object.
			const extFnT = getExtFnType(ext);
			const arrayView = resolvedObjType.kind == TypeKind.Array || resolvedObjType.kind == TypeKind.SizedArray || resolvedObjType.kind == TypeKind.Span;
			if (!ext.isStatic && isReadonlyView(objType) && arrayView && extFnT.typeChildren.length > 0
					&& writesThroughReceiver(skipModifier(extFnT.typeChildren[0]) ?? extFnT.typeChildren[0])) {
				addError(ctx, "'" + d.property + "' mutates its receiver, and " + typeDisplayName(objType) + " is a read-only view (PARALOCK E24)", node.location.line, node.location.column);
			}
			if (!ext.isStatic && isReadonlyView(objType) && !arrayView
					&& !(extFnT.typeChildren.length > 0 && isReadonlyView(extFnT.typeChildren[0]))) {
				refuseReadonlyViewCall(ctx, node, d.property, objType, extReceiverDisplay(ext));
			}
			if (!ext.isStatic && extFnT.typeChildren.length > 0) {
				let srcType = extFnT;
				// Check for generics: either type-level (hasGenericParams) or flag-level (gen: in fnFlags)
				const symHasGenerics = hasGenericParams(srcType) || (ext.sym != null && ext.sym.declNode != null && ext.sym.declNode.kind == NodeKind.FunctionDecl && isGenericFn((ext.sym.declNode.data as FunctionDeclData).fnFlags));
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
					if (recvParam.kind == TypeKind.Ref && recvParam.typeReturn != null && recvParam.typeReturn.kind == TypeKind.Array) recvParam = recvParam.typeReturn;
					if (unifyObj.kind == TypeKind.Ref && unifyObj.typeReturn != null && unifyObj.typeReturn.kind == TypeKind.Array) unifyObj = unifyObj.typeReturn;
					unifyType(recvParam, unifyObj, eb);
					if (eb.names.length > 0) {
						// On-demand instantiation (generateInstance pattern)
						// Clone the generic function, substitute types, register specialized version
						if (ext.sym != null && ext.sym.declNode != null && ext.sym.builtinKind == "" && bindingsCoverDecl(eb, ext.sym.declNode)) {
							const instSym = callInstantiateGeneric(ext.sym, eb.params, eb.types, ctx, node.location);
							if (instSym != null) {
								node.resolvedSym = instSym;
							}
						}
						srcType = substituteBound(srcType, eb);
					}
				}
				return stripReceiverParam(srcType);
			}
			return extFnT;
		}
	}
	if (isUnresolvedType(propType) && !d.isOptional && !isUnresolvedType(resolvedObjType) && resolvedObjType.kind != TypeKind.Error) {
		if (ctx.initTracker.leftPartOfAsgn > 0) {
			if (findAccessor(ctx, objType, "set_" + d.property) != null || findAccessor(ctx, objType, "get_" + d.property) != null) return propType;
		} else if (findAccessor(ctx, objType, "get_" + d.property) != null) {
			return callGetter(ctx, node, d);
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
	const resolvedPerInstance = ctx.inGenericContext > 0 && hasGenericParams(resolvedObjType);
	if (isUnresolvedType(propType)
			&& !resolvedPerInstance
			&& !isUnresolvedType(resolvedObjType)
			&& resolvedObjType.kind != TypeKind.Error
			&& !unionVariantHasProperty(resolvedObjType, d.property)
			&& d.property != "getDynamicField"
			&& ctx.initTracker.leftPartOfAsgn == 0
			&& !d.isOptional
			&& ctx.extensionRegistry != null) {
		// Fast-fail: O(1) registry lookup — skip synthesis if no `getDynamicField` extension exists for this type.
		const dynExts = findAllExtensionsByName(ctx.extensionRegistry, "getDynamicField");
		if (dynExts.length > 0) {
			const dynExt = findFirstMatchingExt(dynExts, objType);
			if (dynExt != null) {
				const loc = node.location;
				const memberNode = createNodeAt(NodeKind.MemberExpr,
					{ object: d.object, property: "getDynamicField", isOptional: false }, loc);
				const keyLit = createNodeAt(NodeKind.StringLiteral,
					{ value: d.property }, loc);
				const synthCall = createNodeAt(NodeKind.CallExpr,
					{ callee: memberNode, arguments: [keyLit], isDirectCall: true, resolvedOverloadIdx: -1 }, loc);
				callCheckExpr(ctx, synthCall, null);
				if (synthCall.nodeType != null
						&& synthCall.nodeType.kind != TypeKind.Error
						&& !isUnresolvedType(synthCall.nodeType)) {
					// Rewrite this MemberExpr in-place to the synthesized CallExpr.
					// Caller holds a reference to `node`; we mutate kind/data/type/flags so they see the call.
					// Flags carry NodeFlag.ExtCall set by checkCallExpr — codegen reads it to emit
					// extension-method calling convention instead of closure dispatch.
					node.kind = NodeKind.CallExpr;
					node.data = synthCall.data;
					node.nodeType = synthCall.nodeType;
					node.flags = synthCall.flags;
					node.variantSlot = synthCall.variantSlot;
					if (synthCall.resolvedSym != null) {
						node.resolvedSym = synthCall.resolvedSym;
					}
					return synthCall.nodeType;
				}
			}
		}
	}

	if (isUnresolvedType(propType)
			&& !isUnresolvedType(resolvedObjType)
			&& resolvedObjType.kind != TypeKind.Error
			&& d.property != "valueOf"
			&& ctx.initTracker.leftPartOfAsgn == 0
			&& !d.isOptional
			&& valueOfInPlace(ctx, d.object)) {
		return checkMemberExpr(ctx, node, expectedType);
	}
	// Universal .toString() — every type has a compiler-provided default.
	// builtinLower resolves to the correct C function per type.
	// Return the function type (not string) so CallExpr extracts the return type.
	// Numeric types accept optional radix: .toString() or .toString(36)
	if (d.property == "toString" && isUnresolvedType(propType)) {
		if (distinctBody(resolvedObjType) != null) addError(ctx, distinctTextRefusal(resolvedObjType), node.location.line, node.location.column);
		let toStrFnType: Type | null = null;
		if (isNumeric(widenNumberLiteralType(resolvedObjType))) {
			toStrFnType = createFunction([int32Type()], ["radix"], stringType());
			setMinArity(toStrFnType, 0);
		} else {
			toStrFnType = createFunction([], [], stringType());
		}
		const toStrSym = makeSymbol("toString", SymbolKind.Function, toStrFnType, false);
		toStrSym.builtinKind = "ToStringMethod";
		toStrSym.modulePath = ctx.modulePath;
		stampItem(ctx, toStrSym);
		toStrSym.state = SymbolState.Shaped;
		node.resolvedSym = toStrSym;
		return toStrFnType;
	}
	// Unresolved member access — emit error with field suggestion if available
	const propertyActuallyExists = resolvedObjType.typeNames != null && resolvedObjType.typeNames.indexOf(d.property) >= 0;
	if (isUnresolvedType(propType) && !resolvedPerInstance && !isUnresolvedType(resolvedObjType) && !propertyActuallyExists) {
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
		if (!realFieldOnAlias && resolvedObjType.typeName != "") {
			const aliasSym = lookupSymbol(ctx.table, resolvedObjType.typeName);
			if (aliasSym != null) {
				ensureShaped(aliasSym, ctx);
				let inner = aliasSym.symbolType;
				let _h = 0;
				while (inner != null && _h < 4) {
					_h = _h + 1;
					if (inner.kind == TypeKind.Alias && inner.typeReturn != null) { inner = inner.typeReturn; continue; }
					if (inner.kind == TypeKind.Ref && inner.typeReturn != null) { inner = inner.typeReturn; continue; }
					break;
				}
				if (inner != null && (inner.kind == TypeKind.Struct || inner.kind == TypeKind.Union)
						&& !isUnresolvedType(getProperty(inner, d.property))) {
					realFieldOnAlias = true;
				}
			}
		}
		// Also try `objType.sym` (the un-resolved receiver) — alias parameters
		// often expose the declaration via this back-pointer even when typeName
		// was lost during peeling above.
		if (!realFieldOnAlias && objType.sym != null) {
			ensureShaped(objType.sym, ctx);
			let symType = objType.sym.symbolType;
			let _h2 = 0;
			while (symType != null && _h2 < 4) {
				_h2 = _h2 + 1;
				if (symType.kind == TypeKind.Alias && symType.typeReturn != null) { symType = symType.typeReturn; continue; }
				if (symType.kind == TypeKind.Ref && symType.typeReturn != null) { symType = symType.typeReturn; continue; }
				break;
			}
			if (symType != null && (symType.kind == TypeKind.Struct || symType.kind == TypeKind.Union)
					&& !isUnresolvedType(getProperty(symType, d.property))) {
				realFieldOnAlias = true;
			}
		}
		let suppressDynWrite = false;
		if (!realFieldOnAlias
				&& ctx.initTracker.leftPartOfAsgn > 0
				&& d.property != "setDynamicField"
				&& ctx.extensionRegistry != null) {
			const setExts = findAllExtensionsByName(ctx.extensionRegistry, "setDynamicField");
			for (const e of setExts) {
				if (extDeclaresReceiver(e, objType) || extDeclaresReceiver(e, resolvedObjType)) { suppressDynWrite = true; break; }
			}
		}
		// Disc re-read on a positively-narrowed DU variant: the object's flow
		// type is a bare variant Struct, and enum-disc match-type variants never
		// carry the disc field — resolve it against the DECLARED union's
		// discriminant contract instead of erroring.
		if (d.object.resolvedSym != null && d.object.resolvedSym.symbolType != null) {
			const declaredDu = peelToStructOrUnion(d.object.resolvedSym.symbolType);
			if (declaredDu != null && isDiscriminatedUnion(declaredDu)
					&& getDiscriminantName(declaredDu) == d.property
					&& declaredDu.typeExtra != null) {
				d.object.nodeType = d.object.resolvedSym.symbolType;
				return declaredDu.typeExtra;
			}
		}
		const engineVirtual = resolveEngineNodeVirtualProp(ctx, resolvedObjType, d.property, node);
		if (engineVirtual != null) return engineVirtual;
		if (!suppressDynWrite) {
			const typeName = typeDisplayName(resolvedObjType);
			let suggestion = "";
			if (resolvedObjType.typeNames != null) {
				for (const fn of resolvedObjType.typeNames) {
					if (fn != d.property && fn.length > 0) {
						if (suggestion == "") { suggestion = fn; }
						else { suggestion = suggestion + ", " + fn; }
					}
				}
			}
			if (suggestion != "") {
				addError(ctx, `Property '${d.property}' does not exist on type '${typeName}'. Available: ${suggestion}`, node.location.line, node.location.column);
			} else {
				addError(ctx, `Property '${d.property}' does not exist on type '${typeName}'`, node.location.line, node.location.column);
			}
		}
	}
	return propType;
}

function callGetter(ctx: CheckerContext, node: Node, d: MemberExprData): Type {
	const getterMember = createNodeAt(NodeKind.MemberExpr, { object: d.object, property: "get_" + d.property, isOptional: false }, node.location);
	const call = createNodeAt(NodeKind.CallExpr, { callee: getterMember, arguments: [], isDirectCall: true, resolvedOverloadIdx: -1 }, node.location);
	callCheckExpr(ctx, call, null);
	node.kind = NodeKind.CallExpr;
	node.data = call.data;
	node.nodeType = call.nodeType;
	node.flags = call.flags;
	node.variantSlot = call.variantSlot;
	if (call.resolvedSym != null) node.resolvedSym = call.resolvedSym;
	return call.nodeType!;
}

// The wire flattens SourceLocation onto the node, so these names carry no
// declaration of their own; their type is SourceLocation's, read from it here
// rather than spelled again — spelling it as `number` is what let the engine
// view disagree with the source until a narrowing rule made it fatal.
function borrowedDotField(t: Type, name: string): Type | null {
	let base = borrowedDotBase(t);
	if (base == null) return null;
	let next = borrowedDotBase(base);
	while (next != null) {
		base = next;
		next = borrowedDotBase(base);
	}
	const fields = peelToStructOrUnion(base);
	return isUnresolvedType(getProperty(fields != null ? fields : base, name)) ? null : base;
}

function flattenedLocationFieldType(recvType: Type, name: string): Type | null {
	if (name != "line" && name != "column" && name != "endLine" && name != "endColumn") return null;
	if (recvType.typeNames == null || recvType.typeChildren == null) return int32Type();
	let i = 0;
	while (i < recvType.typeNames.length) {
		if (recvType.typeNames[i] == "location" && i < recvType.typeChildren.length) {
			const loc = peelToStructOrUnion(recvType.typeChildren[i]);
			if (loc == null || loc.typeNames == null || loc.typeChildren == null) break;
			let j = 0;
			while (j < loc.typeNames.length) {
				if (loc.typeNames[j] == name && j < loc.typeChildren.length) {
					return loc.typeChildren[j];
				}
				j = j + 1;
			}
			break;
		}
		i = i + 1;
	}
	return int32Type();
}

interface EngineNodeDataField {
	fieldType: Type | null;
	ambiguous: boolean;
}

function engineNodeDataField(recvType: Type, name: string): EngineNodeDataField {
	const missing: EngineNodeDataField = { fieldType: null, ambiguous: false };
	if (recvType.typeNames == null || recvType.typeChildren == null) return missing;
	let dataType: Type | null = null;
	let fi = 0;
	while (fi < recvType.typeNames.length) {
		if (recvType.typeNames[fi] == "data" && fi < recvType.typeChildren.length) {
			dataType = recvType.typeChildren[fi];
			break;
		}
		fi = fi + 1;
	}
	if (dataType == null) return missing;
	const dataUnion = peelToStructOrUnion(dataType);
	if (dataUnion == null || dataUnion.kind != TypeKind.Union || dataUnion.typeChildren == null) return missing;
	let found: Type | null = null;
	let conflict = false;
	for (const variantRaw of dataUnion.typeChildren) {
		const variant = peelToStructOrUnion(variantRaw);
		if (variant == null || variant.typeNames == null || variant.typeChildren == null) continue;
		let vi = 0;
		while (vi < variant.typeNames.length) {
			if (variant.typeNames[vi] == name && vi < variant.typeChildren.length) {
				const ft = variant.typeChildren[vi];
				if (found == null) {
					found = ft;
				} else if (typeDisplayName(found) != typeDisplayName(ft)) {
					conflict = true;
				}
			}
			vi = vi + 1;
		}
	}
	return { fieldType: found, ambiguous: conflict };
}

// The macro VM's wire format flattens NodeData payload fields onto the Node
// object (expand.ms nodeToASTLiteral / bridge.ms). Inside engine compiles,
// resolve those flat reads against the NodeData union declaration: a field
// name unique across variants (or shared with one type) types directly;
// same name with different types must be narrowed first (LANG.md "unique
// field name" DU access rule).
export function engineNodeHasVirtualKey(recvType: Type | null, key: string): boolean {
	if (!isEngineCheckMode()) return false;
	if (recvType == null || recvType.typeName != "Node") return false;
	if (flattenedLocationFieldType(recvType, key) != null) return true;
	// bindSym bake splices Identifier literals carrying the bound-symbol handle;
	// valueToNode consumes it — never a real Node field.
	if (key == "symHandle" || key == "typeHandle" || key == "gensym") return true;
	return engineNodeDataField(recvType, key).fieldType != null;
}

export function engineNodeVirtualKeyType(recvType: Type | null, key: string): Type | null {
	if (!isEngineCheckMode()) return null;
	if (recvType == null || recvType.typeName != "Node") return null;
	const locField = flattenedLocationFieldType(recvType, key);
	if (locField != null) return locField;
	const df = engineNodeDataField(recvType, key);
	if (df.ambiguous) return null;
	return df.fieldType;
}

export function engineReturnMarshalsToNode(actual: Type | null, expected: Type | null): boolean {
	if (!isEngineCheckMode()) return false;
	if (actual == null || expected == null) return false;
	const wanted = unwrapRef(expected);
	if (typeNameOf(expected) != "Node" && (wanted == null || typeNameOf(wanted) != "Node")) return false;
	if (isNumeric(actual) || isStringLike(actual)) return true;
	if (actual.kind == TypeKind.Boolean || actual.kind == TypeKind.Null) return true;
	const bare = unwrapRef(actual);
	return bare != null && (bare.kind == TypeKind.Array || bare.kind == TypeKind.SizedArray);
}

export function engineIsCompileErrorSentinel(node: Node | null): boolean {
	if (node == null) return false;
	if (!isEngineCheckMode()) return false;
	if (node.kind != NodeKind.ObjectLiteral) return false;
	const d = node.data as ObjectLiteralData;
	if (d.keys == null) return false;
	if (d.keys.length == 0) return false;
	return d.keys[0] == "__compileError";
}

function resolveEngineNodeVirtualProp(ctx: CheckerContext, recvType: Type, prop: string, node: Node): Type | null {
	if (!isEngineCheckMode()) return null;
	if (recvType.typeName != "Node") return null;
	const locField = flattenedLocationFieldType(recvType, prop);
	if (locField != null) return locField;
	const dataField = engineNodeDataField(recvType, prop);
	const found = dataField.fieldType;
	if (found == null) return null;
	if (dataField.ambiguous) {
		addError(ctx, `field '${prop}' has different types across Node variants — narrow with a kind check or '.data as <Kind>Data' before accessing it`, node.location.line, node.location.column);
		return inferredType();
	}
	return found;
}

export function checkMatchExpr(ctx: CheckerContext, node: Node, expectedType: Type | null): Type {
	const d = node.data as MatchExprData;
	const asStatement = node == ctx.stmtPosExpr;
	callCheckExpr(ctx, d.matchDisc, null);
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
	if (d.matchDisc.kind == NodeKind.MemberExpr) {
		const discMd = d.matchDisc.data as MemberExprData;
		if (discMd.object != null && discMd.object.kind == NodeKind.Identifier) {
			const baseSym = lookupSymbol(ctx.table, (discMd.object.data as IdentifierData).name);
			if (baseSym != null && baseSym.symbolType != null) {
				const di = detectUnionDiscriminant(baseSym.symbolType, discMd.property);
				if (di.discField != "") {
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
		const hasGuard = cd.caseGuard != null;
		for (const p of cd.casePatterns) {
			if (p.kind == NodeKind.Identifier) {
				const id = p.data as IdentifierData;
				if (id.name != "_") {
					const sym = lookupSymbol(ctx.table, id.name);
					if (sym != null && sym.symbolKind == SymbolKind.Variable && !hasFlag(sym, SymbolFlag.Mutable)) {
						p.resolvedSym = sym;
						callCheckExpr(ctx, p, discType);
						continue;
					}
				}
				if (refusesTypeArm(ctx, p, d.matchDisc)) continue;
				if (!hasGuard) hasWildcard = true;
				p.nodeType = discType;
			} else {
				const patternKind = p.kind;
				// Extract enum member name — only unguarded arms count for exhaustiveness
				let coveredName = "";
				let covers = false;
				if (patternKind == NodeKind.MemberExpr && !hasGuard) { coveredName = (p.data as MemberExprData).property; covers = true; }
				// Tier 2: collect string literal patterns for exhaustiveness
				if (patternKind == NodeKind.StringLiteral && !hasGuard) { coveredName = (p.data as StringLiteralData).value; covers = true; }
				if (patternKind == NodeKind.BooleanLiteral && !hasGuard) { coveredName = (p.data as BooleanLiteralData).boolValue ? "true" : "false"; covers = true; }
				const errorsBeforeCheck = ctx.errors.length;
				if (kindArmHandled(ctx, d.matchDisc, p)) { callCheckExpr(ctx, p, null); continue; }
				callCheckExpr(ctx, p, discType);
				const errorsBeforePattern = ctx.errors.length;
				if (errorsBeforePattern == errorsBeforeCheck && (patternKind == NodeKind.MemberExpr || patternKind == NodeKind.StringLiteral
					|| patternKind == NodeKind.NumberLiteral || patternKind == NodeKind.BooleanLiteral)) {
					checkSwitchCase(ctx, d.matchDisc, p);
				}
				if (covers && ctx.errors.length == errorsBeforePattern) coveredMembers.push(coveredName);
			}
		}
		// Phase 4: per-arm variant narrowing flows through the binder's
		// synthesizeMatchArmFlow → TrueCondition → getFlowTypeOfReference path.
		// The checker no longer needs to push/pop narrowing state here.

		// Type-check guard expression with narrowing active
		if (cd.caseGuard != null) {
			callCheckExpr(ctx, cd.caseGuard, null);
		}
		let bodyType = inferredType();
		if (cd.caseBody.kind == NodeKind.BlockStmt && asStatement) {
			callCheckStmt(ctx, cd.caseBody);
		} else if (cd.caseBody.kind == NodeKind.BlockStmt) {
			const outerArmExpected = ctx.matchArmExpected;
			ctx.matchArmExpected = expectedType;
			ctx.matchExprDepth = ctx.matchExprDepth + 1;
			callCheckStmt(ctx, cd.caseBody);
			ctx.matchExprDepth = ctx.matchExprDepth - 1;
			ctx.matchArmExpected = outerArmExpected;
			const bd = cd.caseBody.data as BlockStmtData;
			if (bd.statements.length > 0) {
				const last = bd.statements[bd.statements.length - 1];
				if (last.kind == NodeKind.ReturnStmt) {
					const rd = last.data as ReturnStmtData;
					if (rd.argument != null && rd.argument.nodeType != null) {
						bodyType = rd.argument.nodeType;
					}
				}
			}
		} else {
			callCheckExpr(ctx, cd.caseBody, expectedType); if (cd.caseBody.nodeType != null) { bodyType = cd.caseBody.nodeType; }
		}

		branchInits.push(collectNewInits(ctx.initTracker, oldState));
		branchBreaks.push(breaksBlock(cd.caseBody));
		branchBodyTypes.push(bodyType);
		if (isUnresolvedType(returnType) && !isUnresolvedType(bodyType)) {
			returnType = bodyType;
		}
	}
	let matchJoined: Type | null = null;
	const armValues: Node[] = [];
	for (const c of d.matchCases) armValues.push(matchArmValue(c.data as MatchCaseData, asStatement));
	adoptLiteralArms(ctx, armValues);
	for (let ai = 0; ai < armValues.length && ai < branchBodyTypes.length; ai += 1) {
		if (armValues[ai] != null && armValues[ai].nodeType != null) branchBodyTypes[ai] = armValues[ai].nodeType;
	}
	const joined = joinBranchTypes(branchBodyTypes);
	if (!isUnresolvedType(joined)) { matchJoined = joined; returnType = joined; }
	for (const c of d.matchCases) {
		const cd = c.data as MatchCaseData;
		if (cd.caseBody.kind == NodeKind.BlockStmt && asStatement) continue;
		if (cd.caseBody.kind == NodeKind.BlockStmt) {
			const bd = cd.caseBody.data as BlockStmtData;
			if (bd.statements.length > 0) {
				const last = bd.statements[bd.statements.length - 1];
				if (last.kind == NodeKind.ReturnStmt) {
					const rd = last.data as ReturnStmtData;
					if (rd.argument != null) {
						retypeEmptyArrayBranch(rd.argument, returnType);
						if (matchJoined != null) rd.argument = fitJoinedBranch(ctx, rd.argument, matchJoined);
					}
				}
			}
		} else {
			retypeEmptyArrayBranch(cd.caseBody, returnType);
			if (matchJoined != null) cd.caseBody = fitJoinedBranch(ctx, cd.caseBody, matchJoined);
		}
	}
	checkDuplicatePatterns(ctx, d.matchCases);

	// Match is exhaustive if has wildcard (_) or covers all enum members / string DU variants
	let isExhaustive = hasWildcard;
	if (!isExhaustive && discType.kind == TypeKind.Enum) {
		let allCovered = true;
		for (const member of discType.typeNames) {
			let found = false;
			for (const c of coveredMembers) {
				if (c == member) { found = true; }
			}
			if (!found) { allCovered = false; }
		}
		if (allCovered && discType.typeNames.length > 0) isExhaustive = true;
	}
	// Tier 2: string-literal DU exhaustiveness
	if (!isExhaustive && narrowIsStringDU && narrowUnion != null) {
		const variantValues = collectStringDiscriminantValues(narrowUnion, narrowDiscField);
		if (variantValues.length > 0) {
			let allCovered = true;
			for (const v of variantValues) {
				let found = false;
				for (const c of coveredMembers) {
					if (c == v) { found = true; break; }
				}
				if (!found) { allCovered = false; break; }
			}
			if (allCovered) isExhaustive = true;
		}
	}
	if (!isExhaustive && coversEveryLiteral(discType, coveredMembers)) isExhaustive = true;
	mergeInitBranches(ctx.initTracker, oldState, branchInits, branchBreaks, isExhaustive);
	if (discType.kind == TypeKind.Enum && !hasWildcard) {
		const discEnd = estimateExprEndCol(d.matchDisc) + 1;
		checkEnumExhaustiveness(ctx, discType!, coveredMembers, node.location.line, node.location.column, discEnd);
	}
	if (!isExhaustive && discType.kind != TypeKind.Enum && !(narrowIsStringDU && narrowUnion != null) && !isUnresolvedType(discType)
			&& mustCoverEveryValue(discType)) {
		reportUncoveredMatch(ctx, discType, node, d.matchDisc);
	}
	// Tier 2: report missing string DU variants
	if (narrowIsStringDU && narrowUnion != null && !hasWildcard) {
		const variantValues = collectStringDiscriminantValues(narrowUnion, narrowDiscField);
		for (const v of variantValues) {
			let found = false;
			for (const c of coveredMembers) {
				if (c == v) { found = true; break; }
			}
			if (!found) {
				addError(ctx, `Non-exhaustive match: missing variant '${v}'`,
					node.location.line, node.location.column);
			}
		}
	}
	return returnType;
}

export function checkEnumExhaustiveness(ctx: CheckerContext, enumType: Type, covered: string[], matchLine: int32, matchCol: int32, discEndCol: int32): void {
	for (const member of enumType.typeNames) {
		let found = false;
		for (const c of covered) {
			if (c == member) { found = true; }
		}
		if (!found) {
			// Range: from `match` keyword to closing `)` after discriminant
			addErrorRange(ctx, `Non-exhaustive match: missing '${enumType.typeName}.${member}'`, matchLine, matchCol, discEndCol);
		}
	}
}

export function coversEveryLiteral(discType: Type | null, covered: string[]): boolean {
	if (discType == null) return false;
	const t = peelThrough(discType, PEEL_ALL) ?? discType;
	if (t.kind == TypeKind.Boolean) return covered.includes("true") && covered.includes("false");
	if (t.kind == TypeKind.BooleanLiteral || t.kind == TypeKind.StringLiteral) return covered.includes(t.typeName);
	if (t.kind != TypeKind.Union || t.typeChildren.length == 0) return false;
	for (const m of t.typeChildren) {
		if (m.kind != TypeKind.StringLiteral && m.kind != TypeKind.BooleanLiteral) return false;
		if (!covered.includes(m.typeName)) return false;
	}
	return true;
}

export function mustCoverEveryValue(discType: Type | null): boolean {
	if (discType == null) return false;
	const t = peelThrough(discType, PEEL_ALL) ?? discType;
	if (isIntegerType(t) || t.kind == TypeKind.Boolean || t.kind == TypeKind.BooleanLiteral
			|| t.kind == TypeKind.Char || t.kind == TypeKind.Enum || t.kind == TypeKind.StringLiteral) return true;
	if (t.kind != TypeKind.Union || t.typeChildren.length == 0) return false;
	for (const m of t.typeChildren) {
		if (m.kind != TypeKind.StringLiteral && m.kind != TypeKind.BooleanLiteral) return false;
	}
	return true;
}

export function reportUncoveredMatch(ctx: CheckerContext, discType: Type | null, node: Node, disc: Node): void {
	addErrorRange(ctx, `Non-exhaustive match: not every '${typeDisplayName(discType)}' value has an arm — add a '_' arm`,
		node.location.line, node.location.column, estimateExprEndCol(disc) + 1);
}

// Estimate end column of an expression node (for diagnostic ranges)
export function estimateExprEndCol(node: Node): int32 {
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

export function refusesTypeArm(ctx: CheckerContext, p: Node, disc: Node): boolean {
	const name = (p.data as IdentifierData).name;
	const sym = lookupSymbol(ctx.table, name);
	if (sym == null ? builtinTypeNamed(ctx, name) == null : !isTypeSymbol(sym)) return false;
	const kindTest = sym == null && (isPrimitiveKindName(name) || isTypeofTag(name))
		? `; test the kind with typeof ${referenceText(disc)} === "${name}"` : "";
	addError(ctx, `'${name}' only refers to a type, but is being used as a value here: a match arm compares values, so it cannot test which type a value holds${kindTest}`, p.location.line, p.location.column);
	p.nodeType = errorType();
	return true;
}

function referenceText(n: Node): string {
	if (n.kind == NodeKind.Identifier) return (n.data as IdentifierData).name;
	if (n.kind == NodeKind.MemberExpr) {
		const md = n.data as MemberExprData;
		const head = referenceText(md.object);
		return head == "x" ? "x" : head + "." + md.property;
	}
	return "x";
}

// Detect duplicate unguarded match patterns (reference parity: checkForOverlap).
// Shared by checkMatchExpr and checkMatchStmt.
export function checkDuplicatePatterns(ctx: CheckerContext, cases: Node[]): void {
	const seen: string[] = [];
	for (const c of cases) {
		const cd = c.data as MatchCaseData;
		if (cd.caseGuard != null) continue;
		for (const p of cd.casePatterns) {
			let patKey = "";
			if (p.kind == NodeKind.NumberLiteral) {
				patKey = "n:" + (p.data as NumberLiteralData).value.toString();
			} else if (p.kind == NodeKind.MemberExpr) {
				const pmd = p.data as MemberExprData;
				if (pmd.object != null && pmd.object.nodeType != null && pmd.object.nodeType.kind == TypeKind.Enum) {
					patKey = "e:" + pmd.property;
				}
			} else if (p.kind == NodeKind.StringLiteral) {
				patKey = "s:" + (p.data as StringLiteralData).value;
			} else if (p.kind == NodeKind.BooleanLiteral) {
				patKey = "b:" + (p.data as BooleanLiteralData).boolValue.toString();
			}
			if (patKey != "") {
				for (const s of seen) {
					if (s == patKey) {
						addError(ctx, "Duplicate match pattern", p.location.line, p.location.column);
					}
				}
				seen.push(patKey);
			}
		}
	}
}

// Static field lookup — searches class symbol's staticFields
function findStaticField(classSym: Symbol, fieldName: string): Symbol {
	if (classSym == null) return null as unknown as Symbol;
	const qualifiedName = classSym.name + "." + fieldName;
	for (const sf of classSym.staticFields) {
		if (sf.name == qualifiedName) return sf;
	}
	// Walk parent chain for inherited static fields
	let inner = classSym.symbolType;
	if (inner != null && inner.kind == TypeKind.Ref && inner.typeReturn != null) inner = inner.typeReturn;
	if (inner != null && inner.typeExtra != null && inner.typeExtra.sym != null) {
		return findStaticField(inner.typeExtra.sym, fieldName);
	}
	return null as unknown as Symbol;
}

