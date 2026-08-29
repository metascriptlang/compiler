// Type Compatibility - table-driven assignability checking

import { Type, TypeKind, SymbolKind } from "../ast/node";
import { isNumeric, isIntegerType, integerRank, skipModifier, numberType, stringType, booleanType, voidType, nullType, inferredType, createPrimitive, createArray, createFunction, createStruct, createUnion, createEnum, createResult, createRef, createPtr, createCursor, createDistinct, createGenericParam, createSizedArray, createSpan, createEnumLiteral, getMinArity, isAwaitable, isAffineAwaitable, isAtomicRef, isAllStringLiteralUnion, isBrandDistinct, unwrapRefBase, isMaybeType, peelTransparentInstance } from "./types";


// ===== Assignability =====

// A reference array/span/ptr is assigned by a raw payload cast — no per-element
// conversion runs. So numeric elements of different C width (int32 vs number)
// would be reinterpreted, not converted → OOB/garbage. Require matching repr.
function sameElementRepr(a: Type | null, b: Type | null): boolean {
	if (a === null || b === null) return true;
	if (!isNumeric(a) || !isNumeric(b)) return true;
	if (a.kind === b.kind) return true;
	const aDouble = a.kind === TypeKind.Number || a.kind === TypeKind.Float64;
	const bDouble = b.kind === TypeKind.Number || b.kind === TypeKind.Float64;
	return aDouble && bDouble;
}

// True only when source→target would raw-cast memory whose repr differs — a
// reinterpret, not a conversion. Two classes, same argument (no per-element /
// per-field conversion runs on a raw cast):
//  - container elements: int32[] → number[] (4B stride read as 8B → OOB)
//  - structurally-assigned object fields SHARED BY NAME: a union field's C tag
//    is the member index and its payload width is the member repr, so
//    union(number|string) → union(float32|string) reinterprets both; numeric
//    fields must share C width. Fields present on only one side are ignored —
//    this must not become a general assignability gate (terminal fitNode scope).
let _reprDepth = 0;
export function isReinterpretUnsafe(source: Type | null, target: Type | null): boolean {
	if (_reprDepth > 12) return false;
	_reprDepth = _reprDepth + 1;
	const result = isReinterpretUnsafeInner(source, target);
	_reprDepth = _reprDepth - 1;
	return result;
}

function isReinterpretUnsafeInner(source: Type | null, target: Type | null): boolean {
	source = skipModifier(source);
	target = skipModifier(target);
	if (source === null || target === null) return false;
	if (source.kind === TypeKind.Ref && target.kind === TypeKind.Ref) {
		return isReinterpretUnsafe(source.typeReturn, target.typeReturn);
	}
	// Nullable-ref (`X | null`) stores/reads the pointer as X — peel to the
	// non-null member so enforcement reaches through nullable fields/slots.
	if (target.kind === TypeKind.Union && source.kind !== TypeKind.Union && source.kind !== TypeKind.Null) {
		const tn = nonNullMemberOfNullable(target);
		if (tn !== null) return isReinterpretUnsafe(source, tn);
	}
	if (source.kind === TypeKind.Union && target.kind !== TypeKind.Union) {
		const sn = nonNullMemberOfNullable(source);
		if (sn !== null) return isReinterpretUnsafe(sn, target);
	}
	if ((isPointerShapedRepr(source) && isScalarRepr(target))
		|| (isScalarRepr(source) && isPointerShapedRepr(target))) return true;
	if (source.kind === TypeKind.Array && target.kind === TypeKind.Ref
		&& target.typeReturn !== null && target.typeReturn.kind === TypeKind.Array) return true;
	if (source.kind === TypeKind.Ref && source.typeReturn !== null
		&& source.typeReturn.kind === TypeKind.Array && target.kind === TypeKind.Array) return true;
	if (source.kind !== target.kind) return false;
	if (source.kind === TypeKind.Array || source.kind === TypeKind.Span
		|| source.kind === TypeKind.Ptr || source.kind === TypeKind.SizedArray) {
		if (!sameElementRepr(source.typeReturn, target.typeReturn)) return true;
		return isReinterpretUnsafe(source.typeReturn, target.typeReturn);
	}
	// Closures are raw-copied msClosure structs and the call site casts fn to the
	// DECLARED signature — a numeric-repr mismatch in return/params calls through
	// the wrong ABI (Nim tyProc: params AND return invariant, procParamTypeRel).
	if (source.kind === TypeKind.Function) {
		if (fnSlotReprMismatch(source.typeReturn, target.typeReturn)) return true;
		const tParams = target.typeChildren;
		let fi = 0;
		for (const sp of source.typeChildren) {
			if (fi < tParams.length && fnSlotReprMismatch(sp, tParams[fi])) return true;
			fi += 1;
		}
		return false;
	}
	if (source.kind === TypeKind.Struct) {
		if (source === target) return false;
		if (source.typeName !== "" && source.typeName === target.typeName) return false;
		const sNames = source.typeNames;
		const sChildren = source.typeChildren;
		const tChildren = target.typeChildren;
		let ti = 0;
		for (const tProp of target.typeNames) {
			let si = 0;
			for (const sProp of sNames) {
				if (sProp === tProp && si < sChildren.length && ti < tChildren.length) {
					if (fieldReprMismatch(sChildren[si], tChildren[ti])) return true;
					if (isReinterpretUnsafe(sChildren[si], tChildren[ti])) return true;
				}
				si += 1;
			}
			ti += 1;
		}
		return false;
	}
	return false;
}

function isPointerShapedRepr(t: Type | null): boolean {
	if (t === null) return false;
	return t.kind === TypeKind.Ref || t.kind === TypeKind.Ptr
		|| t.kind === TypeKind.Array || t.kind === TypeKind.Span
		|| t.kind === TypeKind.SizedArray || t.kind === TypeKind.Function;
}

function isScalarRepr(t: Type | null): boolean {
	if (t === null) return false;
	if (isNumeric(t)) return true;
	return t.kind === TypeKind.Boolean || t.kind === TypeKind.BooleanLiteral
		|| t.kind === TypeKind.Enum || t.kind === TypeKind.EnumLiteral;
}

// msString-repr family: string, string literals, and pure string-literal unions
// (codegen collapses the latter to msString — genUnionType allStrLit arm).
function isStringRepr(t: Type): boolean {
	return t.kind === TypeKind.String || t.kind === TypeKind.StringLiteral || isAllStringLiteralUnion(t);
}

// The non-null member of a 2-member `X | null` union, or null if not that shape.
export function nonNullMemberOfNullable(t: Type | null): Type | null {
	if (t === null || t.kind !== TypeKind.Union) return null;
	if (t.typeChildren.length !== 2) return null;
	const a = t.typeChildren[0];
	const b = t.typeChildren[1];
	if (a === null || b === null) return null;
	if (b.kind === TypeKind.Null && a.kind !== TypeKind.Null) return a;
	if (a.kind === TypeKind.Null && b.kind !== TypeKind.Null) return b;
	return null;
}

// A union slot's repr: tag = member index, payload = member C type. Members must
// pair up kind-for-kind (literal kinds collapse to their runtime kind; number ≡
// float64) or the blit re-tags into a different layout.
function unionSlotReprMismatch(a: Type | null, b: Type | null): boolean {
	a = skipModifier(a);
	b = skipModifier(b);
	if (a === null || b === null) return false;
	if (isStringRepr(a) && isStringRepr(b)) return false;
	if (isNumeric(a) && isNumeric(b)) return !sameElementRepr(a, b);
	const ak = a.kind === TypeKind.StringLiteral ? TypeKind.String
		: (a.kind === TypeKind.BooleanLiteral ? TypeKind.Boolean : a.kind);
	const bk = b.kind === TypeKind.StringLiteral ? TypeKind.String
		: (b.kind === TypeKind.BooleanLiteral ? TypeKind.Boolean : b.kind);
	if (ak !== bk) return true;
	if (a.kind === TypeKind.Union) {
		if (a.typeChildren.length !== b.typeChildren.length) return true;
		let i = 0;
		while (i < a.typeChildren.length) {
			if (unionSlotReprMismatch(a.typeChildren[i], b.typeChildren[i])) return true;
			i += 1;
		}
		return false;
	}
	if (a.kind === TypeKind.Struct) return isReinterpretUnsafe(a, b);
	return false;
}

// Field-level repr gate for structurally-compatible objects. Lenient outside the
// union/numeric classes — everything else is either caught by the recursive
// isReinterpretUnsafe walk or is an intentional divergence (Ref→Ptr cursor).
function fieldReprMismatch(a: Type | null, b: Type | null): boolean {
	a = skipModifier(a);
	b = skipModifier(b);
	if (a === null || b === null) return false;
	if (isStringRepr(a) && isStringRepr(b)) return false;
	if (a.kind === TypeKind.Union && b.kind === TypeKind.Union) {
		if (a.typeChildren.length !== b.typeChildren.length) return true;
		let i = 0;
		while (i < a.typeChildren.length) {
			if (unionSlotReprMismatch(a.typeChildren[i], b.typeChildren[i])) return true;
			i += 1;
		}
		return false;
	}
	if (a.kind === TypeKind.Union || b.kind === TypeKind.Union) return true;
	if (isNumeric(a) && isNumeric(b)) return !sameElementRepr(a, b);
	return false;
}

