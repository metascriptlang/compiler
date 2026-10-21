// Type System — utility functions for Type manipulation
// Type class + enums are defined in ast/node.ms (reference parity: single-file AST).

import { bareAfterDelim, splitTopLevel, numericLiteralIsFloat, parseNumberLiteral, parseIntegerLiteral, integerLiteralIsBitPattern, fitsInt64Decimal, int64ToDecimal } from "../utils/string";
import { hashToBase36 as _stdHashToBase36 } from "std/hash";
import { mangleSeparatedProperty } from "../codegen/c/names";
import { resolveRuntimeDir } from "../utils/path";
import { join, normalize } from "std/fs/path";
import { Type, TypeKind, TypeFlag, SymbolKind, SymbolFlag, CallingConvention, AttachedOp, Symbol, Node, NodeKind, TypeAliasDeclData, InterfaceDeclData, ClassDeclData, PropertyDeclData, DecoratedDeclData, ExportDeclData } from "../ast/node";

// =====================================================================
// Type Storage Schema — what each Type field means per TypeKind
// =====================================================================
// The Type struct is intentionally flat (one shape, all fields present).
// Field meaning is TypeKind-dependent. This schema is the single source
// of truth for storage access. **Do not bypass it.**
//
//   kind           — the TypeKind enum value
//   typeName       — nominal name (e.g. "Promise", "Result", struct name)
//   typeNames      — field/variant names (Struct fields, Union variants, DU disc metadata)
//   typeChildren   — type args, field types, variant types, parameter types
//   typeReturn     — function return type; alias target; alternate uninstantiated body
//   typeExtra      — second companion slot (DiscriminatedUnion enum, Result's err for GI)
//   typeFlags      — bitset of TypeFlag (IsStruct, HasAsgn, AwaitableAffine, AwaitableScopeBound, ...)
//
// ----- Awaitable types (Promise, @awaitable-annotated) -----
// Represented as: kind = GenericInstance, typeName = "Promise" | <user>,
//                 typeChildren[0] = inner T.
// All awaitables share a single surface type: `Promise<T>`. Origin is tracked
// on `typeFlags` via AwaitableAffine + AwaitableScopeBound bits (set by spawn
// and @affineAwaitable decorators). Semantic queries (isAwaitable,
// isAffineAwaitable) abstract over both representations.
//
// **DO NOT READ `.typeReturn` for awaitable unwrap.** Use `awaitedType(t)`.
// **DO NOT index `.typeChildren[0]` for awaitable unwrap.** Use `awaitedType(t)`.
// **DO NOT check `.typeName` for affine rules.** Use `isAffineAwaitable(t)`.
//
// The semantic query layer below (`peelThrough`, `isAwaitable`, `awaitedType`,
// `isAffineAwaitable`) is the ONLY supported interface. Adding a new
// awaitable-related question? Add a function here; never peek at storage from
// outside this file.
//
// ----- Other notable TypeKinds -----
//   Alias          — typeName = alias name, typeReturn = aliased target
//   Distinct       — typeName = distinct name, typeChildren[0] = base type
//   GenericInstance— typeName = base name, typeChildren = type args, typeReturn = instantiated body
//   Function       — typeChildren = param types, typeReturn = return type, typeNames = param names
//   Struct         — typeName = struct name, typeNames = field names, typeChildren = field types
//   Union          — typeChildren = variant types, typeNames[0] = discriminant (if DU)
//   Result         — boolean-disc match-type Union; GI typeChildren = [ok, err]
//   Ref/Ptr/Borrow — typeReturn = referent type
//   Array/Span     — typeReturn = element type
//   SizedArray/Set — typeReturn = element, typeValue = element/member count
//
// =====================================================================

export struct TargetInfo {
	ptrSize: int32;
	floatSize: int32;
	cpu: string;
	os: string;
}

export function hostTargetInfo(): TargetInfo {
	const t: TargetInfo = { ptrSize: 8, floatSize: 8, cpu: "", os: "" };
	return t;
}

export function floatInt64Align(tg: TargetInfo): int32 {
	if ((tg.cpu == "i386" || tg.cpu == "386") && tg.os != "windows") return 4;
	return 8;
}

function lenPtrAlign(tg: TargetInfo): int32 {
	const a = floatInt64Align(tg);
	return a > tg.ptrSize ? a : tg.ptrSize;
}

export function literalUnionBase(t: Type | null): Type | null;
export function literalUnionBase(t: Readonly<Type | null>): Readonly<Type | null>;
export function literalUnionBase(t: Readonly<Type | null>): Readonly<Type | null> {
	if (t == null || t.kind != TypeKind.Union || t.typeChildren.length == 0) return null;
	let base: Type | null = null;
	for (const child of t.typeChildren) {
		if (child == null) return null;
		const own = child.kind == TypeKind.StringLiteral ? stringType()
			: (child.kind == TypeKind.NumberLiteral ? numberLiteralBase(child) : null);
		if (own == null || (base != null && base.kind != own.kind)) return null;
		base = own;
	}
	return base;
}

// ===== In-Place Type Upgrade (reference parity: assignType) =====
// Copies all fields from source into target, preserving target's object identity.
// This is critical for circular type resolution: forward placeholder objects are
// upgraded in-place so all existing references automatically see the resolved type.
// Reference: reference statement processing assignType(s.typ, t) — same pattern.

export function assignType(target: Type, source: Type): void {
	target.kind = source.kind;
	target.typeName = source.typeName;
	target.typeNames = source.typeNames;
	target.typeChildren = source.typeChildren;
	target.typeReturn = source.typeReturn;
	target.typeExtra = source.typeExtra;
	target.typeFlags = source.typeFlags;
	target.typeValue = source.typeValue;
	target.callConv = source.callConv;
	target.attachedOps = source.attachedOps;
	target.optionalFields = source.optionalFields;
}

// ===== Constructors =====

export function emptyType(): Type {
	return {
		kind: TypeKind.None,
		typeName: "",
		typeNames: [],
		typeChildren: [],
		typeReturn: null,
		typeExtra: null,
		typeFlags: 0 as BitSet<TypeFlag>,
		typeValue: 0,
		callConv: CallingConvention.CcDefault,
		attachedOps: [],
	};
}

export function createPrimitive(kind: TypeKind): Type {
	const t = emptyType();
	t.kind = kind;
	// bigint is a managed primitive like string, but its ordinal sits past the
	// _sysTypes bound, so the flag cannot be stamped on a shared instance — an
	// owner that never sees HasAsgn on the field gets no scope destroy at all.
	if (kind == TypeKind.BigInt || kind == TypeKind.Unknown) { t.typeFlags = (0 as BitSet<TypeFlag>).incl(TypeFlag.HasAsgn); }
	return t;
}

export function createStruct(name: string, propNames: string[], propTypes: Type[], isInterface: boolean): Type {
	const t = emptyType();
	t.kind = TypeKind.Struct;
	t.typeName = name;
	t.typeNames = propNames;
	t.typeChildren = propTypes;
	if (isInterface) { t.typeFlags = (0 as BitSet<TypeFlag>).incl(TypeFlag.IsStruct); }
	// Propagate HasAsgn from any managed field (Reference parity: bottom-up flag propagation)
	for (const pt of propTypes) { propagateToOwner(t, pt); }
	return t;
}

// Generate a deterministic name for an anonymous struct from its field names and types.
// Format: __anon<count>__<field1><suffix>__<field2><suffix>
// Count prefix + double-underscore separators prevent collisions between
// { x_y: 1 } (__anon1__x_yn) and { x: 1, y: 2 } (__anon2__xn__yn).
// Type suffix prevents same-name different-type collisions.
export function anonStructName(fieldNames: string[], fieldTypes: Type[]): string {
	if (fieldNames.length == 0) return "";
	let name = "__anon" + fieldNames.length;
	let i = 0;
	while (i < fieldNames.length) {
		const ft = i < fieldTypes.length ? fieldTypes[i] : null;
		const suffix = ft == null ? "x" : match (ft.kind) {
			TypeKind.Number | TypeKind.Float64 => "n",
			TypeKind.Float32 => "f",
			TypeKind.String => "s",
			TypeKind.Boolean => "b",
			_ => "x" + _stdHashToBase36(typeKey(ft)),
		};
		name = name + "__" + mangleSeparatedProperty(fieldNames[i]) + suffix;
		i = i + 1;
	}
	return name;
}

export function createArray(element: Type | null): Type {
	return {
		kind: TypeKind.Array, typeName: "", typeNames: [], typeChildren: [],
		typeReturn: element, typeExtra: null, typeFlags: (0 as BitSet<TypeFlag>).incl(TypeFlag.HasAsgn),
		callConv: CallingConvention.CcDefault, attachedOps: [],
	};
}

// Reference parity (tyVarargs): wraps a rest parameter's user-written array
// type. Used only on Function.typeChildren[last] when the corresponding param
// is rest. Transparent to most type code via unwrapVarargs / isVarargs.
export function createVarargs(arrayType: Type): Type {
	return {
		kind: TypeKind.Varargs, typeName: "", typeNames: [], typeChildren: [arrayType],
		typeReturn: null, typeExtra: null, typeFlags: (0 as BitSet<TypeFlag>).incl(TypeFlag.HasAsgn),
		callConv: CallingConvention.CcDefault, attachedOps: [],
	};
}

export function isVarargs(t: Type): boolean {
	return t != null && t.kind == TypeKind.Varargs;
}

export function unwrapVarargs(t: Type): Type;
export function unwrapVarargs(t: Readonly<Type>): Readonly<Type>;
export function unwrapVarargs(t: Readonly<Type>): Readonly<Type> {
	if (t != null && t.kind == TypeKind.Varargs && t.typeChildren.length > 0) {
		return t.typeChildren[0];
	}
	return t;
}

export function createSizedArray(element: Type | null, size: int32): Type {
	const t = emptyType();
	t.kind = TypeKind.SizedArray;
	t.typeReturn = element;
	t.typeValue = size;
	if (element != null) propagateToOwner(t, element);
	return t;
}

export function createSpan(element: Type): Type {
	const t = emptyType();
	t.kind = TypeKind.Span;
	t.typeReturn = element;
	return t;
}

export function createFunction(paramTypes: Type[], paramNames: string[], returnType: Type | null): Type {
	// Clone caller's arrays — Function type owns its typeNames/typeChildren and
	// must not share mutable references with FunctionDeclData.params. Without
	// this, FunctionDecl traversal that strips a "..." prefix would silently
	// leak into every Symbol whose Function type was built from those params.
	const ownNames: string[] = [];
	for (let i = 0; i < paramNames.length; i += 1) ownNames.push(paramNames[i]);
	const ownTypes: Type[] = [];
	for (let i = 0; i < paramTypes.length; i += 1) ownTypes.push(paramTypes[i]);
	// Reference parity (tyVarargs): if the last param name carries the legacy
	// "..." prefix, strip it and wrap its type slot with TypeKind.Varargs. From
	// here on, rest-ness is encoded type-level (typeChildren[last].kind), not
	// as a name prefix — callers walk through unwrapVarargs / isVarargs.
	const last = ownNames.length - 1;
	if (last >= 0 && ownNames[last].length > 3 && ownNames[last].slice(0, 3) == "...") {
		ownNames[last] = ownNames[last].slice(3, ownNames[last].length);
		if (last < ownTypes.length && ownTypes[last].kind != TypeKind.Varargs) {
			ownTypes[last] = createVarargs(ownTypes[last]);
		}
	}
	return {
		kind: TypeKind.Function, typeName: "", typeNames: ownNames, typeChildren: ownTypes,
		typeReturn: returnType, typeExtra: null, typeFlags: (0 as BitSet<TypeFlag>).incl(TypeFlag.HasAsgn),
		callConv: CallingConvention.CcDefault, attachedOps: [],
	};
}

// Standard reference parity: procedure type literals default to closure calling convention.
// Named function declarations use createFunction which defaults to the default calling convention.
export function createClosureType(paramTypes: Type[], paramNames: string[], returnType: Type): Type {
	const t = createFunction(paramTypes, paramNames, returnType);
	t.callConv = CallingConvention.CcClosure;
	return t;
}

export function closureStorageType(t: Type): Type {
	if (t.kind != TypeKind.Function || t.callConv == CallingConvention.CcClosure) return t;
	const c = createClosureType(t.typeChildren, t.typeNames, t.typeReturn != null ? t.typeReturn : voidType());
	c.typeValue = t.typeValue;
	c.typeFlags = t.typeFlags;
	return c;
}

export function createEnum(name: string, members: string[], values: number[] = []): Type {
	const t = emptyType();
	t.kind = TypeKind.Enum;
	t.typeName = name;
	t.typeNames = members;
	if (values.length > 0) {
		const valTypes: Type[] = [];
		let i = 0;
		while (i < values.length) {
			const vt = emptyType();
			vt.kind = TypeKind.Number;
			vt.typeValue = values[i] as int32;
			valTypes.push(vt);
			i = i + 1;
		}
		t.typeChildren = valTypes;
	}
	return t;
}


// Result<T, E> as a boolean-discriminated match-type internally:
//   `match (ok: boolean) { true => { value: T }, false => { error: E } }`
// Layout is a tagged union — `r.value` is unreachable when !r.ok, and
// `if (r.ok)` narrows the active variant. Codegen lowers via the standard
// `genUnionType` path; member access dispatch in expressions.ms reads
// `r.v0.ok` / `r.v0.value` / `r.v1.error` through the union-overlapping
// memory at the discriminator slot.
//
// `void` type args (`Result<void, E>` for fallible-no-payload calls) leave
// the field with `void` type — codegen filters it out at typedef + hook walk
// to avoid emitting invalid `void value;` declarations.
const _resultParams: Type[] = [createGenericParam("T"), createGenericParam("E")];
const _iteratorResultParam: Type = createGenericParam("T");

export function createResult(okType: Type, errType: Type): Type {
	// Concrete user types live ONLY in typeChildren; the variants keep Result's
	// own parameters until an instance substitutes them by identity, so a user
	// `T` inside `Result<T[], E>` is never confused with Result's `T`.
	const tParam = _resultParams[0];
	const eParam = _resultParams[1];
	const trueVariant = emptyType();
	trueVariant.kind = TypeKind.Struct;
	trueVariant.typeNames = ["ok", "value"];
	trueVariant.typeChildren = [createBooleanLiteral(true), tParam];
	const falseVariant = emptyType();
	falseVariant.kind = TypeKind.Struct;
	falseVariant.typeNames = ["ok", "error"];
	falseVariant.typeChildren = [createBooleanLiteral(false), eParam];
	const base = createUnionInOrder([trueVariant, falseVariant]);
	base.typeName = "Result";
	base.typeExtra = booleanType();
	base.typeNames = ["ok", "true", "false"];
	base.typeFlags = (0 as BitSet<TypeFlag>).incl(TypeFlag.HasAsgn).incl(TypeFlag.Spelled);
	const gi = createGenericInstance(base, [okType, errType]);
	instantiateGenericBody(gi, "T,E");
	return gi;
}

export function createPromise(innerType: Type | null): Type {
	const base = emptyType();
	base.kind = TypeKind.Struct;
	base.typeName = "Promise";
	base.typeNames = [];
	base.typeChildren = [];
	base.typeFlags = (0 as BitSet<TypeFlag>).incl(TypeFlag.Spelled);
	const gi = createGenericInstance(base, [innerType!]);
	instantiateGenericBody(gi, "T");
	return gi;
}

// Affine, scope-bound `Promise<T>` produced by `spawn(...)`. Surface type is
// plain `Promise<T>` — developers never learn a second name. The affine and
// scope-bound semantics ride entirely on typeFlags (AwaitableAffine +
// AwaitableScopeBound), propagated through createGenericInstance onto every
// instance. PARALOCK R1-R6 rules read these via isAffineAwaitable; compat.ms
// implements the implicit upcast to a plain Promise (strips the flags).
export function createSpawnHandle(innerType: Type | null): Type {
	const base = emptyType();
	base.kind = TypeKind.Struct;
	base.typeName = "Promise";
	base.typeNames = [];
	base.typeChildren = [];
	// Flag bits = source of truth for affine + scope-bound semantics.
	// createGenericInstance propagates base.typeFlags onto the produced
	// GenericInstance so isAffineAwaitable(t) can detect spawn-origin Promises
	// anywhere they flow.
	base.typeFlags = (0 as BitSet<TypeFlag>).incl(TypeFlag.AwaitableAffine).incl(TypeFlag.AwaitableScopeBound).incl(TypeFlag.Spelled);
	const gi = createGenericInstance(base, [innerType!]);
	instantiateGenericBody(gi, "T");
	return gi;
}

// Iterator<T> — return type of function* generators. Wraps yield type T.
// At runtime: { next: () => { value: T, done: boolean } }
export function createIteratorResult(yieldType: Type): Type {
	const genericBase = spelled(createStruct("IteratorResult", ["value", "done"], [_iteratorResultParam, createPrimitive(TypeKind.Boolean)], false));
	const gi = createGenericInstance(genericBase, [yieldType]);
	instantiateGenericBody(gi, "T");
	return gi;
}

export function createIterator(yieldType: Type): Type {
	const nextFnType = createClosureType([], [], createIteratorResult(yieldType));
	const iter = spelled(createStruct("Iterator", ["next"], [nextFnType], false));
	return iter;
}

export function isIterator(t: Readonly<Type | null>): boolean {
	if (t == null) return false;
	return t.typeFlags.has(TypeFlag.Spelled) && t.typeName == "Iterator";
}

export function getIteratorNextFnType(t: Type | null): Type | null {
	if (t == null || !isIterator(t)) return null;
	if (t.typeChildren != null && t.typeChildren.length > 0) return t.typeChildren[0];
	return null;
}

export function getIteratorYieldType(t: Type): Type | null;
export function getIteratorYieldType(t: Readonly<Type>): Readonly<Type | null>;
export function getIteratorYieldType(t: Readonly<Type>): Readonly<Type | null> {
	if (t == null) return null;
	// Iterator struct has field "next: () => IteratorResult<T>"
	// IteratorResult has field "value: T" — extract T from there
	if (t.typeChildren != null && t.typeChildren.length > 0) {
		const nextFnType = t.typeChildren[0]; // the next() function type
		if (nextFnType != null && nextFnType.typeReturn != null) {
			const resultType = nextFnType.typeReturn; // IteratorResult<T>
			if (resultType.typeChildren != null && resultType.typeChildren.length > 0) {
				return resultType.typeChildren[0]; // T (the value field)
			}
		}
	}
	return inferredType();
}

export function isResult(t: Readonly<Type | null>): boolean {
	if (t == null) return false;
	if (t.kind == TypeKind.Result) return true;
	return t.kind == TypeKind.GenericInstance && t.typeFlags.has(TypeFlag.Spelled) && t.typeName == "Result";
}

// Result's ok-type / err-type live on the GenericInstance's `typeChildren`
// slots ([T, E] from `Result<T, E>`). The Union body's `typeExtra` carries the
// disc TYPE (`Boolean`) — never the err type — so reading it would be wrong.
// `createResult` always wraps in a GI; `null` returns are for non-Result inputs.
export function getResultOkType(t: Type | null): Type | null {
	if (t == null) return null;
	if (t.kind == TypeKind.GenericInstance && t.typeChildren.length > 0) return t.typeChildren[0];
	return null;
}

export function getResultErrType(t: Type | null): Type | null {
	if (t == null) return null;
	if (t.kind == TypeKind.GenericInstance && t.typeChildren.length > 1) return t.typeChildren[1];
	return null;
}

// =====================================================================
// REPROMISE T1 — Semantic query layer for awaitable types
// =====================================================================
// Single gateway for every question about `Promise<T>` and
// @awaitable-annotated types. Callers never peek at raw storage.
//
// Key design points:
//   - `peelThrough` handles Alias/Distinct wrappers but NOT GenericInstance
//     (for awaitable shape queries, GenericInstance IS the answer).
//   - Surface is a single type name: "Promise". Origin (plain async vs
//     spawn-affine) is distinguished by AwaitableAffine + AwaitableScopeBound
//     flag bits on `typeFlags`.
//   - Future @awaitable-annotated types from stdlib plug in via the registry
//     (T2.6 — currently a stub awaiting collect-pass wiring).
// =====================================================================

// PeelFlag — bitmask controlling which Type wrappers `peelThrough` unwraps.
// Matches the reference `skipTypes` peel mask semantics.
export enum PeelFlag {
	Alias = 1,       // bit 0 — peel TypeKind.Alias
	Distinct = 2,    // bit 1 — peel TypeKind.Distinct
}

export const PEEL_ALIAS: int32 = 1;
export const PEEL_DISTINCT: int32 = 2;
export const PEEL_ALL: int32 = 3;
// Maximum peel depth — guards against malformed cyclic/deeply-nested types.
// 8 covers any realistic chain (Ref<GI<Ref<GI<...>>>> is already 4 levels).
export const PEEL_MAX_DEPTH = 8;

// Universal peeler: strip transparent wrappers per the mask.
// Does NOT peel GenericInstance — for shape queries, GenericInstance IS the answer
// (e.g. Promise<T> is a GenericInstance we want to inspect, not peel past).
// Returns the input unchanged if no layer matches the mask.
export function peelThrough(t: Type, mask: int32): Type | null;
export function peelThrough(t: Readonly<Type>, mask: int32): Readonly<Type | null>;
export function peelThrough(t: Readonly<Type>, mask: int32): Readonly<Type | null> {
	if (t == null) return null;
	let cur = t;
	let _g = 0;
	// Fixed-point loop — keep peeling until no layer matches the mask.
	// Bounded by PEEL_MAX_DEPTH: a cyclic Alias/Distinct chain never reaches a
	// fixpoint (next always differs from cur), so an unbounded loop would spin.
	while (_g < PEEL_MAX_DEPTH) {
		_g = _g + 1;
		let next: Readonly<Type> = cur;
		if (cur.kind == TypeKind.Alias && (mask & PEEL_ALIAS) != 0
			&& cur.typeReturn != null) {
			next = cur.typeReturn;
		} else if (cur.kind == TypeKind.Distinct && (mask & PEEL_DISTINCT) != 0
			&& cur.typeChildren != null && cur.typeChildren.length > 0
			&& cur.typeChildren[0] != null) {
			next = cur.typeChildren[0];
		}
		if (next == cur) return cur;
		cur = next;
	}
	return cur;
}

// isAwaitable — the canonical "can we await this?" question.
// Returns true for `Promise<T>` (plain or affine) and @awaitable-annotated types
// (detected by the AwaitableAffine flag bit set by `createGenericInstance`).
// Peels through Alias wrappers so `type P = Promise<int>; P` still answers true.
export function isAwaitable(t: Readonly<Type | null>): boolean {
	if (t == null) return false;
	const p = peelThrough(t, PEEL_ALIAS);
	if (p == null || p.kind != TypeKind.GenericInstance) return false;
	if (p.typeFlags.has(TypeFlag.Spelled) && p.typeName == "Promise") return true;
	// REPROMISE T2 Stage A: @affineAwaitable-annotated types carry both bits.
	if (p.typeFlags.has(TypeFlag.AwaitableAffine)) return true;
	return false;
}

// awaitedType — the T inside an Awaitable<T>. Returns null for non-awaitables
// or shape-degenerate awaitables (e.g. typeChildren empty).
export function awaitedType(t: Type | null): Type | null;
export function awaitedType(t: Readonly<Type | null>): Readonly<Type | null>;
export function awaitedType(t: Readonly<Type | null>): Readonly<Type | null> {
	if (t == null) return null;
	const p = peelThrough(t, PEEL_ALIAS);
	if (p == null || !isAwaitable(p)) return null;
	if (p.typeChildren != null && p.typeChildren.length > 0) return p.typeChildren[0];
	// Fallback for edge cases where a stub awaitable has no type arg recorded yet.
	return p.typeReturn;
}

export function asyncBodyType(declared: Type): Type {
	return awaitedType(declared) ?? declared;
}

// isAffineAwaitable — an awaitable carrying affine consumption semantics
// (spawn-origin Promises, @affineAwaitable types). Reads the flag bit set by T2.
// Used by PARALOCK R1-R6 affine checker rules.
export function isAffineAwaitable(t: Type | null): boolean {
	if (t == null) return false;
	const p = peelThrough(t, PEEL_ALIAS);
	if (p == null) return false;
	return p.typeFlags.has(TypeFlag.AwaitableAffine);
}

export function createModuleNamespace(modulePath: string): Type {
	const t = emptyType();
	t.kind = TypeKind.Module;
	t.typeName = modulePath;
	return t;
}

export function createTypeRef(name: string): Type {
	const t = emptyType();
	t.kind = TypeKind.TypeReference;
	t.typeName = name;
	return t;
}

export function nullableUnionOf(members: Type[]): Type {
	let sawNull = false;
	const parts: Type[] = [];
	for (const member of members) {
		if (member == null) continue;
		const nested = nestedUnionOf(member);
		const m = nested != null ? nested : peelTransparentInstance(member);
		if (m.kind == TypeKind.Null) { sawNull = true; continue; }
		if (isMaybeType(m) && m.typeReturn != null) {
			sawNull = true;
			parts.push(m.typeReturn);
			continue;
		}
		if (hasNullMember(m)) {
			sawNull = true;
			for (const c of m.typeChildren) {
				if (c != null && c.kind != TypeKind.Null) parts.push(c);
			}
			continue;
		}
		parts.push(m);
	}
	if (!sawNull) return createUnion(members);
	const kept: Type[] = [];
	for (const p of parts) {
		let dup = false;
		for (const k of kept) {
			if (k == p) { dup = true; break; }
		}
		if (!dup) kept.push(p);
	}
	if (kept.length == 0) return nullType();
	foldBooleanLiterals(kept);
	if (kept.length == 1) {
		const only = kept[0];
		if (isMaybeWrappable(only) || only.kind == TypeKind.Union) return createMaybeType(only);
		if (members.length == 2 && members[0] != null && members[0].kind == TypeKind.Null && members[1] == only) {
			return createUnion(members);
		}
		return createUnion([only, nullType()]);
	}
	return createMaybeType(createUnion(kept));
}

export function isNullableShape(members: Type[]): boolean {
	for (const m of members) {
		if (m == null) continue;
		if (m.kind == TypeKind.Null || isMaybeType(m) || hasNullMember(m)) return true;
	}
	return false;
}

function hasNullMember(t: Type): boolean {
	if (t.kind != TypeKind.Union || t.typeChildren == null) return false;
	for (const c of t.typeChildren) {
		if (c != null && c.kind == TypeKind.Null) return true;
	}
	return false;
}

export function createUnion(types: Type[]): Type {
	return buildUnion(types, true);
}

export function createUnionInOrder(types: Type[]): Type {
	return buildUnion(types, false);
}

function nestedUnionOf(t: Type | null): Type | null {
	if (t == null) return null;
	if (t.kind == TypeKind.Union) return t;
	if (t.kind != TypeKind.GenericInstance || !aliasesUnion(t)) return null;
	instantiateGenericBody(t, genericParamsOf(t));
	const seen = peelTransparentInstance(t);
	return seen.kind == TypeKind.Union ? seen : null;
}

function buildUnion(types: Type[], canonical: boolean): Type {
	// Flatten nested unions — `Union(Null, Union(A, B))` becomes `Union(Null, A, B)`.
	// Without flattening, downstream shape checks miss the canonical form and
	// codegen falls back to a literal tagged union.
	let needsFlatten = false;
	for (const ut of types) {
		if (nestedUnionOf(ut) != null || (ut != null && peelTransparentInstance(ut) != ut)) { needsFlatten = true; break; }
	}
	let flat: Type[] = types;
	if (needsFlatten) {
		flat = [];
		for (const ut of types) {
			const nested = nestedUnionOf(ut);
			if (nested != null && nested.typeChildren != null) {
				for (const inner of nested.typeChildren) {
					if (inner != null) flat.push(inner);
				}
			} else if (ut != null) {
				flat.push(peelTransparentInstance(ut));
			}
		}
	}
	// Dedup AFTER flatten — a branch join like `Null` + `Union(Null, Ref<T>)` has
	// distinct top-level antecedents (no top-level dedup possible upstream) but
	// flatten unwraps the inner Null, producing `[Null, Null, Ref<T>]`. Without
	// post-flatten dedup, `unwrapRefNullUnion` and other shape checks miss the
	// canonical 2-variant form and DRC/codegen emit `msUnion_*` for what should
	// collapse to a bare pointer.
	const seen: Type[] = [];
	for (const k of flat) {
		if (k == null) continue;
		let dup = false;
		for (const u of seen) {
			if (u == k) { dup = true; break; }
		}
		if (!dup) seen.push(k);
	}
	if (foldBooleanLiterals(seen) && seen.length == 1) return seen[0];
	if (canonical && !extendsDeclaredSum(types)) sortUnionMembers(seen);
	const t = emptyType();
	t.kind = TypeKind.Union;
	t.typeChildren = seen;
	for (const ut of flat) { propagateToOwner(t, ut); }
	stampInlineDuVariants(seen);
	// Null-extension of a discriminated match-type keeps its disc metadata:
	// `Event | null` must stay recognizable as the DU `Event` plus a null
	// member — flattening used to drop typeNames/typeExtra, so the bridge
	// (unionToAst) handed macros a bare 3-member union and enum-disc DUs
	// became undecodable behind `| null` witnesses. Conditions are strict:
	// exactly ONE flattened source carried metadata, its variants survived
	// dedup index-aligned from 0 (typeNames keys map to variants by index),
	// and every extra member is Null. Anything else (DU | string, two DUs)
	// keeps the unstamped shape.
	if (needsFlatten) {
		let metaSrc: Type | null = null;
		let metaCount = 0;
		for (const ut of types) {
			const nested = nestedUnionOf(ut);
			if (nested != null && nested.typeNames != null && nested.typeNames.length >= 2) {
				metaSrc = nested;
				metaCount += 1;
			}
		}
		if (metaCount == 1 && metaSrc != null && metaSrc.typeChildren != null) {
			const vc = metaSrc.typeChildren.length;
			let aligned = seen.length >= vc;
			if (aligned) {
				for (let vi = 0; vi < vc; vi += 1) {
					if (seen[vi] != metaSrc.typeChildren[vi]) { aligned = false; break; }
				}
			}
			if (aligned) {
				for (let ei = vc; ei < seen.length; ei += 1) {
					if (seen[ei].kind != TypeKind.Null) { aligned = false; break; }
				}
			}
			if (aligned) {
				const names: string[] = [];
				for (const nm of metaSrc.typeNames) { names.push(nm); }
				t.typeNames = names;
				t.typeExtra = metaSrc.typeExtra;
			}
		}
	}
	return t;
}

// `true | false` is `boolean`: both literal members, and a `boolean` beside them, become one
// `boolean` member at the first one's position. Returns whether it folded.
function foldBooleanLiterals(members: Type[]): boolean {
	let sawTrue = false;
	let sawFalse = false;
	for (const m of members) {
		if (m.kind == TypeKind.BooleanLiteral) {
			if (booleanLiteralValue(m)) sawTrue = true;
			else sawFalse = true;
		}
	}
	if (!sawTrue || !sawFalse) return false;
	let kept = 0;
	let placed = false;
	for (let i = 0; i < members.length; i += 1) {
		const m = members[i];
		const isBoolean = m.kind == TypeKind.BooleanLiteral || m.kind == TypeKind.Boolean;
		if (isBoolean && placed) continue;
		members[kept] = isBoolean ? booleanType() : m;
		if (isBoolean) placed = true;
		kept += 1;
	}
	members.shrink(kept);
	return true;
}

function extendsDeclaredSum(types: Type[]): boolean {
	for (const ut of types) {
		if (ut != null && ut.kind == TypeKind.Union && ut.typeNames != null && ut.typeNames.length >= 2) return true;
	}
	return false;
}

export function sortUnionMembers(members: Type[]): void {
	const keys: string[] = [];
	for (const m of members) keys.push(unionMemberKey(m));
	for (let i = 1; i < members.length; i += 1) {
		const m = members[i];
		const k = keys[i];
		let j = i - 1;
		while (j >= 0 && keys[j] > k) {
			members[j + 1] = members[j];
			keys[j + 1] = keys[j];
			j -= 1;
		}
		members[j + 1] = m;
		keys[j + 1] = k;
	}
}

function unionMemberKey(t: Type): string {
	if (t.kind == TypeKind.Null) return "~null";
	let owner: Type | null = t;
	let depth = 0;
	while (owner != null && owner.sym == null && owner.typeReturn != null && depth < PEEL_MAX_DEPTH) {
		owner = owner.typeReturn;
		depth += 1;
	}
	const ownerPath = owner != null && owner.sym != null ? owner.sym.modulePath : "";
	return typeKey(t) + "\u0001" + ownerPath;
}

// DU-variant identity (Nim attachedOps-by-ItemId analog for structural types):
// an INLINE (nameless) struct variant exists only as its union's payload — its
// C storage and lifecycle belong to the DU machinery (<Union>_vN carriers), so
// the analyzer must defer (classify → no RC). Named-alias variants keep their
// own identity and sound named-hook path; do NOT flag them (they double as
// standalone user value types). Separate function on purpose: inlining this
// loop into createUnion hangs the v0.2.24 analyzer on the enlarged var graph.
function stampInlineDuVariants(seen: Type[]): void {
	for (const v of seen) {
		if (v.kind == TypeKind.Struct && v.typeName == "") markDuVariant(v);
	}
}

export function markDuVariant(v: Type): void {
	v.typeFlags = v.typeFlags.incl(TypeFlag.DuVariant);
	duRegAdd(_duVariantRegistry, v);
}

// Registered inline-variant payload types, in registration order. The flag on the
// object is NOT enough downstream: eager per-module imports and exploratory literal
// checks mint structurally-equal COPIES that never pass through createUnion. The
// analyzer resolves identity for those by STRUCTURAL HASH over this registry
// (classify.ms) — the MS-native analog of Nim's single-world ItemId, given the
// intentional per-module type worlds (NIM-REF CK-19).
// NameSet-shaped on purpose: module-scope state must be a struct mutated through
// free functions taking it as a param — a method call directly on a module-level
// array emits broken C (`->push` on msRefArray, moduleless-sym family).
interface DuVariantRegistry {
	items: Type[];
}
let _duVariantRegistry: DuVariantRegistry = { items: [] };
function duRegAdd(reg: DuVariantRegistry, v: Type): void {
	reg.items.push(v);
}
export function duVariantRegistry(): Type[] {
	return _duVariantRegistry.items;
}

export function resetDuVariantRegistry(): void {
	_duVariantRegistry = { items: [] };
}

export function duVariantMark(): int32 {
	return _duVariantRegistry.items.length;
}

export function duVariantsFrom(mark: int32): Type[] {
	const items: Type[] = [];
	for (let i = mark; i < _duVariantRegistry.items.length; i += 1) items.push(_duVariantRegistry.items[i]);
	return items;
}

export function replayDuVariants(items: Type[]): void {
	for (const v of items) {
		if (!_duVariantRegistry.items.includes(v)) duRegAdd(_duVariantRegistry, v);
	}
}

// Find which union variant contains ALL the given field names (and optionally types).
// When fieldTypes is non-empty, also checks type kind to disambiguate variants with
// same field names but different types (e.g., { value: number } vs { value: string }).
// Returns the variant index, or -1 if no variant matches.
export function findUnionVariant(unionType: Readonly<Type | null>, fieldNames: Readonly<string[]>, fieldTypes: Readonly<Type[]>): int32 {
	if (unionType == null || unionType.typeChildren == null || fieldNames.length == 0) return -1;
	const exact = variantHoldingFields(unionType, fieldNames, fieldTypes, true);
	return exact >= 0 ? exact : variantHoldingFields(unionType, fieldNames, fieldTypes, false);
}

