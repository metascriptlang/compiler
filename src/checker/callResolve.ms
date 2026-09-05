// Call / member / new resolution, overloads and generic instantiation.
// Reaches the expression dispatcher only through the checkerCallbacks door.

import { ArrayAccessData, ArrayLiteralData, BlockStmtData, BooleanLiteralData, CallExprData, CallingConvention, FunctionDeclData, IdentifierData, MacroInvocationData, MatchCaseData, MatchExprData, MemberExprData, MethodDeclData, NewExprData, Node, NodeData, NodeFlag, NodeKind, NumberLiteralData, ObjectLiteralData, OutExprData, ReturnStmtData, SourceLocation, SpliceManyData, StringLiteralData, Symbol, SymbolKind, SymbolState, TryExprData, Type, TypeAssertionData, TypeKind, VariableDeclData, createNode, createNodeAt } from "../ast/node";
import { TokenKind, createToken } from "../lexer/token";
import { cloneNodeForCheck, monoConcreteTypeName } from "../monomorphize/clone";
import { mangleMonoName } from "../monomorphize/registry";
import { findCallTypeArg, getExplicitTypeArg, getGenericDecl } from "../parser/context";
import { findChar, splitTopLevel } from "../utils/string";
import { callCheckStmt, callExpandMacroInvocation, callInstantiateGeneric } from "./checkerCallbacks";
import { CandidateScore, cmpCandidates, emptyCandidateScore, explainStructuralPrefix, findFirstMismatch, isAssignable, isNoMatch, needsStdConv, sameType, scoreCandidatePriority, scoreCandidateWithSkip } from "./compat";
import { CheckerContext, ExportedSymInfo, ExtensionMethod, addError, addErrorRange, addWarning, extractGenericNames, filterExtsByReceiverType, filterStaticExtsByReceiverName, findAllExtensionsByName, findExportedSymbol, findFirstMatchingExt, getExtFnType, hasStaticExtForReceiver, isEngineCheckMode, isGenericFn, sgRecordSym, stripReceiverParam } from "./context";
import { fitJoinedBranch, fitNode, isIntegralNumberLiteral, isNodeIntLit, joinBranchTypes, narrowUnionToVariant, synthCStringConv, synthMaybeWrap, tryAdoptAnonStruct, trySynthesizeAsCoercion, widenMaybePayload, widenVariantToUnion } from "./fit";
import { getFlowTypeOfReference, isDefinitelyNonNullAt } from "./flow";
import { BreakState, breaksBlock, collectNewInits, mergeInitBranches, restoreInitState, saveInitState } from "./initTracker";
import { instantiateClassConstructor, lookupCtorDefaults, pickBodyCtx } from "./instantiate";
import { ensureShaped, recordGenericTypeInstantiation, resolveAnnotation } from "./resolvePass";
import { markConsumedName, symbolConsumeKey } from "./spawnAffinity";
import { isContextSensitive } from "./speculate";
import { SymbolFlag, getCtorParamTypes, hasFlag, hasOverloads, lookupSymbol, makeSymbol, makeSymbolState, markConsumed, markUsed, setFlag } from "./symbol";
import { expandTemplate, isTemplateSym } from "./template";
import { UnifyBindings, booleanType, collectStringDiscriminantValues, createArc, createArray, createEnumLiteral, createFunction, createGenericInstance, createLocked, createPrimitive, createPromise, createRef, createSpawnHandle, createTypeRef, createUnifyBindings, detectUnionDiscriminant, duFieldRequiresNarrowing, duSharedFieldOffsetDiffers, duVariantIndexOfType, errorType, findFieldInVariant, findVariantByDiscriminant, findVariantByFieldName, float64Type, getDiscriminantName, getElementType, getMinArity, getProperty, getResultOkType, getReturnType, hasGenericParams, inferredType, instantiateGeneric, instantiateGenericBody, int32Type, isAffineAwaitable, isAtomicRef, isAwaitable, isBrandDistinct, isDiscriminatedUnion, isFloatType, isIntegerType, isLockedRef, isMaybeType, isNumeric, lockedPayloadType, isPointerShapedForUnknown, isResult, isStringLike, isUnknownType, isUnresolvedType, mergeUnifyBindings, nullType, numberType, peelToStructOrUnion, setMinArity, stringType, substituteAllParams, substituteType, typeDisplayName, typeNameOf, unifyType, unionVariantHasProperty, unwrapRef, unwrapRefNullUnion, unwrapVarargs, voidType } from "./types";
import { checkActorArgSendable, checkArcPointeeSendable, checkLockedPayloadSendable, checkSpawnCaptures, hasNonisolatedField } from "./sendable";
import { callCheckExpr } from "./checkerCallbacks";

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
export function inheritContainerInfo(fieldSym: Symbol, ctx: CheckerContext, typeName: string): void {
	if (typeName === "") return;
	const cSym = resolveContainerModule(ctx, typeName);
	if (cSym !== null) {
		fieldSym.modulePath = cSym.modulePath;
		if (cSym.location !== null) fieldSym.location = cSym.location;
	}
}