let _assignDepth = 0;
export function isAssignable(source: Type | null, target: Type | null): boolean {
	if (_assignDepth > 20) return true;
	_assignDepth = _assignDepth + 1;
	const result = isAssignableInner(source, target);
	_assignDepth = _assignDepth - 1;
	return result;
}

function isAssignableInner(source: Type | null, target: Type | null): boolean {
	// allowsNil (sigmatch.nim:730): a cursor link is nilable by design — null is
	// the end-of-chain state. Checked BEFORE skipModifier because it peels Cursor.
	// Ref/Ptr stay TS-strict (`T | null` opt-in; see the Null-source arm below).
	if (source !== null && target !== null
		&& source.kind === TypeKind.Null && target.kind === TypeKind.Cursor) {
		return true;
	}
	// Reference parity: sink and lent modifiers are transparent ownership modifiers — unwrap before comparing
	// Standard reference implementation skips these modifiers during type relationship checks.
	source = skipModifier(source);
	target = skipModifier(target);

	// Null guard: null operands flow through unwrapped types and indicate
	// "no information" — conservatively report compatible to avoid blocking checks
	// that legitimately have no type yet (e.g. unresolved generics).
	if (source === null || target === null) return true;

	// Reference parity: tyVarargs is transparent — peel to inner array type
	// before comparing. Callers may legitimately pass either the wrapped or
	// unwrapped form depending on whether they walked through Function.typeChildren.
	if (source.kind === TypeKind.Varargs && source.typeChildren.length > 0) {
		source = source.typeChildren[0];
	}
	if (target.kind === TypeKind.Varargs && target.typeChildren.length > 0) {
		target = target.typeChildren[0];
	}

	source = peelTransparentInstance(source);
	target = peelTransparentInstance(target);

	// Never is the bottom type — assignable TO everything. After exhaustive
	// narrowing (all union variants handled), the residual type is never.
	// `return x` where `x: never` must be valid regardless of the return type.
	if (source.kind === TypeKind.Never) return true;

	// Same kind is always compatible
	if (source.kind === target.kind) {
		return match (source.kind) {
			TypeKind.SizedArray => source.typeFlags === target.typeFlags && isAssignable(source.typeReturn, target.typeReturn),
			TypeKind.Array | TypeKind.Span | TypeKind.Ptr => sameElementRepr(source.typeReturn, target.typeReturn) && isAssignable(source.typeReturn, target.typeReturn),
			TypeKind.Ref => {
				// Arc<T> and plain Ref<T> share kind=Ref but must not interconvert:
				// mixing atomic + non-atomic rc ops on one object is UB.
				if (isAtomicRef(source) !== isAtomicRef(target)) {
					return false;
				}
				// Nominal shortcut: Ref types with same-named inner struct are assignable
				// (handles cross-module interface identity where Type objects differ but names match)
				if (source.typeReturn !== null && target.typeReturn !== null
					&& source.typeReturn.typeName !== "" && source.typeReturn.typeName === target.typeReturn.typeName) {
					return true;
				}
				return isAssignable(source.typeReturn, target.typeReturn);
			},
			TypeKind.Function => isFunctionAssignable(source, target),
			TypeKind.Struct => isObjectAssignable(source, target),
			TypeKind.Enum | TypeKind.Distinct => source.typeName === target.typeName,
			TypeKind.EnumLiteral => source.typeName === target.typeName
				&& source.typeNames.length > 0 && target.typeNames.length > 0
				&& source.typeNames[0] === target.typeNames[0],
			TypeKind.GenericInstance => {
				// Structural compatibility: compare type args pairwise
				const limit = source.typeChildren.length < target.typeChildren.length ? source.typeChildren.length : target.typeChildren.length;
				for (let gi = 0; gi < limit; gi += 1) {
					if (!isAssignable(source.typeChildren[gi], target.typeChildren[gi])) return false;
				}
				// PARALOCK: an affine `Promise<T>` (spawn-origin, AwaitableAffine bit set)
				// upcasts to a plain `Promise<T>` with compatible inner — this is the
				// opt-out path that strips affinity. Element type compatibility is
				// already verified by the loop above.
				if (isAffineAwaitable(source) && isAwaitable(target) && !isAffineAwaitable(target)) return true;
				return source.typeName === target.typeName;
			},
			_ => true,
		};
	}

	// Generic-alias instance carries its resolved body in typeReturn
	// (instantiateGenericBody). When the resolved body is a leaf (not a
	// Struct/Union-backed generic like Map/Result), compare against it so
	// `U<Box<string>>` (resolves to string) accepts a string value.
	if (target.kind === TypeKind.GenericInstance && target.typeReturn !== null
		&& target.typeReturn.kind !== TypeKind.Struct && target.typeReturn.kind !== TypeKind.Union) {
		return isAssignable(source, target.typeReturn);
	}
	if (source.kind === TypeKind.GenericInstance && source.typeReturn !== null
		&& source.typeReturn.kind !== TypeKind.Struct && source.typeReturn.kind !== TypeKind.Union) {
		return isAssignable(source.typeReturn, target);
	}

	// Brand widens implicitly to its base (CubeId → string); base → brand needs `as`.
	if (isBrandDistinct(source) && source.typeReturn !== null && target.kind !== TypeKind.Distinct) {
		return isAssignable(source.typeReturn, target);
	}

	// Implicit coercion to Span: T[] -> Span<T> or T[N] -> Span<T> or string -> Span<char>
	if (target.kind === TypeKind.Span) {
		if (source.kind === TypeKind.Array || source.kind === TypeKind.SizedArray) {
			return isAssignable(source.typeReturn, target.typeReturn);
		}
		if (source.kind === TypeKind.String && target.typeReturn !== null && target.typeReturn.kind === TypeKind.Char) {
			return true;
		}
	}

	// Var (out param) unwrap: T -> Var<T> (caller passes T, callee gets T*)
	if (target.kind === TypeKind.Var && target.typeReturn !== null) {
		return isAssignable(source, target.typeReturn);
	}

	// Implicit borrow promotion: T -> Borrow<T> (zero-copy const pointer)
	if (target.kind === TypeKind.Borrow && target.typeReturn !== null) {
		return isAssignable(source, target.typeReturn);
	}

	// Inference sentinels (Inferred = open signature, None = typeless node) and
	// user unknown stay lenient — shape rules are enforced at fitNode.
	if (source.kind === TypeKind.Unknown || target.kind === TypeKind.Unknown
		|| source.kind === TypeKind.None || target.kind === TypeKind.None
		|| source.kind === TypeKind.Inferred || target.kind === TypeKind.Inferred) {
		return true;
	}

	// GenericParam on either side: unresolved generic, allow
	if (source.kind === TypeKind.GenericParam || target.kind === TypeKind.GenericParam) {
		return true;
	}

	// Error type is compatible with everything (suppress cascading errors)
	if (source.kind === TypeKind.Error || target.kind === TypeKind.Error) {
		return true;
	}

	// TypeReference: unresolved forward/cross-module type — compare by canonical name.


	// Target is union: source must be assignable to at least one member.
	// MUST run before:
	//  - Ref→T auto-deref, so `Ref<X>` matches `Union(Ref<X>, Null)` directly
	//    instead of being deref'd to `X` (which wouldn't match Ref<X>).
	//  - Null-source allowance, so `null` matches `Union(T, Null)` via the
	//    Null member instead of falling into the legacy bare-target rule.
	if (target.kind === TypeKind.Union) {
		for (const member of target.typeChildren) {
			if (isAssignable(source, member)) return true;
		}
		return false;
	}

	// null assignable to legacy nullable kinds (value-struct/array/function/span).
	// TS-strict shift: Ref/Ptr are NO LONGER auto-nullable — callers must use
	// `T | null` (handled by the Union-target check above) to opt into nullability.
	// Cursor<T> is the deliberate exception (allowsNil arm at function entry).
	// Void target lets callers write `Result.ok(null)` for Result<void, E> (§7.5).
	if (source.kind === TypeKind.Null) {
		return match (target.kind) {
			TypeKind.Struct | TypeKind.Array | TypeKind.SizedArray | TypeKind.Span | TypeKind.Function | TypeKind.Void => true,
			_ => false,
		};
	}

	// Numeric widening: any numeric type assignable to Number
	if (isNumeric(source) && target.kind === TypeKind.Number) {
		return true;
	}

	// Integer → float64 widening (lossless for int32 range)
	if (isIntegerType(source) && target.kind === TypeKind.Float64) {
		return true;
	}

	// Ref<T> ↔ Ptr<T>: both are pointer types, interchangeable when inner types match.
	// Must check BEFORE Ref→T auto-deref to prevent Ref being unwrapped then compared against Ptr.
	// Arc<T> is excluded — it is not pointer-interchangeable (atomic rc must stay typed).
	// Intentional divergence from Nim's strict ref/ptr split — MS Ptr<T> is the cursor
	// pattern (NIM-REF.md row 63).
	if ((source.kind === TypeKind.Ref && target.kind === TypeKind.Ptr)
		|| (source.kind === TypeKind.Ptr && target.kind === TypeKind.Ref)) {
		if (!isAtomicRef(source) && !isAtomicRef(target)
			&& source.typeReturn !== null && target.typeReturn !== null) {
			return isAssignable(source.typeReturn, target.typeReturn);
		}
	}
	// Ref<T> → T auto-deref: self-referential fields are promoted to Ref<T>,
	// but passing them to functions expecting T should work transparently.
	// Arc<T> does NOT auto-unwrap — sharing the pointee unguarded defeats the atomic rc.
	if (source.kind === TypeKind.Ref && !isAtomicRef(source) && source.typeReturn !== null) {
		if (source.typeReturn.kind === TypeKind.Array && target.kind === TypeKind.Array) return false;
		return isAssignable(source.typeReturn, target);
	}

	// String → CString implicit coercion (zero-copy pointer extraction)
	if (source.kind === TypeKind.String && target.kind === TypeKind.CString) {
		return true;
	}
	if (source.kind === TypeKind.CString && target.kind === TypeKind.String) {
		return true;
	}

	// StringLiteral → String (subtype: "north" assignable to string)
	if (source.kind === TypeKind.StringLiteral && target.kind === TypeKind.String) {
		return true;
	}

	// StringLiteral → StringLiteral (same value only)
	if (source.kind === TypeKind.StringLiteral && target.kind === TypeKind.StringLiteral) {
		return source.typeName === target.typeName;
	}

	// StringLiteral → CString (string literal can be passed as cstring)
	if (source.kind === TypeKind.StringLiteral && target.kind === TypeKind.CString) {
		return true;
	}

	// BooleanLiteral → Boolean (subtype: `true` assignable to boolean).
	// BooleanLiteral → BooleanLiteral matches only on identical value.
	// Boolean → BooleanLiteral falls through to the default `false` (general
	// boolean cannot satisfy a specific true/false constraint).
	if (source.kind === TypeKind.BooleanLiteral && target.kind === TypeKind.Boolean) {
		return true;
	}
	if (source.kind === TypeKind.BooleanLiteral && target.kind === TypeKind.BooleanLiteral) {
		return source.typeName === target.typeName;
	}

	// EnumLiteral → Enum (subtype: NodeKind.BinaryExpr assignable to NodeKind)
	if (source.kind === TypeKind.EnumLiteral && target.kind === TypeKind.Enum) {
		return source.typeName === target.typeName;
	}
	// Integer → Enum (enums are int32 at runtime; allows { kind: 0 } for enum-typed fields)
	if (isIntegerType(source) && target.kind === TypeKind.Enum) {
		return true;
	}
	// Enum → EnumLiteral is NOT allowed (would lose specificity) — fall through to false
	// EnumLiteral → Number/Int32 (enums are ints at runtime)
	if (source.kind === TypeKind.EnumLiteral && (target.kind === TypeKind.Int32 || target.kind === TypeKind.Number)) {
		return true;
	}

	// Source is union: all members must be assignable to target.
	// NB: `T | null → T` is rejected here (Null not assignable to non-null T) —
	// intentional TS-style divergence (NIM-REF.md §"Nullable-ref struct field
	// hooks"), swallowed by the fitNode isReinterpretUnsafe scope (row 72).
	if (source.kind === TypeKind.Union) {
		for (const member of source.typeChildren) {
			if (!isAssignable(member, target)) return false;
		}
		return true;
	}

	// (Target-is-union check moved earlier — see above the Ref auto-deref branch.)

	return false;
}