function variantHoldingFields(unionType: Readonly<Type>, fieldNames: Readonly<string[]>, fieldTypes: Readonly<Type[]>, exact: boolean): int32 {
	let vi = 0;
	while (vi < unionType.typeChildren.length) {
		const variant = peelToStruct(unionType.typeChildren[vi]);
		if (variant != null && variant.typeNames != null && variant.typeNames.length >= fieldNames.length
				&& (!exact || variant.typeNames.length == fieldNames.length)) {
			let allFound = true;
			let ti = 0;
			while (ti < fieldNames.length) {
				let found = false;
				let fi = 0;
				while (fi < variant.typeNames.length) {
					if (variant.typeNames[fi] == fieldNames[ti]) {
						// When fieldTypes provided, match by type compatibility to disambiguate
						// variants with same field names but different types.
						// Reference parity: subtype check, not exact equality.
						if (fieldTypes.length > ti && fi < variant.typeChildren.length) {
							if (typesCompatibleForVariant(variant.typeChildren[fi], fieldTypes[ti])) {
								found = true;
							}
						} else {
							found = true;
						}
						fi = variant.typeNames.length;
					}
					fi = fi + 1;
				}
				if (!found) {
					allFound = false;
					ti = fieldNames.length;
				}
				ti = ti + 1;
			}
			if (allFound) return vi;
		}
		vi = vi + 1;
	}
	return -1;
}

// Compatible type matching for union variant field disambiguation.
// Reference parity: subtype checking for object fields.
// We check type-class compatibility: all numerics match, all strings match,
// all ref/ptr types match, exact kind for everything else.
function typesCompatibleForVariant(formal: Readonly<Type>, actual: Readonly<Type>): boolean {
	if (formal == null || actual == null) return false;
	if (formal.kind == actual.kind) return true;
	// Numeric family: number, int8-int64, uint8-uint64, float32, float64
	if (isNumeric(formal) && isNumeric(actual)) return true;
	// Reference family: Ref, Ptr, Borrow all compatible
	if ((formal.kind == TypeKind.Ref || formal.kind == TypeKind.Ptr || formal.kind == TypeKind.Borrow)
		&& (actual.kind == TypeKind.Ref || actual.kind == TypeKind.Ptr || actual.kind == TypeKind.Borrow)) return true;
	return false;
}

// Check if a name-only matched variant is ambiguous (another variant has the same field names).
// When ambiguous, we need property types to disambiguate (e.g. { value: number } vs { value: string }).
export function isAmbiguousVariant(unionType: Type | null, matchedIdx: number, fieldNames: string[]): boolean {
	if (unionType == null || unionType.typeChildren == null) return false;
	let vi = 0;
	while (vi < unionType.typeChildren.length) {
		if (vi != matchedIdx) {
			const variant = peelToStruct(unionType.typeChildren[vi]);
			if (variant != null && variant.typeNames != null && variant.typeNames.length >= fieldNames.length) {
				let allFound = true;
				let ti = 0;
				while (ti < fieldNames.length) {
					let found = false;
					let fi = 0;
					while (fi < variant.typeNames.length) {
						if (variant.typeNames[fi] == fieldNames[ti]) { found = true; fi = variant.typeNames.length; }
						fi = fi + 1;
					}
					if (!found) { allFound = false; ti = fieldNames.length; }
					ti = ti + 1;
				}
				if (allFound) return true;
			}
		}
		vi = vi + 1;
	}
	return false;
}

// Find a field's type within a single variant struct. Returns null if not found.
export function findFieldInVariant(variant: Type, fieldName: string): Type | null;
export function findFieldInVariant(variant: Readonly<Type>, fieldName: string): Readonly<Type | null>;
export function findFieldInVariant(variant: Readonly<Type>, fieldName: string): Readonly<Type | null> {
	// Peel Ref/Ptr — interface-typed variants are Ref<Struct> in the C backend.
	const v = peelToStruct(variant);
	if (v == null || v.typeNames == null) return null;
	let i = 0;
	while (i < v.typeNames.length) {
		if (v.typeNames[i] == fieldName && i < v.typeChildren.length) {
			return v.typeChildren[i];
		}
		i = i + 1;
	}
	return null;
}

export function unionVariantHasProperty(t: Type | null, name: string): boolean {
	if (t == null || t.kind != TypeKind.Union || t.typeChildren == null) return false;
	for (const variant of t.typeChildren) {
		if (variant == null) continue;
		if (findFieldInVariant(variant, name) != null) return true;
	}
	return false;
}

// Check if a union type is a discriminated union (has discriminant metadata).
// Discriminated unions have typeExtra (enum type) and typeNames[0] (discriminant field name).
export function isDiscriminatedUnion(t: Readonly<Type | null>): boolean {
	if (t == null) return false;
	return t.kind == TypeKind.Union && t.typeExtra != null && t.typeNames != null && t.typeNames.length > 0;
}

// Get the discriminant field name from a discriminated union.
export function getDiscriminantName(t: Readonly<Type | null>): string {
	if (t == null) return "";
	if (t.typeNames != null && t.typeNames.length > 0) return t.typeNames[0];
	return "";
}

// Tier 2: detect if a Union type has a discriminant field matching `fieldName`.
// Returns { isStringDU, discField } — the caller can use these to pick the right
// variant-finding function (findVariantByEnumMember vs findVariantByStringDiscriminant).
// Checks enum-based DUs first, then string-literal DUs.
export interface DiscriminantInfo {
	isStringDU: boolean;
	discField: string;
}

export function detectUnionDiscriminant(unionType: Type | null, fieldName: string): DiscriminantInfo {
	if (isDiscriminatedUnion(unionType) && getDiscriminantName(unionType) == fieldName) {
		return { isStringDU: false, discField: fieldName };
	}
	if (unionType != null && unionType.kind == TypeKind.Union) {
		const sdf = findSharedStringDiscriminant(unionType);
		if (sdf != "" && sdf == fieldName) {
			return { isStringDU: true, discField: sdf };
		}
	}
	return { isStringDU: false, discField: "" };
}

// Find variant index by field name, peeling Ref/Ptr per variant to reach the
// underlying Struct. Returns the first variant containing the field, or -1.
//
// Caller must establish DU context FIRST — typically by checking
// `isRealDiscriminatedUnion` (codegen) or `narrowingObjType.kind === Union`
// after `peelToStructOrUnion`. Without that gate, calling on `T | null`
// (nullable) patterns would erroneously match the Ref variant's fields.
let _fvbCount: float64 = 0;
let _queryProfilingEnabled = true;
let _queryCachesReadOnly = false;
export function setConcurrentTypeQueries(enabled: boolean): void {
	_queryProfilingEnabled = !enabled;
	_queryCachesReadOnly = enabled;
}
export function findVariantByFieldNameProfile(): float64[] { return [_fvbCount]; }
export function findVariantByFieldName(unionType: Readonly<Type | null>, fieldName: string): int32 {
	if (!_queryProfilingEnabled) return findVariantByFieldNameInner(unionType, fieldName);
	_fvbCount = _fvbCount + 1;
	const r = findVariantByFieldNameInner(unionType, fieldName);
	return r;
}
function findVariantByFieldNameInner(unionType: Readonly<Type | null>, fieldName: string): int32 {
	if (unionType == null || unionType.typeChildren == null) return -1;
	let i = 0;
	while (i < unionType.typeChildren.length) {
		const variant = peelToStruct(unionType.typeChildren[i]);
		if (variant != null && variant.typeNames != null) {
			for (const fn of variant.typeNames) {
				if (fn == fieldName) return i;
			}
		}
		i = i + 1;
	}
	return -1;
}

// Which slot of a union a value belongs in — the checker's half of codegen's
// own rule (expressions.ms, "Variant struct → discriminated union"), so the two
// agree on the tag. Lives here rather than beside its callers because the
// RELATION (compat.isAssignable) and the CONVERSION (fit.widenVariantToUnion,
// fit.widenMaybePayload) must answer identically: a relation that accepts what
// no conversion can build reinterprets silently.
//
// Non-struct member match. Refuses unions with a Null member (those are the
// Maybe/nilable family — synthMaybeWrap and nullableLower own them, and their C
// repr is not a tagged union) and all-string-literal unions (repr = msString).
export function primitiveMemberIndexInUnion(formal: Type, exprType: Type): int32 {
	const hits = primitiveMemberHits(formal, exprType);
	return hits.length == 1 ? hits[0] : -1;
}

// Every member a non-struct value matches; more than one is ambiguous.
export function primitiveMemberHits(formal: Type, exprType: Type): int32[] {
	const hits: int32[] = [];
	if (formal.kind != TypeKind.Union || formal.typeChildren == null) return hits;
	const ek = exprType.kind;
	const carried = literalUnionBase(exprType) != null;
	if (ek == TypeKind.Struct || (ek == TypeKind.Union && !carried) || ek == TypeKind.Null) return hits;
	for (const child of formal.typeChildren) {
		if (child == null || child.kind == TypeKind.Null) return hits;
	}
	if (literalUnionBase(formal) != null) return hits;
	if (ek == TypeKind.String || ek == TypeKind.StringLiteral || ek == TypeKind.NumberLiteral || carried) {
		const slot = literalSlotOf(formal, exprType);
		if (slot >= 0) hits.push(slot);
		return hits;
	}
	let vi: int32 = 0;
	for (const child of formal.typeChildren) {
		let hit = child == exprType;
		if (!hit && child.kind != TypeKind.Struct && child.kind != TypeKind.Ref) hit = child.kind == ek;
		if (hit) hits.push(vi);
		vi += 1;
	}
	return hits;
}

function literalSlotOf(formal: Type, value: Type): int32 {
	const base = literalBase(value);
	let slot: int32 = -1;
	let wide = false;
	for (let i: int32 = 0; i < formal.typeChildren.length; i += 1) {
		const child = formal.typeChildren[i];
		if (literalBase(child).kind != base.kind) continue;
		if (slot < 0) slot = i;
		if (child.kind == base.kind) wide = true;
	}
	if (slot < 0 || wide) return slot;
	if (value.kind == base.kind) return -1;
	const literals = value.kind == TypeKind.Union ? value.typeChildren : [value];
	for (const lit of literals) {
		let held = false;
		for (const child of formal.typeChildren) {
			if (child.kind == lit.kind && child.typeName == lit.typeName) held = true;
		}
		if (!held) return -1;
	}
	return slot;
}

// Layout name for prefix/field signatures: literal types collapse to their base
// (a "a" vs "b" string-literal discriminant is the SAME msString layout), while
// genuinely different widths (int16 vs int32) stay distinct.
function duLayoutName(t: Type | null): string {
	if (t == null) return "?";
	return match (t.kind) {
		TypeKind.StringLiteral => "string",
		TypeKind.BooleanLiteral => "boolean",
		TypeKind.NumberLiteral => duLayoutName(numberLiteralBase(t)),
		TypeKind.EnumLiteral => t.typeName,
		_ => typeDisplayName(t),
	};
}

// C lays each variant's fields sequentially inside the overlapping union, so a
// field name shared across variants reads correctly by name ONLY when every
// declaring variant lays it out identically: same field-layout prefix before it
// (identical prefix ⇒ identical offset, padding included) AND the same field
// layout itself (same offset + different width still misreads). Returns true when
// the layout signatures differ — such an access is unsound without narrowing.
export function duSharedFieldOffsetDiffers(unionType: Type | null, fieldName: string): boolean {
	if (unionType == null || unionType.typeChildren == null) return false;
	let firstSig = "";
	let found = 0;
	for (let i = 0; i < unionType.typeChildren.length; i += 1) {
		const variant = peelToStruct(unionType.typeChildren[i]);
		if (variant == null || variant.typeNames == null) continue;
		let sig = "";
		let hasField = false;
		for (let fi = 0; fi < variant.typeNames.length; fi += 1) {
			const ft = fi < variant.typeChildren.length ? variant.typeChildren[fi] : null;
			if (!storesNothing(variant, ft)) sig = sig + "|" + duLayoutName(ft);
			if (variant.typeNames[fi] == fieldName) { hasField = true; break; }
		}
		if (!hasField) continue;
		if (found == 0) {
			firstSig = sig;
		} else if (sig != firstSig) {
			return true;
		}
		found += 1;
	}
	return false;
}

// A field read off a union without narrowing is sound only when EVERY variant
// declares it with an identical layout prefix. `duSharedFieldOffsetDiffers`
// never fires for a field that a strict SUBSET of variants declares (a
// single-variant field meets no conflicting signature), yet reading such a
// field routes the access to a slot of the declaring variant while another
// variant may be active — reinterpreted bytes, no runtime check. Maybe unions
// (payload | null) are exempt: the null side carries no fields and payload
// reads are governed by the null-check narrowing paths instead.
export function duFieldRequiresNarrowing(unionType: Type | null, fieldName: string): boolean {
	if (unionType == null || unionType.typeChildren == null) return false;
	if (unwrapRefNullUnion(unionType) != null) return false;
	if (duSharedFieldSlotDiffers(unionType, fieldName)) return true;
	let firstSig = "";
	let found = 0;
	let variants = 0;
	for (let i = 0; i < unionType.typeChildren.length; i += 1) {
		const variant = peelToStruct(unionType.typeChildren[i]);
		if (variant == null || variant.typeNames == null) return true;
		variants += 1;
		let sig = "";
		let hasField = false;
		for (let fi = 0; fi < variant.typeNames.length; fi += 1) {
			const ft = fi < variant.typeChildren.length ? variant.typeChildren[fi] : null;
			if (!storesNothing(variant, ft)) sig = sig + "|" + duLayoutName(ft);
			if (variant.typeNames[fi] == fieldName) { hasField = true; break; }
		}
		if (!hasField) continue;
		if (found == 0) {
			firstSig = sig;
		} else if (sig != firstSig) {
			return true;
		}
		found += 1;
	}
	if (found == 0) return false;
	return found < variants;
}

export function literalTagDiscriminant(unionType: Type | null): string {
	if (unionType == null || unionType.typeChildren == null) return "";
	if (isDiscriminatedUnion(unionType)) {
		const dt = unionType.typeExtra;
		return dt != null && (dt.kind == TypeKind.Boolean || dt.kind == TypeKind.String || dt.kind == TypeKind.Enum) ? getDiscriminantName(unionType) : "";
	}
	const strDisc = findSharedStringDiscriminant(unionType);
	if (strDisc != "") return strDisc;
	const boolDisc = findSharedBooleanDiscriminant(unionType);
	return boolDisc != "" ? boolDisc : findSharedEnumDiscriminant(unionType);
}

export function duSharedFieldSlotDiffers(unionType: Type | null, fieldName: string): boolean {
	if (unionType == null || unionType.typeChildren == null) return false;
	let firstInline = -1;
	for (const member of unionType.typeChildren) {
		const variant = peelToStruct(member);
		if (variant == null || variant.typeNames == null || !variant.typeNames.includes(fieldName)) continue;
		const inline = inlineVariantStruct(member) != null ? 1 : 0;
		if (firstInline < 0) {
			firstInline = inline;
		} else if (inline != firstInline) {
			return literalTagDiscriminant(unionType) != fieldName;
		}
	}
	return false;
}

// The member of `enumT` a discriminated union's variant key names; the key is
// the member as the declaration spelled it, bare or qualified by its enum.
export function variantKeyMember(enumT: Readonly<Type>, key: string): int32 {
	return enumT.typeNames.indexOf(bareAfterDelim(key, ".")) as int32;
}

// The enum literal an expression denotes: the checked member reference carries it
// on its Symbol, or as its own type where the context asked for the literal.
export function enumMemberLiteralOf(node: Node | null): Type | null {
	if (node == null) return null;
	const sym = node.resolvedSym;
	if (sym != null && sym.symbolKind == SymbolKind.EnumMember && isEnumLiteral(sym.symbolType)) return sym.symbolType;
	return isEnumLiteral(node.nodeType) ? node.nodeType : null;
}

// Tier 2: detect a string-literal discriminant field shared by every variant of the union.
// A discriminant field must:
//   - be present on every variant
//   - have a distinct StringLiteral type in each variant (so we can disambiguate)
// Returns the field name, or "" if no such field exists.

// Preference order: first matching field encountered in variant 0.
// Peel Ref/Ptr wrapper to reach the underlying Struct so variant field walks
// work for interface-typed variants (interface = Ref<Struct> in the C backend).
// Returns the original type if it's already a Struct or has no peelable wrapper.
export function peelToStruct(t: Type | null): Type | null;
export function peelToStruct(t: Readonly<Type | null>): Readonly<Type | null>;
export function peelToStruct(t: Readonly<Type | null>): Readonly<Type | null> {
	if (t == null) return null;
	let cur: Readonly<Type> = t;
	let _g = 0;
	while (cur != null && _g < PEEL_MAX_DEPTH) {
		_g = _g + 1;
		if (cur.kind == TypeKind.Struct) return cur;
		if ((cur.kind == TypeKind.Ref || cur.kind == TypeKind.Ptr || cur.kind == TypeKind.Alias) && cur.typeReturn != null) {
			cur = cur.typeReturn;
			continue;
		}
		break;
	}
	return cur;
}

export function inlineVariantStruct(member: Type | null): Type | null;
export function inlineVariantStruct(member: Readonly<Type | null>): Readonly<Type | null>;
export function inlineVariantStruct(member: Readonly<Type | null>): Readonly<Type | null> {
	let cur = member;
	let _g = 0;
	while (cur != null && cur.kind == TypeKind.Alias && cur.typeReturn != null && _g < PEEL_MAX_DEPTH) {
		_g = _g + 1;
		cur = cur.typeReturn;
	}
	return cur != null && cur.kind == TypeKind.Struct ? cur : null;
}

export function storesNothing(owner: Readonly<Type>, field: Readonly<Type | null>): boolean {
	if (field == null) return false;
	if (field.kind == TypeKind.Void) return true;
	return (field.kind == TypeKind.BooleanLiteral || field.kind == TypeKind.EnumLiteral)
		&& owner.kind == TypeKind.Struct && owner.typeFlags.has(TypeFlag.DuVariant);
}

// Peel Ref/Ptr/GenericInstance wrappers until reaching a Struct or Union body.
// Used by checkers and codegen for generic match-type aliases like
// `MyResult<T, E> = Ref<MyData<T, E>>` where the chain is GI → Ref → GI → Union.
// Returns the original type if no peelable wrapper exists. Bounded by
// `PEEL_MAX_DEPTH` against pathological cyclic types.
export function peelToStructOrUnion(t: Type | null): Type | null;
export function peelToStructOrUnion(t: Readonly<Type | null>): Readonly<Type | null>;
export function peelToStructOrUnion(t: Readonly<Type | null>): Readonly<Type | null> {
	if (t == null) return null;
	let cur: Readonly<Type> = t;
	let _g = 0;
	while (cur != null && _g < PEEL_MAX_DEPTH) {
		_g = _g + 1;
		if (cur.kind == TypeKind.Struct || cur.kind == TypeKind.Union) return cur;
		if ((cur.kind == TypeKind.Ref || cur.kind == TypeKind.Ptr || cur.kind == TypeKind.Cursor || cur.kind == TypeKind.Alias) && cur.typeReturn != null) {
			cur = cur.typeReturn;
			continue;
		}
		if (cur.kind == TypeKind.GenericInstance) {
			if (cur.typeReturn != null) {
				cur = cur.typeReturn;
				continue;
			}
			if (cur.typeExtra != null) {
				cur = cur.typeExtra;
				continue;
			}
		}
		break;
	}
	return cur;
}

export function positionalFieldsOf(t: Type | null): Type | null {
	const gi = t != null && t.kind == TypeKind.Ref ? t.typeReturn : t;
	if (gi != null && gi.kind == TypeKind.GenericInstance) instantiateGenericBody(gi, genericParamsOf(gi));
	const body = peelToStructOrUnion(t);
	return body != null && body.kind == TypeKind.Struct && body.typeNames != null ? body : null;
}

export function instantiatedUnionBehind(t: Type): Type {
	if (t.kind == TypeKind.GenericInstance) instantiateGenericBody(t, genericParamsOf(t));
	return matchUnionBehindInstance(t);
}

export function matchUnionBehindInstance(t: Type): Type;
export function matchUnionBehindInstance(t: Readonly<Type>): Readonly<Type>;
export function matchUnionBehindInstance(t: Readonly<Type>): Readonly<Type> {
	if (t.kind != TypeKind.GenericInstance) return t;
	if (t.typeReturn == null) {
		if (_queryCachesReadOnly && pendingBody(t, genericParamsOf(t))) throw new Error(`internal: generic instance '${typeDisplayName(t)}' reached emission without its body`);
		return t;
	}
	const u = peelToStructOrUnion(t);
	return u != null && u.kind == TypeKind.Union ? u : t;
}

// A generic instantiation whose body has no nominal Struct/Union carries no
// identity of its own: `type Brand<T> = T` means `Brand<number>` IS number.
// Reference parity: ccgtypes.nim `irrelevantForBackend` + getSimpleTypeDesc
// `of tyGenericInst: skipModifier typ`.
function isUnionAlias(nominal: Readonly<Type | null>): boolean {
	return nominal != null && nominal.kind == TypeKind.Union && !isDiscriminatedUnion(nominal)
		&& nominal.sym != null && nominal.sym.symbolKind == SymbolKind.TypeAlias;
}

function aliasesUnion(gi: Readonly<Type>): boolean {
	return isUnionAlias(peelToStructOrUnion(gi.typeExtra));
}

export function peelTransparentInstance(t: Type): Type;
export function peelTransparentInstance(t: Readonly<Type>): Readonly<Type>;
export function peelTransparentInstance(t: Readonly<Type>): Readonly<Type> {
	let cur: Readonly<Type> = t;
	let _g = 0;
	while (_g < PEEL_MAX_DEPTH) {
		_g = _g + 1;
		if (cur.kind != TypeKind.GenericInstance) return cur;
		if (cur.typeReturn == null) {
			if (_queryCachesReadOnly && pendingBody(cur, genericParamsOf(cur))) throw new Error(`internal: generic instance '${typeDisplayName(cur)}' reached emission without its body`);
			return cur;
		}
		if (cur.typeExtra != null && cur.typeExtra.kind == TypeKind.Distinct) return cur;
		const nominal = peelToStructOrUnion(cur.typeExtra);
		if (aliasesUnion(cur)
			&& ((cur.typeReturn.kind == TypeKind.Union && hasTypeIdentity(cur.typeReturn)) || isMaybeType(cur.typeReturn))) return cur.typeReturn;
		if (nominal != null
			&& (nominal.kind == TypeKind.Struct || nominal.kind == TypeKind.Union)) return cur;
		cur = cur.typeReturn;
	}
	return cur;
}

// Detect a literal-typed discriminant field shared by every variant. Variants
// must each have the SAME field name with the requested `literalKind` type
// and DISTINCT values (different `typeName` strings). Returns the field name
// or "" when no such discriminator exists.
//
// Single implementation backs both `findSharedStringDiscriminant` (for
// `kind: "circle" | "square"`) and `findSharedBooleanDiscriminant` (for
// `ok: true | false`). Variants are peeled through `Ref`/`Ptr` so interface-
// typed variants (`Ref<Struct>` in the C backend) work the same as bare
// anonymous structs.
// The VALUE a literal type stands for. StringLiteral/BooleanLiteral keep it in
// `typeName`; an EnumLiteral's `typeName` is the ENUM's name (shared by every
// variant) with the member in `typeNames[0]`, so comparing `typeName` there
// would read every variant as the same value.
function literalDiscValue(t: Readonly<Type | null>): string {
	if (t == null) return "";
	if (t.kind == TypeKind.EnumLiteral) {
		return t.typeNames != null && t.typeNames.length > 0 ? t.typeName + "." + t.typeNames[0] : t.typeName;
	}
	return t.typeName;
}

function findSharedLiteralDiscriminant(unionType: Readonly<Type | null>, literalKind: TypeKind): string {
	if (unionType == null || unionType.typeChildren == null || unionType.typeChildren.length < 2) return "";
	const variants = unionType.typeChildren;
	const first = peelToStruct(variants[0]);
	if (first == null || first.typeNames == null) return "";
	for (let fi = 0; fi < first.typeNames.length; fi += 1) {
		if (fi >= first.typeChildren.length) continue;
		const firstFt = first.typeChildren[fi];
		if (firstFt == null || firstFt.kind != literalKind) continue;
		const candidateName = first.typeNames[fi];
		// Check every other variant has this field as the same literal kind with a
		// *different* value (so the discriminator can disambiguate variants).
		let sharedOk = true;
		const seen: string[] = [literalDiscValue(firstFt)];
		for (let vi = 1; vi < variants.length; vi += 1) {
			const v = peelToStruct(variants[vi]);
			if (v == null || v.typeNames == null) { sharedOk = false; break; }
			let foundInV = false;
			for (let vfi = 0; vfi < v.typeNames.length; vfi += 1) {
				if (v.typeNames[vfi] != candidateName) continue;
				if (vfi >= v.typeChildren.length) break;
				const vft = v.typeChildren[vfi];
				if (vft == null || vft.kind != literalKind) break;
				const vftValue = literalDiscValue(vft);
				let dup = false;
				for (const s of seen) { if (s == vftValue) { dup = true; break; } }
				if (dup) { sharedOk = false; break; }
				seen.push(vftValue);
				foundInV = true;
				break;
			}
			if (!foundInV) { sharedOk = false; break; }
			if (!sharedOk) break;
		}
		if (sharedOk) return candidateName;
	}
	return "";
}

export function findSharedStringDiscriminant(unionType: Readonly<Type | null>): string {
	return findSharedLiteralDiscriminant(unionType, TypeKind.StringLiteral);
}

// Tier 2 (boolean): detect a boolean-literal discriminant shared by every variant.
// Variants must each have the same field name with a BooleanLiteral type and
// distinct values (true vs false).
export function findSharedBooleanDiscriminant(unionType: Readonly<Type | null>): string {
	return findSharedLiteralDiscriminant(unionType, TypeKind.BooleanLiteral);
}

// Tier 2 (enum): a TS-style union whose variants each pin the same field to a
// distinct enum member (`kind: EvKind.Click` | `kind: EvKind.Key`). This is the
// same discriminator the match-type DU form declares — see the auto-stamp in
// resolvePass, which promotes it to the enum DU contract (typeExtra + typeNames).
export function findSharedEnumDiscriminant(unionType: Readonly<Type | null>): string {
	return findSharedLiteralDiscriminant(unionType, TypeKind.EnumLiteral);
}

// The Enum Type behind an enum-literal discriminant field, read off the first
// variant that carries it (EnumLiteral.typeReturn back-references the enum).
export function enumDiscriminantTypeOf(unionType: Type | null, discFieldName: string): Type | null {
	if (unionType == null || unionType.typeChildren == null) return null;
	for (const rawVariant of unionType.typeChildren) {
		const variant = peelToStruct(rawVariant);
		if (variant == null || variant.typeNames == null) continue;
		for (let fi = 0; fi < variant.typeNames.length; fi += 1) {
			if (variant.typeNames[fi] != discFieldName) continue;
			if (fi >= variant.typeChildren.length) break;
			const ft = variant.typeChildren[fi];
			if (ft != null && ft.kind == TypeKind.EnumLiteral) return ft.typeReturn;
			break;
		}
	}
	return null;
}

// Find the variant index whose `discFieldName` field is a literal of the given
// kind with `litValueName` as its `typeName`. Backs both the string and boolean
// variant lookups — both encode the literal value in `Type.typeName`
// (`"circle"`/`"square"` for StringLiteral, `"true"`/`"false"` for
// BooleanLiteral). Returns -1 when no variant matches.
function findVariantByLiteralDiscriminant(unionType: Readonly<Type | null>, discFieldName: string, literalKind: TypeKind, litValueName: string): int32 {
	if (unionType == null || unionType.typeChildren == null) return -1;
	for (let i = 0; i < unionType.typeChildren.length; i += 1) {
		const variant = peelToStruct(unionType.typeChildren[i]);
		if (variant == null || variant.typeNames == null) continue;
		for (let fi = 0; fi < variant.typeNames.length; fi += 1) {
			if (variant.typeNames[fi] != discFieldName) continue;
			if (fi >= variant.typeChildren.length) continue;
			const ft = variant.typeChildren[fi];
			if (ft != null && ft.kind == literalKind && literalDiscValue(ft) == litValueName) {
				return i;
			}
		}
	}
	return -1;
}

// Find variant index by boolean literal discriminator value.
export function findVariantByBooleanDiscriminant(unionType: Readonly<Type | null>, discFieldName: string, litValue: boolean): int32 {
	return findVariantByLiteralDiscriminant(unionType, discFieldName, TypeKind.BooleanLiteral, litValue ? "true" : "false");
}

// Tier 2: collect all string-literal discriminant values from a union's variants.
// Returns ["circle", "square"] for type Shape = {kind:"circle",...} | {kind:"square",...}.
function collectLiteralDiscriminantValues(unionType: Type | null, discFieldName: string, literalKind: TypeKind): string[] {
	const values: string[] = [];
	if (unionType == null || unionType.typeChildren == null) return values;
	for (const rawVariant of unionType.typeChildren) {
		const variant = peelToStruct(rawVariant);
		if (variant == null || variant.typeNames == null) continue;
		for (let fi = 0; fi < variant.typeNames.length; fi += 1) {
			if (variant.typeNames[fi] != discFieldName) continue;
			if (fi >= variant.typeChildren.length) continue;
			const ft = variant.typeChildren[fi];
			if (ft != null && ft.kind == literalKind) {
				values.push(literalDiscValue(ft));
			}
			break;
		}
	}
	return values;
}

export function collectStringDiscriminantValues(unionType: Type | null, discFieldName: string): string[] {
	return collectLiteralDiscriminantValues(unionType, discFieldName, TypeKind.StringLiteral);
}

// Variant keys in `typeChildren` order — the shape typeNames[1..] must carry for
// `variantKeyMember` (dotted `Enum.Member`, same form the match-type DU
// declaration stores).
export function collectEnumDiscriminantValues(unionType: Type | null, discFieldName: string): string[] {
	return collectLiteralDiscriminantValues(unionType, discFieldName, TypeKind.EnumLiteral);
}

// Tier 2: find variant index by scanning variant structs directly for a string-literal
// discriminant field matching `discFieldName` with the given literal value.
// Used when the union is string-literal based (type Shape = {kind:"a",...} | {kind:"b",...})
// and there's no enum-backed discriminant metadata on the union itself.
// Returns -1 if no variant has a StringLiteral field matching the value.
export function findVariantByStringDiscriminant(unionType: Readonly<Type | null>, discFieldName: string, litValue: string): int32 {
	return findVariantByLiteralDiscriminant(unionType, discFieldName, TypeKind.StringLiteral, litValue);
}

// Maybe<T> — Reference: Nim's Option[T] (~/projects/nim/lib/pure/options.nim).
// Wrapper struct { value: T, present: bool } for non-pointer types.
// Ref/Ptr types are inherently nullable (NULL pointer = sentinel) — no wrapper.
// Cached per-inner-type identity.
const _maybeCache: Type[] = [];
const _maybeCacheNames: string[] = [];

// Stable cache key for Maybe<T> dedup. Named types (struct, interface, class,
// generic instances) have a non-empty typeName — use it. Primitives created via
// createPrimitive() have typeName === "" — disambiguate via TypeKind ordinal so
// Maybe<int32> ≠ Maybe<float64> ≠ Maybe<string> etc.
function identSafeKey(s: string): string {
	let out = "";
	let i = 0;
	while (i < s.length) {
		const b = s.byteAt(i);
		const alnum = (b >= "a".code && b <= "z".code) || (b >= "A".code && b <= "Z".code) || (b >= "0".code && b <= "9".code);
		if (alnum) out = out + s.charAt(i);
		i += 1;
	}
	return out + s.length.toString();
}

function hasNominalIdentity(inner: Type): boolean {
	const k = inner.kind;
	return k == TypeKind.Struct || k == TypeKind.Enum || k == TypeKind.Distinct || k == TypeKind.Result;
}

function moduleQualifiedName(inner: Type): string {
	const owner = inner.sym != null ? inner.sym.modulePath : "";
	return owner == "" ? inner.typeName : inner.typeName + "_" + identSafeKey(owner);
}

function maybeCacheKey(inner: Type): string {
	if (inner.kind == TypeKind.StringLiteral) return "sl_" + identSafeKey(inner.typeName);
	if (inner.kind == TypeKind.NumberLiteral) return "nl_" + identSafeKey(inner.typeName);
	if (inner.kind == TypeKind.GenericInstance) return "gi_" + identSafeKey(typeKey(inner));
	if (inner.kind == TypeKind.Set) {
		return inner.typeReturn != null ? "set_" + maybeCacheKey(inner.typeReturn) : "set_any";
	}
	if (inner.typeName != "" && hasNominalIdentity(inner)) return moduleQualifiedName(inner);
	if (literalUnionBase(inner) != null) {
		const members: string[] = [];
		for (const c of inner.typeChildren) {
			if (c != null) members.push(identSafeKey(c.typeName));
		}
		members.sort();
		let key = "slu";
		for (const m of members) key = key + "_" + m;
		return key;
	}
	if (inner.kind == TypeKind.Function) return "fn_" + identSafeKey(typeKey(inner));
	const k = inner.kind;
	if (k == TypeKind.Union || k == TypeKind.Array || k == TypeKind.Tuple || k == TypeKind.Span || k == TypeKind.SizedArray) {
		return "p" + (k as number) + "_" + identSafeKey(typeKey(inner));
	}
	const scalar = k == TypeKind.Number ? TypeKind.Float64 : k;
	return "p" + (scalar as number);
}

export function representedPayload(inner: Type): Type;
export function representedPayload(inner: Readonly<Type>): Readonly<Type>;
export function representedPayload(inner: Readonly<Type>): Readonly<Type> {
	if (inner.kind == TypeKind.StringLiteral) return stringType();
	if (inner.kind == TypeKind.NumberLiteral) return numberLiteralBase(inner);
	return literalUnionBase(inner) ?? inner;
}

export function createMaybeType(inner: Type): Type {
	// Pointer types are inherently nullable — no wrapper needed (reference parity: nullable pointers)
	if (inner.kind == TypeKind.Ref || inner.kind == TypeKind.Ptr) return inner;
	const key = maybeCacheKey(inner);
	let i = 0;
	while (i < _maybeCacheNames.length) {
		if (_maybeCacheNames[i] == key) {
			if (maybePayloadIs(_maybeCache[i], inner)) return _maybeCache[i];
			break;
		}
		i += 1;
	}
	const t = emptyType();
	t.kind = TypeKind.Struct;
	t.typeName = "Maybe_" + maybeCacheKey(representedPayload(inner));
	t.typeNames = ["value", "present"];
	t.typeChildren = [inner, booleanType()];
	t.typeFlags = (0 as BitSet<TypeFlag>).incl(TypeFlag.IsStruct).incl(TypeFlag.IsMaybe).incl(TypeFlag.Spelled);
	t.typeReturn = inner;    // store inner type for unwrapping
	propagateToOwner(t, inner);
	if (!_queryCachesReadOnly) {
		if (i < _maybeCacheNames.length) {
			_maybeCache[i] = t;
		} else {
			_maybeCache.push(t);
			_maybeCacheNames.push(key);
		}
	}
	return t;
}

function maybePayloadIs(cached: Type, inner: Type): boolean {
	return sameDeclarationsIn(cached.typeReturn, inner, 0);
}

function sameDeclarationsIn(a: Type | null, b: Type | null, depth: int32): boolean {
	if (a == null || b == null || a == b || depth > 4) return true;
	if (a.sym != null && b.sym != null) return a.sym == b.sym;
	if (a.kind == TypeKind.GenericInstance && a.typeExtra != null && b.typeExtra != null
		&& !sameDeclarationsIn(unwrapRefBase(a.typeExtra), unwrapRefBase(b.typeExtra), depth + 1)) return false;
	if (!sameDeclarationsIn(a.typeReturn, b.typeReturn, depth + 1)) return false;
	const n = a.typeChildren.length < b.typeChildren.length ? a.typeChildren.length : b.typeChildren.length;
	for (let i = 0; i < n; i += 1) {
		if (!sameDeclarationsIn(a.typeChildren[i], b.typeChildren[i], depth + 1)) return false;
	}
	return true;
}

export function createRef(inner: Type | null): Type {
	const t = emptyType();
	t.kind = TypeKind.Ref;
	t.typeReturn = inner;
	t.typeFlags = (0 as BitSet<TypeFlag>).incl(TypeFlag.HasAsgn);
	return t;
}

export function createArc(inner: Type | null): Type {
	const t = emptyType();
	t.kind = TypeKind.Ref;
	t.typeReturn = inner;
	t.typeFlags = (0 as BitSet<TypeFlag>).incl(TypeFlag.HasAsgn).incl(TypeFlag.IsAtomic);
	return t;
}

