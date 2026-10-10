// Expression Checker — type inference for all expression kinds
// Extracted from checkPass.ms. Uses checkerCallbacks for mutual recursion with checkStmt.

import { refusePrivateField, declaresReadonlyField, hiddenPrivateField, declaringSymOf, befriend, unfriend, expansionOf, markExpansion } from "./visibility";
import { Node, NodeKind, NodeData, createNode, createNodeAt, NodeFlag, makeLoc, SourceLocation, IdentifierData, BinaryExprData, UnaryExprData, UpdateExprData, NumberLiteralData, CallExprData, MemberExprData, ArrayAccessData, ObjectLiteralData, ArrayLiteralData, ConditionalExprData, TypeAssertionData, SpreadExprData, NewExprData, TryExprData, AwaitExprData, YieldExprData, MoveExprData, OutExprData, SizeofExprData, HiddenDerefData, HiddenStdConvData, MacroInvocationData, StringLiteralData, BigIntLiteralData, ArrowFunctionData, FunctionExprData, MatchCaseData, MatchExprData, FunctionDeclData, MethodDeclData, ClassDeclData, ActorDeclData, PropertyDeclData, DecoratedDeclData, BlockStmtData, ExprStmtData, ReturnStmtData, IfStmtData, SpliceManyData, VariableDeclData, Type, TypeKind, CallingConvention, Symbol, SymbolKind, SymbolState, BooleanLiteralData, collectConcatParts, JSXElementData, JSXFragmentData, JSXExpressionContainerData, JSXAttributeData, JSXSpreadAttributeData } from "../ast/node";
import { getIdentId } from "./idents";
import { TokenKind, Token, createToken } from "../lexer/token";
import { peelTransparentInstance, literalBase, symGenericParams, genericParamNamesOf, runtimeClassSym, soleUnionMember, isFunctionKind, isArrayShaped, inferredType, noneType, numberType, int32Type, float64Type, isFloatType, createReadonlyView, propagateReadonlyView, isReadonlyView, isSharedGraphType, isNodeGraphType, createRef, createStruct, stringType, booleanType, charType, voidType, nullType, errorType, createArray, createArc, createTuple, isAtomicRef, createSpan, createFunction, createClosureType, closureStorageType, createTypeRef, createPrimitive, createUnion, createMaybeType, isMaybeWrappable, isPrimitiveUnionMember, substituteType, instantiateGeneric, createGenericInstance, anonStructName, isNumeric, isIntegerType, getReturnType, getElementType, getProperty, sizeOfType, typeNameOf, isIndexableMapType, unwrapRef, unwrapVarargs, unwrapRefNullUnion, isDiscriminatedUnion, getDiscriminantName, findVariantByDiscriminant, findVariantByStringDiscriminant, findSharedStringDiscriminant, detectUnionDiscriminant, collectStringDiscriminantValues, findFieldInVariant, unionVariantHasProperty, findUnionVariant, isAmbiguousVariant, findVariantByFieldName, duVariantIndexOfType, duSharedFieldOffsetDiffers, unifyType, createUnifyBindings, mergeUnifyBindings, UnifyBindings, hasGenericParams, getMinArity, setMinArity, isNarrowingIntConv, integerRank, skipModifier, createPromise, createSpawnHandle, isAwaitable, isAffineAwaitable, awaitedType, isResult, getResultOkType, getResultErrType, instantiateGenericBody, isStringLike, isPrimitiveKind, isStructType, isMaybeType, unwrapMaybeType, createEnumLiteral, typeDisplayName, booleanLiteralValue, peelToStructOrUnion, unknownRefusal, unknownRefusalText, UnknownRefusal, smuggledIntoUnknown, objectConversion, ObjConv, isUnknownType, isUnresolvedType, isBrandDistinct, distinctCallTarget, literalTagDiscriminant, withoutReadonlyView, isViewType, unwrapRefBase, peelThrough, PEEL_ALL, isValuePointee, classParentOf, isNullableShape } from "./types";
import { ScopeKind, SymbolFlag, defineSymbol, isCapturableValue, isCapturedAcross, isFrameValue, lookupSymbol, makeSymbol, makeSymbolState, openScope, closeScope, hasOverloads, hasFlag, setFlag, markConsumed, getCtorParamTypes, classDeclNodeOf, parentClassSymOf, lookupCtorDefaults, isVisibleSymbol } from "./symbol";
import { markUsedIn, CheckerContext, ExportedSymInfo, addError, addErrorRange, addWarning, findAllExtensionsByName, resolveOperatorCall, ExtensionMethod, isCancelled, filterExtsByReceiverType, findFirstMatchingExt, getExtFnType, stripReceiverParam, sgRecordSym, findExportedSymbol, extractGenericNames, isGenericFn, isEngineCheckMode, macroConverterFor, isGeneratorFlags, refusesTypeAsValue, findExtension, findAccessor } from "./context";
import {
	isAssignable, isReinterpretUnsafe, nonNullMemberOfNullable, needsStdConv, findFirstMismatch,
	scoreCandidatePriority, scoreCandidateWithSkip, isNoMatch, emptyCandidateScore, cmpCandidates,
	CandidateScore, sameType, isAnonStructAdoption, dropsReadonlyView, isValueStructDecl, sameNominal, valueStructBaseDepth, numericConvRefuses, viewFieldNotHeld, numericRefusalReason, explainStructuralPrefix } from "./compat";
import { callCheckStmt, callDemandReturn, callLaterDeclarationNote, checkInTypeSlot, registerCheckExpr } from "./checkerCallbacks";
import { checkArcPointeeSendable } from "./sendable";
import { isLockedRef, isIterator, getIteratorYieldType } from "./types";
import { isLocation, writeRefusal, readonlyPrefixType, readonlyRootType, writeThroughArc, writeThroughGraphBackedge, WriteSite } from "./assignable";
import { builtinTypeNamed, resolveAnnotation, resolveTypeExpr, resolveTypeExprs, ensureShaped, recordGenericTypeInstantiation, refuseSuspendingViewParam, bodyMentionsName } from "./resolvePass";
import { mangleMonoName } from "../monomorphize/registry";
import { cloneNodeForCheck, cloneNodeKeepSem, monoConcreteTypeName } from "../monomorphize/clone";
import { callExpandMacroInvocation, callEvalComptimeBlock } from "./checkerCallbacks";
import { findChar, splitTopLevel, fitsInt64Decimal, int64ToDecimal } from "../utils/string";
import { basename } from "std/fs/path";
import { checkPointerAddress } from "./pointerAddress";
import { findCallTypeArg } from "../parser/context";
import { markConsumedName, isConsumedName, removeConsumedName, symbolConsumeKey } from "./spawnAffinity";
import { forEachChild } from "../ast/visitor";
import {
	markInitialized, isInitialized, getDeclBlock, requiresInit,
	saveInitState, restoreInitState, collectNewInits, mergeInitBranches, breaksBlock, BreakState,
} from "./initTracker";
import { callInstantiateGeneric } from "./checkerCallbacks";
import { getFlowTypeOfReference, isDefinitelyNonNullAt, isEndOfBodyReachable, unionOfTypes } from "./flow";
import { isContextSensitive } from "./speculate";
import { isTemplateSym, expandTemplate } from "./template";
import { adoptLiteralArms, declaredTagUnionOf, branchFitsSlot, checkBitwiseOperands, checkNegatedIntLiteral, reportConstIndexBound, reportConstCast, tupleIndexType, checkRelationalOperands, checkBinaryOperands, refuseDisjointStrings, typeofComparisonHint, fitJoinedBranch, fitNode, reportReadonlyDrop, inferBinaryOp, inferUnaryOp, isBitwiseAllowed, isBitwiseBinaryOp, isNodeIntLit, joinBranchTypes, literalFitsInType, narrowUnionToVariant, assertIntoNullable, checkedProjection, assertionNarrows, isStrLitSet, rejectBigIntMix, reportLiteralRange, synthCStringConv, synthMaybeWrap, synthStringify, tryAdoptAnonStruct, tryApplyConverter, convertsWithoutRoutine, operandConverter, slotTakesValue, reportedErrorSince, valueOfInPlace, ReadNeed, operandReadsValue, refuseFunctionTruthiness, isFunctionShaped, isSyncGeneratorFlags, settleYields, unaryArithFails, arrayIndexFails, widenVariantToUnion, wrapInConv, tagUnionMemberSlot, projectTagUnionMember, objectPathHolders, isSlotUnion, constantOperandAs, nullishPayloadType, exactConstantType, untypedIntegerLiteralType, wideOperandLiteralSlot, rejectLossyIntFloatMix, literalAdoptsFloat32, intLiteralExactInFloat, reportFloat32LiteralRange, constantAdoptsFloat32, compoundOperandRefuses, reportCompoundOperand, isPayloadCarrier, isScalarPrimitive, textConversionRefusal, narrowsToMember, isFittingNumericConstant, isBitwiseCompoundOp, refuseMixedSignedCompare, convertsBetweenUnions, unionConversionRefusal, convertUnionToUnion, nullableUnionPayloads, convertStoredUnionRead, heldInTarget, unionsOverlap } from "./fit";

// Extension receiver matching functions imported from context.ms (shared with LSP)

function literalElemType(el: Node): Type | null {
	if (el.kind != NodeKind.SpreadExpr) return el.nodeType;
	let src = (el.data as SpreadExprData).spreadArg.nodeType;
	if (src != null && src.kind == TypeKind.Ref && src.typeReturn != null) src = src.typeReturn;
	if (src != null && (src.kind == TypeKind.Array || src.kind == TypeKind.SizedArray || src.kind == TypeKind.Span)
			&& src.typeReturn != null) return src.typeReturn;
	return el.nodeType;
}

function refuseSpreadElements(ctx: CheckerContext, spread: Node, elem: Type | null): void {
	const from = literalElemType(spread);
	if (from == null || elem == null || isUnresolvedType(from) || isUnresolvedType(elem)) return;
	if (hasGenericParams(from) || hasGenericParams(elem) || sameType(from, elem)) return;
	const numeric = isNumeric(from) && isNumeric(elem);
	const wraps = !numeric && (isMaybeType(elem) || (elem.kind == TypeKind.Union && unwrapRefNullUnion(elem) == null));
	if (numeric ? !numericConvRefuses(from, elem) : (!wraps && isAssignable(from, elem))) return;
	const why = numeric ? `implicit ${typeDisplayName(from)} → ${typeDisplayName(elem)} conversion ${numericRefusalReason(from, elem)}`
		: wraps ? `each '${typeDisplayName(from)}' would have to be converted to '${typeDisplayName(elem)}'`
		: `'${typeDisplayName(from)}' is not assignable to '${typeDisplayName(elem)}'${explainStructuralPrefix(from, elem)}`;
	addError(ctx, `a spread copies its elements into the array as they are: ${why} — convert them first, e.g. with map`,
		spread.location.line, spread.location.column);
}

function isComparisonOp(op: string): boolean {
	return op == "<" || op == "<=" || op == ">" || op == ">=" || op == "==" || op == "!=" || op == "===" || op == "!==";
}

function isStructOperand(t: Type): boolean {
	return isStructType(t) || (t.kind == TypeKind.GenericInstance && isStructType(t.typeReturn));
}

function declaredOperatorResult(ctx: CheckerContext, op: string, left: Type | null, right: Type | null): Type | null {
	if (left == null || right == null || isStringLike(left) || isStringLike(right) || ctx.extensionRegistry == null) return null;
	const ext = resolveOperatorCall(ctx.table, ctx.extensionRegistry, op, [left, right]);
	if (ext == null) return null;
	const fnType = getExtFnType(ext);
	return fnType != null ? fnType.typeReturn : null;
}

function checkAssignTarget(ctx: CheckerContext, target: Node): void {
	if (target.kind != NodeKind.ArrayLiteral) {
		checkExpr(ctx, target, null);
		const k = target.kind;
		if (k != NodeKind.Identifier && k != NodeKind.MemberExpr && k != NodeKind.ArrayAccess && k != NodeKind.ObjectLiteral) {
			addError(ctx, "a destructuring assignment target must be a variable, a field or an element", target.location.line, target.location.column);
		}
		return;
	}
	const d = target.data as ArrayLiteralData;
	const types: Type[] = [];
	let restElem: Type | null = null;
	let untyped = false;
	for (const el of d.elements) {
		if (el.kind == NodeKind.SpreadExpr) {
			checkAssignTarget(ctx, (el.data as SpreadExprData).spreadArg);
			el.nodeType = inferredType();
			restElem = literalElemType(el);
			continue;
		}
		checkAssignTarget(ctx, el);
		if (el.nodeType == null) { untyped = true; continue; }
		types.push(el.nodeType);
	}
	if (untyped) {
		target.nodeType = errorType();
		return;
	}
	let shared: Type | null = restElem != null ? restElem : (types.length > 0 ? types[0] : null);
	for (const t of types) {
		if (shared == null || !sameType(t, shared)) { shared = null; break; }
	}
	if (shared != null) {
		target.nodeType = createRef(createArray(shared));
	} else if (restElem == null) {
		target.nodeType = createTuple(types);
	} else {
		addError(ctx, "a rest element in a destructuring assignment needs every other target to have its element type", target.location.line, target.location.column);
		target.nodeType = errorType();
	}
}

function reportArcWrite(ctx: CheckerContext, target: Node): void {
	addError(ctx, "cannot write through 'Arc<T>' — SHARE is immutable; shared mutable state is Locked<T> (PARALOCK Amendment I)",
		target.location.line, target.location.column);
}

function reportReadonlyWrite(ctx: CheckerContext, ro: Type, verb: string, line: int32, column: int32): void {
	addError(ctx, "cannot " + verb + " " + typeDisplayName(ro) + " — a read-only view never converts back to the mutable type (PARALOCK E24)", line, column);
}

function reportSharedWrite(ctx: CheckerContext, target: Node): void {
	if (writeThroughArc(target)) { reportArcWrite(ctx, target); return; }
	if (writeThroughGraphBackedge(target)) {
		addError(ctx, "cannot write through a type/symbol back-edge into the AST — the graph is borrowed and its node exits are read-only (PARALOCK E24)", target.location.line, target.location.column);
		return;
	}
	const ro = readonlyPrefixType(target);
	if (ro != null) {
		reportReadonlyWrite(ctx, ro, "write through", target.location.line, target.location.column);
		return;
	}
	const refusal = writeRefusal(target, WriteSite.Assign);
	if (refusal != "") addError(ctx, refusal, target.location.line, target.location.column);
}

function literalDiscriminantOwner(md: MemberExprData): Type | null {
	let obj = md.object;
	while (obj.kind == NodeKind.HiddenDeref) obj = (obj.data as HiddenDerefData).expr;
	const declared = obj.resolvedSym != null && (obj.kind == NodeKind.Identifier || obj.kind == NodeKind.MemberExpr) ? obj.resolvedSym.symbolType : obj.nodeType;
	const u = peelToStructOrUnion(declared);
	if (u == null || u.kind != TypeKind.Union) return null;
	return literalTagDiscriminant(u) == md.property ? u : null;
}

function readonlyFieldDeclarer(classSym: Symbol, propName: string): Symbol {
	let sym = classSym;
	let depth = 0;
	while (sym != null && depth < 64) {
		const decl = classDeclNodeOf(sym);
		if (decl == null) return declaresReadonlyField(sym, propName) ? sym : null as unknown as Symbol;
		const body = decl.kind == NodeKind.ClassDecl
			? (decl.data as ClassDeclData).classBody
			: (decl.data as ActorDeclData).actorBody;
		for (const m of body) {
			let prop = m;
			if (prop.kind == NodeKind.DecoratedDecl) {
				const dd = prop.data as DecoratedDeclData;
				if (dd.decoratedNode != null) prop = dd.decoratedNode;
			}
			if (prop.kind != NodeKind.PropertyDecl) continue;
			const pd = prop.data as PropertyDeclData;
			if (pd.propName != propName) continue;
			return pd.propIsReadonly ? sym : (null as unknown as Symbol);
		}
		sym = parentClassSymOf(sym);
		depth += 1;
	}
	return null as unknown as Symbol;
}

function isDeclaringStaticBlockWrite(ctx: CheckerContext, declaring: Symbol): boolean {
	const cls = ctx.staticBlockClass;
	if (cls == null) return false;
	return cls == declaring || classDeclNodeOf(cls) == classDeclNodeOf(declaring);
}

function isDeclaringCtorThisWrite(ctx: CheckerContext, object: Node, declaring: Symbol): boolean {
	let receiverNode = object;
	while (receiverNode != null && receiverNode.kind == NodeKind.HiddenDeref) {
		receiverNode = (receiverNode.data as HiddenDerefData).expr;
	}
	if (receiverNode == null || receiverNode.kind != NodeKind.Identifier) return false;
	if ((receiverNode.data as IdentifierData).name != "this") return false;
	const fn = ctx.currentFunction;
	if (fn == null || fn.name != "constructor" || fn.symbolKind != SymbolKind.Method) return false;
	if (fn.symbolType == null || fn.symbolType.kind != TypeKind.Function || fn.symbolType.typeChildren.length == 0) return false;
	const receiver = unwrapRef(fn.symbolType.typeChildren[0]);
	if (receiver == null || receiver.sym == null) return false;
	return receiver.sym == declaring || classDeclNodeOf(receiver.sym) == classDeclNodeOf(declaring);
}

function isReadonlyAttachedStatic(owner: Node, field: Symbol | null): boolean {
	if (owner.resolvedSym == null || owner.resolvedSym.symbolKind != SymbolKind.Function) return false;
	if (field == null || field.declNode == null || field.declNode.kind != NodeKind.PropertyDecl) return false;
	return (field.declNode.data as PropertyDeclData).propIsReadonly;
}

function reportReadonlyField(ctx: CheckerContext, target: Node): void {
	const md = target.data as MemberExprData;
	if (md.object.nodeType == null) return;
	if (isReadonlyAttachedStatic(md.object, target.resolvedSym)) {
		addError(ctx, `cannot assign to '${md.property}' because it is a read-only property`,
			target.location.line, target.location.column);
		return;
	}
	let ownerType = md.object.nodeType;
	if (ownerType.kind == TypeKind.Ref && ownerType.typeReturn != null) ownerType = ownerType.typeReturn;
	if (ownerType.sym == null) return;
	if (ownerType.sym.symbolKind == SymbolKind.Actor && md.property == "pid") {
		addError(ctx, `cannot assign to 'pid' because it is a read-only property`,
			target.location.line, target.location.column);
	}
	const declaring = readonlyFieldDeclarer(ownerType.sym, md.property);
	if (declaring == null || isDeclaringCtorThisWrite(ctx, md.object, declaring)) return;
	if (!isDeclaringStaticBlockWrite(ctx, declaring)) {
		addError(ctx, `cannot assign to '${md.property}' because it is a read-only property`,
			target.location.line, target.location.column);
	} else if (target.resolvedSym != null && target.resolvedSym.symFlags.has(SymbolFlag.Static)) {
		setFlag(target.resolvedSym, SymbolFlag.Mutable);
	}
}

// Phase 4: invalidateFacts / factReferencesVar deleted.
// Assignments that invalidate narrowing now flow through the binder's
// FlowAssignment node + getFlowTypeOfReference. Per-use-site queries see
// the post-assignment flow state naturally — no fact stack to purge.





// ===== Expression Checker =====




function checkedInstanceSym(ctx: CheckerContext, target: Type | null): Symbol | null {
	const held = target != null ? skipModifier(target) : null;
	const ref = held != null && held.kind == TypeKind.Union ? unwrapRefNullUnion(held) : held;
	const body = ref != null && ref.kind == TypeKind.Ref ? ref.typeReturn : null;
	if (body == null || body.kind != TypeKind.GenericInstance) return null;
	const cls = runtimeClassSym(body);
	if (cls == null) return null;
	const names = splitTopLevel(genericParamNamesOf(symGenericParams(cls)), ",").map((n: string): string => n.trim());
	return instantiateClassConstructor(cls, names, body.typeChildren, ctx);
}

function stampCheckedInstance(ctx: CheckerContext, node: Node, target: Type): void {
	const instance = checkedInstanceSym(ctx, target);
	if (instance == null) return;
	if (node.typeExpr == null) node.typeExpr = createNodeAt(NodeKind.Identifier, { name: instance.name } as IdentifierData, node.location);
	node.typeExpr!.resolvedSym = instance;
}

export function checkExpr(ctx: CheckerContext, node: Node, expectedType: Type | null): void {
	if (node == null) return;
	if (node.flags.has(NodeFlag.Sem) && node.nodeType != null) return;
	if (isCancelled(ctx.cancelCtx, ctx.cancelVersion)) { node.nodeType = errorType(); return; }
	const slotType = node.flags.has(NodeFlag.Folded) && node.nodeType != null
		? node.nodeType
		: (expectedType != null && (expectedType.kind == TypeKind.Sink || expectedType.kind == TypeKind.Lent) && expectedType.typeReturn != null)
		? expectedType.typeReturn
		: expectedType;
	checkExprInner(ctx, node, slotType);
	viewThroughReadonlyBase(node);
	node.flags = node.flags.incl(NodeFlag.Sem);
}

function viewThroughReadonlyBase(node: Node): void {
	if (node.nodeType == null) return;
	let base: Node | null = null;
	if (node.kind == NodeKind.MemberExpr) base = (node.data as MemberExprData).object;
	else if (node.kind == NodeKind.ArrayAccess) base = (node.data as ArrayAccessData).array;
	if (base == null) return;
	let ro = base.nodeType != null && isReadonlyView(base.nodeType);
	if (!ro && base.kind == NodeKind.HiddenDeref) {
		const inner = (base.data as HiddenDerefData).expr;
		ro = inner != null && inner.nodeType != null && isReadonlyView(inner.nodeType);
	}
	if (ro) node.nodeType = propagateReadonlyView(node.nodeType);
}


function converterSlotTarget(t: Type): Type {
	if (isMaybeType(t)) {
		const payload = unwrapMaybeType(t);
		if (payload != null) return payload;
	}
	const refPayload = unwrapRefNullUnion(t);
	if (refPayload != null) return refPayload;
	return t;
}

function reportUnconsumedJsx(ctx: CheckerContext, node: Node, what: string, expectedType: Type | null): void {
	if (ctx.jsxMacroArgDepth == 0) {
		let msg = what + " must be consumed by a macro (it produces a compile-time Node)";
		if (expectedType != null && !isUnresolvedType(expectedType)) {
			msg = msg + "; import a converter targeting '" + typeDisplayName(converterSlotTarget(expectedType)) + "' to lower it at this boundary";
		}
		addError(ctx, msg, node.location.line, node.location.column);
	}
}