// ===== Standard Conversion Check (standard reference implementation parity) =====
// Returns true when source needs an explicit cast to target in C codegen.
// Used by checker to insert HiddenStdConv nodes at call argument positions.
export function needsStdConv(source: Type, target: Type): boolean {
	if (source === null || target === null) return false;
	// Var (out param): unwrap to inner type for conversion check
	if (target.kind === TypeKind.Var && target.typeReturn !== null) {
		return needsStdConv(source, target.typeReturn);
	}
	if (source.kind === target.kind) return false;
	// Numeric widening/narrowing: int32→number, float32→number, etc.
	if (isNumeric(source) && isNumeric(target)) return true;
	// Variant struct → discriminated union: different C layouts require
	// proper construction (tag + variant slot), not a raw cast.
	if (target.kind === TypeKind.Union && target.typeChildren !== null && source.kind === TypeKind.Struct) {
		return true;
	}
	// Array/SizedArray/String to Span coercion requires struct initializer
	if (target.kind === TypeKind.Span) {
		if (source.kind === TypeKind.Array || source.kind === TypeKind.SizedArray) return true;
		if ((source.kind === TypeKind.String || source.kind === TypeKind.StringLiteral) && target.typeReturn !== null && target.typeReturn.kind === TypeKind.Char) return true;
	}
	// String/StringLiteral → CString requires msStringToCString extraction
	if ((source.kind === TypeKind.String || source.kind === TypeKind.StringLiteral) && target.kind === TypeKind.CString) return true;
	if (source.kind === TypeKind.CString && target.kind === TypeKind.String) return true;
	// Borrow promotion: T → Borrow<T> (take address)
	if (target.kind === TypeKind.Borrow && target.typeReturn !== null) {
		if (source.kind !== TypeKind.Borrow) return true;
	}
	return false;
}


// Repr comparison for ONE slot (param or return) of a function signature.
// Peels `X | null` to X first — a nullable ref is pointer-repr like X itself
// (the TS-nullable DIVERGE-INTENTIONAL model), so RaiserContext vs
// RaiserContext|null is NOT a mismatch; int32 vs number IS.
function fnSlotReprMismatch(a: Type | null, b: Type | null): boolean {
	a = skipModifier(a);
	b = skipModifier(b);
	if (a === null || b === null) return false;
	if (b.kind === TypeKind.Union && a.kind !== TypeKind.Union && a.kind !== TypeKind.Null) {
		const bn = nonNullMemberOfNullable(b);
		if (bn !== null) return fnSlotReprMismatch(a, bn);
	}
	if (a.kind === TypeKind.Union && b.kind !== TypeKind.Union && b.kind !== TypeKind.Null) {
		const an = nonNullMemberOfNullable(a);
		if (an !== null) return fnSlotReprMismatch(an, b);
	}
	if (fieldReprMismatch(a, b)) return true;
	return isReinterpretUnsafe(a, b);
}

// Function assignability: contravariant params, covariant return
function isFunctionAssignable(source: Type | null, target: Type | null): boolean {
	if (source === null || target === null) return false;
	if (source.typeChildren.length !== target.typeChildren.length) return false;
	// Check params (contravariant: target params assignable to source params)
	let i = 0;
	for (const sourceParam of source.typeChildren) {
		if (!isAssignable(target.typeChildren[i], sourceParam)) return false;
		i += 1;
	}
	// Repr invariance (Nim tyProc: params AND return invariant via
	// procParamTypeRel — conversions never apply inside proc types; the
	// closure is raw-copied and the call site casts fn to the DECLARED
	// signature, so a numeric-width change calls through the wrong ABI).
	// Mirrors the sameElementRepr gate on Array/Span/Ptr elements above.
	let ri = 0;
	for (const sp of source.typeChildren) {
		if (fnSlotReprMismatch(sp, target.typeChildren[ri])) return false;
		ri += 1;
	}
	if (fnSlotReprMismatch(source.typeReturn, target.typeReturn)) return false;
	// Check return (covariant)
	if (source.typeReturn !== null && target.typeReturn !== null) {
		return isAssignable(source.typeReturn, target.typeReturn);
	}
	return true;
}

// A literal bound without an annotation freezes as `__anonN__...` (anonStructName).
function isAnonLiteralName(name: string): boolean {
	return name.length > 6 && name.slice(0, 6) === "__anon";
}

// Object assignability: nominal first, then structural (source has all target properties)
function isObjectAssignable(source: Type | null, target: Type | null): boolean {
	// Identity: same object → trivially assignable
	if (source === target) return true;
	if (source === null || target === null) return false;
	// Nominal: same typeName means same type (handles self-referencing types like Type, Scope)
	if (source.typeName !== "" && source.typeName === target.typeName) return true;
	// Cross-module nominal: types linked via sym identity (both point to same Symbol)
	if (source.sym !== null && source.sym === target.sym) return true;
	// Exact-field anon→named pairs are assignable; fitNode materializes the
	// member-wise re-construction. Every other anon→named pair stays rejected:
	// no lowering exists, so C emits two distinct types (clang error) while js
	// runs the cast silently. Annotating at the literal is the supported path.
	if (isAnonStructAdoption(source, target)) return true;
	if (isAnonLiteralName(source.typeName) && target.typeName !== "" && !isAnonLiteralName(target.typeName)) return false;
	// Pin source/target fields to locals — the binder's flow narrowing on the
	// `source: Type | null` parameter doesn't always propagate into nested
	// for-of bodies (each loop iteration walks the narrowing chain anew).
	const sNames = source.typeNames;
	const sChildren = source.typeChildren;
	const tNames = target.typeNames;
	const tChildren = target.typeChildren;
	// Structural assign raw-casts the object, so the target's fields must land
	// on the SAME offsets in the source: same name at the same index, left to
	// right, target's list a prefix of the source's. Matching by name alone
	// would let `A{x,y}` pass as `B{y}` and read A's x. The reference permits
	// object upcasts for this reason and no other — the declared parent embeds
	// as the layout prefix (inheritanceDiff walks that chain; there is no
	// structural path for records). `extends` and `A & B` both flatten
	// parent-first (appendStructFields), so they satisfy this by construction.
	if (tNames.length > sNames.length) return false;
	let idx = 0;
	for (const targetProp of tNames) {
		if (sNames[idx] !== targetProp) return false;
		if (idx < sChildren.length && idx < tChildren.length) {
			if (!isAssignable(sChildren[idx], tChildren[idx])) return false;
			// Shared fields whose union/numeric repr differs would reinterpret
			// (mirror of the sameElementRepr gate on Array/Span/Ptr elements above).
			if (fieldReprMismatch(sChildren[idx], tChildren[idx])) return false;
		}
		idx += 1;
	}
	return true;
}