export function isAtomicRef(t: Readonly<Type | null>): boolean {
	return t != null && t.kind == TypeKind.Ref && t.typeFlags.has(TypeFlag.IsAtomic);
}

export function isValuePointee(pointee: Readonly<Type>): boolean {
	if (pointee.kind == TypeKind.Void) return false;
	if (pointee.kind == TypeKind.Struct || pointee.kind == TypeKind.GenericInstance) {
		const decl = pointee.kind == TypeKind.GenericInstance && pointee.typeExtra != null ? pointee.typeExtra : pointee;
		return decl.sym != null && decl.sym.symbolKind == SymbolKind.Struct;
	}
	return pointee.kind != TypeKind.Array && pointee.kind != TypeKind.Function;
}

// Locked<T> (PARALOCK I22) — the one sanctioned shared-mutable cell. ONE
// allocation: atomic-rc header + inline ticket lock + typed payload, so the
// handle IS an atomic Ref and every mechanism Arc already drives (atomic
// incref/decref in classify, the boundary incref at the msgSetter, the
// write-block) applies unchanged. The pointee is a generated struct whose two
// leading int32 fields ARE the ticket lock: they sit at offset 0, so the
// runtime's acquire/release cast the handle straight to msTicketLock* and need
// no knowledge of T. The payload is reached only through the load/store
// intercepts, which read the field offset off this same struct.
export function lockedCellName(payload: Type | null): string {
	return "msLockedCell_" + _stdHashToBase36(payload != null ? typeKey(payload) : "void");
}

export function createLockedCell(payload: Type | null): Type {
	return spelled(createStruct(lockedCellName(payload),
		["lockNext", "lockServing", "value"],
		[getSysType(TypeKind.Int32), getSysType(TypeKind.Int32), payload!], true));
}

export function createLocked(payload: Type | null): Type {
	const t = emptyType();
	t.kind = TypeKind.Ref;
	t.typeReturn = createLockedCell(payload);
	t.typeFlags = (0 as BitSet<TypeFlag>).incl(TypeFlag.HasAsgn).incl(TypeFlag.IsAtomic).incl(TypeFlag.IsLocked);
	return t;
}

export function isSendableFunction(t: Readonly<Type | null>): boolean {
	return t != null && t.kind == TypeKind.Function && t.typeFlags.has(TypeFlag.IsSendable);
}

export function createSendable(fn: Type): Type {
	if (isSendableFunction(fn)) return fn;
	const c = copyTypeShallow(fn);
	c.typeFlags = c.typeFlags.incl(TypeFlag.IsSendable);
	return c;
}

export function isLockedRef(t: Readonly<Type | null>): boolean {
	return t != null && t.kind == TypeKind.Ref && t.typeFlags.has(TypeFlag.IsLocked);
}

export function isReadonlyView(t: Readonly<Type | null>): boolean {
	if (t == null) return false;
	if (t.kind != TypeKind.Ref && t.kind != TypeKind.Array && t.kind != TypeKind.Span
		&& t.kind != TypeKind.Ptr && t.kind != TypeKind.Struct && t.kind != TypeKind.Union
		&& t.kind != TypeKind.Unknown && t.kind != TypeKind.GenericParam) return false;
	return t.typeFlags.has(TypeFlag.IsReadonly);
}

export function copyTypeShallow(t: Type): Type {
	const c = emptyType();
	c.kind = t.kind;
	c.typeName = t.typeName;
	c.typeNames = t.typeNames;
	c.typeChildren = t.typeChildren;
	c.typeReturn = t.typeReturn;
	c.typeExtra = t.typeExtra;
	c.typeFlags = t.typeFlags;
	c.callConv = t.callConv;
	c.attachedOps = t.attachedOps;
	c.sym = t.sym;
	c.optionalFields = t.optionalFields;
	return c;
}

function isPodFieldType(t: Type | null, depth: int32): boolean {
	if (t == null) return true;
	if (isNumeric(t)) return true;
	return match (t.kind) {
		TypeKind.BigInt | TypeKind.Boolean | TypeKind.BooleanLiteral | TypeKind.NumberLiteral | TypeKind.Char
			| TypeKind.String | TypeKind.StringLiteral | TypeKind.CString
			| TypeKind.Enum | TypeKind.EnumLiteral | TypeKind.Void | TypeKind.Null => true,
		TypeKind.Distinct | TypeKind.SizedArray => isPodFieldType(t.typeReturn, depth + 1),
		TypeKind.Ref => isAtomicRef(t),
		TypeKind.Struct | TypeKind.Union => !structCarriesRef(t, depth + 1),
		_ => false,
	};
}

function structCarriesRef(t: Type, depth: int32): boolean {
	if (depth > 8 || t.typeChildren == null) return false;
	for (const ft of t.typeChildren) {
		if (!isPodFieldType(ft, depth)) return true;
	}
	return false;
}

export function typeCarriesRef(t: Type | null): boolean {
	return !isPodFieldType(t, 0);
}

export function isSharedGraphType(t: Type | null): boolean {
	if (t == null) return false;
	let base = t;
	if (base.kind == TypeKind.Union && base.typeChildren.length == 2) {
		const a = base.typeChildren[0];
		const b = base.typeChildren[1];
		if (a != null && a.kind == TypeKind.Null && b != null) base = b;
		else if (b != null && b.kind == TypeKind.Null && a != null) base = a;
	}
	if (base.kind == TypeKind.Ref && base.typeReturn != null) base = base.typeReturn;
	if (base.kind == TypeKind.Array) return isSharedGraphType(base.typeReturn);
	return isMetaGraphRoot(base, "Type") || isMetaGraphRoot(base, "Symbol");
}

export function isNodeGraphType(t: Type | null): boolean {
	if (t == null) return false;
	let base = t;
	if (base.kind == TypeKind.Union && base.typeChildren.length == 2) {
		const a = base.typeChildren[0];
		const b = base.typeChildren[1];
		if (a != null && a.kind == TypeKind.Null && b != null) base = b;
		else if (b != null && b.kind == TypeKind.Null && a != null) base = a;
	}
	if (base.kind == TypeKind.Array) return isNodeGraphType(base.typeReturn);
	if (base.kind == TypeKind.Ref && base.typeReturn != null) base = base.typeReturn;
	return isMetaGraphRoot(base, "Node");
}

let _metaGraphModule = "";

function isMetaGraphRoot(t: Type, name: string): boolean {
	if (t.sym == null || t.sym.name != name) return false;
	if (_metaGraphModule == "") _metaGraphModule = normalize(join(resolveRuntimeDir(), "std/meta/node.ms"));
	return normalize(t.sym.modulePath) == _metaGraphModule;
}

export function propagateReadonlyView(t: Type | null): Type {
	return createReadonlyView(t);
}

export function createReadonlyView(t: Type | null): Type {
	if (t == null) return null as unknown as Type;
	if (isReadonlyView(t)) return t;
	if (t.readonlyView != null) return t.readonlyView;
	const viewable = t.kind == TypeKind.Array || t.kind == TypeKind.Unknown || t.kind == TypeKind.Span || t.kind == TypeKind.GenericParam
		|| t.kind == TypeKind.Ptr || (t.kind == TypeKind.Ref && !isAtomicRef(t))
		|| ((t.kind == TypeKind.Struct || t.kind == TypeKind.Union) && structCarriesRef(t, 0));
	if (!viewable) return t;
	const c = copyTypeShallow(t);
	c.typeFlags = c.typeFlags.incl(TypeFlag.IsReadonly);
	if (t.kind == TypeKind.Union) c.typeChildren = t.typeChildren.map((m) => createReadonlyView(m));
	c.mutableView = t;
	t.readonlyView = c;
	return c;
}

export function withoutReadonlyView(t: Type | null): Type {
	if (t == null) return null as unknown as Type;
	if (!isReadonlyView(t)) return t;
	if (t.mutableView != null) return t.mutableView;
	const c = copyTypeShallow(t);
	c.typeFlags = c.typeFlags.excl(TypeFlag.IsReadonly);
	c.readonlyView = t;
	t.mutableView = c;
	return c;
}

export function isViewKind(t: Type | null): boolean {
	return t != null && (t.kind == TypeKind.Span || t.kind == TypeKind.Borrow
		|| t.kind == TypeKind.Lent || t.kind == TypeKind.Var);
}

// Struct and class fields are not descended: a field never holds a view (refused at its declaration).
export function findViewType(t: Type | null): Type | null {
	return findViewTypeAt(t, 0);
}

function findViewTypeAt(t: Type | null, depth: int32): Type | null {
	if (t == null || depth > 8) return null;
	if (isViewKind(t)) return t;
	if (t.kind == TypeKind.Array || t.kind == TypeKind.SizedArray || t.kind == TypeKind.Ref
			|| t.kind == TypeKind.Distinct || t.kind == TypeKind.Alias || t.kind == TypeKind.Sink) {
		return findViewTypeAt(t.typeReturn, depth + 1);
	}
	if (t.kind == TypeKind.Tuple || t.kind == TypeKind.Union || t.kind == TypeKind.GenericInstance
			|| t.kind == TypeKind.Varargs) {
		for (const c of t.typeChildren) {
			const v = findViewTypeAt(c, depth + 1);
			if (v != null) return v;
		}
	}
	return null;
}

export function nestedViewType(t: Type | null): Type | null {
	let top = t;
	if (top != null && top.kind == TypeKind.Union && top.typeChildren.length == 2) {
		const a = top.typeChildren[0];
		const b = top.typeChildren[1];
		if (a != null && a.kind == TypeKind.Null) top = b;
		else if (b != null && b.kind == TypeKind.Null) top = a;
	}
	if (top != null && top.kind == TypeKind.Var && top.typeReturn != null && top.typeReturn.kind == TypeKind.Span) top = top.typeReturn;
	if (isViewKind(top)) return findViewType(top!.typeReturn);
	return findViewType(top);
}

export function ownedAlternativeOf(view: Type): string {
	const elem = view.typeReturn != null ? typeDisplayName(view.typeReturn) : "T";
	return view.kind == TypeKind.Span ? "an owning " + elem + "[] (copy it with [...x])" : "a " + elem + " value";
}

// The T of a Locked<T> — the cell's third field. Null for anything else.
export function lockedPayloadType(t: Type | null): Type;
export function lockedPayloadType(t: Readonly<Type | null>): Readonly<Type>;
export function lockedPayloadType(t: Readonly<Type | null>): Readonly<Type> {
	if (!isLockedRef(t) || t.typeReturn == null) return null as unknown as Type;
	const cell = t.typeReturn;
	if (cell.typeChildren == null || cell.typeChildren.length < 3) return null as unknown as Type;
	return cell.typeChildren[2];
}

// Walking a Ref for substitution needs two things the three Ref classes answer
// differently: which type underneath carries the parameters, and which
// constructor rebuilds the wrapper afterwards. A Locked<T> handle points at the
// generated cell, so its parameter-bearing part is the PAYLOAD, not the
// pointee; and it must be tested before Arc, since its flag set includes
// IsAtomic and the Arc branch would drop IsLocked and hand the result a raw
// cell. Both rules live here so a caller cannot get one of them right and the
// other wrong.
export function refSubstInner(t: Type): Type | null;
export function refSubstInner(t: Readonly<Type>): Readonly<Type | null>;
export function refSubstInner(t: Readonly<Type>): Readonly<Type | null> {
	return isLockedRef(t) ? lockedPayloadType(t) : t.typeReturn;
}

export function rebuildRefLike(t: Type, inner: Type | null): Type {
	if (isLockedRef(t)) return createLocked(inner);
	if (isAtomicRef(t)) return createArc(inner);
	return createRef(inner);
}

// The annotation spelling that re-resolves to this Ref class, or "" for a plain
// Ref (a class/interface annotation re-resolves to Ref<Struct> on its own, so
// the wrapper is not written). Same classification as the two above — kept
// beside them so the ordering rule has exactly one home.
export function refWrapperName(t: Readonly<Type>): string {
	if (isLockedRef(t)) return "Locked";
	if (isAtomicRef(t)) return "Arc";
	return "";
}

export function createPtr(inner: Type | null): Type {
	const t = emptyType();
	t.kind = TypeKind.Ptr;
	t.typeReturn = inner;
	return t;
}

export function createCursor(inner: Type | null): Type {
	const t = emptyType();
	t.kind = TypeKind.Cursor;
	t.typeReturn = inner;
	return t;
}

export function unwrapCursor(t: Type | null): Type | null {
	if (t != null && t.kind == TypeKind.Cursor) return t.typeReturn;
	return t;
}

export function createBorrow(inner: Type): Type {
	const t = emptyType();
	t.kind = TypeKind.Borrow;
	t.typeReturn = inner;
	return t;
}

export function createVar(inner: Type): Type {
	const t = emptyType();
	t.kind = TypeKind.Var;
	t.typeReturn = inner;
	return t;
}

export function createOutVar(inner: Type): Type {
	const t = createVar(inner);
	t.typeFlags = t.typeFlags.incl(TypeFlag.OutParam);
	return t;
}

export function isOutParam(t: Type | null): boolean {
	return t != null && t.kind == TypeKind.Var && t.typeFlags.has(TypeFlag.OutParam);
}

function substitutedVar(t: Type, inner: Type): Type {
	return isOutParam(t) ? createOutVar(inner) : createVar(inner);
}

export function createSink(inner: Type): Type {
	const t = emptyType();
	t.kind = TypeKind.Sink;
	t.typeReturn = inner;
	propagateToOwner(t, inner);
	return t;
}

export function createTuple(elementTypes: Type[]): Type {
	const t = emptyType();
	t.kind = TypeKind.Tuple;
	t.typeChildren = elementTypes;
	for (const et of elementTypes) { propagateToOwner(t, et); }
	return t;
}



export function createDistinct(inner: Type): Type {
	const t = emptyType();
	t.kind = TypeKind.Distinct;
	t.typeReturn = inner;
	propagateToOwner(t, inner);
	return t;
}

// ===== BitSet<E> =====
// A set of enum members is a type of its own (TypeKind.Set, element in
// typeReturn); `BitSet<E>` resolves to it in resolveAnnotation the same way
// Span/Ref/Arc/Locked do, and its representation follows the member count.

// BitSet numbers members by ORDINAL. An enum whose members carry hand-assigned
// values (1, 2, 4, ...) is already a flag encoding, so combining it must keep the
// existing numeric meaning — applying BitSet there would encode the bits twice.
export function isOrdinalEnum(t: Type | null): boolean {
	if (t == null || t.kind != TypeKind.Enum) return false;
	if (t.typeChildren.length == 0) return false;
	for (let i = 0; i < t.typeChildren.length; i += 1) {
		const v = t.typeChildren[i];
		if (v == null) return false;
		if (v.typeValue != (i as int32)) return false;
	}
	return true;
}

// A generic distinct/alias instance is nominal to the checker only; its
// representation is the substituted body. Backends that switch on width need
// that body, not the instance.
function instanceBody(t: Readonly<Type>): Readonly<Type | null> {
	const base = t.typeExtra;
	if (base == null || base.typeReturn == null) return null;
	if (t.typeReturn == null) return missingBody(t) ? null : base.typeReturn;
	return base.kind == TypeKind.Distinct && t.typeReturn.kind == TypeKind.Distinct ? t.typeReturn.typeReturn : t.typeReturn;
}

export function substituteInstanceArgs(gi: Type, target: Type): Type {
	const names = splitTopLevel(genericParamsOf(gi), ",").map((n: string): string => n.trim());
	if (names.length == 0 || names.length > gi.typeChildren.length) return target;
	return substituteParams(target, declaredParamsOf(gi, names.length), gi.typeChildren);
}

function missingBody(t: Readonly<Type>): boolean {
	if (!pendingBody(t, genericParamsOf(t))) return false;
	if (_queryCachesReadOnly) throw new Error(`internal: generic instance '${typeDisplayName(t)}' reached emission without its body`);
	return true;
}

export function distinctInstanceRepr(t: Type | null): Type | null;
export function distinctInstanceRepr(t: Readonly<Type | null>): Readonly<Type | null>;
export function distinctInstanceRepr(t: Readonly<Type | null>): Readonly<Type | null> {
	if (t == null) return null;
	if (t.kind != TypeKind.GenericInstance) return null;
	const base = t.typeExtra;
	if (base == null || base.typeReturn == null) return null;
	if (base.kind != TypeKind.Distinct && base.kind != TypeKind.Alias) return null;
	return instanceBody(t);
}

export function genericInstanceAbiRepr(t: Type): Type;
export function genericInstanceAbiRepr(t: Readonly<Type>): Readonly<Type>;
export function genericInstanceAbiRepr(t: Readonly<Type>): Readonly<Type> {
	const transparent = peelTransparentInstance(t);
	if (transparent != t) return transparent;
	const distinctRepr = distinctInstanceRepr(t);
	if (distinctRepr != null && distinctRepr.kind != TypeKind.Struct && distinctRepr.kind != TypeKind.Union) return distinctRepr;
	return t;
}

export const BITSET_MAX_MEMBERS: int32 = 65536;

function bitSetMemberCount(elem: Readonly<Type>): int32 {
	let memberType = elem;
	if (memberType.kind == TypeKind.Enum && memberType.typeNames.length == 0
			&& memberType.sym != null && memberType.sym.symbolType != null
			&& memberType.sym.symbolType.kind == TypeKind.Enum) {
		memberType = memberType.sym.symbolType;
	}
	return memberType.typeNames.length;
}

function bitSetReprForMembers(members: int32): Type | null {
	if (members <= 8) return createPrimitive(TypeKind.Uint8);
	if (members <= 16) return createPrimitive(TypeKind.Uint16);
	if (members <= 32) return createPrimitive(TypeKind.Uint32);
	if (members <= 64) return createPrimitive(TypeKind.Uint64);
	if (members <= BITSET_MAX_MEMBERS) return createSizedArray(createPrimitive(TypeKind.Uint8), (members + 7) >> 3);
	return null;
}

export function bitSetRepr(elem: Type | null): Type | null;
export function bitSetRepr(elem: Readonly<Type | null>): Readonly<Type | null>;
export function bitSetRepr(elem: Readonly<Type | null>): Readonly<Type | null> {
	if (elem == null) return null;
	return bitSetReprForMembers(bitSetMemberCount(elem));
}

export function setRepr(t: Type | null): Type | null;
export function setRepr(t: Readonly<Type | null>): Readonly<Type | null>;
export function setRepr(t: Readonly<Type | null>): Readonly<Type | null> {
	if (t == null || t.kind != TypeKind.Set) return null;
	return t.typeValue > 0 ? bitSetReprForMembers(t.typeValue) : bitSetRepr(t.typeReturn);
}

export function peelToRepr(t: Type | null): Type | null;
export function peelToRepr(t: Readonly<Type | null>): Readonly<Type | null>;
export function peelToRepr(t: Readonly<Type | null>): Readonly<Type | null> {
	if (t == null) return null;
	if (t.kind == TypeKind.Distinct) return peelToRepr(t.typeReturn);
	const widened = widenNumberLiteralType(t);
	if (widened != t) return widened;
	if (t.kind == TypeKind.Set) {
		const sr = setRepr(t);
		return sr != null ? peelToRepr(sr) : t;
	}
	const repr = distinctInstanceRepr(t);
	if (repr != null) return peelToRepr(repr);
	return t;
}

export function bitSetElemType(t: Type | null): Type | null {
	if (t == null || t.kind != TypeKind.Set) return null;
	return t.typeReturn;
}

export function createBitSet(elem: Type): Type {
	const t = emptyType();
	t.kind = TypeKind.Set;
	t.typeName = "BitSet";
	t.typeReturn = elem;
	t.typeValue = bitSetMemberCount(elem);
	return spelled(t);
}

export function createBrandDistinct(brandKey: string, inner: Type): Type {
	const t = createDistinct(inner);
	t.typeName = brandKey;
	t.typeFlags = t.typeFlags.incl(TypeFlag.BrandWiden);
	return t;
}

export function isBrandDistinct(t: Readonly<Type | null>): boolean {
	if (t == null) return false;
	return t.kind == TypeKind.Distinct && t.typeFlags.has(TypeFlag.BrandWiden);
}

export function distinctBody(t: Type | null): Type | null;
export function distinctBody(t: Readonly<Type | null>): Readonly<Type | null>;
export function distinctBody(t: Readonly<Type | null>): Readonly<Type | null> {
	if (t == null) return null;
	if (t.kind == TypeKind.Distinct) return t.typeReturn;
	if (t.kind != TypeKind.GenericInstance) return null;
	const base = t.typeExtra;
	if (base == null || base.kind != TypeKind.Distinct) return null;
	return distinctInstanceRepr(t);
}

export function borrowedDotBase(t: Type | null): Type | null {
	if (t == null) return null;
	const wrapper = t.kind == TypeKind.GenericInstance ? t.typeExtra : t;
	if (wrapper == null || wrapper.kind != TypeKind.Distinct || !wrapper.typeFlags.has(TypeFlag.BorrowDot)) return null;
	return distinctBody(t);
}

export function distinctCallTarget(t: Type | null): Type | null {
	const body = distinctBody(t);
	return body != null && body.kind == TypeKind.Function ? body : null;
}

export function distinctNumericBase(t: Type | null): Type | null {
	let cur = t;
	let depth = 0;
	let body = distinctBody(cur);
	while (body != null && depth < PEEL_MAX_DEPTH) {
		cur = body;
		body = distinctBody(cur);
		depth += 1;
	}
	return cur != t && isNumeric(cur) ? cur : null;
}

export function distinctWidenBody(t: Type | null): Type | null {
	if (t == null) return null;
	const wrapper = t.kind == TypeKind.GenericInstance ? t.typeExtra : t;
	if (!isBrandDistinct(wrapper)) return null;
	return distinctBody(t);
}

export function createGenericParam(name: string): Type {
	const t = emptyType();
	t.kind = TypeKind.GenericParam;
	t.typeName = name;
	return t;
}

// GenericInstance: preserves type args structurally after instantiation.
// typeChildren = type arguments, typeExtra = base type (struct/interface).
// typeReturn = EAGERLY INSTANTIATED body (concrete body after substitution).
// Enables structural unification: HashMap<K,V> vs HashMap<string,string> → K=string, V=string.
// For Ref<Struct> (interface types), unwrap to inner struct for name and flags.
export function unwrapRefBase(t: Type): Type;
export function unwrapRefBase(t: Readonly<Type>): Readonly<Type>;
export function unwrapRefBase(t: Readonly<Type>): Readonly<Type> {
	return (t != null && t.kind == TypeKind.Ref && t.typeReturn != null) ? t.typeReturn : t;
}

// Built-in generics are never parsed, so no declaration carries their
// parameter names; without them instantiateGenericBody leaves typeReturn
// empty and narrowing leaks GenericParam (Bug 16).
export function builtinGenericParams(name: string): string {
	return match (name) {
		"Result" => "T,E",
		"Promise" => "T",
		"Iterator" => "T",
		"IteratorResult" => "T",
		"Arc" => "T",
		"Locked" => "T",
		_ => "",
	};
}

function peelDeclWrapper(decl: Node | null): Node | null;
function peelDeclWrapper(decl: Readonly<Node | null>): Readonly<Node | null>;
function peelDeclWrapper(decl: Readonly<Node | null>): Readonly<Node | null> {
	let cur = decl;
	let guard = 0;
	while (cur != null && guard < 8) {
		guard = guard + 1;
		if (cur.kind == NodeKind.DecoratedDecl) { cur = (cur.data as DecoratedDeclData).decoratedNode; continue; }
		if (cur.kind == NodeKind.ExportDecl) { cur = (cur.data as ExportDeclData).exportedDecl; continue; }
		return cur;
	}
	return cur;
}

export function declGenericParams(decl: Readonly<Node | null>): string {
	const d = peelDeclWrapper(decl);
	if (d == null) return "";
	if (d.kind == NodeKind.TypeAliasDecl) {
		const params = (d.data as TypeAliasDeclData).aliasGenericParams;
		return params != null ? params : "";
	}
	if (d.kind == NodeKind.ClassDecl || d.kind == NodeKind.InterfaceDecl || d.kind == NodeKind.StructDecl
			|| d.kind == NodeKind.ActorDecl || d.kind == NodeKind.ExternDecl) {
		return d.typeArg != null ? d.typeArg : "";
	}
	return "";
}

export function symGenericParams(sym: Readonly<Symbol | null>): string {
	if (sym == null) return "";
	if (sym.declNode != null) return declGenericParams(sym.declNode);
	const viaType = genericParamsOf(sym.symbolType);
	return viaType != "" ? viaType : builtinGenericParams(sym.name);
}

function genericOwnerOf(cur: Type): Symbol | null;
function genericOwnerOf(cur: Readonly<Type>): Readonly<Symbol | null>;
function genericOwnerOf(cur: Readonly<Type>): Readonly<Symbol | null> {
	if (cur.kind != TypeKind.GenericInstance) return cur.sym;
	const base = cur.typeExtra != null ? unwrapRefBase(cur.typeExtra) : null;
	return base != null ? base.sym : null;
}

export function genericParamsOf(t: Readonly<Type | null>): string {
	if (t == null) return "";
	let cur = t;
	if ((cur.kind == TypeKind.Ref || cur.kind == TypeKind.Ptr) && cur.typeReturn != null) cur = cur.typeReturn;
	const owner = genericOwnerOf(cur);
	if (owner != null && owner.declNode != null) return genericParamNamesOf(declGenericParams(owner.declNode));
	return builtinGenericParams(cur.typeName);
}

export function declaredTypeParams(sym: Symbol, count: int32): Type[] {
	return sym.typeParams.length == count ? sym.typeParams : [];
}

export function declaredParamsOf(t: Type, count: int32): Type[] {
	const cur = (t.kind == TypeKind.Ref || t.kind == TypeKind.Ptr) && t.typeReturn != null ? t.typeReturn : t;
	const owner = genericOwnerOf(cur);
	if (owner != null) return declaredTypeParams(owner, count);
	if (cur.kind != TypeKind.GenericInstance || cur.typeExtra == null) return [];
	const own: Type[] = [];
	collectGenericParams(unwrapRefBase(cur.typeExtra), own, 0);
	return own.length == count ? own : [];
}

export function genericParamNamesOf(params: string): string {
	const names: string[] = [];
	for (const param of splitTopLevel(params, ",")) names.push(splitTopLevel(param, ":")[0].trim());
	return names.join(",");
}

export function createGenericInstance(baseType: Type, typeArgs: Type[]): Type {
	const innerBase = unwrapRefBase(baseType);
	return {
		kind: TypeKind.GenericInstance,
		typeName: innerBase != null ? innerBase.typeName : "",
		typeNames: [],
		typeChildren: typeArgs,
		typeReturn: null as unknown as Type,
		typeExtra: baseType,
		typeFlags: innerBase != null ? innerBase.typeFlags : 0 as BitSet<TypeFlag>,
		typeValue: 0,
		callConv: CallingConvention.CcDefault,
		attachedOps: [],
	};
}

let _instantiatedBodies: int32 = 0;
export function instantiatedBodyCount(): int32 { return _instantiatedBodies; }

function bodyWouldShareTheDeclaration(base: Readonly<Type | null>, names: string[], args: Readonly<Type[]>): boolean {
	if (base == null || !isDeclaredStruct(base) || symGenericParams(base.sym) == "") return false;
	const declared = base.sym.typeParams;
	for (let i = 0; i < names.length; i += 1) {
		if (args[i] == null || args[i].kind != TypeKind.GenericParam) return true;
		if (i < declared.length ? args[i] != declared[i] : args[i].typeName != names[i]) return true;
	}
	return false;
}

// Reference parity (handleGenericInvocation): eagerly instantiate
// GenericInstance body. Uses explicit param names from the parser's generic declaration
// store. Produces a fully concrete body
// stored in typeReturn for direct field access — no lazy substitution at access time.
const _instancesBuilding: Type[] = [];

function instanceBeingBuilt(gi: Type): Type | null {
	for (const building of _instancesBuilding) {
		if (building.typeExtra != gi.typeExtra || building.typeChildren.length != gi.typeChildren.length) continue;
		let same = true;
		for (let i = 0; i < gi.typeChildren.length; i += 1) {
			if (typeKey(building.typeChildren[i]) != typeKey(gi.typeChildren[i])) same = false;
		}
		if (same) return building;
	}
	return null;
}

function pendingBody(gi: Readonly<Type>, declaredParams: string): boolean {
	if (gi.kind != TypeKind.GenericInstance || gi.typeReturn != null || declaredParams == "") return false;
	const baseType = gi.typeExtra;
	if (baseType == null) return false;
	const innerBase = baseType.kind == TypeKind.Ref && baseType.typeReturn != null ? baseType.typeReturn : baseType;
	if (innerBase.kind == TypeKind.Error || isUnresolvedType(innerBase)) return false;
	const names = splitTopLevel(genericParamNamesOf(declaredParams), ",");
	if (names.length == 0 || names.length > gi.typeChildren.length) return false;
	const phantom = isDeclaredStruct(innerBase) && !innerBase.typeFlags.has(TypeFlag.HasGenericParam);
	return !(phantom && bodyWouldShareTheDeclaration(innerBase, names, gi.typeChildren));
}

export function instantiateGenericBody(gi: Type, declaredParams: string): void {
	if (!pendingBody(gi, declaredParams)) return;
	const baseType = gi.typeExtra;
	// Unwrap Ref for interface types (interface = Ref<Struct> after refactor)
	const isRefWrapped = baseType.kind == TypeKind.Ref && baseType.typeReturn != null;
	const innerBase = isRefWrapped ? baseType.typeReturn : baseType;
	// Split declared param names (e.g. "K,V" → ["K", "V"])
	const paramNames = splitTopLevel(genericParamNamesOf(declaredParams), ",");
	const names: string[] = [];
	const args: Type[] = [];
	let pi = 0;
	while (pi < paramNames.length) {
		names.push(splitTopLevel(paramNames[pi], ":")[0].trim());
		args.push(gi.typeChildren[pi]);
		pi = pi + 1;
	}
	const tracked = !_queryCachesReadOnly;
	if (tracked) _instancesBuilding.push(gi);
	const body = substituteParams(innerBase, declaredParamsOf(gi, names.length), args);
	if (tracked) _instancesBuilding.pop();
	if (body == innerBase && bodyWouldShareTheDeclaration(innerBase, names, args)) return;
	if (body != innerBase && body.kind == TypeKind.Union && isUnionAlias(innerBase)) body.typeInst = gi;
	// Re-wrap in Ref if the base was Ref<Struct>
	gi.typeReturn = isRefWrapped ? createRef(body) : body;
	_instantiatedBodies = _instantiatedBodies + 1;
}

// ===== System Types (Standard reference parity) =====
// Pre-allocated primitive types indexed by TypeKind ordinal. O(1) lookup, no allocation.
// Module-level array initialized once; replaces per-call createPrimitive.

const _sysTypes: Type[] = [];
function initSysTypes(): void {
	// Pre-allocate one Type per TypeKind (indices 0..Error)
	for (let i = 0; i <= (TypeKind.Error as number); i += 1) {
		_sysTypes.push(createPrimitive(i as TypeKind));
	}
	// Managed primitives get TypeFlag.HasAsgn (Reference parity: managed types have tfHasAsgn)
	_sysTypes[TypeKind.String as number].typeFlags = (0 as BitSet<TypeFlag>).incl(TypeFlag.HasAsgn);
}
initSysTypes();

export function getSysType(kind: TypeKind): Type {
	const idx = kind as number;
	if (idx >= 0 && idx < _sysTypes.length) return _sysTypes[idx];
	return createPrimitive(kind);
}

export function isSysType(t: Type): boolean {
	const idx = t.kind as number;
	return idx >= 0 && idx < _sysTypes.length && _sysTypes[idx] == t;
}

// ===== Well-Known Type Accessors =====
// Thin wrappers over getSysType for backward compatibility + readability.

export function numberType(): Type { return getSysType(TypeKind.Number); }

export function literalBase(t: Type): Type {
	if (t.kind == TypeKind.StringLiteral) return stringType();
	if (t.kind == TypeKind.NumberLiteral) return numberLiteralBase(t);
	const carried = literalUnionBase(t);
	if (carried != null) return carried;
	if (t.kind == TypeKind.BooleanLiteral) return booleanType();
	if (t.kind == TypeKind.EnumLiteral && t.typeReturn != null) return t.typeReturn;
	return t;
}
export function holdsNumberLiteral(t: Type | null): boolean {
	if (t == null) return false;
	const held = isMaybeType(t) && t.typeReturn != null ? t.typeReturn : t;
	if (held.kind == TypeKind.NumberLiteral) return true;
	if (held.kind != TypeKind.Union) return false;
	for (const child of held.typeChildren) {
		if (child != null && child.kind == TypeKind.NumberLiteral) return true;
	}
	return false;
}

export function widenNumberLiteralType(t: Type): Type;
export function widenNumberLiteralType(t: Readonly<Type>): Readonly<Type>;
export function widenNumberLiteralType(t: Readonly<Type>): Readonly<Type> {
	if (t.kind == TypeKind.NumberLiteral) return numberLiteralBase(t);
	const carried = literalUnionBase(t);
	return carried != null && carried.kind != TypeKind.String ? carried : t;
}
export function stringType(): Type { return getSysType(TypeKind.String); }
export function booleanType(): Type { return getSysType(TypeKind.Boolean); }
export function voidType(): Type { return getSysType(TypeKind.Void); }
export function nullType(): Type { return getSysType(TypeKind.Null); }

// ===== Sentinel kinds — one meaning per kind, never a classifying flag =====
// (Nim model: tyPointer / tyInferred / tyError / tyNone — astdef.nim)
//   TypeKind.Unknown   user-written `unknown`: strict top type, pointer repr
//                      (void*). Anything → unknown is legal; unknown → anything
//                      needs narrowing (fat values have no void* repr).
//   TypeKind.Inferred  inference in progress — the ONLY kind isUnresolvedType
//                      matches, and the only one compat.ms leniency serves.
//   TypeKind.Error     error recovery + cancelled checks.
//   TypeKind.None      node kinds with no type to speak of (regex/quote/JSXText).
//   Ptr<void>          deliberate raw pointers (boxed closure returns, $up env
//                      chain, actor dispatch, async stepper) — never a sentinel.
// TypeKind.Pending is the unconstructible legacy kind (ctor deleted 2026-08-06):
// all these meanings once shared it behind TypeFlag.UserUnknown, and readers
// disagreeing about its pointer-ness produced memory corruption four times
// (NIM-REF CK-46). A new meaning gets a NEW kind — never a flag, never a
// shared singleton.
// Unknown sits past the 0..Error getSysType preallocation on purpose
// (bootstrap-stable ordinals) — this accessor returns a fresh type per call.
export function unknownType(): Type { return getSysType(TypeKind.Unknown); }

export function nonPrimitiveType(): Type { return getSysType(TypeKind.NonPrimitive); }

export function isNonPrimitiveType(t: Type | null): boolean {
	const s = skipModifier(t);
	if (s == null) return false;
	if (s.kind == TypeKind.Union) {
		for (const member of s.typeChildren) {
			if (!isNonPrimitiveType(member)) return false;
		}
		return s.typeChildren.length > 0;
	}
	return match (s.kind) {
		TypeKind.Ref | TypeKind.Struct | TypeKind.Array | TypeKind.SizedArray | TypeKind.Span | TypeKind.Tuple
			| TypeKind.Function | TypeKind.Set | TypeKind.Result | TypeKind.NonPrimitive => true,
		TypeKind.GenericInstance => s.typeReturn == null || isNonPrimitiveType(s.typeReturn),
		TypeKind.Distinct | TypeKind.Alias => isNonPrimitiveType(s.typeReturn),
		_ => false,
	};
}