// Converter boundary lowering (LANG-JSX.md): JSX at a settled expected-runtime-type position
// rewrites in place into a MacroInvocation of the in-scope converter for that target, then
// re-checks — the eager-expansion branch expands and re-checks against the same expected type.
// Never fires inside macro args (jsxMacroArgDepth) or where no expected type is settled.
function tryConverterAtBoundary(ctx: CheckerContext, node: Node, expectedType: Type | null): boolean {
	if (expectedType == null) return false;
	if (isUnresolvedType(expectedType) || expectedType.kind == TypeKind.GenericParam) return false;
	if (ctx.jsxMacroArgDepth > 0) return false;
	const convSym = macroConverterFor(ctx, converterSlotTarget(expectedType));
	if (convSym == null || macroDeclOf(convSym) == null) return false;
	const jsxArg = createNodeAt(node.kind, node.data, node.location);
	jsxArg.typeExpr = node.typeExpr;
	node.kind = NodeKind.MacroInvocation;
	node.data = { macroName: convSym.name, macroArgs: [jsxArg], macroHasParens: true };
	node.nodeType = null as unknown as Type;
	node.resolvedSym = convSym;
	node.flags = 0 as BitSet<NodeFlag>;
	node.variantSlot = 0;
	checkExpr(ctx, node, expectedType);
	return true;
}

// Record the JSX tag's base name as a symbol reference for LSP go-to-def / rename. An uppercase
// tag is a component reference (binds to the function symbol); a lowercase tag is a platform
// string (no binding). node.typeExpr is the positioned Identifier the parser stored for the tag.
function recordJsxTagSym(ctx: CheckerContext, node: Node): void {
	if (node.typeExpr == null) return;
	const base = (node.typeExpr.data as IdentifierData).name;
	if (base.byteLength == 0 || base.byteAt(0) < "A".code || base.byteAt(0) > "Z".code) return;
	const sym = lookupSymbol(ctx.table, base);
	if (sym == null) return;
	node.typeExpr.resolvedSym = sym;
	const loc = node.typeExpr.location;
	sgRecordSym(ctx, loc.line, loc.column, loc.column + base.byteLength, sym, sym.symbolType, sym.symbolKind, base, "", false);
}


function isLocalToFunction(ctx: CheckerContext, name: string, sym: Symbol): boolean {
	const nameId = getIdentId(ctx.table.identCache, name);
	let scope = ctx.table.current;
	while (scope != null) {
		if (scope.symbols.get(nameId) == sym) return true;
		if (scope.scopeKind == ScopeKind.Function) return false;
		scope = scope.parent;
	}
	return false;
}

function routineFlags(decl: Node | null): string {
	let d = decl;
	while (d != null && d.kind == NodeKind.DecoratedDecl) {
		d = (d.data as DecoratedDeclData).decoratedNode;
	}
	if (d == null) return "";
	return match (d.kind) {
		NodeKind.FunctionDecl => (d.data as FunctionDeclData).fnFlags,
		NodeKind.MethodDecl => (d.data as MethodDeclData).methodFlags,
		NodeKind.ArrowFunction => (d.data as ArrowFunctionData).arrowFlags,
		NodeKind.FunctionExpr => (d.data as FunctionExprData).funcExprFlags,
		_ => "",
	};
}

function routineSuspends(fn: Symbol | null): boolean {
	if (fn == null) return false;
	return hasFlag(fn, SymbolFlag.Async) || isGeneratorFlags(routineFlags(fn.declNode));
}

function capturesView(ctx: CheckerContext, name: string, sym: Symbol): boolean {
	if (!isFrameValue(sym)) return false;
	const nameId = getIdentId(ctx.table.identCache, name);
	let crossed = false;
	let scope = ctx.table.current;
	while (scope != null && scope.symbols.get(nameId) != sym) {
		if (scope.scopeKind == ScopeKind.Function) crossed = true;
		scope = scope.parent;
	}
	if (scope == null) return false;
	const suspended = !crossed && sym.symbolKind == SymbolKind.Parameter &&
		routineSuspends(ctx.currentFunction);
	return (crossed || suspended) && isViewType(sym.symbolType);
}

function viewTypeText(t: Type | null): string {
	if (t == null || t.typeReturn == null) return typeDisplayName(t);
	return match (t.kind) {
		TypeKind.Array => `Vec<${viewTypeText(t.typeReturn)}>`,
		TypeKind.Span => `Span<${viewTypeText(t.typeReturn)}>`,
		_ => typeDisplayName(t),
	};
}

function viewCaptureRefusal(ctx: CheckerContext, name: string, sym: Symbol): string {
	const t = sym.symbolType;
	const shown = t.kind == TypeKind.Var && t.typeReturn != null ? t.typeReturn : t;
	const decl = sym.declNode;
	const at = decl != null && decl.kind == NodeKind.VariableDecl
		? (decl.data as VariableDeclData).nameLocation
		: sym.location;
	const file = basename(ctx.modulePath);
	const where = at != null ? `${file}(${at.line}, ${at.column})` : file;
	const hint = t.kind == TypeKind.Var && shown.kind == TypeKind.Ref
		? `drop the parameter modifier: a ${viewTypeText(shown)} is already shared by reference`
		: "return the value instead";
	return `'${name}' is of type <${viewTypeText(shown)}> which cannot be captured` +
		` as it would violate memory safety, declared here: ${where}; ${hint}`;
}

function typeLiteralAgainstPayload(ctx: CheckerContext, node: Node, expectedType: Type | null): boolean {
	if (expectedType == null || !isMaybeType(expectedType) || expectedType.typeReturn == null) return false;
	checkExprInner(ctx, node, expectedType.typeReturn);
	return true;
}

// Internal: compute type for node. All match arms and sub-functions return Type.
function checkExplicitDeref(ctx: CheckerContext, node: Node, target: Node): void {
	const written = target.nodeType;
	const ptr = written == null ? null : withoutReadonlyView(written);
	const pointee = ptr != null && (ptr.kind == TypeKind.Ptr || ptr.kind == TypeKind.Ref) ? ptr.typeReturn : null;
	if (pointee == null || !derefablePointee(ptr!, pointee)) {
		addError(ctx, explicitDerefRefusal(ptr, pointee), node.location.line, node.location.column);
		node.nodeType = errorType();
		return;
	}
	node.nodeType = isReadonlyView(written) ? propagateReadonlyView(pointee) : pointee;
}

function explicitDerefRefusal(ptr: Type | null, pointee: Type | null): string {
	if (ptr == null) return "'x[]' dereferences a Ptr<T> or a Ref<T>; this operand has no type";
	if (ptr.kind == TypeKind.Ptr) return "'x[]' cannot dereference Ptr<void>; cast it to a Ptr<T> first";
	if (pointee == null) return "'x[]' dereferences a Ptr<T> or a Ref<T>; this operand is " + typeDisplayName(ptr) + ", a value";
	const shown = ptr.sym != null ? ptr.sym.name : pointee.sym != null ? pointee.sym.name : typeDisplayName(ptr);
	return "'x[]' dereferences a Ptr<T> or a Ref<T>; this operand is " + shown + ", which is already a reference: use it without '[]'";
}

function derefablePointee(ptr: Type, pointee: Type): boolean {
	if (pointee.kind == TypeKind.Void) return false;
	if (ptr.kind == TypeKind.Ptr) return true;
	return isValuePointee(pointee);
}

function checkExprInner(ctx: CheckerContext, node: Node, expectedType: Type | null): void {
	if (startsOptionalChain(node)) { checkOptionalChain(ctx, node, expectedType); return; }
	checkExprKind(ctx, node, expectedType);
}

function checkExprKind(ctx: CheckerContext, node: Node, expectedType: Type | null): void {
	const result = match (node.kind) {
		NodeKind.NumberLiteral => { checkNumberLiteral(ctx, node, expectedType); return; },
		NodeKind.BigIntLiteral => {
			node.nodeType = createPrimitive(TypeKind.BigInt);
			return;
		},
		NodeKind.StringLiteral => { checkStringLiteral(ctx, node, expectedType); return; },
		NodeKind.BooleanLiteral => { checkBooleanLiteral(ctx, node, expectedType); return; },
		NodeKind.NullLiteral => nullType(),
		NodeKind.QuoteExpr => {
			if (tryConverterAtBoundary(ctx, node, expectedType)) { return; }
			node.nodeType = noneType(); return;
		},
		NodeKind.RegexLiteral | NodeKind.JSXText => noneType(),
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
		NodeKind.SpliceMany => { checkSpliceMany(ctx, node, expectedType); return; },
		NodeKind.ComptimeBlock => { checkComptimeBlock(ctx, node, expectedType); return; },
		NodeKind.Identifier => { checkIdentifier(ctx, node, expectedType); return; },
		NodeKind.BinaryExpr => { checkBinaryExpr(ctx, node, expectedType); return; },
		NodeKind.UnaryExpr => { checkUnaryExpr(ctx, node, expectedType); return; },
		NodeKind.UpdateExpr => { checkUpdateExpr(ctx, node, expectedType); return; },
		NodeKind.CallExpr => checkCallExpr(ctx, node, expectedType),
		NodeKind.MemberExpr => {
			node.nodeType = checkMemberExpr(ctx, node, expectedType);
			return;
		},
		NodeKind.ArrayAccess => { checkArrayAccess(ctx, node, expectedType); return; },
		NodeKind.ObjectLiteral => { checkObjectLiteral(ctx, node, expectedType); return; },
		NodeKind.ArrayLiteral => { checkArrayLiteral(ctx, node, expectedType); return; },
		NodeKind.ArrowFunction => checkArrowExpr(ctx, node, expectedType),
		NodeKind.FunctionExpr => checkFuncExpr(ctx, node, expectedType),
		NodeKind.ConditionalExpr => { checkConditionalExpr(ctx, node, expectedType); return; },
		NodeKind.TypeAssertion => { checkTypeAssertion(ctx, node, expectedType); return; },
		NodeKind.SpreadExpr => {
			const d = node.data as SpreadExprData;
			checkExpr(ctx, d.spreadArg, null);
			if (isFunctionShaped(d.spreadArg.nodeType) && !valueOfInPlace(ctx, d.spreadArg)) {
				addError(ctx, "a function value cannot be spread — call it first", node.location.line, node.location.column);
			}
			node.nodeType = inferredType(); return;
		},
		NodeKind.NewExpr => checkNewExpr(ctx, node, expectedType),
		NodeKind.TryExpr => checkTryExpr(ctx, node),
		NodeKind.MatchExpr => checkMatchExpr(ctx, node, expectedType),
		NodeKind.AwaitExpr => { checkAwaitExpr(ctx, node, expectedType); return; },
		NodeKind.YieldExpr => {
			checkYield(ctx, node);
			node.nodeType = inferredType(); return;
		},
		NodeKind.MoveExpr => { checkMoveExpr(ctx, node, expectedType); return; },
		NodeKind.OutExpr => {
			const d = node.data as OutExprData;
			checkExpr(ctx, d.outArg, null);
			const roOut = readonlyRootType(d.outArg);
			if (roOut != null) reportReadonlyWrite(ctx, roOut, "pass an 'out' argument through", node.location.line, node.location.column);
			node.nodeType = d.outArg.nodeType; return;
		},
		NodeKind.SizeofExpr => { checkSizeofExpr(ctx, node, expectedType); return; },
		NodeKind.HiddenDeref => { checkHiddenDeref(ctx, node, expectedType); return; },
		NodeKind.HiddenAddr => {
			const d = node.data as HiddenDerefData;
			checkExpr(ctx, d.expr, null); node.nodeType = d.expr.nodeType; return;
		},
		NodeKind.HiddenStdConv | NodeKind.HiddenSubConv => {
			const d = node.data as HiddenStdConvData;
			checkExpr(ctx, d.convExpr, isMaybeType(d.convType) ? d.convType.typeReturn : null);
			node.nodeType = d.convType; return;
		},
		NodeKind.MacroInvocation => { checkMacroInvocation(ctx, node, expectedType); return; },
		_ => inferredType(),
	};
	node.nodeType = result;
}

function checkNumberLiteral(ctx: CheckerContext, node: Node, expectedType: Type | null): void {
	if (typeLiteralAgainstPayload(ctx, node, expectedType)) return;
	reportLiteralRange(ctx, node);
	if (expectedType != null && isIntegerType(expectedType)) {
		if (literalFitsInType(node, expectedType, false)) {
			node.nodeType = expectedType; return;
		} else if (isNodeIntLit(node)) {
			// Reference parity: standard reference's type change diagnostic emits compile-time error for out-of-range literals
			const nd = node.data as NumberLiteralData;
			const shown = nd.outOfRangeText != "" ? nd.outOfRangeText : int64ToDecimal(nd.intVal);
			addError(ctx, "cannot convert " + shown + " to " + typeDisplayName(expectedType), node.location.line, node.location.column);
			node.nodeType = expectedType; return;
		} else {
			node.nodeType = float64Type(); return;
		}
	} else if (expectedType != null && (expectedType.kind == TypeKind.Float64 || expectedType.kind == TypeKind.Float32
			|| expectedType.kind == TypeKind.Number)) {
		if (isNodeIntLit(node) && !intLiteralExactInFloat(node, expectedType)) {
			node.nodeType = untypedIntegerLiteralType(ctx, node, false); return;
		}
		if (expectedType.kind == TypeKind.Float32) reportFloat32LiteralRange(ctx, node);
		node.nodeType = expectedType.kind == TypeKind.Number ? numberType() : expectedType; return;
	} else if (expectedType != null && expectedType.kind == TypeKind.Union) {
		// Mirror the StringLiteral/BooleanLiteral arms below: a numeric
		// member of the expected union types the literal, so `width: 400.0`
		// fits `float32 | string | null`. An integer literal takes an
		// integer member before a float one, whatever the member order.
		if (isNodeIntLit(node)) {
			for (const child of expectedType.typeChildren) {
				if (child != null && isIntegerType(child) && literalFitsInType(node, child, false)) {
					node.nodeType = child; return;
				}
			}
		}
		for (const child of expectedType.typeChildren) {
			if (child == null) continue;
			if (isIntegerType(child) && literalFitsInType(node, child, false)) {
				node.nodeType = child; return;
			}
			if ((child.kind == TypeKind.Float64 || child.kind == TypeKind.Float32 || child.kind == TypeKind.Number)
				&& (!isNodeIntLit(node) || intLiteralExactInFloat(node, child))) {
				if (child.kind == TypeKind.Float32) reportFloat32LiteralRange(ctx, node);
				node.nodeType = child; return;
			}
		}
		if (isNodeIntLit(node)) { node.nodeType = untypedIntegerLiteralType(ctx, node, false); return; }
		node.nodeType = float64Type(); return;
	} else {
		// Default inference: integer literals → int32 (int64 past its range), float literals → float64
		if (isNodeIntLit(node)) { node.nodeType = untypedIntegerLiteralType(ctx, node, false); return; }
		node.nodeType = float64Type(); return;
	}
}

function checkStringLiteral(ctx: CheckerContext, node: Node, expectedType: Type | null): void {
	if (typeLiteralAgainstPayload(ctx, node, expectedType)) return;
	// TypeScript parity: string literals get StringLiteral type when expectedType demands it
	if (expectedType != null) {
		const sd = node.data as StringLiteralData;
		if (expectedType.kind == TypeKind.StringLiteral && expectedType.typeName == sd.value) {
			node.nodeType = expectedType; return;
		}
		if (expectedType.kind == TypeKind.Union) {
			for (const child of expectedType.typeChildren) {
				if (child != null && child.kind == TypeKind.StringLiteral && child.typeName == sd.value) {
					node.nodeType = child; return;
				}
			}
			// All members are StringLiteral but value not found → type error
			let allStrLit = true;
			for (const child of expectedType.typeChildren) {
				if (child == null || child.kind != TypeKind.StringLiteral) allStrLit = false;
			}
			if (allStrLit && expectedType.typeChildren.length > 0) {
				addError(ctx, `Type '"${sd.value}"' is not assignable to type '${typeDisplayName(expectedType)}'` + typeofComparisonHint(expectedType, null), node.location.line, node.location.column);
				node.nodeType = stringType(); return;
			}
		}
	}
	node.nodeType = stringType(); return;
}

function checkBooleanLiteral(ctx: CheckerContext, node: Node, expectedType: Type | null): void {
	if (typeLiteralAgainstPayload(ctx, node, expectedType)) return;
	// TypeScript parity: boolean literals get BooleanLiteral type when expectedType demands it.
	// Required for discriminated union narrowing on `ok: true | false` discriminants.
	if (expectedType != null) {
		const bd = node.data as BooleanLiteralData;
		if (expectedType.kind == TypeKind.BooleanLiteral
			&& booleanLiteralValue(expectedType) == bd.boolValue) {
			node.nodeType = expectedType; return;
		}
		if (expectedType.kind == TypeKind.Union) {
			for (const child of expectedType.typeChildren) {
				if (child != null && child.kind == TypeKind.BooleanLiteral
					&& booleanLiteralValue(child) == bd.boolValue) {
					node.nodeType = child; return;
				}
			}
		}
	}
	node.nodeType = booleanType(); return;
}

function checkSpliceMany(ctx: CheckerContext, node: Node, expectedType: Type | null): void {
	if (node == ctx.stmtPosExpr) { node.nodeType = inferredType(); return; }
	const splice = createNodeAt(NodeKind.SpliceMany, node.data, node.location);
	const spliceValue = unwrapSpliceManyAtExpr(ctx, node, splice);
	if (spliceValue == null) { node.nodeType = errorType(); return; }
	node.kind = spliceValue.kind;
	node.data = spliceValue.data;
	if (spliceValue.location != null) node.location = spliceValue.location;
	node.nodeType = null as unknown as Type;
	node.resolvedSym = null;
	node.flags = 0 as BitSet<NodeFlag>;
	node.variantSlot = 0;
	checkExpr(ctx, node, expectedType);
	bindRefsToHoistedPrefix(node, splice);
	node.nodeType = node.nodeType; return;
}

function checkComptimeBlock(ctx: CheckerContext, node: Node, expectedType: Type | null): void {
	// Eagerly fold @comptime block — mirrors Phase B+ macro eager
	// expansion below. Without this, `const X = @comptime { ... }`
	// fossilizes X's symbol type as `unknown`, emitting `void* X` in C
	// codegen, because the post-check evaluateComptimeBlocks pass
	// replaces the AST node AFTER the variable's symbol type is set.
	markNamesUsed(ctx, node);
	if (insideGenericTemplate(ctx)) {
		node.nodeType = expectedType != null ? expectedType : inferredType();
		return;
	}
	const expanded = callEvalComptimeBlock(node, ctx);
	const staticType = expanded.nodeType;
	let expandedValue = expanded;
	const hoists = isHoistingSplice(ctx, node, expanded);
	if (hoists) {
		expandedValue = unwrapSpliceManyAtExpr(ctx, node, expanded);
		if (expandedValue == null) { node.nodeType = errorType(); return; }
	}
	node.kind = expandedValue.kind;
	node.data = expandedValue.data;
	if (expandedValue.typeArg != "") node.typeArg = expandedValue.typeArg;
	if (expandedValue.location != null) node.location = expandedValue.location;
	node.nodeType = null as unknown as Type;
	node.resolvedSym = null;
	node.flags = 0 as BitSet<NodeFlag>;
	node.variantSlot = 0;
	const valueType = expectedType != null || hoists || staticType == null || isUnresolvedType(staticType)
		|| staticType.kind == TypeKind.Error || staticType.kind == TypeKind.Void || isNodeGraphType(staticType)
		? expectedType : staticType;
	checkExpr(ctx, node, valueType);
	if (hoists) bindRefsToHoistedPrefix(node, expanded);
	node.nodeType = node.nodeType; return;
}

function checkUpdateExpr(ctx: CheckerContext, node: Node, expectedType: Type | null): void {
	const d = node.data as UpdateExprData;
	checkExpr(ctx, d.updateArg, null);
	reportSharedWrite(ctx, d.updateArg);
	if (d.updateArg.kind == NodeKind.MemberExpr) {
		const umd = d.updateArg.data as MemberExprData;
		if (umd.property == "length" && umd.object.nodeType != null &&
			(umd.object.nodeType.kind == TypeKind.Array || umd.object.nodeType.kind == TypeKind.SizedArray || umd.object.nodeType.kind == TypeKind.Span || isStringLike(umd.object.nodeType) || umd.object.nodeType.kind == TypeKind.CString)) {
			if (umd.object.nodeType.kind == TypeKind.SizedArray) {
				addError(ctx, "cannot modify 'length' on fixed-size array", d.updateArg.location.line, d.updateArg.location.column);
			} else {
				addError(ctx, "cannot use increment/decrement on 'length'; use 'arr.length = n' instead", d.updateArg.location.line, d.updateArg.location.column);
			}
		}
	}
	const ut = d.updateArg.nodeType;
	if (ut != null && (isNumeric(ut) || ut.kind == TypeKind.BigInt)) { node.nodeType = ut; return; }
	if (ut != null && ut.kind != TypeKind.Error) {
		addError(ctx, `increment/decrement needs a numeric operand, got '${typeDisplayName(ut)}'`, d.updateArg.location.line, d.updateArg.location.column);
	}
	node.nodeType = int32Type(); return;
}

function optionalRootOf(end: Node): Node | null {
	let link: Node = end;
	while (true) {
		if (link.kind == NodeKind.MemberExpr) {
			const d = link.data as MemberExprData;
			if (d.isOptional) return link;
			link = d.object;
		} else if (link.kind == NodeKind.ArrayAccess) {
			link = (link.data as ArrayAccessData).array;
		} else if (link.kind == NodeKind.CallExpr) {
			link = (link.data as CallExprData).callee;
		} else if (link.kind == NodeKind.TypeAssertion && (link.data as TypeAssertionData).asType == "!") {
			link = (link.data as TypeAssertionData).asExpr;
		} else {
			return null;
		}
	}
	return null;
}

function startsOptionalChain(node: Node): boolean {
	return node.flags.has(NodeFlag.OptionalChainEnd) || (node.kind == NodeKind.MemberExpr && (node.data as MemberExprData).isOptional);
}