// A value of one object type reaching a slot of a DIFFERENT object type. This
// is the only class the assignment positions gate on: they historically fit
// their operand without consulting assignability at all, and widening them to
// the full relation would reject 223 deliberate sites in this tree (numeric
// narrowing that fitNode converts, `Ref`→`Ptr` non-owning links, the nullable
// idiom) against 0 sites of this class. Everything here is a raw pointer cast
// whose offsets do not line up — a silent wrong-field read, or a reinterpreted
// pointer when the reprs differ.
export function isObjectShapeMismatch(source: Type | null, target: Type | null): boolean {
	const s0 = skipModifier(source);
	const t0 = skipModifier(target);
	if (s0 === null || t0 === null) return false;
	const s = unwrapRefBase(s0);
	const t = unwrapRefBase(t0);
	if (s.kind !== TypeKind.Struct || t.kind !== TypeKind.Struct) return false;
	if (s === t) return false;
	if (s.typeName === "" || t.typeName === "") return false;
	if (s.typeName === t.typeName) return false;
	if (s.sym !== null && s.sym === t.sym) return false;
	return !isAssignable(source, target);
}

// Error-path only: when a rejected object pair HAS every required field but in
// the wrong slots, "got A, expected B" reads like a compiler bug. Name the field
// that moved. Empty string when the plain message already explains the rejection.
export function explainStructuralPrefix(source: Type | null, target: Type | null): string {
	const s0 = skipModifier(source);
	const t0 = skipModifier(target);
	if (s0 === null || t0 === null) return "";
	const s = unwrapRefBase(s0);
	const t = unwrapRefBase(t0);
	if (s.kind !== TypeKind.Struct || t.kind !== TypeKind.Struct) return "";
	if (s.typeName === "" || t.typeName === "") return "";
	if (s.typeName === t.typeName) return "";
	if (isAnonLiteralName(s.typeName) && !isAnonLiteralName(t.typeName)) {
		return " (the literal froze as an anonymous type before reaching '" + t.typeName
			+ "'; annotate at the literal: `const x: " + t.typeName + " = { ... }`)";
	}
	let ti = 0;
	for (const tProp of t.typeNames) {
		let foundAt = 0 - 1;
		let si = 0;
		for (const sProp of s.typeNames) {
			if (sProp === tProp) foundAt = si;
			si += 1;
		}
		if (foundAt < 0) return "";
		if (foundAt !== ti) {
			return " ('" + tProp + "' is field " + String(ti) + " of " + t.typeName
				+ " but field " + String(foundAt) + " of " + s.typeName
				+ "; a structural match is a pointer cast, so " + t.typeName
				+ "'s fields must be a leading prefix of " + s.typeName
				+ " — declare " + s.typeName + " as `extends " + t.typeName + "`"
				+ " or reorder its fields)";
		}
		ti += 1;
	}
	return "";
}

// Duck-typed adoption boundary: a frozen anonymous-literal value may be
// re-constructed member-wise into a NAMED value struct when the field lists
// match EXACTLY (same names, order, and per-field type identity). Interface
// targets keep reference/aliasing semantics and stay rejected; extra-field
// (prefix) matches stay rejected — the C copy would drop fields the js
// identity keeps, a built-in parity split.
export function isAnonStructAdoption(source: Type | null, target: Type | null): boolean {
	if (source === null || target === null) return false;
	if (source.kind !== TypeKind.Struct || target.kind !== TypeKind.Struct) return false;
	if (!isAnonLiteralName(source.typeName)) return false;
	if (target.typeName === "" || isAnonLiteralName(target.typeName)) return false;
	if (target.sym !== null && target.sym.symbolKind === SymbolKind.Interface) return false;
	if (isMaybeType(target)) return false;
	const sNames = source.typeNames;
	const tNames = target.typeNames;
	if (sNames.length !== tNames.length) return false;
	for (let i = 0; i < tNames.length; i += 1) {
		if (sNames[i] !== tNames[i]) return false;
		if (i >= source.typeChildren.length || i >= target.typeChildren.length) return false;
		if (!sameType(source.typeChildren[i], target.typeChildren[i])) return false;
	}
	return true;
}

// ===== Overload Resolution =====

export enum TypeRelation {
	None,           // 0 - no match
	Convertible,    // 1 - requires conversion
	IntConv,        // 2 - int/float conversion
	Subtype,        // 3 - inheritance/structural
	Generic,        // 4 - generic param match / inference pending
	FromLiteral,    // 5 - from literal (proven safe)
	Exact,          // 6 - exact match
}

// ===== Type identity =====
//
// Identity answers "are these the SAME type", which is a different question
// from `typeRelation`/`isAssignable` ("may a value of one be used where the
// other is expected"). Control-flow merges need identity: two narrowed
// branches may only collapse into one when their types are the same, or a
// union variant is silently dropped.
//
// Structure mirrors the reference `sameType`/`sameTypeAux`: dispatch on kind,
// nominal types compare by name, anonymous aggregates compare field names +
// field types + repr flags, value-carrying types compare values, transparent
// wrappers compare their inner type. Self-referential types (Node, Scope)
// make the walk cyclic, so the reference bounds it with a recursion check and
// assumes "same" once the budget is spent — the conservative answer for a
// merge is to treat the pair as identical rather than to recurse forever.

let _sameTypeDepth = 0;

export function sameType(a: Type | null, b: Type | null): boolean {
	if (a === b) return true;
	if (a === null || b === null) return false;
	if (_sameTypeDepth > 12) return true;
	_sameTypeDepth = _sameTypeDepth + 1;
	const result = sameTypeInner(a, b);
	_sameTypeDepth = _sameTypeDepth - 1;
	return result;
}

function sameTypeList(a: Type[], b: Type[]): boolean {
	if (a === null && b === null) return true;
	if (a === null || b === null) return false;
	if (a.length !== b.length) return false;
	for (let i = 0; i < a.length; i += 1) {
		if (!sameType(a[i], b[i])) return false;
	}
	return true;
}

function sameNameList(a: string[], b: string[]): boolean {
	if (a === null && b === null) return true;
	if (a === null || b === null) return false;
	if (a.length !== b.length) return false;
	for (let i = 0; i < a.length; i += 1) {
		if (a[i] !== b[i]) return false;
	}
	return true;
}

function sameStructType(a: Type, b: Type): boolean {
	// Nominal types keep comparing by name; anonymous ones are structural.
	if (a.typeName !== "" || b.typeName !== "") return a.typeName === b.typeName;
	if (a.typeFlags !== b.typeFlags) return false;
	if (!sameNameList(a.typeNames, b.typeNames)) return false;
	return sameTypeList(a.typeChildren, b.typeChildren);
}

function sameInnerType(a: Type, b: Type): boolean {
	if (a.typeReturn === null && b.typeReturn === null) return true;
	if (a.typeReturn === null || b.typeReturn === null) return false;
	return sameType(a.typeReturn, b.typeReturn);
}

function sameTypeInner(a: Type, b: Type): boolean {
	if (a.kind !== b.kind) return false;
	return match (a.kind) {
		TypeKind.Struct => sameStructType(a, b),
		TypeKind.Enum | TypeKind.Distinct | TypeKind.GenericParam
			| TypeKind.StringLiteral | TypeKind.BooleanLiteral
			| TypeKind.TypeReference => a.typeName === b.typeName,
		TypeKind.EnumLiteral => a.typeName === b.typeName && sameNameList(a.typeNames, b.typeNames),
		TypeKind.GenericInstance => a.typeName === b.typeName && sameTypeList(a.typeChildren, b.typeChildren),
		TypeKind.Union | TypeKind.Tuple | TypeKind.Varargs
			| TypeKind.Conditional => sameTypeList(a.typeChildren, b.typeChildren),
		TypeKind.Function => sameTypeList(a.typeChildren, b.typeChildren) && sameInnerType(a, b),
		TypeKind.SizedArray => a.typeFlags === b.typeFlags && sameInnerType(a, b),
		TypeKind.Array | TypeKind.Span | TypeKind.Ref | TypeKind.Ptr
			| TypeKind.Borrow | TypeKind.Var | TypeKind.Sink
			| TypeKind.Lent => sameInnerType(a, b),
		// Primitives and every remaining kind carry no payload — same kind is
		// the whole answer.
		_ => true,
	};
}

let _relationDepth = 0;
export function typeRelation(formal: Type | null, actual: Type | null): TypeRelation {
	if (_relationDepth > 20) return TypeRelation.Generic;
	_relationDepth = _relationDepth + 1;
	const result = typeRelationInner(formal, actual);
	_relationDepth = _relationDepth - 1;
	return result;
}