export function isPlainObjectType(t: Type | null): boolean {
	const s = skipModifier(t);
	if (s == null) return false;
	if (s.kind == TypeKind.Union) {
		for (const member of s.typeChildren) {
			if (!isPlainObjectType(member)) return false;
		}
		return s.typeChildren.length > 0;
	}
	if (s.kind == TypeKind.Distinct) return isPlainObjectType(s.typeReturn);
	if (isArrayShaped(s) || s.kind == TypeKind.Tuple) return true;
	const held = s.kind == TypeKind.Ref && s.typeReturn != null ? s.typeReturn : s;
	if (held.kind == TypeKind.GenericInstance && distinctBody(held) != null) {
		return getBuiltinKind(held.typeExtra) != "Proxy" && isPlainObjectType(distinctBody(held));
	}
	if (held.kind == TypeKind.Ptr || runtimeClassSym(held) != null) return false;
	const body = peelToStructOrUnion(held);
	return body != null && body.kind == TypeKind.Struct && !isMaybeType(body) && (body.sym == null || body.sym.symbolKind != SymbolKind.Class);
}

export function isUnresolvedType(t: Readonly<Type | null>): boolean {
	return t != null && t.kind == TypeKind.Inferred;
}
export function isUnknownType(t: Readonly<Type | null>): boolean {
	return t != null && t.kind == TypeKind.Unknown;
}
export function noneType(): Type { return getSysType(TypeKind.None); }
export function inferredType(): Type { return getSysType(TypeKind.Inferred); }
export function neverType(): Type { return getSysType(TypeKind.Never); }
export function errorType(): Type { return getSysType(TypeKind.Error); }
export function charType(): Type { return getSysType(TypeKind.Char); }
export function cstringType(): Type { return getSysType(TypeKind.CString); }
export function int32Type(): Type { return getSysType(TypeKind.Int32); }
export function float64Type(): Type { return getSysType(TypeKind.Float64); }

// Destructuring binding types — the single derivation, read by BOTH the checker
// (defineForOfPatternBindings) and the transform (destructuringLower). Nim needs
// no equivalent: makeVarTupleSection re-sems the generated accesses (semstmts.nim:757).
export function destrPositionalElemType(srcType: Type | null, i: int32): Type | null {
	let bt = srcType;
	if (bt == null) return null;
	bt = peelTransparentInstance(bt);
	if ((bt.kind == TypeKind.Ref || bt.kind == TypeKind.Var) && bt.typeReturn != null) bt = bt.typeReturn;
	if (bt.kind == TypeKind.Tuple && bt.typeChildren != null && i < bt.typeChildren.length) return bt.typeChildren[i];
	if ((bt.kind == TypeKind.Array || bt.kind == TypeKind.SizedArray) && bt.typeReturn != null) return bt.typeReturn;
	return null;
}

function destructuredFields(srcType: Type | null): Type | null {
	if (srcType == null) return null;
	let bt = peelTransparentInstance(srcType);
	if ((bt.kind == TypeKind.Ref || bt.kind == TypeKind.Var) && bt.typeReturn != null) bt = bt.typeReturn;
	const body = bt.kind == TypeKind.GenericInstance ? peelToStructOrUnion(bt) : bt;
	return body != null && body.kind == TypeKind.Struct ? body : null;
}

export function destrNamedFieldType(srcType: Type | null, fieldName: string): Type | null {
	const bt = destructuredFields(srcType);
	if (bt == null) return null;
	for (let fi = 0; fi < bt.typeNames.length; fi += 1) {
		if (bt.typeNames[fi] == fieldName && fi < bt.typeChildren.length) return bt.typeChildren[fi];
	}
	return null;
}

export function destrHasRuntimeLength(srcType: Type | null): boolean {
	let bt = srcType;
	if (bt == null) return false;
	bt = peelTransparentInstance(bt);
	if ((bt.kind == TypeKind.Ref || bt.kind == TypeKind.Var) && bt.typeReturn != null) bt = bt.typeReturn;
	return bt.kind == TypeKind.Array || bt.kind == TypeKind.SizedArray;
}

export function destrDefaultedType(derived: Type | null): Type | null {
	if (derived == null) return null;
	if (isMaybeType(derived)) return unwrapMaybeType(derived);
	if (derived.kind != TypeKind.Union || derived.typeChildren == null) return derived;
	const kept: Type[] = [];
	for (const m of derived.typeChildren) {
		if (m != null && m.kind != TypeKind.Null) kept.push(m);
	}
	if (kept.length == 0 || kept.length == derived.typeChildren.length) return derived;
	if (kept.length == 1) return kept[0];
	return createUnion(kept);
}

export function destrRestElemType(srcType: Type | null): Type | null {
	let bt = srcType;
	if (bt == null) return null;
	bt = peelTransparentInstance(bt);
	if ((bt.kind == TypeKind.Ref || bt.kind == TypeKind.Var) && bt.typeReturn != null) bt = bt.typeReturn;
	if (bt.kind == TypeKind.Array && bt.typeReturn != null) return bt;
	if (bt.kind == TypeKind.SizedArray && bt.typeReturn != null) return createArray(bt.typeReturn);
	return null;
}

export function destrObjectRestNames(srcType: Type | null, taken: string[]): string[] {
	const names: string[] = [];
	const bt = destructuredFields(srcType);
	if (bt == null) return names;
	for (const fieldName of bt.typeNames) {
		let isTaken = false;
		for (const takenName of taken) {
			if (takenName == fieldName) isTaken = true;
		}
		if (!isTaken) names.push(fieldName);
	}
	return names;
}

export function destrObjectRestType(srcType: Type | null, taken: string[]): Type | null {
	const names = destrObjectRestNames(srcType, taken);
	if (names.length == 0) return null;
	const types: Type[] = [];
	for (const fieldName of names) {
		const ft = destrNamedFieldType(srcType, fieldName);
		if (ft == null) return null;
		types.push(ft);
	}
	return spelled(createStruct(anonStructName(names, types), names, types, false));
}

// StringLiteral: a specific string value as a type (TypeScript parity).
// Not a singleton — each unique value creates a new instance.
export function createStringLiteral(value: string): Type {
	const t = emptyType();
	t.kind = TypeKind.StringLiteral;
	t.typeName = value;
	return t;
}

export function createNumberLiteral(name: string, base: Type): Type {
	const t = emptyType();
	t.kind = TypeKind.NumberLiteral;
	t.typeName = name;
	t.typeReturn = base;
	return t;
}

export function numberLiteralBase(t: Type): Type;
export function numberLiteralBase(t: Readonly<Type>): Readonly<Type>;
export function numberLiteralBase(t: Readonly<Type>): Readonly<Type> {
	return t.typeReturn != null ? t.typeReturn : int32Type();
}

export function integerLiteralName(v: int64): string { return int64ToDecimal(v); }

export function fractionLiteralName(v: number): string {
	const s = v.toString();
	return numericLiteralIsFloat(s) || s.indexOf("n") >= 0 ? s : s + ".0";
}

export function numberLiteralTypeOf(text: string): Type | null {
	const negative = text.startsWith("-");
	const body = negative ? text.slice(1, text.length) : text;
	if (numericLiteralIsFloat(body)) {
		const v = parseNumberLiteral(text);
		return v - v == 0 ? createNumberLiteral(fractionLiteralName(v), float64Type()) : null;
	}
	if (integerLiteralIsBitPattern(body) || !fitsInt64Decimal(body, negative)) return null;
	const v = parseIntegerLiteral(text);
	return createNumberLiteral(integerLiteralName(v), v >= -2147483648 && v <= 2147483647 ? int32Type() : createPrimitive(TypeKind.Int64));
}

export function isStringLiteral(t: Type | null): boolean {
	return t != null && t.kind == TypeKind.StringLiteral;
}

// BooleanLiteral: specific boolean value as a type (TypeScript parity).
// typeName = "true" | "false" — the literal value as a string.
// Required for discriminated union narrowing on `ok: true | false` discriminants.
export function createBooleanLiteral(value: boolean): Type {
	const t = emptyType();
	t.kind = TypeKind.BooleanLiteral;
	t.typeName = value ? "true" : "false";
	return t;
}

export function booleanLiteralValue(t: Readonly<Type | null>): boolean {
	if (t == null || t.kind != TypeKind.BooleanLiteral) return false;
	return t.typeName == "true";
}

// EnumLiteral: a specific enum member as a type (TypeScript parity).
// typeName = enum type name (e.g. "NodeKind").
// typeNames[0] = specific member (e.g. "BinaryExpr").
// typeReturn = back-reference to the underlying Enum Type for fast subtype checks.
export function enumMemberValue(t: Readonly<Type>, index: int32): int32 {
	return t.typeChildren != null && index < t.typeChildren.length && t.typeChildren[index] != null ? t.typeChildren[index].typeValue : index;
}

export function enumOrdinalBounds(t: Readonly<Type>): int32[] {
	const count = t.typeNames.length;
	let low: int32 = 0;
	let high: int32 = 0;
	for (let i = 0; i < count; i += 1) {
		const v = enumMemberValue(t, i);
		if (i == 0 || v < low) low = v;
		if (i == 0 || v > high) high = v;
	}
	return [low, high];
}

export function enumStorageKind(t: Readonly<Type>): TypeKind {
	if (t.sym != null && t.sym.symFlags.has(SymbolFlag.ImportC)) return TypeKind.Int32;
	if (t.typeNames.length == 0) return TypeKind.Int32;
	const bounds = enumOrdinalBounds(t);
	if (bounds[0] < 0) return TypeKind.Int32;
	if (bounds[1] < 256) return TypeKind.Uint8;
	if (bounds[1] < 65536) return TypeKind.Uint16;
	return TypeKind.Int32;
}

function enumStorageOf(t: Type): Type;
function enumStorageOf(t: Readonly<Type>): Readonly<Type>;
function enumStorageOf(t: Readonly<Type>): Readonly<Type> {
	const e = t.kind == TypeKind.EnumLiteral && t.typeReturn != null ? t.typeReturn : t;
	return createPrimitive(e.kind == TypeKind.Enum ? enumStorageKind(e) : TypeKind.Int32);
}

export function createEnumLiteral(enumType: Type, memberName: string): Type {
	const t = emptyType();
	t.kind = TypeKind.EnumLiteral;
	t.typeName = enumType.typeName;
	t.typeNames = [memberName];
	t.typeReturn = enumType;
	return t;
}

export function isEnumLiteral(t: Type | null): boolean {
	return t != null && t.kind == TypeKind.EnumLiteral;
}

// Tier 3: Conditional type — T extends U ? A : B
// typeChildren[0] = check type (T)
// typeChildren[1] = extends type (U)
// typeChildren[2] = true branch (A)
// typeChildren[3] = false branch (B)
export function createConditionalType(check: Type, extendsType: Type, trueType: Type, falseType: Type): Type {
	const t = emptyType();
	t.kind = TypeKind.Conditional;
	t.typeChildren = [check, extendsType, trueType, falseType];
	return t;
}

// The `infer` parameters a conditional's extends clause declares, kept as the elements of
// typeReturn; every other parameter in the clause is an outer one, so the conditional defers.
export function setInferParams(cond: Type, declared: Type[]): void {
	if (declared.length > 0) cond.typeReturn = createTuple(declared);
}

function inferParamsOf(t: Type): Type[] {
	return t.typeReturn != null ? t.typeReturn.typeChildren : [];
}

// A conditional whose check type is written as a naked type parameter distributes over a
// union that parameter is given (reference: root.isDistributive). typeExtra keeps that
// parameter: a substitution replaces it in the check type only, and inside the extends type
// and the branches it is bound per member when the conditional is evaluated.
export function markDistributive(cond: Type): void {
	const check = cond.typeChildren.length == 4 ? cond.typeChildren[0] : null;
	if (check != null && check.kind == TypeKind.GenericParam) cond.typeExtra = check;
}

function distributiveParam(t: Type): Type | null {
	return t.typeExtra != null && t.typeExtra.kind == TypeKind.GenericParam ? t.typeExtra : null;
}

// Evaluate a conditional type if its check and extends types are concrete (no GenericParam).
// Returns the true/false branch, or the original type if unevaluable.
export function evaluateConditionalType(t: Type | null): Type {
	if (t == null || t.kind != TypeKind.Conditional) return t != null ? t : inferredType();
	if (t.typeChildren.length < 4) return t;
	const check = t.typeChildren[0];
	// Defer if check type still has unresolved generic params (not yet substituted)
	if (hasGenericParams(check)) return t;
	const param = distributiveParam(t);
	if (param == null) return conditionalFor(t, check, [], []);
	const members = mappedSourceMembers(check);
	if (members.length == 0) return conditionalFor(t, check, [param], [check]);
	const parts: Type[] = [];
	for (const m of members) {
		const part = conditionalFor(t, m, [param], [m]);
		if (part == t) return t;
		parts.push(part);
	}
	return unionOfParts(parts);
}

function conditionalFor(t: Type, check: Type, params: Type[], concretes: Type[]): Type {
	const ext = params.length > 0 ? substituteParams(t.typeChildren[1], params, concretes) : t.typeChildren[1];
	if (hasGenericParams(ext)) {
		const bindings = createUnifyBindings();
		unifyType(ext, check, bindings);
		const inferParams = inferParamsOf(t);
		for (let i = bindings.params.length - 1; i >= 0; i -= 1) {
			if (inferParams.indexOf(bindings.params[i]) >= 0) continue;
			bindings.names.splice(i, 1);
			bindings.params.splice(i, 1);
			bindings.types.splice(i, 1);
		}
		for (const gp of inferParams) {
			if (boundSlot(bindings, gp) < 0) bindParam(bindings, gp, unknownType());
		}
		const inferredExt = substituteBound(ext, bindings);
		if (hasGenericParams(inferredExt)) return t;
		if (!isAssignableForConditional(check, inferredExt)) return branchFor(t.typeChildren[3], params, concretes);
		for (let i = 0; i < params.length; i += 1) bindParam(bindings, params[i], concretes[i]);
		return substituteBound(t.typeChildren[2], bindings);
	}
	return branchFor(isAssignableForConditional(check, ext) ? t.typeChildren[2] : t.typeChildren[3], params, concretes);
}

function branchFor(branch: Type, params: Type[], concretes: Type[]): Type {
	return params.length > 0 ? substituteParams(branch, params, concretes) : branch;
}

// Simplified assignability check for conditional type evaluation.
// Uses the main isAssignable but avoids circular dependency.
let _condAssignFn: (source: Type, target: Type) => boolean = null as unknown as (source: Type, target: Type) => boolean;
export function setConditionalAssignFn(fn: (source: Type, target: Type) => boolean): void {
	_condAssignFn = fn;
}
function isAssignableForConditional(source: Type, target: Type): boolean {
	if (_condAssignFn != null) return _condAssignFn(source, target);
	return source.kind == target.kind;
}

// Indexed access type — T[K], deferred while T or K is generic.
// typeChildren[0] = object type (T)
// typeChildren[1] = index type (K)
export function createIndexedAccessType(objectType: Type, indexType: Type): Type {
	const t = emptyType();
	t.kind = TypeKind.IndexedAccess;
	t.typeChildren = [objectType, indexType];
	return t;
}

// The type of the property a string literal index names, a union of them for a union of
// literals; the deferred type while either side is generic; null when a key names no property.
export function indexedAccessOf(objectType: Type, indexType: Type): Type | null {
	if (hasGenericParams(objectType) || hasGenericParams(indexType)) return createIndexedAccessType(objectType, indexType);
	if (indexType.kind != TypeKind.Union) return memberOfKey(objectType, indexType);
	if (!isKeyUnion(indexType)) return null;
	const members: Type[] = [];
	for (const key of indexType.typeChildren) {
		const member = memberOfKey(objectType, key);
		if (member == null) return null;
		if (members.indexOf(member) < 0) members.push(member);
	}
	return members.length == 1 ? members[0] : createUnion(members);
}

function arrayOf(t: Type): Type | null {
	const peeled = skipModifier(t);
	const array = peeled != null ? unwrapRef(peeled) : null;
	return array != null && array.kind == TypeKind.Array ? array : null;
}

export function isArrayType(t: Type): boolean { return arrayOf(t) != null; }

// E[][number] is E and E[]["length"] is number; a struct's key is the field it names.
function memberOfKey(objectType: Type, key: Type): Type | null {
	const array = arrayOf(objectType);
	if (array != null) {
		if (isNumeric(key)) return array.typeReturn;
		return key.kind == TypeKind.StringLiteral && key.typeName == "length" ? numberType() : null;
	}
	const tuple = peelTransparentInstance(unwrapRef(objectType));
	if (tuple.kind == TypeKind.Tuple) {
		const at = key.kind == TypeKind.StringLiteral || key.kind == TypeKind.NumberLiteral ? parseIntStrict(key.typeName) : -1;
		return at >= 0 && at < tuple.typeChildren.length ? tuple.typeChildren[at] : null;
	}
	return key.kind == TypeKind.StringLiteral ? findFieldInVariant(objectType, key.typeName) : null;
}

function parseIntStrict(text: string): int32 {
	if (text.length == 0 || text.length > 9) return -1;
	let n = 0;
	for (let i = 0; i < text.length; i += 1) {
		const c = text.byteAt(i);
		if (c < "0".code || c > "9".code) return -1;
		n = n * 10 + (c - "0".code);
	}
	return n;
}

export function evaluateIndexedAccessType(t: Type): Type {
	if (t.typeChildren.length < 2) return t;
	const resolved = indexedAccessOf(t.typeChildren[0], t.typeChildren[1]);
	return resolved != null ? resolved : t;
}

// keyof T, deferred while T is generic. typeChildren[0] = T.
export function createKeyOfType(objectType: Type): Type {
	const t = emptyType();
	t.kind = TypeKind.KeyOf;
	t.typeChildren = [objectType];
	return t;
}

export function evaluateKeyOfType(t: Type): Type {
	if (t.typeChildren.length < 1 || hasGenericParams(t.typeChildren[0])) return t;
	const keys = keyOfType(t.typeChildren[0]);
	return keys != null ? keys : t;
}

// Mapped type `{ [P in C as N]: X }`, deferred while its keys, its template or the object its
// modifiers come from are generic. typeReturn = P (typeNames[0] its name); typeChildren = [C, X]
// and N when written;
// typeExtra = the modifiers type: T of a `keyof T` constraint, or of a `K extends keyof T` one.
export enum MappedModifier {
	IncludeReadonly,
	ExcludeReadonly,
	IncludeOptional,
	ExcludeOptional,
	KeyOfDeclared,
}

function mappedParam(t: Type): Type | null {
	return t.typeReturn;
}

export function mappedModifiers(t: Readonly<Type>): BitSet<MappedModifier> {
	return (t.typeValue as uint8) as BitSet<MappedModifier>;
}

export function createMappedType(param: Type, constraint: Type, template: Type, nameType: Type | null, modifiersType: Type | null, modifiers: BitSet<MappedModifier>): Type {
	const t = emptyType();
	t.kind = TypeKind.Mapped;
	t.typeNames = [param.typeName];
	t.typeReturn = param;
	t.typeChildren = nameType != null ? [constraint, template, nameType] : [constraint, template];
	t.typeExtra = modifiersType;
	t.typeValue = (modifiers as uint8) as int32;
	return t;
}

// The members of a homomorphic mapped type's source that it maps one by one: the
// members of a union, `null` included; none for any other type.
function mappedSourceMembers(source: Type): Type[] {
	if (source.kind == TypeKind.Union) return source.typeChildren;
	if (isMaybeType(source) && source.typeReturn != null) {
		const payload = source.typeReturn!;
		const members: Type[] = payload.kind == TypeKind.Union ? [...payload.typeChildren] : [payload];
		members.push(nullType());
		return members;
	}
	return [];
}

function isObjectSource(t: Type): boolean {
	const s = peelTransparentInstance(unwrapRef(t));
	return s.kind == TypeKind.Struct || s.kind == TypeKind.Tuple || arrayOf(t) != null;
}

function withNullMember(t: Type): Type {
	return isNullableShape([t]) ? t : nullableUnionOf([t, nullType()]);
}

// `T | null` without its null: T; `null` alone is never.
export function withoutNullMember(t: Type): Type {
	if (t.kind == TypeKind.Null) return neverType();
	if (isMaybeType(t)) return unwrapMaybeType(t);
	if (t.kind != TypeKind.Union || t.typeChildren == null) return t;
	const remaining: Type[] = [];
	for (const v of t.typeChildren) {
		if (v.kind != TypeKind.Null) remaining.push(v);
	}
	if (remaining.length == t.typeChildren.length) return t;
	if (remaining.length == 0) return neverType();
	if (remaining.length == 1) return remaining[0];
	return createUnion(remaining);
}

function mappedTemplateAt(t: Type, child: int32, key: Type): Type {
	return substituteParams(t.typeChildren[child], [mappedParam(t)!], [key]);
}

// The keys the constraint names, as property-name literals; null when one is no property name.
function mappedKeys(constraint: Type): Type[] | null {
	const members: Type[] = constraint.kind == TypeKind.Union ? constraint.typeChildren : [constraint];
	const keys: Type[] = [];
	for (const m of members) {
		if (m == null || m.kind == TypeKind.Never) continue;
		if (m.kind != TypeKind.StringLiteral) return null;
		keys.push(m);
	}
	return keys;
}

// The value a homomorphic mapped type over an array or a tuple maps to: the element
// type under key `number`, or each element under its index.
function mappedArrayLike(t: Type, source: Type, mods: BitSet<MappedModifier>): Type {
	const tuple = peelTransparentInstance(unwrapRef(source));
	const readonly = mods.has(MappedModifier.IncludeReadonly)
		|| (!mods.has(MappedModifier.ExcludeReadonly) && isReadonlyView(source));
	if (tuple.kind == TypeKind.Tuple) {
		const elements: Type[] = [];
		for (let i = 0; i < tuple.typeChildren.length; i += 1) {
			const element = mappedTemplateAt(t, 1, createStringLiteral(String(i)));
			if (hasGenericParams(element)) return t;
			elements.push(mods.has(MappedModifier.IncludeOptional) ? withNullMember(element) : element);
		}
		const mapped = createTuple(elements);
		const required = getMinArity(tuple);
		if (mods.has(MappedModifier.IncludeOptional)) setMinArity(mapped, 0);
		else if (!mods.has(MappedModifier.ExcludeOptional) && required < tuple.typeChildren.length) setMinArity(mapped, required);
		return mapped;
	}
	let element = mappedTemplateAt(t, 1, numberType());
	if (hasGenericParams(element)) return t;
	if (mods.has(MappedModifier.IncludeOptional)) element = withNullMember(element);
	const array = createRef(createArray(element));
	return readonly ? createReadonlyView(array) : array;
}

// Reference: resolveMappedTypeMembers — one property per key of the constraint; `?` and
// `readonly` from the modifiers, else inherited from the modifiers type's property.
// `{ readonly [P in keyof T]: T[P] }` keeps T's members and only forbids writes: the read-only
// view of T itself.
function isReadonlyOnly(t: Type, source: Type, mods: BitSet<MappedModifier>): boolean {
	if (!mods.has(MappedModifier.IncludeReadonly) || mods.has(MappedModifier.IncludeOptional) || mods.has(MappedModifier.ExcludeOptional)) return false;
	const template = t.typeChildren[1];
	return template.kind == TypeKind.IndexedAccess && template.typeChildren.length == 2
		&& template.typeChildren[0] == source
		&& template.typeChildren[1] == mappedParam(t);
}

export function evaluateMappedType(t: Type): Type {
	if (t.kind != TypeKind.Mapped || t.typeChildren.length < 2) return t;
	const mods = mappedModifiers(t);
	const source = t.typeExtra;
	if (source != null && hasGenericParams(source)) return t;
	if (mods.has(MappedModifier.KeyOfDeclared) && source != null && t.typeChildren.length == 2) {
		if (!isObjectSource(source) && mappedSourceMembers(source).length == 0) return source;
		if (arrayOf(source) != null || peelTransparentInstance(unwrapRef(source)).kind == TypeKind.Tuple) return mappedArrayLike(t, source, mods);
		if (isReadonlyOnly(t, source, mods)) return createReadonlyView(source);
	}
	const constraint = t.typeChildren[0];
	if (hasGenericParams(constraint)) return t;
	const keys = mappedKeys(constraint);
	if (keys == null) return t;
	const modifiersStruct = source != null ? peelToStruct(source) : null;
	const optionalOfSource: string[] = modifiersStruct != null && modifiersStruct.kind == TypeKind.Struct && modifiersStruct.optionalFields != null
		? modifiersStruct.optionalFields : [];
	const names: string[] = [];
	const types: Type[] = [];
	const optional: string[] = [];
	for (const key of keys) {
		const propNames: Type[] = [];
		if (t.typeChildren.length > 2) {
			const named = mappedTemplateAt(t, 2, key);
			if (hasGenericParams(named)) return t;
			const remapped = mappedKeys(named);
			if (remapped == null) return t;
			for (const n of remapped) propNames.push(n);
		} else {
			propNames.push(key);
		}
		for (const propName of propNames) {
			const name = propName.typeName;
			if (names.indexOf(name) >= 0) return t;
			const sourceOptional = optionalOfSource.indexOf(key.typeName) >= 0;
			const isOptional = mods.has(MappedModifier.IncludeOptional) || (!mods.has(MappedModifier.ExcludeOptional) && sourceOptional);
			let propType = mappedTemplateAt(t, 1, key);
			if (hasGenericParams(propType) || propType.kind == TypeKind.IndexedAccess) return t;
			if (isOptional) propType = withNullMember(propType);
			else if (sourceOptional) propType = withoutNullMember(propType);
			names.push(name);
			types.push(propType);
			if (isOptional) optional.push(name);
		}
	}
	const struct = createStruct("", names, types, true);
	if (optional.length > 0) struct.optionalFields = optional;
	const result = createRef(struct);
	const readonly = mods.has(MappedModifier.IncludeReadonly)
		|| (!mods.has(MappedModifier.ExcludeReadonly) && source != null && isReadonlyView(source));
	return readonly ? createReadonlyView(result) : result;
}

// A mapped type waits while its keys, its source or its template name an outer type parameter.
export function mappedIsGeneric(t: Type): boolean {
	if (hasGenericParams(t.typeChildren[0]) || (t.typeExtra != null && hasGenericParams(t.typeExtra))) return true;
	for (let ci = 1; ci < t.typeChildren.length; ci += 1) {
		if (hasGenericParams(mappedTemplateAt(t, ci, neverType()))) return true;
	}
	return false;
}

// The key type of a mapped type whose keys are all of `string` or of `number`: an index signature.
export function mappedIndexKey(t: Type): Type | null {
	const key = t.typeChildren[0];
	if (t.typeChildren.length > 2 || (key.kind != TypeKind.String && !isNumeric(key))) return null;
	return key;
}

export function mappedValueAt(t: Type, key: Type): Type {
	const value = mappedTemplateAt(t, 1, key);
	return mappedModifiers(t).has(MappedModifier.IncludeOptional) ? withNullMember(value) : value;
}

// Why a mapped type with nothing generic left did not become an object type.
export function mappedRefusal(t: Type): string {
	const source = t.typeExtra;
	const constraint = t.typeChildren[0];
	const shown = typeDisplayName(constraint);
	if (source != null && mappedModifiers(t).has(MappedModifier.KeyOfDeclared) && mappedSourceMembers(source).length == 0 && !isObjectSource(source)) {
		return "it maps over '" + typeDisplayName(source) + "', which has no properties";
	}
	const keys = mappedKeys(constraint);
	if (keys == null) {
		const members: Type[] = constraint.kind == TypeKind.Union ? constraint.typeChildren : [constraint];
		for (const m of members) {
			if (m.kind == TypeKind.String || isNumeric(m)) return "its keys '" + shown + "' name no fixed set of properties: write '{ [key: " + typeDisplayName(m) + "]: V }' or 'Map<" + typeDisplayName(m) + ", V>'";
			if (m.kind != TypeKind.StringLiteral && m.kind != TypeKind.Never) return "its key '" + typeDisplayName(m) + "' is no property name: a key is a string literal type";
		}
	}
	if (t.typeChildren.length > 2) return "its 'as' clause does not give string literal property names, one per key";
	return "its template '" + typeDisplayName(t.typeChildren[1]) + "' does not resolve for every key of '" + shown + "'";
}

function mappedDisplay(t: Readonly<Type>): string {
	if (t.typeChildren.length < 2 || t.typeNames.length < 1) return "unknown";
	const mods = mappedModifiers(t);
	const readonly = mods.has(MappedModifier.IncludeReadonly) ? "readonly " : mods.has(MappedModifier.ExcludeReadonly) ? "-readonly " : "";
	const optional = mods.has(MappedModifier.IncludeOptional) ? "?" : mods.has(MappedModifier.ExcludeOptional) ? "-?" : "";
	const constraint = mods.has(MappedModifier.KeyOfDeclared) && t.typeExtra != null ? "keyof " + typeDisplayName(t.typeExtra) : typeDisplayName(t.typeChildren[0]);
	const remap = t.typeChildren.length > 2 ? " as " + typeDisplayName(t.typeChildren[2]) : "";
	return "{ " + readonly + "[" + t.typeNames[0] + " in " + constraint + remap + "]" + optional + ": " + typeDisplayName(t.typeChildren[1]) + " }";
}

// A constraint that holds only property names: a string literal, a union of them, or keyof T.
export function isKeyConstraint(t: Type | null): boolean {
	return t != null && (t.kind == TypeKind.StringLiteral || t.kind == TypeKind.KeyOf || isAllStringLiteralUnion(t) || isKeyUnion(t));
}

// A union of property names, with `number` for the indices of an array (keyof E[]).
function isKeyUnion(t: Type): boolean {
	if (t.kind != TypeKind.Union || t.typeChildren.length == 0) return false;
	for (const child of t.typeChildren) {
		if (child == null || (child.kind != TypeKind.StringLiteral && !isNumeric(child))) return false;
	}
	return true;
}

// keyof T for an object type: the union of its property names as string literal types;
// keyof E[] is `number | "length"`, an array's methods being no keys in MetaScript.
export function keyOfType(objectType: Type): Type | null {
	if (arrayOf(objectType) != null) return createUnionInOrder([numberType(), createStringLiteral("length")]);
	const s = peelToStruct(objectType);
	if (s == null || s.typeNames == null || s.typeNames.length == 0) return null;
	const keys: Type[] = [];
	for (const name of s.typeNames) keys.push(createStringLiteral(name));
	return keys.length == 1 ? keys[0] : createUnionInOrder(keys);
}

export function isAllStringLiteralUnion(t: Readonly<Type | null>): boolean {
	if (t == null || t.kind != TypeKind.Union) return false;
	if (t.typeChildren.length == 0) return false;
	for (const child of t.typeChildren) {
		if (child == null || child.kind != TypeKind.StringLiteral) return false;
	}
	return true;
}

export function numberLiteralSet(t: Type | null): Type[] | null;
export function numberLiteralSet(t: Readonly<Type | null>): Readonly<Type[] | null>;
export function numberLiteralSet(t: Readonly<Type | null>): Readonly<Type[] | null> {
	if (t == null) return null;
	const single: Readonly<Type>[] = [t];
	const members: Readonly<Type[]> = t.kind == TypeKind.NumberLiteral ? single : literalUnionBase(t) != null && literalUnionBase(t)!.kind != TypeKind.String ? t.typeChildren : [];
	if (members.length == 0) return null;
	for (const m of members) if (!isNumeric(numberLiteralBase(m))) return null;
	return members;
}

// isStringLike — true for String, StringLiteral, and Union<StringLiteral...>.
// Single source of truth: these are all msString at runtime.
export function isStringLike(t: Readonly<Type | null>): boolean {
	if (t == null) return false;
	if (t.kind == TypeKind.String || t.kind == TypeKind.StringLiteral) return true;
	return isAllStringLiteralUnion(t);
}

export function isFloatType(t: Readonly<Type | null>): boolean {
	if (t == null) return false;
	return t.kind == TypeKind.Float32 || t.kind == TypeKind.Float64;
}

// Single source of truth for what may live inside a primitive union
// (`float32 | string`): the tagged-struct lowering only knows how to carry
// these as raw C payload members.
export function isPrimitiveUnionMember(m: Readonly<Type | null>): boolean {
	if (m == null) return false;
	if (m.kind == TypeKind.Null || m.kind == TypeKind.String || m.kind == TypeKind.StringLiteral
		|| m.kind == TypeKind.Boolean || m.kind == TypeKind.BooleanLiteral || m.kind == TypeKind.NumberLiteral) return true;
	return isNumeric(m);
}

// True for unions lowered to `{ _tag; union {...} }` in C. All-strlit unions
// are msString-carried (no _tag) and must never take this path.
export function isTagCarriedUnion(t: Readonly<Type | null>): boolean {
	if (t == null || t.kind != TypeKind.Union) return false;
	if (t.typeChildren == null || t.typeChildren.length == 0) return false;
	return literalUnionBase(t) == null;
}

export function typeofTagOf(t: Readonly<Type | null>): string {
	if (t == null) return "object";
	const v = peelTransparentInstance(t);
	if (v.kind == TypeKind.Set) return typeofTagOf(setRepr(v));
	if (isNumeric(v) || v.kind == TypeKind.NumberLiteral || v.kind == TypeKind.Enum || v.kind == TypeKind.EnumLiteral) return "number";
	if (v.kind == TypeKind.String || v.kind == TypeKind.StringLiteral) return "string";
	if (v.kind == TypeKind.Boolean || v.kind == TypeKind.BooleanLiteral) return "boolean";
	if (v.kind == TypeKind.Function) return "function";
	if (v.kind == TypeKind.BigInt) return "bigint";
	return "object";
}

export function primitiveKindName(t: Type | null): string {
	if (t == null) return "";
	return match (peelTransparentInstance(t).kind) {
		TypeKind.Int8 => "int8",
		TypeKind.Int16 => "int16",
		TypeKind.Int32 => "int32",
		TypeKind.Int64 => "int64",
		TypeKind.Uint8 => "uint8",
		TypeKind.Uint16 => "uint16",
		TypeKind.Uint32 => "uint32",
		TypeKind.Uint64 => "uint64",
		TypeKind.Float32 => "float32",
		TypeKind.Float64 => "float64",
		TypeKind.Char => "char",
		TypeKind.CString => "cstring",
		_ => "",
	};
}

export function isPrimitiveKindName(s: string): boolean {
	return match (s) {
		"int8" | "int16" | "int32" | "int64" | "uint8" | "uint16" | "uint32" | "uint64" => true,
		"float32" | "float64" | "char" | "cstring" => true,
		_ => false,
	};
}

// A value whose held kind no member tag answers: `unknown`, or a nullable
// whose payload is itself a union, which keeps no tag for the payload member.
export function holdsNoExactKind(t: Type): boolean {
	const v = peelTransparentInstance(t);
	if (isUnknownType(v)) return true;
	if (!isMaybeType(v) || v.typeReturn == null) return false;
	const payload = peelTransparentInstance(v.typeReturn!);
	return isUnknownType(payload) || isMaybeType(payload) || isTagCarriedUnion(payload);
}

export function typeofNameMatches(t: Type, name: string): boolean {
	return isPrimitiveKindName(name) ? primitiveKindName(t) == name : typeofTagOf(t) == name;
}

export function jsMemberKind(t: Type): string {
	if (t.kind == TypeKind.Null) return "null";
	if (t.kind == TypeKind.Ref && runtimeClassSym(t.typeReturn) != null) return "class";
	if (isArrayShaped(t) || t.kind == TypeKind.Tuple) return "array";
	return typeofTagOf(t);
}

export function unionHasMemberOfKind(t: Type | null, kind: TypeKind): boolean {
	if (t == null || t.kind != TypeKind.Union || t.typeChildren == null) return false;
	for (const m of t.typeChildren) {
		if (m != null && m.kind == kind) return true;
	}
	return false;
}

export function soleUnionMember(u: Type | null, pred: (t: Type) => boolean): Type | null {
	if (u == null || u.kind != TypeKind.Union || u.typeChildren == null) return null;
	let found: Type | null = null;
	for (const m of u.typeChildren) {
		if (m == null) continue;
		const inner = peelTransparentInstance(m);
		if (!pred(inner)) continue;
		if (found != null) return null;
		found = inner;
	}
	return found;
}

export function isFunctionKind(t: Type): boolean {
	return t.kind == TypeKind.Function;
}

export function functionSlotOf(slot: Type | null): Type | null {
	if (slot == null) return null;
	let fn = peelTransparentInstance(slot);
	if (isMaybeType(fn) && fn.typeReturn != null) fn = peelTransparentInstance(fn.typeReturn);
	if (fn.kind == TypeKind.Union) {
		const soleFn = soleUnionMember(fn, isFunctionKind);
		if (soleFn != null) fn = soleFn;
	}
	return fn.kind == TypeKind.Function && fn.typeChildren != null ? fn : null;
}

