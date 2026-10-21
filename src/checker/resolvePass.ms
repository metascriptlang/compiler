// Pass 2: Resolve - parse type annotations, enrich collected symbols
//
// The parser currently stores type annotations as strings (TypeAnnotation nodes)
// and skips them in most places. Function params are string[] (names only).
// This pass enriches the symbol table by:
//   A. Parsing type annotation strings into Type objects
//   B. Building proper Function/Object types for collected declarations

import { firstPrivateField } from "./visibility";
import { Node, NodeKind, NodeFlag, createNodeAt, makeLoc, ProgramData, FunctionDeclData, InterfaceDeclData, ExportDeclData, ClassDeclData, ActorDeclData, MethodDeclData, PropertyDeclData, ConstructorDeclData, TypeAliasDeclData, VariableDeclData, DecoratedDeclData, ExternDeclData, MacroDeclData, IdentifierData, MemberExprData, TypeGenericData, TypeArrayData, TypeUnionData, TypeIntersectionData, TypeFunctionData, TypeObjectData, ObjectLiteralData, TypeAssertionData, DeclKind, Type, TypeKind, TypeFlag, Symbol, SymbolKind, SymbolState, NumberLiteralData, StringLiteralData, BooleanLiteralData, BigIntLiteralData, noFieldDecorators, SourceLocation, CallingConvention, BinaryExprData, UnaryExprData } from "../ast/node";
import { peelToStructOrUnion, skipModifier, unwrapRefNullUnion, isUnknownType, isOrdinalEnum, hasGenericParams, UnifyBindings, symGenericParams, builtinGenericParams, declGenericParams, genericParamNamesOf, genericParamsOf, substituteParams, createUnifyBindings, inferredType, errorType, noneType, isUnresolvedType, createReadonlyView, getSysType, numberType, stringType, booleanType, voidType, nullType, neverType, charType, cstringType, createPrimitive, createStringLiteral, createBooleanLiteral, createEnumLiteral, createArray, createFunction, createClosureType, createStruct, createResult, createPromise, createIterator, createUnion, createGenericParam, createDistinct, createGenericInstance, instantiateGenericBody, isResult, getResultOkType, getResultErrType, createSizedArray, createSpan, createBorrow, createPtr, createCursor, createRef, createArc, createLocked, createVar, createSink, setMinArity, assignType, isStructType, isNumeric, unwrapRef, propagateToOwner, propagateGenericParam, createConditionalType, setInferParams, evaluateConditionalType, typeDisplayName, emptyType, createTuple, findSharedBooleanDiscriminant, findSharedEnumDiscriminant, enumDiscriminantTypeOf, collectEnumDiscriminantValues, unknownType, createBrandDistinct, nonPrimitiveType, createBitSet, nullableUnionOf, isNullableShape, withoutReadonlyView, isReadonlyView, isMaybeType, isAwaitable, awaitedType, isSysType, createUnionInOrder, nestedViewType, ownedAlternativeOf, findViewType, createOutVar, keyOfType, indexedAccessOf, createKeyOfType, isKeyConstraint, functionSlotOf, getProperty, isPrimitiveKind, isStringLike, unifyType, numberLiteralTypeOf, markDuVariant, bindParam, declaredTypeParams, substituteBound, markDistributive, createIndexedAccessType, createMappedType, evaluateMappedType, mappedRefusal, MappedModifier, mappedIsGeneric, mappedIndexKey, mappedValueAt, peelTransparentInstance } from "./types";
import { ScopeKind, lookupSymbol, defineSymbol, makeSymbol, openScope, closeScope, hasFlag, isTypeSymbol, SymbolFlag, setFlag, parentClassSymOf } from "./symbol";
import { refuseAliasCycle } from "./aliasCycle";
import { markUsedIn, noteImported, findExportedSymbol, CheckerContext, reportDuplicateConverter, getExtReceiverType, extractGenericNames, addError, addWarning, sgRecordSym, extractGenericParamDecls, getStaticExtTypeName, getExtReceiverText, isLifecycleHookName, declaresLifecycleHook, createContext, findDeclaredExt, findAllExtensionsByName, getExtFnType, stripReceiverParam, stampItem } from "./context";
import { checkFieldDecoratorNames } from "./decoratorHelpers";
import { getIdentId } from "./idents";
import { proxyAtExtern } from "./proxy";
import { findChar, splitTopLevel, parseIntStr, bareAfterDelim, optionalizeTypeString } from "../utils/string";
import { findCallTypeArg, createState, isAtEnd } from "../parser/context";
import { getDeclName, staticExtSymOf, fillClass, fillActor, markDeclMethodsExported } from "./collectPass";
import { isAssignable as isAssignableCheck, isValueStructDecl, sameType } from "./compat";
import { mintCtorRoutine, ctorRoutineOf, ctorFormalTypes } from "./ctorRoutine";
import { monoTypeKey } from "../monomorphize/registry";
import { constantLiteralOf } from "./constFold";
import { lex } from "../lexer/lexer";
import { parseExpressionFromState } from "../parser/expressions/core";

function anyHasGenericParams(types: Type[]): boolean {
	for (const t of types) {
		if (hasGenericParams(t)) return true;
	}
	return false;
}

interface ForwardNullable {
	target: Type;
	members: Type[];
}

interface ForwardOwner {
	owner: Type;
	member: Type;
}

const _forwardNullables: ForwardNullable[] = [];
const _forwardOwners: ForwardOwner[] = [];

function declaresType(t: Type | null, sym: Symbol): boolean {
	let peeled = t;
	while (peeled != null && peeled.kind == TypeKind.Alias) peeled = peeled.typeReturn;
	return peeled != null && peeled.sym == sym;
}

function isUnresolvedAlias(t: Type | null): boolean {
	if (t == null || t.kind != TypeKind.Inferred || t.sym == null) return false;
	return t.sym.symbolKind == SymbolKind.TypeAlias;
}

function isForwardAlias(t: Type | null): boolean {
	if (!isUnresolvedAlias(t) || t == null || t.sym == null) return false;
	return t.sym.state == SymbolState.Shaping;
}

function isDeferredNullable(t: Type): boolean {
	for (const entry of _forwardNullables) {
		if (entry.target == t) return true;
	}
	return false;
}

function deferNullableUnion(members: Type[]): Type {
	const target = createUnion(members);
	_forwardNullables.push({ target: target, members: members });
	return target;
}

function recordForwardFields(owner: Type, fieldTypes: Type[]): void {
	for (const t of fieldTypes) {
		if (isForwardAlias(t) || isDeferredNullable(t)) _forwardOwners.push({ owner: owner, member: t });
	}
}

function settleForwardTypes(): void {
	let i = 0;
	while (i < _forwardNullables.length) {
		const entry = _forwardNullables[i];
		let waiting = false;
		let failed = false;
		for (const m of entry.members) {
			if (isForwardAlias(m)) waiting = true;
			else if (isUnresolvedAlias(m)) failed = true;
		}
		if (waiting) {
			i = i + 1;
			continue;
		}
		if (!failed) assignType(entry.target, nullableUnionOf(entry.members));
		_forwardNullables.splice(i, 1);
	}
	let j = 0;
	while (j < _forwardOwners.length) {
		const entry = _forwardOwners[j];
		if (isForwardAlias(entry.member) || isDeferredNullable(entry.member)) {
			j = j + 1;
			continue;
		}
		propagateToOwner(entry.owner, entry.member);
		_forwardOwners.splice(j, 1);
	}
}

// stripRestParamPrefix — in-place strip of the legacy "..." prefix from the
// last entry of an AST param-name array. Mirrors what createFunction does for
// Function.typeNames so downstream consumers (codegen, scope binding, LSP) see
// clean names. Returns true if the function has a rest param, so callers can
// adjust minArity in one branch.
function stripRestParamPrefix(params: string[]): boolean {
	const last = params.length - 1;
	if (last < 0) return false;
	if (params[last].length > 3 && params[last].slice(0, 3) == "...") {
		params[last] = params[last].slice(3, params[last].length);
		return true;
	}
	return false;
}

// A function carries its out/ref parameters as positions in fnFlags; a method or constructor the parser
// leaves them on the name ("out:x"). Lifting the prefix into the same flags lets one wrap serve both,
// and lets a generic class's instantiated method find them.
function liftParamModifiers(params: string[], flags: string): string {
	let outAt = "";
	let refAt = "";
	let sinkAt = "";
	for (let i = 0; i < params.length; i += 1) {
		if (params[i].length > 4 && params[i].slice(0, 4) == "out:") {
			params[i] = params[i].slice(4, params[i].length);
			outAt = outAt == "" ? `${i}` : `${outAt},${i}`;
		} else if (params[i].length > 4 && params[i].slice(0, 4) == "ref:") {
			params[i] = params[i].slice(4, params[i].length);
			refAt = refAt == "" ? `${i}` : `${refAt},${i}`;
		} else if (params[i].length > 5 && params[i].slice(0, 5) == "sink:") {
			params[i] = params[i].slice(5, params[i].length);
			sinkAt = sinkAt == "" ? `${i}` : `${sinkAt},${i}`;
		}
	}
	if (outAt != "") flags = flags == "" ? `out:${outAt}` : `${flags}|out:${outAt}`;
	if (refAt != "") flags = flags == "" ? `ref:${refAt}` : `${flags}|ref:${refAt}`;
	if (sinkAt != "") flags = flags == "" ? `sink:${sinkAt}` : `${flags}|sink:${sinkAt}`;
	return flags;
}

function refuseActorParamModes(ctx: CheckerContext, actorName: string, md: MethodDeclData, at: Node): void {
	for (const p of md.methodParams) {
		const mode = p.startsWith("out:") ? "out" : p.startsWith("ref:") ? "ref" : p.startsWith("sink:") ? "sink" : "";
		if (mode == "") continue;
		const name = p.slice(mode.length + 1, p.length);
		const why = mode == "sink"
			? "an actor message already transfers ownership of its arguments"
			: "the call returns before the actor runs, so it cannot write the caller's variable";
		addError(ctx, `actor method '${actorName}.${md.methodName}' cannot take ${mode} parameter '${name}': ${why}; drop '${mode}'`, at.location.line, at.location.column);
	}
	liftParamModifiers(md.methodParams, "");
}

function wrapModifierTypes(flags: string, paramTypes: Type[]): void {
	if (flags == "" || (flags.indexOf("out:") < 0 && flags.indexOf("ref:") < 0 && flags.indexOf("sink:") < 0)) return;
	for (const fp of splitTopLevel(flags, "|")) {
		const trimFp = fp.trim();
		const prefixLen = trimFp.slice(0, 5) == "sink:" ? 5 : 4;
		const prefix = trimFp.slice(0, prefixLen);
		if (trimFp.length > prefixLen && (prefix == "out:" || prefix == "ref:" || prefix == "sink:")) {
			for (const ip of splitTopLevel(trimFp.slice(prefixLen, trimFp.length), ",")) {
				const idx = parseIntStr(ip.trim());
				if (idx >= 0 && idx < paramTypes.length) {
					paramTypes[idx] = prefix == "out:" ? createOutVar(paramTypes[idx]) : prefix == "ref:" ? createVar(paramTypes[idx]) : createSink(paramTypes[idx]);
				}
			}
		}
	}
}

// ===== A. Resolve Annotation Strings =====

function bracketDepthStep(text: string, i: int32): int32 {
	const c = text.charAt(i);
	if (c == "(" || c == "[" || c == "{" || c == "<") return 1;
	const arrowTail = c == ">" && i > 0 && text.charAt(i - 1) == "=";
	if (c == ")" || c == "]" || c == "}" || (c == ">" && !arrowTail)) return -1;
	return 0;
}

function tupleElementText(element: string): { text: string, optional: boolean } {
	const e = element.trim();
	const colon = findChar(e, ":");
	if (colon > 0) {
		let label = e.slice(0, colon).trim();
		const optional = label.endsWith("?");
		if (optional) label = label.slice(0, label.length - 1).trim();
		if (isLabelText(label)) return { text: e.slice(colon + 1, e.length).trim(), optional };
	}
	if (e.endsWith("?")) return { text: e.slice(0, e.length - 1).trim(), optional: true };
	return { text: e, optional: false };
}