function typeRelationInner(formal: Type | null, actual: Type | null): TypeRelation {
	if (formal === null || actual === null) return TypeRelation.None;
	// Ownership modifiers (Sink/Lent) are transparent — unwrap before comparison.
	if (formal.kind === TypeKind.Sink || formal.kind === TypeKind.Lent) {
		if (formal.typeReturn !== null) formal = formal.typeReturn;
	}
	if (actual.kind === TypeKind.Sink || actual.kind === TypeKind.Lent) {
		if (actual.typeReturn !== null) actual = actual.typeReturn;
	}
	// Never is the bottom type — relates to everything. After exhaustive
	// narrowing eliminates all union variants, the residual is never.
	if (actual.kind === TypeKind.Never) return TypeRelation.Exact;
	// Same kind: dispatch on type-specific rules
	if (formal.kind === actual.kind) {
		return match (formal.kind) {
			TypeKind.Struct => {
				if (formal.typeName === actual.typeName) return TypeRelation.Exact;
				if (isObjectAssignable(actual, formal)) return TypeRelation.Subtype;
				return TypeRelation.None;
			},
			TypeKind.Enum | TypeKind.Distinct => {
				if (formal.typeName === actual.typeName) return TypeRelation.Exact;
				return TypeRelation.None;
			},
			// Literal types carry their value in typeName — two different literals
			// are different types (isAssignable :368/:384, sameType :651).
			TypeKind.StringLiteral | TypeKind.BooleanLiteral => {
				if (formal.typeName === actual.typeName) return TypeRelation.Exact;
				return TypeRelation.None;
			},
			TypeKind.EnumLiteral => {
				if (formal.typeName !== actual.typeName) return TypeRelation.None;
				if (formal.typeNames.length === 0 || actual.typeNames.length === 0) return TypeRelation.None;
				if (formal.typeNames[0] === actual.typeNames[0]) return TypeRelation.Exact;
				return TypeRelation.None;
			},
			TypeKind.SizedArray => {
				if (formal.typeFlags !== actual.typeFlags) return TypeRelation.None;
				if (formal.typeReturn !== null && actual.typeReturn !== null) {
					const elemRel = typeRelation(formal.typeReturn, actual.typeReturn);
					if (elemRel === TypeRelation.None) return TypeRelation.None;
					return elemRel;
				}
				return TypeRelation.Exact;
			},
			TypeKind.Array | TypeKind.Span | TypeKind.Ref | TypeKind.Ptr => {
				if (formal.typeReturn !== null && actual.typeReturn !== null) {
					const elemRel = typeRelation(formal.typeReturn, actual.typeReturn);
					if (elemRel === TypeRelation.None) return TypeRelation.None;
					return elemRel;
				}
				return TypeRelation.Exact;
			},
			TypeKind.GenericInstance => {
				// Structural type arg comparison (Result, Promise, Map, Set, user generics)
				if (formal.typeName !== actual.typeName) return TypeRelation.None;
				const giLimit = formal.typeChildren.length < actual.typeChildren.length ? formal.typeChildren.length : actual.typeChildren.length;
				for (let gi = 0; gi < giLimit; gi += 1) {
					const argRel = typeRelation(formal.typeChildren[gi], actual.typeChildren[gi]);
					if (argRel === TypeRelation.None) return TypeRelation.None;
				}
				return TypeRelation.Exact;
			},
			TypeKind.Function => {
				// Nim procTypeRel (sigmatch.nim:789): arity, then every param, then
				// the return type, combined with minRel — the weakest component wins.
				// callConv is deliberately not folded in (NIM-REF row 77: MS has one
				// closure repr, so it carries no discriminating information).
				if (formal.typeChildren.length !== actual.typeChildren.length) return TypeRelation.None;
				let worst = TypeRelation.Exact;
				for (let pi = 0; pi < formal.typeChildren.length; pi += 1) {
					const paramRel = typeRelation(formal.typeChildren[pi], actual.typeChildren[pi]);
					if (paramRel === TypeRelation.None) return TypeRelation.None;
					if (paramRel < worst) worst = paramRel;
				}
				// A null side carries no information (inference pending), so it does
				// not penalise — only two known return types are compared.
				if (formal.typeReturn !== null && actual.typeReturn !== null) {
					const retRel = typeRelation(formal.typeReturn, actual.typeReturn);
					if (retRel === TypeRelation.None) return TypeRelation.None;
					if (retRel < worst) worst = retRel;
				}
				return worst;
			},
			_ => TypeRelation.Exact,
		};
	}
	// Var (out param) unwrap: formal is Var<T>, actual is T → match inner
	if (formal.kind === TypeKind.Var && formal.typeReturn !== null) {
		return typeRelation(formal.typeReturn, actual);
	}

	// Inference sentinels + user unknown score as Generic
	if (formal.kind === TypeKind.Unknown || actual.kind === TypeKind.Unknown
		|| formal.kind === TypeKind.None || actual.kind === TypeKind.None
		|| formal.kind === TypeKind.Inferred || actual.kind === TypeKind.Inferred) {
		return TypeRelation.Generic;
	}
	// GenericParam = inference pending
	if (formal.kind === TypeKind.GenericParam || actual.kind === TypeKind.GenericParam) {
		return TypeRelation.Generic;
	}
	// Implicit coercion to Span: T[] -> Span<T> or T[N] -> Span<T>
	if (formal.kind === TypeKind.Span) {
		if (actual.kind === TypeKind.Array || actual.kind === TypeKind.SizedArray) {
			const elemRel = typeRelation(formal.typeReturn, actual.typeReturn);
			if (elemRel !== TypeRelation.None) return TypeRelation.Subtype;
		}
	}
	// Error type = suppress cascading
	if (formal.kind === TypeKind.Error || actual.kind === TypeKind.Error) {
		return TypeRelation.Exact;
	}
	// FromLiteral: Number/Float64 → sized numeric formal (number and float64 are both IEEE 754 double)
	// Must check before int-to-int widening since Number and Float64 share rank with sized types
	if (isNumeric(formal) && (actual.kind === TypeKind.Number || actual.kind === TypeKind.Float64)) {
		return TypeRelation.FromLiteral;
	}
	// Numeric widening: sized → Number
	if (isNumeric(actual) && formal.kind === TypeKind.Number) {
		return TypeRelation.IntConv;
	}
	// Int-to-int widening: smaller int → larger int (e.g., int32 → int64)
	// Safe widening (rank increases) and same-rank conversions (e.g., int32 → uint32).
	// Narrowing (rank decreases) requires explicit cast.
	if (isNumeric(actual) && isNumeric(formal) && actual.kind !== formal.kind
		&& integerRank(actual) <= integerRank(formal)) {
		return TypeRelation.IntConv;
	}
	// Null to nullable (mirrors isAssignableInner's null-source switch).
	if (actual.kind === TypeKind.Null) {
		if (formal.kind === TypeKind.Struct || formal.kind === TypeKind.Array ||
			formal.kind === TypeKind.SizedArray || formal.kind === TypeKind.Span ||
			formal.kind === TypeKind.Function || formal.kind === TypeKind.Ref || formal.kind === TypeKind.Ptr ||
			formal.kind === TypeKind.Void) {
			return TypeRelation.Subtype;
		}
	}
	// StringLiteral → String (mirrors isAssignable :362).
	if (formal.kind === TypeKind.String && actual.kind === TypeKind.StringLiteral) {
		return TypeRelation.Subtype;
	}
	// BooleanLiteral → Boolean (mirrors isAssignable :381; the reverse stays None).
	if (formal.kind === TypeKind.Boolean && actual.kind === TypeKind.BooleanLiteral) {
		return TypeRelation.Subtype;
	}
	// EnumLiteral cross-kind rules:
	// formal=Enum(K), actual=EnumLiteral(K,A) → Subtype (literal narrows general enum)
	if (formal.kind === TypeKind.Enum && actual.kind === TypeKind.EnumLiteral) {
		if (formal.typeName === actual.typeName) return TypeRelation.Subtype;
		return TypeRelation.None;
	}
	// formal=EnumLiteral(K,A), actual=Enum(K) → None (would lose specificity)
	if (formal.kind === TypeKind.EnumLiteral && actual.kind === TypeKind.Enum) {
		return TypeRelation.None;
	}
	// EnumLiteral → numeric (enums are ints at runtime)
	if (actual.kind === TypeKind.EnumLiteral && isNumeric(formal)) {
		return TypeRelation.IntConv;
	}
	// Union target: best match
	if (formal.kind === TypeKind.Union) {
		let best = TypeRelation.None;
		for (const member of formal.typeChildren) {
			const rel = typeRelation(member, actual);
			if ((rel as number) > (best as number)) { best = rel; }
		}
		return best;
	}
	// Union actual: every member must relate — the weakest member relation wins.
	// Dual of isAssignable's union-source arm (:406); without it overload
	// resolution and assignment disagree on the same pair.
	if (actual.kind === TypeKind.Union) {
		let weakest = TypeRelation.Exact;
		for (const member of actual.typeChildren) {
			const rel = typeRelation(formal, member);
			if (rel === TypeRelation.None) return TypeRelation.None;
			if ((rel as number) < (weakest as number)) { weakest = rel; }
		}
		return weakest;
	}
	if (formal.kind === TypeKind.CString
			&& (actual.kind === TypeKind.String || actual.kind === TypeKind.StringLiteral)) {
		return TypeRelation.Convertible;
	}
	if (formal.kind === TypeKind.String && actual.kind === TypeKind.CString) {
		return TypeRelation.Convertible;
	}
	return TypeRelation.None;
}

// Score a candidate function against actual arguments.
// Returns sum of TypeRelation values, or -1 if any param doesn't match.
export function scoreCandidate(paramTypes: Type[], argTypes: Type[]): number {
	if (paramTypes.length !== argTypes.length) return -1;
	let score = 0;
	for (let i = 0; i < paramTypes.length; i += 1) {
		const rel = typeRelation(paramTypes[i], argTypes[i]);
		if (rel === TypeRelation.None) return -1;
		score = score + (rel as number);
	}
	return score;
}