export function isArrayShaped(t: Type): boolean {
	if (t.kind == TypeKind.Array || t.kind == TypeKind.SizedArray) return true;
	return t.kind == TypeKind.Ref && t.typeReturn != null && t.typeReturn.kind == TypeKind.Array;
}

export function isTypeofTag(s: string): boolean {
	return s == "string" || s == "number" || s == "boolean" || s == "function" || s == "bigint" || s == "object";
}

function isTypeofResult(s: string): boolean {
	return isTypeofTag(s) || s == "symbol" || s == "undefined";
}

export function typeofResultType(): Type {
	const members: Type[] = [];
	for (const tag of ["bigint", "boolean", "function", "number", "object", "string", "symbol", "undefined"]) members.push(createStringLiteral(tag));
	return createUnionInOrder(members);
}

export function isTypeofResultType(t: Type | null): boolean {
	if (t == null || t.kind != TypeKind.Union || t.typeChildren == null || t.typeChildren.length == 0) return false;
	for (const m of t.typeChildren) {
		if (m == null || m.kind != TypeKind.StringLiteral || !isTypeofResult(m.typeName)) return false;
	}
	return true;
}

// ===== Min Arity (Default Parameters) =====
// typeValue holds minArity + 1 so that 0 means "not set" = all params required.

export function setMinArity(t: Type | null, minArity: number): void {
	if (t == null) return;
	t.typeValue = (minArity as int32) + 1;
}

export function callMinArity(t: Type | null): number {
	if (t == null) return 0;
	let min = getMinArity(t);
	while (min > 0 && min <= t.typeChildren.length && acceptsVoid(t.typeChildren[min - 1])) min -= 1;
	return min;
}

function acceptsVoid(t: Type | null): boolean {
	if (t == null) return false;
	if (t.kind == TypeKind.Void) return true;
	if (t.kind != TypeKind.Union) return false;
	for (const member of t.typeChildren) {
		if (member != null && member.kind == TypeKind.Void) return true;
	}
	return false;
}

export function getMinArity(t: Readonly<Type | null>): number {
	if (t == null) return 0;
	const encoded: int32 = t.typeValue;
	if (encoded == 0) return t.typeChildren.length;
	return (encoded - 1) as number;
}

// ===== Attached Ops Helpers (Implementation parity) =====

export function getAttachedOp(t: Type | null, op: AttachedOp): Symbol | null;
export function getAttachedOp(t: Readonly<Type | null>, op: AttachedOp): Readonly<Symbol | null>;
export function getAttachedOp(t: Readonly<Type | null>, op: AttachedOp): Readonly<Symbol | null> {
	if (t == null) return null;
	const idx = op as number;
	if (t.attachedOps.length <= idx) return null;
	return t.attachedOps[idx];
}

export function setAttachedOp(t: Type | null, op: AttachedOp, sym: Symbol | null): void {
	if (t == null) return;
	// Grow array to fit index
	while (t.attachedOps.length <= (op as number)) {
		t.attachedOps.push(null);
	}
	t.attachedOps[op as number] = sym;
}

// Maybe<T> is judged by its payload: the JS backend erases the C `{ value, present }`
// carrier to a native `T | null`, so a copy made for the carrier would deep-copy a
// plain nullable string (corpus 015 "p1=[object Object]").
export function valueCopyRepr(t: Type | null): Type | null;
export function valueCopyRepr(t: Readonly<Type | null>): Readonly<Type | null>;
export function valueCopyRepr(t: Readonly<Type | null>): Readonly<Type | null> {
	const base = distinctBody(t);
	if (base != null) return valueCopyRepr(base);
	if (t != null && t.kind == TypeKind.Struct && t.typeFlags.has(TypeFlag.IsMaybe)) {
		return valueCopyRepr(t.typeReturn);
	}
	if (t != null && t.kind == TypeKind.Set) {
		const repr = setRepr(t);
		if (repr != null) return repr;
	}
	if (t != null && t.kind == TypeKind.GenericInstance && (isStructType(t.typeReturn) || (t.typeReturn != null && t.typeReturn.kind == TypeKind.Union && t.typeReturn.typeFlags.has(TypeFlag.ValueUnion)))) return t.typeReturn;
	return t;
}

export function needsValueCopy(t: Readonly<Type | null>): boolean {
	t = valueCopyRepr(t);
	if (t == null) return false;
	if (t.kind == TypeKind.Struct) return t.typeFlags.has(TypeFlag.IsStruct);
	if (t.kind == TypeKind.Union) return t.typeFlags.has(TypeFlag.ValueUnion);
	if (t.kind == TypeKind.Tuple) return true;
	if (t.kind == TypeKind.Array) return true;
	if (t.kind == TypeKind.SizedArray) return true;
	return false;
}

const PLAIN_DATA_MAX_DEPTH = 64;

export function isPlainDataType(t: Type | null, declaresHook: (owner: Type) => boolean): boolean {
	return plainDataAt(t, declaresHook, 0);
}

function plainDataAt(t: Type | null, declaresHook: (owner: Type) => boolean, depth: int32): boolean {
	if (t == null) return true;
	if (depth > PLAIN_DATA_MAX_DEPTH || isAwaitable(t)) return false;
	const base = distinctBody(t);
	if (base != null) return plainDataAt(base, declaresHook, depth + 1);
	const peeled = peelTransparentInstance(t);
	if (peeled != t) return plainDataAt(peeled, declaresHook, depth + 1);
	if (hasAsgnFlag(t)) return false;
	if (isPrimitiveKind(t.kind)) return true;
	return match (t.kind) {
		TypeKind.Char | TypeKind.BooleanLiteral | TypeKind.EnumLiteral | TypeKind.CString
			| TypeKind.Ptr | TypeKind.Borrow | TypeKind.Span | TypeKind.Set => true,
		TypeKind.Distinct | TypeKind.Alias | TypeKind.Sink | TypeKind.SizedArray => plainDataAt(t.typeReturn, declaresHook, depth + 1),
		TypeKind.Tuple => plainDataAll(t.typeChildren, declaresHook, depth),
		TypeKind.Struct when (isMaybeType(t)) => plainDataAt(t.typeReturn, declaresHook, depth + 1),
		TypeKind.Struct when (isStructType(t)) => !declaresHook(t) && plainDataAll(t.typeChildren, declaresHook, depth),
		TypeKind.Union => !unionHasMemberOfKind(t, TypeKind.StringLiteral) && !declaresHook(t)
			&& plainDataAll(t.typeChildren, declaresHook, depth),
		TypeKind.GenericInstance => t.typeReturn != null && !hasAsgnFlag(t.typeReturn) && !declaresHook(t)
			&& plainDataAt(t.typeReturn, declaresHook, depth + 1),
		_ => false,
	};
}

function plainDataAll(ts: Type[], declaresHook: (owner: Type) => boolean, depth: int32): boolean {
	for (const c of ts) {
		if (!plainDataAt(c, declaresHook, depth + 1)) return false;
	}
	return true;
}

// ===== Tuple Type Name (reference parity: deterministic name for structural types) =====
// DJB2 hash of type structure → "msTuple_HASH". Same algorithm as C codegen
// (types.ms:genTupleType) so generated comparison functions match struct names.

export function tupleTypeName(t: Readonly<Type | null>): string {
	if (t == null || t.kind != TypeKind.Tuple) return "";
	let key = "tuple:";
	let i = 0;
	while (i < t.typeChildren.length) {
		if (i > 0) key = key + ",";
		const child = t.typeChildren[i];
		if (child != null) {
			key = key + typeKey(child);
		}
		i += 1;
	}
	return "msTuple_" + _stdHashToBase36(key);
}

export function spelled(t: Type): Type {
	t.typeFlags = t.typeFlags.incl(TypeFlag.Spelled);
	return t;
}

export function hasTypeIdentity(t: Readonly<Type>): boolean {
	return t.sym != null || t.typeInst != null || t.typeFlags.has(TypeFlag.Spelled)
		|| (t.kind == TypeKind.Distinct && t.typeFlags.has(TypeFlag.BrandWiden));
}

export function nominalTypeKey(t: Readonly<Type>): string {
	const sym = t.sym;
	if (sym != null) {
		const declared = `${sym.modulePath}:${sym.name}:${sym.disamb}`;
		return t.typeFlags.has(TypeFlag.DuVariant) ? duVariantKey(declared, t) : declared;
	}
	if (t.typeInst != null) return typeKey(t.typeInst);
	if (!hasTypeIdentity(t)) throw new Error(`internal: named type '${t.typeName}' (kind ${t.kind as number}) has no declaring symbol`);
	return t.typeName;
}

function duVariantKey(declared: string, t: Readonly<Type>): string {
	let k = declared;
	for (let i = 0; i < t.typeChildren.length; i += 1) {
		k = k + "|" + (i < t.typeNames.length ? t.typeNames[i] : "") + ":" + typeKey(t.typeChildren[i]);
	}
	return k;
}

export function isNominalKind(k: TypeKind): boolean {
	return k == TypeKind.Struct || k == TypeKind.Union || k == TypeKind.Enum || k == TypeKind.Distinct;
}

function genericHeadKey(gi: Readonly<Type>): string {
	let base: Readonly<Type | null> = gi.typeExtra;
	let hops = 0;
	while (base != null && hops < 8
			&& (base.kind == TypeKind.Ref || base.kind == TypeKind.Ptr || base.kind == TypeKind.GenericInstance)) {
		base = base.kind == TypeKind.GenericInstance ? base.typeExtra : base.typeReturn;
		hops = hops + 1;
	}
	if (base != null && base.typeName != "") return nominalTypeKey(base);
	return gi.typeName;
}

// Structural key for tuple naming. tupleTypeName is the SINGLE source of the
// msTuple_<hash> name, so this key need only be internally stable.
function typeKey(t: Readonly<Type>): string {
	return typeKeyIn(t, []);
}

// `keying` holds the types whose keys are being built, so a type met again inside its own key ends
// it; each key owns its list because modules are emitted on parallel workers.
function typeKeyIn(t: Readonly<Type>, keying: Cursor<Readonly<Type>>[]): string {
	if (t == null) return "null";
	for (let i = 0; i < keying.length; i += 1) {
		if (keying[i] == t) return "rec" + (keying.length - i).toString();
	}
	keying.push(t);
	defer keying.pop();
	return typeKeyInner(t, keying);
}

function typeKeyInner(t: Readonly<Type>, keying: Cursor<Readonly<Type>>[]): string {
	if (t == null) return "null";
	if (t.kind == TypeKind.NumberLiteral) return "numlit:" + t.typeName;
	if (t.kind == TypeKind.Alias && t.typeReturn != null) return typeKeyIn(t.typeReturn, keying);
	if (t.kind == TypeKind.GenericParam && t.sym != null) return `${t.typeName}#${t.sym.itemModule}.${t.sym.item}`;
	if (t.typeName != "" && isNominalKind(t.kind)) return t.typeName + "_" + _stdHashToBase36(nominalTypeKey(t));
	if (t.typeName != "" && t.kind != TypeKind.Tuple && t.kind != TypeKind.Function && t.kind != TypeKind.GenericInstance) return t.typeName;
	return match (t.kind) {
		TypeKind.GenericInstance => {
			let k = genericHeadKey(t) + "<";
			let i = 0;
			while (i < t.typeChildren.length) {
				if (i > 0) k = k + ",";
				k = k + (t.typeChildren[i] != null ? typeKeyIn(t.typeChildren[i], keying) : "any");
				i += 1;
			}
			return k + ">";
		},
		TypeKind.Number | TypeKind.Float64 => "float64",
		TypeKind.String => "string",
		TypeKind.Boolean => "boolean",
		TypeKind.Void => "void",
		TypeKind.Int32 => "int32",
		TypeKind.Int64 => "int64",
		TypeKind.Uint32 => "uint32",
		TypeKind.Float32 => "float32",
		TypeKind.BigInt => "bigint",
		TypeKind.Array => {
			return "Array(" + (t.typeReturn != null ? typeKeyIn(t.typeReturn, keying) : "any") + ")";
		},
		TypeKind.Tuple => {
			let k = "tuple:";
			let i = 0;
			while (i < t.typeChildren.length) {
				if (i > 0) k = k + ",";
				k = k + typeKeyIn(t.typeChildren[i], keying);
				i += 1;
			}
			return k;
		},
		TypeKind.Function => {
			let k = "fn(";
			let i = 0;
			while (i < t.typeChildren.length) {
				if (i > 0) k = k + ",";
				k = k + (t.typeChildren[i] != null ? typeKeyIn(t.typeChildren[i], keying) : "any");
				i += 1;
			}
			return k + ")_" + (t.typeReturn != null ? typeKeyIn(t.typeReturn, keying) : "void");
		},
		TypeKind.Union => {
			let k = "union(";
			let i = 0;
			while (i < t.typeChildren.length) {
				if (i > 0) k = k + "|";
				k = k + (t.typeChildren[i] != null ? typeKeyIn(t.typeChildren[i], keying) : "null");
				i += 1;
			}
			return k + ")";
		},
		TypeKind.Span => {
			return "Span(" + (t.typeReturn != null ? typeKeyIn(t.typeReturn, keying) : "any") + ")";
		},
		TypeKind.Set => {
			return "BitSet(" + (t.typeReturn != null ? typeKeyIn(t.typeReturn, keying) : "any") + ")";
		},
		TypeKind.SizedArray => {
			return "SizedArray" + t.typeValue.toString() + "(" + (t.typeReturn != null ? typeKeyIn(t.typeReturn, keying) : "any") + ")";
		},
		TypeKind.Ref => {
			const inner = refSubstInner(t);
			return refWrapperName(t) + "Ref(" + (inner != null ? typeKeyIn(inner, keying) : "any") + ")";
		},
		TypeKind.Ptr => "Ptr(" + (t.typeReturn != null ? typeKeyIn(t.typeReturn, keying) : "any") + ")",
		TypeKind.Borrow => "Borrow(" + (t.typeReturn != null ? typeKeyIn(t.typeReturn, keying) : "any") + ")",
		TypeKind.Var => "Var(" + (t.typeReturn != null ? typeKeyIn(t.typeReturn, keying) : "any") + ")",
		TypeKind.Sink => "Sink(" + (t.typeReturn != null ? typeKeyIn(t.typeReturn, keying) : "any") + ")",
		TypeKind.Cursor => "Cursor(" + (t.typeReturn != null ? typeKeyIn(t.typeReturn, keying) : "any") + ")",
		TypeKind.Struct => {
			let k = "anon(";
			let i = 0;
			while (i < t.typeChildren.length) {
				if (i > 0) k = k + ",";
				k = k + (i < t.typeNames.length ? t.typeNames[i] : "") + ":" + (t.typeChildren[i] != null ? typeKeyIn(t.typeChildren[i], keying) : "any");
				i += 1;
			}
			return k + ")";
		},
		_ => t.kind.toString(),
	};
}

// ===== Type Classification Helpers =====

export function isStructType(t: Readonly<Type | null>): boolean {
	if (t == null) return false;
	if (t.kind == TypeKind.Alias) return isStructType(t.typeReturn);
	if (t.kind != TypeKind.Struct) return false;
	return t.typeFlags.has(TypeFlag.IsStruct);
}

// The actor's handle: the member resolveActor appends after the declared state.
export function actorHandleIndex(t: Type): int32 {
	return t.sym != null && t.sym.symbolKind == SymbolKind.Actor && t.typeNames.length > 0 ? t.typeNames.length - 1 : -1;
}

export function isMaybeType(t: Readonly<Type | null>): boolean {
	if (t == null) return false;
	return t.typeFlags.has(TypeFlag.IsMaybe);
}

// Whether `t | null` should wrap into Maybe<T> at the resolver. Pointers
// (Ref/Ptr) stay as Union — codegen unwraps to a bare pointer using NULL
// as the natural sentinel. Null itself is degenerate. Everything else
// (struct, primitive, string, function) needs the `{ value, present }` wrapper
// because there is no spare bit pattern for "absent". Mirrors Nim's
// SomePointer-vs-value-type split (~/projects/nim/lib/pure/options.nim:90-99).
export function isMaybeWrappable(t: Type | null): boolean {
	if (t == null) return false;
	t = peelTransparentInstance(t);
	const body = distinctBody(t);
	if (body != null) t = body;
	if (t.kind == TypeKind.Null) return false;
	if (t.kind == TypeKind.Ref || t.kind == TypeKind.Ptr) return false;
	// unknown is void* in C — pointer branch of the SomePointer split, same as Ref/Ptr
	if (t.kind == TypeKind.Unknown) return false;
	if (t.kind == TypeKind.Function) return true;
	if (isStructType(t)) return true;
	if (isPrimitiveKind(t.kind)) return true;
	if (t.kind == TypeKind.Set) return true;
	if (t.kind == TypeKind.String) return true;
	if (t.kind == TypeKind.StringLiteral) return true;
	if (literalUnionBase(t) != null) return true;
	if (t.kind == TypeKind.SizedArray || t.kind == TypeKind.Tuple || t.kind == TypeKind.Array) return true;
	if (t.kind == TypeKind.GenericInstance) return t.typeExtra != null && isStructType(t.typeExtra);
	return false;
}

export function unwrapMaybeType(t: Type): Type {
	const inner = t.typeReturn;
	return inner != null ? inner : t;
}

// C-repr query for `unknown` (void*) interop: kinds already living in a
// pointer-sized slot. Value-shaped kinds (string/struct/closure/numeric) have
// no lossless void* form — implicit flows and reinterpret casts must error
// (Nim parity: typeRel tyPointer accepts only nil/ptr/proc/cstring —
// sigmatch.nim:1602). GenericParam/Error/Never defer to instantiation recheck.
export function isPointerShapedForUnknown(t: Type | null): boolean {
	if (t == null) return true;
	const inner = skipModifier(t);
	if (inner == null) return true;
	if (inner.kind == TypeKind.Union) {
		const held = unwrapRefNullUnion(inner);
		return held != null && isPointerShapedForUnknown(held);
	}
	return match (inner.kind) {
		TypeKind.Unknown | TypeKind.Null | TypeKind.Ref | TypeKind.Ptr | TypeKind.Borrow
			| TypeKind.CString | TypeKind.GenericParam | TypeKind.Error | TypeKind.Never => true,
		TypeKind.None | TypeKind.Inferred => false,
		_ => false,
	};
}

export enum UnknownRefusal { None, Address, Value, Builtin }

export function unknownRefusal(t: Type | null): UnknownRefusal {
	if (t == null) return UnknownRefusal.None;
	const inner = skipModifier(t);
	if (inner == null) return UnknownRefusal.None;
	const held = inner.kind == TypeKind.Union ? unwrapRefNullUnion(inner) : inner;
	if (held == null) return UnknownRefusal.Value;
	if (held.kind == TypeKind.Ref && !isClassOrInterfaceObject(held)) return UnknownRefusal.Builtin;
	return match (held.kind) {
		TypeKind.Unknown | TypeKind.Null | TypeKind.Ref | TypeKind.GenericParam | TypeKind.Error | TypeKind.Never => UnknownRefusal.None,
		TypeKind.Ptr | TypeKind.Borrow | TypeKind.CString => UnknownRefusal.Address,
		_ => UnknownRefusal.Value,
	};
}

function isClassOrInterfaceObject(ref: Type): boolean {
	if (isAtomicRef(ref)) return false;
	const builtin = getBuiltinKind(ref);
	if (builtin != "" && builtin != "MetaNode") return false;
	if (ref.sym != null && ref.sym.symbolKind == SymbolKind.Actor) return false;
	const body = ref.typeReturn;
	return body != null && (body.kind == TypeKind.Struct || body.kind == TypeKind.GenericInstance);
}

export enum ObjConv { None, Checked, BadTarget }

export function objectConversion(src: Type | null, target: Type | null): ObjConv {
	const s = heldObjectOrUnknown(src);
	const t = heldTarget(target);
	if (s == null || t == null) return ObjConv.None;
	if (isUnknownType(t) || t.kind == TypeKind.Ptr || t.kind == TypeKind.Borrow) return ObjConv.None;
	const checkable = isRuntimeCheckedClass(t);
	if (isUnknownType(s)) return checkable ? ObjConv.Checked : ObjConv.BadTarget;
	if (!checkable || isClassOrSubclass(s, t)) return ObjConv.None;
	return ObjConv.Checked;
}

function heldTarget(t: Type | null): Type | null {
	const bare = t != null ? skipModifier(t) : null;
	if (bare == null) return null;
	return bare.kind == TypeKind.Union ? unwrapRefNullUnion(bare) : bare;
}

function heldObjectOrUnknown(t: Type | null): Type | null {
	const held = heldTarget(t);
	if (held == null) return null;
	if (isUnknownType(held)) return held;
	if (held.kind != TypeKind.Ref || held.typeReturn == null) return null;
	const body = held.typeReturn;
	return body.kind == TypeKind.Struct || body.kind == TypeKind.GenericInstance ? held : null;
}

function isRuntimeCheckedClass(t: Type): boolean {
	return runtimeClassSym(t.kind == TypeKind.Ref ? t.typeReturn : null) != null;
}

export function unionMemberDisplay(m: Readonly<Type>): string {
	const body = m.kind == TypeKind.Ref ? m.typeReturn : null;
	return body != null && (body.kind == TypeKind.Struct || body.kind == TypeKind.GenericInstance) ? typeDisplayName(body) : typeDisplayName(m);
}

export function runtimeClassSym(body: Type | null): Symbol | null;
export function runtimeClassSym(body: Readonly<Type | null>): Readonly<Symbol | null>;
export function runtimeClassSym(body: Readonly<Type | null>): Readonly<Symbol | null> {
	if (body == null) return null;
	const instance = body.kind == TypeKind.GenericInstance;
	const cls = instance ? genericInstanceClass(body) : body;
	if (cls == null || cls.kind != TypeKind.Struct || cls.sym == null || cls.sym.symbolKind != SymbolKind.Class) return null;
	return instance && cls.sym.symFlags.has(SymbolFlag.ImportC) ? null : cls.sym;
}

function genericInstanceClass(gi: Type): Type | null;
function genericInstanceClass(gi: Readonly<Type>): Readonly<Type | null>;
function genericInstanceClass(gi: Readonly<Type>): Readonly<Type | null> {
	const base: Readonly<Type | null> = gi.typeExtra;
	return base != null && base.kind == TypeKind.Ref ? base.typeReturn : base;
}

export function classParentOf(t: Type | null): Type | null {
	if (t == null) return null;
	const s = t.kind == TypeKind.Ref && t.typeReturn != null ? t.typeReturn : t;
	if (s.kind == TypeKind.GenericInstance) {
		const cls = genericInstanceClass(s);
		if (cls == null || cls.kind != TypeKind.Struct || cls.typeExtra == null) return null;
		return inInstance(s, cls.typeExtra);
	}
	return s.kind == TypeKind.Struct ? s.typeExtra : null;
}

function inInstance(instance: Type, declared: Type): Type {
	const names = splitTopLevel(genericParamsOf(instance), ",");
	if (names.length == 0 || names.length > instance.typeChildren.length) return declared;
	return substituteParams(declared, declaredParamsOf(instance, names.length), instance.typeChildren.slice(0, names.length));
}

export function declaredBasesOf(t: Type | null): Type[] {
	if (t == null) return [];
	const s = t.kind == TypeKind.Ref && t.typeReturn != null ? t.typeReturn : t;
	const body = s.kind == TypeKind.GenericInstance ? genericInstanceClass(s) : s;
	const decl = body != null && body.sym != null ? body.sym.declNode : null;
	if (decl == null || decl.baseExprs == null) return [];
	const bases: Type[] = [];
	for (const base of decl.baseExprs) {
		if (base.nodeType == null || isUnresolvedType(base.nodeType) || base.nodeType.kind == TypeKind.Error) continue;
		bases.push(s.kind == TypeKind.GenericInstance ? inInstance(s, base.nodeType) : base.nodeType);
	}
	return bases;
}

export function classAncestorInstance(t: Type | null, target: Type): Type | null {
	const tgt = target.kind == TypeKind.Ref && target.typeReturn != null ? target.typeReturn : target;
	const tgtClass = tgt.kind == TypeKind.GenericInstance ? genericInstanceClass(tgt) : tgt;
	if (tgtClass == null || tgtClass.kind != TypeKind.Struct || tgtClass.sym == null || tgtClass.sym.symbolKind != SymbolKind.Class) return null;
	let cur = classParentOf(t);
	for (let depth = 0; cur != null && depth < PEEL_MAX_DEPTH; depth += 1) {
		const body = cur.kind == TypeKind.Ref && cur.typeReturn != null ? cur.typeReturn : cur;
		const cls = body.kind == TypeKind.GenericInstance ? genericInstanceClass(body) : body;
		if (cls != null && cls.sym == tgtClass.sym && (body.kind == TypeKind.GenericInstance) == (tgt.kind == TypeKind.GenericInstance)) return body;
		cur = classParentOf(body);
	}
	return null;
}

export function declaredAncestorInstance(t: Type | null, target: Type): Type | null {
	const tgt = target.kind == TypeKind.Ref && target.typeReturn != null ? target.typeReturn : target;
	const origin = tgt.kind == TypeKind.GenericInstance ? genericInstanceClass(tgt) : null;
	if (origin == null || origin.sym == null) return null;
	let level = declaredBasesOf(t);
	for (let depth = 0; level.length > 0 && depth < PEEL_MAX_DEPTH; depth += 1) {
		const next: Type[] = [];
		for (const cur of level) {
			const body = cur.kind == TypeKind.Ref && cur.typeReturn != null ? cur.typeReturn : cur;
			const base = body.kind == TypeKind.GenericInstance ? genericInstanceClass(body) : null;
			if (base != null && base.sym == origin.sym) return body;
			for (const parent of declaredBasesOf(body)) next.push(parent);
		}
		level = next;
	}
	return null;
}

function classOrigin(sym: Symbol | null): Symbol | null {
	return sym != null && sym.instantiatedFrom != null ? sym.instantiatedFrom : sym;
}

export function classBodyOf(t: Type | null): Type | null {
	const body = t != null && t.kind == TypeKind.Ref ? t.typeReturn : t;
	const cls = body != null && body.kind == TypeKind.GenericInstance ? genericInstanceClass(body) : body;
	return cls != null && cls.kind == TypeKind.Struct && cls.sym != null && cls.sym.symbolKind == SymbolKind.Class ? cls : null;
}

function classDepth(t: Type | null, cls: Symbol | null): int32 {
	let cur = classBodyOf(t);
	for (let depth = 0; cur != null && depth < PEEL_MAX_DEPTH; depth += 1) {
		if (classOrigin(cur.sym) == classOrigin(cls)) return depth;
		cur = classBodyOf(cur.typeExtra);
	}
	return -1;
}

// Whether a value of `t` is an instance of some instantiation of the class `cls`.
export function derivesFromClass(t: Type | null, cls: Symbol): boolean {
	if (isAwaitable(t)) return cls.builtinKind == "Promise";
	return classDepth(t, cls) >= 0;
}

// How many parent steps lead from the class of `t` to the class of `ancestor`; -1 when it is not one.
export function classDistance(t: Type | null, ancestor: Type | null): int32 {
	const target = classBodyOf(ancestor);
	return target != null ? classDepth(t, target.sym) : -1;
}

// The members of a union that `x instanceof cls` selects, for a generic `cls`;
// null when the union holds no instance of `cls`, or holds an ancestor class an
// instance of `cls` could hide behind.
export function genericInstanceMembers(t: Type | null, cls: Symbol): Type[] | null {
	if (t == null || t.kind != TypeKind.Union || t.typeChildren == null) return null;
	const selected: Type[] = [];
	for (const m of t.typeChildren) {
		if (derivesFromClass(m, cls)) {
			selected.push(m);
			continue;
		}
		const ancestor = classBodyOf(m);
		if (ancestor != null && ancestor.sym != null && derivesFromClass(cls.symbolType, ancestor.sym)) return null;
	}
	return selected.length > 0 ? selected : null;
}

function isClassOrSubclass(sub: Type, sup: Type): boolean {
	const supBody = sup.typeReturn;
	const supSym = runtimeClassSym(supBody);
	if (supSym == null) return false;
	let cur: Type | null = sub.kind == TypeKind.Ref ? sub.typeReturn : sub;
	for (let depth = 0; cur != null && depth < PEEL_MAX_DEPTH; depth += 1) {
		if (cur.kind == TypeKind.GenericInstance) cur = genericInstanceClass(cur);
		if (cur == null) return false;
		if (cur.sym == supSym) return supBody.kind != TypeKind.GenericInstance;
		const base: Type | null = cur.typeExtra;
		cur = base != null && base.kind == TypeKind.Ref ? base.typeReturn : base;
	}
	return false;
}

export function smuggledIntoUnknown(src: Type | null, target: Type | null): Type | null {
	const s = src != null ? skipModifier(src) : null;
	const t = target != null ? skipModifier(target) : null;
	if (s == null || t == null) return null;
	const tHeld = t.kind == TypeKind.Union ? unwrapRefNullUnion(t) : t;
	if (isUnknownType(tHeld)) return unknownRefusal(s) != UnknownRefusal.None ? s : null;
	const sHeld = s.kind == TypeKind.Union ? unwrapRefNullUnion(s) : s;
	if (isUnknownType(sHeld)) return unknownRefusal(t) != UnknownRefusal.None ? t : null;
	if (s.kind != TypeKind.Function || t.kind != TypeKind.Function) return null;
	const inReturn = smuggledIntoUnknown(s.typeReturn, t.typeReturn);
	if (inReturn != null) return inReturn;
	for (let i = 0; i < s.typeChildren.length && i < t.typeChildren.length; i += 1) {
		const inParam = smuggledIntoUnknown(s.typeChildren[i], t.typeChildren[i]);
		if (inParam != null) return inParam;
	}
	return null;
}

export function unknownRefusalText(t: Type | null, what: UnknownRefusal): string {
	const shown = typeDisplayName(t);
	if (what == UnknownRefusal.Address) {
		return "cannot hold the raw address " + shown + " as unknown — unknown holds objects; keep a C address as Ptr<void>";
	}
	if (what == UnknownRefusal.Builtin) {
		return "cannot hold " + shown + " as unknown — unknown holds class and interface instances; keep it in a field of a class";
	}
	return "cannot hold the value type " + shown + " as unknown — only objects (class or interface instances) are unknown";
}

// unwrapRef — unwrap Ref<T> or Ptr<T> to get inner type (reference: skip pointer types).
// Caller passes a non-null Type (or pre-narrowed value); typeReturn for Ref/Ptr
// is guaranteed non-null by createRef/createPtr, so the result is non-null.
export function unwrapRef(t: Type): Type {
	if (t.kind == TypeKind.Ref || t.kind == TypeKind.Ptr) {
		const inner = t.typeReturn;
		if (inner != null) return inner;
	}
	return t;
}

// If t is Union(Ref<T>, Null), Union(Ptr<T>, Null), Union(unknown, Null) or
// Union(bigint, Null), or a distinct of one of them with Null, return the
// pointer-shaped member. Otherwise return null.
// Used by codegen to collapse nullable-pointer unions to bare pointer types (the
// null pointer is the natural sentinel — no Maybe wrapper needed).
export function unwrapRefNullUnion(t: Type): Type | null;
export function unwrapRefNullUnion(t: Readonly<Type>): Readonly<Type | null>;
export function unwrapRefNullUnion(t: Readonly<Type>): Readonly<Type | null> {
	if (t == null || t.kind != TypeKind.Union) return null;
	if (t.typeChildren == null || t.typeChildren.length != 2) return null;
	const a = t.typeChildren[0];
	const b = t.typeChildren[1];
	if (a == null || b == null) return null;
	if (isNullablePointer(a) && b.kind == TypeKind.Null) return a;
	if (isNullablePointer(b) && a.kind == TypeKind.Null) return b;
	return null;
}

function isNullablePointer(t: Readonly<Type>): boolean {
	if (t.kind == TypeKind.Cursor) return t.typeReturn != null && isNullablePointer(t.typeReturn);
	const k = (peelToRepr(t) ?? t).kind;
	return k == TypeKind.Ref || k == TypeKind.Ptr || k == TypeKind.Unknown || k == TypeKind.BigInt;
}

export function isNullableBigInt(t: Type | null): boolean {
	const held = t != null && t.kind == TypeKind.Union ? unwrapRefNullUnion(t) : null;
	return held != null && held.kind == TypeKind.BigInt;
}

export function holdsFalsyValue(t: Type): boolean {
	const held = peelTransparentInstance(t);
	const k = held.kind;
	if (k == TypeKind.Ref || k == TypeKind.Ptr || k == TypeKind.Function || k == TypeKind.Array
		|| k == TypeKind.SizedArray || k == TypeKind.Span || k == TypeKind.Tuple || k == TypeKind.Set) return false;
	return !isStructType(held);
}

// ===== Needs RC =====
// Types that need reference counting. Pure type query — no codegen dependency.

export function needsRC(t: Type | null): boolean {
	if (t == null) return false;
	return match (t.kind) {
		TypeKind.String => true,
		TypeKind.Array => true,
		TypeKind.SizedArray => needsRC(t.typeReturn),
		TypeKind.Span => false,
		TypeKind.Set => false,
		TypeKind.Ref => true,
		TypeKind.Tuple => {
			let i = 0;
			while (i < t.typeChildren.length) {
				if (needsRC(t.typeChildren[i])) return true;
				i += 1;
			}
			return false;
		},
		_ => false,
	};
}

// ===== tfHasAsgn Flag — Reference parity: propagated lifecycle management flag =====
// Set on types that need lifecycle management (destroy/copy/sink).
// Propagated bottom-up from children to parents at type construction time.

export function hasAsgnFlag(t: Readonly<Type>): boolean {
	if (t == null) return false;
	return t.typeFlags.has(TypeFlag.HasAsgn);
}

// Does an array element of this type need per-element cleanup — i.e. a per-type
// <Name>ArrayDestroy walker that runs each element's destructor — vs a free-only buffer
// wipe? Single source of truth for the destroyFn selection (codegen box site) AND
// destructorLifting's walker emission; both must agree or a managed element leaks (false
// → free-only) or a walker that was never emitted is referenced (true → link error).
// Mirrors classifyArray's needs-cleanup decision. Tuple elements return false here pending
// their per-type walker emission (tuple-literal codegen).
export function arrayElementNeedsCleanup(elem: Type): boolean {
	if (elem == null) return false;
	if (elem.kind == TypeKind.String || elem.kind == TypeKind.Ref
		|| elem.kind == TypeKind.Ptr || elem.kind == TypeKind.Function
		|| elem.kind == TypeKind.BigInt || elem.kind == TypeKind.Unknown) return true;
	if (elem.kind == TypeKind.Distinct && elem.typeReturn != null) {
		return arrayElementNeedsCleanup(elem.typeReturn);
	}
	// Nested value array (Vec<T>[]): the element owns heap (its own buffer + its elements'
	// heap), so the box-site must pick the per-type <Name>ArrayDestroy walker — never the
	// free-only fallback (else every inner buffer leaks).
	if (elem.kind == TypeKind.Array) return true;
	if (elem.kind == TypeKind.Tuple || (elem.kind == TypeKind.Union && elem.typeName == "")) {
		for (const child of elem.typeChildren) {
			if (arrayElementNeedsCleanup(child)) return true;
		}
		return false;
	}
	let structElem = elem;
	if (elem.kind == TypeKind.GenericInstance && elem.typeExtra != null && elem.typeExtra.kind == TypeKind.Struct) {
		structElem = elem.typeExtra;
	}
	if ((structElem.kind == TypeKind.Struct || structElem.kind == TypeKind.Union) && structElem.typeName != "") {
		const bodyAsgn = elem.kind == TypeKind.GenericInstance && elem.typeReturn != null && hasAsgnFlag(elem.typeReturn);
		return hasAsgnFlag(structElem) || bodyAsgn;
	}
	return false;
}