function isLabelText(s: string): boolean {
	if (s == "") return false;
	for (let i = 0; i < s.length; i += 1) {
		const c = s.charAt(i);
		const letter = (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c == "_" || c == "$";
		if (!letter && !(i > 0 && c >= "0" && c <= "9")) return false;
	}
	return true;
}

// Tier 3: find a keyword string at top level (not inside brackets/parens/braces/angles).
function findTopLevelKeyword(text: string, keyword: string): int32 {
	let depth = 0;
	for (let i = 0; i <= text.length - keyword.length; i += 1) {
		depth += bracketDepthStep(text, i);
		if (depth == 0 && text.slice(i, i + keyword.length) == keyword) return i;
	}
	return -1;
}

function findTrueBranchEnd(textAfterQuestion: string): int32 {
	let depth = 0;
	let nestedConditionals = 0;
	for (let i = 0; i < textAfterQuestion.length; i += 1) {
		depth += bracketDepthStep(textAfterQuestion, i);
		if (depth != 0) continue;
		if (textAfterQuestion.slice(i, i + 9) == " extends ") nestedConditionals += 1;
		if (textAfterQuestion.charAt(i) == ":") {
			if (nestedConditionals == 0) return i;
			nestedConditionals -= 1;
		}
	}
	return -1;
}

// Parse function type string to resolved Function type
function resolveFunctionType(text: string, ctx: CheckerContext, line: int32, col: int32): Type {
	let depth = 0;
	let closeIdx = -1;
	for (let i = 0; i < text.length; i += 1) {
		const c = text.charAt(i);
		if (c == "(") depth += 1;
		if (c == ")") {
			depth -= 1;
			if (depth == 0) { closeIdx = i; break; }
		}
	}
	if (closeIdx < 0) return inferredType();

	const paramsStr = text.slice(1, closeIdx).trim();
	const afterParen = text.slice(closeIdx + 1, text.length).trim();
	if (afterParen.length < 2) return inferredType();
	if (afterParen.charAt(0) != "=" || afterParen.charAt(1) != ">") return inferredType();
	const retStr = afterParen.slice(2, afterParen.length).trim();

	const returnType = (retStr != "") ? resolveReturnAnnotation(retStr, ctx, line, col) : voidType();

	// Standard reference parity: procedure type literals default to closure calling convention
	if (paramsStr == "") return createClosureType([], [], returnType);

	const paramParts = splitTopLevel(paramsStr, ",");
	const paramTypes: Type[] = [];
	const paramNames: string[] = [];
	let requiredCount = paramParts.length;
	for (let pi = 0; pi < paramParts.length; pi += 1) {
		const part = paramParts[pi];
		const colonIdx = findChar(part, ":");
		if (colonIdx > 0) {
			let name = part.slice(0, colonIdx).trim();
			let typeText = part.slice(colonIdx + 1, part.length).trim();
			const isSink = name.startsWith("sink ");
			if (isSink) name = name.slice(5, name.length).trim();
			if (name.endsWith("?")) {
				name = name.slice(0, name.length - 1).trim();
				typeText = optionalizeTypeString(typeText);
				if (pi < requiredCount) requiredCount = pi;
			}
			paramNames.push(name);
			const annotated = resolveAnnotation(typeText, ctx, line, col);
			paramTypes.push(isSink ? createSink(annotated) : annotated);
		} else {
			paramNames.push("");
			paramTypes.push(resolveAnnotation(part, ctx, line, col));
		}
	}
	const fnType = createClosureType(paramTypes, paramNames, returnType);
	if (requiredCount < paramParts.length) setMinArity(fnType, requiredCount);
	return fnType;
}

// Unwrap a Type to its underlying Struct (handles Ref<Struct> + GenericInstance).
// Returns the original Type if no struct found at any unwrap level.
// Used by field-merging paths (interface/struct extends, type alias intersection).
function unwrapToStruct(t: Type): Type {
	let s = t;
	if (s.kind == TypeKind.Ref && s.typeReturn != null) s = s.typeReturn;
	if (s.kind == TypeKind.GenericInstance && s.typeReturn != null) {
		s = s.typeReturn;
		if (s.kind == TypeKind.Ref && s.typeReturn != null) s = s.typeReturn;
	}
	return s;
}

function isLiteralTypeKind(k: TypeKind): boolean {
	return k == TypeKind.StringLiteral || k == TypeKind.BooleanLiteral || k == TypeKind.EnumLiteral;
}

// TS branded primitive: one primitive base + object operand(s) whose fields are
// ALL literal-typed. Identity = sorted brand field/value pairs, NOT the alias
// name — tsc parity: two aliases with the same brand literal are one type.
function tryBrandIntersection(operandTypes: Type[]): Type | null {
	let base: Type | null = null;
	const pairs: string[] = [];
	for (const op of operandTypes) {
		const s = unwrapToStruct(op);
		if (s.kind == TypeKind.Struct) {
			if (s.typeNames == null || s.typeNames.length == 0) return null;
			for (let fi = 0; fi < s.typeNames.length; fi += 1) {
				const ft = s.typeChildren[fi];
				if (ft == null || !isLiteralTypeKind(ft.kind)) return null;
				pairs.push(s.typeNames[fi] + ":" + typeDisplayName(ft));
			}
		} else {
			if (base != null) return null;
			if (!(isNumeric(s) || s.kind == TypeKind.String || s.kind == TypeKind.Boolean || s.kind == TypeKind.Char)) return null;
			base = op;
		}
	}
	if (base == null || pairs.length == 0) return null;
	for (let i = 1; i < pairs.length; i += 1) {
		const p = pairs[i];
		let j = i - 1;
		while (j >= 0 && pairs[j] > p) { pairs[j + 1] = pairs[j]; j = j - 1; }
		pairs[j + 1] = p;
	}
	let brandKey = "";
	for (const pr of pairs) {
		brandKey = brandKey.length == 0 ? pr : brandKey + "&" + pr;
	}
	return createBrandDistinct(brandKey, base);
}

// Append fields from a struct-like operand into the accumulator arrays.
// Collision policy: error on duplicate name (Nim-style). Operand label flows
// into error message so user sees which parent / intersection operand introduced
// the colliding field.
function appendStructFields(operandStruct: Type, operandLabel: string, accumNames: string[], accumTypes: Type[], ctx: CheckerContext, line: int32, col: int32, accumOptional: string[] = []): void {
	if (operandStruct.typeNames == null || operandStruct.typeChildren == null) return;
	if (operandStruct.optionalFields != null) {
		for (const name of operandStruct.optionalFields) accumOptional.push(name);
	}
	for (let pi = 0; pi < operandStruct.typeNames.length; pi += 1) {
		const fname = operandStruct.typeNames[pi];
		let collided = false;
		for (const existingName of accumNames) {
			if (existingName == fname) {
				addError(ctx, "field '" + fname + "' from '" + operandLabel + "' collides with previously merged field", line, col);
				collided = true;
				break;
			}
		}
		if (!collided && pi < operandStruct.typeChildren.length) {
			accumNames.push(fname);
			accumTypes.push(operandStruct.typeChildren[pi]);
		}
	}
}

// `infer X` vars from a conditional's extends clause, in scope only while its
// true/false branches resolve. A branch's bare `X` resolves against this stack to
// a GenericParam (substituted by evaluateConditionalType) instead of erroring.
let inferScope: Type[] = [];
let inferDeclared: Type[] | null = null;

function inferScopeFind(name: string): Type | null {
	for (let i = inferScope.length - 1; i >= 0; i -= 1) { if (inferScope[i].typeName == name) return inferScope[i]; }
	return null;
}

function declareInfer(ctx: CheckerContext, name: string): Type {
	const declared = inferDeclared;
	if (declared == null) return createGenericParam(name);
	for (const gp of declared) { if (gp.typeName == name) return gp; }
	const gp = createGenericParam(name);
	typeParamSym(ctx, gp);
	declared.push(gp);
	return gp;
}

// One annotation reaches resolveAnnotation once per checker pass, and the
// passes report DIFFERENT columns for it (declaration start vs the annotation
// itself), so the key has to be the line, not the position.
function warnOncePerLine(ctx: CheckerContext, msg: string, line: int32, col: int32): void {
	for (const e of ctx.errors) {
		if (e.line == line && e.message == msg) return;
	}
	addWarning(ctx, msg, line, col);
}

export function resolveReturnAnnotation(text: string, ctx: CheckerContext, line: int32, col: int32): Type {
	const t = resolveAnnotation(text, ctx, line, col);
	if (t.kind == TypeKind.Span) {
		const elem = t.typeReturn != null ? typeDisplayName(t.typeReturn) : "T";
		addError(ctx, "cannot return Span<" + elem + ">: a Span borrows memory owned by its source; return the owning container (Vec<" + elem + "> or " + elem + "[]) instead", line, col);
	} else {
		refuseNestedView(ctx, "a return value", t, line, col);
	}
	return t;
}

export function refuseNestedView(ctx: CheckerContext, what: string, t: Type | null, line: int32, col: int32): void {
	const view = nestedViewType(t);
	if (view == null) return;
	addError(ctx, what + " of type " + typeDisplayName(t!) + " cannot hold " + typeDisplayName(view)
		+ " inside it: a view borrows memory its source can free while the container still holds it — use " + ownedAlternativeOf(view), line, col);
}
function refuseSuspendingViewParam(ctx: CheckerContext, name: string, t: Type | null, line: int32, col: int32): void {
	const view = findViewType(t);
	if (view == null) return;
	const what = view.kind == TypeKind.Var ? "a ref/out parameter" : "a " + typeDisplayName(view) + " view";
	addError(ctx, "parameter '" + name + "' of an async or generator function cannot be " + what
		+ ": its parameters are captured into the frame the function suspends in, and the memory they point at can change or die across an await or yield — take the view again after each await, or pass a copy with [...x]", line, col);
}

export function refuseUsedSuspendingViewParams(ctx: CheckerContext, paramSyms: Symbol[], paramTypes: Type[], paramLocs: SourceLocation[] | null, fallback: SourceLocation): void {
	for (let i = 0; i < paramSyms.length && i < paramTypes.length; i += 1) {
		if (!hasFlag(paramSyms[i], SymbolFlag.Used)) continue;
		const at = paramLocs != null && i < paramLocs.length && paramLocs[i] != null ? paramLocs[i] : fallback;
		refuseSuspendingViewParam(ctx, paramSyms[i].name, paramTypes[i], at.line, at.column);
	}
}

export function explicitTypeArgs(node: Node, ctx: CheckerContext, limit: int32): (Type | null)[] {
	const out: (Type | null)[] = [];
	const explicitStr = findCallTypeArg(node);
	if (explicitStr == "") return out;
	const argNames = splitTopLevel(explicitStr, ",");
	for (let i = 0; i < limit && i < argNames.length; i += 1) {
		const argTypeStr = argNames[i].trim();
		const resolved = argTypeStr == "" ? null : resolveAnnotation(argTypeStr, ctx, node.location.line, node.location.column);
		out.push(resolved != null && !isUnresolvedType(resolved) ? resolved : null);
	}
	return out;
}

export function bindFromExplicitTypeArgs(node: Node, params: Type[], ctx: CheckerContext): UnifyBindings {
	const result = createUnifyBindings();
	if (params.length == 0) return result;
	const args = explicitTypeArgs(node, ctx, params.length);
	for (let i = 0; i < args.length; i += 1) {
		const resolved = args[i];
		if (resolved != null) bindParam(result, params[i], resolved);
	}
	return result;
}

export function checkExplicitTypeArgArity(ctx: CheckerContext, node: Node, paramNames: string[], calleeName: string): boolean {
	const explicitStr = findCallTypeArg(node);
	if (explicitStr == "") return true;
	let given: int32 = 0;
	for (const a of splitTopLevel(explicitStr, ",")) {
		if (a.trim() != "") given += 1;
	}
	if (given == paramNames.length) return true;
	addError(ctx, `Wrong number of type arguments to '${calleeName}': expected ${paramNames.length}, got ${given}`, node.location.line, node.location.column);
	return false;
}

function refWrapsNominal(refType: Type): boolean {
	const nominal = peelToStructOrUnion(refType.typeReturn);
	return nominal != null && (nominal.kind == TypeKind.Struct || nominal.kind == TypeKind.Union);
}

function declaredByAnotherSymbol(t: Type, alias: Symbol): boolean {
	const owner = t.sym;
	if (owner == null || owner == alias) return false;
	const k = owner.symbolKind;
	return k == SymbolKind.Class || k == SymbolKind.Interface || k == SymbolKind.Struct || k == SymbolKind.Actor || k == SymbolKind.Enum;
}

function instanceOfAliasToNamedType(ctx: CheckerContext, alias: Symbol, baseName: string, genericParams: string, args: Type[], line: int32, col: int32): Type | null {
	if (alias.symbolKind != SymbolKind.TypeAlias) return null;
	markUsedIn(ctx, alias);
	ensureShaped(alias, ctx);
	const body = alias.symbolType;
	const isRef = body.kind == TypeKind.Ref && body.typeReturn != null;
	const inner = isRef ? body.typeReturn : body;
	const namesDeclared = body.kind == TypeKind.Alias || (inner.kind == TypeKind.Struct && declaredByAnotherSymbol(inner, alias));
	if (namesDeclared && genericParamsOf(body.kind == TypeKind.Alias ? body.typeReturn : inner) != "") return null;
	if (!namesDeclared && inner.kind != TypeKind.GenericInstance && inner.kind != TypeKind.Conditional) return null;
	checkTypeArgConstraints(ctx, alias, baseName, args, line, col);
	if (namesDeclared) return body;
	const names = splitTopLevel(genericParamNamesOf(genericParams), ",");
	const inst = substituteParams(inner, declaredTypeParams(alias, names.length), args);
	if (inst.kind == TypeKind.GenericInstance && inst.typeReturn == null) {
		const declParams = genericParamsOf(inst);
		if (declParams != "") instantiateGenericBody(inst, declParams);
	}
	return isRef ? createRef(inst) : inst;
}

function resolveTypeTest(text: string, ctx: CheckerContext, line: int32, col: int32): Type {
	ctx.typeTestDepth = ctx.typeTestDepth + 1;
	const tested = resolveAnnotation(text, ctx, line, col);
	ctx.typeTestDepth = ctx.typeTestDepth - 1;
	return tested;
}

function checkTypeArgConstraints(ctx: CheckerContext, sym: Symbol, baseName: string, args: Type[], line: int32, col: int32): void {
	for (let ci = 0; ci < sym.typeParams.length && ci < args.length; ci += 1) {
		const declared = sym.typeParams[ci].typeExtra;
		if (declared == null) continue;
		const constraint = substituteParams(declared, sym.typeParams, args);
		if (!isUnresolvedType(constraint)
				&& !hasGenericParams(constraint)
				&& !isUnresolvedType(args[ci])
				&& args[ci].kind != TypeKind.GenericParam
				&& !isAssignableCheck(args[ci], constraint)) {
			addError(ctx, `Type '${typeDisplayName(args[ci])}' does not satisfy constraint '${typeDisplayName(constraint)}' for type parameter '${sym.typeParams[ci].typeName}' in '${baseName}'`, line, col);
		}
	}
}

function bitSetElementAllowed(elem: Type): boolean {
	if (isUnresolvedType(elem) || hasGenericParams(elem)) return true;
	if (elem.kind == TypeKind.GenericParam || elem.kind == TypeKind.TypeReference || elem.kind == TypeKind.Error) return true;
	return isOrdinalEnum(elem);
}

type TypeInstanceHooksFn = (instType: Type, ctx: CheckerContext, line: int32, col: int32) => void;

let typeInstanceHooksFn: TypeInstanceHooksFn = (instType: Type, ctx: CheckerContext, line: int32, col: int32): void => {
};

export function registerTypeInstanceHooks(fn: TypeInstanceHooksFn): void {
	typeInstanceHooksFn = fn;
}

export function builtinTypeNamed(ctx: CheckerContext, name: string): Type | null {
	if (lookupSymbol(ctx.table, name) != null) return null;
	const t = resolveAnnotation(name, ctx, 0, 0);
	return isUnresolvedType(t) || t.kind == TypeKind.Null || t.sym != null ? null : t;
}

function isAllDigits(s: string): boolean {
	if (s.length == 0) return false;
	for (let i = 0; i < s.byteLength; i += 1) {
		const code = s.byteAt(i);
		if (code < "0".code || code > "9".code) return false;
	}
	return true;
}

function bindDimensionNames(expr: Node, ctx: CheckerContext): boolean {
	return match (expr.kind) {
		NodeKind.NumberLiteral => true,
		NodeKind.Identifier => {
			const sym = lookupSymbol(ctx.table, (expr.data as IdentifierData).name);
			if (sym == null) return false;
			ensureShaped(sym, ctx);
			markUsedIn(ctx, sym);
			expr.resolvedSym = sym;
			return true;
		},
		NodeKind.BinaryExpr => {
			const d = expr.data as BinaryExprData;
			return bindDimensionNames(d.left, ctx) && bindDimensionNames(d.right, ctx);
		},
		NodeKind.UnaryExpr => bindDimensionNames((expr.data as UnaryExprData).operand, ctx),
		_ => false,
	};
}

function constArrayDimension(text: string, ctx: CheckerContext, line: int32, col: int32): int32 {
	const tokens = lex(text);
	if (!tokens.ok) return -1;
	const state = createState(tokens.value);
	const parsed = parseExpressionFromState(state);
	if (!parsed.ok || !isAtEnd(state) || !bindDimensionNames(parsed.value, ctx)) return -1;
	const folded = constantLiteralOf(parsed.value, 0);
	if (folded == null || folded.kind != NodeKind.NumberLiteral) return -1;
	const fd = folded.data as NumberLiteralData;
	if (fd.isFloat || fd.intVal < 0 || fd.intVal > 2147483647) return -1;
	return fd.intVal as int32;
}

function refuseVoidMember(ctx: CheckerContext, parts: string[], members: Type[], text: string, line: int32, col: int32): void {
	let hasVoid = false;
	for (const m of members) {
		if (m.kind == TypeKind.Void) hasVoid = true;
	}
	if (!hasVoid) return;
	const kept: string[] = [];
	let i = 0;
	for (const up of parts) {
		const part = up.trim();
		if (part.length == 0) continue;
		const shown = members[i].kind == TypeKind.Void ? "null" : part;
		if (!kept.includes(shown)) kept.push(shown);
		i += 1;
	}
	const msg = "'" + text + "' puts void in a union, and void is no value — write '" + kept.join(" | ") + "'";
	for (const e of ctx.errors) {
		if (e.message == msg) return;
	}
	addError(ctx, msg, line, col);
}

function resolveKeyOf(operand: string, ctx: CheckerContext, line: int32, col: int32): Type {
	const objectType = resolveAnnotation(operand, ctx, line, col);
	if (objectType.kind == TypeKind.Error) return objectType;
	if (hasGenericParams(objectType)) return createKeyOfType(objectType);
	const keys = keyOfType(objectType);
	if (keys == null) {
		if (line > 0) addError(ctx, `'keyof ${operand.trim()}' has no keys: '${typeDisplayName(objectType)}' is not an object type with properties`, line, col);
		return errorType();
	}
	return keys;
}

function resolveIndexedAccess(objectText: string, indexText: string, ctx: CheckerContext, line: int32, col: int32): Type | null {
	const indexSym = lookupSymbol(ctx.table, indexText.trim());
	if (indexSym != null && !isTypeSymbol(indexSym)) return null;
	const indexType = resolveAnnotation(indexText, ctx, 0, 0);
	const isKey = indexType.kind == TypeKind.GenericParam || isKeyConstraint(indexType) || isNumeric(indexType);
	if (!isKey) return null;
	const objectType = resolveAnnotation(objectText, ctx, line, col);
	if (objectType.kind == TypeKind.Error) return objectType;
	const access = indexedAccessOf(objectType, indexType);
	if (access != null) return access;
	if (line > 0) addError(ctx, `'${indexText}' is not a key of '${typeDisplayName(objectType)}'`, line, col);
	return errorType();
}

function genericInstanceOf(ctx: CheckerContext, sym: Symbol, genericParams: string, args: Type[], line: int32, col: int32): Type {
	const isRefBase = sym.symbolType.kind == TypeKind.Ref && refWrapsNominal(sym.symbolType);
	let baseType = sym.symbolType;
	if (isRefBase && baseType.typeReturn != null) baseType = baseType.typeReturn;
	const gi = createGenericInstance(baseType, args);
	gi.typeName = sym.name;
	instantiateGenericBody(gi, genericParams);
	typeInstanceHooksFn(gi, ctx, line, col);
	return isRefBase ? createRef(gi) : gi;
}

// An instance whose body is a read-only view is that view, so no write reaches through the
// alias. A mapped type with nothing generic left that did not become an object type: a Map
// when its keys are all of `string` or of `number`, as `{ [key: K]: V }` is; refused otherwise.
function settleMapped(ctx: CheckerContext, t: Type, line: int32, col: int32): Type {
	let body: Type | null = t;
	while (body != null && (body.kind == TypeKind.GenericInstance || body.kind == TypeKind.Ref)) {
		if (body.kind == TypeKind.GenericInstance && body.typeReturn == null) instantiateGenericBody(body, genericParamsOf(body));
		if (body != t && isReadonlyView(body)) return body;
		body = body.typeReturn;
	}
	if (t.kind == TypeKind.GenericInstance && isReadonlyView(body)) return body!;
	if (body == null || body.kind != TypeKind.Mapped || mappedIsGeneric(body)) return t;
	const index = mappedIndexKey(body);
	const mapSym = index != null ? lookupTypeSym(ctx, "Map") : null;
	if (mapSym != null) {
		ensureShaped(mapSym, ctx);
		return genericInstanceOf(ctx, mapSym, symGenericParams(mapSym), [index!, mappedValueAt(body, index!)], line, col);
	}
	if (line > 0) addError(ctx, `'${typeDisplayName(t)}' is no object type: ${mappedRefusal(body)}`, line, col);
	return errorType();
}

interface MappedMember {
	param: string;
	constraint: string;
	nameType: string;
	template: string;
	modifiers: BitSet<MappedModifier>;
	trailing: string;
}

function skipBlanks(text: string, at: int32): int32 {
	let i = at;
	while (i < text.length && (text.charAt(i) == " " || text.charAt(i) == "\t" || text.charAt(i) == "\n")) i += 1;
	return i;
}

interface ModifierScan { at: int32; mods: BitSet<MappedModifier>; }

// A `+`/`-` sign before a modifier, then the modifier: the bit for adding or removing it.
function modifierAt(text: string, scan: ModifierScan, word: string, add: MappedModifier, remove: MappedModifier): ModifierScan {
	let i = skipBlanks(text, scan.at);
	let sign = "";
	if (i < text.length && (text.charAt(i) == "+" || text.charAt(i) == "-")) {
		sign = text.charAt(i);
		i = skipBlanks(text, i + 1);
	}
	if (!text.slice(i, text.length).startsWith(word)) return scan;
	return { at: i + word.length, mods: scan.mods.incl(sign == "-" ? remove : add) };
}

// `[readonly] [P in C (as N)] (?): X`, the only member of a mapped type; null for any other member.
function mappedMemberOf(inner: string): MappedMember | null {
	const readonly = modifierAt(inner, { at: 0, mods: 0 as BitSet<MappedModifier> }, "readonly", MappedModifier.IncludeReadonly, MappedModifier.ExcludeReadonly);
	const i = skipBlanks(inner, readonly.at);
	if (i >= inner.length || inner.charAt(i) != "[") return null;
	let depth = 0;
	let close = -1;
	for (let j = i; j < inner.length && close < 0; j += 1) {
		depth = bracketDepthStep(inner, j) + depth;
		if (depth == 0) close = j;
	}
	if (close < 0) return null;
	const head = inner.slice(i + 1, close).trim();
	const inAt = findTopLevelKeyword(head, " in ");
	if (inAt <= 0 || !isValidTypeIdentifier(head.slice(0, inAt).trim())) return null;
	const range = head.slice(inAt + 4, head.length).trim();
	const asAt = findTopLevelKeyword(range, " as ");
	const optional = modifierAt(inner, { at: close + 1, mods: readonly.mods }, "?", MappedModifier.IncludeOptional, MappedModifier.ExcludeOptional);
	const rest = skipBlanks(inner, optional.at);
	if (rest >= inner.length || inner.charAt(rest) != ":") return null;
	const body = inner.slice(rest + 1, inner.length);
	const members = splitTopLevel(body, body.indexOf(";") >= 0 ? ";" : ",");
	let trailing = "";
	for (let m = 1; m < members.length; m += 1) trailing = trailing + members[m].trim();
	return {
		param: head.slice(0, inAt).trim(),
		constraint: asAt >= 0 ? range.slice(0, asAt).trim() : range,
		nameType: asAt >= 0 ? range.slice(asAt + 4, range.length).trim() : "",
		template: members.length > 0 ? members[0].trim() : "",
		modifiers: optional.mods,
		trailing,
	};
}

// Reference: getTypeFromMappedTypeNode. The modifiers type is T of `keyof T`, or of the
// `keyof T` a type parameter key is constrained by (getModifiersTypeFromMappedType).
function resolveMappedMember(m: MappedMember, text: string, ctx: CheckerContext, line: int32, col: int32): Type {
	if (m.trailing != "") {
		if (line > 0) addError(ctx, `a mapped type may not declare properties or methods: '${text}'; write the other members in an intersection, '{ [${m.param} in ${m.constraint}]: ${m.template} } & { ... }'`, line, col);
		return errorType();
	}
	let mods = m.modifiers;
	let source: Type | null = null;
	let constraint: Type;
	if (m.constraint.startsWith("keyof ")) {
		source = resolveAnnotation(m.constraint.slice(6, m.constraint.length), ctx, line, col);
		if (source.kind == TypeKind.Error) return source;
		mods = mods.incl(MappedModifier.KeyOfDeclared);
		const keys = hasGenericParams(source) ? createKeyOfType(source) : keyOfType(source);
		constraint = keys != null ? keys : neverType();
	} else {
		constraint = resolveAnnotation(m.constraint, ctx, line, col);
		if (constraint.kind == TypeKind.Error) return constraint;
		const bound = constraint.kind == TypeKind.GenericParam ? constraint.typeExtra : null;
		if (bound != null && bound.kind == TypeKind.KeyOf && bound.typeChildren.length == 1) source = bound.typeChildren[0];
	}
	openScope(ctx.table, ScopeKind.Block);
	const param = defineGenericParam(ctx, m.param);
	param.typeExtra = constraint;
	const nameType = m.nameType != "" ? resolveAnnotation(m.nameType, ctx, line, col) : null;
	const template = resolveAnnotation(m.template, ctx, line, col);
	closeScope(ctx.table);
	return settleMapped(ctx, evaluateMappedType(createMappedType(param, constraint, template, nameType, source, mods)), line, col);
}

// `Exclude<T, U>` and `Extract<T, U>`: conditional types over T, distributive as the lib's
// `T extends U ? never : T` is.
function distributiveOver(check: Type, extendsType: Type, keep: boolean): Type {
	const param = createGenericParam("$check");
	const cond = createConditionalType(param, extendsType, keep ? param : neverType(), keep ? neverType() : param);
	markDistributive(cond);
	return substituteParams(cond, [param], [check]);
}

// TypeScript's lib utility types, as the lib declares them over mapped and conditional types:
// `Partial<T> = { [P in keyof T]?: T[P] }` and the rest. Built here rather than declared in
// the prelude, like `Readonly<T>`, so a builder that predates mapped types still reads std.
function utilityType(head: string, args: string[], ctx: CheckerContext, line: int32, col: int32): Type | null {
	const arity = match (head) {
		"Partial" | "Required" => 1,
		"Pick" | "Omit" | "Record" | "Exclude" | "Extract" => 2,
		_ => 0,
	};
	if (arity == 0 || args.length != arity) return null;
	const first = resolveAnnotation(args[0], ctx, line, col);
	if (first.kind == TypeKind.Error) return first;
	const second = arity == 2 ? resolveAnnotation(args[1], ctx, line, col) : null;
	if (second != null && second.kind == TypeKind.Error) return second;
	if (head == "Exclude" || head == "Extract") return distributiveOver(first, second!, head == "Extract");
	const key = createGenericParam("$key");
	if (head == "Record") {
		return settleMapped(ctx, evaluateMappedType(createMappedType(key, first, second!, null, null, 0 as BitSet<MappedModifier>)), line, col);
	}
	if (head == "Partial" || head == "Required") {
		const source = createGenericParam("$source");
		const mods = (0 as BitSet<MappedModifier>).incl(MappedModifier.KeyOfDeclared)
			.incl(head == "Partial" ? MappedModifier.IncludeOptional : MappedModifier.ExcludeOptional);
		const homomorphic = createMappedType(key, createKeyOfType(source), createIndexedAccessType(source, key), null, source, mods);
		return settleMapped(ctx, substituteParams(homomorphic, [source], [first]), line, col);
	}
	const keysOfFirst = hasGenericParams(first) ? createKeyOfType(first) : keyOfType(first);
	const allKeys = keysOfFirst != null ? keysOfFirst : neverType();
	if (head == "Pick" && !hasGenericParams(first) && !hasGenericParams(second!) && !isAssignableCheck(second!, allKeys)) {
		if (line > 0) addError(ctx, `type '${typeDisplayName(second!)}' does not satisfy the constraint 'keyof ${typeDisplayName(first)}' of Pick: the keys are ${typeDisplayName(allKeys)}`, line, col);
		return errorType();
	}
	const constraint = head == "Pick" ? second! : distributiveOver(allKeys, second!, false);
	const template = indexedAccessOf(first, key);
	const mapped = createMappedType(key, constraint, template != null ? template : createIndexedAccessType(first, key), null, first, 0 as BitSet<MappedModifier>);
	return settleMapped(ctx, evaluateMappedType(mapped), line, col);
}

export function resolveAnnotation(text: string, ctx: CheckerContext, line: int32, col: int32): Type {
	let trimmed = text.trim();
	if (trimmed == "") return inferredType();
	// Strip outer parens that wrap the entire expression (not function type form `(...) => ...`).
	// `(T | null)`, `(A & B)`, etc. — needed when `(...)` surrounds the type before an array
	// suffix `[]` strips down to the parenthesised form. Without this, splitTopLevel("|") sees
	// `|` inside parens (depth > 0) and skips union detection.
	while (trimmed.length >= 2 && trimmed.charAt(0) == "(" && trimmed.charAt(trimmed.length - 1) == ")") {
		// Verify the outer parens match (depth returns to 0 only at the final char) AND that
		// this isn't a function type form `(params) => ret` (those reach the `=>` branch below).
		let depth = 0;
		let closesAtEnd = true;
		let isFnForm = false;
		for (let i = 0; i < trimmed.length; i += 1) {
			const c = trimmed.charAt(i);
			if (c == "(") depth = depth + 1;
			if (c == ")") {
				depth = depth - 1;
				if (depth == 0 && i < trimmed.length - 1) {
					closesAtEnd = false;
					const after = trimmed.slice(i + 1, trimmed.length).trim();
					if (after.length >= 2 && after.charAt(0) == "=" && after.charAt(1) == ">") isFnForm = true;
					break;
				}
			}
		}
		if (!closesAtEnd || isFnForm) break;
		trimmed = trimmed.slice(1, trimmed.length - 1).trim();
	}

	// Balance-skipped positions (generic arguments, object-type fields) never reach
	// skipTypeAtom, so this is where a misplaced `distinct` surfaces for them.
	if (trimmed.length > 9 && trimmed.slice(0, 9) == "distinct ") {
		addError(ctx, "'distinct' is only allowed at the start of a type alias right-hand side (type X = distinct Y)", line, col);
		return errorType();
	}

	if (trimmed.length > 7 && trimmed.slice(0, 7) == "typeof ") return resolveTypeQuery(ctx, trimmed.slice(7, trimmed.length).trim(), line, col);

	// Tier 3: infer X — produce a GenericParam placeholder for conditional type unification
	if (trimmed.length > 6 && trimmed.slice(0, 6) == "infer ") {
		const inferName = trimmed.slice(6, trimmed.length).trim();
		if (inferName != "") return declareInfer(ctx, inferName);
	}

	// Function type: (params) => returnType
	if (trimmed.length > 0 && trimmed.charAt(0) == "(") {
		let fnDepth = 0;
		let fnCloseIdx = -1;
		for (let i = 0; i < trimmed.length; i += 1) {
			const c = trimmed.charAt(i);
			if (c == "(") fnDepth += 1;
			if (c == ")") {
				fnDepth -= 1;
				if (fnDepth == 0) { fnCloseIdx = i; break; }
			}
		}
		if (fnCloseIdx >= 0) {
			const afterClose = trimmed.slice(fnCloseIdx + 1, trimmed.length).trim();
			if (afterClose.length >= 2 && afterClose.charAt(0) == "=" && afterClose.charAt(1) == ">") {
				return resolveFunctionType(trimmed, ctx, line, col);
			}
		}
	}

	// Tier 3: Conditional type: T extends U ? A : B
	// Detect " extends " at top level (not inside brackets/parens).
	const extendsIdx = findTopLevelKeyword(trimmed, " extends ");
	if (extendsIdx >= 0) {
		const checkPart = trimmed.slice(0, extendsIdx).trim();
		const afterExtends = trimmed.slice(extendsIdx + 9, trimmed.length).trim();
		// Find top-level '?' in the remainder
		const qIdx = findTopLevelKeyword(afterExtends, "?");
		if (qIdx >= 0) {
			const constraintPart = afterExtends.slice(0, qIdx).trim();
			const afterQ = afterExtends.slice(qIdx + 1, afterExtends.length).trim();
			const colonIdx = findTrueBranchEnd(afterQ);
			if (colonIdx >= 0) {
				const truePart = afterQ.slice(0, colonIdx).trim();
				const falsePart = afterQ.slice(colonIdx + 1, afterQ.length).trim();
				const checkType = resolveAnnotation(checkPart, ctx, line, col);
				const outerDeclared = inferDeclared;
				const declared: Type[] = [];
				inferDeclared = declared;
				const extendsType = resolveTypeTest(constraintPart, ctx, line, col);
				inferDeclared = outerDeclared;
				const inferSaved = inferScope.length;
				for (const gp of declared) inferScope.push(gp);
				const trueType = resolveAnnotation(truePart, ctx, line, col);
				const falseType = resolveAnnotation(falsePart, ctx, line, col);
				while (inferScope.length > inferSaved) { inferScope.pop(); }
				const cond = createConditionalType(checkType, extendsType, trueType, falseType);
				setInferParams(cond, declared);
				markDistributive(cond);
				return evaluateConditionalType(cond);
			}
		}
	}

	// Check for intersection types (split on top-level &) — erasure tier.
	// Intersection binds tighter than union, so checked BEFORE the union split.
	// At runtime the type collapses to its left-most operand; downstream
	// passes (checker / transform / codegen) never see an Intersection Type.
	// Branded types like `string & { __brand: "X" }` resolve to `string`.
	const intersectionParts = splitTopLevel(trimmed, "&");
	if (intersectionParts.length >= 2) {
		// Two-tier semantic:
		//   - All operands object-like (struct/interface/anonymous object) →
		//     synthesize a merged struct with all fields combined. Matches
		//     TypeScript intersection field merging (LANG.md §5.3 example
		//     `type Extended = IUser & { role: string }`).
		//   - Any operand is primitive (e.g. `string & { __brand: "X" }`) →
		//     erasure to first operand (branded primitives, Bug 1 path).
		const operandTypes: Type[] = [];
		const operandLabels: string[] = [];
		let allObjectLike = true;
		for (const ip of intersectionParts) {
			const part = ip.trim();
			if (part.length == 0) continue;
			const opType = resolveAnnotation(part, ctx, line, col);
			operandTypes.push(opType);
			operandLabels.push(part);
			if (unwrapToStruct(opType).kind != TypeKind.Struct) {
				allObjectLike = false;
			}
		}
		if (operandTypes.length >= 2 && allObjectLike) {
			const mergedNames: string[] = [];
			const mergedTypes: Type[] = [];
			const mergedOptional: string[] = [];
			for (let oi = 0; oi < operandTypes.length; oi += 1) {
				appendStructFields(unwrapToStruct(operandTypes[oi]), operandLabels[oi], mergedNames, mergedTypes, ctx, line, col, mergedOptional);
			}
			const merged = createStruct("", mergedNames, mergedTypes, true);
			if (mergedOptional.length > 0) merged.optionalFields = mergedOptional;
			return createRef(merged);
		}
		if (operandTypes.length >= 2) {
			const brand = tryBrandIntersection(operandTypes);
			if (brand != null) return brand;
		}
		// Erasure tier (non-brand mix): first operand wins. S2 (TSGAP item 5)
		// replaces this silent collapse with a hard error.
		const firstPart = intersectionParts[0].trim();
		if (firstPart.length > 0) {
			return resolveAnnotation(firstPart, ctx, line, col);
		}
	}

	// Check for union types (split on top-level |)
	const unionParts = splitTopLevel(trimmed, "|");
	if (unionParts.length >= 2) {
		const members: Type[] = [];
		for (const up of unionParts) {
			const part = up.trim();
			if (part.length > 0) {
				members.push(resolveAnnotation(part, ctx, line, col));
			}
		}
		if (line > 0) refuseVoidMember(ctx, unionParts, members, trimmed, line, col);
		if (members.length > 0 && isNullableShape(members) && !anyHasGenericParams(members)) {
			for (const m of members) {
				if (isForwardAlias(m)) return deferNullableUnion(members);
			}
			return nullableUnionOf(members);
		}
		if (members.length > 0) return createUnion(members);
	}

	// String literal type: "north" → StringLiteral("north") (TypeScript parity)
	if (trimmed.length >= 2 && trimmed.charAt(0) == "\"" && trimmed.charAt(trimmed.length - 1) == "\"") {
		return createStringLiteral(trimmed.slice(1, trimmed.length - 1));
	}

	if (trimmed.length > 6 && trimmed.slice(0, 6) == "keyof ") return resolveKeyOf(trimmed.slice(6, trimmed.length), ctx, line, col);

	// Boolean literal type: `true` / `false` → BooleanLiteral (TypeScript parity)
	// Required for discriminated union narrowing on boolean discriminants
	// (e.g. `type Result<T,E> = { ok: true, value: T } | { ok: false, error: E }`).
	if (trimmed == "true") return createBooleanLiteral(true);
	if (trimmed == "false") return createBooleanLiteral(false);

	const digits = trimmed.startsWith("-") ? trimmed.slice(1, trimmed.length).trim() : trimmed;
	if (digits.length > 0 && digits.byteAt(0) >= "0".code && digits.byteAt(0) <= "9".code) {
		const lit = numberLiteralTypeOf(trimmed.startsWith("-") ? "-" + digits : digits);
		if (lit != null) return lit;
		addError(ctx, "'" + trimmed + "' is not a numeric literal type: write a decimal value within int64 or a finite float64", line, col);
		return errorType();
	}

	// Object literal type: { field: Type; ... } or { field: Type, ... }
	// Also handles index signature: { [key: K]: V } → normalized to Map<K, V>.
	// Ordered `Map` is the target (not HashMap) because JS object literals preserve
	// insertion order — the semantic match for `{ [key: K]: V }` sugar.
	if (trimmed.charAt(0) == "{" && trimmed.endsWith("}")) {
		const inner = trimmed.slice(1, trimmed.length - 1).trim();
		if (inner == "") return createRef(createStruct("", [], [], true));
		const mappedMember = mappedMemberOf(inner);
		if (mappedMember != null) return resolveMappedMember(mappedMember, trimmed, ctx, line, col);

		// Index signature: { [name: K]: V } is syntactic sugar for Map<K, V> (ordered).
		// After normalization, both syntaxes produce identical Type structs.
		// See docs/PACKAGE.md and the index signature impl plan.
		if (inner.charAt(0) == "[") {
			// Find the BALANCED closing `]` — the key type may contain its own
			// brackets (e.g. `{ [key: number[]]: V }`), so a naive findChar("]")
			// would stop at the wrong bracket.
			let bracketDepth = 0;
			let closeBracket = -1;
			let bi = 0;
			while (bi < inner.length) {
				const c = inner.charAt(bi);
				if (c == "[") { bracketDepth = bracketDepth + 1; }
				else if (c == "]") {
					bracketDepth = bracketDepth - 1;
					if (bracketDepth == 0) { closeBracket = bi; bi = inner.length; }
				}
				bi = bi + 1;
			}
			if (closeBracket > 0) {
				// Find the FIRST colon (inside [...], between name and key type)
				const nameColon = findChar(inner, ":");
				if (nameColon > 0 && nameColon < closeBracket) {
					const keyType = inner.slice(nameColon + 1, closeBracket).trim();
					// Everything after `]` should be `: V` (with optional trailing ;)
					let afterBracket = inner.slice(closeBracket + 1, inner.length).trim();
					// Strip trailing semicolon(s)
					while (afterBracket.length > 0 && afterBracket.charAt(afterBracket.length - 1) == ";") {
						afterBracket = afterBracket.slice(0, afterBracket.length - 1).trim();
					}
					if (afterBracket.length > 0 && afterBracket.charAt(0) == ":") {
						const valueType = afterBracket.slice(1, afterBracket.length).trim();
						if (keyType != "" && valueType != "") {
							// Rewrite to Map<K, V> (ordered) and recurse — reuses all generic resolution.
							const mapAnnotation = "Map<" + keyType + ", " + valueType + ">";
							return resolveAnnotation(mapAnnotation, ctx, line, col);
						}
					}
				}
			}
		}

		// TypeScript uses semicolons in type position, commas in value position — support both
		const hasSemicolon = inner.indexOf(";") >= 0;
		const fields = splitTopLevel(inner, hasSemicolon ? ";" : ",");
		const names: string[] = [];
		const types: Type[] = [];
		const optionalFields: string[] = [];
		for (const f of fields) {
			const field = f.trim();
			if (field != "") {
				const colonIdx = findChar(field, ":");
				if (colonIdx > 0) {
					let fname = field.slice(0, colonIdx).trim();
					let fieldIsOptional = false;
					if (fname.endsWith("?")) {
						fname = fname.slice(0, fname.length - 1).trim();
						fieldIsOptional = true;
					}
					let ftypeStr = field.slice(colonIdx + 1, field.length).trim();
					if (fieldIsOptional) {
						ftypeStr = optionalizeTypeString(ftypeStr);
						optionalFields.push(fname);
					}
					names.push(fname);
					types.push(resolveAnnotation(ftypeStr, ctx, line, col));
				}
			}
		}
		const objectType = createStruct("", names, types, true);
		if (optionalFields.length > 0) objectType.optionalFields = optionalFields;
		recordForwardFields(objectType, types);
		return createRef(objectType);
	}

	// Tuple type: [T, U, ...] — bracket at start AND end, distinct from `T[]` array suffix.
	// This is checked BEFORE array suffixes because those forms have a base type before the `[`.
	if (trimmed.charAt(0) == "[" && trimmed.endsWith("]")) {
		const tupleInner = trimmed.slice(1, trimmed.length - 1).trim();
		if (tupleInner == "" && line > 0) {
			addError(ctx, "the empty tuple type '[]' has no value representation: drop the parameter or give the tuple an element", line, col);
			return errorType();
		}
		if (tupleInner != "") {
			const elements = splitTopLevel(tupleInner, ",");
			// Single element with no comma is ambiguous with `[N]` size, but standalone
			// `[N]` isn't valid TS — we treat it as a 1-element tuple. `[T]` works.
			const tupleTypes: Type[] = [];
			let firstOptional = -1;
			for (const e of elements) {
				const element = tupleElementText(e);
				if (element.text == "") continue;
				if (element.optional && firstOptional < 0) firstOptional = tupleTypes.length;
				if (!element.optional && firstOptional >= 0 && line > 0) {
					addError(ctx, "A required element cannot follow an optional element: '" + e.trim() + "' in '" + trimmed + "'", line, col);
				}
				const text = element.optional ? optionalizeTypeString(element.text) : element.text;
				tupleTypes.push(resolveAnnotation(text, ctx, line, col));
			}
			if (tupleTypes.length > 0) {
				const tuple = createTuple(tupleTypes);
				if (firstOptional >= 0) setMinArity(tuple, firstOptional);
				return tuple;
			}
		}
	}

	// Check for array suffix [] or [ ] (token-joined form from captureOptionalType)
	if (trimmed.endsWith("[ ]")) {
		const inner = trimmed.slice(0, trimmed.length - 3).trim();
		return createRef(createArray(resolveAnnotation(inner, ctx, line, col)));
	}
	if (trimmed.endsWith("[]")) {
		const inner = trimmed.slice(0, trimmed.length - 2);
		return createRef(createArray(resolveAnnotation(inner, ctx, line, col)));
	}
	if (trimmed.endsWith("]")) {
		const openBracket = findChar(trimmed, "[");
		if (openBracket > 0) {
			const inner = trimmed.slice(0, openBracket).trim();
			const sizeStr = trimmed.slice(openBracket + 1, trimmed.length - 1).trim();
			if (sizeStr == "" || sizeStr == " ") {
				return createRef(createArray(resolveAnnotation(inner, ctx, line, col)));
			}
			if (isAllDigits(sizeStr)) {
				return createSizedArray(resolveAnnotation(inner, ctx, line, col), parseIntStr(sizeStr));
			}

			const dim = constArrayDimension(sizeStr, ctx, line, col);
			if (dim < 0) {
				const access = resolveIndexedAccess(inner, sizeStr, ctx, line, col);
				if (access != null) return access;
				if (line > 0) {
					addError(ctx, `array size '${sizeStr}' must be a compile-time integer constant`, line, col);
					return errorType();
				}
				return createSizedArray(resolveAnnotation(inner, ctx, line, col), 0);
			}
			return createSizedArray(resolveAnnotation(inner, ctx, line, col), dim);
		}
	}

	// Check for generic types: Name<A, B> or Name < A, B > (token-joined form)
	const angleBracket = findChar(trimmed, "<");
	if (angleBracket > 0 && trimmed.endsWith(">")) {
		const writtenName = trimmed.slice(0, angleBracket).trim();
		const qualifiedSym = namespaceTypeSym(ctx, writtenName);
		const baseName = qualifiedSym != null ? qualifiedSym.name : writtenName;
		const argsText = trimmed.slice(angleBracket + 1, trimmed.length - 1).trim();
		const args = splitTopLevel(argsText, ",");
		const builtinHead = builtinTypeHead(ctx, writtenName, baseName);

		if (builtinHead == "Result" && args.length == 2) {
			return createResult(resolveAnnotation(args[0], ctx, line, col), resolveAnnotation(args[1], ctx, line, col));
		}
		if (builtinHead == "Promise" && args.length == 1) {
			return promiseAnnotationOf(ctx, resolveAnnotation(args[0], ctx, line, col), line, col);
		}
		if (builtinHead == "Iterator" && args.length == 1) {
			return createIterator(resolveAnnotation(args[0], ctx, line, col));
		}
		if (builtinHead == "Array" && args.length == 1) {
			return createRef(createArray(resolveAnnotation(args[0], ctx, line, col)));
		}
		if (builtinHead == "Vec" && args.length == 1) {
			return createArray(resolveAnnotation(args[0], ctx, line, col));
		}
		if (builtinHead == "BitSet" && args.length == 1) {
			const elem = resolveAnnotation(args[0], ctx, line, col);
			if (!bitSetElementAllowed(elem)) {
				addError(ctx, "BitSet element must be an enum with ordinal members, got '" + typeDisplayName(elem) + "'", line, col);
			}
			return createBitSet(elem);
		}
		if (builtinHead == "Span" && args.length == 1) {
			return createSpan(resolveAnnotation(args[0], ctx, line, col));
		}
		if (builtinHead == "Borrow" && args.length == 1) {
			return createBorrow(resolveAnnotation(args[0], ctx, line, col));
		}
		if (builtinHead == "Ptr" && args.length == 1) {
			return createPtr(resolveAnnotation(args[0], ctx, line, col));
		}
		if (builtinHead == "Cursor" && args.length == 1) {
			return createCursor(resolveAnnotation(args[0], ctx, line, col));
		}
		if (builtinHead == "Ref" && args.length == 1) {
			return createRef(resolveAnnotation(args[0], ctx, line, col));
		}
		if (builtinHead == "Arc" && args.length == 1) {
			return createArc(resolveAnnotation(args[0], ctx, line, col));
		}
		if (builtinHead == "Locked" && args.length == 1) {
			return createLocked(resolveAnnotation(args[0], ctx, line, col));
		}
		if (builtinHead == "Readonly" && args.length == 1) {
			const viewed = resolveAnnotation(args[0], ctx, line, col);
			if (viewed.kind != TypeKind.GenericParam) return createReadonlyView(viewed);
			const source = createGenericParam("$source");
			const mods = (0 as BitSet<MappedModifier>).incl(MappedModifier.KeyOfDeclared).incl(MappedModifier.IncludeReadonly);
			const key = createGenericParam("$key");
			const homomorphic = createMappedType(key, createKeyOfType(source), createIndexedAccessType(source, key), null, source, mods);
			return substituteParams(homomorphic, [source], [viewed]);
		}
		const utility = utilityType(builtinHead, args, ctx, line, col);
		if (utility != null) return utility;
		if (builtinHead == "Var" && args.length == 1) {
			return createVar(resolveAnnotation(args[0], ctx, line, col));
		}
		// Generic interface/class resolution (Map, Set, user-defined generics)
		const genericSym = lookupTypeSym(ctx, writtenName);
		const genericParams = genericSym != null ? symGenericParams(genericSym) : builtinGenericParams(baseName);
		if (genericParams != "") {
			// Check if ALL args are generic params of the enclosing function.
			// If so, preserve as generic type (don't instantiate).
			// e.g. inside set<K,V>(this m: HashMap<K,V>), HashMap<K,V> stays generic.
			let allGenericParams = true;
			const resolvedArgs: Type[] = [];
			for (const arg of args) {
				const resolved = resolveAnnotation(arg.trim(), ctx, line, col);
				resolvedArgs.push(resolved);
				if (resolved.kind != TypeKind.GenericParam) allGenericParams = false;
			}
			const aliased = genericSym != null ? instanceOfAliasToNamedType(ctx, genericSym, baseName, genericParams, resolvedArgs, line, col) : null;
			if (aliased != null) return aliased;
			if (allGenericParams && resolvedArgs.length > 0) {
				// Return GenericInstance with GenericParam type args.
				// This preserves hasGenericParams for unification + enables structural matching.
				const baseSym = lookupTypeSym(ctx, writtenName);
				if (baseSym != null) {
					markUsedIn(ctx, baseSym);
					ensureShaped(baseSym, ctx);
					const isRefBase = baseSym.symbolType.kind == TypeKind.Ref && refWrapsNominal(baseSym.symbolType);
					let baseType = baseSym.symbolType;
					if (isRefBase && baseType.typeReturn != null) baseType = baseType.typeReturn;
					const gi1 = createGenericInstance(baseType, resolvedArgs);
					gi1.typeName = baseSym.name;
					instantiateGenericBody(gi1, genericParams);
					return isRefBase ? createRef(gi1) : gi1;
				}
				return emitUnresolvedTypeRef(ctx, baseName, line, col, "");
			}
			// Concrete instantiation: produce the concrete type.
			// Reference parity (handleGenericInvocation):
			// both type annotations and `new` expressions go through the same
			// instantiation path, producing the same concrete type.
			// Build GenericInstance with structural type args
			const baseSym2 = lookupTypeSym(ctx, writtenName);
			if (baseSym2 != null) {
				markUsedIn(ctx, baseSym2);
				ensureShaped(baseSym2, ctx);
				const resolvedArgs: Type[] = [];
				for (const a of args) {
					resolvedArgs.push(resolveAnnotation(a.trim(), ctx, line, col));
				}
				checkTypeArgConstraints(ctx, baseSym2, baseName, resolvedArgs, line, col);
				return settleMapped(ctx, genericInstanceOf(ctx, baseSym2, genericParams, resolvedArgs, line, col), line, col);
			}
			// Symbol not found — emit error + return TypeRef for recovery
			const typeArgKey = buildTypeArgKey(args, ctx);
			const mangledName = baseName + "__" + typeArgKey;
			return emitUnresolvedTypeRef(ctx, baseName, line, col, mangledName);
		}
		// Non-generic: look up base type
		const baseSym = lookupTypeSym(ctx, writtenName);
		if (baseSym != null) {
			markUsedIn(ctx, baseSym);
			// Demand-driven resolution: ensure the base symbol is shaped before using its type
			ensureShaped(baseSym, ctx);
			return baseSym.symbolType;
		}
		return emitUnresolvedTypeRef(ctx, baseName, line, col, "");
	}

	// Enum literal type: K.A — qualified name referring to a specific enum member.
	// Split on the LAST `.` so nested module paths resolve correctly.
	// Skip if the annotation contains compound-type tokens — those shapes are handled
	// by earlier branches (generics, arrays, objects, function types).
	const hasCompoundToken = trimmed.indexOf("(") >= 0
		|| trimmed.indexOf("<") >= 0
		|| trimmed.indexOf("[") >= 0
		|| trimmed.indexOf("{") >= 0;
	if (!hasCompoundToken && trimmed.indexOf(".") >= 0) {
		let lastDot = -1;
		for (let i = 0; i < trimmed.length; i += 1) {
			if (trimmed.charAt(i) == ".") lastDot = i;
		}
		if (lastDot > 0 && lastDot < trimmed.length - 1) {
			const enumName = trimmed.slice(0, lastDot).trim();
			const memberName = trimmed.slice(lastDot + 1, trimmed.length).trim();
			if (enumName != "" && memberName != "") {
				const enumSym = lookupTypeSym(ctx, enumName);
				if (enumSym != null && enumSym.symbolType != null && enumSym.symbolType.kind == TypeKind.Enum) {
					markUsedIn(ctx, enumSym);
					ensureShaped(enumSym, ctx);
					const enumType = enumSym.symbolType;
					// Verify member exists
					let found = false;
					for (const m of enumType.typeNames) {
						if (m == memberName) { found = true; break; }
					}
					if (found) return createEnumLiteral(enumType, memberName);
					if (line > 0) {
						addWarning(ctx, `Enum '${enumName}' has no member '${memberName}'`, line, col);
					}
					return inferredType();
				}
			}
		}
	}

	// Primitive types, symbol lookup, or forward reference
	return match (trimmed) {
		"number" => numberType(),
		"string" => stringType(),
		"boolean" => booleanType(),
		"void" => voidType(),
		"null" => nullType(),
		"never" => neverType(),
		"unknown" => unknownType(),
		"object" => {
			if (line > 0 && ctx.typeTestDepth == 0) {
				addError(ctx, "'object' only tests a type here, after 'extends' (`V extends object ? A : B`, `<T extends object>`); a value typed 'object' has no representation - type it as a class, an interface or 'unknown'", line, col);
				return errorType();
			}
			return nonPrimitiveType();
		},
		"any" => {
			if (line > 0) {
				addError(ctx, "'any' is not a MetaScript type - use 'unknown' with an explicit cast", line, col);
				return errorType();
			}
			return inferredType();
		},
		"undefined" => {
			if (line > 0) warnOncePerLine(ctx, "'undefined' is an alias of 'null' - prefer 'null'", line, col);
			return nullType();
		},
		"int8" => createPrimitive(TypeKind.Int8),
		"int16" => createPrimitive(TypeKind.Int16),
		"int32" => createPrimitive(TypeKind.Int32),
		"int64" => createPrimitive(TypeKind.Int64),
		"uint8" => createPrimitive(TypeKind.Uint8),
		"uint16" => createPrimitive(TypeKind.Uint16),
		"uint32" => createPrimitive(TypeKind.Uint32),
		"uint64" => createPrimitive(TypeKind.Uint64),
		"float32" => createPrimitive(TypeKind.Float32),
		"float64" => createPrimitive(TypeKind.Float64),
		"bigint" => createPrimitive(TypeKind.BigInt),
		"char" => charType(),
		"cstring" => cstringType(),
		_ => {
			const inferred = inferScopeFind(trimmed);
			if (inferred != null) return inferred;
			const sym = lookupTypeSym(ctx, trimmed);
			if (sym != null && line > 0 && isGenericTypeDecl(sym)) {
				const count = splitTopLevel(declGenericParams(sym.declNode), ",").length;
				addError(ctx, `generic type '${trimmed}' requires ${count} type argument(s)`, line, col);
				return errorType();
			}
			if (sym != null && isStaticHiddenTypeParam(ctx, trimmed, sym)) {
				if (line > 0) addError(ctx, `a static member cannot reference the class type parameter '${trimmed}': one static is shared by every instantiation of the class`, line, col);
				return errorType();
			}
			if (sym != null) {
				markUsedIn(ctx, sym);
				// Demand-driven: ensure shaped before using
				ensureShaped(sym, ctx);
				// Circular type reference: sym still Unknown → return the SAME object
				// (reference parity: forward type identity preservation). When the type is
				// fully resolved later, assignType upgrades this object in-place,
				// and all references automatically see the resolved type.
				return sym.symbolType;
			}
			return emitUnresolvedTypeRef(ctx, trimmed, line, col, "");
		},
	};
}

function resolveTypeQuery(ctx: CheckerContext, operand: string, line: int32, col: int32): Type {
	const sym = lookupSymbol(ctx.table, operand);
	if (sym != null && sym.symbolKind == SymbolKind.Module && sym.symbolType != null) {
		markUsedIn(ctx, sym);
		return sym.symbolType;
	}
	if (line > 0) {
		addError(ctx, `'typeof ${operand}' in a type names a namespace import only ('import * as ${operand} from "…"'); the type of another value is not supported as a type query`, line, col);
		return errorType();
	}
	return inferredType();
}

function namespaceTypeSym(ctx: CheckerContext, name: string): Symbol | null {
	const dot = name.indexOf(".");
	if (dot <= 0) return null;
	const nsSym = lookupSymbol(ctx.table, name.slice(0, dot));
	if (nsSym == null || nsSym.symbolKind != SymbolKind.Module || nsSym.modulePath == "") return null;
	const exported = findExportedSymbol(ctx.exportRegistry, nsSym.modulePath, name.slice(dot + 1, name.length));
	if (exported == null) return null;
	markUsedIn(ctx, nsSym);
	noteImported(ctx, exported.sym);
	return exported.sym;
}

export function builtinTypeHead(ctx: CheckerContext, writtenName: string, baseName: string = ""): string {
	const declared = lookupTypeSym(ctx, writtenName);
	if (declared != null && isTypeSymbol(declared)) return declared.builtinKind;
	return baseName != "" ? baseName : writtenName;
}

function isStaticHiddenTypeParam(ctx: CheckerContext, name: string, sym: Symbol): boolean {
	const boundary = ctx.staticInitBoundary;
	return boundary != null && sym.symbolType != null && sym.symbolType.kind == TypeKind.GenericParam
		&& boundary.symbols.get(getIdentId(ctx.table.identCache, name)) == sym;
}

function lookupTypeSym(ctx: CheckerContext, name: string): Symbol | null {
	const sym = lookupSymbol(ctx.table, name);
	return sym != null ? sym : namespaceTypeSym(ctx, name);
}

function isGenericTypeDecl(sym: Symbol): boolean {
	const k = sym.symbolKind;
	const isTypeDecl = k == SymbolKind.Class || k == SymbolKind.Interface || k == SymbolKind.Struct
		|| k == SymbolKind.TypeAlias || k == SymbolKind.Actor;
	return isTypeDecl && sym.declNode != null && declGenericParams(sym.declNode) != "";
}

// Emit error for unresolved type name and return TypeRef for recovery.
// Reference parity: semTypeIdent calls localError via qualifiedLookUp({checkUndeclared}).
// When line > 0, a located diagnostic is emitted. When line === 0 (inference-time),
// no error — the caller doesn't have source location.
function isValidTypeIdentifier(name: string): boolean {
	if (name.length == 0) return false;
	const ch0 = name.charAt(0);
	// String literals, quoted names, numbers — not type identifiers
	if (ch0 == "\"" || ch0 == "'" || (ch0 >= "0" && ch0 <= "9")) return false;
	// Names with dashes or spaces — string literal union members (parser strips quotes)
	if (name.indexOf("-") >= 0 || name.indexOf(" ") >= 0) return false;
	return true;
}

function emitUnresolvedTypeRef(ctx: CheckerContext, name: string, line: int32, col: int32, mangledName: string): Type {
	if (line > 0 && isValidTypeIdentifier(name)
			&& name.indexOf("__") < 0 && name.indexOf("typeof ") < 0
			&& name != "unknown" && name != "never") {
		// Hard error, not warning: the inferredType() recovery reaches codegen as
		// void*, and call sites then pass &global for what should be an object
		// pointer — a silent memory-corruption miscompile, far worse than failing
		// the build (the missing-NameSet-import incident).
		addError(ctx, `Unresolved type '${name}' - missing import?`, line, col);
		return errorType();
	}
	// Reference parity: unresolved types become inferredType, never TypeReference.
	// All valid types must be resolved during semantic analysis — if lookupSymbol fails,
	// it's a genuine error (missing import, typo). Codegen never does name resolution.
	return inferredType();
}

export function boundAnnotationType(node: Node | null): Type | null {
	if (node == null || !node.flags.has(NodeFlag.BoundSym)) return null;
	if (node.resolvedSym == null || node.nodeType == null) {
		throw new Error("internal: a bound type annotation has no checked symbol or type");
	}
	return node.nodeType;
}

// ===== TypeExpr Recording (standard parity: markUsed in semTypeNode) =====
// Walks a positioned TypeExpr AST tree and records USE for every type identifier.
// Does NOT resolve types — resolveAnnotation still handles that via string path.
// This is purely additive: records symbol positions for LSP hover/goto-def.

export function resolveTypeExpr(node: Node | null, ctx: CheckerContext): void {
	if (node == null) return;
	match (node.kind) {
		NodeKind.Identifier => {
			const d = node.data as IdentifierData;
			const sym = node.flags.has(NodeFlag.BoundSym) ? node.resolvedSym : lookupSymbol(ctx.table, d.name);
			if (sym != null) {
				sgRecordSym(ctx, node.location.line, node.location.column,
					node.location.column + d.name.length,
					sym, sym.symbolType, sym.symbolKind, d.name, "", false);
			}
		},
		NodeKind.TypeGeneric => {
			const d = node.data as TypeGenericData;
			resolveTypeExpr(d.typExprBase, ctx);
			for (const arg of d.typExprArgs) {
				resolveTypeExpr(arg, ctx);
			}
		},
		NodeKind.TypeArray => {
			const d = node.data as TypeArrayData;
			resolveTypeExpr(d.typExprElement, ctx);
		},
		NodeKind.TypeUnion => {
			const d = node.data as TypeUnionData;
			for (const member of d.typExprMembers) {
				resolveTypeExpr(member, ctx);
			}
		},
		NodeKind.TypeIntersection => {
			// Erasure-tier: walk all operands so LSP records inner type identifiers.
			// Resolution to a Type happens at the annotation-string level (Site B
			// below) where intersection collapses to its first operand.
			const d = node.data as TypeIntersectionData;
			for (const member of d.typExprMembers) {
				resolveTypeExpr(member, ctx);
			}
		},
		NodeKind.TypeFunction => {
			const d = node.data as TypeFunctionData;
			for (const param of d.typExprParams) {
				resolveTypeExpr(param, ctx);
			}
			resolveTypeExpr(d.typExprReturn, ctx);
		},
		NodeKind.TypeObject => {
			const d = node.data as TypeObjectData;
			for (const ft of d.typExprFieldTypes) {
				resolveTypeExpr(ft, ctx);
			}
			// Index signature (for LSP symbol recording): walk key and value types too
			if (d.typExprIndexKey != null) { resolveTypeExpr(d.typExprIndexKey, ctx); }
			if (d.typExprIndexValue != null) { resolveTypeExpr(d.typExprIndexValue, ctx); }
		},
		NodeKind.MemberExpr => {
			// Tier 1: enum literal type position — `K.A` produces a MemberExpr.
			// Walk the object (the enum name) and record the member position so LSP
			// can offer hover/goto-def for both the enum and its specific member.
			const md = node.data as MemberExprData;
			resolveTypeExpr(md.object, ctx);
			if (md.object != null && md.object.kind == NodeKind.Identifier) {
				const enumName = (md.object.data as IdentifierData).name;
				const enumSym = lookupSymbol(ctx.table, enumName);
				if (enumSym != null && enumSym.symbolType != null && enumSym.symbolType.kind == TypeKind.Enum) {
					// Record the member position. The dot is 1 column wide.
					const memberCol = md.object.location.column + enumName.length + 1;
					const memberSym = makeSymbol(md.property, SymbolKind.EnumMember, enumSym.symbolType, false);
					memberSym.modulePath = enumSym.modulePath;
					memberSym.location = enumSym.location;
					sgRecordSym(ctx, node.location.line, memberCol, memberCol + md.property.length,
						memberSym, enumSym.symbolType, SymbolKind.EnumMember, md.property, enumName, false);
				}
			}
		},
		// This function is ONLY called on nodes from the typeExpr side channel,
		// which by construction only contains type-expression shapes (Identifier +
		// TypeGeneric/Array/Union/Function/Object). Any other NodeKind here is a
		// no-op: there is nothing to record for LSP. When adding a NEW type-expr
		// kind (e.g. TypeIntersection), add it to the match ABOVE — the wildcard
		// will silently drop it otherwise.
		_ => {},
	};
}

// Resolve all TypeExpr nodes in a type annotation array (params, fields).
// Null-safe: skips null arrays and null entries.
export function resolveTypeExprs(exprs: Node[] | null, ctx: CheckerContext): void {
	if (exprs == null) return;
	for (const te of exprs) {
		if (te == null) continue;
		resolveTypeExpr(te, ctx);
	}
}

// ===== Demand-Driven Shaping (Implementation parity) =====

export function fillForwardSymbol(ctx: CheckerContext, sym: Symbol): void {
	if (!hasFlag(sym, SymbolFlag.Forward)) return;
	sym.symFlags = sym.symFlags.excl(SymbolFlag.Forward);
	const decl = sym.declNode;
	if (decl == null) return;
	if (decl.kind == NodeKind.ClassDecl) fillClass(ctx, decl);
	else if (decl.kind == NodeKind.ActorDecl) fillActor(ctx, decl);
	else return;
	if (hasFlag(sym, SymbolFlag.Exported)) markDeclMethodsExported(ctx, decl);
}

function promiseAnnotationOf(ctx: CheckerContext, inner: Type, line: int32, col: int32): Type {
	if (isAwaitable(inner)) {
		const value = awaitedType(inner);
		const flat = value != null ? "Promise<" + typeDisplayName(value) + ">" : "Promise<T>";
		addError(ctx, `'Promise<${typeDisplayName(inner)}>' is a promise of a promise, which is refused: write '${flat}' (an async function that returns a promise already gives '${flat}')`, line, col);
		return value != null ? createPromise(value) : errorType();
	}
	const delivered = thenablePromised(ctx, inner);
	if (delivered != null) {
		addError(ctx, `'Promise<${typeDisplayName(inner)}>' is a promise of a thenable, which is refused: a promise adopts what a thenable delivers, so write 'Promise<${typeDisplayName(delivered)}>'`, line, col);
		return createPromise(delivered);
	}
	return createPromise(inner);
}

export function thenSignatureOf(ctx: CheckerContext, t: Type): Type | null {
	if (isPrimitiveKind(t.kind) || isStringLike(t)) return null;
	const field = functionSlotOf(getProperty(t, "then"));
	if (field != null) return field;
	if (ctx.extensionRegistry == null) return null;
	const receiver = withoutReadonlyView(t);
	const ext = findDeclaredExt(findAllExtensionsByName(ctx.extensionRegistry, "then"), receiver);
	if (ext == null || ext.isStatic) return null;
	if (ext.sym != null) ensureShaped(ext.sym, ctx);
	const method = getExtFnType(ext);
	if (method.kind != TypeKind.Function || method.typeChildren.length == 0) return null;
	const bindings = createUnifyBindings();
	unifyType(method.typeChildren[0], receiver, bindings);
	return stripReceiverParam(bindings.names.length > 0 ? substituteBound(method, bindings) : method);
}

export function thenablePromised(ctx: CheckerContext, t: Type | null): Type | null {
	if (t == null || isAwaitable(t) || isUnresolvedType(t)) return null;
	const then = thenSignatureOf(ctx, t);
	if (then == null) return null;
	const onFulfilled = then.typeChildren.length > 0 ? functionSlotOf(then.typeChildren[0]) : null;
	if (onFulfilled == null) return null;
	return onFulfilled.typeChildren.length > 0 ? onFulfilled.typeChildren[0] : voidType();
}

export function ensureShaped(sym: Symbol, ctx: CheckerContext): void {
	if (sym.state == SymbolState.Shaped || sym.state == SymbolState.Checking || sym.state == SymbolState.Checked) {
		// A primary can reach Shaped BEFORE later overloads are appended to it:
		// one scope shared by several modules (the prelude context) resolves
		// `set` when the FIRST module declaring it is resolved, and every later
		// module's `set` lands on that already-shaped symbol as an overload.
		// resolveDeclarations shapes by NAME, so those arrivals are never
		// visited and stay Hollow — getExtFnType then falls back to noneType
		// and isReceiverMatch rejects a perfectly good extension.
		// Draining here keeps "shaped primary => shaped overloads" true
		// regardless of arrival order.
		drainOverloads(sym, ctx);
		return;
	}
	if (sym.state == SymbolState.Shaping) {
		// Type aliases allow circular references (e.g. DocData refs Doc, Doc refs DocData).
		// Standard reference implementation handles this via multi-pass type sections. We silently return —
		// callers must handle sym.symbolType still being Unknown.
		if (sym.symbolKind != SymbolKind.TypeAlias) {
			addError(ctx, `Circular dependency detected while resolving '${sym.name}'`, sym.location.line, sym.location.column);
		}
		return;
	}

	if (ctx.decoratorsPending && hasFlag(sym, SymbolFlag.Forward)) return;
	if (ctx.importSet.has(sym)) return;
	fillForwardSymbol(ctx, sym);
	sym.state = SymbolState.Shaping;
	const node = sym.declNode;
	if (node != null) {
		match (node.kind) {
			NodeKind.FunctionDecl => resolveFunction(ctx, node),
			NodeKind.InterfaceDecl => resolveInterface(ctx, node),
			NodeKind.StructDecl => resolveInterface(ctx, node),
			NodeKind.ClassDecl => resolveClass(ctx, node),
			NodeKind.ActorDecl => resolveActor(ctx, node),
			NodeKind.TypeAliasDecl => resolveTypeAlias(ctx, node),
			NodeKind.VariableDecl => resolveVariable(ctx, node),
			NodeKind.ExternDecl => resolveExtern(ctx, node),
			NodeKind.MacroDecl => resolveConverterTarget(ctx, node, sym),
			_ => {},
		};
	}
	sym.state = SymbolState.Shaped;

	// Recursively ensure all overloads are shaped (Demand-Driven Completeness)
	drainOverloads(sym, ctx);
}

// The target resolves in the declaring module's scope, with line=0 so an
// unresolvable annotation adds no diagnostic; such a converter never applies.
function resolveConverterTarget(ctx: CheckerContext, node: Node, sym: Symbol): void {
	if (!node.flags.has(NodeFlag.Converter)) return;
	const d = node.data as MacroDeclData;
	if (d.macroDeclReturnType == "") return;
	const t = resolveAnnotation(d.macroDeclReturnType, ctx, 0, 0);
	if (t == null) return;
	if (t.kind == TypeKind.Inferred || t.kind == TypeKind.Error || t.kind == TypeKind.None
		|| t.kind == TypeKind.TypeReference || t.kind == TypeKind.Unknown) return;
	ctx.converterTargetTypes.set(sym, t);
	reportDuplicateConverter(ctx, sym, node.location.line, node.location.column);
}

// Shape every overload hanging off `sym`. Split out so the already-shaped
// early-return above can run it too — see the comment there.
function drainOverloads(sym: Symbol, ctx: CheckerContext): void {
	for (const ov of sym.overloads) {
		if (ov.state == SymbolState.Hollow) ensureShaped(ov, ctx);
	}
}

// ===== Generic Type Instantiation Helpers =====

// Build a type arg key from resolved type arg strings.
//
// Resolves each annotation string to its `Type` and runs `monoTypeKey` so
// the resulting key is the SAME canonical form the Type-based mono path
// uses for `mangleMonoName`. Without this alignment, `Map<string, Handler>`
// where `Handler = (s: string) => void` produced two different mangled
// suffixes — `string_Handler` (raw user spelling, struct path) vs
// `string_function` (canonical, function path) — and the resulting
// universe of struct/function symbols disagreed.
// Routing both through `monoTypeKey` makes the struct mono path and the
// function mono path agree on names without needing any further per-type
// special-casing in `monoConcreteTypeName`.
export function buildTypeArgKey(args: string[], ctx: CheckerContext): string {
	let key = "";
	for (let i = 0; i < args.length; i += 1) {
		if (i > 0) key = key + "_";
		const trimmed = args[i].trim();
		const resolved = trimmed != "" ? resolveAnnotation(trimmed, ctx, 0, 0) : inferredType();
		const canonical = !isUnresolvedType(resolved) ? monoTypeKey(resolved) : trimmed;
		key = key + canonical;
	}
	return key;
}


// ===== Resolve Helpers =====

// Resolve an array of type annotation strings into Type[], matching names 1:1
function resolveTypeStrings(typeStrs: string[], count: number, ctx: CheckerContext, line: int32, col: int32, annotations: Node[] | null = null): Type[] {
	const types: Type[] = [];
	for (let i = 0; i < count; i += 1) {
		const bound = annotations != null && i < annotations.length ? boundAnnotationType(annotations[i]) : null;
		if (bound != null) {
			types.push(bound);
		} else if (i < typeStrs.length && typeStrs[i] != "") {
			types.push(resolveAnnotation(typeStrs[i], ctx, line, col));
		} else {
			types.push(inferredType());
		}
	}
	return types;
}

// ===== Generic Parameter Extraction =====

// Extract generic param names from fnFlags: "gen:T,U" or "async|gen:T,U" -> ["T", "U"]
// Define a generic param symbol, handling optional constraint: "T" or "T:Comparable"
function typeParamSym(ctx: CheckerContext, gp: Type): Symbol {
	const sym = makeSymbol(gp.typeName, SymbolKind.TypeAlias, gp, false);
	stampItem(ctx, sym);
	gp.sym = sym;
	return sym;
}

export function defineGenericParam(ctx: CheckerContext, paramStr: string): Type {
	const colonPos = findChar(paramStr, ":");
	if (colonPos > 0) {
		// Has constraint: "T:Comparable" -> name="T", constraint="Comparable"
		const paramName = paramStr.slice(0, colonPos);
		const constraintStr = paramStr.slice(colonPos + 1, paramStr.length);
		const gp = createGenericParam(paramName);
		// Store constraint type in typeExtra
		gp.typeExtra = resolveTypeTest(constraintStr, ctx, 0, 0);
		defineSymbol(ctx.table, typeParamSym(ctx, gp));
		return gp;
	}
	// No constraint: "T"
	const gp = createGenericParam(paramStr);
	defineSymbol(ctx.table, typeParamSym(ctx, gp));
	return gp;
}

export function defineTypeParams(ctx: CheckerContext, sym: Symbol, params: string): void {
	openScope(ctx.table, ScopeKind.Block);
	if (sym.typeParams.length > 0) {
		for (const gp of sym.typeParams) defineSymbol(ctx.table, makeSymbol(gp.typeName, SymbolKind.TypeAlias, gp, false));
		return;
	}
	const constraints: string[] = [];
	const declared: Type[] = [];
	for (const param of splitTopLevel(params, ",")) {
		const trimmed = param.trim();
		if (trimmed == "") continue;
		const colonPos = findChar(trimmed, ":");
		declared.push(defineGenericParam(ctx, colonPos > 0 ? trimmed.slice(0, colonPos) : trimmed));
		constraints.push(colonPos > 0 ? trimmed.slice(colonPos + 1, trimmed.length) : "");
	}
	for (let i = 0; i < declared.length; i += 1) {
		if (constraints[i] != "") declared[i].typeExtra = resolveTypeTest(constraints[i], ctx, 0, 0);
	}
	sym.typeParams = declared;
}

function markTemplateType(owner: Type): void {
	owner.typeFlags = owner.typeFlags.incl(TypeFlag.HasGenericParam);
}

function declaredMethodSym(ctx: CheckerContext, member: Node, written: Node): Symbol {
	const sym = member.resolvedSym != null ? member.resolvedSym : written.resolvedSym;
	if (sym == null) throw new Error(`internal: method at ${member.location.line}:${member.location.column} has no declaration symbol for its type parameters`);
	return sym;
}

// ===== B. Resolve Declarations (Pass 2) =====

// Callable-namespace attachment (Number.MAX_SAFE_INTEGER): merged statics
// live on a Function symbol whose ensureShaped resolves only the function
// signature — the constant members never pass through resolveClass. Resolve
// their annotations here so member and symbol types are real before codegen.
export function resolveAttachedStatics(ctx: CheckerContext, sym: Symbol): void {
	for (const sf of sym.staticFields) {
		if (sf.state == SymbolState.Shaped || sf.state == SymbolState.Checked) continue;
		const member = sf.declNode;
		if (member == null) continue;
		const pd = member.data as PropertyDeclData;
		const staticType = pd.propType != ""
			? resolveAnnotation(pd.propType, ctx, member.location.line, member.location.column)
			: createPrimitive(TypeKind.Float64);
		member.nodeType = staticType;
		sf.symbolType = staticType;
		sf.state = SymbolState.Shaped;
		if (pd.propInitializer != null
				&& (pd.propInitializer.nodeType == null
					|| pd.propInitializer.nodeType.kind == TypeKind.None
					|| pd.propInitializer.nodeType.kind == TypeKind.Inferred)) {
			pd.propInitializer.nodeType = staticType;
		}
	}
}

export function resolveDeclarations(ctx: CheckerContext, program: Node): void {
	const stmts = program.data as ProgramData;
	for (const stmt of stmts.programStmts) {
		const staticMember = staticExtSymOf(stmt.kind == NodeKind.ExportDecl ? (stmt.data as ExportDeclData).exportedDecl : stmt);
		if (staticMember != null) {
			ensureShaped(staticMember, ctx);
			continue;
		}
		const name = getDeclName(stmt);
		if (name != "") {
			const sym = lookupSymbol(ctx.table, name);
			if (sym != null) {
				ensureShaped(sym, ctx);
				if (sym.staticFields.length > 0) resolveAttachedStatics(ctx, sym);
			}
		} else if (stmt.kind == NodeKind.ExportDecl) {
			const d = stmt.data as ExportDeclData;
			const innerName = getDeclName(d.exportedDecl);
			if (innerName != "") {
				const sym = lookupSymbol(ctx.table, innerName);
				if (sym != null) {
					ensureShaped(sym, ctx);
					if (sym.staticFields.length > 0) resolveAttachedStatics(ctx, sym);
				}
			}
		} else if (stmt.kind == NodeKind.DecoratedDecl) {
			const dd = stmt.data as DecoratedDeclData;
			const innerName = getDeclName(dd.decoratedNode);
			if (innerName != "") {
				const sym = lookupSymbol(ctx.table, innerName);
				if (sym != null) {
					ensureShaped(sym, ctx);
					if (sym.staticFields.length > 0) resolveAttachedStatics(ctx, sym);
				}
			}
		}
	}
}

// getDeclName imported from collectPass (single canonical copy)

// findPredicateInfix — locate the ` is ` keyword in a function return
// annotation so we can split the parameter name from the predicate target
// type. Returns the index of the `i` of "is", or -1 if no top-level predicate
// exists. Only a leading `<ident> is ` pattern qualifies — we check that the
// prefix is an identifier-shaped token (no whitespace, no dots, no colons)
// so we never misread constructs like `Result< is Whatever >` (impossible but
// covered defensively).
function findPredicateInfix(text: string): int32 {
	// Accept only the canonical shape: `<ident> is <type>`.
	const idxSp = findChar(text, " ");
	if (idxSp <= 0) return -1;
	if (idxSp + 3 >= text.length) return -1;
	if (text.charAt(idxSp + 1) != "i") return -1;
	if (text.charAt(idxSp + 2) != "s") return -1;
	if (text.charAt(idxSp + 3) != " ") return -1;
	// Prefix must be a bare identifier (letters/digits/underscore).
	let i: int32 = 0;
	while (i < idxSp) {
		const c = text.charAt(i);
		const isLetter = (c >= "a" && c <= "z") || (c >= "A" && c <= "Z");
		const isDigit = c >= "0" && c <= "9";
		const isUnder = c == "_";
		if (!isLetter && !isDigit && !isUnder) return -1;
		i = i + 1;
	}
	return (idxSp + 1) as int32;
}


function overloadDeclConflict(existing: Symbol, fnType: Type, d: FunctionDeclData): boolean {
	const a = existing.symbolType;
	if (a.typeChildren.length != fnType.typeChildren.length) return false;
	for (let i = 0; i < a.typeChildren.length; i += 1) {
		if (a.typeNames[i] != fnType.typeNames[i]) return false;
		if (!sameType(a.typeChildren[i], fnType.typeChildren[i])) return false;
	}
	const ea = existing.declNode != null && existing.declNode.kind == NodeKind.FunctionDecl
		? existing.declNode.data as FunctionDeclData : null;
	if (ea == null || ea.fnReturnType == "" || d.fnReturnType == "") return false;
	return !sameType(a.typeReturn, fnType.typeReturn);
}

function checkOverloadDeclAmbiguity(ctx: CheckerContext, node: Node, sym: Symbol, fnType: Type, d: FunctionDeclData): void {
	const primary = lookupSymbol(ctx.table, d.fnName);
	if (primary == null || primary.symbolKind != SymbolKind.Function) return;
	let relevant = primary == sym;
	if (!relevant) {
		for (const ov of primary.overloads) {
			if (ov == sym) {
				relevant = true;
				break;
			}
		}
	}
	if (!relevant) return;
	const candidates: Symbol[] = [primary];
	for (const ov of primary.overloads) candidates.push(ov);
	for (const cand of candidates) {
		if (cand == sym || cand.symbolKind != SymbolKind.Function) continue;
		if (cand.modulePath != sym.modulePath) continue;
		if (isUnresolvedType(cand.symbolType) || cand.symbolType.kind != TypeKind.Function) continue;
		if (overloadDeclConflict(cand, fnType, d)) {
			const prev = cand.declNode != null ? cand.declNode.location : node.location;
			addError(ctx, `overloaded '${d.fnName}' leads to ambiguous calls — previous declaration at line ${prev.line}`, node.location.line, node.location.column);
			return;
		}
	}
}
export function resolveFunction(ctx: CheckerContext, node: Node): void {
	const d = node.data as FunctionDeclData;
	// Use resolvedSym set by collectPass (preserves overloadIdx for overloaded functions).
	let sym = node.resolvedSym;
	if (sym == null) {
		sym = lookupSymbol(ctx.table, d.fnName);
		if (sym == null) return;
		node.resolvedSym = sym;
	}

	// Set state to Shaped early to allow recursive references in signature
	sym.state = SymbolState.Shaped;

	const staticTypeName = getStaticExtTypeName(d.fnFlags);
	if (staticTypeName != "") {
		const owner = lookupSymbol(ctx.table, staticTypeName);
		if (owner == null) {
			addError(ctx, `'this typeof ${staticTypeName}' names no type in scope`, node.location.line, node.location.column);
		} else {
			sym.staticOwner = owner;
		}
	}

	// Open temp scope with GenericParam types
 // so resolveAnnotation finds "T" -> GenericParam("T")
	const genericNames = extractGenericParamDecls(d.fnFlags);

	if (genericNames.length > 0) defineTypeParams(ctx, sym, genericNames.join(","));

	const paramTypes = resolveTypeStrings(d.fnParamTypes, d.params.length, ctx, node.location.line, node.location.column, node.typeExprs);
	resolveTypeExprs(node.typeExprs, ctx);

	// Wrap out/ref param types in TypeKind.Var (reference parity: tyVar — both are T* in C)
	wrapModifierTypes(d.fnFlags, paramTypes);

	for (let pi = 0; pi < paramTypes.length && pi < d.params.length; pi += 1) {
		const pLoc = node.paramLocations != null && pi < node.paramLocations.length && node.paramLocations[pi] != null
			? node.paramLocations[pi] : node.location;
		refuseNestedView(ctx, "parameter '" + d.params[pi] + "'", paramTypes[pi], pLoc.line, pLoc.column);
	}

	const retLoc = node.typeExpr != null ? node.typeExpr.location : node.location;
	// Type predicate detection: fnReturnType is `"<paramName> is <typeText>"`
	// (see captureOptionalType in parser/util.ms). Split once, resolve the
	// target type, set the function's actual return type to `boolean`, and
	// stash a sentinel on the function Type's `typeExtra` slot — flow.ms
	// narrowType reads this to narrow callers in conditions.
	let returnType: Type;
	let predicateSentinel: Type | null = null;
	const boundReturn = boundAnnotationType(node.typeExpr);
	if (boundReturn != null) {
		returnType = boundReturn;
	} else if (d.fnReturnType != "") {
		// Assertion function: `asserts paramName is Type` — strip `asserts `
		// prefix and handle as a predicate with void return type and a distinct
		// sentinel marker ("asserts:" prefix on typeName).
		let predSource = d.fnReturnType;
		let isAssertion = false;
		if (predSource.length > 8 && predSource.slice(0, 8) == "asserts ") {
			predSource = predSource.slice(8, predSource.length);
			isAssertion = true;
		}
		const predIdx = findPredicateInfix(predSource);
		if (predIdx > 0) {
			const paramName = predSource.slice(0, predIdx - 1).trim();
			const targetText = predSource.slice(predIdx + 3, predSource.length).trim();
			const targetType = resolveAnnotation(targetText, ctx, retLoc.line, retLoc.column);
			// Predicates return boolean; assertions return void (they throw on failure).
			returnType = isAssertion ? voidType() : booleanType();
			// Sentinel: kind=None marker on Function.typeExtra. typeName holds the
			// parameter name (prefixed with "asserts:" for assertion functions).
			// typeReturn holds the narrowing target type.
			predicateSentinel = emptyType();
			predicateSentinel.kind = TypeKind.None;
			predicateSentinel.typeName = isAssertion ? `asserts:${paramName}` : paramName;
			predicateSentinel.typeReturn = targetType;
		} else if (sym.builtinKind != "") {
			returnType = resolveAnnotation(d.fnReturnType, ctx, retLoc.line, retLoc.column);
		} else {
			returnType = resolveReturnAnnotation(d.fnReturnType, ctx, retLoc.line, retLoc.column);
		}
	} else {
		returnType = inferredType();
	}
	// Record return type annotation positions for LSP
	resolveTypeExpr(node.typeExpr, ctx);
	refuseHookReceiver(ctx, node, paramTypes, d.fnReturnType != "" ? returnType : null);
	const fnType = createFunction(paramTypes, d.params, returnType);
	if (hasFlag(sym, SymbolFlag.Inline)) fnType.callConv = CallingConvention.CcInline;
	if (predicateSentinel != null) {
		fnType.typeExtra = predicateSentinel;
	}
	if (d.fnFlags.indexOf("extern", 0) >= 0 && !ctx.modulePath.endsWith(".jms")) {
		refuseUnknownAtCBoundary(ctx, d.fnName, paramTypes, returnType, node);
	}
	const proxySpot = d.fnFlags.indexOf("extern", 0) >= 0 ? proxyAtExtern(ctx, paramTypes, returnType) : "";
	if (proxySpot != "") addError(ctx, "extern '" + d.fnName + "' " + proxySpot + ": a Proxy crosses into foreign code, which reads it without its traps — " + (proxySpot == "return type" ? "return the target and wrap it here" : "pass proxyTarget(p)"), node.location.line, node.location.column);

	// Set minArity for functions with default parameters (Reference parity: count non-null defaults)
	let defCount = 0;
	if (d.fnDefaults != null) {
		for (const def of d.fnDefaults) {
			if (def != null) defCount = defCount + 1;
		}
	}
	// Rest-ness is the type-level Varargs marker that createFunction installed.
	// AST params still carry the legacy "..." prefix from the parser; strip it
	// in-place so downstream consumers (codegen, suggest, LSP) see clean names.
	const hasRestParam = stripRestParamPrefix(d.params);
	if (defCount > 0 || hasRestParam) {
		const restReduction = hasRestParam ? 1 : 0;
		setMinArity(fnType, d.params.length - defCount - restReduction);
	}

	if (genericNames.length > 0) {
		closeScope(ctx.table);
	}

	checkOverloadDeclAmbiguity(ctx, node, sym, fnType, d);
	// Overload handling: resolve in declaration order
	if (sym.overloads.length > 0 && !isUnresolvedType(sym.symbolType)) {
		// Primary already resolved — assign to first unresolved overload
		for (const overload of sym.overloads) {
			if (isUnresolvedType(overload.symbolType)) {
				overload.symbolType = fnType;
				// Ensure overload sym also points to its declNode
				overload.declNode = node;
				overload.state = SymbolState.Shaped;
				// Copy defaults to overload sym for cross-module availability
				if (d.fnDefaults != null && d.fnDefaults.length > 0) {
					overload.defaultParams = d.fnDefaults;
				}
				return;
			}
		}
	}

	sym.symbolType = fnType;
	node.nodeType = fnType;
	// Copy defaults to primary sym for cross-module availability
	if (d.fnDefaults != null && d.fnDefaults.length > 0) {
		sym.defaultParams = d.fnDefaults;
	}
}

function hookWritesItsReceiver(name: string): boolean {
	return name == "onCopy" || name == "onMove" || name == "onMoved" || name == "onTrace";
}

function holdsUnknown(t: Type | null): boolean {
	const bare = t != null ? skipModifier(t) : null;
	if (bare == null) return false;
	if (bare.kind == TypeKind.Varargs) return false;
	if (bare.kind == TypeKind.Union) return isUnknownType(unwrapRefNullUnion(bare));
	return isUnknownType(bare);
}

function refuseUnknownAtCBoundary(ctx: CheckerContext, name: string, paramTypes: Type[], returnType: Type, node: Node): void {
	let spot = "";
	for (let i = 0; i < paramTypes.length && spot == ""; i += 1) {
		if (holdsUnknown(paramTypes[i])) spot = "parameter " + (i + 1).toString();
	}
	if (spot == "" && holdsUnknown(returnType)) spot = "return type";
	if (spot == "") return;
	addError(ctx, "extern '" + name + "' " + spot + ": unknown holds managed objects, a C function sees raw addresses — declare it Ptr<void>", node.location.line, node.location.column);
}

function hookObjectName(t: Type): string {
	const k = t.kind;
	return k == TypeKind.Struct || k == TypeKind.GenericInstance || k == TypeKind.Distinct || k == TypeKind.Union ? t.typeName : "";
}

function hookReceiverShapes(hook: string): string {
	const object = " (T a struct, a class or a generic instance of one)";
	if (hook == "onDestroy") return "'this x: T', or for a struct also 'this ref x: T' and 'this x: Var<T>'" + object;
	if (hook == "onClone") return "'this x: T'" + object;
	return "'this ref x: T' or 'this x: Var<T>' for a struct, 'this x: T' for a class" + object;
}

function hookReceiverFault(hook: string, key: string, written: string, recv: Type): string {
	let obj: Type = recv;
	let byVar = false;
	if (obj.kind == TypeKind.Var && obj.typeReturn != null) {
		byVar = true;
		obj = obj.typeReturn;
	}
	let byClass = false;
	const readonlyView = isReadonlyView(obj);
	if (obj.kind == TypeKind.Ref && obj.typeReturn != null && refWrapsNominal(obj)) {
		byClass = true;
		obj = obj.typeReturn;
	}
	if (obj.kind == TypeKind.Error) return "";
	const display = byVar && !written.startsWith("Var") ? "ref " + written : written;
	if (obj.kind == TypeKind.Ptr) return "'" + display + "' addresses the type, it is not the type the hook belongs to, so the hook would never run";
	if (isMaybeType(obj) || unwrapRefNullUnion(obj) != null) return "'" + typeDisplayName(recv) + "' may be null, and a hook always receives the object itself";
	const name = hookObjectName(obj);
	if (name == "" && obj.kind != TypeKind.Alias) {
		const shown = written == key ? typeDisplayName(recv) : display;
		return "'" + shown + "' is not a type a hook can belong to, so the hook would never run";
	}
	if (name != key) return "'" + display + "' is not the type's own name, and a hook is found by the name its receiver is declared with, so the hook would never run";
	if (byVar && byClass) return "'" + display + "' points at the class reference, and a class receiver already is the reference the hook writes through: take it as 'this x: " + name + "'";
	if (hookWritesItsReceiver(hook)) {
		if (readonlyView) return "'" + display + "' is a read-only view, and the hook has to write its receiver";
		if (!byVar && !byClass) return "'" + display + "' is a value type, so 'this' would be a copy of the destination the hook has to write";
	}
	if (hook == "onClone" && byVar) return "'" + display + "' hands the hook the destination, and a clone is a new value made from a receiver taken by value";
	return "";
}

function refuseHookReceiver(ctx: CheckerContext, node: Node, paramTypes: Type[], declaredReturn: Type | null): void {
	const d = node.data as FunctionDeclData;
	if (!isLifecycleHookName(d.fnName) || paramTypes.length == 0) return;
	const key = getExtReceiverType(d.fnFlags);
	if (key == "") return;
	const recv = paramTypes[0];
	if (recv == null || isUnresolvedType(recv)) return;
	const fault = hookReceiverFault(d.fnName, key, getExtReceiverText(d.fnFlags), recv);
	if (fault != "") {
		const loc = node.paramLocations != null && node.paramLocations.length > 0 && node.paramLocations[0] != null ? node.paramLocations[0] : node.location;
		addError(ctx, "signature for '" + d.fnName + "' must take its receiver as " + hookReceiverShapes(d.fnName) + ": " + fault, loc.line, loc.column);
		return;
	}
	refuseHookOutsideItsModule(ctx, node, key);
	refuseHookSignature(ctx, d.fnName, d.nameLocation, paramTypes, declaredReturn);
}

function hookObjectOf(t: Type): Type {
	let obj = t;
	if (obj.kind == TypeKind.Var && obj.typeReturn != null) obj = obj.typeReturn;
	if (obj.kind == TypeKind.Ref && obj.typeReturn != null && refWrapsNominal(obj)) obj = obj.typeReturn;
	return withoutReadonlyView(obj);
}

function hookTakes(hook: string): string {
	if (hook == "onCopy" || hook == "onMove") return "the receiver and the source value ('y: T')";
	if (hook == "onTrace") return "the receiver and the tracer ('env: Ptr<void>')";
	return "the receiver only";
}

function hookParamFault(hook: string, paramTypes: Type[]): string {
	if (hook != "onDestroy" && hook != "onTrace" && paramTypes.length > 0) {
		const recv = paramTypes[0];
		if (recv.kind == TypeKind.Ref && recv.typeReturn != null && refWrapsNominal(recv)) {
			return "'" + typeDisplayName(recv) + "' is a class, its values are shared by reference and never copied, moved or cloned by value, so the hook would never run";
		}
	}
	const want = hook == "onCopy" || hook == "onMove" || hook == "onTrace" ? 2 : 1;
	if (paramTypes.length != want) {
		return "it takes " + hookTakes(hook) + ", " + paramTypes.length.toString() + " parameter" + (paramTypes.length == 1 ? "" : "s") + " declared";
	}
	if (hook == "onTrace") {
		const env = paramTypes[1];
		if (env.kind != TypeKind.Ptr || env.typeReturn == null || env.typeReturn.kind != TypeKind.Void) {
			return "its second parameter is '" + typeDisplayName(env) + "', the tracer is 'env: Ptr<void>'";
		}
	}
	if (hook == "onCopy" || hook == "onMove") {
		const src = paramTypes[1];
		if (!sameType(hookObjectOf(paramTypes[0]), hookObjectOf(src)) || src.kind == TypeKind.Var) {
			return "its second parameter is '" + typeDisplayName(src) + "', the source value is the receiver's own type ('y: T')";
		}
	}
	return "";
}

function hookReturnFault(hook: string, paramTypes: Type[], returnType: Type): string {
	if (hook == "onClone") {
		if (returnType.kind == TypeKind.Var || !sameType(hookObjectOf(paramTypes[0]), hookObjectOf(returnType))) {
			return "it returns '" + typeDisplayName(returnType) + "', a clone is a new value of the receiver's own type";
		}
		return "";
	}
	if (returnType.kind != TypeKind.Void) return "it returns '" + typeDisplayName(returnType) + "', a hook returns nothing";
	return "";
}

function hookTypesAreResolved(paramTypes: Type[], returnType: Type | null): boolean {
	if (paramTypes.length == 0) return false;
	for (const t of paramTypes) {
		if (t == null || isUnresolvedType(t)) return false;
	}
	return returnType == null || !isUnresolvedType(returnType);
}

function refuseHookSignature(ctx: CheckerContext, hook: string, at: SourceLocation, paramTypes: Type[], returnType: Type | null): void {
	if (!hookTypesAreResolved(paramTypes, returnType)) return;
	let fault = hookParamFault(hook, paramTypes);
	if (fault == "" && returnType != null) fault = hookReturnFault(hook, paramTypes, returnType);
	if (fault == "") return;
	addError(ctx, "signature for '" + hook + "' is wrong: " + fault, at.line, at.column);
}

export function refuseHookInferredReturn(ctx: CheckerContext, hook: string, at: SourceLocation, fnType: Type): void {
	const returnType = fnType.typeReturn;
	if (returnType == null || !hookTypesAreResolved(fnType.typeChildren, returnType)) return;
	if (hookParamFault(hook, fnType.typeChildren) != "") return;
	const fault = hookReturnFault(hook, fnType.typeChildren, returnType);
	if (fault == "") return;
	addError(ctx, "signature for '" + hook + "' is wrong: " + fault, at.line, at.column);
}

function refuseHookOutsideItsModule(ctx: CheckerContext, node: Node, typeName: string): void {
	const d = node.data as FunctionDeclData;
	const hookSym = node.resolvedSym;
	const typeSym = lookupSymbol(ctx.table, typeName);
	if (hookSym == null || typeSym == null || hookSym.modulePath == "" || typeSym.modulePath == "") return;
	if (hookSym.modulePath == typeSym.modulePath) return;
	addError(ctx, "type bound operation '" + d.fnName + "' can be defined only in the same module with its type (" + typeName + "): declare it in the module that declares '" + typeName + "'", d.nameLocation.line, d.nameLocation.column);
}

function warnOwningSelfRef(ctx: CheckerContext, fieldName: string, typeName: string, line: int32, col: int32): void {
	addWarning(ctx, "owning self-referential field '" + fieldName + "' in '" + typeName + "': destroy recurses per node — a long chain overflows the stack; for non-owning links use Cursor<" + typeName + "> with an arena/array owner", line, col);
}

function refuseViewField(ctx: CheckerContext, fieldName: string, typeName: string, fieldType: Type | null, line: int32, col: int32): void {
	const view = findViewType(fieldType);
	if (view == null) return;
	addError(ctx, "field '" + fieldName + "' of '" + typeName + "' cannot hold " + typeDisplayName(view)
		+ ": a view borrows memory its source can free while the field still holds it — store " + ownedAlternativeOf(view), line, col);
}

function interfaceCycleChain(ctx: CheckerContext, currentName: string, targetName: string, visited: string[]): string {
	for (const v of visited) {
		if (v == currentName) return "";
	}
	visited.push(currentName);
	const sym = lookupSymbol(ctx.table, currentName);
	if (sym == null || sym.declNode == null) return "";
	if (sym.declNode.kind != NodeKind.InterfaceDecl) return "";
	const pd = sym.declNode.data as InterfaceDeclData;
	for (const parentExpr of pd.interfaceExtends) {
		const bare = parentExpr.indexOf("<") >= 0
			? parentExpr.slice(0, parentExpr.indexOf("<"))
			: parentExpr;
		const parentName = bare.trim();
		if (parentName == targetName) return currentName + "' extends '" + targetName;
		const chain = interfaceCycleChain(ctx, parentName, targetName, visited);
		if (chain != "") return currentName + "' extends '" + chain;
	}
	return "";
}

export function resolveInterface(ctx: CheckerContext, node: Node): void {
	const d = node.data as InterfaceDeclData;
	const sym = lookupSymbol(ctx.table, d.interfaceName);
	if (sym == null) return;
	node.resolvedSym = sym;

	// Set state to Shaped immediately to allow circular references in fields
	sym.state = SymbolState.Shaped;
	sgRecordSym(ctx, d.nameLocation.line, d.nameLocation.column, d.nameLocation.column + d.interfaceName.length, sym, sym.symbolType, sym.symbolKind, d.interfaceName, "", true);
	checkFieldDecoratorNames(ctx, d.interfaceFieldDecorators);

	// Check for generic params (e.g., interface Box<T> — parser stores in side-channel)
	const genericStr = declGenericParams(node);
	const hasGenerics = genericStr != "";
	if (hasGenerics) defineTypeParams(ctx, sym, genericStr);

	const fieldTypes = resolveTypeStrings(d.interfaceFieldTypes, d.interfaceFields.length, ctx, node.location.line, node.location.column);
	resolveTypeExprs(node.typeExprs, ctx);

	// Phase 2: Resolve parent type expressions (extends list / `= A & B` operands)
	// inside generic scope so refs to T in parent (e.g. `extends Container<T>`)
	// resolve to local generic param. See LANG.md §4.6 + §5.3.
	// Phase 8: detect extends cycles (direct `A extends A` and indirect chains) — error.
	const parentTypes: Type[] = [];
	for (const parentExpr of d.interfaceExtends) {
		const bareParentName = parentExpr.indexOf("<") >= 0
			? parentExpr.slice(0, parentExpr.indexOf("<"))
			: parentExpr;
		if (bareParentName.trim() == d.interfaceName) {
			addError(ctx, "'" + d.interfaceName + "' cannot extend itself (cyclic inheritance)", node.location.line, node.location.column);
			parentTypes.push(errorType());
			continue;
		}
		const cycleChain = interfaceCycleChain(ctx, bareParentName.trim(), d.interfaceName, []);
		if (cycleChain != "") {
			addError(ctx, "'" + d.interfaceName + "' has a cyclic extends chain ('" + d.interfaceName + "' extends '" + cycleChain + "')", node.location.line, node.location.column);
			parentTypes.push(errorType());
			continue;
		}
		const pt = resolveAnnotation(parentExpr, ctx, node.location.line, node.location.column);
		parentTypes.push(pt);
	}
	const baseExprs: Node[] = [];
	for (let i = 0; i < parentTypes.length; i += 1) {
		const base = createNodeAt(NodeKind.Identifier, { name: d.interfaceExtends[i] } as IdentifierData, node.location);
		base.nodeType = parentTypes[i];
		baseExprs.push(base);
	}
	node.baseExprs = baseExprs;

	if (hasGenerics) {
		closeScope(ctx.table);
	}

	// Phase 2: Merge parent fields + own fields. Nim policy: error on duplicate.
	// Helpers `unwrapToStruct` + `appendStructFields` shared with type alias
	// intersection path (resolveAnnotation) — both apply the same field-merging
	// algorithm at type resolution time.
	const mergedNames: string[] = [];
	const mergedTypes: Type[] = [];
	const optionalFields: string[] = [];
	for (let xi = 0; xi < d.interfaceExtends.length; xi += 1) {
		const parentExpr = d.interfaceExtends[xi];
		const pt = parentTypes[xi];
		if (pt != null && pt.kind == TypeKind.Error) continue;
		if (pt == null || isUnresolvedType(pt)) {
			addError(ctx, "cannot resolve parent type '" + parentExpr + "'", node.location.line, node.location.column);
			continue;
		}
		const parentStruct = unwrapToStruct(pt);
		if (parentStruct.kind != TypeKind.Struct) {
			addError(ctx, "cannot extend non-object type '" + parentExpr + "'", node.location.line, node.location.column);
			continue;
		}
		appendStructFields(parentStruct, parentExpr, mergedNames, mergedTypes, ctx, node.location.line, node.location.column, optionalFields);
		if (d.interfaceExtends.length > 1 && parentStruct.typeNames != null) {
			const inherited = firstPrivateField(parentStruct.sym, parentStruct.typeNames);
			if (inherited != "") {
				addError(ctx, "struct '" + d.interfaceName + "' extends several parents, so it cannot inherit the private field '" + inherited + "' of '" + parentExpr + "' — a private field is inherited through a single parent", node.location.line, node.location.column);
			}
		}
	}
	// Append own fields with collision check against accumulated parent fields.
	for (let oi = 0; oi < d.interfaceFields.length; oi += 1) {
		const fname = d.interfaceFields[oi];
		let collided = false;
		for (const existingName of mergedNames) {
			if (existingName == fname) {
				addError(ctx, "field '" + fname + "' redefines inherited field", node.location.line, node.location.column);
				collided = true;
				break;
			}
		}
		if (!collided && oi < fieldTypes.length) {
			mergedNames.push(fname);
			mergedTypes.push(fieldTypes[oi]);
		}
	}

	// reference parity (Nim "illegal recursion in type"): hard error. The field is
	// still repaired to Ref<T> so later passes (LSP keeps checking after errors)
	// never walk an infinite-size type.
	// NOTE: only checks own fields (inherited fields can't reference child by name — they were resolved in parent's scope).
	for (let fi = 0; fi < mergedTypes.length; fi += 1) {
		const ft = mergedTypes[fi];
		if (ft != null && isStructType(ft) && declaresType(ft, sym)) {
			mergedTypes[fi] = createRef(ft);
			const fieldName = fi < mergedNames.length ? mergedNames[fi] : "?";
			addError(ctx, "self-referential value field '" + fieldName + "' in '" + d.interfaceName + "' — a struct cannot contain itself by value (infinite size); use an interface/class (reference type), Ptr<" + d.interfaceName + ">, or an index into an owning array", node.location.line, 0);
		}
	}

	// Trees (arrays-of-self) are depth-bounded — only a direct self-ref link recurses
	// destroy by chain length, so only those are flagged.
	for (let wi = 0; wi < d.interfaceFields.length; wi += 1) {
		if (wi >= fieldTypes.length) break;
		const wft = fieldTypes[wi];
		let wLine = node.location.line;
		let wCol = node.location.column;
		if (node.paramLocations != null && wi < node.paramLocations.length) {
			wLine = node.paramLocations[wi].line;
			wCol = node.paramLocations[wi].column;
		}
		if (wft != null && wft.kind == TypeKind.Ref && wft.typeReturn != null
			&& declaresType(wft.typeReturn, sym)) {
			warnOwningSelfRef(ctx, d.interfaceFields[wi], d.interfaceName, wLine, wCol);
		}
		if (node.kind != NodeKind.StructDecl) refuseViewField(ctx, d.interfaceFields[wi], d.interfaceName, wft, wLine, wCol);
	}

	// Update sym type in-place — avoid temporary Type that shares typeChildren
	// (temporary's destructor would decref elements while sym still references them)
	// For interface (Ref<Struct>), update the inner struct. For struct (plain Struct), update directly.
	const target = sym.symbolType.kind == TypeKind.Ref ? unwrapRef(sym.symbolType) : sym.symbolType;
	target.kind = TypeKind.Struct;
	target.typeName = d.interfaceName;
	target.typeNames = mergedNames;
	target.typeChildren = mergedTypes;
	target.typeFlags = (0 as BitSet<TypeFlag>).incl(TypeFlag.IsStruct);
	for (const name of d.interfaceOptionalFields) optionalFields.push(name);
	target.optionalFields = optionalFields.length > 0 ? optionalFields : null;
	if (sym.symbolType.kind == TypeKind.Struct && parentTypes.length == 1 && isValueStructDecl(parentTypes[0])) target.typeExtra = parentTypes[0];
	for (const pt of mergedTypes) { propagateToOwner(target, pt); }
	if (hasGenerics) markTemplateType(target);
	if (sym.symbolType.kind == TypeKind.Struct && declaresLifecycleHook(ctx, sym)) target.typeFlags = target.typeFlags.incl(TypeFlag.HasAsgn);
	node.nodeType = sym.symbolType;
	if (sym.symbolType.kind == TypeKind.Struct) refuseValueRecursion(ctx, node, target, d);
	// Record each OWN interface field DEF for symbol graph (inherited fields
	// already recorded by parent's resolveInterface). Parser stores per-field
	// source locations in node.paramLocations.
	for (let ri = 0; ri < d.interfaceFields.length; ri += 1) {
		const fieldSym = makeSymbol(d.interfaceFields[ri], SymbolKind.Property, fieldTypes[ri], false);
		fieldSym.state = SymbolState.Shaped;
		let fieldLine = node.location.line;
		let fieldCol = node.location.column;
		if (node.paramLocations != null && ri < node.paramLocations.length) {
			const fl = node.paramLocations[ri];
			fieldLine = fl.line;
			fieldCol = fl.column;
		}
		sgRecordSym(ctx, fieldLine, fieldCol, fieldCol + d.interfaceFields[ri].length, fieldSym, fieldTypes[ri], SymbolKind.Property, d.interfaceFields[ri], d.interfaceName, true);
	}
}

function refuseValueRecursion(ctx: CheckerContext, node: Node, self: Type, d: InterfaceDeclData): void {
	for (let fi = 0; fi < self.typeChildren.length; fi += 1) {
		const ft = self.typeChildren[fi];
		if (ft == null || ft == self || !holdsByValue(ft, self, [])) continue;
		const fieldName = fi < self.typeNames.length ? self.typeNames[fi] : "?";
		let at = node.location;
		for (let oi = 0; oi < d.interfaceFields.length; oi += 1) {
			if (d.interfaceFields[oi] == fieldName && node.paramLocations != null && oi < node.paramLocations.length && node.paramLocations[oi] != null) at = node.paramLocations[oi];
		}
		addError(ctx, "value field '" + fieldName + "' in '" + d.interfaceName + "' holds '" + d.interfaceName + "' by value through '" + typeDisplayName(ft)
			+ "' — a struct cannot contain itself (infinite size); use an interface/class (reference type), Ptr<" + d.interfaceName + ">, or an index into an owning array", at.line, at.column);
	}
}

function holdsByValue(t: Type | null, self: Type, seen: Type[]): boolean {
	if (t == null) return false;
	if (t == self) return true;
	for (const s of seen) {
		if (s == t) return false;
	}
	seen.push(t);
	if (t.kind == TypeKind.Struct && isMaybeType(t)) return holdsByValue(t.typeReturn, self, seen);
	if (t.kind == TypeKind.SizedArray || t.kind == TypeKind.Distinct || t.kind == TypeKind.GenericInstance) return holdsByValue(t.typeReturn, self, seen);
	if (t.kind != TypeKind.Struct && t.kind != TypeKind.Tuple && t.kind != TypeKind.Union) return false;
	for (const c of t.typeChildren) {
		if (holdsByValue(c, self, seen)) return true;
	}
	return false;
}

export function resolveTypeAlias(ctx: CheckerContext, node: Node): void {
	const d = node.data as TypeAliasDeclData;
	const sym = lookupSymbol(ctx.table, d.aliasName);
	if (sym == null) return;
	node.resolvedSym = sym;
	sgRecordSym(ctx, d.nameLocation.line, d.nameLocation.column, d.nameLocation.column + d.aliasName.length, sym, sym.symbolType, SymbolKind.TypeAlias, d.aliasName, "", true);
	if (hasFlag(sym, SymbolFlag.Borrow) && !d.aliasIsDistinct) {
		addError(ctx, `only a distinct type can borrow its base's fields: type ${d.aliasName} = distinct …`, d.nameLocation.line, d.nameLocation.column);
	}

	if (d.aliasType == "" && d.discriminantName == "") {
		return;
	}

	// Discriminated union: resolve structured variant data instead of aliasType text
	if (d.discriminantName != "") {
		// Tier 3: open generic param scope for `type MyData<T, E> = match (...) { ... }`
		// so variant field annotations (e.g. `value: T`) can resolve T as a GenericParam
		// instead of Unknown. Without this, instantiated generic match-types lose their
		// type parameters and field access returns Unknown.
		const hasGenericAliasDU = d.aliasGenericParams != null && d.aliasGenericParams != "";
		if (hasGenericAliasDU) defineTypeParams(ctx, sym, d.aliasGenericParams);
		const resolved = resolveDiscriminatedUnion(ctx, d, sym, node.flags.has(NodeFlag.ValueUnion));
		if (hasGenericAliasDU) {
			closeScope(ctx.table);
		}
		if (resolved != null) {
			assignType(sym.symbolType, resolved);
			node.nodeType = sym.symbolType;
			refuseAliasCycle(ctx, d, sym, resolved);
		}
		settleForwardTypes();
		return;
	}

	// Tier 3: generic type alias — define generic param symbols in a nested scope
	// so the body can reference them (e.g. type Box<T> = { value: T }).
	const hasGenericAlias = d.aliasGenericParams != null && d.aliasGenericParams != "";
	if (hasGenericAlias) defineTypeParams(ctx, sym, d.aliasGenericParams);

	const resolved = resolveAnnotation(d.aliasType, ctx, node.location.line, node.location.column);
	resolveTypeExpr(node.typeExpr, ctx);

	if (hasGenericAlias) {
		closeScope(ctx.table);
	}

	// Propagate alias name to Union types (Reference gap: string-based annotations don't carry names)
	if (resolved.kind == TypeKind.Union && resolved.typeName == "") {
		resolved.typeName = d.aliasName;
	}
	// Tier 3: for generic aliases, stamp the typeName so instantiation can reference the alias
	if (hasGenericAlias && resolved.typeName == "" && !isSysType(resolved)) {
		resolved.typeName = d.aliasName;
	}
	if (hasGenericAlias && resolved.kind == TypeKind.Ref && resolved.typeReturn != null
			&& resolved.typeReturn.kind == TypeKind.Struct && resolved.typeReturn.sym == null) {
		resolved.typeReturn.sym = sym;
	}
	// TypeScript-parity auto-detection of boolean-discriminator DUs:
	// `type R = { ok: true, ... } | { ok: false, ... }`. Stamp the discriminator
	// metadata so codegen and narrowing treat it as discriminated. String-literal
	// DUs (`{ kind: "circle" } | { kind: "square" }`) are handled by the existing
	// `findSharedStringDiscriminant` path used directly by checkExprPass — those
	// tests rely on the un-stamped Union shape, so don't auto-stamp them here.
	if (resolved.kind == TypeKind.Union
		&& (resolved.typeNames == null || resolved.typeNames.length == 0)
		&& resolved.typeExtra == null) {
		const boolDisc = findSharedBooleanDiscriminant(resolved);
		if (boolDisc != "") {
			resolved.typeNames = [boolDisc];
			resolved.typeExtra = booleanType();
		} else {
			// `{ kind: K.A, ... } | { kind: K.B, ... }` declares the same enum
			// discriminator the match-type form declares, so it gets the same
			// contract: typeExtra = enum type, typeNames = [disc, key0, key1...]
			// in typeChildren order (variantKeyMember reads keys there).
			const enumDisc = findSharedEnumDiscriminant(resolved);
			const enumType = enumDisc != "" ? enumDiscriminantTypeOf(resolved, enumDisc) : null;
			if (enumType != null) {
				const keys = collectEnumDiscriminantValues(resolved, enumDisc);
				if (keys.length == resolved.typeChildren.length) {
					const names: string[] = [enumDisc];
					for (const k of keys) names.push(k);
					resolved.typeNames = names;
					resolved.typeExtra = enumType;
				}
			}
		}
	}
	if (d.aliasIsDistinct) {
		const distType = createDistinct(resolved);
		distType.typeName = d.aliasName;
		if (resolved.kind == TypeKind.Function) distType.typeFlags = distType.typeFlags.incl(TypeFlag.BrandWiden);
		if (hasFlag(sym, SymbolFlag.Borrow)) distType.typeFlags = distType.typeFlags.incl(TypeFlag.BorrowDot);
		if (declaresLifecycleHook(ctx, sym)) distType.typeFlags = distType.typeFlags.incl(TypeFlag.HasAsgn);
		assignType(sym.symbolType, distType);
		node.nodeType = sym.symbolType;
	} else if ((hasGenericAlias ? declaredByAnotherSymbol(resolved, sym) : resolved.sym != null)
		&& (resolved.kind == TypeKind.Struct || resolved.kind == TypeKind.Enum)) {
		const wrap = emptyType();
		wrap.kind = TypeKind.Alias;
		wrap.typeName = d.aliasName;
		wrap.typeReturn = resolved;
		assignType(sym.symbolType, wrap);
		node.nodeType = sym.symbolType;
	} else {
		assignType(sym.symbolType, resolved);
		node.nodeType = sym.symbolType;
		const bodyParam = resolved.kind == TypeKind.GenericParam ? sym.typeParams.indexOf(resolved) : -1;
		if (bodyParam >= 0) sym.typeParams[bodyParam] = sym.symbolType;
	}
	refuseAliasCycle(ctx, d, sym, resolved);
	settleForwardTypes();
}

// Resolve discriminated union: type X = match (disc: EnumType) { EnumVal => { fields }, ... }
// Produces a Union type with discriminant metadata:
//   typeChildren = variant types, typeName = alias name,
//   typeExtra = discriminant enum Type,
//   typeNames = [discFieldName, variantKey0, variantKey1, ...]
function resolveDiscriminatedUnion(ctx: CheckerContext, d: TypeAliasDeclData, aliasSym: Symbol, valueUnion: boolean): Type | null {
	// Resolve discriminant type — must be an enum or boolean.
	// Boolean disc is the natural fit for two-variant unions like
	// `type Result<T,E> = match (ok: boolean) { true => {...}, false => {...} }`.
	const discType = resolveAnnotation(d.discriminantType, ctx, 0, 0);
	const isBooleanDisc = discType.kind == TypeKind.Boolean;
	if (discType.kind != TypeKind.Enum && !isBooleanDisc) {
		addError(ctx, "Discriminant type '" + d.discriminantType + "' must be an enum or boolean", 0, 0);
		return null;
	}

	if (isBooleanDisc) {
		// Boolean disc requires exactly the keys "true" and "false".
		for (const key of d.variantKeys) {
			if (key != "true" && key != "false") {
				addError(ctx, "Variant key '" + key + "' must be 'true' or 'false' for boolean discriminator", 0, 0);
			}
		}
	} else {
		// Validate each variant key is a valid enum member
		for (const key of d.variantKeys) {
			const memberName = bareAfterDelim(key, ".");
			let found = false;
			if (discType.typeNames != null) {
				for (const m of discType.typeNames) {
					if (m == memberName) {
						found = true;
					}
				}
			}
			if (!found) {
				addError(ctx, "'" + key + "' is not a member of enum '" + d.discriminantType + "'", 0, 0);
			}
		}
	}

	// Resolve each variant type. Every variant carries the disc field as a
	// literal type (`BooleanLiteral` or `EnumLiteral`), so a narrowed variant
	// used as a whole value keeps it. A `struct` union unwraps each written
	// object to a by-value arm, stamps an enum arm `<alias>.<key>` (dotted: error
	// messages display `MyData.Ok`; `variantStructCName` excludes dotted names
	// from direct C use and falls back to the synthetic `<Union>_v<N>` that
	// `genUnionType` emits) and C stores no field of one value in it
	// (`storesNothing`). A `type` union keeps each object a reference and
	// anonymous, as the written union of objects does.
	const variantTypes: Type[] = [];
	for (let vi = 0; vi < d.variantTypes.length; vi += 1) {
		let resolved = resolveAnnotation(d.variantTypes[vi], ctx, 0, 0);
		const written = d.variantTypes[vi].trim().charAt(0) == "{" && resolved != null && resolved.kind == TypeKind.Ref && resolved.typeReturn != null;
		const body = written ? resolved.typeReturn : resolved;
		if (body != null && body.kind == TypeKind.Struct && vi < d.variantKeys.length) {
			const bareKey = bareAfterDelim(d.variantKeys[vi], ".");
			const discFieldType = isBooleanDisc ? createBooleanLiteral(d.variantKeys[vi] == "true") : createEnumLiteral(discType, bareKey);
			const newNames: string[] = [d.discriminantName];
			for (const n of body.typeNames) newNames.push(n);
			const newChildren: Type[] = [discFieldType];
			for (const c of body.typeChildren) newChildren.push(c);
			body.typeNames = newNames;
			body.typeChildren = newChildren;
			if (valueUnion && !isBooleanDisc) {
				body.typeName = d.aliasName + "." + bareKey;
				body.sym = variantSymbol(aliasSym, body);
				markDuVariant(body);
			}
		}
		if (written && valueUnion) resolved = body;
		variantTypes.push(resolved);
	}

	// Build Union type with discriminant metadata.
	// typeExtra = discriminant type (Enum or Boolean primitive)
	// typeNames = [discFieldName, key0, key1, ...]
	const unionType = createUnionInOrder(variantTypes);
	unionType.typeName = d.aliasName;
	unionType.typeExtra = isBooleanDisc ? booleanType() : discType;
	const names: string[] = [d.discriminantName];
	for (const key of d.variantKeys) {
		names.push(key);
	}
	unionType.typeNames = names;
	if (valueUnion) unionType.typeFlags = unionType.typeFlags.incl(TypeFlag.ValueUnion);
	return unionType;
}

function variantSymbol(aliasSym: Symbol, body: Type): Symbol {
	const v = makeSymbol(body.typeName, SymbolKind.TypeAlias, body, false);
	v.modulePath = aliasSym.modulePath;
	v.disamb = aliasSym.disamb;
	v.location = aliasSym.location;
	v.declNode = aliasSym.declNode;
	return v;
}

function resolveVariable(ctx: CheckerContext, node: Node): void {
	const d = node.data as VariableDeclData;
	if (d.declType != "") {
		// Annotated module var: bind the type in Pass 2. Pass 3 checks bodies in
		// SOURCE ORDER, so a function body above the declaration would otherwise
		// see Unknown — silent miscompile (method lowering misses, raw `->name` C)
		// instead of the 3-pass order-independence the checker guarantees.
		// Mirrors resolveExtern below; Shaping machinery handles forward aliases.
		const sym = lookupSymbol(ctx.table, d.declName);
		if (sym != null && isUnresolvedType(sym.symbolType)) {
			sym.symbolType = resolveAnnotation(d.declType, ctx, node.location.line, node.location.column);
		}
		return;
	}
	// No annotation: for const object literals, infer struct type from field names.
	// This gives cross-module exports a meaningful type (not unknown) for LSP hover/completion.
	// Full inference happens in Pass 3; this is a lightweight early approximation.
	if (d.declKind == DeclKind.Const && d.initializer != null && d.initializer.kind == NodeKind.ObjectLiteral) {
		const sym = lookupSymbol(ctx.table, d.declName);
		if (sym != null && isUnresolvedType(sym.symbolType)) {
			const objData = d.initializer.data as ObjectLiteralData;
			const fieldNames: string[] = [];
			const fieldTypes: Type[] = [];
			for (let fi = 0; fi < objData.keys.length; fi += 1) {
				fieldNames.push(objData.keys[fi]);
				// Values are literals — resolve their types if annotated (e.g., 0x0001 as uint32)
				const valNode = objData.properties[fi];
				if (valNode != null && valNode.kind == NodeKind.TypeAssertion) {
					const ta = valNode.data as TypeAssertionData;
					const resolved = resolveAnnotation(ta.asType, ctx, node.location.line, node.location.column);
					fieldTypes.push(resolved);
				} else {
					fieldTypes.push(inferredType());
				}
			}
			sym.symbolType = createStruct("", fieldNames, fieldTypes, true);
		}
	}
}

// Resolve extern const/let/var type annotation → set symbol type.
// Reference parity: importc symbols get their type resolved during sem pass.
export function resolveExtern(ctx: CheckerContext, node: Node): void {
	const d = node.data as ExternDeclData;
	const sym = lookupSymbol(ctx.table, d.externName);
	if (sym == null) return;
	node.resolvedSym = sym;

	// Resolve type annotation if present
	if (d.externType != "") {
		const resolved = resolveAnnotation(d.externType, ctx, node.location.line, node.location.column);
		if (!isUnresolvedType(resolved)) {
			sym.symbolType = resolved;
			resolved.sym = sym;
			node.nodeType = resolved;
		}
	}
}

function resolveConstructorType(member: Node, sym: Symbol, ctx: CheckerContext): void {
	const cd = member.data as ConstructorDeclData;
	for (const p of cd.ctorParams) {
		if (p.slice(0, 4) == "out:" || p.slice(0, 4) == "ref:") addError(ctx, "a constructor parameter cannot be 'out' or 'ref': '" + p.slice(4, p.length) + "'", member.location.line, member.location.column);
	}
	const paramTypes = resolveTypeStrings(cd.ctorParamTypes, cd.ctorParams.length, ctx, member.location.line, member.location.column);
	wrapModifierTypes(liftParamModifiers(cd.ctorParams, ""), paramTypes);
	resolveTypeExprs(member.typeExprs, ctx);
	member.nodeType = createFunction(paramTypes, cd.ctorParams, voidType());
	stripRestParamPrefix(cd.ctorParams);
	mintCtorRoutine(ctx, sym, sym.name, sym.symbolType, member.nodeType.typeChildren, member.nodeType.typeNames, member, cd.ctorDefaults != null ? cd.ctorDefaults : []);
}

function declaresConstructor(body: Node[]): boolean {
	for (const member of body) {
		if (member.kind == NodeKind.ConstructorDecl) return true;
		if (member.kind == NodeKind.DecoratedDecl) {
			const inner = (member.data as DecoratedDeclData).decoratedNode;
			if (inner != null && inner.kind == NodeKind.ConstructorDecl) return true;
		}
	}
	return false;
}

function inheritConstructor(ctx: CheckerContext, node: Node, sym: Symbol, parentSym: Symbol, parentType: Type): void {
	const d = node.data as ClassDeclData;
	if (!hasFlag(parentSym, SymbolFlag.HasConstructor) || declaresConstructor(d.classBody)) return;
	const parentRoutine = ctorRoutineOf(parentSym);
	if (parentRoutine == null || parentRoutine.symbolType == null) return;
	const parentCtor = createFunction(ctorFormalTypes(parentRoutine)!, parentRoutine.symbolType.typeNames.slice(1), voidType());
	const instance = unwrapRef(parentType);
	const names = instance.kind == TypeKind.GenericInstance
		? splitTopLevel(genericParamNamesOf(symGenericParams(parentSym)), ",").map((n: string): string => n.trim())
		: [];
	const loc = node.location;
	const params: string[] = [];
	const paramTypes: Type[] = [];
	const typeTexts: string[] = [];
	const args: Node[] = [];
	const locs: SourceLocation[] = [];
	for (let i = 0; i < parentCtor.typeChildren.length; i += 1) {
		const pt = names.length > 0 ? substituteParams(parentCtor.typeChildren[i], declaredTypeParams(parentSym, names.length), instance.typeChildren) : parentCtor.typeChildren[i];
		const name = i < parentCtor.typeNames.length && parentCtor.typeNames[i] != "" ? parentCtor.typeNames[i] : "p" + i.toString();
		params.push(name);
		paramTypes.push(pt);
		typeTexts.push(typeDisplayName(pt));
		locs.push(loc);
		const ref = createNodeAt(NodeKind.Identifier, { name }, loc);
		args.push(pt.kind == TypeKind.Varargs ? createNodeAt(NodeKind.SpreadExpr, { spreadArg: ref }, loc) : ref);
	}
	const superCall = createNodeAt(NodeKind.CallExpr, { callee: createNodeAt(NodeKind.Identifier, { name: "super" }, loc), arguments: args, isDirectCall: true, resolvedOverloadIdx: -1 }, loc);
	const body = createNodeAt(NodeKind.BlockStmt, { statements: [createNodeAt(NodeKind.ExprStmt, { expr: superCall }, loc)] }, loc);
	const ctorNode = createNodeAt(NodeKind.ConstructorDecl, { ctorParams: params, ctorParamTypes: typeTexts, ctorBody: body, ctorDefaults: [] }, loc);
	ctorNode.nodeType = createFunction(paramTypes, params, voidType());
	ctorNode.paramLocations = locs;
	d.classBody.push(ctorNode);
	setFlag(sym, SymbolFlag.HasConstructor);
	setFlag(sym, SymbolFlag.InheritsConstructor);
	mintCtorRoutine(ctx, sym, sym.name, sym.symbolType, paramTypes, params, ctorNode, []);
}

// A resolved class names its parent by Symbol; one not resolved yet is declared in
// this module, so its `extends` name binds in this scope.
function declaredParentClass(ctx: CheckerContext, classSym: Symbol): Symbol | null {
	if (classSym.declNode == null || classSym.declNode.kind != NodeKind.ClassDecl) return null;
	const resolved = parentClassSymOf(classSym);
	if (resolved != null) return resolved;
	const ext = (classSym.declNode.data as ClassDeclData).classExtends;
	if (ext == "") return null;
	return lookupSymbol(ctx.table, ext.indexOf("<") >= 0 ? ext.slice(0, ext.indexOf("<")).trim() : ext.trim());
}

export function resolveClass(ctx: CheckerContext, node: Node): void {
	const d = node.data as ClassDeclData;
	const sym = lookupSymbol(ctx.table, d.className);
	if (sym == null) return;
	node.resolvedSym = sym;
	if (sym.instantiatedFrom == null) d.classDisplayName = d.className;

	// Set state to Shaped immediately to allow circular references in methods/properties
	sym.state = SymbolState.Shaped;

	// Check for generic params (e.g., class Container<T> — parser stores in side-channel)
	const genericStr = declGenericParams(node);
	const hasGenerics = genericStr != "";
	if (hasGenerics) defineTypeParams(ctx, sym, genericStr);

	// Save collectPass type to preserve decorator metadata (nativeName/builtinKind on typeName)
	const oldType = sym.symbolType;

	// Build Object type — collect members inline
	const memberNames: string[] = [];
	const memberTypes: Type[] = [];
	const ownOptional: string[] = [];
	const optionalFields: string[] = [];
	for (let mi = 0; mi < d.classBody.length; mi += 1) {
		let member = d.classBody[mi];
		// Unwrap DecoratedDecl to get the inner declaration
		if (member.kind == NodeKind.DecoratedDecl) {
			const dd = member.data as DecoratedDeclData;
			if (dd.decoratedNode == null) {
				continue;
			}
			member = dd.decoratedNode;
		}
		if (member.kind == NodeKind.MethodDecl) {
			// Reference parity: methods are NOT struct fields — resolve their types
			// and update the extension's fnType, but don't add to struct.
			const md = member.data as MethodDeclData;
			// Method-level generic params (e.g. parse<T>) — define in temp scope
			// so resolveAnnotation finds "T" → GenericParam("T"), same as resolveFunctionDecl.
			const methodGenericNames = extractGenericParamDecls(md.methodFlags);
			const hasMethodGenerics = methodGenericNames.length > 0;
			md.methodFlags = liftParamModifiers(md.methodParams, md.methodFlags);
			const receiver = hasMethodGenerics && !md.methodIsStatic && md.methodParams.length > 0 && md.methodParams[0] == "this"
				? resolveTypeStrings(md.methodParamTypes, 1, ctx, member.location.line, member.location.column)[0]
				: null;
			if (hasMethodGenerics) defineTypeParams(ctx, declaredMethodSym(ctx, member, d.classBody[mi]), methodGenericNames.join(","));
			const paramTypes = resolveTypeStrings(md.methodParamTypes, md.methodParams.length, ctx, member.location.line, member.location.column);
			if (receiver != null) paramTypes[0] = receiver;
			wrapModifierTypes(md.methodFlags, paramTypes);
			resolveTypeExprs(member.typeExprs, ctx);
			const returnType = (md.methodReturnType != "") ? resolveReturnAnnotation(md.methodReturnType, ctx, member.location.line, member.location.column) : inferredType();
			resolveTypeExpr(member.typeExpr, ctx);
			if (hasMethodGenerics) {
				closeScope(ctx.table);
			}
			if (isLifecycleHookName(md.methodName) && !md.methodIsStatic) {
				refuseHookSignature(ctx, md.methodName, md.nameLocation, paramTypes, md.methodReturnType != "" ? returnType : null);
			}
			const fnType = createFunction(paramTypes, md.methodParams, returnType);
			stripRestParamPrefix(md.methodParams);
			// Use resolvedSym set by collectClassMethod — avoids overload ambiguity with lookupSymbol
			// DecoratedDecl wraps MethodDecl — resolvedSym is on the inner node
			const methodSym = member.resolvedSym != null ? member.resolvedSym : d.classBody[mi].resolvedSym;
			if (methodSym != null && methodSym.symbolType != null && methodSym.symbolType.typeName != "") {
				fnType.typeName = methodSym.symbolType.typeName;
			}
			member.nodeType = fnType;
			// Update the method symbol's type with resolved params/return
			if (methodSym != null && methodSym.symbolType != null) {
				assignType(methodSym.symbolType, fnType);
			}
		} else if (member.kind == NodeKind.PropertyDecl) {
			const pd = member.data as PropertyDeclData;
			if (pd.propIsStatic) {
				let staticType = inferredType();
				if (pd.propType != "") {
					const savedBoundary = ctx.staticInitBoundary;
					ctx.staticInitBoundary = ctx.table.current;
					staticType = resolveAnnotation(pd.propType, ctx, member.location.line, member.location.column);
					resolveTypeExpr(member.typeExpr, ctx);
					ctx.staticInitBoundary = savedBoundary;
					refuseViewField(ctx, pd.propName, d.className, staticType, member.location.line, member.location.column);
				}
				member.nodeType = staticType;
				const sf = member.resolvedSym;
				if (sf == null || sf.symbolKind != SymbolKind.Variable || !hasFlag(sf, SymbolFlag.Static)) {
					addError(ctx, `internal: static field '${d.className}.${pd.propName}' has no declaration symbol`, member.location.line, member.location.column);
				} else {
					sf.symbolType = staticType;
					sf.state = SymbolState.Shaped;
				}
			} else {
				memberNames.push(pd.propName);
				if (member.flags.has(NodeFlag.Optional)) ownOptional.push(pd.propName);
				if (pd.propType != "") {
					const propType = resolveAnnotation(pd.propType, ctx, member.location.line, member.location.column);
					resolveTypeExpr(member.typeExpr, ctx);
					member.nodeType = propType;
					memberTypes.push(propType);
					// Same owning self-ref hazard as interface fields (resolveInterface).
					if (propType.kind == TypeKind.Ref && propType.typeReturn != null
						&& declaresType(propType.typeReturn, sym)) {
						warnOwningSelfRef(ctx, pd.propName, d.className, member.location.line, member.location.column);
					}
					refuseViewField(ctx, pd.propName, d.className, propType, member.location.line, member.location.column);
				} else {
					memberTypes.push(inferredType());
				}
			}
		} else if (member.kind == NodeKind.ConstructorDecl) {
			resolveConstructorType(member, sym, ctx);
		}
	}

	// Update inner struct in-place — avoid temporary Type that shares typeChildren
	// (temporary's destructor would decref elements while inner still references them)
	const inner = unwrapRef(sym.symbolType);
	inner.kind = TypeKind.Struct;
	inner.typeName = d.className;
	inner.typeFlags = inner.typeFlags.incl(TypeFlag.IsStruct);

	// Phase 4: Class field flatten — merge parent fields into child's typeChildren.
	// Mirrors interface/struct (Phases 1-3); for class we also keep typeExtra
	// (used by static field chain + inheritance distance) and SET
	// HasInheritedFields flag so destructorLifting suppresses parent destroy
	// genCall (avoids double-free since fields walked inline by DRC walker).
	let mergedNames = memberNames;
	let mergedTypes = memberTypes;
	let didMergeParent = false;
	if (inner.typeExtra != null && inner.typeExtra.kind == TypeKind.TypeReference) {
		const parentExpr = inner.typeExtra.typeName;
		// B6: ensure parent fully Shaped before reading its fields. lookupSymbol
		// gets the bare-name symbol; for "Bar<T>" form, resolveAnnotation handles
		// the GenericInstance path which itself ensures shapedness.
		const bareParentName = parentExpr.indexOf("<") >= 0
			? parentExpr.slice(0, parentExpr.indexOf("<"))
			: parentExpr;
		// Phase 8: detect direct self-cycle (`class A extends A`) — error.
		if (bareParentName.trim() == d.className) {
			addError(ctx, "'" + d.className + "' cannot extend itself (cyclic inheritance)", node.location.line, node.location.column);
			inner.typeNames = memberNames;
			inner.typeChildren = memberTypes;
			for (const pt of memberTypes) { propagateToOwner(inner, pt); }
			node.nodeType = sym.symbolType;
			if (hasGenerics) closeScope(ctx.table);
			return;
		}
		// Mutual / multi-step cycle (`A extends B`, `B extends A` — or longer chain).
		// We can't rely on the Shaping state for this: `resolveClass` flips the
		// symbol to `Shaped` early to support forward references inside method
		// bodies, so by the time we recurse into a parent the original class
		// already looks finished. Walk the parent chain *structurally* via the
		// `classExtends` annotation strings before triggering resolution — if
		// the chain leads back to ourselves, report and bail out the same way
		// the self-cycle branch above does. Without this the partial-resolve
		// races produce a misleading "field 'x' redefines inherited field"
		// downstream instead of a clean "cyclic inheritance" diagnostic.
		let cycleProbe: Symbol | null = lookupSymbol(ctx.table, bareParentName.trim());
		let cycleSteps: int32 = 0;
		while (cycleProbe != null && cycleSteps < 64) {
			if (cycleProbe == sym) {
				addError(ctx, "'" + d.className + "' cyclic inheritance — '" + d.className + "' indirectly extends itself via '" + bareParentName + "'", node.location.line, node.location.column);
				inner.typeNames = memberNames;
				inner.typeChildren = memberTypes;
				for (const pt of memberTypes) { propagateToOwner(inner, pt); }
				node.nodeType = sym.symbolType;
				if (hasGenerics) closeScope(ctx.table);
				return;
			}
			cycleProbe = declaredParentClass(ctx, cycleProbe);
			cycleSteps = (cycleSteps + 1) as int32;
		}
		const parentSym = lookupSymbol(ctx.table, bareParentName);
		if (parentSym != null) ensureShaped(parentSym, ctx);
		// resolveAnnotation handles both "Bar" and "Bar<T>" forms (Phase 1c).
		const parentType = resolveAnnotation(parentExpr, ctx, node.location.line, node.location.column);
		if (!isUnresolvedType(parentType)) {
			inner.typeExtra = parentType;
			propagateGenericParam(inner, parentType);
			const parentStruct = unwrapToStruct(parentType);
			// Stamp the parent as non-final (OpenClass) so canFormAcycle adopts the
			// Nim tfFinal rule (types.nim:436-438): a CBase-typed field may point at
			// a subclass that closes a back-edge, so any class that IS extended can
			// form a cycle regardless of its own declared fields.
			if (parentStruct.kind == TypeKind.Struct) {
				parentStruct.typeFlags = parentStruct.typeFlags.incl(TypeFlag.OpenClass);
			}
			// B8: only struct/class parents allowed.
			if (parentStruct.kind != TypeKind.Struct) {
				addError(ctx, "class can only extend another class — '" + parentExpr + "' is not a class type", node.location.line, node.location.column);
			} else {
				const newNames: string[] = [];
				const newTypes: Type[] = [];
				appendStructFields(parentStruct, parentExpr, newNames, newTypes, ctx, node.location.line, node.location.column, optionalFields);
				for (let oi = 0; oi < memberNames.length; oi += 1) {
					const fname = memberNames[oi];
					let collided = false;
					for (const existingName of newNames) {
						if (existingName == fname) {
							addError(ctx, "field '" + fname + "' redefines inherited field", node.location.line, node.location.column);
							collided = true;
							break;
						}
					}
					if (!collided) {
						newNames.push(fname);
						newTypes.push(memberTypes[oi]);
					}
				}
				mergedNames = newNames;
				mergedTypes = newTypes;
				didMergeParent = true;
				if (parentSym != null) inheritConstructor(ctx, node, sym, parentSym, parentType);
			}
		}
	}

	if (hasGenerics) closeScope(ctx.table);
	inner.typeNames = mergedNames;
	inner.typeChildren = mergedTypes;
	for (const name of ownOptional) optionalFields.push(name);
	inner.optionalFields = optionalFields.length > 0 ? optionalFields : null;
	if (didMergeParent) {
		inner.typeFlags = inner.typeFlags.incl(TypeFlag.HasInheritedFields);
	}
	// Propagate HasAsgn from any managed field (parent + own after merge)
	for (const pt of mergedTypes) { propagateToOwner(inner, pt); }
	if (hasGenerics) markTemplateType(inner);
	node.nodeType = sym.symbolType;
}

function refuseActorHandleName(ctx: CheckerContext, actorName: string, memberName: string, member: Node): void {
	if (memberName != "pid") return;
	addError(ctx, `actor '${actorName}' cannot declare a member named 'pid': 'pid' reads the actor's handle`, member.location.line, member.location.column);
}

export function resolveActor(ctx: CheckerContext, node: Node): void {
	const d = node.data as ActorDeclData;
	const sym = lookupSymbol(ctx.table, d.actorName);
	if (sym == null) return;
	node.resolvedSym = sym;
	sym.state = SymbolState.Shaped;

	const genericStr = declGenericParams(node);
	const hasGenerics = genericStr != "";
	if (hasGenerics) defineTypeParams(ctx, sym, genericStr);

	// Build struct type — collect instance properties and resolve methods
	const memberNames: string[] = [];
	const memberTypes: Type[] = [];
	for (let mi = 0; mi < d.actorBody.length; mi += 1) {
		let member = d.actorBody[mi];
		if (member.kind == NodeKind.DecoratedDecl) {
			const dd = member.data as DecoratedDeclData;
			if (dd.decoratedNode == null) continue;
			member = dd.decoratedNode;
		}
		if (member.kind == NodeKind.MethodDecl) {
			const md = member.data as MethodDeclData;
			if (!md.methodIsStatic) refuseActorHandleName(ctx, d.actorName, md.methodName, member);
			refuseActorParamModes(ctx, d.actorName, md, member);
			const methodGenericNames = extractGenericParamDecls(md.methodFlags);
			const hasMethodGenerics = methodGenericNames.length > 0;
			if (hasMethodGenerics) defineTypeParams(ctx, declaredMethodSym(ctx, member, d.actorBody[mi]), methodGenericNames.join(","));
			const paramTypes = resolveTypeStrings(md.methodParamTypes, md.methodParams.length, ctx, member.location.line, member.location.column);
			resolveTypeExprs(member.typeExprs, ctx);
			const returnType = (md.methodReturnType != "") ? resolveReturnAnnotation(md.methodReturnType, ctx, member.location.line, member.location.column) : inferredType();
			resolveTypeExpr(member.typeExpr, ctx);
			if (hasMethodGenerics) {
				closeScope(ctx.table);
			}
			const fnType = createFunction(paramTypes, md.methodParams, returnType);
			stripRestParamPrefix(md.methodParams);
			const methodSym = member.resolvedSym != null ? member.resolvedSym : d.actorBody[mi].resolvedSym;
			if (methodSym != null && methodSym.symbolType != null && methodSym.symbolType.typeName != "") {
				fnType.typeName = methodSym.symbolType.typeName;
			}
			member.nodeType = fnType;
			if (methodSym != null && methodSym.symbolType != null) {
				assignType(methodSym.symbolType, fnType);
			}
		} else if (member.kind == NodeKind.PropertyDecl) {
			const pd = member.data as PropertyDeclData;
			if (pd.propIsStatic) {
				let staticType = inferredType();
				if (pd.propType != "") {
					const savedBoundary = ctx.staticInitBoundary;
					ctx.staticInitBoundary = ctx.table.current;
					staticType = resolveAnnotation(pd.propType, ctx, member.location.line, member.location.column);
					resolveTypeExpr(member.typeExpr, ctx);
					ctx.staticInitBoundary = savedBoundary;
					refuseViewField(ctx, pd.propName, d.actorName, staticType, member.location.line, member.location.column);
				}
				member.nodeType = staticType;
				const sf = member.resolvedSym;
				if (sf == null || sf.symbolKind != SymbolKind.Variable || !hasFlag(sf, SymbolFlag.Static)) {
					addError(ctx, `internal: static field '${d.actorName}.${pd.propName}' has no declaration symbol`, member.location.line, member.location.column);
				} else {
					sf.symbolType = staticType;
					sf.state = SymbolState.Shaped;
				}
				continue;
			}
			refuseActorHandleName(ctx, d.actorName, pd.propName, member);
			memberNames.push(pd.propName);
			if (pd.propType != "") {
				const propType = resolveAnnotation(pd.propType, ctx, member.location.line, member.location.column);
				resolveTypeExpr(member.typeExpr, ctx);
				member.nodeType = propType;
				memberTypes.push(propType);
				refuseViewField(ctx, pd.propName, d.actorName, propType, member.location.line, member.location.column);
			} else {
				memberTypes.push(inferredType());
			}
		} else if (member.kind == NodeKind.ConstructorDecl) {
			resolveConstructorType(member, sym, ctx);
		}
	}

	if (hasGenerics) {
		closeScope(ctx.table);
	}

	// pid field: the actor's runtime identity (int64 — pointer cast to integer)
	memberNames.push("pid");
	memberTypes.push(getSysType(TypeKind.Int64));

	// Update inner struct in-place
	const inner = unwrapRef(sym.symbolType);
	inner.kind = TypeKind.Struct;
	inner.typeName = d.actorName;
	inner.typeNames = memberNames;
	inner.typeChildren = memberTypes;
	inner.typeFlags = (0 as BitSet<TypeFlag>).incl(TypeFlag.IsStruct);
	for (const pt of memberTypes) { propagateToOwner(inner, pt); }
	if (hasGenerics) markTemplateType(inner);
	node.nodeType = sym.symbolType;
}

// ===== Tests =====


function resolveWith(text: string): Type {
	const ctx = createContext();
	return resolveAnnotation(text, ctx, 0, 0);
}

function declareGeneric(ctx: CheckerContext, kind: NodeKind, name: string, params: string, fields: string[], types: string[]): Symbol {
	const zl = makeLoc(0, 0);
	let decl: Node;
	if (kind == NodeKind.ClassDecl) {
		const body: Node[] = [];
		for (let i = 0; i < fields.length; i += 1) {
			body.push(createNodeAt(NodeKind.PropertyDecl, { propName: fields[i], propType: types[i], propIsStatic: false, propIsReadonly: false, propVisibility: "", propInitializer: null as unknown as Node }, zl));
		}
		decl = createNodeAt(NodeKind.ClassDecl, { className: name, classDisplayName: name, classExtends: "", classBody: body, nameLocation: zl, classImplements: [] }, zl);
	} else {
		decl = createNodeAt(NodeKind.InterfaceDecl, { interfaceName: name, interfaceFields: fields, interfaceFieldTypes: types, interfaceExtends: [], nameLocation: zl, interfaceFieldVisibility: [] as string[], interfaceFieldDecorators: noFieldDecorators(fields.length), interfaceOptionalFields: [] as string[], nativeName: "" }, zl);
	}
	decl.typeArg = params;
	const sym = makeSymbol(name, kind == NodeKind.ClassDecl ? SymbolKind.Class : SymbolKind.Interface, createStruct(name, fields, [], true), false);
	sym.declNode = decl;
	sym.state = SymbolState.Shaped;
	defineSymbol(ctx.table, sym);
	return sym;
}

test "number" { assert resolveWith("number").kind == TypeKind.Number; }

test "string" { assert resolveWith("string").kind == TypeKind.String; }

test "boolean" { assert resolveWith("boolean").kind == TypeKind.Boolean; }

test "void" { assert resolveWith("void").kind == TypeKind.Void; }

test "null" { assert resolveWith("null").kind == TypeKind.Null; }

test "never" { assert resolveWith("never").kind == TypeKind.Never; }

test "int32" { assert resolveWith("int32").kind == TypeKind.Int32; }

test "float64" { assert resolveWith("float64").kind == TypeKind.Float64; }

test "unknown name" { assert resolveWith("Foo").kind == TypeKind.Inferred; }

test "empty" { assert resolveWith("").kind == TypeKind.Inferred; }

test "number[]" {
	const t = resolveWith("number[]");
	assert t.kind == TypeKind.Ref;
	assert t.typeReturn != null && t.typeReturn.kind == TypeKind.Array;
	assert t.typeReturn.typeReturn != null && t.typeReturn.typeReturn.kind == TypeKind.Number;
}

test "string[]" {
	const t = resolveWith("string[]");
	assert t.kind == TypeKind.Ref;
	assert t.typeReturn != null && t.typeReturn.kind == TypeKind.Array;
	assert t.typeReturn.typeReturn != null && t.typeReturn.typeReturn.kind == TypeKind.String;
}

test "Result<number, string>" {
	const t = resolveWith("Result<number, string>");
	assert isResult(t);
	const ok = getResultOkType(t);
	assert ok != null && ok.kind == TypeKind.Number;
	const err = getResultErrType(t);
	assert err != null && err.kind == TypeKind.String;
}

test "Array<boolean>" {
	const t = resolveWith("Array<boolean>");
	assert t.kind == TypeKind.Ref;
	assert t.typeReturn != null && t.typeReturn.kind == TypeKind.Array;
	assert t.typeReturn.typeReturn != null && t.typeReturn.typeReturn.kind == TypeKind.Boolean;
}

test "Vec<number> resolves to value array kind" {
	const t = resolveWith("Vec<number>");
	assert t.kind == TypeKind.Array;
	assert t.typeReturn != null && t.typeReturn.kind == TypeKind.Number;
}

test "number[4]" {
	const t = resolveWith("number[4]");
	assert t.kind == TypeKind.SizedArray;
	assert t.typeReturn != null && t.typeReturn.kind == TypeKind.Number;
	assert t.typeValue == 4;
}

test "Span<boolean>" {
	const t = resolveWith("Span<boolean>");
	assert t.kind == TypeKind.Span;
	assert t.typeReturn != null && t.typeReturn.kind == TypeKind.Boolean;
}

test "string | number" {
	const t = resolveWith("string | number");
	assert t.kind == TypeKind.Union;
	assert t.typeChildren.length == 2;
	assert t.typeChildren[0].kind == TypeKind.Number;
	assert t.typeChildren[1].kind == TypeKind.String;
	const back = resolveWith("number | string");
	assert back.typeChildren[0].kind == TypeKind.Number && back.typeChildren[1].kind == TypeKind.String;
}

test "known symbol" {
	const ctx = createContext();
	defineSymbol(ctx.table, makeSymbol("MyType", SymbolKind.Interface, createStruct("MyType", [], [], true), false));
	const t = resolveAnnotation("MyType", ctx, 0, 0);
	assert t.kind == TypeKind.Struct;
	assert t.typeName == "MyType";
}

test "function gets Function type" {
	const ctx = createContext();
	const symStub = makeSymbol("foo", SymbolKind.Function, noneType(), false);
	defineSymbol(ctx.table, symStub);
	// Simulate a FunctionDecl node
	const zl = makeLoc(0, 0);
	const fnNode = createNodeAt(NodeKind.FunctionDecl, { fnName: "foo", params: ["a", "b"], fnParamTypes: ["", ""], fnBody: createNodeAt(NodeKind.BlockStmt, { statements: [] }, zl), fnFlags: "", fnReturnType: "", fnDefaults: [], nameLocation: zl }, zl);
	symStub.declNode = fnNode;
	const node = createNodeAt(NodeKind.Program, { programStmts: [fnNode] }, zl);
	resolveDeclarations(ctx, node);
	const sym = lookupSymbol(ctx.table, "foo");
	assert sym != null;
	assert sym.symbolType.kind == TypeKind.Function;
	assert sym.symbolType.typeChildren.length == 2;
	assert sym.symbolType.typeNames[0] == "a";
	assert sym.symbolType.typeNames[1] == "b";
}

test "function with typed params" {
	const ctx = createContext();
	const symStub = makeSymbol("add", SymbolKind.Function, noneType(), false);
	defineSymbol(ctx.table, symStub);
	const zl = makeLoc(0, 0);
	const fnNode = createNodeAt(NodeKind.FunctionDecl, { fnName: "add", params: ["a", "b"], fnParamTypes: ["number", "number"], fnBody: createNodeAt(NodeKind.BlockStmt, { statements: [] }, zl), fnFlags: "", fnReturnType: "number", fnDefaults: [], nameLocation: zl }, zl);
	symStub.declNode = fnNode;
	const node = createNodeAt(NodeKind.Program, { programStmts: [fnNode] }, zl);
	resolveDeclarations(ctx, node);
	const sym = lookupSymbol(ctx.table, "add");
	assert sym != null;
	assert sym.symbolType.kind == TypeKind.Function;
	assert sym.symbolType.typeChildren[0].kind == TypeKind.Number;
	assert sym.symbolType.typeChildren[1].kind == TypeKind.Number;
	const ret1 = sym.symbolType.typeReturn;
	assert ret1 != null && ret1.kind == TypeKind.Number;
}

test "decorated function gets resolved" {
	const ctx = createContext();
	const symStub = makeSymbol("floor", SymbolKind.Function, noneType(), false);
	defineSymbol(ctx.table, symStub);
	const zl = makeLoc(0, 0);
	const fnNode = createNodeAt(NodeKind.FunctionDecl, { fnName: "floor", params: ["x"], fnParamTypes: ["number"], fnBody: createNodeAt(NodeKind.BlockStmt, { statements: [] }, zl), fnFlags: "", fnReturnType: "number", fnDefaults: [], nameLocation: zl }, zl);
	symStub.declNode = fnNode;
	const decoNode = createNodeAt(NodeKind.DecoratedDecl, { decorators: [], decoratedNode: fnNode }, zl);
	const node = createNodeAt(NodeKind.Program, { programStmts: [decoNode] }, zl);
	resolveDeclarations(ctx, node);
	const sym = lookupSymbol(ctx.table, "floor");
	assert sym != null;
	assert sym.symbolType.kind == TypeKind.Function;
	const ret = sym.symbolType.typeReturn;
	assert ret != null && ret.kind == TypeKind.Number;
}

test "Box<number> resolves to a generic instance" {
	const ctx = createContext();
	declareGeneric(ctx, NodeKind.InterfaceDecl, "Box", "T", ["value"], ["T"]);
	const t = resolveAnnotation("Box<number>", ctx, 0, 0);
	assert t.kind == TypeKind.GenericInstance;
}

test "Pair<string, number> resolves to a generic instance" {
	const ctx = createContext();
	declareGeneric(ctx, NodeKind.InterfaceDecl, "Pair", "A,B", ["first", "second"], ["A", "B"]);
	const t = resolveAnnotation("Pair<string, number>", ctx, 0, 0);
	assert t.kind == TypeKind.GenericInstance;
}

test "non-generic base falls through" {
	const ctx = createContext();
	defineSymbol(ctx.table, makeSymbol("Foo", SymbolKind.Interface, createStruct("Foo", [], [], true), false));
	const t = resolveAnnotation("Foo<number>", ctx, 0, 0);
	// Non-generic: returns base type (Foo)
	assert t.kind == TypeKind.Struct;
	assert t.typeName == "Foo";
}

test "a declaration without parameters is not generic, whatever its name" {
	const ctx = createContext();
	declareGeneric(ctx, NodeKind.ClassDecl, "Box", "", ["v"], ["int32"]);
	const t = resolveAnnotation("Box<number>", ctx, 0, 0);
	assert t.kind == TypeKind.Struct;
}

test "generic class Container<T> resolves to a generic instance" {
	const ctx = createContext();
	declareGeneric(ctx, NodeKind.ClassDecl, "Container", "T", ["item", "count"], ["T", "number"]);
	const t = resolveAnnotation("Container<string>", ctx, 0, 0);
	assert t.kind == TypeKind.GenericInstance;
}

test "constraint stored on GenericParam typeExtra" {
	// Simulate "T:number" — defineGenericParam parses colon, sets typeExtra
	const ctx = createContext();
	openScope(ctx.table, ScopeKind.Block);
	defineGenericParam(ctx, "T:number");
	const sym = lookupSymbol(ctx.table, "T");
	assert sym != null;
	assert sym.symbolType.kind == TypeKind.GenericParam;
	assert sym.symbolType.typeName == "T";
	const ext = sym.symbolType.typeExtra;
	assert ext != null && ext.kind == TypeKind.Number;
	closeScope(ctx.table);
}

test "no constraint leaves typeExtra null" {
	const ctx = createContext();
	openScope(ctx.table, ScopeKind.Block);
	defineGenericParam(ctx, "U");
	const sym = lookupSymbol(ctx.table, "U");
	assert sym != null;
	assert sym.symbolType.kind == TypeKind.GenericParam;
	assert sym.symbolType.typeName == "U";
	closeScope(ctx.table);
}

test "constrained interface Box<T extends number>" {
	const ctx = createContext();
	declareGeneric(ctx, NodeKind.InterfaceDecl, "Box", "T:number", ["value"], ["T"]);
	const t = resolveAnnotation("Box<number>", ctx, 0, 0);
	assert t.kind == TypeKind.GenericInstance;
}

test "fnDefaults on FunctionDeclData" {
	const zl = makeLoc(0, 0);
	const defNode = createNodeAt(NodeKind.NumberLiteral, { value: 42, isFloat: false, intVal: 42 as int64 }, zl);
	const fnNode = createNodeAt(NodeKind.FunctionDecl, { fnName: "defTest", params: ["a", "b"], fnParamTypes: ["number", "number"], fnBody: createNodeAt(NodeKind.BlockStmt, { statements: [] }, zl), fnFlags: "", fnReturnType: "", fnDefaults: [null as unknown as Node, defNode], nameLocation: zl }, zl);
	const d = fnNode.data as FunctionDeclData;
	assert d.fnDefaults.length == 2;
	assert d.fnDefaults[0] == null;
	assert d.fnDefaults[1] != null;
	assert d.fnDefaults[1].kind == NodeKind.NumberLiteral;
}

// ===== Nullable Pointer Resolution Tests =====

test "Ref<number> | null stays Union(Ref, Null)" {
	const t = resolveWith("Ref<number> | null");
	assert t.kind == TypeKind.Union;
	assert t.typeChildren.length == 2;
	assert t.typeChildren[0].kind == TypeKind.Ref;
	const inner0 = t.typeChildren[0].typeReturn;
	assert inner0 != null && inner0.kind == TypeKind.Number;
	assert t.typeChildren[1].kind == TypeKind.Null;
}

test "null | Ref<string> stays Union(Ref, Null)" {
	const t = resolveWith("null | Ref<string>");
	assert t.kind == TypeKind.Union;
	assert t.typeChildren.length == 2;
	assert t.typeChildren[0].kind == TypeKind.Ref;
	assert t.typeChildren[1].kind == TypeKind.Null;
	const inner1 = t.typeChildren[0].typeReturn;
	assert inner1 != null && inner1.kind == TypeKind.String;
}

test "Ptr<number> | null stays Union(Ptr, Null)" {
	const t = resolveWith("Ptr<number> | null");
	assert t.kind == TypeKind.Union;
	assert t.typeChildren.length == 2;
	assert t.typeChildren[0].kind == TypeKind.Ptr;
	const inner0 = t.typeChildren[0].typeReturn;
	assert inner0 != null && inner0.kind == TypeKind.Number;
	assert t.typeChildren[1].kind == TypeKind.Null;
}

test "null | Ptr<boolean> stays Union(Ptr, Null)" {
	const t = resolveWith("null | Ptr<boolean>");
	assert t.kind == TypeKind.Union;
	assert t.typeChildren.length == 2;
	assert t.typeChildren[0].kind == TypeKind.Ptr;
	assert t.typeChildren[1].kind == TypeKind.Null;
	const inner1 = t.typeChildren[0].typeReturn;
	assert inner1 != null && inner1.kind == TypeKind.Boolean;
}

test "string | null wraps as Maybe<string>" {
	// Per LANG.md §6: non-pointer T | null wraps in Maybe<T> with `{ value, present }`.
	// Pointers (Ref/Ptr) stay as Union (NULL is the natural sentinel).
	const t = resolveWith("string | null");
	assert t.kind == TypeKind.Struct;
	assert t.typeFlags.has(TypeFlag.IsMaybe);
}

test "number | null wraps as Maybe<number>" {
	const t = resolveWith("number | null");
	assert t.kind == TypeKind.Struct;
	assert t.typeFlags.has(TypeFlag.IsMaybe);
}

// An overload appended AFTER its primary was already shaped must still get
// shaped. One scope shared by several modules (the prelude context) hits this:
// `set` is resolved when the first module declaring it resolves, and every
// later module's `set` lands on that shaped symbol as an overload that
// resolveDeclarations — which shapes by NAME — never revisits.
//
// RED MEANS: the late overload stays Hollow, so its symbolType is not a
// Function, getExtFnType falls back to noneType and isReceiverMatch rejects
// the extension — the call site then reports "Property does not exist".
test "an overload appended after the primary is shaped still gets shaped" {
	const ctx = createContext();
	const zl = makeLoc(0, 0);

	const firstSym = makeSymbol("ovlLate", SymbolKind.Function, noneType(), false);
	const firstNode = createNodeAt(NodeKind.FunctionDecl, { fnName: "ovlLate", params: ["a"], fnParamTypes: ["number"], fnBody: createNodeAt(NodeKind.BlockStmt, { statements: [] }, zl), fnFlags: "", fnReturnType: "number", fnDefaults: [], nameLocation: zl }, zl);
	firstNode.resolvedSym = firstSym;
	firstSym.declNode = firstNode;
	defineSymbol(ctx.table, firstSym);

	// Primary resolves on its own, before the second declaration exists.
	ensureShaped(firstSym, ctx);
	assert firstSym.state == SymbolState.Shaped;

	const lateSym = makeSymbol("ovlLate", SymbolKind.Function, noneType(), false);
	const lateNode = createNodeAt(NodeKind.FunctionDecl, { fnName: "ovlLate", params: ["s"], fnParamTypes: ["string"], fnBody: createNodeAt(NodeKind.BlockStmt, { statements: [] }, zl), fnFlags: "", fnReturnType: "string", fnDefaults: [], nameLocation: zl }, zl);
	lateNode.resolvedSym = lateSym;
	lateSym.declNode = lateNode;
	defineSymbol(ctx.table, lateSym);
	assert firstSym.overloads.length == 1;
	assert lateSym.state == SymbolState.Hollow;

	// Second demand on the same NAME must drain the newcomer.
	ensureShaped(firstSym, ctx);
	assert lateSym.state == SymbolState.Shaped, "late overload was left Hollow";
	assert lateSym.symbolType.kind == TypeKind.Function, "late overload has no function type";
	assert lateSym.symbolType.typeChildren.length == 1;
	assert lateSym.symbolType.typeChildren[0].kind == TypeKind.String;
}