// ===== Standard-Aligned Overload Resolution (Priority-Based) =====

// Candidate scoring with per-category counters (Standard reference pattern).
// All 7 fields included upfront so struct never changes (DRC #32 safe).
export interface CandidateScore {
	exactMatches: number;       // isEqual matches
	genericMatches: number;     // isGeneric / isInferred matches
	subtypeMatches: number;     // isSubtype / isSubrange matches
	intConvMatches: number;     // isIntConv + isFromIntLit (Standard weight: += 256)
	convMatches: number;        // isConvertible (converters — always 0 for now)
	inheritancePenalty: number; // class hierarchy depth (-1 = inactive)
	calleeScope: number;        // scope depth where candidate found (higher = inner)
}

export function emptyCandidateScore(): CandidateScore {
	return {
		exactMatches: 0, genericMatches: 0, subtypeMatches: 0,
		intConvMatches: 0, convMatches: 0,
		inheritancePenalty: -1, calleeScope: 0,
	};
}

export function isNoMatch(score: CandidateScore): boolean {
	return score.exactMatches === -1;
}

// Score a candidate function against actual arguments (Standard-aligned priority counters).
// Maps TypeRelation → counter increments matching standard reference implementation.
// minArity: minimum required args (default = paramTypes.length, i.e. all required).
export function scoreCandidatePriority(paramTypes: Type[], argTypes: Type[], minArity: number): CandidateScore {
	return scoreCandidateWithSkip(paramTypes, argTypes, minArity, null as unknown as boolean[]);
}

// Score variant that treats args marked in skipMask as unconditional Subtype
// matches (context-sensitive args in two-pass overload resolution — object
// literals and arrow functions are re-checked with the winner's param types in
// Pass 2, so Pass 1 scoring must not reject them for partial/incomplete typing).
export function scoreCandidateWithSkip(paramTypes: Type[], argTypes: Type[], minArity: number, skipMask: boolean[]): CandidateScore {
	const score = emptyCandidateScore();
	if (argTypes.length < minArity || argTypes.length > paramTypes.length) {
		score.exactMatches = -1;
		return score;
	}
	// Score only provided args (default-filled params don't contribute)
	for (let i = 0; i < argTypes.length; i += 1) {
		if (skipMask !== null && i < skipMask.length && skipMask[i]) {
			score.subtypeMatches = score.subtypeMatches + 1;
			continue;
		}
		const rel = typeRelation(paramTypes[i], argTypes[i]);
		if (rel === TypeRelation.None) {
			score.exactMatches = -1;
			return score;
		}
		match (rel) {
			TypeRelation.Exact => { score.exactMatches = score.exactMatches + 1; },
			TypeRelation.FromLiteral => { score.intConvMatches = score.intConvMatches + 256; },
			TypeRelation.Generic => { score.genericMatches = score.genericMatches + 1; },
			TypeRelation.Subtype => { score.subtypeMatches = score.subtypeMatches + 1; },
			TypeRelation.IntConv => { score.intConvMatches = score.intConvMatches + 1; },
			TypeRelation.Convertible => { score.convMatches = score.convMatches + 1; },
			_ => {},
		};
	}
	return score;
}

// Compare inheritance penalties. -1 = inactive (sentinel).
// Lower penalty = more specific (better). Returns >0 if a is better.
function cmpInheritancePenalty(a: number, b: number): number {
	if (a === -1 && b === -1) return 0;
	if (a === -1) return -1; // a inactive, b has penalty → b is better
	if (b === -1) return 1;  // b inactive, a has penalty → a is better
	return b - a; // lower penalty is better, so b - a > 0 means a < b means a wins
}

// Standard-aligned priority comparison (9-step chain from reference signature matching).
// Returns >0 if a is better, <0 if b is better, 0 if ambiguous.
// candidateTypeA/B are the Function types for generic specialization (Phase 5).
// Pass null to skip steps 7-8.
export function cmpCandidates(a: CandidateScore, b: CandidateScore,
	candidateTypeA: Type | null, candidateTypeB: Type | null): number {
	// 1. Exact matches (highest priority)
	let result = a.exactMatches - b.exactMatches;
	if (result !== 0) return result;
	// 2. Generic matches
	result = a.genericMatches - b.genericMatches;
	if (result !== 0) return result;
	// 3. Subtype matches
	result = a.subtypeMatches - b.subtypeMatches;
	if (result !== 0) return result;
	// 4. Int conversion matches
	result = a.intConvMatches - b.intConvMatches;
	if (result !== 0) return result;
	// 5. Conversion matches
	result = a.convMatches - b.convMatches;
	if (result !== 0) return result;
	// 6. Inheritance penalty (lower = better)
	result = cmpInheritancePenalty(a.inheritancePenalty, b.inheritancePenalty);
	if (result !== 0) return result;
	// 7. checkGeneric — generic specialization (Phase 5, stubbed)
	if (candidateTypeA !== null && candidateTypeB !== null) {
		result = checkGenericSpecialization(candidateTypeA, candidateTypeB);
		if (result !== 0) return result;
		// 8. complexDisambiguation — genericness depth (Phase 5, stubbed)
		result = complexDisambiguation(candidateTypeA, candidateTypeB);
		if (result !== 0) return result;
	}
	// 9. Scope depth (higher = inner scope = preferred)
	result = a.calleeScope - b.calleeScope;
	return result;
}

// Generic specialization: cross-test formal types for specificity.
// f<T>(x: T[]) is more specific than f<T>(x: T) because T[] can match T generically
// but T cannot match T[].
// Returns >0 if A is more specific, <0 if B, 0 if equal/contradictory.
function checkGenericSpecialization(typeA: Type, typeB: Type): number {
	if (typeA === null || typeB === null) return 0;
	if (typeA.kind !== TypeKind.Function || typeB.kind !== TypeKind.Function) return 0;
	const lenA = typeA.typeChildren.length;
	const lenB = typeB.typeChildren.length;
	if (lenA !== lenB) return 0;
	let aWins = 0;
	let bWins = 0;
	let i = 0;
	while (i < lenA) {
		const pA = typeA.typeChildren[i];
		const pB = typeB.typeChildren[i];
		// Cross-test: can B's formal match A's as Generic?
		const bMatchesA = typeRelation(pA, pB);
		const aMatchesB = typeRelation(pB, pA);
		if (bMatchesA === TypeRelation.Generic && aMatchesB !== TypeRelation.Generic) {
			aWins = aWins + 1; // A is more specific (B is more general)
		} else if (aMatchesB === TypeRelation.Generic && bMatchesA !== TypeRelation.Generic) {
			bWins = bWins + 1; // B is more specific (A is more general)
		}
		i = i + 1;
	}
	if (aWins > 0 && bWins === 0) return 1;
	if (bWins > 0 && aWins === 0) return -1;
	return 0; // contradiction or equal
}

// Count generic nesting depth of a type (Standard reference implementation).
// Higher depth = more specific overload.
// GenericParam = 1, Container<T> = 1 + sumGeneric(T)
let sumGenericDepth = 0;
function sumGeneric(t: Type | null): number {
	if (t === null) return 0;
	if (t.kind === TypeKind.GenericParam || t.kind === TypeKind.Unknown || t.kind === TypeKind.None || t.kind === TypeKind.Inferred) return 1;
	if (sumGenericDepth > 20) return 0;
	sumGenericDepth = sumGenericDepth + 1;
	let childSum = 0;
	let i = 0;
	while (i < t.typeChildren.length) {
		childSum = childSum + sumGeneric(t.typeChildren[i]);
		i = i + 1;
	}
	if (t.typeReturn !== null) {
		childSum = childSum + sumGeneric(t.typeReturn);
	}
	if (t.typeExtra !== null) {
		childSum = childSum + sumGeneric(t.typeExtra);
	}
	sumGenericDepth = sumGenericDepth - 1;
	if (childSum > 0) return childSum + 1;
	return 0;
}

// Complex disambiguation: per-parameter generic depth comparison.
// Higher sumGeneric = more specific overload.
// Per-parameter contradiction detection: if param i favors A but param j favors B → return 0.
// Returns >0 if A is more specific, <0 if B, 0 if equal/contradictory.
function complexDisambiguation(typeA: Type, typeB: Type): number {
	if (typeA === null || typeB === null) return 0;
	if (typeA.kind !== TypeKind.Function || typeB.kind !== TypeKind.Function) return 0;
	let aWins = 0;
	let bWins = 0;
	let i = 0;
	const len = typeA.typeChildren.length;
	while (i < len && i < typeB.typeChildren.length) {
		const gA = sumGeneric(typeA.typeChildren[i]);
		const gB = sumGeneric(typeB.typeChildren[i]);
		if (gA > gB) {
			aWins = aWins + 1;
		} else if (gB > gA) {
			bWins = bWins + 1;
		}
		i = i + 1;
	}
	// Contradiction: both have params where they're more specific → ambiguous
	if (aWins > 0 && bWins > 0) return 0;
	if (aWins > 0) return 1;
	if (bWins > 0) return -1;
	return 0;
}