function checkOptionalChain(ctx: CheckerContext, node: Node, expectedType: Type | null): void {
	node.flags = node.flags.excl(NodeFlag.OptionalChainEnd);
	const root = optionalRootOf(node);
	if (root == null) {
		checkExprKind(ctx, node, expectedType);
		return;
	}
	const rd = root.data as MemberExprData;
	const tested = rd.object;
	checkInTypeSlot(ctx, tested);
	if (tested.nodeType == null) {
		checkExprKind(ctx, node, expectedType);
		return;
	}
	if (!isNullableShape([tested.nodeType])) {
		checkExprKind(ctx, node, expectedType);
		rd.isOptional = false;
		return;
	}
	const loc = node.location;
	const probe = readsOnlyNames(tested) ? cloneNodeKeepSem(tested) : tested;
	rd.object = createNodeAt(NodeKind.TypeAssertion, { asExpr: tested, asType: "!" }, tested.location);
	rd.isOptional = false;
	const chain = createNodeAt(node.kind, node.data, loc);
	chain.flags = node.flags;
	chain.typeArg = node.typeArg;
	chain.typeExpr = node.typeExpr;
	const cond = createNodeAt(NodeKind.BinaryExpr, { operator: "!==", left: probe, right: typedNull(loc) }, loc);
	cond.nodeType = booleanType();
	const arms = { ternaryCondition: cond, ternaryConsequent: chain, ternaryAlternate: typedNull(loc) } as ConditionalExprData;
	ctx.condEvalDepth = ctx.condEvalDepth + 1;
	checkExpr(ctx, chain, null);
	ctx.condEvalDepth = ctx.condEvalDepth - 1;
	node.kind = NodeKind.ConditionalExpr;
	node.data = arms;
	node.resolvedSym = null;
	node.typeArg = "";
	node.typeExpr = null;
	node.nodeType = fitConditionalArms(ctx, arms, expectedType, false);
}

function typedNull(loc: SourceLocation): Node {
	const n = createNodeAt(NodeKind.NullLiteral, { nullPlaceholder: true }, loc);
	n.nodeType = nullType();
	return n;
}

function checkConditionalExpr(ctx: CheckerContext, node: Node, expectedType: Type | null): void {
	const d = node.data as ConditionalExprData;
	checkExpr(ctx, d.ternaryCondition, null);
	refuseFunctionTruthiness(ctx, d.ternaryCondition);
	const ternCondT = d.ternaryCondition.nodeType;
	if (ternCondT != null && ternCondT.kind == TypeKind.Void) {
		addError(ctx, "an expression of type 'void' cannot be tested for truthiness",
			d.ternaryCondition.location.line, d.ternaryCondition.location.column);
	}
	ctx.condEvalDepth = ctx.condEvalDepth + 1;
	checkExpr(ctx, d.ternaryConsequent, expectedType);
	checkExpr(ctx, d.ternaryAlternate, expectedType);
	ctx.condEvalDepth = ctx.condEvalDepth - 1;
	node.nodeType = fitConditionalArms(ctx, d, expectedType, node == ctx.conversionOperand); return;
}

function checkAwaitExpr(ctx: CheckerContext, node: Node, expectedType: Type | null): void {
	const d = node.data as AwaitExprData;
	checkExpr(ctx, d.awaitArg, null);
	const argType = d.awaitArg.nodeType;
	if (argType != null && isAwaitable(argType)) {
		const promiseInner = awaitedType(argType);
		node.nodeType = promiseInner != null ? promiseInner : inferredType();
		// PARALOCK Phase 1: consuming an affine-awaitable identifier records on
		// TWO channels:
		//   1. Branch-aware tracker (markConsumedName) — drives reuse detection
		//      (R2/E3) path-sensitively, so `if { await h; return; } await h`
		//      correctly sees h as free on the fall-through path.
		//   2. Monotonic symbol flag (markConsumed) — ensures scope-exit check
		//      passes for handles consumed on any branch, including exiting
		//      branches whose tracker state gets rolled back by the merge.
		if (isAffineAwaitable(argType) && d.awaitArg.kind == NodeKind.Identifier) {
			const idSym = d.awaitArg.resolvedSym;
			if (idSym != null) {
				markConsumedName(ctx.affineTracker, symbolConsumeKey(idSym));
				markConsumed(idSym);
			}
		}
		node.nodeType = node.nodeType; return;
	}
	node.nodeType = inferredType(); return;
}

function checkMoveExpr(ctx: CheckerContext, node: Node, expectedType: Type | null): void {
	const d = node.data as MoveExprData;
	// Validate operand: only identifiers, member access, array access, and calls allowed
	if (d.moveArg.kind != NodeKind.Identifier
		&& d.moveArg.kind != NodeKind.MemberExpr
		&& d.moveArg.kind != NodeKind.ArrayAccess
		&& d.moveArg.kind != NodeKind.CallExpr) {
		addError(ctx, "invalid 'move' operand: expected identifier, field access, array access, or call expression", node.location.line, node.location.column);
	}
	checkExpr(ctx, d.moveArg, null);
	const roMove = readonlyRootType(d.moveArg);
	if (roMove != null) {
		addError(ctx, "cannot move out of " + typeDisplayName(roMove) + " — a read-only view is borrowed, not owned; to hand a value to a spawn thunk, list it in spawn(fn, { move: [x] }) (PARALOCK E24)", node.location.line, node.location.column);
	} else if (d.moveArg.kind == NodeKind.MemberExpr || d.moveArg.kind == NodeKind.ArrayAccess) {
		const refusal = writeRefusal(d.moveArg, WriteSite.Assign);
		if (refusal != "") addError(ctx, refusal, d.moveArg.location.line, d.moveArg.location.column);
		if (d.moveArg.kind == NodeKind.MemberExpr) reportReadonlyField(ctx, d.moveArg);
	}
	// PARALOCK Phase 1: `move h` on an affine Promise counts as consumption.
	// Ownership transfers out of the current scope, so the binding must
	// not be awaited again — same consumption semantics as `await h`.
	const moveArgType = d.moveArg.nodeType;
	if (moveArgType != null && isAffineAwaitable(moveArgType) && d.moveArg.kind == NodeKind.Identifier) {
		const idSym = d.moveArg.resolvedSym;
		if (idSym != null) {
			markConsumedName(ctx.affineTracker, symbolConsumeKey(idSym));
			markConsumed(idSym);
		}
	}
	node.nodeType = d.moveArg.nodeType; return;
}

function checkSizeofExpr(ctx: CheckerContext, node: Node, expectedType: Type | null): void {
	const d = node.data as SizeofExprData;
	const resolved = resolveAnnotation(d.sizeofType, ctx, 0, 0);
	resolveTypeExpr(node.typeExpr, ctx);
	// Generic operand: leave unfolded so mono substitutes sizeofType→concrete, then the instance re-check folds the real size.
	if (resolved.kind == TypeKind.GenericParam || hasGenericParams(resolved)) { node.nodeType = int32Type(); return; }
	const size = sizeOfType(ctx.targetInfo, resolved);
	if (size < 0) {
		if (resolved.kind == TypeKind.Void || isUnresolvedType(resolved) || isUnknownType(resolved)) {
			addError(ctx, `'sizeof' needs a type with a known layout — '${d.sizeofType}' has none here`,
				node.location.line, node.location.column);
			node.nodeType = int32Type(); return;
		}
		d.sizeofResolved = resolved;
		node.nodeType = int32Type(); return;
	}
	node.kind = NodeKind.NumberLiteral;
	node.data = { value: size as number, isFloat: false, intVal: size as int64 };
	node.nodeType = int32Type(); return;
}

function checkHiddenDeref(ctx: CheckerContext, node: Node, expectedType: Type | null): void {
	const d = node.data as HiddenDerefData;
	checkExpr(ctx, d.expr, null);
	if (node.flags.has(NodeFlag.ExplicitDeref)) {
		checkExplicitDeref(ctx, node, d.expr);
		return;
	}
	if (node.nodeType == null) {
		const inner = d.expr.nodeType;
		node.nodeType = (inner != null && inner.kind == TypeKind.Ref && inner.typeReturn != null)
			? inner.typeReturn
			: inner;
	}
	return;
}