export function isCountedRef(t: Readonly<Type | null>): boolean {
	if (t == null || isPrimitiveKind(t.kind)) return false;
	return match (t.kind) {
		TypeKind.BigInt | TypeKind.Unknown => true,
		TypeKind.Ref => t.sym == null || t.sym.symbolKind != SymbolKind.Actor,
		TypeKind.GenericInstance => {
			if (isAwaitable(t)) return true;
			const body = distinctBody(t);
			if (body != null) return isCountedRef(body);
			const peeled = peelTransparentInstance(t);
			return peeled != t && isCountedRef(peeled);
		},
		TypeKind.Distinct | TypeKind.Sink => isCountedRef(t.typeReturn),
		TypeKind.Union => {
			const inner = unwrapRefNullUnion(t);
			return inner != null && inner.kind != TypeKind.Ptr
				&& (inner.sym == null || inner.sym.symbolKind != SymbolKind.Actor);
		},
		_ => false,
	};
}

export function isUncountedElement(elem: Readonly<Type | null>): boolean {
	if (elem == null) return false;
	const bare = elem.kind == TypeKind.Union ? unwrapRefNullUnion(elem) : elem;
	return bare != null && (bare.kind == TypeKind.Cursor || (bare.kind == TypeKind.Ptr && !isCountedRef(bare.typeReturn)));
}

export function countedEvictElement(elemType: Type | null): Type | null {
	if (elemType == null) return null;
	const peeled = peelTransparentInstance(elemType);
	if (isUncountedElement(peeled)) return null;
	const bare = peeled.kind == TypeKind.Union ? unwrapRefNullUnion(peeled) : peeled;
	if (bare == null) return null;
	if (bare.kind != TypeKind.Ref && bare.kind != TypeKind.Ptr && !isUnknownType(bare)) return null;
	if (bare.sym != null && bare.sym.symbolKind == SymbolKind.Actor) return null;
	if (bare.kind == TypeKind.Ref && bare.typeReturn != null && bare.typeReturn.kind == TypeKind.Array) return null;
	return bare;
}

export function evictionNeedsElementHook(elem: Type | null): boolean {
	if (elem == null || elem.kind == TypeKind.String || !arrayElementNeedsCleanup(elem)) return false;
	return countedEvictElement(elem) == null && !isUncountedElement(peelTransparentInstance(elem));
}

export function propagateToOwner(parent: Type, child: Type): void {
	if (child != null && (child.typeFlags.has(TypeFlag.HasAsgn) || isAwaitable(child))) {
		parent.typeFlags = parent.typeFlags.incl(TypeFlag.HasAsgn);
	}
	if (isDeclaredStruct(parent)) propagateGenericParam(parent, child);
}

export function isDeclaredStruct(t: Readonly<Type>): boolean {
	if (t.kind != TypeKind.Struct || t.sym == null) return false;
	const declared = t.sym.symbolKind;
	return declared == SymbolKind.Class || declared == SymbolKind.Interface || declared == SymbolKind.Struct || declared == SymbolKind.Actor;
}

export function propagateGenericParam(owner: Type, member: Type | null): void {
	if (!owner.typeFlags.has(TypeFlag.HasGenericParam) && hasGenericParams(member)) {
		owner.typeFlags = owner.typeFlags.incl(TypeFlag.HasGenericParam);
	}
}

// ===== Ownership Modifiers =====
// TypeKind.Lent has no producer; Sink is produced by an explicit `sink` param.

export function skipModifier(t: Type | null): Type | null;
export function skipModifier(t: Readonly<Type | null>): Readonly<Type | null>;
export function skipModifier(t: Readonly<Type | null>): Readonly<Type | null> {
	let cur = t;
	while (cur != null && (cur.kind == TypeKind.Sink || cur.kind == TypeKind.Lent || cur.kind == TypeKind.Var
			|| cur.kind == TypeKind.Cursor || cur.kind == TypeKind.Alias)) {
		cur = cur.typeReturn;
	}
	return cur;
}

export function peelSink(t: Type): Type {
	return t.kind == TypeKind.Sink && t.typeReturn != null ? t.typeReturn : t;
}

export function isViewType(t: Type | null): boolean {
	if (t != null && t.typeReturn == null && t.typeExtra == null && t.typeChildren.length == 0) return t.kind == TypeKind.Var || t.kind == TypeKind.Span || t.kind == TypeKind.Borrow;
	return holdsView(t, new TypeVisitSet());
}

export function holdsViewSkippingClear(t: Type | null, clear: TypeVisitSet): boolean {
	return holdsView(t, clear);
}

function holdsView(t: Type | null, seen: TypeVisitSet): boolean {
	if (t == null) return false;
	if (t.kind == TypeKind.Var || t.kind == TypeKind.Span || t.kind == TypeKind.Borrow) return true;
	if (t.typeReturn == null && t.typeExtra == null && t.typeChildren.length == 0) return false;
	if (!typeVisitAdd(seen, t)) return false;
	return match (t.kind) {
		TypeKind.Sink | TypeKind.Alias | TypeKind.Cursor => holdsView(t.typeReturn, seen),
		TypeKind.Distinct | TypeKind.Array | TypeKind.SizedArray => holdsView(t.typeReturn, seen),
		TypeKind.Ref => holdsView(t.typeReturn, seen),
		TypeKind.GenericInstance => holdsView(t.typeExtra, seen),
		TypeKind.Struct | TypeKind.Tuple | TypeKind.Union => anyChildHoldsView(t, seen),
		_ => false,
	};
}

function anyChildHoldsView(t: Type, seen: TypeVisitSet): boolean {
	for (let i = 0; i < t.typeChildren.length; i += 1) {
		if (holdsView(t.typeChildren[i], seen)) return true;
	}
	return false;
}

export function holdsInferred(t: Type | null): boolean {
	return inferredScan(t, new TypeVisitSet());
}

function inferredScan(t: Type | null, seen: TypeVisitSet): boolean {
	if (t == null) return false;
	if (t.kind == TypeKind.Inferred) return true;
	if (isDeclaredStruct(t) || !typeVisitAdd(seen, t)) return false;
	if (inferredScan(t.typeReturn, seen) || inferredScan(t.typeExtra, seen)) return true;
	for (let i = 0; i < t.typeChildren.length; i += 1) {
		if (inferredScan(t.typeChildren[i], seen)) return true;
	}
	return false;
}

export function mayHoldAddress(t: Readonly<Type | null>): boolean {
	if (t != null && t.typeReturn == null && t.typeExtra == null && t.typeChildren.length == 0) return t.kind == TypeKind.Var || t.kind == TypeKind.Span || t.kind == TypeKind.Borrow || t.kind == TypeKind.Ptr || t.kind == TypeKind.Lent;
	return holdsAddress(t, new TypeVisitSet());
}

function holdsAddress(t: Readonly<Type | null>, seen: TypeVisitSet): boolean {
	if (t == null) return false;
	if (t.kind == TypeKind.Var || t.kind == TypeKind.Span || t.kind == TypeKind.Borrow || t.kind == TypeKind.Ptr || t.kind == TypeKind.Lent) return true;
	if (t.typeReturn == null && t.typeExtra == null && t.typeChildren.length == 0) return false;
	if (!typeVisitAdd(seen, t)) return false;
	return match (t.kind) {
		TypeKind.Sink | TypeKind.Alias | TypeKind.Cursor | TypeKind.Distinct => holdsAddress(t.typeReturn, seen),
		TypeKind.Array | TypeKind.SizedArray | TypeKind.Ref => holdsAddress(t.typeReturn, seen),
		TypeKind.GenericInstance => holdsAddress(t.typeExtra, seen),
		TypeKind.Struct | TypeKind.Tuple | TypeKind.Union => anyChildHoldsAddress(t, seen),
		_ => false,
	};
}

function anyChildHoldsAddress(t: Readonly<Type>, seen: TypeVisitSet): boolean {
	for (let i = 0; i < t.typeChildren.length; i += 1) {
		if (holdsAddress(t.typeChildren[i], seen)) return true;
	}
	return false;
}

export function unwrapPointerLikeForVariant(t: Type | null): Type | null;
export function unwrapPointerLikeForVariant(t: Readonly<Type | null>): Readonly<Type | null>;
export function unwrapPointerLikeForVariant(t: Readonly<Type | null>): Readonly<Type | null> {
	if (t == null) return null;
	const k = t.kind;
	if ((k == TypeKind.Ptr || k == TypeKind.Ref
		|| k == TypeKind.Sink || k == TypeKind.Lent) && t.typeReturn != null) {
		return t.typeReturn;
	}
	return t;
}

// ===== Generic Instantiation =====

// Substitute a generic parameter name with a concrete type throughout a type tree.
// Returns a new Type (does not mutate original).
function typeVisitHas(seen: Cursor<Type>[], t: Type): boolean {
	for (let i = seen.length - 1; i >= 0; i -= 1) {
		if (seen[i] == t) return true;
	}
	return false;
}

const TYPE_VISIT_LINEAR_MAX: int32 = 8;

export class TypeVisitSet {
	entries: Cursor<Readonly<Type>>[];
	table: int32[];
	constructor() {
		this.entries = [];
		this.table = [];
	}
}

function typeVisitSlot(visited: TypeVisitSet, t: Cursor<Readonly<Type>>): int32 {
	const mask: int32 = visited.table.length - 1;
	let h: int32 = ((t as unknown).hash() & (mask as int64)) as int32;
	while (visited.table[h] != 0 && visited.entries[visited.table[h] - 1] != t) h = (h + 1) & mask;
	return h;
}

function typeVisitGrow(visited: TypeVisitSet): void {
	const cap: int32 = visited.table.length == 0 ? 16 : visited.table.length * 2;
	const table: int32[] = new Array(cap);
	visited.table = table;
	for (let i = 0; i < visited.entries.length; i += 1) {
		visited.table[typeVisitSlot(visited, visited.entries[i])] = i + 1;
	}
}

export function typeVisitAdd(visited: TypeVisitSet, t: Cursor<Readonly<Type>>): boolean {
	if (visited.table.length == 0) {
		if (typeVisitHas(visited.entries, t as unknown as Type)) return false;
		visited.entries.push(t);
		if (visited.entries.length > TYPE_VISIT_LINEAR_MAX) typeVisitGrow(visited);
		return true;
	}
	if (visited.table.length < (visited.entries.length + 1) * 2) typeVisitGrow(visited);
	const h = typeVisitSlot(visited, t);
	if (visited.table[h] != 0) return false;
	visited.entries.push(t);
	visited.table[h] = visited.entries.length;
	return true;
}

// Reference parity (instCopyType → newSons + dest[i] = src[i]):
// Copy type with independent arrays. Children copied via push(null) + indexed
// assignment so DRC generates =copy (incref) in C. JS gets independence from push.
function nameInstanceBody(gi: Type, from: Type): void {
	const body = gi.typeReturn;
	if (body != null && body.kind == TypeKind.Union && body != from.typeReturn && from.typeReturn != null && from.typeReturn.typeInst != null) body.typeInst = gi;
}

function copyTypeForSubst(t: Type): Type {
	const result = emptyType();
	result.kind = t.kind;
	result.typeName = t.typeName;
	result.typeReturn = t.typeReturn;
	result.typeExtra = t.typeExtra;
	result.typeFlags = t.typeFlags;
	result.typeValue = t.typeValue;
	result.callConv = t.callConv;
	for (let ci = 0; ci < t.typeChildren.length; ci += 1) {
		result.typeChildren.push(null as unknown as Type);
		result.typeChildren[ci] = t.typeChildren[ci];
	}
	for (let ni = 0; ni < t.typeNames.length; ni += 1) {
		result.typeNames.push("");
		result.typeNames[ni] = t.typeNames[ni];
	}
	for (let oi = 0; oi < t.attachedOps.length; oi += 1) {
		result.attachedOps.push(null);
		result.attachedOps[oi] = t.attachedOps[oi];
	}
	return result;
}

// The bindings without `param`, so a parameter a type operator binds itself is not replaced by
// a substitution from outside it.
function withoutParam(params: Type[], concretes: Type[], param: Type | null): ParamBindings {
	const out: ParamBindings = { params: [], concretes: [] };
	for (let i = 0; i < params.length; i += 1) {
		if (params[i] == param) continue;
		out.params.push(params[i]);
		out.concretes.push(concretes[i]);
	}
	return out;
}

interface ParamBindings {
	params: Type[];
	concretes: Type[];
}

// The check type is substituted; a distributive conditional's parameter stays in the extends
// type and the branches, bound to the check type when the conditional is evaluated.
function substitutedConditionalAll(t: Type, params: Type[], concretes: Type[], active: Cursor<Type>[]): Type {
	if (t.typeChildren.length != 4) return t;
	const inner = withoutParam(params, concretes, distributiveParam(t));
	const cond = copyTypeForSubst(t);
	cond.typeChildren[0] = substituteAllParamsInner(t.typeChildren[0], params, concretes, active);
	for (let ci = 1; ci < 4; ci += 1) {
		cond.typeChildren[ci] = substituteAllParamsInner(t.typeChildren[ci], inner.params, inner.concretes, active);
	}
	return evaluateConditionalType(cond);
}

// Reference: instantiateMappedType — a homomorphic mapped type distributes over a union its
// type variable is instantiated with; P is bound inside the template and the `as` clause only.
function substitutedMapped(t: Type, params: Type[], concretes: Type[], active: Cursor<Type>[]): Type {
	const source = t.typeExtra;
	const variable = mappedModifiers(t).has(MappedModifier.KeyOfDeclared) && source != null && source.kind == TypeKind.GenericParam
		? params.indexOf(source) as int32 : -1;
	const members = variable >= 0 ? mappedSourceMembers(concretes[variable]) : [];
	if (members.length > 0) {
		const parts: Type[] = [];
		for (const m of members) {
			const each: Type[] = [...concretes];
			each[variable] = m;
			parts.push(substitutedMapped(t, params, each, active));
		}
		return unionOfParts(parts);
	}
	const inner = withoutParam(params, concretes, mappedParam(t));
	const m = copyTypeForSubst(t);
	m.typeChildren[0] = substituteAllParamsInner(t.typeChildren[0], params, concretes, active);
	for (let ci = 1; ci < t.typeChildren.length; ci += 1) {
		m.typeChildren[ci] = substituteAllParamsInner(t.typeChildren[ci], inner.params, inner.concretes, active);
	}
	m.typeExtra = source != null ? substituteAllParamsInner(source, params, concretes, active) : null;
	return evaluateMappedType(m);
}

function unionOfParts(all: Type[]): Type {
	const parts: Type[] = [];
	for (const p of all) {
		if (p.kind != TypeKind.Never) parts.push(p);
	}
	if (parts.length == 0) return neverType();
	if (parts.length == 1) return parts[0];
	return isNullableShape(parts) ? nullableUnionOf(parts) : createUnion(parts);
}

function canonicalSubstitutedUnion(copy: Type): Type {
	if (isNullableShape(copy.typeChildren) && !hasGenericParams(copy)) return nullableUnionOf(copy.typeChildren);
	if (copy.typeName != "" || (copy.typeNames != null && copy.typeNames.length > 0)) return copy;
	for (const m of copy.typeChildren) {
		if (m != null && m.kind == TypeKind.Union) return createUnion(copy.typeChildren);
	}
	sortUnionMembers(copy.typeChildren);
	return copy;
}

let _substCount: float64 = 0;
export function substituteParamsProfile(): float64[] { return [_substCount]; }

// Every binding is substituted in ONE tree walk: inferGenericReturn folds
// bindings per call site, and a walk per binding cost ~56s on self-host.
export function substituteParams(t: Type | null, params: Type[], concretes: Type[]): Type {
	const seen: Cursor<Type>[] = [];
	if (!_queryProfilingEnabled) return substituteAllParamsInner(t, params, concretes, seen);
	_substCount = _substCount + 1;
	const r = substituteAllParamsInner(t, params, concretes, seen);
	return r;
}

export function substituteBound(t: Type | null, b: UnifyBindings): Type {
	if (b.params.length == 0) return t != null ? t : inferredType();
	return substituteParams(t, b.params, b.types);
}

function substituteAllParamsInner(t: Type | null, params: Type[], concretes: Type[], seen: Cursor<Type>[]): Type {
	if (t == null) return inferredType();
	if (t.kind == TypeKind.GenericParam) {
		const slot = params.indexOf(withoutReadonlyView(t));
		if (slot < 0) return t;
		return isReadonlyView(t) ? createReadonlyView(concretes[slot]) : concretes[slot];
	}
	if (typeVisitHas(seen, t)) return t;
	seen.push(t);
	const result = substituteAllParamsWalk(t, params, concretes, seen);
	seen.pop();
	return result;
}

function substituteAllParamsWalk(t: Type, params: Type[], concretes: Type[], active: Cursor<Type>[]): Type {
	const result = match (t.kind) {
			TypeKind.Number | TypeKind.String | TypeKind.Boolean |
			TypeKind.Void | TypeKind.Null | TypeKind.Unknown |
			TypeKind.Never | TypeKind.Error | TypeKind.None | TypeKind.Inferred |
			TypeKind.GenericParam | TypeKind.CString => t,
			TypeKind.Array => createArray(substituteAllParamsInner(t.typeReturn, params, concretes, active)),
			TypeKind.SizedArray => createSizedArray(substituteAllParamsInner(t.typeReturn, params, concretes, active), t.typeValue),
			TypeKind.Span => createSpan(substituteAllParamsInner(t.typeReturn, params, concretes, active)),
			TypeKind.Set => createBitSet(substituteAllParamsInner(t.typeReturn, params, concretes, active)),
			TypeKind.Varargs => t.typeChildren.length > 0
				? createVarargs(substituteAllParamsInner(t.typeChildren[0], params, concretes, active))
				: t,
			TypeKind.Function => {
				const fn = copyTypeForSubst(t);
				substituteChildrenInPlaceAll(fn, params, concretes, active);
				fn.typeReturn = substituteAllParamsInner(t.typeReturn, params, concretes, active);
				return fn;
			},
			TypeKind.Union | TypeKind.Tuple => {
				if (t.kind == TypeKind.Union && t.typeName != "" && !hasGenericParams(t)) return t;
				const copy = copyTypeForSubst(t);
				substituteChildrenInPlaceAll(copy, params, concretes, active);
				return t.kind == TypeKind.Union ? canonicalSubstitutedUnion(copy) : copy;
			},
			TypeKind.Ref => rebuildRefLike(t, substituteAllParamsInner(refSubstInner(t), params, concretes, active)),
			TypeKind.Ptr => createPtr(substituteAllParamsInner(t.typeReturn, params, concretes, active)),
			TypeKind.Borrow => createBorrow(substituteAllParamsInner(t.typeReturn, params, concretes, active)),
			TypeKind.Var => substitutedVar(t, substituteAllParamsInner(t.typeReturn, params, concretes, active)),
			TypeKind.Sink => createSink(substituteAllParamsInner(t.typeReturn, params, concretes, active)),
			TypeKind.Cursor => createCursor(substituteAllParamsInner(t.typeReturn, params, concretes, active)),
			TypeKind.Distinct => substitutedDistinct(t, substituteAllParamsInner(t.typeReturn, params, concretes, active)),
			TypeKind.Struct => substituteStructAll(t, params, concretes, active),
			TypeKind.GenericInstance => {
				// typeExtra intentionally NOT walked (walking it cost ~20× compile time).
				const gi = copyTypeForSubst(t);
				substituteChildrenInPlaceAll(gi, params, concretes, active);
				const building = instanceBeingBuilt(gi);
				if (building != null) return building;
				if (gi.typeReturn != null && typeVisitHas(active, gi.typeReturn)) {
					gi.typeReturn = null as unknown as Type;
				} else if (gi.typeReturn != null) {
					gi.typeReturn = substituteAllParamsInner(gi.typeReturn, params, concretes, active);
					nameInstanceBody(gi, t);
				}
				return gi;
			},
			TypeKind.Conditional => substitutedConditionalAll(t, params, concretes, active),
			TypeKind.IndexedAccess => {
				const access = copyTypeForSubst(t);
				substituteChildrenInPlaceAll(access, params, concretes, active);
				return evaluateIndexedAccessType(access);
			},
			TypeKind.KeyOf => {
				const keyOf = copyTypeForSubst(t);
				substituteChildrenInPlaceAll(keyOf, params, concretes, active);
				return evaluateKeyOfType(keyOf);
			},
			TypeKind.Mapped => substitutedMapped(t, params, concretes, active),
			_ => t,
		};
	return isReadonlyView(t) ? createReadonlyView(result) : result;
}

function substitutedDistinct(t: Type, inner: Type): Type {
	if (inner == t.typeReturn) return t;
	const copy = copyTypeForSubst(t);
	copy.typeReturn = inner;
	return copy;
}

function substituteChildrenInPlaceAll(copy: Type, params: Type[], concretes: Type[], seen: Cursor<Type>[]): void {
	for (let ci = 0; ci < copy.typeChildren.length; ci += 1) {
		copy.typeChildren[ci] = substituteAllParamsInner(copy.typeChildren[ci], params, concretes, seen);
	}
}

function substituteStructAll(t: Type, params: Type[], concretes: Type[], seen: Cursor<Type>[]): Type {
	if (isDeclaredStruct(t) && !t.typeFlags.has(TypeFlag.HasGenericParam)) return t;
	const newFieldTypes: Type[] = [];
	let changed = false;
	for (let ci = 0; ci < t.typeChildren.length; ci += 1) {
		const sub = substituteAllParamsInner(t.typeChildren[ci], params, concretes, seen);
		newFieldTypes.push(sub);
		if (sub != t.typeChildren[ci]) changed = true;
	}
	if (!changed) return t;
	if (t.typeFlags.has(TypeFlag.IsMaybe)) {
		return createMaybeType(newFieldTypes[0]);
	}
	const newNames: string[] = [];
	for (let ni = 0; ni < t.typeNames.length; ni += 1) {
		newNames.push(t.typeNames[ni]);
	}
	const result = createStruct(t.typeName, newNames, newFieldTypes, isStructType(t));
	result.typeReturn = t.typeReturn;
	result.typeExtra = t.typeExtra;
	result.optionalFields = t.optionalFields;
	if (t.typeFlags.has(TypeFlag.DuVariant)) {
		result.typeFlags = result.typeFlags.incl(TypeFlag.DuVariant);
		result.sym = t.sym;
	}
	if (t.typeFlags.has(TypeFlag.Spelled)) result.typeFlags = result.typeFlags.incl(TypeFlag.Spelled);
	return result;
}

// ===== Type Unification =====
// Recursively match formal (may contain GenericParam) against concrete (always resolved).
// Extracts bindings into UnifyBindings (parallel arrays: names + types).

export interface UnifyBindings {
	names: string[];
	params: Type[];
	types: Type[];
}

export function createUnifyBindings(): UnifyBindings {
	return { names: [], params: [], types: [] };
}

export function bindParam(b: UnifyBindings, param: Type, t: Type): void {
	b.names.push(param.typeName);
	b.params.push(param);
	b.types.push(t);
}

export function bindAt(b: UnifyBindings, from: UnifyBindings, i: int32): void {
	b.names.push(from.names[i]);
	b.params.push(from.params[i]);
	b.types.push(from.types[i]);
}

export function boundSlot(b: UnifyBindings, param: Type): int32 {
	return b.params.indexOf(param) as int32;
}

// Merge `from` into `into`, skipping any parameter already bound. Stable union:
// arg-driven bindings keep priority, explicit-type-arg bindings fill gaps.
export function mergeUnifyBindings(into: UnifyBindings, from: UnifyBindings): void {
	for (let i = 0; i < from.names.length; i += 1) {
		if (boundSlot(into, from.params[i]) < 0) bindAt(into, from, i);
	}
}

let unifyDepth = 0;

let _unifyCount: float64 = 0;
export function unifyTypeProfile(): float64[] { return [_unifyCount]; }
export function unifyType(formal: Type | null, concrete: Type | null, bindings: UnifyBindings): void {
	if (!_queryProfilingEnabled) { unifyTypeGuard(formal, concrete, bindings); return; }
	_unifyCount = _unifyCount + 1;
	unifyTypeGuard(formal, concrete, bindings);
}
function unifyTypeGuard(formal: Type | null, concrete: Type | null, bindings: UnifyBindings): void {
	if (formal == null || concrete == null) return;
	// Identity check — break circular type references (e.g., Doc → DocData → Doc)
	if (formal == concrete) return;
	// Depth guard — prevent infinite recursion on recursive types (e.g., JsonValue contains JsonValue[])
	if (unifyDepth > 20) return;
	unifyDepth = unifyDepth + 1;
	unifyTypeInner(formal, concrete, bindings);
	unifyDepth = unifyDepth - 1;
}

function unifyTypeInner(formal: Type | null, concrete: Type | null, bindings: UnifyBindings): void {
	if (formal == null) return;
	if (concrete == null) return;
	// Direct generic param match
	if (formal.kind == TypeKind.GenericParam) {
		bindParam(bindings, withoutReadonlyView(formal), closureStorageType(isReadonlyView(formal) ? withoutReadonlyView(concrete) : concrete));
		return;
	}
	if ((formal.kind == TypeKind.Var || formal.kind == TypeKind.Borrow || formal.kind == TypeKind.Cursor || formal.kind == TypeKind.Sink) && formal.typeReturn != null) {
		unifyType(formal.typeReturn, concrete.kind == formal.kind && concrete.typeReturn != null ? concrete.typeReturn : concrete, bindings);
		return;
	}
	if (formal.kind == TypeKind.Span) {
		const source = unwrapRef(concrete);
		if (source.kind == TypeKind.Array || source.kind == TypeKind.SizedArray
				|| source.kind == TypeKind.Span) {
			unifyType(formal.typeReturn, source.typeReturn, bindings);
			return;
		}
		if (source.kind == TypeKind.String || source.kind == TypeKind.StringLiteral) {
			unifyType(formal.typeReturn, charType(), bindings);
			return;
		}
	}
	// Array/Span/Ref/Ptr: unify element types
	if (formal.kind == concrete.kind
		&& (formal.kind == TypeKind.Array || formal.kind == TypeKind.SizedArray
			|| formal.kind == TypeKind.Span || formal.kind == TypeKind.Set || formal.kind == TypeKind.Ref || formal.kind == TypeKind.Ptr)) {
		if (formal.typeReturn != null && concrete.typeReturn != null) {
			unifyType(formal.typeReturn, concrete.typeReturn, bindings);
		}
		return;
	}
	if (concrete.kind == TypeKind.Struct && isMaybeType(concrete) && concrete.typeReturn != null
			&& formal.kind != TypeKind.Union && !isMaybeType(formal)) {
		unifyType(formal, concrete.typeReturn, bindings);
		return;
	}
	// GenericInstance: structural unification of type arguments
	// HashMap<K,V> (formal, with GenericParam children) vs HashMap<string,string> (concrete)
	// Base type must match: HashMap<K,V> unifies with HashMap<string,string> but NOT HashSet<string>
	if (formal.kind == TypeKind.GenericInstance && concrete.kind == TypeKind.GenericInstance) {
		// Affine and plain Promises share typeName "Promise" — their distinction
		// is in flag bits, not in the name. Simple equality covers both.
		const namesMatch = formal.typeName == concrete.typeName;
		if (!namesMatch) {
			const aliased = peelTransparentInstance(concrete);
			if (aliased != concrete) {
				unifyType(formal, aliased, bindings);
				return;
			}
			const ancestor = classAncestorInstance(concrete, formal) ?? declaredAncestorInstance(concrete, formal);
			if (ancestor != null) unifyType(formal, ancestor, bindings);
			return;
		}
		const limit = formal.typeChildren.length < concrete.typeChildren.length ? formal.typeChildren.length : concrete.typeChildren.length;
		for (let gi = 0; gi < limit; gi += 1) {
			unifyType(formal.typeChildren[gi], concrete.typeChildren[gi], bindings);
		}
		return;
	}
	// GenericInstance vs Struct (either direction) — try base type matching
	if (formal.kind == TypeKind.GenericInstance && concrete.kind == TypeKind.Struct) {
		const ancestor = classAncestorInstance(concrete, formal) ?? declaredAncestorInstance(concrete, formal);
		if (ancestor != null) {
			unifyType(formal, ancestor, bindings);
			return;
		}
		const members = positionalFieldsOf(formal);
		if (members != null) unifyType(members, concrete, bindings);
		return;
	}
	if (formal.kind == TypeKind.Struct && concrete.kind == TypeKind.GenericInstance) {
		// Struct("Map") with generic params vs GenericInstance("Map", [string, string])
		// Unify by matching formal's fields against the instantiated body's fields
		if (formal.typeName == concrete.typeName && concrete.typeReturn != null) {
			const body = unwrapRef(concrete.typeReturn);
			if (body.kind == TypeKind.Struct) {
				const limit = formal.typeChildren.length < body.typeChildren.length ? formal.typeChildren.length : body.typeChildren.length;
				for (let i = 0; i < limit; i += 1) {
					unifyType(formal.typeChildren[i], body.typeChildren[i], bindings);
				}
			}
		}
		return;
	}
	// Bridge Union<T, Null> ↔ Maybe<X> for nullable witness inference.
	// At decl time, generic param `T | null` resolves to Union<GP, Null>
	// (GP isn't Maybe-wrappable). At call site, user-spelled `X | null`
	// for value-type X resolves to Maybe<X>. Both shapes represent the
	// same logical type — peel Maybe to its inner so unifyType can bind T.
	if (formal.kind == TypeKind.Union && concrete.kind == TypeKind.Struct
			&& isMaybeType(concrete) && concrete.typeReturn != null
			&& formal.typeChildren.length == 2) {
		const fa = formal.typeChildren[0];
		const fb = formal.typeChildren[1];
		if (fa != null && fb != null) {
			if (fb.kind == TypeKind.Null) { unifyType(fa, concrete.typeReturn, bindings); return; }
			if (fa.kind == TypeKind.Null) { unifyType(fb, concrete.typeReturn, bindings); return; }
		}
	}
	if (formal.kind == TypeKind.Struct && concrete.kind == TypeKind.Union
			&& isMaybeType(formal) && formal.typeReturn != null
			&& concrete.typeChildren.length == 2) {
		const ca = concrete.typeChildren[0];
		const cb = concrete.typeChildren[1];
		if (ca != null && cb != null) {
			if (cb.kind == TypeKind.Null) { unifyType(formal.typeReturn, ca, bindings); return; }
			if (ca.kind == TypeKind.Null) { unifyType(formal.typeReturn, cb, bindings); return; }
		}
	}
	if (formal.kind == TypeKind.Union && concrete.kind != TypeKind.Union && !isMaybeType(concrete)) {
		unifyIntoUnionFormal(formal, concrete, bindings);
		return;
	}
	if (formal.kind == TypeKind.Conditional && concrete.kind != TypeKind.Conditional && formal.typeChildren.length == 4) {
		unifyType(formal.typeChildren[2], concrete, bindings);
		unifyType(formal.typeChildren[3], concrete, bindings);
		return;
	}
	// Structural match — same kind, recurse into children
	if (formal.kind != concrete.kind) return;
	if (formal.kind == TypeKind.Array || formal.kind == TypeKind.SizedArray || formal.kind == TypeKind.Span || formal.kind == TypeKind.Set) {
		unifyType(formal.typeReturn, concrete.typeReturn, bindings);
		return;
	}
	// Result and Promise are now GenericInstance — handled above
	if (formal.kind == TypeKind.Function) {
		const fnLimit = formal.typeChildren.length < concrete.typeChildren.length ? formal.typeChildren.length : concrete.typeChildren.length;
		for (let i = 0; i < fnLimit; i += 1) {
			unifyType(formal.typeChildren[i], concrete.typeChildren[i], bindings);
		}
		unifyType(formal.typeReturn, concrete.typeReturn, bindings);
		return;
	}
	if (formal.kind == TypeKind.Ref || formal.kind == TypeKind.Ptr) {
		unifyType(formal.typeReturn, concrete.typeReturn, bindings);
		return;
	}
	if (formal.kind == TypeKind.Union || formal.kind == TypeKind.Struct || formal.kind == TypeKind.Tuple) {
		// Structs with field names on both sides unify BY NAME: an object literal's
		// key order is the writer's choice (JSX attr order, etc.) and need not match
		// the formal's declaration order — positional pairing would silently bind
		// generic params against the wrong field's type.
		if (formal.kind == TypeKind.Struct
				&& formal.typeNames.length > 0 && concrete.typeNames.length > 0) {
			const fLimit = formal.typeNames.length < formal.typeChildren.length ? formal.typeNames.length : formal.typeChildren.length;
			const cLimit = concrete.typeNames.length < concrete.typeChildren.length ? concrete.typeNames.length : concrete.typeChildren.length;
			for (let i = 0; i < fLimit; i += 1) {
				for (let j = 0; j < cLimit; j += 1) {
					if (concrete.typeNames[j] == formal.typeNames[i]) {
						unifyType(formal.typeChildren[i], concrete.typeChildren[j], bindings);
						break;
					}
				}
			}
			return;
		}
		const uoLimit = formal.typeChildren.length < concrete.typeChildren.length ? formal.typeChildren.length : concrete.typeChildren.length;
		for (let i = 0; i < uoLimit; i += 1) {
			unifyType(formal.typeChildren[i], concrete.typeChildren[i], bindings);
		}
		return;
	}
}

// One value into a union formal: a member it already is binds nothing, a generic member
// that infers from it takes it, and otherwise the union's one bare type parameter does.
function unifyIntoUnionFormal(formal: Type, concrete: Type, bindings: UnifyBindings): void {
	const base = literalBase(concrete);
	let naked: Type | null = null;
	let nakedCount = 0;
	for (const m of formal.typeChildren) {
		if (m == null) continue;
		if (m.kind == TypeKind.GenericParam) {
			naked = m;
			nakedCount += 1;
		} else if (!hasGenericParams(m) && isMemberItself(m, base)) {
			return;
		}
	}
	for (const m of formal.typeChildren) {
		if (m == null || m.kind == TypeKind.GenericParam || !hasGenericParams(m)) continue;
		const before = bindings.names.length;
		unifyType(m, concrete, bindings);
		if (bindings.names.length > before) return;
	}
	if (nakedCount == 1 && naked != null) unifyType(naked, concrete, bindings);
}

function isMemberItself(member: Type, value: Type): boolean {
	if (member == value) return true;
	if (isPrimitiveKind(member.kind)) return member.kind == value.kind;
	return member.sym != null && member.sym == value.sym;
}

export function hasGenericParams(t: Readonly<Type | null>): boolean {
	if (t == null) return false;
	if (t.kind == TypeKind.GenericParam) return true;
	if (isDeclaredStruct(t)) return t.typeFlags.has(TypeFlag.HasGenericParam);
	if (t.typeReturn == null && t.typeExtra == null && t.typeChildren.length == 0) return false;
	return genericScan(t, new TypeVisitSet());
}

function genericScan(t: Readonly<Type | null>, active: TypeVisitSet): boolean {
	if (t == null) return false;
	if (t.kind == TypeKind.GenericParam) return true;
	if (isDeclaredStruct(t)) return t.typeFlags.has(TypeFlag.HasGenericParam);
	if (t.typeReturn == null && t.typeExtra == null && t.typeChildren.length == 0) return false;
	if (!typeVisitAdd(active, t)) return false;
	if (t.kind == TypeKind.GenericInstance) {
		for (let gi = 0; gi < t.typeChildren.length; gi += 1) {
			if (genericScan(t.typeChildren[gi], active)) return true;
		}
		return false;
	}
	if (genericScan(t.typeReturn, active)) return true;
	if (genericScan(t.typeExtra, active)) return true;
	for (let i = 0; i < t.typeChildren.length; i += 1) {
		if (genericScan(t.typeChildren[i], active)) return true;
	}
	return false;
}

// ===== Type Query Helpers =====

export function isValueStorage(t: Readonly<Type | null>): boolean {
	if (t == null) return false;
	if ((t.kind == TypeKind.Distinct || t.kind == TypeKind.Alias) && t.typeReturn != null) return isValueStorage(t.typeReturn);
	const k = t.kind;
	return k == TypeKind.Struct || k == TypeKind.Array || k == TypeKind.GenericInstance
		|| k == TypeKind.Tuple || k == TypeKind.String || k == TypeKind.Function
		|| k == TypeKind.Union;
}