// Resolve which overload index best matches argTypes.
// candidates: array of Function types (primary at [0], overloads at [1..n])
// scopeDepths: parallel array of scope depths per candidate (0 if same scope)
// Returns: index into candidates, -1 = no match, -2 = ambiguous
export function resolveOverloadIdx(candidates: Type[], argTypes: Type[],
	scopeDepths: number[]): number {
	let bestIdx = -1;
	let bestScore = emptyCandidateScore();
	let bestType: Type | null = null;
	let ambiguous = false;
	for (let i = 0; i < candidates.length; i += 1) {
		if (candidates[i].kind !== TypeKind.Function) continue;
		const score = scoreCandidatePriority(candidates[i].typeChildren, argTypes, getMinArity(candidates[i]));
		if (isNoMatch(score)) continue;
		// Set scope depth from parallel array
		if (i < scopeDepths.length) {
			score.calleeScope = scopeDepths[i];
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
	}
	if (ambiguous) return -2;
	return bestIdx;
}

// Find first mismatch position between a candidate's params and actual arg types.
// Returns 0-based position, or -1 if all match.
export function findFirstMismatch(paramTypes: Type[], argTypes: Type[], minArity: number): number {
	if (argTypes.length > paramTypes.length) return paramTypes.length; // extra arg
	if (argTypes.length < minArity) return argTypes.length; // missing required param
	for (let i = 0; i < argTypes.length; i += 1) {
		const rel = typeRelation(paramTypes[i], argTypes[i]);
		if (rel === TypeRelation.None) return i;
	}
	return -1;
}

// ===== Tests =====
test "same kind" {
	assert isAssignable(numberType(), numberType());
	assert isAssignable(stringType(), stringType());
	assert isAssignable(booleanType(), booleanType());
}

test "different kind" {
	assert !isAssignable(numberType(), stringType());
	assert !isAssignable(stringType(), booleanType());
}

test "unknown compatible" {
	assert isAssignable(inferredType(), numberType());
	assert isAssignable(numberType(), inferredType());
}

test "numeric widening" {
	assert isAssignable(createPrimitive(TypeKind.Int32), numberType());
	assert isAssignable(createPrimitive(TypeKind.Float64), numberType());
}

test "null to nullable" {
	assert isAssignable(nullType(), createStruct("Foo", [], [], false));
	assert isAssignable(nullType(), createArray(numberType()));
	assert !isAssignable(nullType(), numberType());
}

test "same element" { assert isAssignable(createArray(numberType()), createArray(numberType())); }

test "different element" { assert !isAssignable(createArray(numberType()), createArray(stringType())); }

test "unknown element" { assert isAssignable(createArray(inferredType()), createArray(numberType())); }

test "same signature" {
	const f1 = createFunction([numberType()], ["a"], stringType());
	const f2 = createFunction([numberType()], ["b"], stringType());
	assert isAssignable(f1, f2);
}

test "different param count" {
	const f1 = createFunction([numberType()], ["a"], voidType());
	const f2 = createFunction([], [], voidType());
	assert !isAssignable(f1, f2);
}

test "covariant return" {
	const f1 = createFunction([], [], inferredType());
	const f2 = createFunction([], [], numberType());
	assert isAssignable(f1, f2);
}

test "nominal same name" {
	const o1 = createStruct("Type", ["kind"], [numberType()], false);
	const o2 = createStruct("Type", ["kind"], [inferredType()], false);
	assert isAssignable(o1, o2);
}

test "exact match" {
	const o1 = createStruct("A", ["x"], [numberType()], false);
	const o2 = createStruct("B", ["x"], [numberType()], false);
	assert isAssignable(o1, o2);
}

test "source has extra props" {
	const o1 = createStruct("A", ["x", "y"], [numberType(), stringType()], false);
	const o2 = createStruct("B", ["x"], [numberType()], false);
	assert isAssignable(o1, o2);
}

test "source missing prop" {
	const o1 = createStruct("A", ["x"], [numberType()], false);
	const o2 = createStruct("B", ["x", "y"], [numberType(), stringType()], false);
	assert !isAssignable(o1, o2);
}

test "exact match" {
	assert typeRelation(numberType(), numberType()) === TypeRelation.Exact;
	assert typeRelation(stringType(), stringType()) === TypeRelation.Exact;
}

test "no match" { assert typeRelation(numberType(), stringType()) === TypeRelation.None; }

test "unknown = generic" {
	assert typeRelation(numberType(), inferredType()) === TypeRelation.Generic;
	assert typeRelation(inferredType(), numberType()) === TypeRelation.Generic;
}

test "int conversion" { assert typeRelation(numberType(), createPrimitive(TypeKind.Int32)) === TypeRelation.IntConv; }

test "null to object" { assert typeRelation(createStruct("Foo", [], [], false), nullType()) === TypeRelation.Subtype; }

test "exact args" {
	const score = scoreCandidate([numberType(), stringType()], [numberType(), stringType()]);
	assert score === 12; // 6 + 6
}

test "arity mismatch" { assert scoreCandidate([numberType()], []) === -1; }

test "type mismatch" { assert scoreCandidate([numberType()], [stringType()]) === -1; }

test "mixed scoring" {
	const score = scoreCandidate([numberType(), numberType()], [numberType(), createPrimitive(TypeKind.Int32)]);
	assert score === 8; // 6 (exact) + 2 (intconv)
}

test "source union all match" {
	const u = createUnion([numberType(), stringType()]);
	assert !isAssignable(u, numberType());
}

test "target union has match" {
	const u = createUnion([numberType(), stringType()]);
	assert isAssignable(numberType(), u);
	assert isAssignable(stringType(), u);
	assert !isAssignable(booleanType(), u);
}

test "same result types" {
	const r1 = createResult(numberType(), stringType());
	const r2 = createResult(numberType(), stringType());
	assert isAssignable(r1, r2);
}

test "different ok type" {
	const r1 = createResult(numberType(), stringType());
	const r2 = createResult(stringType(), stringType());
	assert !isAssignable(r1, r2);
}

test "different err type" {
	const r1 = createResult(numberType(), stringType());
	const r2 = createResult(numberType(), numberType());
	assert !isAssignable(r1, r2);
}

test "unknown ok compatible" {
	const r1 = createResult(inferredType(), stringType());
	const r2 = createResult(numberType(), stringType());
	assert isAssignable(r1, r2);
}

test "same enum name" {
	const e1 = createEnum("Color", ["Red", "Green"], null as unknown as number[]);
	const e2 = createEnum("Color", ["Red", "Green"], null as unknown as number[]);
	assert isAssignable(e1, e2);
}

test "different enum name" {
	const e1 = createEnum("Color", ["Red"], null as unknown as number[]);
	const e2 = createEnum("Shape", ["Circle"], null as unknown as number[]);
	assert !isAssignable(e1, e2);
}

test "same ref inner" {
	const r1 = createRef(numberType());
	const r2 = createRef(numberType());
	assert isAssignable(r1, r2);
}

test "different ref inner" {
	const r1 = createRef(numberType());
	const r2 = createRef(stringType());
	assert !isAssignable(r1, r2);
}

test "same ptr inner" {
	const p1 = createPtr(numberType());
	const p2 = createPtr(numberType());
	assert isAssignable(p1, p2);
}

// TS-strict: null is NOT assignable to bare Ref<T> — must be Union(Ref<T>, Null).
test "null rejected by bare ref" { assert !isAssignable(nullType(), createRef(numberType())); }

test "null accepted by Ref|Null union" {
	const u = createUnion([createRef(numberType()), nullType()]);
	assert isAssignable(nullType(), u);
}

test "null to sized array" { assert isAssignable(nullType(), createSizedArray(numberType(), 4)); }

test "null to span" { assert isAssignable(nullType(), createSpan(numberType())); }

test "array to span" {
	const arr = createArray(numberType());
	const span = createSpan(numberType());
	assert isAssignable(arr, span);
	assert typeRelation(span, arr) === TypeRelation.Subtype;
}

test "sized array to span" {
	const sarr = createSizedArray(numberType(), 4);
	const span = createSpan(numberType());
	assert isAssignable(sarr, span);
	assert typeRelation(span, sarr) === TypeRelation.Subtype;
}

test "mismatched element to span" {
	const arr = createArray(stringType());
	const span = createSpan(numberType());
	assert !isAssignable(arr, span);
	assert typeRelation(span, arr) === TypeRelation.None;
}

// TS-strict: null is NOT assignable to bare Ptr<T> — must be Union(Ptr<T>, Null).
test "null rejected by bare ptr" { assert !isAssignable(nullType(), createPtr(numberType())); }

// allowsNil (sigmatch.nim:730): a cursor link is nilable by design.
test "null accepted by bare cursor" { assert isAssignable(nullType(), createCursor(numberType())); }

test "null still rejected by bare ref" { assert !isAssignable(nullType(), createRef(createStruct("S", [], [], true))); }

test "null accepted by Ptr|Null union" {
	const u = createUnion([createPtr(numberType()), nullType()]);
	assert isAssignable(nullType(), u);
}

test "same distinct name" {
	const d1 = createDistinct(numberType());
	d1.typeName = "UserId";
	const d2 = createDistinct(numberType());
	d2.typeName = "UserId";
	assert isAssignable(d1, d2);
}

test "different distinct name" {
	const d1 = createDistinct(numberType());
	d1.typeName = "UserId";
	const d2 = createDistinct(numberType());
	d2.typeName = "GroupId";
	assert !isAssignable(d1, d2);
}

test "enum exact" {
	const e1 = createEnum("Color", ["Red"], null as unknown as number[]);
	const e2 = createEnum("Color", ["Red"], null as unknown as number[]);
	assert typeRelation(e1, e2) === TypeRelation.Exact;
}

test "enum mismatch" {
	const e1 = createEnum("Color", ["Red"], null as unknown as number[]);
	const e2 = createEnum("Shape", ["Circle"], null as unknown as number[]);
	assert typeRelation(e1, e2) === TypeRelation.None;
}

test "enum literal same member exact" {
	const e = createEnum("K", ["A", "B"], null as unknown as number[]);
	const a1 = createEnumLiteral(e, "A");
	const a2 = createEnumLiteral(e, "A");
	assert typeRelation(a1, a2) === TypeRelation.Exact;
}

test "enum literal different members none" {
	const e = createEnum("K", ["A", "B"], null as unknown as number[]);
	const a = createEnumLiteral(e, "A");
	const b = createEnumLiteral(e, "B");
	assert typeRelation(a, b) === TypeRelation.None;
}

test "enum literal subtype of enum" {
	const e = createEnum("K", ["A", "B"], null as unknown as number[]);
	const a = createEnumLiteral(e, "A");
	assert typeRelation(e, a) === TypeRelation.Subtype;
}

test "enum not assignable to enum literal" {
	const e = createEnum("K", ["A", "B"], null as unknown as number[]);
	const a = createEnumLiteral(e, "A");
	assert typeRelation(a, e) === TypeRelation.None;
}

test "enum literal isAssignable to enum" {
	const e = createEnum("K", ["A", "B"], null as unknown as number[]);
	const a = createEnumLiteral(e, "A");
	assert isAssignable(a, e);
}

test "enum literal cross-enum none" {
	const k = createEnum("K", ["A"], null as unknown as number[]);
	const m = createEnum("M", ["A"], null as unknown as number[]);
	const ka = createEnumLiteral(k, "A");
	const ma = createEnumLiteral(m, "A");
	assert typeRelation(ka, ma) === TypeRelation.None;
}

test "result exact" {
	const r1 = createResult(numberType(), stringType());
	const r2 = createResult(numberType(), stringType());
	assert typeRelation(r1, r2) === TypeRelation.Exact;
}

test "result mismatch" {
	const r1 = createResult(numberType(), stringType());
	const r2 = createResult(stringType(), stringType());
	assert typeRelation(r1, r2) === TypeRelation.None;
}

test "array same element exact" { assert typeRelation(createArray(numberType()), createArray(numberType())) === TypeRelation.Exact; }

test "array different element none" { assert typeRelation(createArray(numberType()), createArray(stringType())) === TypeRelation.None; }

test "ref same inner exact" { assert typeRelation(createRef(numberType()), createRef(numberType())) === TypeRelation.Exact; }

test "ref different inner none" { assert typeRelation(createRef(numberType()), createRef(stringType())) === TypeRelation.None; }

test "ptr same inner exact" { assert typeRelation(createPtr(numberType()), createPtr(numberType())) === TypeRelation.Exact; }

test "ptr different inner none" { assert typeRelation(createPtr(numberType()), createPtr(stringType())) === TypeRelation.None; }

test "from literal" {
	assert typeRelation(createPrimitive(TypeKind.Int32), numberType()) === TypeRelation.FromLiteral;
	assert typeRelation(createPrimitive(TypeKind.Float64), numberType()) === TypeRelation.FromLiteral;
}

test "generic param" {
	const gp = createGenericParam("T");
	assert typeRelation(gp, numberType()) === TypeRelation.Generic;
	assert typeRelation(numberType(), gp) === TypeRelation.Generic;
}

test "exact beats subtype-sum" {
	// a: 1 exact + 0 subtype; b: 0 exact + 3 subtype
	// Priority: exact wins regardless of subtype count
	const a = emptyCandidateScore();
	a.exactMatches = 1;
	const b = emptyCandidateScore();
	b.subtypeMatches = 3;
	const nullT = null;
	assert cmpCandidates(a, b, nullT, nullT) > 0;
}

test "FromLiteral weight intConvMatches += 256" {
	// formal=Int32, actual=Number → FromLiteral (number literal to sized param)
	const params = [createPrimitive(TypeKind.Int32)];
	const args = [numberType()];
	const score = scoreCandidatePriority(params, args, params.length);
	assert !isNoMatch(score);
	// FromLiteral maps to intConvMatches += 256
	assert score.intConvMatches === 256;
	assert score.exactMatches === 0;
}

test "ambiguity: equal scores" {
	// Two identical candidates → cmp returns 0
	const a = emptyCandidateScore();
	a.exactMatches = 2;
	const b = emptyCandidateScore();
	b.exactMatches = 2;
	const nullT = null;
	assert cmpCandidates(a, b, nullT, nullT) === 0;
}

test "inheritance penalty: lower wins" {
	const a = emptyCandidateScore();
	a.exactMatches = 1;
	a.inheritancePenalty = 1; // direct parent
	const b = emptyCandidateScore();
	b.exactMatches = 1;
	b.inheritancePenalty = 3; // grandgrandparent
	const nullT = null;
	// a has lower penalty → a is better → result > 0
	assert cmpCandidates(a, b, nullT, nullT) > 0;
}

test "scope depth: inner wins" {
	const a = emptyCandidateScore();
	a.exactMatches = 1;
	a.calleeScope = 2;
	const b = emptyCandidateScore();
	b.exactMatches = 1;
	b.calleeScope = 0;
	const nullT = null;
	// a is inner (higher scope) → a wins → result > 0
	assert cmpCandidates(a, b, nullT, nullT) > 0;
}

test "single candidate matches" {
	const fn1 = createFunction([numberType()], ["a"], stringType());
	const candidates = [fn1];
	const argTypes = [numberType()];
	const depths: number[] = [0];
	assert resolveOverloadIdx(candidates, argTypes, depths) === 0;
}

test "picks best of two" {
	// fn1(number) vs fn2(string); call with number → fn1 wins (idx 0)
	const fn1 = createFunction([numberType()], ["a"], stringType());
	const fn2 = createFunction([stringType()], ["b"], stringType());
	const candidates = [fn1, fn2];
	const argTypes = [numberType()];
	const depths: number[] = [0, 0];
	assert resolveOverloadIdx(candidates, argTypes, depths) === 0;
}

test "picks second overload" {
	// fn1(number) vs fn2(string); call with string → fn2 wins (idx 1)
	const fn1 = createFunction([numberType()], ["a"], stringType());
	const fn2 = createFunction([stringType()], ["b"], stringType());
	const candidates = [fn1, fn2];
	const argTypes = [stringType()];
	const depths: number[] = [0, 0];
	assert resolveOverloadIdx(candidates, argTypes, depths) === 1;
}

test "no match returns -1" {
	const fn1 = createFunction([numberType()], ["a"], stringType());
	const candidates = [fn1];
	const argTypes = [stringType()];
	const depths: number[] = [0];
	assert resolveOverloadIdx(candidates, argTypes, depths) === -1;
}

test "ambiguous returns -2" {
	// Two identical-signature candidates → ambiguous
	const fn1 = createFunction([numberType()], ["a"], stringType());
	const fn2 = createFunction([numberType()], ["b"], numberType());
	const candidates = [fn1, fn2];
	const argTypes = [numberType()];
	const depths: number[] = [0, 0];
	assert resolveOverloadIdx(candidates, argTypes, depths) === -2;
}

test "all match" { assert findFirstMismatch([numberType()], [numberType()], 1) === -1; }

test "first param mismatch" { assert findFirstMismatch([numberType()], [stringType()], 1) === 0; }

test "second param mismatch" { assert findFirstMismatch([numberType(), stringType()], [numberType(), numberType()], 2) === 1; }

test "arity mismatch too many args" { assert findFirstMismatch([numberType()], [numberType(), stringType()], 1) === 1; }

test "arity mismatch too few args" { assert findFirstMismatch([numberType(), stringType()], [numberType()], 2) === 1; }

test "complexDisambiguation deeper type wins" {
	// f(T[]) vs f(T) — array param has deeper generic nesting
	const gp = createGenericParam("T");
	const arrGp = createArray(gp);
	const fnDeep = createFunction([arrGp], ["x"], stringType());
	const fnShallow = createFunction([gp], ["x"], stringType());
	const a = emptyCandidateScore();
	a.genericMatches = 1;
	const b = emptyCandidateScore();
	b.genericMatches = 1;
	const nullT = null;
	// step 7 (checkGenericSpecialization) + step 8 (complexDisambiguation) should
	// prefer deeper nesting. With equal genericMatches, cmpCandidates goes to step 7+8.
	const cmp = cmpCandidates(a, b, fnDeep, fnShallow);
	assert cmp > 0;
}

test "complexDisambiguation per-param contradiction returns 0" {
	// f<T,U>(x: T[], y: U) vs f<T,U>(x: T, y: U[])
	// param 0 favors A (deeper), param 1 favors B (deeper) → contradiction → 0
	const gp1 = createGenericParam("T");
	const gp2 = createGenericParam("U");
	const arrGp1 = createArray(gp1);
	const arrGp2 = createArray(gp2);
	const fnA = createFunction([arrGp1, gp2], ["x", "y"], stringType());
	const fnB = createFunction([gp1, arrGp2], ["x", "y"], stringType());
	const a = emptyCandidateScore();
	a.genericMatches = 2;
	const b = emptyCandidateScore();
	b.genericMatches = 2;
	const cmp = cmpCandidates(a, b, fnA, fnB);
	assert cmp === 0;
}