function checkBinaryExpr(ctx: CheckerContext, node: Node, expectedType: Type | null): void {
	const d = node.data as BinaryExprData;
	// Ref parity: leftPartOfAsgn
	const isAsgn = d.operator == "=" || d.operator == "+=" || d.operator == "-=" ||
		d.operator == "*=" || d.operator == "/=" || d.operator == "%=" ||
		d.operator == "&&=" || d.operator == "||=" || d.operator == "??=" ||
		isBitwiseCompoundOp(d.operator);
	if (isAsgn && node != ctx.stmtPosExpr) {
		addError(ctx, "assignment is a statement, not an expression - assign first, then use the variable: 'x = f(); while (x !== null) { ... }'", node.location.line, node.location.column);
	}
	if (d.operator == "=" && d.left.kind == NodeKind.ArrayAccess && (d.left.data as ArrayAccessData).array != null) {
		const target = d.left.data as ArrayAccessData;
		ctx.initTracker.leftPartOfAsgn = ctx.initTracker.leftPartOfAsgn + 1;
		checkExpr(ctx, target.array, null);
		ctx.initTracker.leftPartOfAsgn = ctx.initTracker.leftPartOfAsgn - 1;
		if (target.array.nodeType != null && declaresSubscript(ctx, peelTransparentInstance(target.array.nodeType), "[]=")) {
			const sargs: Node[] = [];
			sargs.push(target.index);
			sargs.push(d.right);
			node.nodeType = rewriteAsMethodCall(ctx, node, target.array, "[]=", sargs); return;
		}
	}
	if (isAsgn) {
		ctx.initTracker.leftPartOfAsgn = ctx.initTracker.leftPartOfAsgn + 1;
	}
	if (isAsgn && d.left.kind == NodeKind.ArrayLiteral) {
		if (d.operator != "=") addError(ctx, "a destructuring pattern can only be assigned with '='", d.left.location.line, d.left.location.column);
		checkAssignTarget(ctx, d.left);
	} else {
		checkExpr(ctx, d.left, wideOperandLiteralSlot(d.left));
	}
	let leftType = d.left.nodeType;
	if (isAsgn) {
		ctx.initTracker.leftPartOfAsgn = ctx.initTracker.leftPartOfAsgn - 1;
	}
	if (isAsgn) { reportSharedWrite(ctx, d.left); }
	if (isAsgn && !isLocation(d.left) && d.left.kind != NodeKind.ArrayLiteral && d.left.kind != NodeKind.ObjectLiteral
			&& d.left.nodeType != null && d.left.nodeType.kind != TypeKind.Error) {
		addError(ctx, "this expression cannot be assigned to — it is not a variable, nor a field or element reached from one or through a reference", d.left.location.line, d.left.location.column);
	}
	// Block assignment to read-only properties
	if (isAsgn && d.left.kind == NodeKind.MemberExpr) {
		const md = d.left.data as MemberExprData;
		reportReadonlyField(ctx, d.left);
		// Built-in readonly: str.length, sized-array.length
		if (md.property == "length" && md.object.nodeType != null) {
			if (isStringLike(md.object.nodeType) || md.object.nodeType.kind == TypeKind.CString) {
				addError(ctx, "cannot assign to 'length' on string (strings are immutable)", d.left.location.line, d.left.location.column);
			} else if (md.object.nodeType.kind == TypeKind.SizedArray) {
				addError(ctx, "cannot modify 'length' on fixed-size array", d.left.location.line, d.left.location.column);
			} else if (md.object.nodeType.kind == TypeKind.Array && d.operator != "=") {
				addError(ctx, "compound assignment to 'length' is not allowed; use 'arr.length = arr.length " + d.operator.slice(0, d.operator.length - 1) + " n' instead", d.left.location.line, d.left.location.column);
			}
		}
		const discUnion = literalDiscriminantOwner(md);
		if (discUnion != null) {
			addError(ctx, `cannot assign to '${md.property}': it is the discriminant of '${typeDisplayName(discUnion)}' — assign a whole value of the other variant instead`,
				d.left.location.line, d.left.location.column);
		}
	}
	const rightExpected = d.operator == "=" ? leftType : (d.operator == "??" ? nullishArmExpected(expectedType) : wideOperandLiteralSlot(d.right));
	const rhsGuarded = d.operator == "&&" || d.operator == "||" || d.operator == "??";
	if (rhsGuarded) ctx.condEvalDepth = ctx.condEvalDepth + 1;
	if (d.operator == "instanceof") checkInTypeSlot(ctx, d.right);
	else checkExpr(ctx, d.right, rightExpected);
	if (rhsGuarded) ctx.condEvalDepth = ctx.condEvalDepth - 1;
	let rightType = d.right.nodeType;
	if (!isAsgn && d.operator != "??") {
		if (d.operator == "&&" || d.operator == "||") {
			refuseFunctionTruthiness(ctx, d.left);
			leftType = d.left.nodeType;
		}
		const leftConverted = operandConverter(ctx, d.operator, d.left, leftType, rightType, true);
		if (leftConverted != null) { d.left = leftConverted; leftType = leftConverted.nodeType; }
		const rightConverted = leftConverted != null ? null : operandConverter(ctx, d.operator, d.right, leftType, rightType, false);
		if (rightConverted != null) { d.right = rightConverted; rightType = rightConverted.nodeType; }
		if (operandReadsValue(ctx, d.operator, leftType, rightType, true) && valueOfInPlace(ctx, d.left)) leftType = d.left.nodeType;
		if (operandReadsValue(ctx, d.operator, leftType, rightType, false) && valueOfInPlace(ctx, d.right)) rightType = d.right.nodeType;
	} else if (isAsgn) {
		const rightConverted = operandConverter(ctx, d.operator, d.right, leftType, rightType, false);
		if (rightConverted != null) {
			d.right = rightConverted;
			rightType = rightConverted.nodeType;
		} else if (operandReadsValue(ctx, d.operator, leftType, rightType, false) && valueOfInPlace(ctx, d.right)) {
			rightType = d.right.nodeType;
		}
	}
	// Parity: standard reference node fitting — insert HiddenStdConv for narrowing assignment
	if (d.operator == "=" && leftType != null) {
		d.right = fitNode(ctx, d.right, leftType, rightType);
	}
	// Null RHS routes through the same relation as literal-field init
	// (semAsgn→fitNode→typeRel parity, scoped to Null: no flow-narrowing
	// dependency, so the terminal fitNode scope is not re-opened).
	if (d.operator == "=" && leftType != null && d.right.nodeType != null
			&& d.right.nodeType.kind == TypeKind.Null
			&& !isUnresolvedType(leftType)
			&& leftType.kind != TypeKind.Error
			&& !isAssignable(d.right.nodeType, leftType)) {
		addError(ctx,
			"Type 'null' is not assignable to type '" + typeDisplayName(leftType) + "'",
			d.right.location.line, d.right.location.column);
	}
	if (isAsgn && d.left.kind == NodeKind.MemberExpr && d.left.nodeType != null && isUnresolvedType(d.left.nodeType)) {
		const md = d.left.data as MemberExprData;
		const recvType = md.object.nodeType;
		if (recvType != null && findAccessor(ctx, recvType, "set_" + md.property) != null) {
			node.nodeType = callSetter(ctx, node, d, md); return;
		}
		if (recvType != null && findAccessor(ctx, recvType, "get_" + md.property) != null) {
			addError(ctx, `Cannot assign to '${md.property}' because it is a read-only property: it has a getter and no setter`, d.left.location.line, d.left.location.column);
			node.nodeType = errorType(); return;
		}
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
	if (checkAssignmentWrite(ctx, node, d, isAsgn)) return;
	// Ref parity: initVar on assignment LHS
	if (isAsgn && d.left.kind == NodeKind.Identifier) {
		const lhsId = d.left.data as IdentifierData;
		// Ref parity: nfFirstWrite — set when first assignment is in same block as declaration
		if (!isInitialized(ctx.initTracker, lhsId.name)) {
			if (getDeclBlock(ctx.initTracker, lhsId.name) == ctx.initTracker.currentBlock) {
				node.flags = node.flags.incl(NodeFlag.FirstWrite);
			}
		}
		markInitialized(ctx.initTracker, lhsId.name);
		// Phase 4: reassignment invalidation now flows through the
		// binder's FlowAssignment node — no fact stack to purge.
	}
	if (isAsgn && ctx.ctorExits != null && d.left.kind == NodeKind.MemberExpr) {
		const lhsMember = d.left.data as MemberExprData;
		let lhsObject = lhsMember.object;
		if (lhsObject.kind == NodeKind.HiddenDeref) lhsObject = (lhsObject.data as HiddenDerefData).expr;
		if (lhsObject.kind == NodeKind.Identifier && (lhsObject.data as IdentifierData).name == "this") {
			markInitialized(ctx.initTracker, "this." + lhsMember.property);
		}
	}
	typeBinaryOperands(ctx, node, d, isAsgn, leftType, rightType, expectedType);
}

function checkAssignmentWrite(ctx: CheckerContext, node: Node, d: BinaryExprData, isAsgn: boolean): boolean {
	if (isAsgn && d.left.kind == NodeKind.MemberExpr
			&& d.left.nodeType != null
			&& isUnresolvedType(d.left.nodeType)
			&& ctx.extensionRegistry != null) {
		const md = d.left.data as MemberExprData;
		if (md.object.nodeType != null && md.property != "setDynamicField") {
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
				if (probeType.kind == TypeKind.Alias && probeType.typeReturn != null) {
					probeType = probeType.typeReturn;
					continue;
				}
				if (probeType.kind == TypeKind.Ref && probeType.typeReturn != null) {
					probeType = probeType.typeReturn;
					continue;
				}
				break;
			}
			const peeled = peelToStructOrUnion(probeType);
			if (peeled != null) probeType = peeled;
			let propertyExists = !isUnresolvedType(getProperty(probeType, md.property))
				|| (probeType.typeNames != null && probeType.typeNames.indexOf(md.property) >= 0);
			if (!propertyExists && probeType.typeName != "") {
				const classSym = lookupSymbol(ctx.table, probeType.typeName);
				if (classSym != null) {
					ensureShaped(classSym, ctx);
					let classStruct = classSym.symbolType;
					if (classStruct != null && classStruct.kind == TypeKind.Alias && classStruct.typeReturn != null) {
						classStruct = classStruct.typeReturn;
					}
					if (classStruct != null && classStruct.kind == TypeKind.Ref && classStruct.typeReturn != null) {
						classStruct = classStruct.typeReturn;
					}
					if (classStruct != null && (classStruct.kind == TypeKind.Struct || classStruct.kind == TypeKind.Union)) {
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
			if (!propertyExists && recvType.sym != null) {
				ensureShaped(recvType.sym, ctx);
				let symType = recvType.sym.symbolType;
				let _h = 0;
				while (symType != null && _h < 4) {
					_h = _h + 1;
					if (symType.kind == TypeKind.Alias && symType.typeReturn != null) { symType = symType.typeReturn; continue; }
					if (symType.kind == TypeKind.Ref && symType.typeReturn != null) { symType = symType.typeReturn; continue; }
					break;
				}
				if (symType != null && (symType.kind == TypeKind.Struct || symType.kind == TypeKind.Union)
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
					if (recvType.typeName != "") recvNames.push(recvType.typeName);
					if (probeType.typeName != "" && probeType.typeName != recvType.typeName) recvNames.push(probeType.typeName);
					if (recvType.sym != null && recvType.sym.name != "") {
						let alreadyIn = false;
						for (const n of recvNames) { if (n == recvType.sym.name) alreadyIn = true; }
						if (!alreadyIn) recvNames.push(recvType.sym.name);
					}
					for (const e of setExts) {
						if (e.receiverTypeName == "") continue;
						for (const rn of recvNames) {
							if (e.receiverTypeName == rn) { extMatch = true; break; }
						}
						if (extMatch) break;
					}
				}
				if (extMatch) {
					if (d.operator != "=") {
						const lhsRead = d.operator.slice(0, d.operator.length - 1);
						addError(ctx,
							`compound assignment '${d.operator}' is not supported on dynamic field '${md.property}'; rewrite as 'expr.${md.property} = expr.${md.property} ${lhsRead} value'`,
							node.location.line, node.location.column);
						node.nodeType = errorType(); return true;
					}
					const keyLit = createNodeAt(NodeKind.StringLiteral, { value: md.property }, node.location);
					const wargs: Node[] = [];
					wargs.push(keyLit);
					wargs.push(d.right);
					node.nodeType = rewriteAsMethodCall(ctx, node, md.object, "setDynamicField", wargs); return true;
				}
			}
		}
	}
	// Strings are immutable at the surface (docs/STRING-CONTRACT.md);
	// the byte-mutation story is the uint8[] buffer tier.
	if (isAsgn && d.left.kind == NodeKind.ArrayAccess) {
		const sad = d.left.data as ArrayAccessData;
		let strObjType = sad.array.nodeType;
		if (strObjType != null && strObjType.kind == TypeKind.Ref && strObjType.typeReturn != null) {
			strObjType = strObjType.typeReturn;
		}
		if (strObjType != null && isStringLike(strObjType)) {
			addError(ctx, "strings are immutable - mutate bytes via uint8[] (asBytes/asString) instead",
				node.location.line, node.location.column);
			node.nodeType = errorType(); return true;
		}
	}
	// HashMap<K,V> subscript write: `m[k] = v` → `m.set(k, v)`. Mutate the
	// whole BinaryExpr into a method call so the existing extension
	// resolution + lowering path handles it. Counterpart of the read-case
	// mutation in the ArrayAccess arm above.
	if (d.operator == "=" && d.left.kind == NodeKind.ArrayAccess) {
		const ad = d.left.data as ArrayAccessData;
		let setObjType = ad.array.nodeType;
		if (setObjType != null && setObjType.kind == TypeKind.Ref && setObjType.typeReturn != null) {
			setObjType = setObjType.typeReturn;
		}
		// cstring is an immutable FFI bridge — caller must materialise a
		// `string` before mutating bytes. Nim parity (jsgen.nim:1285).
		if (setObjType != null && setObjType.kind == TypeKind.CString) {
			addError(ctx, "cstring doesn't support `[]=` operator — convert to string first",
				node.location.line, node.location.column);
			node.nodeType = errorType(); return true;
		}
		if (setObjType != null && setObjType.kind == TypeKind.GenericInstance
			&& isIndexableMapType(setObjType)) {
			const wargs: Node[] = [];
			wargs.push(ad.index);
			wargs.push(d.right);
			node.nodeType = rewriteAsMethodCall(ctx, node, ad.array, "set", wargs); return true;
		}
	}
	return false;
}

function typeBinaryOperands(ctx: CheckerContext, node: Node, d: BinaryExprData, isAsgn: boolean, leftType: Type | null, rightType: Type | null, expectedType: Type | null): void {
	// Post-hoc literal coercion: if one side is typed integer and other is integer literal that fits, coerce.
	// Example: `h: int64; h * 33` — coerces literal 33 (default int32) to int64.
	let effLeft = leftType != null ? peelTransparentInstance(leftType) : null;
	let effRight = rightType != null ? peelTransparentInstance(rightType) : null;
	const rightAsFloat32 = leftType != null && leftType.kind == TypeKind.Float32 ? constantAdoptsFloat32(d.right) : null as unknown as Node;
	const leftAsFloat32 = rightAsFloat32 == null && !isAsgn && rightType != null && rightType.kind == TypeKind.Float32 ? constantAdoptsFloat32(d.left) : null as unknown as Node;
	if (isIntegerType(leftType) && rightType != null
		&& isNodeIntLit(d.right) && literalFitsInType(d.right, leftType!, false)) {
		effRight = leftType;
		d.right.nodeType = leftType;
	} else if (isIntegerType(rightType) && leftType != null
		&& isNodeIntLit(d.left) && literalFitsInType(d.left, rightType!, false)) {
		effLeft = rightType;
		d.left.nodeType = rightType;
	} else if (leftType != null && leftType.kind == TypeKind.Float32 && literalAdoptsFloat32(d.right)) {
		reportFloat32LiteralRange(ctx, d.right);
		effRight = leftType;
		d.right.nodeType = leftType;
	} else if (rightType != null && rightType.kind == TypeKind.Float32 && literalAdoptsFloat32(d.left)) {
		reportFloat32LiteralRange(ctx, d.left);
		effLeft = rightType;
		d.left.nodeType = rightType;
	} else if (rightAsFloat32 != null) {
		reportFloat32LiteralRange(ctx, rightAsFloat32);
		d.right = rightAsFloat32;
		effRight = leftType;
	} else if (leftAsFloat32 != null) {
		reportFloat32LiteralRange(ctx, leftAsFloat32);
		d.left = leftAsFloat32;
		effLeft = rightType;
	} else {
		const constRight = constantOperandAs(d.right, d.left, leftType);
		const constLeft = constRight == null && !isAsgn ? constantOperandAs(d.left, d.right, rightType) : null as unknown as Node;
		if (constRight != null) {
			d.right = constRight;
			effRight = leftType;
		} else if (constLeft != null) {
			d.left = constLeft;
			effLeft = rightType;
		}
	}
	if (d.operator == "instanceof" && d.right.resolvedSym != null
		&& d.right.resolvedSym.symbolKind == SymbolKind.Class && symGenericParams(d.right.resolvedSym) != "") {
		addError(ctx, "instanceof cannot test the generic class " + d.right.resolvedSym.name + " without its type arguments — each instance has its own identity; read it with `as " + d.right.resolvedSym.name + "<…>`", d.right.location.line, d.right.location.column);
	}
	// Bitwise ops require integer operands (reference parity: no float overloads)
	// Insert implicit number → int32 cast for C backend
	if ((isUnknownType(effLeft) || isUnknownType(effRight))
		&& d.operator != "=" && d.operator != "===" && d.operator != "!=="
		&& d.operator != "==" && d.operator != "!="
		&& d.operator != "&&" && d.operator != "||" && d.operator != "??"
		&& d.operator != "&&=" && d.operator != "||=" && d.operator != "??="
		&& d.operator != "instanceof") {
		addError(ctx, "operator '" + d.operator + "' cannot be applied to 'unknown' — narrow with an explicit cast", node.location.line, node.location.column);
	}
	const voidLeft = effLeft != null && effLeft.kind == TypeKind.Void;
	const voidRight = effRight != null && effRight.kind == TypeKind.Void;
	if ((voidLeft || voidRight) && d.operator != "=") {
		const voidOther = voidLeft ? effRight : effLeft;
		const isEqOp = d.operator == "===" || d.operator == "!=="
			|| d.operator == "==" || d.operator == "!=";
		const otherNullish = voidOther != null
			&& (voidOther.kind == TypeKind.Null || voidOther.kind == TypeKind.Void);
		const concatOk = d.operator == "+" && voidOther != null && isStringLike(voidOther);
		const nullishOk = d.operator == "??" || d.operator == "??=";
		if (d.operator == "&&" || d.operator == "||"
			|| d.operator == "&&=" || d.operator == "||=") {
			addError(ctx, "an expression of type 'void' cannot be tested for truthiness",
				node.location.line, node.location.column);
		} else if (isEqOp && !otherNullish) {
			addError(ctx, "comparison of 'void' and '" + typeDisplayName(voidOther!)
				+ "' — the types have no overlap; a void result only equals null",
				node.location.line, node.location.column);
		} else if (!isEqOp && !concatOk && !nullishOk) {
			addError(ctx, "operator '" + d.operator
				+ "' cannot be applied to 'void' — a void call produces no value",
				node.location.line, node.location.column);
		}
	}
	if (isBitwiseBinaryOp(d.operator)) {
		const userBitwise = declaredOperatorResult(ctx, d.operator, effLeft, effRight);
		if (userBitwise != null) {
			node.flags = node.flags.incl(NodeFlag.UserOp);
			node.nodeType = userBitwise; return;
		}
		checkBitwiseOperands(ctx, d.operator, effLeft!, effRight!, node);
		if (effLeft != null && effLeft.kind == TypeKind.Number) {
			d.left = wrapInConv(d.left, createPrimitive(TypeKind.Int32));
			effLeft = createPrimitive(TypeKind.Int32);
		}
		if (effRight != null && effRight.kind == TypeKind.Number) {
			d.right = wrapInConv(d.right, createPrimitive(TypeKind.Int32));
			effRight = createPrimitive(TypeKind.Int32);
		}
	} else if (isBitwiseCompoundOp(d.operator)) {
		const bitMark = ctx.errors.length;
		checkBitwiseOperands(ctx, d.operator, effLeft!, effRight!, node);
		if (reportedErrorSince(ctx, bitMark)) { node.nodeType = errorType(); return; }
		if (effRight != null && effRight.kind == TypeKind.Number) {
			d.right = wrapInConv(d.right, createPrimitive(TypeKind.Int32));
			effRight = createPrimitive(TypeKind.Int32);
		}
	}
	if (d.operator == "+" && effLeft != null && effRight != null) {
		if (effLeft.kind == TypeKind.CString && isStringLike(effRight)) {
			d.left = wrapInConv(d.left, stringType());
			effLeft = stringType();
		}
		if (effRight.kind == TypeKind.CString && isStringLike(effLeft)) {
			d.right = wrapInConv(d.right, stringType());
			effRight = stringType();
		}
	}
	if ((d.operator == "+" || d.operator == "+=") && effLeft != null && effRight != null) {
		if (isStringLike(effLeft) && !isStringLike(effRight)) {
			const convRight = synthStringify(ctx, d.right);
			if (convRight != null) {
				d.right = convRight;
				effRight = stringType();
			}
		} else if (d.operator == "+" && isStringLike(effRight) && !isStringLike(effLeft)) {
			const convLeft = synthStringify(ctx, d.left);
			if (convLeft != null) {
				d.left = convLeft;
				effLeft = stringType();
			}
		}
	}
	const isArithmeticOp = d.operator == "+" || d.operator == "-" || d.operator == "*"
		|| d.operator == "/" || d.operator == "%" || d.operator == "**";
	if (isArithmeticOp || isComparisonOp(d.operator)) {
		const userResult = declaredOperatorResult(ctx, d.operator, effLeft, effRight);
		if (userResult != null) {
			node.flags = node.flags.incl(NodeFlag.UserOp);
			node.nodeType = userResult; return;
		}
	}
	const isRelational = d.operator == "<" || d.operator == ">" || d.operator == "<=" || d.operator == ">=";
	const isConcat = d.operator == "+" && (isStringLike(effLeft) || isStringLike(effRight));
	if ((isArithmeticOp || isRelational) && !isConcat
		&& (isMaybeType(effLeft) || isMaybeType(effRight))) {
		const maybeSide = isMaybeType(effLeft) ? effLeft : effRight;
		const innerName = maybeSide.typeReturn != null ? typeDisplayName(maybeSide.typeReturn) : "T";
		addError(ctx, "operand of '" + d.operator + "' is possibly null (" + innerName + " | null) — unwrap with '!', '??', or a null check first", node.location.line, node.location.column);
		node.nodeType = isRelational ? booleanType() : ((maybeSide.typeReturn != null) ? maybeSide.typeReturn : inferredType());
		return;
	}
	if (refuseDisjointStrings(ctx, d.operator, d.left, d.right, node)) { node.nodeType = errorType(); return; }
	const tplOpName = (d.operator == "!=" || d.operator == "!==") ? "!="
		: ((d.operator == ">" || d.operator == ">=") ? d.operator : "");
	if (tplOpName != "" && effLeft != null && effRight != null
		&& !isMaybeType(effLeft) && !isMaybeType(effRight)
		&& effLeft.kind != TypeKind.Null && effRight.kind != TypeKind.Null
		&& !hasGenericParams(effLeft) && !hasGenericParams(effRight)
		&& ((isStringLike(effLeft) && isStringLike(effRight))
			|| (isStructOperand(effLeft) && isStructOperand(effRight) && typeNameOf(effLeft) == typeNameOf(effRight))
			|| (effLeft.kind == TypeKind.Tuple && effRight.kind == TypeKind.Tuple)
			|| (tplOpName == "!=" && effLeft.kind == TypeKind.SizedArray
				&& effRight.kind == TypeKind.SizedArray)
			|| (effLeft.kind == TypeKind.Ref && effRight.kind == TypeKind.Ref && typeNameOf(effLeft) == typeNameOf(effRight)))) {
		const opConc = ctx.extensionRegistry != null
			? resolveOperatorCall(ctx.table, ctx.extensionRegistry, tplOpName, [effLeft, effRight])
			: null as unknown as ExtensionMethod;
		if (opConc == null) {
			const opSym = lookupSymbol(ctx.table, tplOpName);
			if (opSym != null) {
				const tplCands = [opSym];
				for (const ov of opSym.overloads) tplCands.push(ov);
				for (const cand of tplCands) {
					if (!isTemplateSym(cand)) continue;
					const synthCall = { callee: null as unknown as Node, arguments: [d.left, d.right], isDirectCall: false, resolvedOverloadIdx: -1 } as CallExprData;
					node.nodeType = expandTemplate(ctx, cand, node, synthCall, expectedType);
					return;
				}
			}
		}
	}
	if (isRelational) checkRelationalOperands(ctx, d.operator, effLeft!, effRight!, node);
	if (isComparisonOp(d.operator)) refuseMixedSignedCompare(ctx, d.operator, effLeft, effRight, node);
	if (rejectBigIntMix(ctx, d.operator, effLeft, effRight, node)) { node.nodeType = errorType(); return; }
	if (rejectLossyIntFloatMix(ctx, d.operator, d.left, d.right, effLeft, effRight)) { node.nodeType = errorType(); return; }
	if (checkBinaryOperands(ctx, d.operator, effLeft!, effRight!, node)) { node.nodeType = errorType(); return; }
	if (compoundOperandRefuses(d.operator, effLeft, effRight)) {
		reportCompoundOperand(ctx, d.operator, d.left, d.right, effRight!, effLeft!);
		node.nodeType = errorType();
		return;
	}
	if (isBitwiseCompoundOp(d.operator) && effLeft != null && effRight != null) {
		const base = d.operator.slice(0, d.operator.length - 1);
		const stored = inferBinaryOp(base, effLeft, effRight);
		if (stored != null && !isAssignable(stored, effLeft)) {
			addError(ctx, "'" + d.operator + "' cannot store the '" + typeDisplayName(stored) + "' result of '" + base + "' in '"
				+ typeDisplayName(effLeft) + "'", node.location.line, node.location.column);
			node.nodeType = errorType();
			return;
		}
	}
	const nullishJoined = d.operator == "??" ? fitNullishArms(ctx, d, effLeft, effRight, expectedType, node == ctx.conversionOperand) : null;
	if (nullishJoined != null) { node.nodeType = nullishJoined; return; }
	node.nodeType = exactConstantType(ctx, node, inferBinaryOp(d.operator, effLeft!, effRight!));
	if (d.operator == "??" && node.nodeType != null && isMaybeType(node.nodeType)) {
		d.right = fitJoinedBranch(ctx, d.right, node.nodeType);
	}
}

function checkObjectLiteral(ctx: CheckerContext, node: Node, expectedType: Type | null): void {
	const d = node.data as ObjectLiteralData;
	// Unwrap ownership modifiers (Sink/Lent/Var) and Ref — transparent wrappers.
	// Reference parity: skipTypes({tySink, tyOwned})
	let objExpected = skipModifier(expectedType);
	// Union(Ref<T>, Null) — pick the Ref member for context propagation.
	// Source-level nullable type is preserved on node.nodeType below; this
	// only affects how field-types flow into the literal's properties.
	if (objExpected != null) {
		const refMember = unwrapRefNullUnion(objExpected);
		if (refMember != null) objExpected = refMember;
	}
	if (objExpected != null && isAtomicRef(objExpected) && !isLockedRef(objExpected)
		&& objExpected.typeReturn != null && !hasGenericParams(objExpected.typeReturn)) {
		checkArcPointeeSendable(ctx, objExpected.typeReturn, node.location.line, node.location.column);
	}
	// Unwrap Ref for class types — ObjectLiteral constructs the inner struct
	if (objExpected != null && objExpected.kind == TypeKind.Ref && objExpected.typeReturn != null) {
		objExpected = objExpected.typeReturn;
	}
	// Unwrap Maybe<T> for inner shape matching — `{ kind: 7 }` flowing into
	// a `Token | null` slot matches Token's fields, not Maybe<Token>'s
	// `{ value, present }` wrapper. fitNode at the call site inserts the
	// wrap after this node is shape-checked. Mirrors the Ref/Union peels above.
	if (objExpected != null && isMaybeType(objExpected) && objExpected.typeReturn != null) {
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
	if (objExpected != null && objExpected.kind == TypeKind.GenericInstance
		&& isIndexableMapType(objExpected)
		&& objExpected.typeChildren != null && objExpected.typeChildren.length == 2) {
		const mapKeyType = objExpected.typeChildren[0];
		const mapValType = objExpected.typeChildren[1];
		// 1. Validate every value against V and emit errors on mismatch.
		let mli = 0;
		while (mli < d.properties.length) {
			checkExpr(ctx, d.properties[mli], mapValType);
			const vt = d.properties[mli].nodeType;
			if (vt != null && mapValType != null && !isAssignable(vt, mapValType)) {
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
			kNode.flags = kNode.flags.incl(NodeFlag.Sem);
			keyNodes.push(kNode);
			ki = ki + 1;
		}
		const keysArr = createNode(NodeKind.ArrayLiteral, { elements: keyNodes }, mtok);
		keysArr.nodeType = createRef(createArray(mapKeyType));
		keysArr.flags = keysArr.flags.incl(NodeFlag.Sem);
		// 3. Build values array — reuse the already-checked property nodes.
		const valNodes: Node[] = [];
		let vi = 0;
		while (vi < d.properties.length) {
			valNodes.push(d.properties[vi]);
			vi = vi + 1;
		}
		const valsArr = createNode(NodeKind.ArrayLiteral, { elements: valNodes }, mtok);
		valsArr.nodeType = createRef(createArray(mapValType));
		valsArr.flags = valsArr.flags.incl(NodeFlag.Sem);
		// 4. Build the builder callee (mapFromPairs for ordered Map,
		// hashMapFromPairs for HashMap) + mutate this node into the call.
		const builderName = objExpected.typeName == "HashMap" ? "hashMapFromPairs" : "mapFromPairs";
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
		node.flags = node.flags.excl(NodeFlag.Sem);
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
	const literalOwnerSym = declaringSymOf(objExpected);
	const literalClassType = objExpected;
	objExpected = peelToStructOrUnion(objExpected);
	// A generic-containing expected type (un-instantiated formal like
	// `{ v: T }` at a call site whose T is still unbound) must NOT be
	// adopted: stamping it makes the literal's type identical to the
	// formal, so unifyType's identity check derives zero bindings and
	// the generic is never instantiated (loud missing-symbol C error),
	// while the literal's fields emit as void*. Fall through to the
	// self-synthesized anonymous struct — unification against the formal
	// then binds T from the literal's own concrete field types.
	if (objExpected != null && objExpected.kind == TypeKind.Struct
		&& objExpected.typeChildren != null
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
		if (stampType != null && isMaybeType(stampType)) {
			stampType = stampType.typeReturn != null ? stampType.typeReturn : objExpected;
		}
		const stampRef = stampType != null ? unwrapRefNullUnion(stampType) : null;
		if (stampRef != null) stampType = stampRef;
		node.nodeType = (stampType != null) ? stampType : objExpected;
		// Pin to consts so the inner while-loop body sees non-null typeNames/
		// typeChildren — flow narrowing on `let objExpected` doesn't reach
		// inside nested loops via the binder's current narrowing rules.
		const objE = objExpected;
		const objNames = objE.typeNames;
		const objChildren = objE.typeChildren;
		const containerName = objE.typeName != null ? objE.typeName : "";
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
			if (keyName != "" && keyName != "..." && keyName != "__computed__"
				&& objNames != null) {
				let ni = 0;
				while (ni < objNames.length) {
					if (objNames[ni] == keyName) {
						if (ni < objChildren.length) {
							fieldExpected = objChildren[ni];
						}
						break;
					}
					ni = ni + 1;
				}
			}
			// Fallback: positional match for spread/computed keys
			if (fieldExpected == null && (keyName == "..." || keyName == "__computed__")
				&& fi < objChildren.length) {
				fieldExpected = objChildren[fi];
			}
			if (fieldExpected == null) {
				fieldExpected = engineNodeVirtualKeyType(objE, keyName);
			}
			// Engine (macro-body) view of Node.nodeType, write position: macros
			// stamp type-AST Nodes into emitted literals (`nodeType: ft`), so the
			// slot expects a Node VALUE — Ref<Node>, matching the read override in
			// checkMemberExpr — not the checker Type the class declares.
			if (fieldExpected != null && isEngineCheckMode()
					&& keyName == "nodeType" && containerName == "Node") {
				fieldExpected = (expectedType != null && typeNameOf(expectedType) == "Node")
					? expectedType
					: objE;
			}
			checkExpr(ctx, d.properties[fi], fieldExpected);
			if (fieldExpected != null) {
				d.properties[fi] = fitNode(ctx, d.properties[fi], fieldExpected, d.properties[fi].nodeType);
			}
			refuseHiddenFieldInLiteral(ctx, literalOwnerSym != null ? literalOwnerSym : objE.sym, keyName, d.properties[fi], node, d, fi);
			// Record property key as reference to struct field
			if (fi < d.keys.length && d.keyLocations != null && fi < d.keyLocations.length && fieldExpected != null) {
				const keyLoc = d.keyLocations[fi];
				if (keyName != "..." && keyName != "__computed__" && keyLoc.line > 0) {
					let fieldSym: Symbol | null = null;
					if (containerName != "") {
						fieldSym = lookupSymbol(ctx.table, containerName + "_" + keyName);
						if (fieldSym != null) ensureShaped(fieldSym, ctx);
					}
					if (fieldSym == null) {
						fieldSym = makeSymbolState(keyName, SymbolKind.Property, fieldExpected, false, SymbolState.Shaped);
						inheritContainerInfo(fieldSym, ctx, containerName);
					}
					sgRecordSym(ctx, keyLoc.line, keyLoc.column, keyLoc.column + keyName.length, fieldSym, fieldExpected, SymbolKind.Property, keyName, containerName, false);
				}
			}
			fi = fi + 1;
		}
		// Excess property + duplicate field check
		if (objNames != null) {
			let ki = 0;
			while (ki < d.keys.length) {
				const key = d.keys[ki];
				if (key != "..." && key != "__computed__") {
					let found = false;
					let ni = 0;
					while (ni < objNames.length) {
						if (objNames[ni] == key) { found = true; break; }
						ni = ni + 1;
					}
					if (!found && engineNodeHasVirtualKey(objE, key)) found = true;
					if (!found) {
						if (d.keyLocations != null && ki < d.keyLocations.length) {
							const kl = d.keyLocations[ki];
							addErrorRange(ctx, "'" + key + "' does not exist in type '" + containerName + "'", kl.line, kl.column, kl.column + key.length);
						} else {
							addError(ctx, "'" + key + "' does not exist in type '" + containerName + "'", node.location.line, node.location.column);
						}
					}
					// Check duplicate: same key appeared earlier
					let di = 0;
					while (di < ki) {
						if (d.keys[di] == key) {
							if (d.keyLocations != null && ki < d.keyLocations.length) {
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
		if (objNames != null && !(isEngineCheckMode() && containerName == "Node")) {
			let hasDynamicKey = false;
			for (const k of d.keys) {
				if (k == "..." || k == "__computed__") hasDynamicKey = true;
			}
			if (!hasDynamicKey && d.keys.length == d.properties.length) {
				for (let oi = 0; oi < objNames.length && oi < objChildren.length; oi += 1) {
					if (objNames[oi].startsWith("__") || d.keys.includes(objNames[oi])) continue;
					const init = literalFieldInitializer(ctx, literalClassType, objNames[oi], objChildren[oi], node.location);
					if (init == null) continue;
					d.keys.push(objNames[oi]);
					d.properties.push(init);
					if (d.keyLocations != null) d.keyLocations.push(makeLoc(0, 0));
				}
			}
			if (!hasDynamicKey) {
				let mi = 0;
				while (mi < objNames.length) {
					const wantT = mi < objChildren.length ? objChildren[mi] : null as unknown as Type;
					if (wantT != null && requiresInit(wantT)) {
						const want = objNames[mi];
						let present = false;
						for (const k of d.keys) { if (k == want) { present = true; break; } }
						if (!present) {
							addError(ctx, `field '${want}' must be initialized: type '${typeDisplayName(wantT)}' has no default value — give it in the literal or an initializer in the class, or declare the field optional with '?'`, node.location.line, node.location.column);
						}
					}
					mi = mi + 1;
				}
			}
		}
		node.nodeType = node.nodeType; return;
	} else if (objExpected != null && objExpected.kind == TypeKind.Union
		&& isDiscriminatedUnion(objExpected)) {
		// Discriminated union construction validation
		// Pass original expectedType so Ref wrapper is preserved for codegen heap-alloc
		const constructed = checkDiscriminatedConstruction(ctx, node, d, objExpected, expectedType);
		node.nodeType = constructed; return;
	} else if (objExpected != null && objExpected.kind == TypeKind.Union) {
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
		if (stringDiscName != "") {
			// Look for the discriminant field in the literal
			let litDiscIdx = -1;
			for (let ki = 0; ki < d.keys.length; ki += 1) {
				if (d.keys[ki] == stringDiscName) { litDiscIdx = ki; break; }
			}
			if (litDiscIdx >= 0 && litDiscIdx < d.properties.length) {
				const discProp = d.properties[litDiscIdx];
				if (discProp.kind == NodeKind.StringLiteral) {
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
		if (varIdx < 0 && stringDiscName == "") {
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
					const probeType = probe.nodeType;
					propTypes.push(probeType!);
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
		const variant = (varIdx >= 0 && objExpected.typeChildren != null
			&& varIdx < objExpected.typeChildren.length)
			? objExpected.typeChildren[varIdx]
			: null;
		if (variant != null && variant.kind == TypeKind.Ref) {
			rearmLiteralForRecheck(node, variant);
			checkExpr(ctx, node, variant);
			return;
		}
		for (let fi = 0; fi < d.properties.length; fi += 1) {
			const key = fi < d.keys.length ? d.keys[fi] : "";
			const fieldExpected = (variant != null && key != "")
				? findFieldInVariant(variant, key)
				: null;
			checkExpr(ctx, d.properties[fi], fieldExpected);
			if (stringDiscName != "" && variant != null && key != "" && key != stringDiscName && fieldExpected == null) {
				// Resolved to a specific variant via string discriminant, but this field
				// doesn't belong to it — report.
				addError(ctx, `Field '${key}' does not exist on the ${stringDiscName}-matched variant`,
					node.location.line, node.location.column);
			}
		}
		// +1 offset so 0 means "not set" (variant 0 becomes 1).
		if (varIdx >= 0) {
			node.variantSlot = varIdx + 1;
		}
		node.nodeType = objExpected; return;
	} else {
		// No expected type — synthesize anonymous struct from literal fields
		const fieldNames: string[] = [];
		const fieldTypes: Type[] = [];
		let pi = 0;
		let spreadSeen = false;
		while (pi < d.properties.length) {
			checkExpr(ctx, d.properties[pi], null);
			const rawFt = d.properties[pi].nodeType;
			const ft = rawFt != null ? closureStorageType(rawFt) : rawFt;
			if (ft != rawFt) d.properties[pi] = fitNode(ctx, d.properties[pi], ft, rawFt);
			const spreadFields = pi < d.keys.length && d.keys[pi] == "..." && d.properties[pi].kind == NodeKind.SpreadExpr
				? spreadFieldsOf((d.properties[pi].data as SpreadExprData).spreadArg.nodeType) : null;
			if (spreadFields != null) {
				spreadSeen = true;
				for (let fi = 0; fi < spreadFields.typeNames.length; fi += 1) {
					const fname = spreadFields.typeNames[fi];
					if (fname.startsWith("__") || fi >= spreadFields.typeChildren.length) continue;
					const at = fieldNames.indexOf(fname);
					if (at >= 0) fieldTypes[at] = spreadFields.typeChildren[fi];
					else { fieldNames.push(fname); fieldTypes.push(spreadFields.typeChildren[fi]); }
				}
				pi = pi + 1;
				continue;
			}
			const at = spreadSeen && pi < d.keys.length ? fieldNames.indexOf(d.keys[pi]) : -1;
			if (at >= 0 && d.keys[pi] != "..." && d.keys[pi] != "__computed__") { fieldTypes[at] = ft!; pi = pi + 1; continue; }
			if (pi < d.keys.length) { fieldNames.push(d.keys[pi]); }
			fieldTypes.push(ft!);
			pi = pi + 1;
		}
		const anonName = anonStructName(fieldNames, fieldTypes);
		node.nodeType = createRef(createStruct(anonName, fieldNames, fieldTypes, false)); return;
	}
}

function checkTypeAssertion(ctx: CheckerContext, node: Node, expectedType: Type | null): void {
	let d = node.data as TypeAssertionData;
	// Non-null assertion `expr!` (sentinel asType "!"): strip the nullable
	// from the operand type; nullableLower rule 1c reads `.value` at codegen.
	if (d.asType == "!") {
		checkExpr(ctx, d.asExpr, null);
		const st0 = d.asExpr.nodeType;
		if (st0 != null && isMaybeType(st0) && st0.typeReturn != null) {
			node.nodeType = st0.typeReturn;
		} else if (st0 != null && st0.kind == TypeKind.Union && unwrapRefNullUnion(st0) != null) {
			node.nodeType = unwrapRefNullUnion(st0);
		} else {
			node.nodeType = st0 != null ? st0 : inferredType();
		}
		if (isReadonlyView(st0) && node.nodeType != null) node.nodeType = propagateReadonlyView(node.nodeType);
		node.flags = node.flags.incl(NodeFlag.Sem);
		return;
	}
	const asLoc = node.typeExpr != null ? node.typeExpr.location : node.location;
	const targetType = (d.asType != "") ? resolveAnnotation(d.asType, ctx, asLoc.line, asLoc.column) : inferredType();
	// TS parity: `expr as T` propagates T as contextual type to expr.
	// Critical for object literals: `{ a: 1 } as Foo` must construct a Foo
	// (not an anonymous struct that codegen then can't cast to Foo).
	// `as unknown` is a type-system escape hatch — don't use it as context.
	const asFnBody = distinctCallTarget(targetType);
	const innerExpected = (!isUnresolvedType(targetType)) ? (asFnBody != null ? asFnBody : targetType) : null;
	const operandMark = ctx.errors.length;
	const prevConversion = ctx.conversionOperand;
	ctx.conversionOperand = isNumeric(targetType) && targetType.kind != TypeKind.Char ? d.asExpr : null as unknown as Node;
	checkExpr(ctx, d.asExpr, innerExpected);
	ctx.conversionOperand = prevConversion;
	reportConstCast(ctx, d.asExpr, targetType);
	let srcType = d.asExpr.nodeType;
	const operandType = srcType;
	const operandNode = d.asExpr;
	let viaConverter = false;
	// Record type annotation position for LSP
	resolveTypeExpr(node.typeExpr, ctx);
	if (srcType != null && srcType.kind == TypeKind.Function && targetType.kind == TypeKind.Function) {
		const smuggled = smuggledIntoUnknown(srcType, targetType);
		if (smuggled != null) {
			addError(ctx, "cannot cast " + typeDisplayName(srcType) + " to " + typeDisplayName(targetType) + " — it would carry " + typeDisplayName(smuggled) + " through an unknown slot, and unknown holds objects", asLoc.line, asLoc.column);
		}
	}
	const targetHeld = targetType.kind == TypeKind.Union ? unwrapRefNullUnion(targetType) : targetType;
	if (isUnknownType(targetHeld) && srcType != null) {
		const refusal = unknownRefusal(srcType);
		if (refusal != UnknownRefusal.None) {
			const onward = expectedType != null && !isUnresolvedType(expectedType) && !isUnknownType(expectedType) ? expectedType : null;
			if (onward != null) {
				addError(ctx, "cannot reinterpret " + typeDisplayName(srcType) + " as " + typeDisplayName(onward) + " through unknown — unknown holds objects; convert with `as " + typeDisplayName(onward) + "` or build the " + typeDisplayName(onward) + " value", asLoc.line, asLoc.column);
			} else {
				addError(ctx, unknownRefusalText(srcType, refusal), asLoc.line, asLoc.column);
			}
		}
	}
	const nullableMember = targetType.kind == TypeKind.Union ? unwrapRefNullUnion(targetType) : null;
	const projectedMember = nullableMember != null ? nullableMember : targetType;
	if (srcType != null && isSlotUnion(srcType) && (targetType.kind != TypeKind.Union || isStrLitSet(targetType) || nullableMember != null)
		&& !isUnresolvedType(targetType) && (tagUnionMemberSlot(srcType, projectedMember) >= 0 || objectPathHolders(srcType, projectedMember).length > 0)) {
		const projected = checkedProjection(d.asExpr, srcType, projectedMember);
		if (projected.kind == NodeKind.TypeAssertion) {
			node.data = { asExpr: (projected.data as TypeAssertionData).asExpr, asType: d.asType };
			if (projected.flags.has(NodeFlag.ObjCheck)) node.flags = node.flags.incl(NodeFlag.ObjCheck);
		} else {
			node.data = { asExpr: projected, asType: d.asType };
		}
		node.nodeType = isReadonlyView(srcType) ? propagateReadonlyView(targetType) : targetType;
		node.flags = node.flags.incl(NodeFlag.ConvCheck);
		stampCheckedInstance(ctx, node, targetType);
		return;
	}
	if (srcType != null && !reportedErrorSince(ctx, operandMark) && convertAsBetweenUnions(ctx, node, srcType, targetType, asLoc)) return;
	if (srcType != null && !isUnresolvedType(srcType) && !isUnresolvedType(targetType)
		&& !hasGenericParams(srcType) && !hasGenericParams(targetType) && !reportedErrorSince(ctx, operandMark)) {
		const carried = assertIntoNullable(d.asExpr, srcType, targetType);
		if (carried != null as unknown as Node) {
			node.data = { asExpr: carried, asType: d.asType };
			node.nodeType = targetType;
			return;
		}
	}
	if (srcType != null && !isUnresolvedType(targetType) && !isUnknownType(targetType)
		&& !slotTakesValue(srcType, targetType)) {
		const asCall = convertsWithoutRoutine(srcType, targetType) ? null : tryApplyConverter(ctx, d.asExpr, srcType, targetType);
		if (asCall != null) {
			viaConverter = true;
			node.data = { asExpr: asCall, asType: d.asType };
			d = node.data as TypeAssertionData;
			srcType = asCall.nodeType;
		} else if (valueOfInPlace(ctx, d.asExpr, ReadNeed.Slot, targetType)) {
			srcType = d.asExpr.nodeType;
		}
	}
	if (srcType != null && srcType.kind != TypeKind.Union) {
		const projected = narrowUnionToVariant(d.asExpr, srcType);
		if (projected != null as unknown as Node) {
			node.data = { asExpr: projected, asType: d.asType };
			d = node.data as TypeAssertionData;
		}
	}
	// Nil typing: collapse `null as T` into typed NullLiteral.
	if (srcType != null && dropsReadonlyView(srcType, targetType)) reportReadonlyWrite(ctx, srcType, "cast away", asLoc.line, asLoc.column);
	if (!isUnresolvedType(targetType) && targetType.kind != TypeKind.Null
		&& d.asExpr != null && d.asExpr.kind == NodeKind.NullLiteral) {
		const throughUnknown = srcType != null && isUnknownType(srcType);
		if (!hasGenericParams(targetType) && !isAssignable(nullType(), targetType)
			&& unknownRefusal(targetType) == UnknownRefusal.Value && !(throughUnknown && isFunctionKind(targetType))) {
			const held = throughUnknown ? "unknown" : "null";
			addError(ctx, "cannot cast " + held + " to the value type " + typeDisplayName(targetType) + " — it holds no null; write `" + typeDisplayName(targetType) + " | null`", asLoc.line, asLoc.column);
			node.nodeType = targetType;
			return;
		}
		node.kind = NodeKind.NullLiteral;
		node.data = { nullPlaceholder: true };
		node.nodeType = targetType;
		node.flags = node.flags.incl(NodeFlag.Sem);
		node.nodeType = targetType; return;
	}
	// String↔CString needs runtime conversion at the FFI boundary, not erasure.
	else if (srcType != null
		&& ((targetType.kind == TypeKind.CString
				&& (srcType.kind == TypeKind.String || srcType.kind == TypeKind.StringLiteral))
			|| (targetType.kind == TypeKind.String && srcType.kind == TypeKind.CString))) {
		node.kind = NodeKind.HiddenStdConv;
		node.data = { convExpr: d.asExpr, convType: targetType };
		node.nodeType = targetType;
		node.flags = node.flags.incl(NodeFlag.Sem);
		node.nodeType = targetType; return;
	}
	// Reference parity: when narrowing a Union, resolve to the actual variant type.
	else if (srcType != null && srcType.kind == TypeKind.Union
		&& targetType.kind == TypeKind.Struct && targetType.typeNames != null) {
		const varIdx = findUnionVariant(srcType, targetType.typeNames, targetType.typeChildren);
		if (varIdx >= 0 && varIdx < srcType.typeChildren.length) {
			node.nodeType = srcType.typeChildren[varIdx];
			if (isSlotUnion(srcType)) node.data = { asExpr: projectTagUnionMember(d.asExpr, srcType, srcType.typeChildren[varIdx]), asType: d.asType };
		} else {
			node.nodeType = targetType;
		}
	} else if (srcType != null && srcType.kind == TypeKind.Union && targetType.kind == TypeKind.Ref
		&& targetType.typeReturn != null) {
		const refTarget = targetType.typeReturn;
		const refIdx = refTarget.typeNames != null ? findUnionVariant(srcType, refTarget.typeNames, refTarget.typeChildren) : -1;
		node.nodeType = refIdx >= 0 ? srcType.typeChildren[refIdx] : targetType;
		if (refIdx >= 0 && isSlotUnion(srcType)) node.data = { asExpr: projectTagUnionMember(d.asExpr, srcType, srcType.typeChildren[refIdx]), asType: d.asType };
	} else {
		node.nodeType = targetType;
	}
	if (srcType != null && (srcType.kind != TypeKind.Union || isStrLitSet(srcType)) && targetType.kind == TypeKind.Union) {
		const widened = widenVariantToUnion(d.asExpr, targetType, srcType);
		if (widened != null as unknown as Node) node.data = { asExpr: widened, asType: d.asType };
	}
	const castSrcUnknown =(srcType != null && srcType.kind == TypeKind.Union) ? unwrapRefNullUnion(srcType) : srcType;
	if (castSrcUnknown != null && isUnknownType(castSrcUnknown) && !isUnresolvedType(targetType)
		&& !reportedErrorSince(ctx, operandMark)) {
		const targetBare = skipModifier(targetType) ?? targetType;
		if (unknownRefusal(targetType) == UnknownRefusal.Value) {
			addError(ctx, "cannot cast unknown to the value type " + typeDisplayName(targetType) + " — unknown holds objects", asLoc.line, asLoc.column);
		} else if (targetBare.kind == TypeKind.CString) {
			addError(ctx, "cannot cast unknown to cstring — unknown holds objects, never a C string; keep a C string as cstring or Ptr<void>", asLoc.line, asLoc.column);
		}
	}
	if (operandType != null && !viaConverter && !reportedErrorSince(ctx, operandMark)) {
		const adopted = tryAdoptAnonStruct(ctx, operandNode, targetType, operandType);
		if (adopted != null as unknown as Node) {
			node.data = { asExpr: adopted, asType: d.asType };
			node.nodeType = targetType;
			return;
		}
		if (reportedErrorSince(ctx, operandMark)) return;
		if (refuseUnrelatedStructAs(ctx, operandNode, operandType, targetType, asLoc.line, asLoc.column)) return;
		if (refuseContainerReinterpret(ctx, operandNode, operandType, targetType, asLoc.line, asLoc.column)) return;
		const viewed = srcType != null ? objectViewOf(ctx, d.asExpr, srcType, targetType, asLoc.line, asLoc.column) : null;
		if (reportedErrorSince(ctx, operandMark)) return;
		if (viewed != null) node.nodeType = viewed;
	}
	const objConv = reportedErrorSince(ctx, operandMark) ? ObjConv.None : objectConversion(srcType, targetType);
	if (objConv == ObjConv.BadTarget) {
		addError(ctx, "cannot check a conversion from unknown to " + typeDisplayName(targetType) + " — only a class has a runtime identity; convert to a class, or keep the value in a discriminated union", asLoc.line, asLoc.column);
	} else if (objConv == ObjConv.Checked && !sameType(srcType, targetType)) {
		node.flags = node.flags.incl(NodeFlag.ObjCheck);
		stampCheckedInstance(ctx, node, targetType);
	}
	if (srcType != null && !isUnresolvedType(targetType) && !reportedErrorSince(ctx, operandMark)
		&& assertionNarrows(srcType, targetType)) {
		node.flags = node.flags.incl(NodeFlag.ConvCheck);
		stampCheckedInstance(ctx, node, targetType);
	}
	if (node.kind == NodeKind.TypeAssertion && srcType != null && srcType.kind != TypeKind.Error
		&& !isUnresolvedType(srcType) && !isUnresolvedType(targetType)
		&& targetType.kind != TypeKind.Error && !isUnknownType(targetType)
		&& !reportedErrorSince(ctx, operandMark)
		&& isPayloadCarrier(srcType) && isScalarPrimitive(targetType)
		&& !narrowsToMember(srcType, targetType)) {
		addError(ctx, "cannot convert " + typeDisplayName(srcType) + " to " + typeDisplayName(targetType)
			+ " — a struct or union payload has no conversion to a primitive; read a field (e.g. .ok, .value) instead",
			asLoc.line, asLoc.column);
	}
	if (node.kind == NodeKind.TypeAssertion && srcType != null && !viaConverter
		&& !isUnresolvedType(srcType) && !isUnresolvedType(targetType)
		&& !reportedErrorSince(ctx, operandMark)) {
		const refusal = textConversionRefusal(srcType, targetType);
		if (refusal != "") addError(ctx, refusal, asLoc.line, asLoc.column);
	}
	if (srcType != null && isReadonlyView(srcType) && node.nodeType != null) node.nodeType = propagateReadonlyView(node.nodeType);
	if (!reportedErrorSince(ctx, operandMark)) checkPointerAddress(ctx, node, d.asExpr, targetType);
	return;
}

function checkArrayLiteral(ctx: CheckerContext, node: Node, expectedType: Type | null): void {
	const d = node.data as ArrayLiteralData;
	// Reference parity: semArrayConstr does expectedType.skipTypes(abstractRange)
	// which strips Sink/Lent/Var wrappers before checking Array kind
	const arrExpectedRaw = skipModifier(expectedType);
	let arrExpected = arrExpectedRaw != null ? peelTransparentInstance(arrExpectedRaw) : null;
	// `T[] | null` (TS nullable array): the literal checks against the array
	// member and the surrounding fit wraps it — the union counterpart of the
	// Ref<Array> peel below, so it runs first and hands that peel its member.
	// Without it an empty [] keeps an inferred element type all the way into
	// the emission gate.
	if (arrExpected != null && arrExpected.kind == TypeKind.Union
			&& arrExpected.typeChildren != null && arrExpected.typeChildren.length == 2) {
		const ua = arrExpected.typeChildren[0];
		const ub = arrExpected.typeChildren[1];
		const uNonNull = (ua != null && ub != null && ub.kind == TypeKind.Null) ? ua
			: ((ua != null && ub != null && ua.kind == TypeKind.Null) ? ub : null);
		if (uNonNull != null
				&& (uNonNull.kind == TypeKind.Array || uNonNull.kind == TypeKind.SizedArray
					|| (uNonNull.kind == TypeKind.Ref && uNonNull.typeReturn != null
						&& uNonNull.typeReturn.kind == TypeKind.Array))) {
			arrExpected = uNonNull;
		}
	}
	if (arrExpected != null && isMaybeType(arrExpected) && arrExpected.typeReturn != null) {
		arrExpected = peelTransparentInstance(arrExpected.typeReturn);
	}
	if (arrExpected != null && arrExpected.kind == TypeKind.Union) {
		const soleArr = soleUnionMember(arrExpected, isArrayShaped);
		if (soleArr != null) arrExpected = soleArr;
	}
	// reference array: an expected Ref<Array<T>> checks the literal against the
	// inner value array, but tags the result Ref so nativeLower boxes it onto the heap.
	let refArrayWrap: Type | null = null;
	if (arrExpected != null && arrExpected.kind == TypeKind.Ref && arrExpected.typeReturn != null
			&& arrExpected.typeReturn.kind == TypeKind.Array) {
		refArrayWrap = arrExpected;
		arrExpected = arrExpected.typeReturn;
	}
	// Tuple context: a bracket literal in tuple position is a tuple, not an array.
	// Type each element against its positional type and tag the node Tuple — else it
	// defaults to Ref<Array> and mismatches the expected tuple (e.g. `return [a, b]`
	// for a `[T, U]` return type errors "expected Tuple, got Array"). Sibling of the
	// Array / SizedArray / Ref<Array> contextual cases below.
	if (arrExpected != null && arrExpected.kind == TypeKind.Tuple && arrExpected.typeChildren != null) {
		for (let ti = 0; ti < d.elements.length; ti += 1) {
			const te = ti < arrExpected.typeChildren.length ? arrExpected.typeChildren[ti] : null;
			checkExpr(ctx, d.elements[ti], te);
			if (te != null) d.elements[ti] = fitNode(ctx, d.elements[ti], te, d.elements[ti].nodeType);
		}
		node.nodeType = arrExpected;
		return;
	}
	const elemExpected = (arrExpected != null
		&& (arrExpected.kind == TypeKind.Array || arrExpected.kind == TypeKind.SizedArray
			|| arrExpected.kind == TypeKind.Span)
		&& arrExpected.typeReturn != null)
		? arrExpected.typeReturn
		: null;
	if (d.elements.length == 0) {
		if (arrExpected != null && (arrExpected.kind == TypeKind.SizedArray || arrExpected.kind == TypeKind.Array)) {
			node.nodeType = refArrayWrap != null ? refArrayWrap : arrExpected; return;
		} else if (elemExpected != null) {
			node.nodeType = createRef(createArray(elemExpected)); return;
		} else {
			node.nodeType = createRef(createArray(inferredType())); return;
		}
	} else {
		for (let i = 0; i < d.elements.length; i += 1) {
			checkExpr(ctx, d.elements[i], elemExpected);
			if (elemExpected != null) {
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
			if (elType != null && isAffineAwaitable(elType) && el.kind == NodeKind.Identifier) {
				const elSym = el.resolvedSym;
				if (elSym != null) {
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
		if (elemExpected == null && elemType != null && isAwaitable(elemType)) {
			const inner0 = awaitedType(elemType);
			let hasAffine = isAffineAwaitable(elemType);
			let hasPlain = isAwaitable(elemType) && !hasAffine;
			let ej = 1;
			while (ej < d.elements.length) {
				const ejType = d.elements[ej].nodeType;
				if (ejType != null && isAwaitable(ejType)) {
					if (isAffineAwaitable(ejType)) hasAffine = true;
					else hasPlain = true;
				}
				ej = ej + 1;
			}
			if (hasAffine && hasPlain && inner0 != null) {
				elemType = createPromise(inner0);
				addWarning(ctx,
					"affine Promise flags stripped in mixed array — affine tracking dropped (PARALOCK §5.4)",
					node.location.line, node.location.column);
			}
		}
		if (elemExpected == null && d.elements.length > 1
			&& !(elemType != null && isAwaitable(elemType))) {
			adoptLiteralArms(ctx, d.elements);
			const elemJoinTypes: Type[] = [];
			for (const el of d.elements) {
				const elType = literalElemType(el);
				elemJoinTypes.push(elType!);
			}
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
		if (elemExpected == null && isUnresolvedType(elemType)) {
			const spreadTypes: Type[] = [];
			for (const el of d.elements) {
				const st = literalElemType(el);
				if (st != null) spreadTypes.push(st);
			}
			const fromSpreads = joinBranchTypes(spreadTypes);
			if (!isUnresolvedType(fromSpreads)) elemType = fromSpreads;
		}
		// A spread first element carries no type of its own; under a Span or other
		// element slot every element was checked against that slot.
		if (elemExpected != null && isUnresolvedType(elemType) && !isUnresolvedType(elemExpected)) elemType = elemExpected;
		if (elemExpected == null && elemType != null && closureStorageType(elemType) != elemType) {
			const storedElem = closureStorageType(elemType);
			let si = 0;
			while (si < d.elements.length) {
				d.elements[si] = fitJoinedBranch(ctx, d.elements[si], storedElem);
				si = si + 1;
			}
			elemType = storedElem;
		}
		for (const el of d.elements) {
			if (el.kind == NodeKind.SpreadExpr) refuseSpreadElements(ctx, el, elemExpected != null ? elemExpected : elemType);
		}
		// Reference parity (semArrayConstr): error only on too-many elements.
		// Too-few is allowed at literal level; type compatibility catches mismatches.
		if (arrExpected != null && arrExpected.kind == TypeKind.SizedArray) {
			const expectedLen = arrExpected.typeValue;
			if (d.elements.length > expectedLen) {
				addError(ctx, `Fixed-size array expects at most ${expectedLen} element(s), got ${d.elements.length}`, node.location.line, node.location.column);
			}
			node.nodeType = refArrayWrap != null ? refArrayWrap : arrExpected; return;
		} else if (arrExpected != null && arrExpected.kind == TypeKind.Array && !hasGenericParams(arrExpected)) {
			node.nodeType = refArrayWrap != null ? refArrayWrap : arrExpected; return;
		} else {
			// No array context: a bare `[...]` literal is a reference array (T[] = Ref<Array>),
			// so nativeLower boxes it and it matches T[] params/returns post-flip.
			node.nodeType = refArrayWrap != null ? refArrayWrap : createRef(createArray(elemType)); return;
		}
	}
}

function checkArrayAccess(ctx: CheckerContext, node: Node, expectedType: Type | null): void {
	const d = node.data as ArrayAccessData;
	// Defensive: malformed ArrayAccess may have null d.array (e.g. macro
	// VM round-trip lost the field). Convert null deref into diagnostic.
	if (d.array == null) {
		addError(ctx, "internal: ArrayAccess with null array sub-expression", node.location.line, node.location.column);
		node.nodeType = errorType(); return;
	}
	checkInTypeSlot(ctx, d.array);
	const arrayIsFunction = isFunctionShaped(d.array.nodeType) && !valueOfInPlace(ctx, d.array);
	let arrType = d.array.nodeType;
	// The index is a READ even when the ArrayAccess is on an assignment
	// LHS (`a[i] = v`). leftPartOfAsgn suppresses flow narrowing for the
	// assignment target, but the index sub-expression must still narrow
	// (else a value-Maybe index keeps its carrier type → codegen mixes
	// struct and payload). Reset around the index check only.
	if (d.index != null) {
		const savedLpa = ctx.initTracker.leftPartOfAsgn;
		ctx.initTracker.leftPartOfAsgn = 0;
		checkExpr(ctx, d.index, null);
		ctx.initTracker.leftPartOfAsgn = savedLpa;
	}
	if (arrayIsFunction) {
		addError(ctx, "a function value cannot be indexed — call it first", node.location.line, node.location.column);
		node.nodeType = errorType(); return;
	}
	// Array sub-expr may have null nodeType when a macro expansion
	// returns an Identifier whose lookup hasn't repopulated the
	// symbol's type yet. Diagnostic instead of null deref.
	if (arrType == null) {
		addError(ctx, "internal: array type unresolved in ArrayAccess (child kind=" + d.array.kind + ")", node.location.line, node.location.column);
		node.nodeType = errorType(); return;
	}
	arrType = peelTransparentInstance(arrType);
	// Enum reverse index E[v]: TS numeric-enum reverse mapping, value → member-name string.
	// Base must be the enum TYPE symbol itself (not a value of enum type).
	if (d.array.kind == NodeKind.Identifier && d.array.resolvedSym != null
			&& d.array.resolvedSym.symbolKind == SymbolKind.Enum) {
		const revIdxType = d.index != null ? d.index.nodeType : null;
		if (revIdxType == null || !(isNumeric(revIdxType) || revIdxType.kind == TypeKind.Enum)) {
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
	if (mapObjType != null && mapObjType.kind == TypeKind.Ref && mapObjType.typeReturn != null) {
		mapObjType = mapObjType.typeReturn;
	}
	if (mapObjType != null && mapObjType.kind == TypeKind.GenericInstance
		&& isIndexableMapType(mapObjType)
		&& ctx.initTracker.leftPartOfAsgn == 0) {
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
		node.flags = node.flags.excl(NodeFlag.Sem);
		node.nodeType = null;
		node.nodeType = checkCallExpr(ctx, node, null); return;
	}
	const subscriptRecv = subscriptOperandOf(arrType);
	if (subscriptRecv != null && (declaresSubscript(ctx, arrType, "[]") || declaresSubscript(ctx, arrType, "[]="))) {
		if (ctx.initTracker.leftPartOfAsgn > 0) {
			addError(ctx, "'[]' of '" + typeDisplayName(subscriptRecv) + "' returns a value, so this subscript cannot be assigned to — only 'x[i] = v' writes, through a declared '[]='", node.location.line, node.location.column);
			node.nodeType = errorType(); return;
		}
		if (!declaresSubscript(ctx, arrType, "[]")) {
			addError(ctx, "type '" + typeDisplayName(subscriptRecv) + "' has no '[]' operator", node.location.line, node.location.column);
			node.nodeType = errorType(); return;
		}
		const sargs: Node[] = [];
		sargs.push(d.index);
		node.nodeType = rewriteAsMethodCall(ctx, node, d.array, "[]", sargs); return;
	}
	if (subscriptRecv != null && !hasGenericParams(subscriptRecv)
			&& (subscriptRecv.kind == TypeKind.Struct || subscriptRecv.kind == TypeKind.Boolean || isNumeric(subscriptRecv))) {
		addError(ctx, "type '" + typeDisplayName(subscriptRecv) + "' has no '[]' operator", node.location.line, node.location.column);
		node.nodeType = errorType(); return;
	}
	// reference array: deref Ref<Array> so element-type + nativeLower/codegen see the value array
	if (arrType.kind == TypeKind.Ref && arrType.typeReturn != null && arrType.typeReturn.kind == TypeKind.Array) {
		const drefTok = createToken(TokenKind.Ident, "", node.location.line);
		const drefNode = createNode(NodeKind.HiddenDeref, { expr: d.array }, drefTok);
		drefNode.nodeType = arrType.typeReturn;
		d.array = drefNode;
		arrType = arrType.typeReturn;
	}
	if (arrayIndexFails(arrType, d.index)) {
		const lpaAtIndex = ctx.initTracker.leftPartOfAsgn;
		ctx.initTracker.leftPartOfAsgn = 0;
		const indexRead = valueOfInPlace(ctx, d.index);
		ctx.initTracker.leftPartOfAsgn = lpaAtIndex;
		if (!indexRead || arrayIndexFails(arrType, d.index)) {
			addError(ctx, "an array index must be a number, got '" + typeDisplayName(d.index.nodeType!) + "'",
				node.location.line, node.location.column);
			node.nodeType = errorType(); return;
		}
	}
	reportConstIndexBound(ctx, arrType, d.index, node);
	const idxType = d.index.nodeType;
	// Implicit number → int64 cast for array index (C requires integer subscript)
	if (idxType != null && idxType.kind == TypeKind.Number && d.index.kind != NodeKind.BinaryExpr) {
		d.index = wrapInConv(d.index, createPrimitive(TypeKind.Int64));
	}
	const rangeIndex = d.index.kind == NodeKind.BinaryExpr
		&& ((d.index.data as BinaryExprData).operator == ".." || (d.index.data as BinaryExprData).operator == "...");
	if (arrType.kind == TypeKind.Tuple && arrType.typeChildren != null && !rangeIndex) {
		node.nodeType = tupleIndexType(ctx, arrType, d, node); return;
	}
	// Range access: arr[start..end] returns Span<elemType>
	let accessType: Type = inferredType();
	if (d.index.kind == NodeKind.BinaryExpr) {
		const bd = d.index.data as BinaryExprData;
		if (bd.operator == ".." || bd.operator == "...") {
			accessType = arrType.kind == TypeKind.String ? createReadonlyView(createSpan(charType()))
				: createSpan(getElementType(arrType));
		} else if (arrType.kind == TypeKind.String) {
			accessType = stringType();
		} else {
			accessType = getElementType(arrType);
		}
	} else if (arrType.kind == TypeKind.String) {
		accessType = stringType();
	} else {
		accessType = getElementType(arrType);
	}
	node.nodeType = accessType;
	node.nodeType = accessType; return;
}

function checkIdentifier(ctx: CheckerContext, node: Node, expectedType: Type | null): void {
	const d = node.data as IdentifierData;
	// Phase 5: `super` resolves to parent class via enclosing `this`'s
	// classType.typeExtra chain. Special-cased BEFORE lookupSymbol because
	// `super` is never a regular declared symbol.
	if (d.name == "super") {
		node.nodeType = resolveSuper(ctx, node); return;
	}
	// Enum member access is rewritten to a mangled Identifier ("E_M")
	// whose name is deliberately never bound in scope — its resolution
	// lives only on the inline resolvedSym. A re-check of injected
	// comptime/macro decls (resolvedSym preserved by cloneNodeForCheck)
	// must trust it rather than look the mangled name up and fail. A
	// normal identifier never arrives pre-tagged EnumMember.
	if (node.resolvedSym != null && node.resolvedSym.symbolKind == SymbolKind.EnumMember) {
		node.nodeType = node.resolvedSym.symbolType; return;
	}
	// bindSym: the macro pre-bound this identifier in its own module's
	// scope — the user's scope must not re-resolve (or hijack) it.
	const sym = resolveCalleeIdent(ctx, node);
	if (sym == null && ctx.jsxMacroArgDepth > 0) {
		const builtin = builtinTypeNamed(ctx, d.name);
		if (builtin != null) { node.nodeType = builtin; return; }
	}
	if (sym == null) {
			addError(ctx, `Undefined variable '${d.name}'` + callLaterDeclarationNote(d.name), node.location.line, node.location.column);
		node.nodeType = errorType(); return;
	}
	if (node.flags.has(NodeFlag.BoundSym) && isFrameValue(sym) && !isVisibleSymbol(ctx.table, sym)) {
		addError(ctx, `'${d.name}' is a local of another function: a macro placed it where that function's frame does not exist`, node.location.line, node.location.column);
		node.nodeType = errorType(); return;
	}
	// Demand-driven: ensure the symbol's signature is resolved before using its type
	ensureShaped(sym, ctx);
	node.resolvedSym = sym;
	markUsedIn(ctx, sym);
	if (sym.symbolKind == SymbolKind.Function || (sym.symbolKind == SymbolKind.Variable && sym.symbolType != null
			&& sym.symbolType.kind == TypeKind.Function && isUnresolvedType(sym.symbolType.typeReturn))) callDemandReturn(ctx, sym, node);
	if (refusesTypeAsValue(ctx, node, sym, d.name)) { node.nodeType = errorType(); return; }
	if (d.name == "this" && (sym.symbolKind == SymbolKind.Class || sym.symbolKind == SymbolKind.Actor)) node.data = { name: sym.name };
	if (sym.symbolKind == SymbolKind.Function && hasFlag(sym, SymbolFlag.CompileTime) && node != ctx.calleeExpr
			&& !isEngineCheckMode() && ctx.compileTimeBodyDepth == 0) {
		addError(ctx, `'${d.name}' is @comptime, so it runs only while compiling: call it with compile-time arguments; it has no run-time code to reference as a value`, node.location.line, node.location.column);
		node.nodeType = errorType(); return;
	}
	if (hasFlag(sym, SymbolFlag.ComptimeNodeAlias)) {
		addError(ctx, `'${d.name}' binds a compile-time JSX/Node and can only be consumed by a macro (e.g. element(${d.name})), not used as a runtime value`, node.location.line, node.location.column);
		node.nodeType = errorType(); return;
	}
	if (ctx.staticInitBoundary != null && isFrameValue(sym) && isCapturedAcross(ctx.table, d.name, sym, ctx.staticInitBoundary)) {
		const what = sym.symbolKind == SymbolKind.Parameter ? "parameter" : "enclosing local";
		addError(ctx, "a static initializer cannot read the " + what + " '" + d.name + "' — a class declared in a function body initializes its statics once, before any call runs", node.location.line, node.location.column);
		node.nodeType = errorType(); return;
	}
	if (capturesView(ctx, d.name, sym)) {
		const useAt = node.location;
		addError(ctx, viewCaptureRefusal(ctx, d.name, sym), useAt.line, useAt.column);
	}
	// PARALOCK Phase 1 R2/E3: affine-Promise bindings are single-use.
	// Reuse check is keyed by symbolConsumeKey (name + declaration site) so
	// shadowed bindings don't false-positive. First-await is OK because the
	// AwaitExpr handler marks the key AFTER its inner checkExpr returns.
	if (sym.symbolType != null && isAffineAwaitable(sym.symbolType)
		&& isConsumedName(ctx.affineTracker, symbolConsumeKey(sym))
		&& ctx.initTracker.leftPartOfAsgn <= 0) {
		addError(ctx,
			"affine Promise '" + d.name + "' has already been awaited and cannot be reused (PARALOCK R2/E3)",
			node.location.line, node.location.column);
	}
	if (isConsumedName(ctx.affineTracker, "mv:" + symbolConsumeKey(sym))) {
		if (ctx.initTracker.leftPartOfAsgn > 0) removeConsumedName(ctx.affineTracker, "mv:" + symbolConsumeKey(sym));
		else addError(ctx, "'" + d.name + "' was moved into a spawn thunk and cannot be used afterwards — spawn(fn, { move: [" + d.name + "] }) transferred it (PARALOCK E24)", node.location.line, node.location.column);
	}
	// Ref parity: useVar — only check vars declared in current scope (getDeclBlock >= 0).
	// Imports/globals never varDecl'd → naturally skipped. Matches reference's owner-based scoping.
	if (sym.symbolKind == SymbolKind.Variable && getDeclBlock(ctx.initTracker, d.name) >= 0
		&& ctx.initTracker.leftPartOfAsgn <= 0 && ctx.currentFunction != null
		&& !isInitialized(ctx.initTracker, d.name) && isLocalToFunction(ctx, d.name, sym)) {
		if (requiresInit(sym.symbolType)) {
			addError(ctx, "'" + d.name + "' may be read before it is assigned: type '" + typeDisplayName(sym.symbolType) + "' has no default value", node.location.line, node.location.column);
			markInitialized(ctx.initTracker, d.name);
		} else if (ctx.strictDefs) {
			addWarning(ctx, "variable '" + d.name + "' may be used before initialization", node.location.line, node.location.column);
			markInitialized(ctx.initTracker, d.name);
		}
	}
	sgRecordSym(ctx, node.location.line, node.location.column, node.location.column + d.name.length, sym, sym.symbolType, sym.symbolKind, d.name, "", false);
	// Assignment LHS: return the declared type, not the flow-narrowed
	// one. Inside `if (x === null) { x = {...} }` the RHS otherwise
	// gets `null` as contextualType and falls through to anon-struct
	// synthesis instead of widening to x's declared type.
	const boundary = ctx.readonlyBoundary;
	const capturedView = boundary != null && isCapturableValue(sym) && isCapturedAcross(ctx.table, d.name, sym, boundary);
	let readType = sym.symbolType;
	if (readType != null && (readType.kind == TypeKind.Var || readType.kind == TypeKind.Borrow) && readType.typeReturn != null) {
		readType = readType.typeReturn;
	}
	if (ctx.initTracker.leftPartOfAsgn > 0) {
		node.nodeType = capturedView ? propagateReadonlyView(readType) : readType; return;
	}
	const flowType = getFlowTypeOfReference(node, readType);
	node.nodeType = capturedView ? propagateReadonlyView(flowType) : flowType;
	return;
}

function checkUnaryExpr(ctx: CheckerContext, node: Node, expectedType: Type | null): void {
	const d = node.data as UnaryExprData;
	// Propagate expectedType through unary +/- for literal coercion (e.g., -128 → int8)
	const unaryExpected = (d.unaryOp == "-" || d.unaryOp == "+") ? expectedType : null;
	if (d.unaryOp == "-" && isNodeIntLit(d.operand)
		&& unaryExpected != null && isIntegerType(unaryExpected)) {
		checkNegatedIntLiteral(ctx, d.operand, unaryExpected);
		node.nodeType = unaryExpected;
		return;
	}
	if (d.unaryOp == "-" && isNodeIntLit(d.operand) && unaryExpected == null) {
		reportLiteralRange(ctx, d.operand);
		d.operand.nodeType = untypedIntegerLiteralType(ctx, d.operand, true);
		node.nodeType = d.operand.nodeType;
		return;
	}
	checkExpr(ctx, d.operand, unaryExpected);
	if (d.unaryOp == "!") {
		refuseFunctionTruthiness(ctx, d.operand);
	} else if ((d.unaryOp == "-" || d.unaryOp == "+") && unaryArithFails(ctx, d.unaryOp, d.operand.nodeType)
		&& !valueOfInPlace(ctx, d.operand)) {
		addError(ctx, "unary '" + d.unaryOp + "' needs a numeric operand, got '" + typeDisplayName(d.operand.nodeType!) + "'",
			node.location.line, node.location.column);
		node.nodeType = errorType(); return;
	} else if (d.unaryOp == "~" && d.operand.nodeType != null && d.operand.nodeType.kind != TypeKind.Number
		&& !isBitwiseAllowed(d.operand.nodeType)) {
		valueOfInPlace(ctx, d.operand);
	}
	const operandType = d.operand.nodeType;
	if (d.unaryOp == "!" && operandType != null && operandType.kind == TypeKind.Void) {
		addError(ctx, "an expression of type 'void' cannot be tested for truthiness",
			node.location.line, node.location.column);
		node.nodeType = errorType(); return;
	}
	if (d.unaryOp == "+" && operandType != null && operandType.kind == TypeKind.BigInt) {
		addError(ctx, "unary '+' is not allowed on bigint — use Number(b) to convert", node.location.line, node.location.column);
		node.nodeType = errorType(); return;
	}
	// Bitwise NOT: integer/enum = ok, number = warn, other = error
	if (d.unaryOp == "~") {
		if (operandType != null && operandType.kind == TypeKind.Set) {
			addError(ctx, "bitwise NOT '~' has no meaning on a set — use '.difference(other)' to remove members", node.location.line, node.location.column);
			node.nodeType = errorType(); return;
		}
		if (operandType != null && operandType.kind == TypeKind.Number) {
			addWarning(ctx, "bitwise NOT '~' on 'number' implicitly casts to int32; prefer explicit integer type", node.location.line, node.location.column);
			d.operand = wrapInConv(d.operand, createPrimitive(TypeKind.Int32));
		} else if (!isBitwiseAllowed(operandType)) {
			const name = operandType != null ? typeDisplayName(operandType) : "unknown";
			addError(ctx, "bitwise NOT '~' requires integer type, got '" + name + "'", node.location.line, node.location.column);
		}
	}
	if ((d.unaryOp == "-" || d.unaryOp == "+" || d.unaryOp == "!" || d.unaryOp == "~")
		&& operandType != null && !isStringLike(operandType)
		&& !(d.unaryOp == "-" && d.operand.kind == NodeKind.NumberLiteral)
		&& ctx.extensionRegistry != null) {
		const unExt = resolveOperatorCall(ctx.table, ctx.extensionRegistry, d.unaryOp, [operandType]);
		if (unExt != null) {
			const unFnType = getExtFnType(unExt);
			if (unFnType != null && unFnType.typeReturn != null) {
				node.flags = node.flags.incl(NodeFlag.UserOp);
				node.nodeType = unFnType.typeReturn; return;
			}
		}
	}
	if (d.unaryOp == "typeof" && operandType != null && operandType.kind == TypeKind.Union) {
		const stored = declaredTagUnionOf(d.operand);
		if (stored != null && stored != operandType) d.operand.nodeType = stored;
	}
	node.nodeType = inferUnaryOp(d.unaryOp, operandType!); return;
}

function checkMacroInvocation(ctx: CheckerContext, node: Node, expectedType: Type | null): void {
	// Implementation parity: pragma/macro args are type-checked
	const md = node.data as MacroInvocationData;
	// reference parity: @emit backtick interpolation (reference emit processing)
	if (md.macroName == "emit" && isDirectiveInvocation(node)) {
		processEmitInterpolation(ctx, node);
	}
	// @import args are pure syntax (not evaluated) — skip type-checking
	foldComptimeNodeAliasArgs(ctx, md.macroArgs);
	if (md.macroName != "import") { checkJsxConsumed(ctx, md.macroArgs); }
	// SERIALIZE Bug 8: deferred user macros expand eagerly when re-checked
	// with concrete types. After mono clones a generic body, replaceTypeVars
	// substitutes T→concrete in arg.nodeType. The re-check then hits this
	// MacroInvocation with concrete args and must expand — otherwise the
	// surrounding ReturnStmt/VariableDecl gets voidType, breaking the
	// declared-return-type assignability check.
	//
	// Mirrors the CallExpr eager path. Only fires for
	// names that resolve to a macro; builtin directives (emit, include, ...)
	// keep the voidType behavior. If args still contain GenericParam
	// (defer convention), return inferredType — let the next mono level
	// or post-mono expand pass handle it.
	const macroSym = invokedMacroSym(ctx, node);
	if (macroSym != null) {
		node.resolvedSym = macroSym;
		if (macroDepthExceeded(ctx, md.macroName, node)) return;
		if (anyArgIsParametric(md.macroArgs)) { node.nodeType = inferredType(); return; }
		ctx.macroExpansionDepth = ctx.macroExpansionDepth + 1;
		const expanded = callExpandMacroInvocation(node, ctx, 0);
		// When a user macro emits a sentinel error (or VM fails),
		// expandMacroInvocation returns the SAME MacroInvocation node and
		// has already called addError. Re-checking would route back into
		// this same branch and re-fire the macro, multiplying the error
		// up to the depth limit and finally emitting a misleading
		// "possible recursive macro" warning. Detect by kind preservation.
		if (expanded.kind == NodeKind.MacroInvocation) {
			ctx.macroExpansionDepth = ctx.macroExpansionDepth - 1;
			node.nodeType = errorType(); return;
		}
		const friends = expansionOf(ctx, node, macroSym.modulePath);
		const friendScope = befriend(ctx, friends);
		let expandedValue = expanded;
		const hoists = isHoistingSplice(ctx, node, expanded);
		if (hoists) {
			expandedValue = unwrapSpliceManyAtExpr(ctx, node, expanded);
			if (expandedValue == null) {
				unfriend(friendScope, friends);
				ctx.macroExpansionDepth = ctx.macroExpansionDepth - 1;
				node.nodeType = errorType(); return;
			}
		}
		node.kind = expandedValue.kind;
		node.data = expandedValue.data;
		if (expandedValue.typeArg != "") node.typeArg = expandedValue.typeArg;
		if (expandedValue.location != null) node.location = expandedValue.location;
		node.nodeType = null as unknown as Type;
		node.resolvedSym = null;
		node.flags = 0 as BitSet<NodeFlag>;
		node.variantSlot = 0;
		keepFoldedType(node, expandedValue);
		if (node.kind == NodeKind.SpliceMany) markExpansion(ctx, node, friends);
		checkExpr(ctx, node, expectedType);
		unfriend(friendScope, friends);
		if (hoists) bindRefsToHoistedPrefix(node, expanded);
		ctx.macroExpansionDepth = ctx.macroExpansionDepth - 1;
		node.nodeType = node.nodeType; return;
	}
	node.nodeType = voidType(); return;
}


// Phase 5: resolve `super` identifier to the parent class symbol.
// `super` is only valid inside an instance method (where "this" is in scope).
// Walks: this → enclosing class type → typeExtra → parent class.
function fitConditionalArms(ctx: CheckerContext, d: ConditionalExprData, expectedType: Type | null, converting: boolean): Type | null {
	if (expectedType != null && ((converting && isNumeric(d.ternaryConsequent.nodeType) && isNumeric(d.ternaryAlternate.nodeType))
		|| (branchFitsSlot(ctx, d.ternaryConsequent.nodeType, expectedType)
		&& branchFitsSlot(ctx, d.ternaryAlternate.nodeType, expectedType)))) {
		d.ternaryConsequent = fitArm(ctx, d.ternaryConsequent, expectedType, converting);
		d.ternaryAlternate = fitArm(ctx, d.ternaryAlternate, expectedType, converting);
		const fitted = d.ternaryConsequent.nodeType;
		return fitted != null && sameType(fitted, d.ternaryAlternate.nodeType) ? fitted : expectedType;
	}
	retypeEmptyArrayBranch(d.ternaryConsequent, d.ternaryAlternate.nodeType);
	retypeEmptyArrayBranch(d.ternaryAlternate, d.ternaryConsequent.nodeType);
	adoptLiteralArms(ctx, [d.ternaryConsequent, d.ternaryAlternate]);
	const branchTypes: Type[] = [];
	if (d.ternaryConsequent.nodeType != null) { branchTypes.push(d.ternaryConsequent.nodeType); }
	if (d.ternaryAlternate.nodeType != null) { branchTypes.push(d.ternaryAlternate.nodeType); }
	const joined = joinBranchTypes(branchTypes);
	if (isUnresolvedType(joined)) return d.ternaryConsequent.nodeType;
	d.ternaryConsequent = fitJoinedBranch(ctx, d.ternaryConsequent, joined);
	d.ternaryAlternate = fitJoinedBranch(ctx, d.ternaryAlternate, joined);
	return joined;
}

function fitArm(ctx: CheckerContext, arm: Node, expectedType: Type, converting: boolean): Node {
	const armType = arm.nodeType;
	if (converting && armType != null && isNumeric(armType) && numericConvRefuses(armType, expectedType)
		&& !isFittingNumericConstant(arm, expectedType)) {
		return wrapInConv(arm, expectedType);
	}
	return fitNode(ctx, arm, expectedType, armType);
}

function nullishArmExpected(expectedType: Type | null): Type | null {
	return expectedType != null && isMaybeType(expectedType) ? expectedType.typeReturn : expectedType;
}

function fitNullishArms(ctx: CheckerContext, d: BinaryExprData, leftType: Type | null, rightType: Type | null, expectedType: Type | null, converting: boolean): Type | null {
	if (rightType == null || rightType.kind == TypeKind.Null || isMaybeType(rightType) || nullishPayloadType(rightType) != null) return null;
	const payload = nullishPayloadType(leftType);
	if (payload == null) {
		// A left side already known non-null makes the right arm dead, yet it is
		// still a value of the left's type: an empty array takes that type.
		if (leftType != null) retypeEmptyArrayBranch(d.right, leftType);
		return null;
	}
	const target = nullishArmExpected(expectedType);
	if (converting && target != null && isNumeric(payload) && isNumeric(target) && numericConvRefuses(payload, target)) {
		d.right = fitJoinedBranch(ctx, d.right, payload);
		return payload;
	}
	const payloadArm = createNodeAt(NodeKind.TypeAssertion, { asExpr: d.left, asType: "!" } as TypeAssertionData, d.left.location);
	payloadArm.nodeType = payload;
	payloadArm.flags = payloadArm.flags.incl(NodeFlag.Sem);
	const arms = { ternaryCondition: d.left, ternaryConsequent: payloadArm, ternaryAlternate: d.right } as ConditionalExprData;
	const joined = fitConditionalArms(ctx, arms, nullishArmExpected(expectedType), converting);
	d.right = arms.ternaryAlternate;
	return joined;
}

// Sets node.resolvedSym to the parent class symbol so codegen can emit the
// correct `ParentClassName_new` call. Returns parent class type.
// Errors if used outside a method, in a static method, or if the enclosing
// class has no `extends` clause.
function resolveSuper(ctx: CheckerContext, node: Node): Type {
	const thisSym = lookupSymbol(ctx.table, "this");
	if (thisSym == null || thisSym.symbolType == null) {
		addError(ctx, "'super' is only valid inside an instance method or constructor", node.location.line, node.location.column);
		return errorType();
	}
	const parent = classParentOf(thisSym.symbolType);
	if (parent == null) {
		addError(ctx, "'super' requires the enclosing class to have an 'extends' clause", node.location.line, node.location.column);
		return errorType();
	}
	const parentType = parent.kind == TypeKind.Ref && parent.typeReturn != null ? parent.typeReturn : parent;
	if (parentType.kind == TypeKind.GenericInstance) {
		const instanceOf = runtimeClassSym(parentType);
		if (instanceOf != null) {
			ensureShaped(instanceOf, ctx);
			node.resolvedSym = instanceOf;
			return parent;
		}
	}
	const parentName = parentType.typeName;
	if (parentName == "") {
		addError(ctx, "'super' parent class has no resolvable name", node.location.line, node.location.column);
		return errorType();
	}
	const parentSym = parentType.sym != null && parentType.sym.symbolKind == SymbolKind.Class ? parentType.sym : lookupSymbol(ctx.table, parentName);
	if (parentSym == null) {
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
function subscriptOperandOf(receiver: Type | null): Type | null {
	const peeled = skipModifier(receiver);
	if (peeled == null) return null;
	const t = unwrapRefBase(peeled);
	if (isStringLike(t) || isIndexableMapType(t)) return null;
	if (t.kind == TypeKind.Array || t.kind == TypeKind.SizedArray || t.kind == TypeKind.Span || t.kind == TypeKind.Ptr
			|| t.kind == TypeKind.Tuple || t.kind == TypeKind.CString) return null;
	return t;
}

function declaresSubscript(ctx: CheckerContext, receiver: Type | null, op: string): boolean {
	const t = subscriptOperandOf(receiver);
	if (t == null || ctx.extensionRegistry == null) return false;
	return findExtension(ctx.extensionRegistry, typeNameOf(t), op) != null;
}

function readsOnlyNames(n: Node): boolean {
	if (n.kind == NodeKind.Identifier) return true;
	if (n.kind == NodeKind.HiddenDeref) return readsOnlyNames((n.data as HiddenDerefData).expr);
	return n.kind == NodeKind.MemberExpr && readsOnlyNames((n.data as MemberExprData).object);
}

function callSetter(ctx: CheckerContext, node: Node, d: BinaryExprData, md: MemberExprData): Type {
	if (d.operator == "=") return rewriteAsMethodCall(ctx, node, md.object, "set_" + md.property, [d.right]);
	if (!readsOnlyNames(md.object)) {
		addError(ctx, `compound assignment '${d.operator}' to accessor '${md.property}' needs a receiver that is a name or a field path: store the receiver in a local first`, node.location.line, node.location.column);
		return errorType();
	}
	const read = createNodeAt(NodeKind.MemberExpr, { object: cloneNodeForCheck(md.object), property: md.property, isOptional: false }, d.left.location);
	const combined = createNodeAt(NodeKind.BinaryExpr, { operator: d.operator.slice(0, d.operator.length - 1), left: read, right: d.right }, node.location);
	return rewriteAsMethodCall(ctx, node, md.object, "set_" + md.property, [combined]);
}

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
	node.flags = node.flags.excl(NodeFlag.Sem);
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





// ===== Generators =====

function yieldsInferred(sym: Symbol | null): boolean {
	return sym != null && isSyncGeneratorFlags(routineFlags(sym.declNode));
}

function declaredReturnOf(sym: Symbol): Type | null {
	return sym.symbolType.kind == TypeKind.Function ? sym.symbolType.typeReturn : sym.symbolType;
}

function checkYield(ctx: CheckerContext, node: Node): void {
	const d = node.data as YieldExprData;
	if (d.yieldArg == null) return;
	const fn = ctx.currentFunction;
	if (d.isDelegate || !yieldsInferred(fn)) {
		checkExpr(ctx, d.yieldArg, null);
		return;
	}
	const declared = declaredReturnOf(fn!);
	if (declared != null && !isUnresolvedType(declared)) {
		const elem = isIterator(declared) ? getIteratorYieldType(declared) : null;
		const slot = elem != null && !isUnresolvedType(elem) ? elem : null;
		checkExpr(ctx, d.yieldArg, slot);
		if (slot != null && d.yieldArg.nodeType != null) d.yieldArg = fitNode(ctx, d.yieldArg, slot, d.yieldArg.nodeType);
		return;
	}
	checkExpr(ctx, d.yieldArg, null);
	const t = d.yieldArg.nodeType;
	if (t == null || ctx.matchExprDepth > 0) return;
	if (ctx.inferredReturn.kind == TypeKind.Inferred) ctx.inferredReturn = t;
	else if (ctx.inferredReturn != t) {
		const joined = joinBranchTypes([ctx.inferredReturn, t]);
		if (!isUnresolvedType(joined)) ctx.inferredReturn = joined;
	}
	ctx.inferredReturnStmts.push(node);
}

export function refuseGeneratorReturnValue(ctx: CheckerContext, node: Node): boolean {
	const fn = ctx.currentFunction;
	if (ctx.matchExprDepth > 0 || !yieldsInferred(fn) || !isUnresolvedType(declaredReturnOf(fn!))) return false;
	const arg = (node.data as ReturnStmtData).argument;
	if (arg != null) {
		addError(ctx, "a generator's 'return' ends it and carries no value: its values are what it yields; write 'return;'", node.location.line, node.location.column);
	}
	return true;
}

// ===== Anonymous Functions =====

function producesSequence(t: Type): boolean {
	const n = t.typeName;
	return n == "Generator" || n == "AsyncGenerator" || n == "Iterator" || n == "AsyncIterator" || n == "Iterable" || n == "IterableIterator";
}

export function refuseFallingOffEnd(ctx: CheckerContext, name: string, body: Node, declared: Type | null, isAsync: boolean, isGenerator: boolean, at: SourceLocation): void {
	if (isGenerator || declared == null || body.kind != NodeKind.BlockStmt || isUnresolvedType(declared) || producesSequence(declared)) return;
	let ret: Type | null = declared;
	if (isAsync) ret = awaitedType(declared);
	if (ret == null || ret.kind == TypeKind.Void || isUnknownType(ret) || isUnresolvedType(ret)) return;
	if (ret.kind == TypeKind.Union) {
		for (const m of ret.typeChildren) {
			if (m != null && m.kind == TypeKind.Void) return;
		}
	}
	if (breaksBlock(body) == BreakState.BsNoReturn || !isEndOfBodyReachable(body)) return;
	if (ret.kind == TypeKind.Never) {
		addError(ctx, "'" + name + "' returns 'never' but can reach the end of its body", at.line, at.column);
		return;
	}
	addError(ctx, "'" + name + "' lacks an ending return statement: its return type '" + typeDisplayName(ret) + "' needs a value on every path", at.line, at.column);
}

export function checkAnonymousFunction(ctx: CheckerContext, name: string, params: string[], paramTypes: string[], body: Node, paramLocs: SourceLocation[], returnTypeAnnotation: string, expectedType: Type | null, fnFlags: string, fnNode: Node): Type {
	const isAsync = fnFlags == "async" || fnFlags == "async_generator" || (fnFlags != "" && fnFlags.indexOf("async") >= 0);
	if (params.length > 0 && params[0] == "this") {
		const thisLoc = paramLocs != null && paramLocs.length > 0 && paramLocs[0] != null ? paramLocs[0] : fnNode.location;
		addError(ctx, "a 'this' parameter is only valid as the receiver of a class method", thisLoc.line, thisLoc.column);
	}
	const savedReturn = ctx.inferredReturn;
	ctx.inferredReturn = inferredType();
	const savedReturnStmts = ctx.inferredReturnStmts;
	ctx.inferredReturnStmts = [];
	const savedReturnTries = ctx.inferredReturnTries;
	ctx.inferredReturnTries = [];
	const savedMatchDepth = ctx.matchExprDepth;
	ctx.matchExprDepth = 0;

	// Contextual param types from expectedType (e.g. callback signature at the call site).
	// Used when the user wrote untyped params: `arr.forEach(n => f(n))` — `n` typed by callee.
	// IMPORTANT: only param types are contextually inferred. Return type is still inferred
	// from body, because contextual return types may be generic (`() => T`) and would shadow
	// the concrete inference from the body that downstream passes (lambda lifting) rely on.
	let ctxParamTypes: Type[] = null as unknown as Type[];
	// A `fn | null` formal is a Maybe struct — peel it so the arrow is typed from the inner fn.
	let fnExpected = expectedType != null ? peelTransparentInstance(expectedType) : null;
	if (fnExpected != null && isMaybeType(fnExpected) && fnExpected.typeReturn != null) {
		fnExpected = peelTransparentInstance(fnExpected.typeReturn);
	}
	if (fnExpected != null && fnExpected.kind == TypeKind.Union) {
		const soleFn = soleUnionMember(fnExpected, isFunctionKind);
		if (soleFn != null) fnExpected = soleFn;
	}
	if (fnExpected != null && fnExpected.kind == TypeKind.Function && fnExpected.typeChildren != null) {
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
	if (returnTypeAnnotation != "" && returnTypeAnnotation != "void") {
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
	if (explicitReturnType == null && returnTypeAnnotation == ""
		&& fnExpected != null
		&& fnExpected.kind == TypeKind.Function
		&& fnExpected.typeReturn != null
		&& !isUnresolvedType(fnExpected.typeReturn)
		&& !hasGenericParams(fnExpected.typeReturn)) {
		explicitReturnType = fnExpected.typeReturn;
	}

	const savedFunction = ctx.currentFunction;
	// Set explicit return type on function symbol BEFORE checking body, so return
	// statements can use it as expectedType (semProcAux parity: annotation propagates)
	const fnSymType = explicitReturnType != null ? createFunction([], [], explicitReturnType) : inferredType();
	const sym = makeSymbol(name, SymbolKind.Function, fnSymType, false);
	sym.declNode = fnNode;
	if (isAsync) setFlag(sym, SymbolFlag.Async);
	ctx.currentFunction = sym;
	const savedCtorExits = ctx.ctorExits;
	ctx.ctorExits = null;
	openScope(ctx.table, ScopeKind.Function);
	const savedBoundary = ctx.readonlyBoundary;
	if (ctx.pendingSpawnThunk) {
		ctx.pendingSpawnThunk = false;
		ctx.readonlyBoundary = ctx.table.current;
	}
	const suspends = isAsync || fnFlags.indexOf("generator") >= 0;
	const paramSyms: Symbol[] = [];
	let pi = 0;
	for (const p of params) {
		let pType = inferredType();
		if (pi < paramTypes.length && paramTypes[pi] != "") {
			pType = resolveAnnotation(paramTypes[pi], ctx, 0, 0);
		} else if (ctxParamTypes != null && pi < ctxParamTypes.length && ctxParamTypes[pi] != null) {
			// Contextual fallback: untyped param inherits expected param type
			pType = ctxParamTypes[pi];
		}
		if (suspends && bodyMentionsName(body, p)) {
			const at = paramLocs != null && pi < paramLocs.length && paramLocs[pi] != null ? paramLocs[pi] : fnNode.location;
			refuseSuspendingViewParam(ctx, p, pType, at.line, at.column);
		}
		const paramSym = makeSymbol(p, SymbolKind.Parameter, pType, false);
		if (paramLocs != null && pi < paramLocs.length && paramLocs[pi] != null) {
			paramSym.location = paramLocs[pi];
		}
		paramSyms.push(paramSym);
		defineSymbol(ctx.table, paramSym);
		if (paramLocs != null && pi < paramLocs.length && paramLocs[pi] != null) {
			sgRecordSym(ctx, paramLocs[pi].line, paramLocs[pi].column,
				paramLocs[pi].column + p.length,
				paramSym, pType, SymbolKind.Parameter, p, "", true);
		}
		pi += 1;
	}
	fnNode.paramSyms = paramSyms;
	if (body.kind == NodeKind.BlockStmt) {
		callCheckStmt(ctx, body);
		if (explicitReturnType != null) {
			refuseFallingOffEnd(ctx, name, body, explicitReturnType, isAsync, fnFlags.indexOf("generator") >= 0, fnNode.location);
		}
	} else {
		let bodyExpected = explicitReturnType;
		if (isAsync && bodyExpected != null) {
			const unwrapped = awaitedType(bodyExpected);
			if (unwrapped != null) bodyExpected = unwrapped;
		}
		const hoistMark = ctx.pendingHoisted.length;
		checkExpr(ctx, body, bodyExpected);
		const exprType = body.nodeType;
		if (ctx.inferredReturn.kind == TypeKind.Inferred && exprType != null) {
			ctx.inferredReturn = exprType;
		}
		const temps = takeDefaultArgTemps(ctx, hoistMark);
		if (temps.length > 0) bodyIntoBlock(body, temps);
	}
	closeScope(ctx.table);
	ctx.readonlyBoundary = savedBoundary;
	ctx.ctorExits = savedCtorExits;
	ctx.currentFunction = savedFunction;
	ctx.matchExprDepth = savedMatchDepth;

	const inferredRet = explicitReturnType == null && returnTypeAnnotation == "" && isSyncGeneratorFlags(fnFlags)
		? settleYields(ctx, name, fnNode.location)
		: closureStorageType(ctx.inferredReturn);
	if (body.kind == NodeKind.BlockStmt && explicitReturnType == null && returnTypeAnnotation == "" && !isUnresolvedType(inferredRet)) {
		refuseFallingOffEnd(ctx, name, body, inferredRet, false, fnFlags.indexOf("generator") >= 0, fnNode.location);
	}
	for (const rs of ctx.inferredReturnStmts) {
		const rsd = rs.data as ReturnStmtData;
		if (rsd.argument != null) rsd.argument = fitJoinedBranch(ctx, rsd.argument, inferredRet);
	}
	for (const t of ctx.inferredReturnTries) checkPropagatedErrorAgainst(ctx, t, ctx.inferredReturn.kind == TypeKind.Inferred ? voidType() : inferredRet, name);
	ctx.inferredReturn = savedReturn;
	ctx.inferredReturnStmts = savedReturnStmts;
	ctx.inferredReturnTries = savedReturnTries;

	const types: Type[] = [];
	let ti = 0;
	for (const p of params) {
		let pType = inferredType();
		if (ti < paramTypes.length && paramTypes[ti] != "") {
			pType = resolveAnnotation(paramTypes[ti], ctx, 0, 0);
		} else if (ctxParamTypes != null && ti < ctxParamTypes.length && ctxParamTypes[ti] != null) {
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
	if (explicitReturnType != null) {
		if (isAsync && returnTypeAnnotation != "" && explicitReturnType.kind != TypeKind.Void
			&& !isAwaitable(explicitReturnType)) {
			const got = typeDisplayName(explicitReturnType);
			addError(ctx,
				"async " + name + " must declare return type as Promise<" + got
					+ ">, not bare '" + got + "'",
				body.location.line, body.location.column);
		}
		return createClosureType(types, params, explicitReturnType);
	}
	if (returnTypeAnnotation == "void") {
		return createClosureType(types, params, isAsync ? createPromise(voidType()) : voidType());
	}
	if (!isUnresolvedType(inferredRet)) {
		if (isAsync && fnFlags.indexOf("generator") < 0 && isAwaitable(inferredRet)) refuseReturnedPromise(ctx, name == "<arrow>" ? "an async arrow function" : "an async function expression", inferredRet, body.location);
		const retT = isAsync && !isAwaitable(inferredRet) ? createPromise(inferredRet) : inferredRet;
		return createClosureType(types, params, retT);
	}
	return createClosureType(types, params, isAsync ? createPromise(voidType()) : voidType());
}

export function refuseReturnedPromise(ctx: CheckerContext, what: string, returned: Type, at: SourceLocation): void {
	addError(ctx, `${what} returns '${typeDisplayName(returned)}' from its body, which makes a promise of a promise and is refused: write 'return await ...' so it returns the value`, at.line, at.column);
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
	if (expectedType == null) return;
	let fnExpected = peelTransparentInstance(expectedType);
	if (isMaybeType(fnExpected) && fnExpected.typeReturn != null) {
		fnExpected = peelTransparentInstance(fnExpected.typeReturn);
	}
	if (fnExpected.kind == TypeKind.Union) {
		const soleFn = soleUnionMember(fnExpected, isFunctionKind);
		if (soleFn != null) fnExpected = soleFn;
	}
	if (fnExpected.kind != TypeKind.Function || fnExpected.typeChildren == null) return;
	if (params.length >= fnExpected.typeChildren.length) return;
	let i = params.length;
	while (i < fnExpected.typeChildren.length) {
		const pt = fnExpected.typeChildren[i];
		if (pt == null || isUnresolvedType(pt) || pt.kind == TypeKind.GenericParam || hasGenericParams(pt)) return;
		i += 1;
	}
	while (paramTypes.length < params.length) {
		paramTypes.push("");
	}
	i = params.length;
	while (i < fnExpected.typeChildren.length) {
		params.push("__msPad" + String(i));
		paramTypes.push("");
		if (node.paramLocations != null) {
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
	const fnType = checkAnonymousFunction(ctx, "<arrow>", d.arrowParams, d.arrowParamTypes, d.arrowBody, node.paramLocations!, d.arrowReturnType, expectedType, d.arrowFlags, node);
	// The implicit return of an expression body is a fit position like any
	// ReturnStmt (checkReturnStmt:1229) — reseat the body through fitNode so
	// no coercion (Maybe wrap, closure wrap) is forgotten.
	if (d.arrowBody != null && d.arrowBody.kind != NodeKind.BlockStmt
		&& fnType.typeReturn != null && !isUnresolvedType(fnType.typeReturn)) {
		let returnExpected = fnType.typeReturn;
		if (d.arrowFlags == "async" || d.arrowFlags == "async_generator") {
			const unwrapped = awaitedType(returnExpected);
			if (unwrapped != null) returnExpected = unwrapped;
		}
		if (returnExpected.kind != TypeKind.Void) d.arrowBody = fitNode(ctx, d.arrowBody, returnExpected, d.arrowBody.nodeType);
	}
	return fnType;
}

function checkFuncExpr(ctx: CheckerContext, node: Node, expectedType: Type | null): Type {
	const d = node.data as FunctionExprData;
	resolveTypeExpr(node.typeExpr, ctx);
	resolveTypeExprs(node.typeExprs, ctx);
	padLiteralParams(d.funcExprParams, d.funcExprParamTypes, node, expectedType);
	return checkAnonymousFunction(ctx, "(anon)", d.funcExprParams, d.funcExprParamTypes, d.funcExprBody, node.paramLocations!, d.funcExprReturnType, expectedType, d.funcExprFlags, node);
}

// ===== @emit Backtick Interpolation (reference emit processing parity) =====
// Scans a single string arg for `identifier` patterns, splits into multiple args:
// string literals for raw text, Identifier nodes for resolved symbols.


function processEmitInterpolation(ctx: CheckerContext, node: Node): void {
	const md = node.data as MacroInvocationData;
	if (md.macroArgs.length != 1) return;
	const arg = md.macroArgs[0];

	// Template literal form: @emit(`foo ${bar} baz`) — desugared to BinaryExpr(+) chain
	if (arg.kind == NodeKind.BinaryExpr) {
		const parts = collectConcatParts(arg);
		// Filter empty string literals (from template coercion prefix "" + ...)
		const newArgs: Node[] = [];
		for (const p of parts) {
			if (p.kind == NodeKind.StringLiteral && (p.data as StringLiteralData).value == "") continue;
			newArgs.push(p);
		}
		if (newArgs.length > 0) { md.macroArgs = newArgs; }
		return;
	}

	if (arg.kind != NodeKind.StringLiteral) return;
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
		while (b < str.byteLength && str.charAt(b) != "`") {
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
		while (c < str.byteLength && str.charAt(c) != "`") {
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
			if (sym != null) {
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

import { instantiateClassConstructor, pickBodyCtx, literalFieldInitializer } from "./instantiate";
import { anyArgIsParametric, keepFoldedType, invokedMacroSym, isDirectiveInvocation, macroDeclOf, checkCallExpr, checkDiscriminatedConstruction, rearmLiteralForRecheck, checkJsxConsumed, checkMatchExpr, checkMemberExpr, checkNewExpr, checkTryExpr, engineNodeHasVirtualKey, engineNodeVirtualKeyType, foldComptimeNodeAliasArgs, macroDepthExceeded, resolveCalleeIdent, inheritContainerInfo, retypeEmptyArrayBranch, unwrapSpliceManyAtExpr, isHoistingSplice, bindRefsToHoistedPrefix, checkPropagatedErrorAgainst, markNamesUsed, takeDefaultArgTemps } from "./callResolve";

function bodyIntoBlock(body: Node, temps: Node[]): void {
	const value = createNodeAt(NodeKind.Identifier, { name: "" }, body.location);
	value.kind = body.kind;
	value.data = body.data;
	value.nodeType = body.nodeType;
	value.resolvedSym = body.resolvedSym;
	value.flags = body.flags;
	value.variantSlot = body.variantSlot;
	value.typeArg = body.typeArg;
	value.typeExpr = body.typeExpr;
	value.flowNode = body.flowNode;
	const valueless = body.nodeType == null || body.nodeType.kind == TypeKind.Void || body.nodeType.kind == TypeKind.Never;
	const last = valueless
		? createNodeAt(NodeKind.ExprStmt, { expr: value }, body.location)
		: createNodeAt(NodeKind.ReturnStmt, { argument: value }, body.location);
	const stmts: Node[] = [];
	for (const t of temps) stmts.push(t);
	stmts.push(last);
	body.kind = NodeKind.BlockStmt;
	body.data = { statements: stmts } as BlockStmtData;
	body.nodeType = null;
	body.resolvedSym = null;
	body.typeArg = "";
	body.typeExpr = null;
	body.flowNode = null;
}

function createSyntheticToken(loc: SourceLocation): Token {
	return createToken(TokenKind.Ident, "", loc.line);
}


// Register callback at module load time
registerCheckExpr((ctx: CheckerContext, node: Node, expectedType: Type | null): void => { checkExpr(ctx, node, expectedType); });


function structBehindConversion(t: Type | null): Type | null {
	let s = skipModifier(t) ?? t;
	let depth = 0;
	while (s != null && s.kind == TypeKind.Distinct && s.typeReturn != null && depth < 16) {
		s = s.typeReturn;
		depth += 1;
	}
	if (s != null && s.kind == TypeKind.GenericInstance && s.typeExtra != null && isValueStructDecl(unwrapRefBase(s.typeExtra))) return s;
	return s != null && s.kind == TypeKind.Struct ? s : null;
}

function isStructInstance(t: Type): boolean {
	return t.kind == TypeKind.GenericInstance;
}

function relatedStructInstances(source: Type, target: Type): boolean {
	if (sameType(source, target)) return true;
	if (isStructInstance(source) && isStructInstance(target)) {
		return source.typeExtra != null && target.typeExtra != null
			&& (hasGenericParams(source) || hasGenericParams(target))
			&& sameNominal(unwrapRefBase(source.typeExtra), unwrapRefBase(target.typeExtra));
	}
	const sourceBody = isStructInstance(source) ? source.typeReturn : source;
	const targetBody = isStructInstance(target) ? target.typeReturn : target;
	if (sourceBody == null || targetBody == null) return false;
	return (!isStructInstance(target) && valueStructBaseDepth(sourceBody, target) > 0)
		|| (!isStructInstance(source) && valueStructBaseDepth(targetBody, source) > 0);
}

function refuseUnrelatedStructAs(ctx: CheckerContext, operand: Node, srcType: Type, targetType: Type, line: int32, column: int32): boolean {
	if (operand.kind == NodeKind.ObjectLiteral) return false;
	const target = structBehindConversion(targetType);
	const source = structBehindConversion((srcType.kind == TypeKind.Ref || isMaybeType(srcType)) && srcType.typeReturn != null ? srcType.typeReturn : srcType);
	if (target == null || source == null) return false;
	if (isStructInstance(source) || isStructInstance(target)) {
		if (relatedStructInstances(source, target)) return false;
	} else {
		if (!isValueStructDecl(target)) return false;
		if (sameNominal(source, target) || valueStructBaseDepth(source, target) > 0 || valueStructBaseDepth(target, source) > 0) return false;
	}
	addError(ctx, "cannot convert " + typeDisplayName(srcType) + " to " + typeDisplayName(targetType) + ": a struct converts only to itself, a distinct of it, or a struct it extends"
		+ structConversionHelp(ctx, source, target), line, column);
	return true;
}

function structConversionHelp(ctx: CheckerContext, source: Type, target: Type): string {
	const decl = isStructInstance(target) && target.typeExtra != null ? unwrapRefBase(target.typeExtra) : target;
	if (decl.sym != null && hiddenPrivateField(ctx, decl.sym, decl.typeNames) != "") {
		return " — " + decl.sym.name + " has private fields, so only the module that declares it builds one";
	}
	return " — build a " + typeDisplayName(target) + " from its fields, or declare a converter from " + typeDisplayName(source) + " to " + typeDisplayName(target);
}

// The conversions above are between related objects; any other conversion of a container
// holds only between equal types up to distinct (Nim checkConvertible, compareTypes with
// dcEqIgnoreDistinct), because the container is read in place as the target.
function bareConversionType(t: Type): Type {
	let s: Type = withoutReadonlyView(skipModifier(t) ?? t);
	let depth = 0;
	while ((s.kind == TypeKind.Distinct || (s.kind == TypeKind.Ref && s.typeReturn != null && containerFamily(s.typeReturn) != 0))
		&& s.typeReturn != null && depth < 16) {
		s = withoutReadonlyView(s.typeReturn);
		depth += 1;
	}
	return s;
}

function containerFamily(t: Type): int32 {
	if (isResult(t)) return 5;
	if (nullablePayload(t) != null) return 6;
	return match (t.kind) {
		TypeKind.Array => 1,
		TypeKind.SizedArray => 2,
		TypeKind.Span => 3,
		TypeKind.Tuple => 4,
		_ => 0,
	};
}

function nullablePayload(t: Type): Type | null {
	if (isMaybeType(t)) return t.typeReturn;
	return t.kind == TypeKind.Union ? unwrapRefNullUnion(t) : null;
}

function containerParts(t: Type): Type[] {
	if (isResult(t)) return [getResultOkType(t) ?? voidType(), getResultErrType(t) ?? voidType()];
	const payload = nullablePayload(t);
	if (payload != null) return [payload];
	if (t.kind == TypeKind.Tuple) return t.typeChildren;
	return t.typeReturn != null ? [t.typeReturn] : [];
}

export function sameUpToDistinct(a: Type, b: Type): boolean {
	return firstUnequalPart(a, b).length == 0;
}

function firstUnequalPart(source: Type, target: Type): Type[] {
	const a = bareConversionType(source);
	const b = bareConversionType(target);
	const family = containerFamily(a);
	if (family == 0 || family != containerFamily(b)) return sameType(a, b) ? [] : [source, target];
	if (family == 2 && a.typeValue != b.typeValue) return [source, target];
	const left = containerParts(a);
	const right = containerParts(b);
	if (left.length != right.length) return [source, target];
	if (family == 6 && (membersWithin(left[0], right[0]) || membersWithin(right[0], left[0]))) return [];
	for (let i = 0; i < left.length; i += 1) {
		const unequal = firstUnequalPart(left[i], right[i]);
		if (unequal.length > 0) return unequal;
	}
	return [];
}

// A nullable `as` between unions whose members one holds of the other narrows or widens the
// union by member, which builds the carrier and tests membership; it reads nothing in place.
function unionMembers(t: Type): Type[] {
	return t.kind == TypeKind.Union ? t.typeChildren : [t];
}

function membersWithin(inner: Type, outer: Type): boolean {
	if (inner.kind != TypeKind.Union && outer.kind != TypeKind.Union) return false;
	const candidates = unionMembers(outer);
	for (const member of unionMembers(inner)) {
		let found = false;
		for (const candidate of candidates) {
			if (sameType(member, candidate) || sameType(literalBase(member), candidate)) { found = true; break; }
		}
		if (!found) return false;
	}
	return true;
}

function conversionAdvice(family: int32, to: string): string {
	return match (family) {
		4 => "build the other tuple from the elements, converting each",
		5 => "match on the Result and build the other one from its value or error",
		6 => "test for null and convert the value: `x == null ? null : x as " + to + "`",
		_ => "convert each element instead: `.map((e) => e as " + to + ")`",
	};
}

function refuseContainerReinterpret(ctx: CheckerContext, operand: Node, srcType: Type, targetType: Type, line: int32, column: int32): boolean {
	if (operand.kind == NodeKind.ArrayLiteral || operand.kind == NodeKind.ObjectLiteral) return false;
	if (hasGenericParams(srcType) || hasGenericParams(targetType)) return false;
	const source = bareConversionType(srcType);
	const target = bareConversionType(targetType);
	const family = containerFamily(source);
	if (family == 0 || family == 3 || family != containerFamily(target)) return false;
	if (family == 6 && (objectConversion(srcType, targetType) != ObjConv.None || objectConversion(targetType, srcType) != ObjConv.None)) return false;
	const unequal = firstUnequalPart(source, target);
	if (unequal.length == 0) return false;
	const from = typeDisplayName(unequal[0]);
	const to = typeDisplayName(unequal[1]);
	const whole = unequal[0] == source;
	addError(ctx, "cannot convert " + typeDisplayName(srcType) + " to " + typeDisplayName(targetType)
		+ (whole ? ": they differ in shape, and" : ": it holds " + from + " where " + typeDisplayName(targetType) + " holds " + to + ", and")
		+ " as reads the container in place as the other type — "
		+ conversionAdvice(family, to),
		line, column);
	return true;
}

function spreadFieldsOf(t: Type | null): Type | null {
	if (t == null) return null;
	const base = unwrapRef(t);
	const peeled = base == null ? null : peelThrough(base, PEEL_ALL);
	const body = peeled == null ? base : peeled;
	if (body == null || body.kind != TypeKind.Struct || body.typeNames == null || body.typeChildren == null) return null;
	if (body.sym != null && hasFlag(body.sym, SymbolFlag.ImportC)) return null;
	return body;
}

function viewedObject(t: Type | null): Type | null {
	const bare = skipModifier(t);
	if (bare == null || bare.kind == TypeKind.Union || isAtomicRef(bare)) return null;
	const body = bare.kind == TypeKind.Ref && bare.typeReturn != null ? bare.typeReturn : bare;
	return body.kind == TypeKind.Struct && body.typeNames != null ? body : null;
}

function objectViewOf(ctx: CheckerContext, operand: Node, srcType: Type, targetType: Type, line: int32, column: int32): Type | null {
	if (operand.kind == NodeKind.ObjectLiteral || hasGenericParams(srcType) || hasGenericParams(targetType)) return null;
	const source = viewedObject(srcType);
	const target = viewedObject(targetType);
	const targetBare = skipModifier(targetType);
	if (source == null || target == null || targetBare == null || targetBare.kind != TypeKind.Ref || runtimeClassSym(target) != null) return null;
	if (sameNominal(source, target) || isAssignable(srcType, targetType) || isAssignable(targetType, srcType)) return null;
	const field = viewFieldNotHeld(source, target);
	if (field == "") return srcType;
	const at = source.typeNames.indexOf(field);
	if (at < 0 || at >= source.typeChildren.length) return null;
	addError(ctx, "cannot convert " + typeDisplayName(srcType) + " to " + typeDisplayName(targetType) + ": its field '" + field + "' is " + typeDisplayName(source.typeChildren[at]) + ", and an object type cast reads the object's own fields", line, column);
	return null;
}

function refuseHiddenFieldInLiteral(ctx: CheckerContext, ownerSym: Symbol | null, key: string, value: Node, literal: Node, d: ObjectLiteralData, index: int32): void {
	let line = literal.location.line;
	let column = literal.location.column;
	if (d.keyLocations != null && index < d.keyLocations.length && d.keyLocations[index].line > 0) {
		line = d.keyLocations[index].line;
		column = d.keyLocations[index].column;
	}
	if (key == "...") {
		const spreadSource = value.kind == NodeKind.SpreadExpr ? (value.data as SpreadExprData).spreadArg : value;
		const srcOwner = declaringSymOf(spreadSource.nodeType);
		const src = peelToStructOrUnion(spreadSource.nodeType);
		if (src == null || src.kind != TypeKind.Struct || src.typeNames == null) return;
		const hidden = hiddenPrivateField(ctx, srcOwner, src.typeNames);
		if (hidden != "") refusePrivateField(ctx, srcOwner, hidden, value.location.line, value.location.column);
		return;
	}
	if (key == "" || key == "__computed__") return;
	refusePrivateField(ctx, ownerSym, key, line, column);
}

test "a write target crossing a graph back-edge is rejected" {
	const graphT = createRef(createStruct("Symbol", [], [], false));
	graphT.typeReturn.sym = makeSymbol("Symbol", SymbolKind.Class, null, false);
	const nodeT = createRef(createStruct("Node", [], [], false));
	nodeT.typeReturn.sym = makeSymbol("Node", SymbolKind.Class, null, false);
	assert isSharedGraphType(graphT);
	assert isNodeGraphType(nodeT);
	const tok = createToken(TokenKind.Ident, "", 1);
	const sNode = createNode(NodeKind.Identifier, { name: "s" }, tok);
	sNode.nodeType = graphT;
	const edge = createNode(NodeKind.MemberExpr, { object: sNode, property: "declNode", isOptional: false }, tok);
	edge.nodeType = nodeT;
	const through = createNode(NodeKind.MemberExpr, { object: edge, property: "nodeType", isOptional: false }, tok);
	through.nodeType = null as unknown as Type;
	assert !writeThroughGraphBackedge(edge);
	assert writeThroughGraphBackedge(through);
}

function insideGenericTemplate(ctx: CheckerContext): boolean {
	if (ctx.inGenericContext > 0) return true;
	const current = ctx.currentFunction;
	if (current == null || current.instantiatedFrom != null) return false;
	return hasGenericParams(current.symbolType) || isGenericFn(routineFlags(current.declNode));
}

// Kept out of checkExprInner: every local of that routine is paid by each nested expression's frame.
function convertAsBetweenUnions(ctx: CheckerContext, node: Node, srcType: Type, targetType: Type, asLoc: SourceLocation): boolean {
	const d = node.data as TypeAssertionData;
	const nullableTarget = isSlotUnion(srcType) && isMaybeType(targetType) && targetType.typeReturn != null ? targetType.typeReturn : null;
	const pair = nullableUnionPayloads(srcType, targetType);
	const conversionTarget = nullableTarget != null ? nullableTarget : pair != null ? pair[1] : targetType;
	const conversionSource = pair != null ? pair[0] : srcType;
	if (conversionTarget.kind == TypeKind.Union || conversionSource.kind == TypeKind.Union) {
		if (!heldInTarget(conversionSource, conversionTarget) && unionsOverlap(conversionSource, conversionTarget)) return false;
	}
	let refusalSource: Type = srcType;
	let refusalTarget: Type = targetType;
	let converted: Node | null = null;
	const scalarTarget = nullableTarget != null ? nullableTarget : targetType;
	const reachesScalar = isSlotUnion(srcType) && scalarTarget.kind != TypeKind.Union && !isMaybeType(scalarTarget)
		&& tagUnionMemberSlot(srcType, scalarTarget) < 0 && heldInTarget(srcType, scalarTarget);
	if (reachesScalar && nullableTarget == null) {
		const scalar = convertUnionToUnion(d.asExpr, srcType, targetType);
		node.kind = NodeKind.HiddenSubConv;
		node.data = scalar.data;
		node.flags = node.flags.incl(NodeFlag.Sem).incl(NodeFlag.ConvCheck);
		node.nodeType = targetType;
		return true;
	}
	if (nullableTarget != null && (convertsBetweenUnions(srcType, nullableTarget) || reachesScalar || unionConversionRefusal(srcType, nullableTarget, false) != "")) {
		refusalTarget = nullableTarget;
		if (unionConversionRefusal(srcType, nullableTarget, false) == "") converted = synthMaybeWrap(convertUnionToUnion(d.asExpr, srcType, nullableTarget), targetType, nullableTarget);
	} else {
		const storedRead = convertStoredUnionRead(d.asExpr, srcType, targetType);
		const payloads = nullableUnionPayloads(srcType, targetType);
		if (storedRead != null) {
			converted = storedRead;
		} else if (payloads != null) {
			refusalSource = payloads[0];
			refusalTarget = payloads[1];
			if (unionConversionRefusal(payloads[0], payloads[1], false) == "") converted = convertUnionToUnion(d.asExpr, srcType, targetType);
		} else if (convertsBetweenUnions(srcType, targetType)) {
			if (unionConversionRefusal(srcType, targetType, false) == "") converted = convertUnionToUnion(d.asExpr, srcType, targetType);
		} else {
			return false;
		}
	}
	if (converted == null) {
		addError(ctx, "cannot convert " + typeDisplayName(srcType) + " to " + typeDisplayName(targetType) + " — " + unionConversionRefusal(refusalSource, refusalTarget, false), asLoc.line, asLoc.column);
	} else if (converted.kind == NodeKind.HiddenSubConv) {
		node.kind = NodeKind.HiddenSubConv;
		node.data = converted.data;
		node.flags = node.flags.incl(NodeFlag.Sem);
		if (converted.flags.has(NodeFlag.ConvCheck)) node.flags = node.flags.incl(NodeFlag.ConvCheck);
	} else {
		node.data = { asExpr: converted, asType: d.asType };
	}
	node.nodeType = targetType;
	return true;
}