export function isNumeric(t: Readonly<Type | null>): boolean {
	if (t == null) return false;
	return t.kind == TypeKind.Number || t.kind == TypeKind.Int8 ||
		t.kind == TypeKind.Int16 || t.kind == TypeKind.Int32 ||
		t.kind == TypeKind.Int64 || t.kind == TypeKind.Uint8 ||
		t.kind == TypeKind.Uint16 || t.kind == TypeKind.Uint32 ||
		t.kind == TypeKind.Uint64 || t.kind == TypeKind.Float32 ||
		t.kind == TypeKind.Float64 || t.kind == TypeKind.Char;
}

export function isIntegerType(t: Readonly<Type | null>): boolean {
	if (t == null) return false;
	return t.kind == TypeKind.Int8 || t.kind == TypeKind.Int16 ||
		t.kind == TypeKind.Int32 || t.kind == TypeKind.Int64 ||
		t.kind == TypeKind.Uint8 || t.kind == TypeKind.Uint16 ||
		t.kind == TypeKind.Uint32 || t.kind == TypeKind.Uint64;
}

// Integers a double cannot round-trip: everything up to 32 bits fits exactly in
// the 53-bit mantissa, 64-bit types do not.
export function isWideInteger(t: Type | null): boolean {
	if (t == null) return false;
	return t.kind == TypeKind.Int64 || t.kind == TypeKind.Uint64;
}

// Integer rank for narrowing detection (higher = wider range)
// Parity: standard reference's ordinal range comparison patterns
export function integerRank(t: Type): number {
	return match (t.kind) {
		TypeKind.Int8    => 1,
		TypeKind.Uint8   => 2,
		TypeKind.Int16   => 3,
		TypeKind.Uint16  => 4,
		TypeKind.Int32   => 5,
		TypeKind.Uint32  => 6,
		TypeKind.Int64   => 7,
		TypeKind.Uint64  => 8,
		TypeKind.Float32 => 9,
		TypeKind.Number  => 10,
		TypeKind.Float64 => 10,
		_ => 0,
	};
}

// Returns true when source → target is a narrowing integer conversion
// Parity: standard reference integer conversion matching — narrowing needs HiddenStdConv + range check
export function isNarrowingIntConv(source: Type, target: Type): boolean {
	if (!isIntegerType(target)) return false;
	if (!isIntegerType(source) && source.kind != TypeKind.Number && source.kind != TypeKind.Float64) return false;
	return integerRank(source) > integerRank(target);
}

// Widening across the 64-bit boundary — into it or out of it — also carries a
// HiddenStdConv: the JS BigInt representation needs the boundary marked, and C
// emits it as a no-op cast.
export function isWideningInt64Conv(source: Type, target: Type): boolean {
	if (!isIntegerType(source)) return false;
	if (!isNumeric(target)) return false;
	const crosses64 = source.kind == TypeKind.Int64 || source.kind == TypeKind.Uint64
		|| target.kind == TypeKind.Int64 || target.kind == TypeKind.Uint64;
	if (!crosses64) return false;
	return integerRank(source) < integerRank(target);
}


export function isBoolType(t: Type): boolean {
	return t.kind == TypeKind.Boolean;
}

export function isCallable(t: Type): boolean {
	return t.kind == TypeKind.Function;
}

export function getReturnType(t: Type): Type {
	if (t.kind == TypeKind.Function) {
		const ret = t.typeReturn;
		return ret != null ? ret : inferredType();
	}
	return inferredType();
}

export function getElementType(t: Type): Type {
	if (t.kind == TypeKind.Array || t.kind == TypeKind.SizedArray || t.kind == TypeKind.Span || t.kind == TypeKind.Ptr) {
		const elem = t.typeReturn;
		return elem != null ? elem : inferredType();
	}
	// @builtin("IndexableMap") subscript: `m[k]` returns V. Makes `{ [key: K]: V }`
	// work at runtime via .get() after the lowering in transform/native/nativeLower.ms.
	if (t.kind == TypeKind.GenericInstance && isIndexableMapType(t)
		&& t.typeChildren != null && t.typeChildren.length == 2) {
		return t.typeChildren[1];
	}
	return inferredType();
}

function collectGenericParams(t: Type | null, found: Type[], depth: int32): void {
	if (t == null || depth > 20) return;
	if (t.kind == TypeKind.GenericParam) {
		const declared = withoutReadonlyView(t);
		if (found.indexOf(declared) < 0) found.push(declared);
		return;
	}
	collectGenericParams(t.typeReturn, found, depth + 1);
	collectGenericParams(t.typeExtra, found, depth + 1);
	for (const c of t.typeChildren) collectGenericParams(c, found, depth + 1);
}

let _gpCount: float64 = 0;
export function getPropertyProfile(): float64[] { return [_gpCount]; }
export function getProperty(t: Type | null, name: string): Type {
	if (!_queryProfilingEnabled) return getPropertyInner(t, name);
	_gpCount = _gpCount + 1;
	const r = getPropertyInner(t, name);
	return r;
}
function getPropertyInner(t: Type | null, name: string): Type {
	if (t == null) return inferredType();
	// Unwrap Ref/Ptr to access inner Object's properties (class types are Ref<Object>)
	if (t.kind == TypeKind.Ref || t.kind == TypeKind.Ptr) {
		if (t.typeReturn != null) return getProperty(t.typeReturn, name);
	}
	if (t.kind == TypeKind.Struct) {
		let i = 0;
		for (const propName of t.typeNames) {
			if (propName == name) {
				if (i < t.typeChildren.length) {
					const found = t.typeChildren[i];
					if (found == null) return inferredType();
					return found;
				}
				return inferredType();
			}
			i += 1;
		}
	}
	// GenericInstance: access instantiated body (skipTypes → concrete struct).
	// typeReturn holds the eagerly instantiated body with concrete field types.
	// No lazy substitution needed — field types are already concrete.
	if (t.kind == TypeKind.GenericInstance) {
		// Primary: eagerly instantiated body (typeReturn) — fully concrete
		if (t.typeReturn != null) {
			return getProperty(t.typeReturn, name);
		}
		// Fallback: lazy substitution for GenericInstances without instantiated body
		if (t.typeExtra != null) {
			let baseProp = getProperty(t.typeExtra, name);
			if (isUnresolvedType(baseProp)) return baseProp;
			if (hasGenericParams(baseProp) && t.typeChildren.length > 0) baseProp = substituteInstanceArgs(t, baseProp);
			return baseProp;
		}
	}
	// Union field access: search all variants for the field.
	// For discriminated unions, the discriminant field maps to _tag.
	if (t.kind == TypeKind.Union && t.typeChildren != null) {
		// Check discriminant field first (e.g. "kind" on a discriminated union)
		const tex = t.typeExtra;
		if (tex != null && t.typeNames != null && t.typeNames.length > 0) {
			if (t.typeNames[0] == name) {
				return tex; // discriminant field returns the enum type
			}
		}
		// Search variants for the field — return type if unambiguous across variants
		let foundType: Type | null = null;
		const literals: Type[] = [];
		let allLiterals = true;
		for (const variant of t.typeChildren) {
			if (variant == null) continue;
			const ft = findFieldInVariant(variant, name);
			if (ft == null) continue;
			if (foundType == null) foundType = ft;
			if (ft.kind != TypeKind.StringLiteral) {
				allLiterals = false;
				continue;
			}
			let seen = false;
			for (const l of literals) { if (l.typeName == ft.typeName) seen = true; }
			if (!seen) literals.push(ft);
		}
		if (allLiterals && literals.length > 1) return createUnionInOrder(literals);
		if (foundType != null) return foundType;
	}
	// Enum member access: Color.Red → returns the Enum type
	if (t.kind == TypeKind.Enum) {
		for (const member of t.typeNames) {
			if (member == name) return t;
		}
	}
	return inferredType();
}

// isPrimitiveKind — used by destructorLifting, analyzer/classify, and other DRC code
// A field of a variant union that differs only by literal answers with the first variant's literal,
// where getProperty merges the literals into a new union.
export function fieldTypeView(t: Readonly<Type | null>, name: string): Readonly<Type> {
	if (t == null) return inferredType();
	if ((t.kind == TypeKind.Ref || t.kind == TypeKind.Ptr) && t.typeReturn != null) return fieldTypeView(t.typeReturn, name);
	if (t.kind == TypeKind.GenericInstance) {
		const body = t.typeReturn != null ? t.typeReturn : instanceLayoutBody(t);
		return body != null && body != t ? fieldTypeView(body, name) : inferredType();
	}
	if (t.kind == TypeKind.Struct) {
		const i = t.typeNames.indexOf(name);
		return i >= 0 && i < t.typeChildren.length && t.typeChildren[i] != null ? t.typeChildren[i] : inferredType();
	}
	if (t.kind == TypeKind.Union && t.typeChildren != null) {
		if (t.typeExtra != null && t.typeNames != null && t.typeNames.length > 0 && t.typeNames[0] == name) return t.typeExtra;
		for (const variant of t.typeChildren) {
			const ft = variant != null ? findFieldInVariant(variant, name) : null;
			if (ft != null) return ft;
		}
	}
	if (t.kind == TypeKind.Enum && t.typeNames.indexOf(name) >= 0) return t;
	return inferredType();
}

export function isPrimitiveKind(kind: TypeKind): boolean {
	return kind == TypeKind.Number
		|| kind == TypeKind.Boolean
		|| kind == TypeKind.Void
		|| kind == TypeKind.Null
		|| kind == TypeKind.Int8
		|| kind == TypeKind.Int16
		|| kind == TypeKind.Int32
		|| kind == TypeKind.Int64
		|| kind == TypeKind.Uint8
		|| kind == TypeKind.Uint16
		|| kind == TypeKind.Uint32
		|| kind == TypeKind.Uint64
		|| kind == TypeKind.Float32
		|| kind == TypeKind.Float64
		|| kind == TypeKind.Enum
		|| kind == TypeKind.EnumLiteral
		|| kind == TypeKind.Never
		|| kind == TypeKind.Char
		|| kind == TypeKind.CString
		|| kind == TypeKind.StringLiteral
		|| kind == TypeKind.BooleanLiteral
		|| kind == TypeKind.NumberLiteral
		|| kind == TypeKind.Error
		|| kind == TypeKind.None
		|| kind == TypeKind.Inferred;
}

// typeNameOf — IDENTITY name. Returns the canonical string name used for
// type-keyed lookups: extension receiver matching, transform dispatch,
// `typeof X` extension form, type-string round-trips through the parser.
//
// Returns "" for kinds that have no addressable identity name (Null, Void,
// Never, Unknown, Error, Function, GenericParam). Callers in identity contexts
// rely on this empty-return to short-circuit lookups; do NOT add fallbacks here.
//
// For human-readable display (error messages, signatures, hints) use
// `typeDisplayName` instead — it never returns empty and falls back to the
// kind's spelling.
let _tnoCount: float64 = 0;
export function typeNameOfProfile(): float64[] { return [_tnoCount]; }
export function typeNameOf(t: Readonly<Type | null>): string {
	if (!_queryProfilingEnabled) return typeNameOfInner(t, [], 0);
	_tnoCount = _tnoCount + 1;
	const r = typeNameOfInner(t, [], 0);
	return r;
}

function isDisplaying(open: Readonly<Cursor<Readonly<Type>>[]>, t: Readonly<Type>): boolean {
	for (const u of open) {
		if (u == t) return true;
	}
	return false;
}

function typeNameOfInner(t: Readonly<Type | null>, open: Cursor<Readonly<Type>>[], shapes: int32): string {
	if (t == null) return "";
	// Reference parity: ownership modifiers are transparent — unwrap before naming.
	// Bounded peel loop (not self-recursion): a malformed cyclic wrapper alias
	// whose typeReturn points back at itself would spin forever once tailCallLower
	// rewrites the self-tail-call into while(true). Mirrors the PEEL_MAX_DEPTH peelers.
	let cur: Readonly<Type> = t;
	let prefix = "";
	let _g = 0;
	while (cur != null && _g < PEEL_MAX_DEPTH) {
		_g = _g + 1;
		if (cur.kind == TypeKind.Sink || cur.kind == TypeKind.Lent) {
			if (cur.typeReturn != null) { cur = cur.typeReturn; continue; }
			return prefix;
		}
		if (cur.kind == TypeKind.Var) {
			if (cur.typeReturn != null) { prefix = prefix + "out "; cur = cur.typeReturn; continue; }
			return prefix + "out";
		}
		if (cur.kind == TypeKind.Ref || cur.kind == TypeKind.Ptr) {
			if (cur.typeReturn != null) { cur = cur.typeReturn; continue; }
			return prefix;
		}
		break;
	}
	const t2: Readonly<Type> = cur;
	if (t2.kind == TypeKind.Struct) return prefix + t2.typeName;
	if (t2.kind == TypeKind.GenericInstance) return prefix + t2.typeName;  // "Map" for receiver matching
	return prefix + match (t2.kind) {
		TypeKind.String => "string",
		TypeKind.Number => "number",
		TypeKind.Boolean => "boolean",
		TypeKind.Char => "char",
		TypeKind.Int8 => "int8",
		TypeKind.Int16 => "int16",
		TypeKind.Int32 => "int32",
		TypeKind.Int64 => "int64",
		TypeKind.Uint8 => "uint8",
		TypeKind.Uint16 => "uint16",
		TypeKind.Uint32 => "uint32",
		TypeKind.Uint64 => "uint64",
		TypeKind.Float32 => "float32",
		TypeKind.Float64 => "float64",
		TypeKind.BigInt => "bigint",
		TypeKind.Array => "Array",
		TypeKind.SizedArray => "Array", // Both map to "Array" for extension lookup (UFCS)
		TypeKind.Set => "BitSet",
		TypeKind.Span => "Span",
		TypeKind.Borrow => "Borrow",
		TypeKind.Tuple => "Tuple",
		TypeKind.CString => "cstring",
		TypeKind.StringLiteral => "\"" + t2.typeName + "\"",
		TypeKind.NumberLiteral => t2.typeName,
		TypeKind.IndexedAccess => t2.typeChildren.length < 2 ? "unknown" : typeDisplayNameInner(t2.typeChildren[0], 0 as BitSet<TypeFlag>, open, shapes) + "[" + typeDisplayNameInner(t2.typeChildren[1], 0 as BitSet<TypeFlag>, open, shapes) + "]",
		TypeKind.KeyOf => t2.typeChildren.length < 1 ? "unknown" : "keyof " + typeDisplayNameInner(t2.typeChildren[0], 0 as BitSet<TypeFlag>, open, shapes),
		TypeKind.Mapped => mappedDisplay(t2),
		TypeKind.EnumLiteral => t2.typeName + "." + (t2.typeNames.length > 0 ? t2.typeNames[0] : ""),
		// Result and Promise are now GenericInstance — handled above via t2.typeName
		TypeKind.Enum => t2.typeName,
		TypeKind.TypeReference => t2.typeName,
		TypeKind.Distinct => t2.typeName,
		TypeKind.Union => {
			// Display string literal unions as "north" | "south".
			// Children are rendered for display, so use typeDisplayName so a
			// `null` member shows as "null" instead of an empty segment that
			// would produce "string |  | int32".
			if (t2.typeChildren.length > 0 && !(t2.typeName != "" && isDisplaying(open, t2))) {
				open.push(t2);
				let display = "";
				for (const child of t2.typeChildren) {
					if (display != "") display = display + " | ";
					display = display + typeDisplayNameInner(child, 0 as BitSet<TypeFlag>, open, shapes);
				}
				open.pop();
				return prefix + display;
			}
			return prefix + t2.typeName;
		},
		_ => "",
	};
}

// typeDisplayName — DISPLAY name. Used for diagnostics, error messages,
// signature formatting, LSP hover/hint output. Never returns empty.
//
// Layered fallback:
//   1. typeNameOf — for kinds that have an identity name (string, Map, etc.)
//   2. Spelling for kinds typeNameOf reports as nameless (null, void, etc.)
//   3. <kind:N> escape hatch for unknown future kinds.
//
// For type-keyed lookups (extension receiver matching, transform dispatch),
// use typeNameOf directly — the empty return is intentional there.
let _tdnCount: float64 = 0;
export function typeDisplayNameProfile(): float64[] { return [_tdnCount]; }
export function typeDisplayName(t: Readonly<Type | null>): string {
	if (!_queryProfilingEnabled) return typeDisplayNameInner(t, 0 as BitSet<TypeFlag>, [], 0);
	_tdnCount = _tdnCount + 1;
	const r = typeDisplayNameInner(t, 0 as BitSet<TypeFlag>, [], 0);
	return r;
}
function typeDisplayNameInner(t: Readonly<Type | null>, shown: BitSet<TypeFlag>, open: Cursor<Readonly<Type>>[], shapes: int32): string {
	if (t == null) return "<null>";
	if (t.typeInst != null) return typeDisplayNameInner(t.typeInst, 0 as BitSet<TypeFlag>, open, shapes);
	if (isBrandDistinct(t) && t.sym != null) return t.sym.name;
	if (t.kind == TypeKind.Function && t.callConv == CallingConvention.CcInline) return "@inline function";
	if (t.kind == TypeKind.Varargs && t.typeChildren.length > 0) {
		return "..." + typeDisplayNameInner(t.typeChildren[0], 0 as BitSet<TypeFlag>, open, shapes);
	}
	// Locked<T> is a Ref onto the generated cell struct, so typeNameOf would
	// render the internal cell name. Print the spelling the user wrote.
	if (isLockedRef(t)) return "Locked<" + typeDisplayNameInner(lockedPayloadType(t), 0 as BitSet<TypeFlag>, open, shapes) + ">";
	if (!shown.has(TypeFlag.IsReadonly) && isReadonlyView(t)) return "Readonly<" + typeDisplayNameInner(t, shown.incl(TypeFlag.IsReadonly), open, shapes) + ">";
	if (!shown.has(TypeFlag.IsSendable) && isSendableFunction(t)) return "Sendable<" + typeDisplayNameInner(t, shown.incl(TypeFlag.IsSendable), open, shapes) + ">";
	if (isIterator(t)) return "Iterator<" + typeDisplayNameInner(getIteratorYieldType(t), 0 as BitSet<TypeFlag>, open, shapes) + ">";
	// A generic instance erases to its base name, so two different
	// instantiations render identically ("expected X, got X"). Spell the type
	// arguments the user wrote.
	if (t.kind == TypeKind.Ref && !isAtomicRef(t) && t.typeReturn != null && isValuePointee(t.typeReturn)) {
		return "Ref<" + typeDisplayNameInner(t.typeReturn, 0 as BitSet<TypeFlag>, open, shapes) + ">";
	}
	if (t.kind == TypeKind.Ref && t.typeReturn != null && t.typeReturn.kind == TypeKind.GenericInstance) {
		return typeDisplayNameInner(t.typeReturn, 0 as BitSet<TypeFlag>, open, shapes);
	}
	if (t.kind == TypeKind.GenericInstance && t.typeName != "" && t.typeChildren.length > 0) {
		let argsText = "";
		for (let ai = 0; ai < t.typeChildren.length; ai += 1) {
			if (ai > 0) { argsText = argsText + ", "; }
			argsText = argsText + typeDisplayNameInner(t.typeChildren[ai], 0 as BitSet<TypeFlag>, open, shapes);
		}
		return t.typeName + "<" + argsText + ">";
	}
	if (t.kind == TypeKind.Set) return "BitSet<" + typeDisplayNameInner(t.typeReturn, 0 as BitSet<TypeFlag>, open, shapes) + ">";
	if (t.kind == TypeKind.Cursor && t.typeReturn != null) return "Cursor<" + typeDisplayNameInner(t.typeReturn, 0 as BitSet<TypeFlag>, open, shapes) + ">";
	if (t.kind == TypeKind.Module) return `typeof import("${t.typeName}")`;
	if (t.kind == TypeKind.Borrow && t.typeReturn != null) return "Borrow<" + typeDisplayNameInner(t.typeReturn, 0 as BitSet<TypeFlag>, open, shapes) + ">";
	if (t.kind == TypeKind.Span && t.typeReturn != null) return "Span<" + typeDisplayNameInner(t.typeReturn, 0 as BitSet<TypeFlag>, open, shapes) + ">";
	if (t.kind == TypeKind.Array && t.typeReturn != null) return "Vec<" + typeDisplayNameInner(t.typeReturn, 0 as BitSet<TypeFlag>, open, shapes) + ">";
	if (t.kind == TypeKind.SizedArray && t.typeReturn != null) return typeDisplayNameInner(t.typeReturn, 0 as BitSet<TypeFlag>, open, shapes) + "[" + String(t.typeValue) + "]";
	if (t.kind == TypeKind.Var && t.typeReturn != null) return "out " + typeDisplayNameInner(t.typeReturn, 0 as BitSet<TypeFlag>, open, shapes);
	if (isMaybeType(t) && t.typeReturn != null) return typeDisplayNameInner(t.typeReturn, 0 as BitSet<TypeFlag>, open, shapes) + " | null";
	const shape = namelessObjectShape(t, open, shapes);
	if (shape != "") return shape;
	const name = typeNameOfInner(t, open, shapes);
	// typeNameOf peels Ref and Ptr alike, which renders a pointer and its
	// pointee with the SAME text ("got QB, expected QB"). Ref stays hidden — an
	// interface IS Ref<Struct> here — but Ptr is a distinct spelling the reader
	// writes, so put it back. Bounded like typeNameOf: a self-referential
	// wrapper must not spin.
	if (t.kind == TypeKind.Ptr && name != "") {
		let depth = 0;
		let cur: Readonly<Type | null> = t;
		while (cur != null && cur.kind == TypeKind.Ptr && depth < PEEL_MAX_DEPTH) {
			depth = depth + 1;
			cur = cur.typeReturn;
		}
		let out = name;
		for (let i = 0; i < depth; i += 1) { out = "Ptr<" + out + ">"; }
		return out;
	}
	if (t.kind == TypeKind.Ref && t.typeReturn != null && t.typeReturn.kind == TypeKind.Array) {
		const refElem = t.typeReturn.typeReturn;
		if (refElem != null) return typeDisplayNameInner(refElem, 0 as BitSet<TypeFlag>, open, shapes) + "[]";
	}
	if (t.kind == TypeKind.Tuple && t.typeChildren.length > 0) {
		const parts: string[] = [];
		const required = getMinArity(t);
		for (let i = 0; i < t.typeChildren.length; i += 1) {
			parts.push(typeDisplayNameInner(t.typeChildren[i], 0 as BitSet<TypeFlag>, open, shapes) + (i >= required ? "?" : ""));
		}
		return "[" + parts.join(", ") + "]";
	}
	if (name != "") return name;
	if (t.kind == TypeKind.Ptr && t.typeReturn != null) return "Ptr<" + typeDisplayNameInner(t.typeReturn, 0 as BitSet<TypeFlag>, open, shapes) + ">";
	if (t.kind == TypeKind.Cursor && t.typeReturn != null) return "Cursor<" + typeDisplayNameInner(t.typeReturn, 0 as BitSet<TypeFlag>, open, shapes) + ">";
	return match (t.kind) {
		TypeKind.Null => "null",
		TypeKind.Void => "void",
		TypeKind.Never => "never",
		TypeKind.Unknown => "unknown",
		TypeKind.NonPrimitive => "object",
		TypeKind.Error => "<error>",
		TypeKind.None => "<none>",
		TypeKind.Inferred => "<inferring>",
		TypeKind.Function => "function",
		TypeKind.GenericParam => t.typeName != "" ? t.typeName : "<T>",
		TypeKind.BooleanLiteral => t.typeName,
		_ => "<kind:" + t.kind.toString() + ">",
	};
}

function namelessObjectShape(t: Readonly<Type>, open: Cursor<Readonly<Type>>[], shapes: int32): string {
	const obj = t.kind == TypeKind.Ref && t.typeReturn != null ? t.typeReturn : t;
	if (obj.kind != TypeKind.Struct) return "";
	if (obj.typeName != "" && !obj.typeName.startsWith("__anon")) return "";
	if (obj.typeNames.length == 0) return "{}";
	if (shapes >= 3) return "{ ... }";
	let out = "{ ";
	for (let i = 0; i < obj.typeNames.length; i += 1) {
		const field = i < obj.typeChildren.length ? typeDisplayNameInner(obj.typeChildren[i], 0 as BitSet<TypeFlag>, open, shapes + 1) : "unknown";
		out = out + obj.typeNames[i] + ": " + field + "; ";
	}
	return out + "}";
}

// getBuiltinKind — read the @builtin("...") tag from a type's underlying class Symbol.
// Returns "" if the type has no builtin annotation. Walks transparent wrappers
// (Sink/Lent/Var/Distinct/Ref/Ptr) and GenericInstance → base class, mirroring
// typeNameOf's unwrap policy so `sink m: Map<K,V>` still registers as IndexableMap.
export function getBuiltinKind(t: Type | null): string {
	let cur: Type | null = t;
	let _g = 0;
	while (cur != null && _g < PEEL_MAX_DEPTH) {
		_g = _g + 1;
		if (cur.sym != null && cur.sym.builtinKind != "") return cur.sym.builtinKind;
		if (cur.kind == TypeKind.GenericInstance && cur.typeExtra != null) {
			cur = cur.typeExtra;
			continue;
		}
		// Transparent wrappers — unwrap to inner type before looking up the tag.
		if ((cur.kind == TypeKind.Ref || cur.kind == TypeKind.Ptr
				|| cur.kind == TypeKind.Sink || cur.kind == TypeKind.Lent
				|| cur.kind == TypeKind.Var || cur.kind == TypeKind.Distinct)
				&& cur.typeReturn != null) {
			cur = cur.typeReturn;
			continue;
		}
		break;
	}
	return "";
}

// isIndexableMapType — true when t is a class tagged @builtin("IndexableMap").
// Used by subscript lowering (m[k] → m.get(k) / m.set(k, v)) and m[k] element typing.
// Both Map<K,V> and HashMap<K,V> in std/core/struct.ms carry this tag.
export function isIndexableMapType(t: Type | null): boolean {
	return getBuiltinKind(t) == "IndexableMap";
}

export function isStdCollectionKind(kind: string): boolean {
	return kind == "IndexableMap" || kind == "StdSet";
}

export function isStdCollection(t: Type | null): boolean {
	return isStdCollectionKind(getBuiltinKind(t));
}

export const SIZE_NOT_COMPUTABLE: int32 = -3;

// alignTo — round up offset to alignment boundary
function alignTo(offset: int32, align: int32): int32 {
	if (align <= 1) return offset;
	const rem = offset % align;
	if (rem == 0) return offset;
	return offset + (align - rem);
}

// alignOfType — natural alignment for C ABI (target-aware)
export function alignOfType(tg: TargetInfo, t: Readonly<Type>): int32 {
	return alignOfTypeAt(tg, t, 0);
}

function alignOfTypeAt(tg: TargetInfo, t: Readonly<Type>, depth: int32): int32 {
	if (depth > 16) return 0;
	return alignOfTypeInner(tg, t, depth + 1);
}

function alignOfTypeInner(tg: TargetInfo, t: Readonly<Type>, depth: int32): int32 {
	const ps = tg.ptrSize;
	if (t.kind == TypeKind.Struct || t.kind == TypeKind.Tuple) {
		return alignOfStruct(tg, t, depth);
	}
	if (t.kind == TypeKind.Union) {
		if (unwrapRefNullUnion(t) != null) return ps;
		const carried = literalUnionBase(t);
		if (carried != null) return alignOfTypeAt(tg, carried, depth);
		return alignOfUnion(tg, t, depth);
	}
	if (t.kind == TypeKind.Set) {
		const sr = setRepr(t);
		if (sr != null) return alignOfTypeAt(tg, sr, depth);
	}
	if (t.kind == TypeKind.SizedArray && t.typeReturn != null) {
		return alignOfTypeAt(tg, t.typeReturn, depth);
	}
	if (t.kind == TypeKind.GenericInstance) {
		if (isAwaitable(t)) return ps;
		const body = instanceLayoutBody(t);
		if (body != null && body != t) return alignOfTypeAt(tg, body, depth);
	}
	if ((t.kind == TypeKind.Distinct || t.kind == TypeKind.Alias || t.kind == TypeKind.Sink || t.kind == TypeKind.Lent) && t.typeReturn != null) {
		return alignOfTypeAt(tg, t.typeReturn, depth);
	}
	if (t.kind == TypeKind.Varargs && t.typeChildren.length > 0) {
		return alignOfTypeAt(tg, t.typeChildren[0], depth);
	}
	if (t.kind == TypeKind.Enum || t.kind == TypeKind.EnumLiteral) return alignOfTypeAt(tg, enumStorageOf(t), depth);
	if (t.kind == TypeKind.NumberLiteral) return alignOfTypeAt(tg, numberLiteralBase(t), depth);
	return match (t.kind) {
		TypeKind.Boolean | TypeKind.BooleanLiteral | TypeKind.Char | TypeKind.Int8 | TypeKind.Uint8 => 1,
		TypeKind.Int16 | TypeKind.Uint16 => 2,
		TypeKind.Int32 | TypeKind.Uint32 | TypeKind.Float32 => 4,
		TypeKind.Number | TypeKind.Float64 => floatInt64Align(tg),
		TypeKind.Int64 | TypeKind.Uint64 => floatInt64Align(tg),
		TypeKind.CString | TypeKind.Ref | TypeKind.Ptr | TypeKind.Borrow | TypeKind.Function | TypeKind.Null => ps,
		TypeKind.String | TypeKind.StringLiteral | TypeKind.Array | TypeKind.Span => lenPtrAlign(tg),
		TypeKind.BigInt => ps,
		_ => 0,
	};
}

function alignOfStruct(tg: TargetInfo, t: Readonly<Type>, depth: int32): int32 {
	if (layoutFromC(t)) return 0;
	let maxAlign = 1;
	if (t.typeChildren != null) {
		let i = 0;
		while (i < t.typeChildren.length) {
			if (storesNothing(t, t.typeChildren[i])) { i = i + 1; continue; }
			const a = alignOfTypeAt(tg, t.typeChildren[i], depth);
			if (a > maxAlign) maxAlign = a;
			i = i + 1;
		}
	}
	return maxAlign;
}

// sizeOfType — compile-time sizeof for primitive and compound types (target-aware C ABI)
// Mirrors standard reference implementation for size/alignment: fields are aligned, struct is padded to maxAlign.
export function sizeOfType(tg: TargetInfo, t: Readonly<Type>): int32 {
	if (tg.ptrSize < 4) return SIZE_NOT_COMPUTABLE;
	return sizeOfTypeAt(tg, t, 0);
}

function sizeOfTypeAt(tg: TargetInfo, t: Readonly<Type>, depth: int32): int32 {
	if (depth > 16) return SIZE_NOT_COMPUTABLE;
	return sizeOfTypeInner(tg, t, depth + 1);
}

function sizeOfTypeInner(tg: TargetInfo, t: Readonly<Type>, depth: int32): int32 {
	const ps = tg.ptrSize;
	if (t.kind == TypeKind.Struct || t.kind == TypeKind.Tuple) {
		return sizeOfStruct(tg, t, depth);
	}
	if (t.kind == TypeKind.Union) {
		if (unwrapRefNullUnion(t) != null) return ps;
		const carried = literalUnionBase(t);
		if (carried != null) return sizeOfTypeAt(tg, carried, depth);
		return sizeOfUnion(tg, t, depth);
	}
	if (t.kind == TypeKind.Set) {
		const sr = setRepr(t);
		if (sr != null) return sizeOfTypeAt(tg, sr, depth);
	}
	if (t.kind == TypeKind.SizedArray && t.typeReturn != null) {
		const storageCount = t.typeValue == 0 ? 1 : t.typeValue;
		return sizeOfTypeAt(tg, t.typeReturn, depth) * storageCount;
	}
	if (t.kind == TypeKind.GenericInstance) {
		if (isAwaitable(t)) return ps;
		const body = instanceLayoutBody(t);
		if (body != null && body != t) return sizeOfTypeAt(tg, body, depth);
	}
	if ((t.kind == TypeKind.Distinct || t.kind == TypeKind.Alias || t.kind == TypeKind.Sink || t.kind == TypeKind.Lent) && t.typeReturn != null) {
		return sizeOfTypeAt(tg, t.typeReturn, depth);
	}
	if (t.kind == TypeKind.Varargs && t.typeChildren.length > 0) {
		return sizeOfTypeAt(tg, t.typeChildren[0], depth);
	}
	if (t.kind == TypeKind.Enum || t.kind == TypeKind.EnumLiteral) return sizeOfTypeAt(tg, enumStorageOf(t), depth);
	if (t.kind == TypeKind.NumberLiteral) return sizeOfTypeAt(tg, numberLiteralBase(t), depth);
	return match (t.kind) {
		TypeKind.Boolean | TypeKind.BooleanLiteral | TypeKind.Char | TypeKind.Int8 | TypeKind.Uint8 => 1,
		TypeKind.Int16 | TypeKind.Uint16 => 2,
		TypeKind.Int32 | TypeKind.Uint32 | TypeKind.Float32 => 4,
		TypeKind.Number | TypeKind.Int64 | TypeKind.Uint64 | TypeKind.Float64 => 8,
		TypeKind.String | TypeKind.StringLiteral | TypeKind.Array | TypeKind.Span => alignTo(8 + ps, lenPtrAlign(tg)),
		TypeKind.CString | TypeKind.Ref | TypeKind.Ptr | TypeKind.Borrow | TypeKind.Null => ps,
		TypeKind.Function => ps * 2,
		TypeKind.BigInt => ps,
		_ => SIZE_NOT_COMPUTABLE,
	};
}

function sizeOfStruct(tg: TargetInfo, t: Readonly<Type>, depth: int32): int32 {
	return structLayoutAt(tg, t, depth, -1);
}

export function layoutFromC(t: Readonly<Type>): boolean {
	return t.sym != null && t.sym.symFlags.has(SymbolFlag.ImportC) && !t.typeFlags.has(TypeFlag.CompleteStruct);
}

// Size and field offsets share one traversal, including padding and erased fields.
function structLayoutAt(tg: TargetInfo, t: Readonly<Type>, depth: int32, fieldIndex: int32): int32 {
	if (layoutFromC(t)) return SIZE_NOT_COMPUTABLE;
	if (t.typeFlags.has(TypeFlag.CUnion)) return unionLayoutAt(tg, t, depth, fieldIndex);
	let offset = 0;
	let maxAlign = 1;
	if (t.typeChildren != null) {
		let i = 0;
		while (i < t.typeChildren.length) {
			const field = t.typeChildren[i];
			if (field != null && !storesNothing(t, field)) {
				const fieldSize = sizeOfTypeAt(tg, field, depth);
				if (fieldSize < 0) return fieldSize;
				const fieldAlign = alignOfTypeAt(tg, field, depth);
				if (fieldAlign > maxAlign) maxAlign = fieldAlign;
				offset = alignTo(offset, fieldAlign);
				if (i == fieldIndex) return offset;
				offset = offset + fieldSize;
			}
			if (i == fieldIndex) return offset;
			i = i + 1;
		}
	}
	if (offset == 0) return 0;
	return alignTo(offset, maxAlign);
}

// Every member at offset 0; the size is the largest member rounded up to the strictest alignment.
function unionLayoutAt(tg: TargetInfo, t: Readonly<Type>, depth: int32, fieldIndex: int32): int32 {
	let size = 0;
	let maxAlign = 1;
	for (let i = 0; i < t.typeChildren.length; i += 1) {
		const field = t.typeChildren[i];
		const fieldSize = sizeOfTypeAt(tg, field, depth);
		if (fieldSize < 0) return fieldSize;
		if (i == fieldIndex) return 0;
		const fieldAlign = alignOfTypeAt(tg, field, depth);
		if (fieldAlign > maxAlign) maxAlign = fieldAlign;
		if (fieldSize > size) size = fieldSize;
	}
	return alignTo(size, maxAlign);
}

export function structLayoutType(t: Type): Type | null;
export function structLayoutType(t: Readonly<Type>): Readonly<Type | null>;
export function structLayoutType(t: Readonly<Type>): Readonly<Type | null> {
	let cur = t;
	for (let depth = 0; depth <= 16; depth += 1) {
		if (cur.kind == TypeKind.Struct) return cur;
		if (cur.kind == TypeKind.GenericInstance) {
			const body = instanceLayoutBody(cur);
			if (body == null || body == cur) return null;
			cur = body;
		} else if ((cur.kind == TypeKind.Alias || cur.kind == TypeKind.Distinct || cur.kind == TypeKind.Sink || cur.kind == TypeKind.Lent) && cur.typeReturn != null) {
			cur = cur.typeReturn;
		} else {
			return null;
		}
	}
	return null;
}