// Public API: check expression, store type on node. Callers read node.nodeType.
// Returns void — reference parity (standard checker returns the node, type accessed via field).
// No Type return eliminates DRC borrowed-ref-as-fresh use-after-free.
export function retypeEmptyArrayBranch(branch: Node, otherType: Type | null): void {
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
export function unwrapSpliceManyAtExpr(ctx: CheckerContext, node: Node, expanded: Node): Node {
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
		if (n.nodeTypeAst !== null) continue;
		callCheckExpr(ctx, n, null);
	}
	ctx.jsxMacroArgDepth = ctx.jsxMacroArgDepth - 1;
}

export function foldComptimeNodeAliasArgs(ctx: CheckerContext, args: Node[]): void {
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

// True iff any arg's nodeType still carries a GenericParam — the marker
// for "this call lives inside an un-instantiated generic body". Drives
// the SERIALIZE A3 defer convention: macro invocations with parametric
// args wait for monomorphization to substitute concrete types, then
// re-check eagerly expands.
export function anyArgIsParametric(args: Node[]): boolean {
	for (const arg of args) {
		if (arg.nodeType !== null && hasGenericParams(arg.nodeType)) return true;
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

function isTypeLevelAccess(ctx: CheckerContext, obj: Node): boolean {
	const sym = obj.resolvedSym;
	if (sym === null) return false;
	if (sym.symbolKind === SymbolKind.Class
		|| sym.symbolKind === SymbolKind.Actor
		|| sym.symbolKind === SymbolKind.TypeAlias
		|| sym.symbolKind === SymbolKind.Interface
		|| sym.symbolKind === SymbolKind.Struct) return true;
	if (sym.symbolKind !== SymbolKind.Function) return false;
	if (obj.kind !== NodeKind.Identifier) return false;
	if (ctx.extensionRegistry === null) return false;
	return hasStaticExtForReceiver(ctx.extensionRegistry, sym.name);
}

function getCalleeName(callee: Node): string {
	if (callee.kind === NodeKind.Identifier) {
		return (callee.data as IdentifierData).name;
	}
	if (callee.kind === NodeKind.MemberExpr) {
		return (callee.data as MemberExprData).property;
	}
	return "<unknown>";
}

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
		callCheckExpr(defCtx, cloned, expectedType);
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

function checkNewArgs(ctx: CheckerContext, args: Node[]): void {
	for (const arg of args) { callCheckExpr(ctx, arg, null); }
}

export function checkNewExpr(ctx: CheckerContext, node: Node, expected: Type | null): Type {
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
			} else if (expected !== null && isAtomicRef(expected) && !isLockedRef(expected) && expected.typeReturn !== null) {
				pointee = expected.typeReturn;
			}
		callCheckExpr(ctx, d.newArguments[0], pointee);
		if (pointee === null) { pointee = d.newArguments[0].nodeType; }
		// SHARE pointee rule (PARALOCK Amendment I): the pointee is aliased
		// across threads, so it must be deep-immutable data.
		if (pointee !== null && pointee.kind !== TypeKind.Error) {
			checkArcPointeeSendable(ctx, pointee, d.newCallee.location.line, d.newCallee.location.column);
		}
		const arcType = createArc(pointee);
			node.nodeType = arcType;
			return arcType;
		}
		// new Locked(value): the one shared-MUTABLE cell (PARALOCK I22). One
		// allocation — atomic-rc header + inline ticket lock + typed payload —
		// so the handle is an atomic Ref like Arc and rides every mechanism Arc
		// already drives. nativeLower boxes it via msBoxLocked.
		if (id.name === "Locked" && d.newArguments.length === 1) {
			const ltCol = d.newCallee.location.column + id.name.length;
			const typeArgStr = getExplicitTypeArg(d.newCallee.location.line, ltCol);
			let payload = null as unknown as Type;
			if (typeArgStr !== "") {
				payload = resolveAnnotation(typeArgStr.trim(), ctx, d.newCallee.location.line, ltCol + 1);
			} else if (expected !== null && isLockedRef(expected)) {
				payload = lockedPayloadType(expected);
			}
			callCheckExpr(ctx, d.newArguments[0], payload);
			if (payload === null) { payload = d.newArguments[0].nodeType; }
			if (payload !== null && payload.kind !== TypeKind.Error) {
				checkLockedPayloadSendable(ctx, payload, d.newCallee.location.line, d.newCallee.location.column);
			}
			const lockedType = createLocked(payload);
			node.nodeType = lockedType;
			return lockedType;
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
	callCheckExpr(ctx, d.newCallee, null);
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
		callCheckExpr(ctx, d.newArguments[ai], argExpected);
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

export function checkTryExpr(ctx: CheckerContext, node: Node): Type | null {
	const d = node.data as TryExprData;
	const oldInTry = ctx.inTryExpr;
	ctx.inTryExpr = true;
	callCheckExpr(ctx, d.tryArg, null);
	const argType = d.tryArg.nodeType;
	ctx.inTryExpr = oldInTry;
	// tryArg.nodeType = Result<T,E> (set by checkExpr on the CallExpr)
	// resultDesugar reads tryArg.nodeType for the full Result type.
	// TryExpr itself evaluates to T (the unwrapped value).
	if (d.hasCatch) {
		callCheckExpr(ctx, d.catchVal, null);
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

let _cceCount: float64 = 0;
let _cceTime: float64 = 0;
export function checkCallExprProfile(): float64[] { return [_cceCount, _cceTime]; }
export function checkCallExpr(ctx: CheckerContext, node: Node, expectedType: Type | null): Type {
	_cceCount = _cceCount + 1;
	const _cc0 = performance.now();
	const r = checkCallExprInner(ctx, node, expectedType);
	_cceTime = _cceTime + (performance.now() - _cc0);
	return r;
}
function checkCallExprInner(ctx: CheckerContext, node: Node, expectedType: Type | null): Type {
	const d = node.data as CallExprData;
	callCheckExpr(ctx, d.callee, null);
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
			callCheckExpr(ctx, d.arguments[ai], expected);
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
			callCheckExpr(ctx, node, expectedType);
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
				// Type-level access (e.g., Buffer.method()) — only static extensions apply.
				const isStaticAccess = isTypeLevelAccess(ctx, me.object);
				let filtered = filterExtsByReceiverType(allByName, objType);
				if (filtered.length === 0 && isStaticAccess && me.object.resolvedSym !== null) {
					filtered = filterStaticExtsByReceiverName(allByName, me.object.resolvedSym.name);
				}
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
			// Non-empty array/object literal under a still-generic formal:
			// drop the expected type so the literal infers bottom-up and the
			// forward unify below can bind T (a pushed GenericParam contaminates
			// the literal's type instead). Empty literals keep it — nothing to
			// infer from, the unbound-T gate must stay loud.
			if (_isGenericCall && hasGenericParams(paramExpected)) {
				const nonEmptyArrayLit = d.arguments[ai].kind === NodeKind.ArrayLiteral
					&& (d.arguments[ai].data as ArrayLiteralData).elements.length > 0;
				const nonEmptyObjectLit = d.arguments[ai].kind === NodeKind.ObjectLiteral
					&& (d.arguments[ai].data as ObjectLiteralData).properties.length > 0;
				if (nonEmptyArrayLit || nonEmptyObjectLit) {
					paramExpected = null;
				}
			}
		}
		callCheckExpr(ctx, d.arguments[ai], paramExpected);
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
			// SEND-class (void return — no reply to park on) rejects plain refs;
			// CALL-class borrows them (sound only while awaited — see below).
			const sendClass = calleeType === null || calleeType.typeReturn === null
				|| calleeType.typeReturn.kind === TypeKind.Void;
			let borrowed = false;
			for (let pi = 0; pi < d.arguments.length; pi += 1) {
				if (checkActorArgSendable(ctx, d.arguments[pi], pi, sendClass)) borrowed = true;
			}
			if (borrowed && node === ctx.stmtPosExpr) {
				addError(ctx, "discarded actor call borrows a plain reference — the reply is what keeps it alive\nawait the call, or pass `move` / `Arc<T>` (PARALOCK I21)",
					node.location.line, node.location.column);
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
		let actorBorrowReported = false;
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
				// `A | null` meeting `A | B | null`. Same reason the wrap above
				// lives here: an argument never reaches fitNode, so the carrier
				// widening has to be applied at this site too.
				if (isMaybeType(paramType) && isMaybeType(argTypes[pi])) {
					const widenedArg = widenMaybePayload(d.arguments[pi], paramType, argTypes[pi]);
					if (widenedArg !== null as unknown as Node) {
						d.arguments[pi] = widenedArg;
						argTypes[pi] = paramType;
					}
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
						// float/number → integer: the fractional part would be cut
						// with no annotation beside the value to warn the reader —
						// the cut has to be the programmer's word (`as intN`).
						if ((argTypes[pi].kind === TypeKind.Number || isFloatType(argTypes[pi])) && isIntegerType(paramType)
							&& !isIntegralNumberLiteral(d.arguments[pi])) {
							const calleeName = getCalleeName(d.callee);
							addError(ctx, "implicit " + typeDisplayName(argTypes[pi]) + " → " + typeDisplayName(paramType)
								+ " narrowing in '" + calleeName + "' arg " + String(pi)
								+ " drops the fractional part — write an explicit 'as " + typeDisplayName(paramType) + "'",
								node.location.line, node.location.column);
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
					let lvArg = d.arguments[pi];
					if (lvArg.kind === NodeKind.OutExpr) { lvArg = (lvArg.data as OutExprData).outArg; }
					const argKind = lvArg.kind;
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
					const sendClass = calleeType === null || calleeType.typeReturn === null
						|| calleeType.typeReturn.kind === TypeKind.Void;
					const borrowed = checkActorArgSendable(ctx, d.arguments[pi], pi, sendClass);
					if (borrowed && !actorBorrowReported && node === ctx.stmtPosExpr) {
						actorBorrowReported = true;
						addError(ctx, "discarded actor call borrows a plain reference — the reply is what keeps it alive\nawait the call, or pass `move` / `Arc<T>` (PARALOCK I21)",
							node.location.line, node.location.column);
					}
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
	// Multi-arg form `f<A, B>(...)` binds generic params positionally (parity:
	// explicitGenericInstantiation → setGenericParams + matchGenericParams in
	// the reference). The single-arg path below only binds the first generic
	// param found in the return type, so route multi-arg through explicit
	// positional bindings instead — `Result.ok<int32, string>(5)` needs both.
	const argNames = splitTopLevel(explicitArg, ",");
	if (argNames.length > 1) {
		let genericNames: string[] = [];
		if (node.resolvedSym !== null) {
			genericNames = extractGenericNames(getGenericDeclFlags(node.resolvedSym.declNode));
		}
		if (genericNames.length === 0) {
			const cd = node.data as CallExprData;
			if (cd.callee !== null && cd.callee.kind === NodeKind.MemberExpr) {
				const me = cd.callee.data as MemberExprData;
				if (me.object !== null && me.object.kind === NodeKind.Identifier) {
					const classParams = getGenericDecl((me.object.data as IdentifierData).name);
					if (classParams !== "") {
						genericNames = extractGenericNames("gen:" + classParams);
					}
				}
			}
		}
		if (genericNames.length === 0) {
			return inferGenericReturn(ctx, fnType, argTypes, expectedType, node);
		}
		const eb = createUnifyBindings();
		for (let i = 0; i < argNames.length && i < genericNames.length; i += 1) {
			const argName = argNames[i].trim();
			if (argName === "") continue;
			const resolved = resolveAnnotation(argName, ctx, node.location.line, node.location.column);
			if (resolved !== null && !isUnresolvedType(resolved)) {
				eb.names.push(genericNames[i]);
				eb.types.push(resolved);
			}
		}
		if (eb.names.length === 0) {
			return inferGenericReturn(ctx, fnType, argTypes, expectedType, node);
		}
		returnType = applySubstitutions(returnType, eb);
		if (returnType.kind === TypeKind.GenericInstance && returnType.typeReturn === null) {
			const declParams = getGenericDecl(returnType.typeName);
			if (declParams !== "") {
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
function computeTypeArgCol(node: Node): int32 {
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
	// A formal that received an argument yet still carries a GenericParam after
	// binding would mono into a call with no emitted body — fail loud here, not
	// at C-compile. Return-type-only checking misses param-only T.
	if (ctx.inGenericContext === 0) {
		const chkLim = argTypes.length < fnType.typeChildren.length ? argTypes.length : fnType.typeChildren.length;
		for (let fi = 0; fi < chkLim; fi += 1) {
			const fFormal = fnType.typeChildren[fi];
			if (fFormal === null || !hasGenericParams(fFormal)) continue;
			const fSub = applySubstitutions(fFormal, argBindings);
			if (hasGenericParams(fSub)) {
				const unboundP = findFirstGenericParamName(fSub);
				const pLine = callNode !== null ? callNode.location.line : 0;
				const pCol = callNode !== null ? callNode.location.column : 0;
				addError(ctx, "cannot instantiate: '" + unboundP + "' — annotate the destination type or pass an explicit type argument", pLine, pCol);
				return errorType();
			}
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
	if (b.names.length === 0) return t;
	return substituteAllParams(t, b.names, b.types);
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
	callCheckExpr(ctx, arg, expected);
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
			callCheckExpr(ctx, args[ai], winnerType.typeChildren[ai]);
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

// Walk class inheritance chain from sourceType to targetType.
// Returns depth (1 = direct parent, 2 = grandparent), or -1 if not in chain.
function inheritanceDepth(sourceType: Type, targetType: Type, ctx: CheckerContext): int32 {
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

// Check if a type maps to a pointer in C (Ref, Ptr, Borrow — NOT Object/interface)
// Build a one-off Symbol from ExportedSymInfo for namespace member access.
// Same metadata as importSymFromRegistry, but NOT defined in any scope.
function createSymFromExport(expInfo: ExportedSymInfo, sourcePath: string): Symbol {
	const sym = makeSymbolState(expInfo.name, expInfo.kind, expInfo.symType, false, SymbolState.Shaped);
	setFlag(sym, SymbolFlag.Imported);
	sym.modulePath = expInfo.definingModule !== "" ? expInfo.definingModule : sourcePath;
	sym.disamb = expInfo.disamb;
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
			if (oi < expInfo.overloadDisambs.length) overSym.disamb = expInfo.overloadDisambs[oi];
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
	return t.kind === TypeKind.Ref || t.kind === TypeKind.Ptr || t.kind === TypeKind.Borrow || t.kind === TypeKind.Var;
}

// Validate object literal construction against a discriminated union type.
// Finds the discriminant field in the literal, resolves the variant, and validates fields.
export function checkDiscriminatedConstruction(ctx: CheckerContext, node: Node, d: ObjectLiteralData, unionType: Type | null, stampType: Type | null): Type {
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
			callCheckExpr(ctx, prop, null);
		}
		addError(ctx, "Object literal for discriminated union '" + unionType.typeName + "' missing discriminant field '" + discName + "'", node.location.line, node.location.column);
		node.nodeType = stampType !== null ? stampType : unionType;
		return node.nodeType;
	}

	// Check the discriminant expression first to get its value
	const discExpr = d.properties[discIdx];
	callCheckExpr(ctx, discExpr, unionType.typeExtra);
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
		if (pi !== discIdx) {
			callCheckExpr(ctx, d.properties[pi], null);
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

export function checkMemberExpr(ctx: CheckerContext, node: Node, expectedType: Type | null): Type {
	const d = node.data as MemberExprData;
	callCheckExpr(ctx, d.object, null);
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
	const isStaticClassAccess = isTypeLevelAccess(ctx, d.object);
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
				// The flow graph pinned the reference to ONE variant. Reading a
				// payload field of some OTHER variant through the pinned reference
				// reinterprets bytes — reject. The discriminant itself stays
				// readable: variant structs do not re-declare it (it lives in the
				// union's metadata at a fixed offset), and disc re-reads inside a
				// narrowed block were always legal.
				if (getDiscriminantName(resolvedObjType) !== d.property) {
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
				&& !duFieldRequiresNarrowing(narrowedObjType, d.property)) {
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
		if (narrowedSlot === 0 && !isUnresolvedType(propType)
				&& d.object.flowNode !== null
				&& duFieldRequiresNarrowing(resolvedObjType, d.property)) {
			if (duSharedFieldOffsetDiffers(resolvedObjType, d.property)) {
				addError(ctx, `field '${d.property}' sits at different offsets across variants of '${typeDisplayName(resolvedObjType)}' — narrow with match/if on the discriminant before accessing it`,
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
			// ONE C-level peel. Field resolution peeled everything (Var AND Ref)
			// to find the struct, but a single HiddenDeref emits `(*obj)`. The
			// object's nodeType flavor differs between read sites (checker
			// already peeled Var) and write sites (still Var) — the SYMBOL's
			// declared type is the stable anchor for Var params.
			const symT = d.object.resolvedSym !== null ? d.object.resolvedSym.symbolType : null;
			if (symT !== null && symT.kind === TypeKind.Var && symT.typeReturn !== null) {
				derefNode.nodeType = symT.typeReturn;
			} else if ((objType.kind === TypeKind.Var || objType.kind === TypeKind.Ref) && objType.typeReturn !== null) {
				derefNode.nodeType = objType.typeReturn;
			} else {
				derefNode.nodeType = resolvedObjType;
			}
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
				callCheckExpr(ctx, synthCall, null);
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

// The wire flattens SourceLocation onto the node, so these names carry no
// declaration of their own; their type is SourceLocation's, read from it here
// rather than spelled again — spelling it as `number` is what let the engine
// view disagree with the source until a narrowing rule made it fatal.
function flattenedLocationFieldType(recvType: Type, name: string): Type | null {
	if (name !== "line" && name !== "column" && name !== "endLine" && name !== "endColumn") return null;
	if (recvType.typeNames === null || recvType.typeChildren === null) return int32Type();
	let i = 0;
	while (i < recvType.typeNames.length) {
		if (recvType.typeNames[i] === "location" && i < recvType.typeChildren.length) {
			const loc = peelToStructOrUnion(recvType.typeChildren[i]);
			if (loc === null || loc.typeNames === null || loc.typeChildren === null) break;
			let j = 0;
			while (j < loc.typeNames.length) {
				if (loc.typeNames[j] === name && j < loc.typeChildren.length) {
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
	if (recvType.typeNames === null || recvType.typeChildren === null) return missing;
	let dataType: Type | null = null;
	let fi = 0;
	while (fi < recvType.typeNames.length) {
		if (recvType.typeNames[fi] === "data" && fi < recvType.typeChildren.length) {
			dataType = recvType.typeChildren[fi];
			break;
		}
		fi = fi + 1;
	}
	if (dataType === null) return missing;
	const dataUnion = peelToStructOrUnion(dataType);
	if (dataUnion === null || dataUnion.kind !== TypeKind.Union || dataUnion.typeChildren === null) return missing;
	let found: Type | null = null;
	let conflict = false;
	for (const variantRaw of dataUnion.typeChildren) {
		const variant = peelToStructOrUnion(variantRaw);
		if (variant === null || variant.typeNames === null || variant.typeChildren === null) continue;
		let vi = 0;
		while (vi < variant.typeNames.length) {
			if (variant.typeNames[vi] === name && vi < variant.typeChildren.length) {
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
	if (recvType === null || recvType.typeName !== "Node") return false;
	if (flattenedLocationFieldType(recvType, key) !== null) return true;
	// bindSym bake splices Identifier literals carrying the bound-symbol handle;
	// valueToNode consumes it — never a real Node field.
	if (key === "symHandle") return true;
	return engineNodeDataField(recvType, key).fieldType !== null;
}

function resolveEngineNodeVirtualProp(ctx: CheckerContext, recvType: Type, prop: string, node: Node): Type | null {
	if (!isEngineCheckMode()) return null;
	if (recvType.typeName !== "Node") return null;
	const locField = flattenedLocationFieldType(recvType, prop);
	if (locField !== null) return locField;
	const dataField = engineNodeDataField(recvType, prop);
	const found = dataField.fieldType;
	if (found === null) return null;
	if (dataField.ambiguous) {
		addError(ctx, `field '${prop}' has different types across Node variants — narrow with a kind check or '.data as <Kind>Data' before accessing it`, node.location.line, node.location.column);
		return inferredType();
	}
	return found;
}

export function checkMatchExpr(ctx: CheckerContext, node: Node, expectedType: Type | null): Type {
	const d = node.data as MatchExprData;
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
						callCheckExpr(ctx, p, discType);
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
				callCheckExpr(ctx, p, discType);
			}
		}
		// Phase 4: per-arm variant narrowing flows through the binder's
		// synthesizeMatchArmFlow → TrueCondition → getFlowTypeOfReference path.
		// The checker no longer needs to push/pop narrowing state here.

		// Type-check guard expression with narrowing active
		if (cd.caseGuard !== null) {
			callCheckExpr(ctx, cd.caseGuard, null);
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
						callCheckExpr(ctx, rd.argument, expectedType); bodyType = rd.argument.nodeType;
					}
				}
			}
		} else {
			callCheckExpr(ctx, cd.caseBody, expectedType); bodyType = cd.caseBody.nodeType;
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

export function checkEnumExhaustiveness(ctx: CheckerContext, enumType: Type, covered: string[], matchLine: int32, matchCol: int32, discEndCol: int32): void {
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