export function offsetOfField(tg: TargetInfo, t: Readonly<Type>, field: string): int32 {
	if (tg.ptrSize < 4) return SIZE_NOT_COMPUTABLE;
	const body = structLayoutType(t);
	if (body == null) return SIZE_NOT_COMPUTABLE;
	for (let i = 0; i < body.typeNames.length; i += 1) {
		if (body.typeNames[i] == field && i < body.typeChildren.length) return structLayoutAt(tg, body, 1, i);
	}
	return SIZE_NOT_COMPUTABLE;
}

function instanceLayoutBody(t: Type): Type | null;
function instanceLayoutBody(t: Readonly<Type>): Readonly<Type | null>;
function instanceLayoutBody(t: Readonly<Type>): Readonly<Type | null> {
	if (t.typeReturn != null) return t.typeReturn;
	const base = peelToStructOrUnion(t.typeExtra);
	if (base == null || (base.kind != TypeKind.Struct && base.kind != TypeKind.Union)) return null;
	return missingBody(t) ? null : base;
}

function unionTagType(t: Type): Type | null;
function unionTagType(t: Readonly<Type>): Readonly<Type | null>;
function unionTagType(t: Readonly<Type>): Readonly<Type | null> {
	return t.typeExtra != null && t.typeExtra.kind == TypeKind.Enum ? t.typeExtra : null;
}

function sizeOfUnion(tg: TargetInfo, t: Readonly<Type>, depth: int32): int32 {
	const tag = unionTagType(t);
	const tagSize = tag != null ? sizeOfTypeAt(tg, tag, depth) : 4;
	if (tagSize < 0) return tagSize;
	const tagAlign = tag != null ? alignOfTypeAt(tg, tag, depth) : 4;
	let payload = 0;
	let payloadAlign = 1;
	if (t.typeChildren != null) {
		for (const variant of t.typeChildren) {
			const vs = sizeOfTypeAt(tg, variant, depth);
			if (vs < 0) return vs;
			if (vs > payload) payload = vs;
			const va = alignOfTypeAt(tg, variant, depth);
			if (va > payloadAlign) payloadAlign = va;
		}
	}
	const maxAlign = tagAlign > payloadAlign ? tagAlign : payloadAlign;
	return alignTo(alignTo(tagSize, payloadAlign) + payload, maxAlign);
}

function alignOfUnion(tg: TargetInfo, t: Readonly<Type>, depth: int32): int32 {
	const tag = unionTagType(t);
	let maxAlign = tag != null ? alignOfTypeAt(tg, tag, depth) : 4;
	if (t.typeChildren != null) {
		for (const variant of t.typeChildren) {
			const va = alignOfTypeAt(tg, variant, depth);
			if (va > maxAlign) maxAlign = va;
		}
	}
	return maxAlign;
}

// ===== Tests =====
test "primitive kinds" {
	assert numberType().kind == TypeKind.Number;
	assert stringType().kind == TypeKind.String;
	assert booleanType().kind == TypeKind.Boolean;
	assert voidType().kind == TypeKind.Void;
	assert nullType().kind == TypeKind.Null;
	assert neverType().kind == TypeKind.Never;
	assert errorType().kind == TypeKind.Error;
}

test "createArray" {
	const arrType = createArray(numberType());
	assert arrType.kind == TypeKind.Array;
	assert arrType.typeReturn != null && arrType.typeReturn.kind == TypeKind.Number;
}

test "createSizedArray" {
	const arrType = createSizedArray(numberType(), 4);
	assert arrType.kind == TypeKind.SizedArray;
	assert arrType.typeReturn != null && arrType.typeReturn.kind == TypeKind.Number;
	assert arrType.typeValue == 4;
}

test "createSpan" {
	const spanType = createSpan(numberType());
	assert spanType.kind == TypeKind.Span;
	assert spanType.typeReturn != null && spanType.typeReturn.kind == TypeKind.Number;
}

test "createFunction" {
	const fnType = createFunction([numberType(), stringType()], ["a", "b"], booleanType());
	assert fnType.kind == TypeKind.Function;
	assert fnType.typeChildren.length == 2;
	assert fnType.typeNames[0] == "a";
	assert fnType.typeReturn != null && fnType.typeReturn.kind == TypeKind.Boolean;
}

test "createStruct" {
	const obj = createStruct("Point", ["x"], [numberType()], false);
	assert obj.kind == TypeKind.Struct;
	assert obj.typeName == "Point";
	assert obj.typeNames.length == 1;
	assert obj.typeChildren.length == 1;
	assert obj.typeFlags.isEmpty();
}

test "a struct or tuple holding a Promise needs lifecycle hooks" {
	assert hasAsgnFlag(createStruct("Entry", ["key"], [createPromise(int32Type())], false));
	assert hasAsgnFlag(createStruct("Entry", ["key"], [createSpawnHandle(int32Type())], false));
	assert hasAsgnFlag(createTuple([int32Type(), createPromise(int32Type())]));
}

test "createEnum" {
	const e = createEnum("Color", ["Red", "Green", "Blue"]);
	assert e.kind == TypeKind.Enum;
	assert e.typeName == "Color";
	assert e.typeNames.length == 3;
}

test "createResult" {
	const r = createResult(numberType(), stringType());
	assert isResult(r);
	const ok = getResultOkType(r);
	assert ok != null && ok.kind == TypeKind.Number;
	const err = getResultErrType(r);
	assert err != null && err.kind == TypeKind.String;
}

test "createTypeRef" {
	const t = createTypeRef("MyType");
	assert t.kind == TypeKind.TypeReference;
	assert t.typeName == "MyType";
}

test "createRef and Ptr" {
	const r = createRef(numberType());
	assert r.kind == TypeKind.Ref;
	assert r.typeReturn != null && r.typeReturn.kind == TypeKind.Number;
	const p = createPtr(stringType());
	assert p.kind == TypeKind.Ptr;
	assert p.typeReturn != null && p.typeReturn.kind == TypeKind.String;
}

test "isNumeric" {
	assert isNumeric(numberType());
	assert isNumeric(createPrimitive(TypeKind.Int32));
	assert isNumeric(createPrimitive(TypeKind.Float64));
	assert !isNumeric(stringType());
	assert !isNumeric(booleanType());
}

test "isStringLike" {
	assert isStringLike(stringType());
	assert isStringLike(createStringLiteral("north"));
	assert !isStringLike(numberType());
}

test "isBoolType" {
	assert isBoolType(booleanType());
	assert !isBoolType(numberType());
}

test "isCallable" {
	const fn = createFunction([], [], voidType());
	assert isCallable(fn);
	assert !isCallable(numberType());
}

test "getReturnType" {
	const fn = createFunction([], [], booleanType());
	assert getReturnType(fn).kind == TypeKind.Boolean;
	assert getReturnType(numberType()).kind == TypeKind.Inferred;
}

test "getElementType" {
	const arr = createArray(stringType());
	assert getElementType(arr).kind == TypeKind.String;
	assert getElementType(numberType()).kind == TypeKind.Inferred;
}

test "getProperty" {
	const obj = createStruct("Point", ["x", "y"], [numberType(), stringType()], false);
	assert getProperty(obj, "x").kind == TypeKind.Number;
	assert getProperty(obj, "y").kind == TypeKind.String;
	assert getProperty(obj, "z").kind == TypeKind.Inferred;
	assert getProperty(numberType(), "x").kind == TypeKind.Inferred;
}

function declaredStruct(name: string, names: string[], types: Type[], isValue: boolean): Type {
	const t = createStruct(name, names, types, isValue);
	t.sym = makeSymbol(name, SymbolKind.Struct, t, false);
	return t;
}

test "a ref-carrying union is viewable" {
	const leaf = createRef(declaredStruct("Leaf", ["v"], [int32Type()], false));
	const pair = declaredStruct("PairData", ["leaf", "other"], [leaf, leaf], true);
	const name = declaredStruct("NameData", ["label"], [stringType()], true);
	const structUnion = createUnion([pair, name]);
	assert !isReadonlyView(structUnion);
	assert isReadonlyView(createReadonlyView(structUnion));
	assert withoutReadonlyView(createReadonlyView(structUnion)) == structUnion;
}

test "a union of ref variants is viewable" {
	const namedA = createRef(declaredStruct("NamedA", ["leaf"], [createRef(declaredStruct("Leaf", ["v"], [int32Type()], false))], false));
	const namedB = createRef(declaredStruct("NamedB", ["label"], [stringType()], false));
	const classUnion = createUnion([namedA, namedB]);
	assert isReadonlyView(createReadonlyView(classUnion));
}

test "a pod union is not viewable" {
	const podUnion = createUnion([int32Type(), stringType()]);
	assert !isReadonlyView(createReadonlyView(podUnion));
}

test "a nullable pod union is not viewable" {
	const literals = createUnion([createStringLiteral("alt"), createStringLiteral("~alt")]);
	assert !isReadonlyView(createReadonlyView(createMaybeType(literals)));
	const nested = createUnion([createUnion([int32Type(), stringType()]), createArray(int32Type())]);
	assert isReadonlyView(createReadonlyView(nested));
}

test "substitute generic param" {
	const gp = createGenericParam("T");
	const result = substituteParams(gp, [gp], [numberType()]);
	assert result.kind == TypeKind.Number;
}

test "a parameter spelled like the bound one but declared elsewhere stays" {
	const gp = createGenericParam("T");
	const other = createGenericParam("T");
	const result = substituteParams(gp, [other], [numberType()]);
	assert result == gp;
}

test "substitute in array" {
	const gp = createGenericParam("T");
	const result = substituteParams(createArray(gp), [gp], [stringType()]);
	assert result.kind == TypeKind.Array;
	assert result.typeReturn != null && result.typeReturn.kind == TypeKind.String;
}

test "substitute in function" {
	const gp = createGenericParam("T");
	const fn = createFunction([gp], ["a"], gp);
	const result = substituteParams(fn, [gp], [numberType()]);
	assert result.kind == TypeKind.Function;
	assert result.typeChildren[0].kind == TypeKind.Number;
	assert result.typeReturn != null && result.typeReturn.kind == TypeKind.Number;
}

test "substitute in Result" {
	const t = createGenericParam("T");
	const e = createGenericParam("E");
	const r = createResult(t, e);
	const sub = substituteParams(r, [t, e], [numberType(), stringType()]);
	assert isResult(sub);
	const ok2 = getResultOkType(sub);
	assert ok2 != null && ok2.kind == TypeKind.Number;
	const err2 = getResultErrType(sub);
	assert err2 != null && err2.kind == TypeKind.String;
}

test "a user parameter named like Result's own is not Result's" {
	const userT = createGenericParam("T");
	const r = createResult(createArray(userT), stringType());
	const sub = substituteParams(r, [userT], [int32Type()]);
	instantiateGenericBody(sub, "T,E");
	const ok = getResultOkType(sub);
	assert ok != null && ok.kind == TypeKind.Array && ok.typeReturn.kind == TypeKind.Int32;
	const okVariant = peelToStructOrUnion(sub).typeChildren[0];
	const valueField = findFieldInVariant(okVariant, "value");
	assert valueField != null && valueField.kind == TypeKind.Array && valueField.typeReturn.kind == TypeKind.Int32;
}

test "a union substituted into a union is the flat union the resolver builds" {
	const literals = createUnion([createStringLiteral("a"), createStringLiteral("b")]);
	const gp = createGenericParam("T");
	const generic = createUnion([gp, booleanType()]);
	const direct = createUnion([literals, booleanType()]);
	const all = substituteParams(generic, [gp], [literals]);
	assert all.typeChildren.length == 3 && typeKey(all) == typeKey(direct);
}

// Substitution keeps typeExtra un-substituted (walking it cost ~20× compile
// time on self-host), so callers that need the substituted body
// must invoke instantiateGenericBody themselves. Built-in Result/Promise/Iterator
// have no declaration — they get their param names from `builtinGenericParams`.
test "a substituted Result carries its substituted body" {
	const gp = createGenericParam("T");
	const r = createResult(gp, stringType());
	assert r.typeReturn != null;
	assert r.typeExtra != null;
	const sub = substituteParams(r, [gp], [numberType()]);
	assert sub.typeChildren[0].kind == TypeKind.Number;
	assert sub.typeReturn != null;
	const body = peelToStructOrUnion(sub);
	assert body != null && body.kind == TypeKind.Union;
	const okVariant = body.typeChildren[0];
	const valueField = findFieldInVariant(okVariant, "value");
	assert valueField != null && valueField.kind == TypeKind.Number;
}

test "primitive unchanged" {
	const gp = createGenericParam("T");
	const result = substituteParams(numberType(), [gp], [stringType()]);
	assert result.kind == TypeKind.Number;
}

test "unify direct generic param" {
	const b = createUnifyBindings();
	unifyType(createGenericParam("T"), numberType(), b);
	assert b.names.length == 1;
	assert b.names[0] == "T";
	assert b.types[0].kind == TypeKind.Number;
}

test "unify Array<T> vs Array<string>" {
	const b = createUnifyBindings();
	unifyType(createArray(createGenericParam("T")), createArray(stringType()), b);
	assert b.names.length == 1;
	assert b.names[0] == "T";
	assert b.types[0].kind == TypeKind.String;
}

test "unify Span infers elements from owned shared fixed arrays and strings" {
	const sources: Type[] = [
		createArray(int32Type()),
		createRef(createArray(int32Type())),
		createSizedArray(int32Type(), 2),
		createSpan(int32Type()),
	];
	for (const source of sources) {
		const bindings = createUnifyBindings();
		unifyType(createSpan(createGenericParam("T")), source, bindings);
		assert bindings.names.length == 1;
		assert bindings.types[0].kind == TypeKind.Int32;
	}
	const chars = createUnifyBindings();
	unifyType(createSpan(createGenericParam("T")), stringType(), chars);
	assert chars.names.length == 1;
	assert chars.types[0].kind == TypeKind.Char;
	const rejected = createUnifyBindings();
	unifyType(createSpan(createGenericParam("T")), int32Type(), rejected);
	assert rejected.names.length == 0;
}

test "unify Result<T, E> vs Result<number, string>" {
	const b = createUnifyBindings();
	const formal = createResult(createGenericParam("T"), createGenericParam("E"));
	const concrete = createResult(numberType(), stringType());
	unifyType(formal, concrete, b);
	assert b.names.length == 2;
	assert b.names[0] == "T";
	assert b.types[0].kind == TypeKind.Number;
	assert b.names[1] == "E";
	assert b.types[1].kind == TypeKind.String;
}

test "unify mismatched kinds" {
	const b = createUnifyBindings();
	unifyType(createArray(createGenericParam("T")), numberType(), b);
	assert b.names.length == 0;
}

test "a value into a union formal binds its bare type parameter unless it is a member already" {
	const nullable = createUnion([createGenericParam("T"), nullType()]);
	const bare = createUnifyBindings();
	unifyType(nullable, int32Type(), bare);
	assert bare.names.length == 1;
	assert bare.types[0].kind == TypeKind.Int32;
	const member = createUnifyBindings();
	unifyType(nullable, nullType(), member);
	assert member.names.length == 0;
	const elements = createUnifyBindings();
	unifyType(createUnion([createGenericParam("T"), createArray(createGenericParam("T"))]), createArray(int32Type()), elements);
	assert elements.names.length == 1;
	assert elements.types[0].kind == TypeKind.Int32;
}

test "unify concrete no bindings" {
	const b = createUnifyBindings();
	unifyType(numberType(), numberType(), b);
	assert b.names.length == 0;
}

test "hasGenericParams true" {
	assert hasGenericParams(createGenericParam("T"));
	assert hasGenericParams(createArray(createGenericParam("T")));
	assert hasGenericParams(createFunction([createGenericParam("T")], ["a"], numberType()));
}

test "hasGenericParams false" {
	assert !hasGenericParams(numberType());
	assert !hasGenericParams(createArray(stringType()));
	assert !hasGenericParams(createFunction([numberType()], ["a"], stringType()));
}

test "default returns param count" {
	const fn1 = createFunction([numberType(), stringType()], ["a", "b"], voidType());
	assert getMinArity(fn1) == 2;
}

test "setMinArity stores correctly" {
	const fn2 = createFunction([numberType(), stringType()], ["a", "b"], voidType());
	setMinArity(fn2, 1);
	assert getMinArity(fn2) == 1;
}

test "setMinArity zero" {
	const fn3 = createFunction([numberType()], ["a"], voidType());
	setMinArity(fn3, 0);
	assert getMinArity(fn3) == 0;
}

test "preserves low bits" {
	const fn4 = createFunction([numberType()], ["a"], voidType());
	fn4.typeFlags = (0 as BitSet<TypeFlag>).incl(TypeFlag.IsStruct);
	setMinArity(fn4, 1);
	assert getMinArity(fn4) == 1;
	assert fn4.typeFlags.has(TypeFlag.IsStruct);
}

test "createTuple" {
	const tup = createTuple([numberType(), stringType()]);
	assert tup.kind == TypeKind.Tuple;
	assert tup.typeChildren.length == 2;
	assert tup.typeChildren[0].kind == TypeKind.Number;
	assert tup.typeChildren[1].kind == TypeKind.String;
}

test "typeNameOf Tuple" {
	const tup = createTuple([numberType()]);
	assert typeNameOf(tup) == "Tuple";
}

test "substituteParams Tuple" {
	const gp = createGenericParam("T");
	const tup = createTuple([gp, numberType()]);
	const result = substituteParams(tup, [gp], [stringType()]);
	assert result.kind == TypeKind.Tuple;
	assert result.typeChildren[0].kind == TypeKind.String;
	assert result.typeChildren[1].kind == TypeKind.Number;
}

test "sizeOfType primitives 64-bit" {
	const tg: TargetInfo = { ptrSize: 8, floatSize: 8 };
	assert sizeOfType(tg, createPrimitive(TypeKind.Boolean)) == 1;
	assert sizeOfType(tg, createPrimitive(TypeKind.Char)) == 1;
	assert sizeOfType(tg, createPrimitive(TypeKind.Int32)) == 4;
	assert sizeOfType(tg, createPrimitive(TypeKind.Uint32)) == 4;
	assert sizeOfType(tg, createPrimitive(TypeKind.Float32)) == 4;
	assert sizeOfType(tg, numberType()) == 8;
	assert sizeOfType(tg, createPrimitive(TypeKind.Int64)) == 8;
	assert sizeOfType(tg, createPrimitive(TypeKind.Float64)) == 8;
	assert sizeOfType(tg, stringType()) == 16;
	assert sizeOfType(tg, createArray(numberType())) == 16;
	assert sizeOfType(tg, createPrimitive(TypeKind.Enum)) == 4;
}

test "an enum is stored in the narrowest width that holds its ordinals" {
	const tg: TargetInfo = { ptrSize: 8, floatSize: 8 };
	assert sizeOfType(tg, createEnum("Two", ["A", "B"])) == 1;
	assert sizeOfType(tg, createEnum("Byte", ["A", "B"], [0, 255])) == 1;
	assert sizeOfType(tg, createEnum("Word", ["A", "B"], [0, 300])) == 2;
	assert alignOfType(tg, createEnum("Word", ["A", "B"], [0, 300])) == 2;
	assert sizeOfType(tg, createEnum("Big", ["A", "B"], [0, 70000])) == 4;
	assert sizeOfType(tg, createEnum("Signed", ["A", "B"], [-1, 0])) == 4;
	assert sizeOfType(tg, createEnum("Unordered", ["Hi", "Lo"], [300, 1])) == 2;
}

test "an enum literal is sized by its enum" {
	const tg: TargetInfo = { ptrSize: 8, floatSize: 8 };
	assert sizeOfType(tg, createEnumLiteral(createEnum("Two", ["A", "B"]), "A")) == 1;
}

test "sizeOfType primitives 32-bit" {
	const tg: TargetInfo = { ptrSize: 4, floatSize: 8 };
	assert sizeOfType(tg, numberType()) == 8;
	assert sizeOfType(tg, stringType()) == 16;
	assert sizeOfType(tg, createArray(numberType())) == 16;
	assert alignOfType(tg, stringType()) == 8;
	assert sizeOfType(tg, createFunction([], [], numberType())) == 8;
	assert sizeOfType(tg, createPrimitive(TypeKind.Ref)) == 4;
	assert sizeOfType(tg, createPrimitive(TypeKind.Int32)) == 4;
	assert sizeOfType(tg, createPrimitive(TypeKind.Int64)) == 8;
}

test "sizeOfType object no padding" {
	const tg: TargetInfo = { ptrSize: 8, floatSize: 8 };
	const obj = createStruct("Pair", ["x", "y"], [createPrimitive(TypeKind.Int32), createPrimitive(TypeKind.Int32)], true);
	assert sizeOfType(tg, obj) == 8;
}

test "sizeOfType object with padding" {
	const tg: TargetInfo = { ptrSize: 8, floatSize: 8 };
	// { char (1 byte) + padding(3) + int32 (4 bytes) } = 8
	const obj = createStruct("Mixed", ["a", "b"], [createPrimitive(TypeKind.Char), createPrimitive(TypeKind.Int32)], true);
	assert sizeOfType(tg, obj) == 8;
}

test "sizeOfType object tail padding" {
	const tg: TargetInfo = { ptrSize: 8, floatSize: 8 };
	// { int64 (8 bytes) + char (1 byte) + padding(7) } = 16 (aligned to maxAlign=8)
	const obj = createStruct("Tail", ["x", "y"], [createPrimitive(TypeKind.Int64), createPrimitive(TypeKind.Char)], true);
	assert sizeOfType(tg, obj) == 16;
}

test "sizeOfType function closure" {
	const tg: TargetInfo = { ptrSize: 8, floatSize: 8 };
	assert sizeOfType(tg, createFunction([], [], numberType())) == 16;
}

test "sizeOfType bigint is a pointer" {
	const tg: TargetInfo = { ptrSize: 8, floatSize: 8 };
	assert sizeOfType(tg, createPrimitive(TypeKind.BigInt)) == 8;
}

test "sizeOfType literal discriminants carry their base width" {
	const tg: TargetInfo = { ptrSize: 8, floatSize: 8 };
	assert sizeOfType(tg, createBooleanLiteral(true)) == 1;
	assert sizeOfType(tg, createStringLiteral("circle")) == 16;
	assert alignOfType(tg, createBooleanLiteral(false)) == 1;
	assert alignOfType(tg, createStringLiteral("rect")) == 8;
}

test "sizeOfType union is tag plus widest variant" {
	const tg: TargetInfo = { ptrSize: 8, floatSize: 8 };
	const v0 = createStruct("", ["ok", "value"], [createPrimitive(TypeKind.Boolean), createPrimitive(TypeKind.Int32)], true);
	const v1 = createStruct("", ["ok", "error"], [createPrimitive(TypeKind.Boolean), stringType()], true);
	const u = createUnion([v0, v1]);
	assert sizeOfType(tg, v0) == 8;
	assert sizeOfType(tg, v1) == 24;
	assert alignOfType(tg, u) == 8;
	assert sizeOfType(tg, u) == 32;
}

test "sizeOfType follows a generic instance to its substituted body" {
	const tg: TargetInfo = { ptrSize: 8, floatSize: 8 };
	const v0 = createStruct("", ["ok", "value"], [createBooleanLiteral(true), createPrimitive(TypeKind.Int32)], true);
	const v1 = createStruct("", ["ok", "error"], [createBooleanLiteral(false), stringType()], true);
	const named = createUnion([v0, v1]);
	const inst = createGenericInstance(named, [createPrimitive(TypeKind.Int32), stringType()]);
	inst.typeReturn = named;
	assert sizeOfType(tg, inst) == 24;
}

test "sizeOfType gives an awaitable the width of its future handle" {
	const tg: TargetInfo = { ptrSize: 8, floatSize: 8 };
	assert sizeOfType(tg, createPromise(createPrimitive(TypeKind.Int32))) == 8;
	assert alignOfType(tg, createPromise(stringType())) == 8;
}

test "sizeOfType reports a sizeless type instead of zero" {
	const tg: TargetInfo = { ptrSize: 8, floatSize: 8 };
	assert sizeOfType(tg, voidType()) < 0;
	assert sizeOfType(tg, unknownType()) < 0;
	assert sizeOfType(tg, createGenericParam("T")) < 0;
	const holder = createStruct("Holder", ["v"], [unknownType()], true);
	assert sizeOfType(tg, holder) < 0;
}

test "alignOfType" {
	const tg: TargetInfo = { ptrSize: 8, floatSize: 8 };
	assert alignOfType(tg, createPrimitive(TypeKind.Char)) == 1;
	assert alignOfType(tg, createPrimitive(TypeKind.Int32)) == 4;
	assert alignOfType(tg, numberType()) == 8;
}

test "alignOfType 32-bit keeps int64 and float64 at their natural alignment" {
	const tg: TargetInfo = { ptrSize: 4, floatSize: 8, cpu: "wasm32", os: "wasm" };
	assert alignOfType(tg, numberType()) == 8;
	assert alignOfType(tg, createPrimitive(TypeKind.Int64)) == 8;
	assert alignOfType(tg, createPrimitive(TypeKind.Ref)) == 4;
	assert alignOfType(tg, createPrimitive(TypeKind.Int32)) == 4;
}

test "alignOfType i386 packs int64 and float64 at 4 outside windows" {
	const linux: TargetInfo = { ptrSize: 4, floatSize: 8, cpu: "i386", os: "linux" };
	const windows: TargetInfo = { ptrSize: 4, floatSize: 8, cpu: "i386", os: "windows" };
	assert alignOfType(linux, numberType()) == 4;
	assert alignOfType(linux, createPrimitive(TypeKind.Int64)) == 4;
	assert alignOfType(windows, numberType()) == 8;
	assert alignOfType(windows, createPrimitive(TypeKind.Int64)) == 8;
}

test "sizeOfType declines to lay out a 16-bit target" {
	const avr: TargetInfo = { ptrSize: 2, floatSize: 4, cpu: "avr", os: "bare" };
	assert sizeOfType(avr, createPrimitive(TypeKind.Int32)) < 0;
	assert sizeOfType(avr, createStruct("Head", ["c", "x"], [createPrimitive(TypeKind.Char), createPrimitive(TypeKind.Int64)], true)) < 0;
}

test "sizeOfType char before int64 follows the target alignment rule" {
	const wasm: TargetInfo = { ptrSize: 4, floatSize: 8, cpu: "wasm32", os: "wasm" };
	const i386: TargetInfo = { ptrSize: 4, floatSize: 8, cpu: "i386", os: "linux" };
	const obj = createStruct("Head", ["c", "x"], [createPrimitive(TypeKind.Char), createPrimitive(TypeKind.Int64)], true);
	assert sizeOfType(wasm, obj) == 16;
	assert sizeOfType(i386, obj) == 12;
}

test "a string, an array and a span are sized as their runtime length-and-pointer pair" {
	const wasm: TargetInfo = { ptrSize: 4, floatSize: 8, cpu: "wasm32", os: "wasm" };
	const i386: TargetInfo = { ptrSize: 4, floatSize: 8, cpu: "i386", os: "linux" };
	const host: TargetInfo = { ptrSize: 8, floatSize: 8, cpu: "arm64", os: "macos" };
	assert sizeOfType(wasm, stringType()) == 16;
	assert alignOfType(wasm, createArray(numberType())) == 8;
	assert sizeOfType(i386, stringType()) == 12;
	assert sizeOfType(i386, createSpan(numberType())) == 12;
	assert alignOfType(i386, stringType()) == 4;
	assert sizeOfType(host, stringType()) == 16;
	const held = createStruct("Held", ["v", "t"], [stringType(), createPrimitive(TypeKind.Uint8)], true);
	assert sizeOfType(wasm, held) == 24;
	assert sizeOfType(i386, held) == 16;
}

test "a union of string literals is sized as the string that holds it" {
	const host: TargetInfo = { ptrSize: 8, floatSize: 8, cpu: "arm64", os: "macos" };
	const i386: TargetInfo = { ptrSize: 4, floatSize: 8, cpu: "i386", os: "linux" };
	const align = createUnion([createStringLiteral("auto"), createStringLiteral("center")]);
	assert sizeOfType(host, align) == 16;
	assert alignOfType(host, align) == 8;
	assert sizeOfType(i386, align) == 12;
}

test "field offsets share target padding with struct size" {
	const i386: TargetInfo = { ptrSize: 4, floatSize: 8, cpu: "i386", os: "linux" };
	const sbf: TargetInfo = { ptrSize: 8, floatSize: 8, cpu: "sbf", os: "solana" };
	const nested = createStruct("Nested", ["c", "wide"], [createPrimitive(TypeKind.Uint8), createPrimitive(TypeKind.Uint64)], false);
	const outer = createStruct("Outer", ["lead", "items", "tail"], [createPrimitive(TypeKind.Uint8), createSizedArray(nested, 2), createPrimitive(TypeKind.Uint8)], false);
	assert offsetOfField(i386, nested, "wide") == 4;
	assert offsetOfField(sbf, nested, "wide") == 8;
	assert offsetOfField(i386, outer, "items") == 4;
	assert offsetOfField(i386, outer, "tail") == 28;
	assert sizeOfType(i386, outer) == 32;
	assert offsetOfField(sbf, outer, "items") == 8;
	assert offsetOfField(sbf, outer, "tail") == 40;
	assert sizeOfType(sbf, outer) == 48;
	assert offsetOfField(sbf, outer, "missing") < 0;
	assert offsetOfField(sbf, numberType(), "missing") < 0;
	const unavailable = createStruct("Unavailable", ["unknown", "tail"], [unknownType(), int32Type()], false);
	assert offsetOfField(sbf, unavailable, "tail") < 0;
}

// ===== Maybe<T> + Nullable Pointer Tests =====

test "createMaybeType for interface creates wrapper" {
	const inner = createStruct("Token", ["kind"], [numberType()], true);
	const maybe = createMaybeType(inner);
	assert maybe.kind == TypeKind.Struct;
	assert maybe.typeName == "Maybe_Token";
	assert maybe.typeNames.length == 2;
	assert maybe.typeNames[0] == "value";
	assert maybe.typeNames[1] == "present";
	assert isMaybeType(maybe);
	assert unwrapMaybeType(maybe).typeName == "Token";
}

test "createMaybeType for Ref returns bare pointer" {
	const refType = createRef(createStruct("Foo", [], [], true));
	const result = createMaybeType(refType);
	// Should return the Ref type unchanged — no wrapper
	assert result.kind == TypeKind.Ref;
	assert result == refType;
	assert !isMaybeType(result);
}

test "createMaybeType for Ptr returns bare pointer" {
	const ptrType = createPtr(createStruct("Bar", [], [], true));
	const result = createMaybeType(ptrType);
	// Should return the Ptr type unchanged — no wrapper
	assert result.kind == TypeKind.Ptr;
	assert result == ptrType;
	assert !isMaybeType(result);
}

test "isMaybeType false for Ref" {
	assert !isMaybeType(createRef(numberType()));
}

test "isMaybeType false for Ptr" {
	assert !isMaybeType(createPtr(numberType()));
}

test "isMaybeType false for plain interface" {
	assert !isMaybeType(createStruct("Token", [], [], true));
}

test "createMaybeType caches by name" {
	const inner = createStruct("Cached", [], [], true);
	const m1 = createMaybeType(inner);
	const m2 = createMaybeType(inner);
	assert m1 == m2;
}

// A Locked handle's flags include IsAtomic, so any Arc-first classification
// rebuilds it as Arc<cell> — the payload stops being reachable and the write
// block stops applying. These three pin the ordering at its one home.
test "rebuildRefLike keeps a Locked handle Locked" {
	const rebuilt = rebuildRefLike(createLocked(int32Type()), stringType());
	assert isLockedRef(rebuilt);
	assert lockedPayloadType(rebuilt).kind == TypeKind.String;
}

test "refSubstInner reads a Locked's payload, not its cell" {
	const payload = refSubstInner(createLocked(int32Type()));
	assert payload != null && payload.kind == TypeKind.Int32;
	const pointee = refSubstInner(createArc(stringType()));
	assert pointee != null && pointee.kind == TypeKind.String;
}

test "refWrapperName spells the annotation each Ref class re-resolves from" {
	assert refWrapperName(createLocked(int32Type())) == "Locked";
	assert refWrapperName(createArc(int32Type())) == "Arc";
	assert refWrapperName(createRef(int32Type())) == "";
}

test "only a length-carrying source can be short" {
	assert destrHasRuntimeLength(createArray(int32Type()));
	assert !destrHasRuntimeLength(int32Type());
	assert !destrHasRuntimeLength(null);
}

test "a defaulted binding sheds null" {
	assert destrDefaultedType(createMaybeType(int32Type())) == int32Type();
	assert destrDefaultedType(createUnion([stringType(), nullType()])) == stringType();
	assert destrDefaultedType(int32Type()) == int32Type();
	assert destrDefaultedType(null) == null;
}

import { makeSymbol } from "./symbol";

test "a tuple names its nominal members by declaring symbol" {
	const a = createStruct("TupleCell", ["text"], [stringType()], false);
	a.sym = makeSymbol("TupleCell", SymbolKind.Struct, a, false);
	a.sym.modulePath = "/m/a.ms";
	const b = createStruct("TupleCell", ["count"], [int32Type()], false);
	b.sym = makeSymbol("TupleCell", SymbolKind.Struct, b, false);
	b.sym.modulePath = "/m/b.ms";
	const sameAsA = createStruct("TupleCell", ["text"], [stringType()], false);
	sameAsA.sym = a.sym;
	assert tupleTypeName(createTuple([a, int32Type()])) != tupleTypeName(createTuple([b, int32Type()]));
	assert tupleTypeName(createTuple([a, int32Type()])) == tupleTypeName(createTuple([sameAsA, int32Type()]));
}

test "a tuple refuses a named member that has no declaring symbol" {
	const orphan = createStruct("OrphanCell", ["v"], [int32Type()], false);
	let refused = "";
	try {
		tupleTypeName(createTuple([orphan, int32Type()]));
	} catch (e) {
		refused = e.message;
	}
	assert refused.contains("OrphanCell");
}

test "a named type has identity only from its symbol or the Spelled flag" {
	function refusal(t: Type): string {
		try {
			nominalTypeKey(t);
			return "";
		} catch (e) {
			return e.message;
		}
	}
	const lookalike = createStruct("{x: number}", ["x"], [numberType()], false);
	assert refusal(lookalike).contains("{x: number}");
	const anon = createStruct("__anon1__xn", ["x"], [numberType()], false);
	assert refusal(anon).contains("__anon1__xn");
	const mangled = createStruct("Box__number", ["v"], [numberType()], true);
	assert refusal(mangled).contains("Box__number");
	assert nominalTypeKey(spelled(mangled)) == "Box__number";
	assert nominalTypeKey(spelled(anon)) == "__anon1__xn";
	assert hasTypeIdentity(createMaybeType(stringType()));
	assert hasTypeIdentity(createLockedCell(numberType()));
}

test "an anonymous struct name spells every key as a distinct C identifier" {
	assert anonStructName(["x", "$y"], [numberType(), stringType()]) == "__anon2__xn__dollary_s";
	assert anonStructName(["data-probe"], [stringType()]) == "__anon1__X_dataX2Dprobes";
	assert anonStructName(["é"], [numberType()]) != anonStructName(["è"], [numberType()]);
	assert anonStructName(["a-b"], [numberType()]) != anonStructName(["aminusb_"], [numberType()]);
}

test "an anonymous struct name keeps key boundaries when a key holds a double underscore" {
	assert anonStructName(["x", "s__y"], [stringType(), stringType()]) != anonStructName(["xs__", "y"], [stringType(), stringType()]);
	assert anonStructName(["p", "n__q", "r"], [numberType(), numberType(), numberType()]) != anonStructName(["pn__", "q", "r"], [numberType(), numberType(), numberType()]);
	assert anonStructName(["_id", "x"], [numberType(), numberType()]) == "__anon2___idn__xn";
}
