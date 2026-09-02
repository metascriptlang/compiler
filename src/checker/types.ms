// Type System — utility functions for Type manipulation
// Type class + enums are defined in ast/node.ms (reference parity: single-file AST).

import { bareAfterDelim, splitTopLevel } from "../utils/string";
import { hashToBase36 as _stdHashToBase36 } from "std/hash";
import { Type, TypeKind, TypeFlag, CallingConvention, AttachedOp } from "../ast/node";

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
//   SizedArray     — typeReturn = element, typeFlags upper bits = size
//
// =====================================================================

// ===== Target Configuration (Implementation parity) =====
// Module-level state set once at startup. Defaults to 64-bit.

let targetPtrSize: number = 8;
let targetIntSize: number = 8;

export function setTargetSizes(ptrSize: number, intSize: number): void {
	targetPtrSize = ptrSize;
	targetIntSize = intSize;
}

export function getTargetPtrSize(): number { return targetPtrSize; }
export function getTargetIntSize(): number { return targetIntSize; }


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
	target.callConv = source.callConv;
	target.attachedOps = source.attachedOps;
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
		typeFlags: 0,
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
	if (kind === TypeKind.BigInt) { t.typeFlags = TypeFlag.HasAsgn as int32; }
	return t;
}

export function createStruct(name: string, propNames: string[], propTypes: Type[], isInterface: boolean): Type {
	const t = emptyType();
	t.kind = TypeKind.Struct;
	t.typeName = name;
	t.typeNames = propNames;
	t.typeChildren = propTypes;
	if (isInterface) { t.typeFlags = TypeFlag.IsStruct as int32; }
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
	if (fieldNames.length === 0) return "";
	let name = "__anon" + fieldNames.length;
	let i = 0;
	while (i < fieldNames.length) {
		const ft = i < fieldTypes.length ? fieldTypes[i] : null;
		let suffix = "x";
		if (ft !== null) {
			suffix = match (ft.kind) {
				TypeKind.Number | TypeKind.Float64 => "n",
				TypeKind.Float32 => "f",
				TypeKind.String => "s",
				TypeKind.Boolean => "b",
				TypeKind.Int8 | TypeKind.Int16 | TypeKind.Int32 | TypeKind.Int64 => "i",
				TypeKind.Uint8 | TypeKind.Uint16 | TypeKind.Uint32 | TypeKind.Uint64 => "u",
				TypeKind.Array => {
					// Distinguish array element types to avoid struct name collision
					// (e.g., string[] field vs unknown[] field producing the same anon struct name)
					if (ft.typeReturn !== null) {
						return match (ft.typeReturn.kind) {
							TypeKind.String => "As",
							TypeKind.Number | TypeKind.Float64 => "An",
							TypeKind.Boolean => "Ab",
							_ => "x",
						};
					} else {
						return "x";
					}
				},
				_ => "x",
			};
		}
		name = name + "__" + fieldNames[i] + suffix;
		i = i + 1;
	}
	return name;
}

export function createArray(element: Type | null): Type {
	return {
		kind: TypeKind.Array, typeName: "", typeNames: [], typeChildren: [],
		typeReturn: element, typeExtra: null, typeFlags: TypeFlag.HasAsgn as int32,
		callConv: CallingConvention.CcDefault, attachedOps: [],
	};
}

// Reference parity (tyVarargs): wraps a rest parameter's user-written array
// type. Used only on Function.typeChildren[last] when the corresponding param
// is rest. Transparent to most type code via unwrapVarargs / isVarargs.
export function createVarargs(arrayType: Type): Type {
	return {
		kind: TypeKind.Varargs, typeName: "", typeNames: [], typeChildren: [arrayType],
		typeReturn: null, typeExtra: null, typeFlags: TypeFlag.HasAsgn as int32,
		callConv: CallingConvention.CcDefault, attachedOps: [],
	};
}

export function isVarargs(t: Type): boolean {
	return t !== null && t.kind === TypeKind.Varargs;
}

export function unwrapVarargs(t: Type): Type {
	if (t !== null && t.kind === TypeKind.Varargs && t.typeChildren.length > 0) {
		return t.typeChildren[0];
	}
	return t;
}

export function createSizedArray(element: Type | null, size: number): Type {
	const t = emptyType();
	t.kind = TypeKind.SizedArray;
	t.typeReturn = element;
	t.typeFlags = size;
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
	if (last >= 0 && ownNames[last].length > 3 && ownNames[last].slice(0, 3) === "...") {
		ownNames[last] = ownNames[last].slice(3, ownNames[last].length);
		if (last < ownTypes.length && ownTypes[last].kind !== TypeKind.Varargs) {
			ownTypes[last] = createVarargs(ownTypes[last]);
		}
	}
	return {
		kind: TypeKind.Function, typeName: "", typeNames: ownNames, typeChildren: ownTypes,
		typeReturn: returnType, typeExtra: null, typeFlags: TypeFlag.HasAsgn as int32,
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

export function createEnum(name: string, members: string[], values: number[]): Type {
	const t = emptyType();
	t.kind = TypeKind.Enum;
	t.typeName = name;
	t.typeNames = members;
	// Store enum member values as Type objects with typeFlags holding the integer value
	if (values !== null && values.length > 0) {
		const valTypes: Type[] = [];
		let i = 0;
		while (i < values.length) {
			const vt = emptyType();
			vt.kind = TypeKind.Number;
			vt.typeFlags = values[i] as int32;
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
export function createResult(okType: Type, errType: Type): Type {
	// Use Result's own GenericParam placeholders (named "T"/"E") in variants
	// instead of baking the user-supplied okType/errType. Why: when the user
	// composes `Result<T[], E>` inside a function whose own generic param is
	// also named "T", the baked `Array<GenericParam("T_user"))` collides with
	// Result's "T" at codegen substitution time — sub fires twice, producing
	// `Array<Array<int32>>` (the msRefArrayArray double-wrap bug).
	// Keeping variants generic until codegen substitutes Result's "T"/"E"
	// against `typeChildren` cleanly avoids the name collision. Concrete
	// user types live ONLY in typeChildren; getResultOkType/getResultErrType
	// already read from typeChildren, so accessor callers are unaffected.
	const tParam = createGenericParam("T");
	const eParam = createGenericParam("E");
	const trueVariant = emptyType();
	trueVariant.kind = TypeKind.Struct;
	trueVariant.typeNames = ["ok", "value"];
	trueVariant.typeChildren = [createBooleanLiteral(true), tParam];
	const falseVariant = emptyType();
	falseVariant.kind = TypeKind.Struct;
	falseVariant.typeNames = ["ok", "error"];
	falseVariant.typeChildren = [createBooleanLiteral(false), eParam];
	const base = createUnion([trueVariant, falseVariant]);
	base.typeName = "Result";
	base.typeExtra = booleanType();
	base.typeNames = ["ok", "true", "false"];
	base.typeFlags = TypeFlag.HasAsgn as int32;
	return createGenericInstance(base, [okType, errType]);
}

export function createPromise(innerType: Type | null): Type {
	const base = emptyType();
	base.kind = TypeKind.Struct;
	base.typeName = "Promise";
	base.typeNames = [];
	base.typeChildren = [];
	return createGenericInstance(base, [innerType]);
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
	base.typeFlags = (TypeFlag.AwaitableAffine | TypeFlag.AwaitableScopeBound) as int32;
	return createGenericInstance(base, [innerType]);
}

// Iterator<T> — return type of function* generators. Wraps yield type T.
// At runtime: { next: () => { value: T, done: boolean } }
export function createIteratorResult(yieldType: Type): Type {
	const genericBase = createStruct("IteratorResult", ["value", "done"], [createGenericParam("T"), createPrimitive(TypeKind.Boolean)], false);
	const gi = createGenericInstance(genericBase, [yieldType]);
	instantiateGenericBody(gi, "T");
	return gi;
}

export function createIterator(yieldType: Type): Type {
	const nextFnType = createClosureType([], [], createIteratorResult(yieldType));
	const iter = createStruct("Iterator", ["next"], [nextFnType], false);
	return iter;
}

export function isIterator(t: Type | null): boolean {
	if (t === null) return false;
	return t.typeName === "Iterator";
}

export function getIteratorNextFnType(t: Type | null): Type | null {
	if (t === null || !isIterator(t)) return null;
	if (t.typeChildren !== null && t.typeChildren.length > 0) return t.typeChildren[0];
	return null;
}

export function getIteratorYieldType(t: Type): Type | null {
	if (t === null) return null;
	// Iterator struct has field "next: () => IteratorResult<T>"
	// IteratorResult has field "value: T" — extract T from there
	if (t.typeChildren !== null && t.typeChildren.length > 0) {
		const nextFnType = t.typeChildren[0]; // the next() function type
		if (nextFnType !== null && nextFnType.typeReturn !== null) {
			const resultType = nextFnType.typeReturn; // IteratorResult<T>
			if (resultType.typeChildren !== null && resultType.typeChildren.length > 0) {
				return resultType.typeChildren[0]; // T (the value field)
			}
		}
	}
	return inferredType();
}

export function isResult(t: Type | null): boolean {
	if (t === null) return false;
	if (t.kind === TypeKind.Result) return true;
	return t.kind === TypeKind.GenericInstance && t.typeName === "Result";
}

// Result's ok-type / err-type live on the GenericInstance's `typeChildren`
// slots ([T, E] from `Result<T, E>`). The Union body's `typeExtra` carries the
// disc TYPE (`Boolean`) — never the err type — so reading it would be wrong.
// `createResult` always wraps in a GI; `null` returns are for non-Result inputs.
export function getResultOkType(t: Type | null): Type | null {
	if (t === null) return null;
	if (t.kind === TypeKind.GenericInstance && t.typeChildren.length > 0) return t.typeChildren[0];
	return null;
}

export function getResultErrType(t: Type | null): Type | null {
	if (t === null) return null;
	if (t.kind === TypeKind.GenericInstance && t.typeChildren.length > 1) return t.typeChildren[1];
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
const PEEL_MAX_DEPTH = 8;

// Universal peeler: strip transparent wrappers per the mask.
// Does NOT peel GenericInstance — for shape queries, GenericInstance IS the answer
// (e.g. Promise<T> is a GenericInstance we want to inspect, not peel past).
// Returns the input unchanged if no layer matches the mask.
export function peelThrough(t: Type, mask: int32): Type | null {
	if (t === null) return null;
	let cur = t;
	let _g = 0;
	// Fixed-point loop — keep peeling until no layer matches the mask.
	// Bounded by PEEL_MAX_DEPTH: a cyclic Alias/Distinct chain never reaches a
	// fixpoint (next always differs from cur), so an unbounded loop would spin.
	while (_g < PEEL_MAX_DEPTH) {
		_g = _g + 1;
		let next: Type = cur;
		if (cur.kind === TypeKind.Alias && (mask & PEEL_ALIAS) !== 0
			&& cur.typeReturn !== null) {
			next = cur.typeReturn;
		} else if (cur.kind === TypeKind.Distinct && (mask & PEEL_DISTINCT) !== 0
			&& cur.typeChildren !== null && cur.typeChildren.length > 0
			&& cur.typeChildren[0] !== null) {
			next = cur.typeChildren[0];
		}
		if (next === cur) return cur;
		cur = next;
	}
	return cur;
}

// isAwaitable — the canonical "can we await this?" question.
// Returns true for `Promise<T>` (plain or affine) and @awaitable-annotated types
// (detected by the AwaitableAffine flag bit set by `createGenericInstance`).
// Peels through Alias wrappers so `type P = Promise<int>; P` still answers true.
export function isAwaitable(t: Type | null): boolean {
	if (t === null) return false;
	const p = peelThrough(t, PEEL_ALIAS);
	if (p === null || p.kind !== TypeKind.GenericInstance) return false;
	if (p.typeName === "Promise") return true;
	// REPROMISE T2 Stage A: @affineAwaitable-annotated types carry both bits.
	if ((p.typeFlags & (TypeFlag.AwaitableAffine as int32)) !== 0) return true;
	return false;
}

// awaitedType — the T inside an Awaitable<T>. Returns null for non-awaitables
// or shape-degenerate awaitables (e.g. typeChildren empty).
export function awaitedType(t: Type | null): Type | null {
	if (t === null) return null;
	const p = peelThrough(t, PEEL_ALIAS);
	if (p === null || !isAwaitable(p)) return null;
	if (p.typeChildren !== null && p.typeChildren.length > 0) return p.typeChildren[0];
	// Fallback for edge cases where a stub awaitable has no type arg recorded yet.
	return p.typeReturn;
}

// isAffineAwaitable — an awaitable carrying affine consumption semantics
// (spawn-origin Promises, @affineAwaitable types). Reads the flag bit set by T2.
// Used by PARALOCK R1-R6 affine checker rules.
export function isAffineAwaitable(t: Type | null): boolean {
	if (t === null) return false;
	const p = peelThrough(t, PEEL_ALIAS);
	if (p === null) return false;
	return (p.typeFlags & (TypeFlag.AwaitableAffine as int32)) !== 0;
}

export function createTypeRef(name: string): Type {
	const t = emptyType();
	t.kind = TypeKind.TypeReference;
	t.typeName = name;
	return t;
}

export function createUnion(types: Type[]): Type {
	// Flatten nested unions — `Union(Null, Union(A, B))` becomes `Union(Null, A, B)`.
	// Without flattening, downstream shape checks miss the canonical form and
	// codegen falls back to a literal tagged union.
	let needsFlatten = false;
	for (const ut of types) {
		if (ut !== null && ut.kind === TypeKind.Union) { needsFlatten = true; break; }
	}
	let flat: Type[] = types;
	if (needsFlatten) {
		flat = [];
		for (const ut of types) {
			if (ut !== null && ut.kind === TypeKind.Union && ut.typeChildren !== null) {
				for (const inner of ut.typeChildren) {
					if (inner !== null) flat.push(inner);
				}
			} else if (ut !== null) {
				flat.push(ut);
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
		if (k === null) continue;
		let dup = false;
		for (const u of seen) {
			if (u === k) { dup = true; break; }
		}
		if (!dup) seen.push(k);
	}
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
			if (ut !== null && ut.kind === TypeKind.Union
				&& ut.typeNames !== null && ut.typeNames.length >= 2) {
				metaSrc = ut;
				metaCount += 1;
			}
		}
		if (metaCount === 1 && metaSrc !== null && metaSrc.typeChildren !== null) {
			const vc = metaSrc.typeChildren.length;
			let aligned = seen.length >= vc;
			if (aligned) {
				for (let vi = 0; vi < vc; vi += 1) {
					if (seen[vi] !== metaSrc.typeChildren[vi]) { aligned = false; break; }
				}
			}
			if (aligned) {
				for (let ei = vc; ei < seen.length; ei += 1) {
					if (seen[ei].kind !== TypeKind.Null) { aligned = false; break; }
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

// DU-variant identity (Nim attachedOps-by-ItemId analog for structural types):
// an INLINE (nameless) struct variant exists only as its union's payload — its
// C storage and lifecycle belong to the DU machinery (<Union>_vN carriers), so
// the analyzer must defer (classify → no RC). Named-alias variants keep their
// own identity and sound named-hook path; do NOT flag them (they double as
// standalone user value types). Separate function on purpose: inlining this
// loop into createUnion hangs the v0.2.24 analyzer on the enlarged var graph.
function stampInlineDuVariants(seen: Type[]): void {
	for (const v of seen) {
		if (v.kind === TypeKind.Struct && v.typeName === "") {
			const nf: int32 = v.typeFlags | (TypeFlag.DuVariant as int32);
			v.typeFlags = nf;
			duRegAdd(_duVariantRegistry, v);
		}
	}
}

// Registered inline-variant payload types, in registration order. The flag on the
// object is NOT enough downstream: eager per-module imports and exploratory literal
// checks mint structurally-equal COPIES that never pass through createUnion. The
// analyzer resolves identity for those by STRUCTURAL HASH over this registry
// (classify.ms) — the MS-native analog of Nim's single-world ItemId, given the
// intentional per-module type worlds (NIM-REF Import-resolution row).
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

// Find which union variant contains ALL the given field names (and optionally types).
// When fieldTypes is non-empty, also checks type kind to disambiguate variants with
// same field names but different types (e.g., { value: number } vs { value: string }).
// Returns the variant index, or -1 if no variant matches.
export function findUnionVariant(unionType: Type | null, fieldNames: string[], fieldTypes: Type[]): number {
	if (unionType === null || unionType.typeChildren === null || fieldNames.length === 0) return -1;
	let vi = 0;
	while (vi < unionType.typeChildren.length) {
		const variant = unionType.typeChildren[vi];
		if (variant !== null && variant.typeNames !== null && variant.typeNames.length >= fieldNames.length) {
			let allFound = true;
			let ti = 0;
			while (ti < fieldNames.length) {
				let found = false;
				let fi = 0;
				while (fi < variant.typeNames.length) {
					if (variant.typeNames[fi] === fieldNames[ti]) {
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
function typesCompatibleForVariant(formal: Type, actual: Type): boolean {
	if (formal === null || actual === null) return false;
	if (formal.kind === actual.kind) return true;
	// Numeric family: number, int8-int64, uint8-uint64, float32, float64
	if (isNumeric(formal) && isNumeric(actual)) return true;
	// Reference family: Ref, Ptr, Borrow all compatible
	if ((formal.kind === TypeKind.Ref || formal.kind === TypeKind.Ptr || formal.kind === TypeKind.Borrow)
		&& (actual.kind === TypeKind.Ref || actual.kind === TypeKind.Ptr || actual.kind === TypeKind.Borrow)) return true;
	return false;
}

// Check if a name-only matched variant is ambiguous (another variant has the same field names).
// When ambiguous, we need property types to disambiguate (e.g. { value: number } vs { value: string }).
export function isAmbiguousVariant(unionType: Type | null, matchedIdx: number, fieldNames: string[]): boolean {
	if (unionType === null || unionType.typeChildren === null) return false;
	let vi = 0;
	while (vi < unionType.typeChildren.length) {
		if (vi !== matchedIdx) {
			const variant = unionType.typeChildren[vi];
			if (variant !== null && variant.typeNames !== null && variant.typeNames.length >= fieldNames.length) {
				let allFound = true;
				let ti = 0;
				while (ti < fieldNames.length) {
					let found = false;
					let fi = 0;
					while (fi < variant.typeNames.length) {
						if (variant.typeNames[fi] === fieldNames[ti]) { found = true; fi = variant.typeNames.length; }
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
export function findFieldInVariant(variant: Type, fieldName: string): Type | null {
	// Peel Ref/Ptr — interface-typed variants are Ref<Struct> in the C backend.
	const v = peelToStruct(variant);
	if (v === null || v.typeNames === null) return null;
	let i = 0;
	while (i < v.typeNames.length) {
		if (v.typeNames[i] === fieldName && i < v.typeChildren.length) {
			return v.typeChildren[i];
		}
		i = i + 1;
	}
	return null;
}

export function unionVariantHasProperty(t: Type | null, name: string): boolean {
	if (t === null || t.kind !== TypeKind.Union || t.typeChildren === null) return false;
	for (const variant of t.typeChildren) {
		if (variant === null) continue;
		if (findFieldInVariant(variant, name) !== null) return true;
	}
	return false;
}

// Check if a union type is a discriminated union (has discriminant metadata).
// Discriminated unions have typeExtra (enum type) and typeNames[0] (discriminant field name).
export function isDiscriminatedUnion(t: Type | null): boolean {
	if (t === null) return false;
	return t.kind === TypeKind.Union && t.typeExtra !== null && t.typeNames !== null && t.typeNames.length > 0;
}

// Get the discriminant field name from a discriminated union.
export function getDiscriminantName(t: Type | null): string {
	if (t === null) return "";
	if (t.typeNames !== null && t.typeNames.length > 0) return t.typeNames[0];
	return "";
}

// Tier 2: detect if a Union type has a discriminant field matching `fieldName`.
// Returns { isStringDU, discField } — the caller can use these to pick the right
// variant-finding function (findVariantByDiscriminant vs findVariantByStringDiscriminant).
// Checks enum-based DUs first, then string-literal DUs.
export interface DiscriminantInfo {
	isStringDU: boolean;
	discField: string;
}

export function detectUnionDiscriminant(unionType: Type | null, fieldName: string): DiscriminantInfo {
	if (isDiscriminatedUnion(unionType) && getDiscriminantName(unionType) === fieldName) {
		return { isStringDU: false, discField: fieldName };
	}
	if (unionType !== null && unionType.kind === TypeKind.Union) {
		const sdf = findSharedStringDiscriminant(unionType);
		if (sdf !== "" && sdf === fieldName) {
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
let _fvbTime: float64 = 0;
export function findVariantByFieldNameProfile(): float64[] { return [_fvbCount, _fvbTime]; }
export function findVariantByFieldName(unionType: Type | null, fieldName: string): number {
	_fvbCount = _fvbCount + 1;
	const _v0 = performance.now();
	const r = findVariantByFieldNameInner(unionType, fieldName);
	_fvbTime = _fvbTime + (performance.now() - _v0);
	return r;
}
function findVariantByFieldNameInner(unionType: Type | null, fieldName: string): number {
	if (unionType === null || unionType.typeChildren === null) return -1;
	let i = 0;
	while (i < unionType.typeChildren.length) {
		const variant = peelToStruct(unionType.typeChildren[i]);
		if (variant !== null && variant.typeNames !== null) {
			for (const fn of variant.typeNames) {
				if (fn === fieldName) return i;
			}
		}
		i = i + 1;
	}
	return -1;
}

// Index of a narrowed variant within its declaring union — identity first
// (flow narrowing returns the union's own typeChildren element), then identity
// after peeling Ref wrappers (TS-style DU variants are Ref<interface>), then
// typeName (variants are stamped "<Alias>.<Key>" / interface names, unique per union).
export function duVariantIndexOfType(unionType: Type | null, variantType: Type | null): number {
	if (unionType === null || unionType.typeChildren === null || variantType === null) return -1;
	for (let i = 0; i < unionType.typeChildren.length; i += 1) {
		if (unionType.typeChildren[i] === variantType) return i;
	}
	const target = peelToStruct(variantType);
	if (target === null) return -1;
	for (let i = 0; i < unionType.typeChildren.length; i += 1) {
		if (peelToStruct(unionType.typeChildren[i]) === target) return i;
	}
	if (target.typeName === "") return -1;
	for (let i = 0; i < unionType.typeChildren.length; i += 1) {
		const v = peelToStruct(unionType.typeChildren[i]);
		if (v !== null && v.typeName === target.typeName) return i;
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

export function variantIndexInUnion(formal: Type, exprType: Type): int32 {
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

// `A | null` meeting `A | B | null`: the same subtyping one level down, under
// the Maybe carrier. Returns the payload's slot in the wider union, or -1.
// A union payload widening into a wider union has no single slot to stamp and
// is refused here rather than guessed.
export function maybePayloadWidenSlot(source: Type | null, target: Type | null): int32 {
	if (source === null || target === null) return -1;
	if (!isMaybeType(source) || !isMaybeType(target)) return -1;
	const narrow = source.typeReturn;
	const wide = target.typeReturn;
	if (narrow === null || wide === null) return -1;
	if (wide.kind !== TypeKind.Union || wide.typeChildren === null) return -1;
	if (narrow.kind === TypeKind.Union) return -1;
	if (unwrapRefNullUnion(wide) !== null) return -1;
	return variantIndexInUnion(wide, unwrapRef(narrow));
}

// Layout name for prefix/field signatures: literal types collapse to their base
// (a "a" vs "b" string-literal discriminant is the SAME msString layout), while
// genuinely different widths (int16 vs int32) stay distinct.
function duLayoutName(t: Type | null): string {
	if (t === null) return "?";
	return match (t.kind) {
		TypeKind.StringLiteral => "string",
		TypeKind.BooleanLiteral => "boolean",
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
	if (unionType === null || unionType.typeChildren === null) return false;
	let firstSig = "";
	let found = 0;
	for (let i = 0; i < unionType.typeChildren.length; i += 1) {
		const variant = peelToStruct(unionType.typeChildren[i]);
		if (variant === null || variant.typeNames === null) continue;
		let sig = "";
		let hasField = false;
		for (let fi = 0; fi < variant.typeNames.length; fi += 1) {
			const ft = fi < variant.typeChildren.length ? variant.typeChildren[fi] : null;
			sig = sig + "|" + duLayoutName(ft);
			if (variant.typeNames[fi] === fieldName) { hasField = true; break; }
		}
		if (!hasField) continue;
		if (found === 0) {
			firstSig = sig;
		} else if (sig !== firstSig) {
			return true;
		}
		found += 1;
	}
	return false;
}

// Find variant index by discriminant enum value name (e.g. "NumLit" or "NodeKind.NumLit").
// typeNames layout: [discFieldName, key0, key1, ...] — keys start at index 1.
// Matches both qualified ("Kind.A") and unqualified ("A") against stored keys.
export function findVariantByDiscriminant(unionType: Type | null, enumValue: string): number {
	if (unionType === null || unionType.typeNames === null || unionType.typeNames.length < 2) return -1;
	const queryBare = bareAfterDelim(enumValue, ".");
	// Also handle underscore-mangled form: checkMemberExpr rewrites EnumType.Member to EnumType_Member
	const queryBareUnderscore = bareAfterDelim(enumValue, "_");
	let i = 1;
	while (i < unionType.typeNames.length) {
		const stored = unionType.typeNames[i];
		if (stored === enumValue) return i - 1;
		const storedBare = bareAfterDelim(stored, ".");
		if (storedBare === queryBare) return i - 1;
		if (storedBare === queryBareUnderscore) return i - 1;
		i = i + 1;
	}
	return -1;
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
export function peelToStruct(t: Type | null): Type | null {
	if (t === null) return null;
	let cur: Type = t;
	let _g = 0;
	while (cur !== null && _g < PEEL_MAX_DEPTH) {
		_g = _g + 1;
		if (cur.kind === TypeKind.Struct) return cur;
		if ((cur.kind === TypeKind.Ref || cur.kind === TypeKind.Ptr || cur.kind === TypeKind.Alias) && cur.typeReturn !== null) {
			cur = cur.typeReturn;
			continue;
		}
		break;
	}
	return cur;
}

// Peel Ref/Ptr/GenericInstance wrappers until reaching a Struct or Union body.
// Used by checkers and codegen for generic match-type aliases like
// `MyResult<T, E> = Ref<MyData<T, E>>` where the chain is GI → Ref → GI → Union.
// Returns the original type if no peelable wrapper exists. Bounded by
// `PEEL_MAX_DEPTH` against pathological cyclic types.
export function peelToStructOrUnion(t: Type | null): Type | null {
	if (t === null) return null;
	let cur: Type = t;
	let _g = 0;
	while (cur !== null && _g < PEEL_MAX_DEPTH) {
		_g = _g + 1;
		if (cur.kind === TypeKind.Struct || cur.kind === TypeKind.Union) return cur;
		if ((cur.kind === TypeKind.Ref || cur.kind === TypeKind.Ptr || cur.kind === TypeKind.Cursor || cur.kind === TypeKind.Alias) && cur.typeReturn !== null) {
			cur = cur.typeReturn;
			continue;
		}
		if (cur.kind === TypeKind.GenericInstance) {
			if (cur.typeReturn !== null) {
				cur = cur.typeReturn;
				continue;
			}
			if (cur.typeExtra !== null) {
				cur = cur.typeExtra;
				continue;
			}
		}
		break;
	}
	return cur;
}

// A generic instantiation whose body has no nominal Struct/Union carries no
// identity of its own: `type Brand<T> = T` means `Brand<number>` IS number.
// Reference parity: ccgtypes.nim `irrelevantForBackend` + getSimpleTypeDesc
// `of tyGenericInst: skipModifier typ`.
export function peelTransparentInstance(t: Type): Type {
	let cur: Type = t;
	let _g = 0;
	while (_g < PEEL_MAX_DEPTH) {
		_g = _g + 1;
		if (cur.kind !== TypeKind.GenericInstance || cur.typeReturn === null) return cur;
		const nominal = peelToStructOrUnion(cur.typeExtra);
		if (nominal !== null
			&& (nominal.kind === TypeKind.Struct || nominal.kind === TypeKind.Union)) return cur;
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
function literalDiscValue(t: Type | null): string {
	if (t === null) return "";
	if (t.kind === TypeKind.EnumLiteral) {
		return t.typeNames !== null && t.typeNames.length > 0 ? t.typeName + "." + t.typeNames[0] : t.typeName;
	}
	return t.typeName;
}

function findSharedLiteralDiscriminant(unionType: Type | null, literalKind: TypeKind): string {
	if (unionType === null || unionType.typeChildren === null || unionType.typeChildren.length < 2) return "";
	const variants = unionType.typeChildren;
	const first = peelToStruct(variants[0]);
	if (first === null || first.typeNames === null) return "";
	for (let fi = 0; fi < first.typeNames.length; fi += 1) {
		if (fi >= first.typeChildren.length) continue;
		const firstFt = first.typeChildren[fi];
		if (firstFt === null || firstFt.kind !== literalKind) continue;
		const candidateName = first.typeNames[fi];
		// Check every other variant has this field as the same literal kind with a
		// *different* value (so the discriminator can disambiguate variants).
		let sharedOk = true;
		const seen: string[] = [literalDiscValue(firstFt)];
		for (let vi = 1; vi < variants.length; vi += 1) {
			const v = peelToStruct(variants[vi]);
			if (v === null || v.typeNames === null) { sharedOk = false; break; }
			let foundInV = false;
			for (let vfi = 0; vfi < v.typeNames.length; vfi += 1) {
				if (v.typeNames[vfi] !== candidateName) continue;
				if (vfi >= v.typeChildren.length) break;
				const vft = v.typeChildren[vfi];
				if (vft === null || vft.kind !== literalKind) break;
				const vftValue = literalDiscValue(vft);
				let dup = false;
				for (const s of seen) { if (s === vftValue) { dup = true; break; } }
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

export function findSharedStringDiscriminant(unionType: Type | null): string {
	return findSharedLiteralDiscriminant(unionType, TypeKind.StringLiteral);
}

// Tier 2 (boolean): detect a boolean-literal discriminant shared by every variant.
// Variants must each have the same field name with a BooleanLiteral type and
// distinct values (true vs false).
export function findSharedBooleanDiscriminant(unionType: Type | null): string {
	return findSharedLiteralDiscriminant(unionType, TypeKind.BooleanLiteral);
}

// Tier 2 (enum): a TS-style union whose variants each pin the same field to a
// distinct enum member (`kind: EvKind.Click` | `kind: EvKind.Key`). This is the
// same discriminator the match-type DU form declares — see the auto-stamp in
// resolvePass, which promotes it to the enum DU contract (typeExtra + typeNames).
export function findSharedEnumDiscriminant(unionType: Type | null): string {
	return findSharedLiteralDiscriminant(unionType, TypeKind.EnumLiteral);
}

// The Enum Type behind an enum-literal discriminant field, read off the first
// variant that carries it (EnumLiteral.typeReturn back-references the enum).
export function enumDiscriminantTypeOf(unionType: Type | null, discFieldName: string): Type | null {
	if (unionType === null || unionType.typeChildren === null) return null;
	for (const rawVariant of unionType.typeChildren) {
		const variant = peelToStruct(rawVariant);
		if (variant === null || variant.typeNames === null) continue;
		for (let fi = 0; fi < variant.typeNames.length; fi += 1) {
			if (variant.typeNames[fi] !== discFieldName) continue;
			if (fi >= variant.typeChildren.length) break;
			const ft = variant.typeChildren[fi];
			if (ft !== null && ft.kind === TypeKind.EnumLiteral) return ft.typeReturn;
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
function findVariantByLiteralDiscriminant(unionType: Type | null, discFieldName: string, literalKind: TypeKind, litValueName: string): number {
	if (unionType === null || unionType.typeChildren === null) return -1;
	for (let i = 0; i < unionType.typeChildren.length; i += 1) {
		const variant = peelToStruct(unionType.typeChildren[i]);
		if (variant === null || variant.typeNames === null) continue;
		for (let fi = 0; fi < variant.typeNames.length; fi += 1) {
			if (variant.typeNames[fi] !== discFieldName) continue;
			if (fi >= variant.typeChildren.length) continue;
			const ft = variant.typeChildren[fi];
			if (ft !== null && ft.kind === literalKind && literalDiscValue(ft) === litValueName) {
				return i;
			}
		}
	}
	return -1;
}

// Find variant index by boolean literal discriminator value.
export function findVariantByBooleanDiscriminant(unionType: Type | null, discFieldName: string, litValue: boolean): number {
	return findVariantByLiteralDiscriminant(unionType, discFieldName, TypeKind.BooleanLiteral, litValue ? "true" : "false");
}

// Tier 2: collect all string-literal discriminant values from a union's variants.
// Returns ["circle", "square"] for type Shape = {kind:"circle",...} | {kind:"square",...}.
function collectLiteralDiscriminantValues(unionType: Type | null, discFieldName: string, literalKind: TypeKind): string[] {
	const values: string[] = [];
	if (unionType === null || unionType.typeChildren === null) return values;
	for (const rawVariant of unionType.typeChildren) {
		const variant = peelToStruct(rawVariant);
		if (variant === null || variant.typeNames === null) continue;
		for (let fi = 0; fi < variant.typeNames.length; fi += 1) {
			if (variant.typeNames[fi] !== discFieldName) continue;
			if (fi >= variant.typeChildren.length) continue;
			const ft = variant.typeChildren[fi];
			if (ft !== null && ft.kind === literalKind) {
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
// `findVariantByDiscriminant` (dotted `Enum.Member`, same form the match-type DU
// declaration stores).
export function collectEnumDiscriminantValues(unionType: Type | null, discFieldName: string): string[] {
	return collectLiteralDiscriminantValues(unionType, discFieldName, TypeKind.EnumLiteral);
}

// Tier 2: find variant index by scanning variant structs directly for a string-literal
// discriminant field matching `discFieldName` with the given literal value.
// Used when the union is string-literal based (type Shape = {kind:"a",...} | {kind:"b",...})
// and there's no enum-backed discriminant metadata on the union itself.
// Returns -1 if no variant has a StringLiteral field matching the value.
export function findVariantByStringDiscriminant(unionType: Type | null, discFieldName: string, litValue: string): number {
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

function maybeCacheKey(inner: Type): string {
	if (inner.kind === TypeKind.StringLiteral) return "sl_" + identSafeKey(inner.typeName);
	if (inner.typeName !== "") return inner.typeName;
	if (isAllStringLiteralUnion(inner)) {
		let key = "slu";
		for (const c of inner.typeChildren) {
			if (c !== null) key = key + "_" + identSafeKey(c.typeName);
		}
		return key;
	}
	if (inner.kind === TypeKind.Function) return "fn_" + identSafeKey(typeKey(inner));
	const k = inner.kind;
	if (k === TypeKind.Union || k === TypeKind.Array || k === TypeKind.Tuple || k === TypeKind.Span || k === TypeKind.SizedArray) {
		return "p" + (k as number) + "_" + identSafeKey(typeKey(inner));
	}
	return "p" + (inner.kind as number);
}

export function createMaybeType(inner: Type): Type {
	// Pointer types are inherently nullable — no wrapper needed (reference parity: nullable pointers)
	if (inner.kind === TypeKind.Ref || inner.kind === TypeKind.Ptr) return inner;
	const key = maybeCacheKey(inner);
	let i = 0;
	while (i < _maybeCacheNames.length) {
		if (_maybeCacheNames[i] === key) return _maybeCache[i];
		i += 1;
	}
	const t = emptyType();
	t.kind = TypeKind.Struct;
	t.typeName = "Maybe_" + key;
	t.typeNames = ["value", "present"];
	t.typeChildren = [inner, booleanType()];
	t.typeFlags = (TypeFlag.IsStruct | TypeFlag.IsMaybe) as int32;
	t.typeReturn = inner;    // store inner type for unwrapping
	propagateToOwner(t, inner);
	_maybeCache.push(t);
	_maybeCacheNames.push(key);
	return t;
}

export function createRef(inner: Type | null): Type {
	const t = emptyType();
	t.kind = TypeKind.Ref;
	t.typeReturn = inner;
	t.typeFlags = TypeFlag.HasAsgn as int32;
	return t;
}

export function createArc(inner: Type | null): Type {
	const t = emptyType();
	t.kind = TypeKind.Ref;
	t.typeReturn = inner;
	t.typeFlags = (TypeFlag.HasAsgn | TypeFlag.IsAtomic) as int32;
	return t;
}

export function isAtomicRef(t: Type | null): boolean {
	return t !== null && t.kind === TypeKind.Ref && (t.typeFlags & TypeFlag.IsAtomic) !== 0;
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
	if (t !== null && t.kind === TypeKind.Cursor) return t.typeReturn;
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

export function createBrandDistinct(brandKey: string, inner: Type): Type {
	const t = createDistinct(inner);
	t.typeName = brandKey;
	t.typeFlags = t.typeFlags | (TypeFlag.BrandWiden as int32);
	return t;
}

export function isBrandDistinct(t: Type | null): boolean {
	if (t === null) return false;
	return t.kind === TypeKind.Distinct && (t.typeFlags & (TypeFlag.BrandWiden as int32)) !== 0;
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
export function unwrapRefBase(t: Type): Type {
	return (t !== null && t.kind === TypeKind.Ref && t.typeReturn !== null) ? t.typeReturn : t;
}

export function createGenericInstance(baseType: Type, typeArgs: Type[]): Type {
	const innerBase = unwrapRefBase(baseType);
	return {
		kind: TypeKind.GenericInstance,
		typeName: innerBase !== null ? innerBase.typeName : "",
		typeNames: [],
		typeChildren: typeArgs,
		typeReturn: null as unknown as Type,
		typeExtra: baseType,
		typeFlags: innerBase !== null ? innerBase.typeFlags : 0 as int32,
		callConv: CallingConvention.CcDefault,
		attachedOps: [],
	};
}

// Reference parity (handleGenericInvocation): eagerly instantiate
// GenericInstance body. Uses explicit param names from the parser's generic declaration
// store. Produces a fully concrete body
// stored in typeReturn for direct field access — no lazy substitution at access time.
export function instantiateGenericBody(gi: Type, declaredParams: string): void {
	if (gi.kind !== TypeKind.GenericInstance) return;
	if (gi.typeReturn !== null) return;
	if (declaredParams === "") return;
	const baseType = gi.typeExtra;
	if (baseType === null) return;
	// Unwrap Ref for interface types (interface = Ref<Struct> after refactor)
	const isRefWrapped = baseType.kind === TypeKind.Ref && baseType.typeReturn !== null;
	const innerBase = isRefWrapped ? baseType.typeReturn : baseType;
	if (innerBase.kind !== TypeKind.Struct && innerBase.kind !== TypeKind.Union
		&& innerBase.kind !== TypeKind.Conditional && innerBase.kind !== TypeKind.GenericParam
		&& innerBase.kind !== TypeKind.GenericInstance) return;
	// Split declared param names (e.g. "K,V" → ["K", "V"])
	const paramNames = splitTopLevel(declaredParams, ",");
	if (paramNames.length === 0 || paramNames.length > gi.typeChildren.length) return;
	const names: string[] = [];
	const args: Type[] = [];
	let pi = 0;
	while (pi < paramNames.length) {
		names.push(paramNames[pi].trim());
		args.push(gi.typeChildren[pi]);
		pi = pi + 1;
	}
	const body = substituteAllParams(innerBase, names, args);
	// Re-wrap in Ref if the base was Ref<Struct>
	gi.typeReturn = isRefWrapped ? createRef(body) : body;
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
	_sysTypes[TypeKind.String as number].typeFlags = TypeFlag.HasAsgn;
}
initSysTypes();

export function getSysType(kind: TypeKind): Type {
	const idx = kind as number;
	if (idx >= 0 && idx < _sysTypes.length) return _sysTypes[idx];
	return createPrimitive(kind);
}

// ===== Well-Known Type Accessors =====
// Thin wrappers over getSysType for backward compatibility + readability.

export function numberType(): Type { return getSysType(TypeKind.Number); }
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
// (NIM-REF.md row 58). A new meaning gets a NEW kind — never a flag, never a
// shared singleton.
// Unknown sits past the 0..Error getSysType preallocation on purpose
// (bootstrap-stable ordinals) — this accessor returns a fresh type per call.
export function unknownType(): Type { return getSysType(TypeKind.Unknown); }

export function isUnresolvedType(t: Type | null): boolean {
	return t !== null && t.kind === TypeKind.Inferred;
}
export function isUnknownType(t: Type | null): boolean {
	return t !== null && t.kind === TypeKind.Unknown;
}
export function noneType(): Type { return getSysType(TypeKind.None); }
export function inferredType(): Type { return getSysType(TypeKind.Inferred); }
export function neverType(): Type { return getSysType(TypeKind.Never); }
export function errorType(): Type { return getSysType(TypeKind.Error); }
export function charType(): Type { return getSysType(TypeKind.Char); }
export function cstringType(): Type { return getSysType(TypeKind.CString); }
export function int32Type(): Type { return getSysType(TypeKind.Int32); }
export function float64Type(): Type { return getSysType(TypeKind.Float64); }

// StringLiteral: a specific string value as a type (TypeScript parity).
// Not a singleton — each unique value creates a new instance.
export function createStringLiteral(value: string): Type {
	const t = emptyType();
	t.kind = TypeKind.StringLiteral;
	t.typeName = value;
	return t;
}

export function isStringLiteral(t: Type | null): boolean {
	return t !== null && t.kind === TypeKind.StringLiteral;
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

export function booleanLiteralValue(t: Type | null): boolean {
	if (t === null || t.kind !== TypeKind.BooleanLiteral) return false;
	return t.typeName === "true";
}

// EnumLiteral: a specific enum member as a type (TypeScript parity).
// typeName = enum type name (e.g. "NodeKind").
// typeNames[0] = specific member (e.g. "BinaryExpr").
// typeReturn = back-reference to the underlying Enum Type for fast subtype checks.
export function createEnumLiteral(enumType: Type, memberName: string): Type {
	const t = emptyType();
	t.kind = TypeKind.EnumLiteral;
	t.typeName = enumType.typeName;
	t.typeNames = [memberName];
	t.typeReturn = enumType;
	return t;
}

export function isEnumLiteral(t: Type | null): boolean {
	return t !== null && t.kind === TypeKind.EnumLiteral;
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

// Evaluate a conditional type if its check and extends types are concrete (no GenericParam).
// Returns the true/false branch, or the original type if unevaluable.
export function evaluateConditionalType(t: Type | null): Type {
	if (t === null || t.kind !== TypeKind.Conditional) return t !== null ? t : inferredType();
	if (t.typeChildren.length < 4) return t;
	const check = t.typeChildren[0];
	const ext = t.typeChildren[1];
	// Defer if check type still has unresolved generic params (not yet substituted)
	if (hasGenericParams(check)) return t;
	// Tier 3: if the extends type has GenericParam (from `infer X`), use unifyType
	// to extract bindings, then substitute into the true branch.
	if (hasGenericParams(ext)) {
		const bindings = createUnifyBindings();
		unifyType(ext, check, bindings);
		if (bindings.names.length > 0) {
			// infer succeeded — substitute bindings into true branch
			return substituteAllParams(t.typeChildren[2], bindings.names, bindings.types);
		}
		// infer failed — no match, return false branch
		return t.typeChildren[3];
	}
	return isAssignableForConditional(check, ext) ? t.typeChildren[2] : t.typeChildren[3];
}

// Simplified assignability check for conditional type evaluation.
// Uses the main isAssignable but avoids circular dependency.
let _condAssignFn: (source: Type, target: Type) => boolean = null as unknown as (source: Type, target: Type) => boolean;
export function setConditionalAssignFn(fn: (source: Type, target: Type) => boolean): void {
	_condAssignFn = fn;
}
function isAssignableForConditional(source: Type, target: Type): boolean {
	if (_condAssignFn !== null) return _condAssignFn(source, target);
	return source.kind === target.kind;
}

export function isAllStringLiteralUnion(t: Type | null): boolean {
	if (t === null || t.kind !== TypeKind.Union) return false;
	if (t.typeChildren.length === 0) return false;
	for (const child of t.typeChildren) {
		if (child === null || child.kind !== TypeKind.StringLiteral) return false;
	}
	return true;
}

// isStringLike — true for String, StringLiteral, and Union<StringLiteral...>.
// Single source of truth: these are all msString at runtime.
export function isStringLike(t: Type | null): boolean {
	if (t === null) return false;
	if (t.kind === TypeKind.String || t.kind === TypeKind.StringLiteral) return true;
	return isAllStringLiteralUnion(t);
}

export function isFloatType(t: Type | null): boolean {
	if (t === null) return false;
	return t.kind === TypeKind.Float32 || t.kind === TypeKind.Float64;
}

// Single source of truth for what may live inside a primitive union
// (`float32 | string`): the tagged-struct lowering only knows how to carry
// these as raw C payload members.
export function isPrimitiveUnionMember(m: Type | null): boolean {
	if (m === null) return false;
	if (m.kind === TypeKind.Null || m.kind === TypeKind.String || m.kind === TypeKind.StringLiteral
		|| m.kind === TypeKind.Boolean || m.kind === TypeKind.BooleanLiteral) return true;
	return isNumeric(m);
}

// True for unions lowered to `{ _tag; union {...} }` in C. All-strlit unions
// are msString-carried (no _tag) and must never take this path.
export function isTagCarriedUnion(t: Type | null): boolean {
	if (t === null || t.kind !== TypeKind.Union) return false;
	if (t.typeChildren === null || t.typeChildren.length === 0) return false;
	return !isStringLike(t);
}

// ===== Min Arity (Default Parameters) =====
// Encoded in typeFlags bits 8-15. Zero = not set = all params required.
// Stores minArity + 1 so that 0 means "not set" (backward compatible).

export function setMinArity(t: Type | null, minArity: number): void {
	if (t === null) return;
	t.typeFlags = (t.typeFlags & 0xFF) | (((minArity as int32) + 1) << 8);
}

export function getMinArity(t: Type | null): number {
	if (t === null) return 0;
	const encoded: int32 = (t.typeFlags >> 8) & 0xFF;
	if (encoded === 0) return t.typeChildren.length;
	return (encoded - 1) as number;
}

// ===== Attached Ops Helpers (Implementation parity) =====

export function getAttachedOp(t: Type | null, op: AttachedOp): string {
	if (t === null) return "";
	const idx = op as number;
	if (t.attachedOps.length <= idx) return "";
	return t.attachedOps[idx];
}

export function setAttachedOp(t: Type | null, op: AttachedOp, name: string): void {
	if (t === null) return;
	// Grow array to fit index
	while (t.attachedOps.length <= (op as number)) {
		t.attachedOps.push("");
	}
	t.attachedOps[op as number] = name;
}

export function hasDestructor(t: Type | null): boolean {
	return getAttachedOp(t, AttachedOp.AttachedDestructor) !== "";
}

// ===== Tuple Type Name (reference parity: deterministic name for structural types) =====
// DJB2 hash of type structure → "msTuple_HASH". Same algorithm as C codegen
// (types.ms:genTupleType) so generated comparison functions match struct names.

export function tupleTypeName(t: Type | null): string {
	if (t === null || t.kind !== TypeKind.Tuple) return "";
	let key = "tuple:";
	let i = 0;
	while (i < t.typeChildren.length) {
		if (i > 0) key = key + ",";
		const child = t.typeChildren[i];
		if (child !== null) {
			key = key + typeKey(child);
		}
		i += 1;
	}
	return "msTuple_" + _stdHashToBase36(key);
}

// Structural key for tuple naming. tupleTypeName is the SINGLE source of the
// msTuple_<hash> name, so this key need only be internally stable.
function typeKey(t: Type): string {
	if (t === null) return "null";
	if (t.typeName !== "" && t.kind !== TypeKind.Tuple) return t.typeName;
	return match (t.kind) {
		TypeKind.Number => "number",
		TypeKind.String => "string",
		TypeKind.Boolean => "boolean",
		TypeKind.Void => "void",
		TypeKind.Int32 => "int32",
		TypeKind.Int64 => "int64",
		TypeKind.Uint32 => "uint32",
		TypeKind.Float32 => "float32",
		TypeKind.Float64 => "float64",
		TypeKind.BigInt => "bigint",
		TypeKind.Array => {
			return "Array(" + (t.typeReturn !== null ? typeKey(t.typeReturn) : "any") + ")";
		},
		TypeKind.Tuple => {
			let k = "tuple:";
			let i = 0;
			while (i < t.typeChildren.length) {
				if (i > 0) k = k + ",";
				k = k + typeKey(t.typeChildren[i]);
				i += 1;
			}
			return k;
		},
		TypeKind.Function => {
			let k = "fn(";
			let i = 0;
			while (i < t.typeChildren.length) {
				if (i > 0) k = k + ",";
				k = k + (t.typeChildren[i] !== null ? typeKey(t.typeChildren[i]) : "any");
				i += 1;
			}
			return k + ")_" + (t.typeReturn !== null ? typeKey(t.typeReturn) : "void");
		},
		TypeKind.Union => {
			let k = "union(";
			let i = 0;
			while (i < t.typeChildren.length) {
				if (i > 0) k = k + "|";
				k = k + (t.typeChildren[i] !== null ? typeKey(t.typeChildren[i]) : "null");
				i += 1;
			}
			return k + ")";
		},
		TypeKind.Span => {
			return "Span(" + (t.typeReturn !== null ? typeKey(t.typeReturn) : "any") + ")";
		},
		TypeKind.SizedArray => {
			return "SizedArray" + t.typeFlags.toString() + "(" + (t.typeReturn !== null ? typeKey(t.typeReturn) : "any") + ")";
		},
		_ => t.kind.toString(),
	};
}

// ===== Type Classification Helpers =====

export function isStructType(t: Type | null): boolean {
	if (t === null) return false;
	if (t.kind === TypeKind.Alias) return isStructType(t.typeReturn);
	if (t.kind !== TypeKind.Struct) return false;
	return (t.typeFlags & TypeFlag.IsStruct) !== 0;
}

export function isMaybeType(t: Type | null): boolean {
	if (t === null) return false;
	return (t.typeFlags & TypeFlag.IsMaybe) !== 0;
}

// Whether `t | null` should wrap into Maybe<T> at the resolver. Pointers
// (Ref/Ptr) stay as Union — codegen unwraps to a bare pointer using NULL
// as the natural sentinel. Null itself is degenerate. Everything else
// (struct, primitive, string, function) needs the `{ value, present }` wrapper
// because there is no spare bit pattern for "absent". Mirrors Nim's
// SomePointer-vs-value-type split (~/projects/nim/lib/pure/options.nim:90-99).
export function isMaybeWrappable(t: Type | null): boolean {
	if (t === null) return false;
	if (t.kind === TypeKind.Null) return false;
	if (t.kind === TypeKind.Ref || t.kind === TypeKind.Ptr) return false;
	// unknown is void* in C — pointer branch of the SomePointer split, same as Ref/Ptr
	if (t.kind === TypeKind.Unknown) return false;
	if (t.kind === TypeKind.Function) return true;
	if (isStructType(t)) return true;
	if (isPrimitiveKind(t.kind)) return true;
	if (t.kind === TypeKind.String) return true;
	if (t.kind === TypeKind.StringLiteral) return true;
	if (isAllStringLiteralUnion(t)) return true;
	return false;
}

export function unwrapMaybeType(t: Type): Type {
	const inner = t.typeReturn;
	return inner !== null ? inner : t;
}

// C-repr query for `unknown` (void*) interop: kinds already living in a
// pointer-sized slot. Value-shaped kinds (string/struct/closure/numeric) have
// no lossless void* form — implicit flows and reinterpret casts must error
// (Nim parity: typeRel tyPointer accepts only nil/ptr/proc/cstring —
// sigmatch.nim:1602). GenericParam/Error/Never defer to instantiation recheck.
export function isPointerShapedForUnknown(t: Type | null): boolean {
	if (t === null) return true;
	const inner = skipModifier(t);
	if (inner === null) return true;
	if (inner.kind === TypeKind.Union) return unwrapRefNullUnion(inner) !== null;
	return match (inner.kind) {
		TypeKind.Unknown | TypeKind.Null | TypeKind.Ref | TypeKind.Ptr | TypeKind.Borrow
			| TypeKind.CString | TypeKind.GenericParam | TypeKind.Error | TypeKind.Never => true,
		TypeKind.None | TypeKind.Inferred => false,
		_ => false,
	};
}

// unwrapRef — unwrap Ref<T> or Ptr<T> to get inner type (reference: skip pointer types).
// Caller passes a non-null Type (or pre-narrowed value); typeReturn for Ref/Ptr
// is guaranteed non-null by createRef/createPtr, so the result is non-null.
export function unwrapRef(t: Type): Type {
	if (t.kind === TypeKind.Ref || t.kind === TypeKind.Ptr) {
		const inner = t.typeReturn;
		if (inner !== null) return inner;
	}
	return t;
}

// If t is Union(Ref<T>, Null), Union(Ptr<T>, Null) or Union(unknown, Null),
// return the pointer-shaped member. Otherwise return null. Used by codegen to
// collapse nullable-pointer unions to bare pointer types (the null pointer is
// the natural sentinel — no Maybe wrapper needed).
export function unwrapRefNullUnion(t: Type): Type | null {
	if (t === null || t.kind !== TypeKind.Union) return null;
	if (t.typeChildren === null || t.typeChildren.length !== 2) return null;
	const a = t.typeChildren[0];
	const b = t.typeChildren[1];
	if (a === null || b === null) return null;
	if ((a.kind === TypeKind.Ref || a.kind === TypeKind.Ptr || a.kind === TypeKind.Unknown) && b.kind === TypeKind.Null) return a;
	if ((b.kind === TypeKind.Ref || b.kind === TypeKind.Ptr || b.kind === TypeKind.Unknown) && a.kind === TypeKind.Null) return b;
	return null;
}

// ===== Needs RC =====
// Types that need reference counting. Pure type query — no codegen dependency.

export function needsRC(t: Type | null): boolean {
	if (t === null) return false;
	return match (t.kind) {
		TypeKind.String => true,
		TypeKind.Array => true,
		TypeKind.SizedArray => needsRC(t.typeReturn),
		TypeKind.Span => false,
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

export function hasAsgnFlag(t: Type): boolean {
	if (t === null) return false;
	return (t.typeFlags & TypeFlag.HasAsgn) !== 0;
}

// Does an array element of this type need per-element cleanup — i.e. a per-type
// <Name>ArrayDestroy walker that runs each element's destructor — vs a free-only buffer
// wipe? Single source of truth for the destroyFn selection (codegen box site) AND
// destructorLifting's walker emission; both must agree or a managed element leaks (false
// → free-only) or a walker that was never emitted is referenced (true → link error).
// Mirrors classifyArray's needs-cleanup decision. Tuple elements return false here pending
// their per-type walker emission (tuple-literal codegen).
export function arrayElementNeedsCleanup(elem: Type): boolean {
	if (elem === null) return false;
	if (elem.kind === TypeKind.String || elem.kind === TypeKind.Ref
		|| elem.kind === TypeKind.Ptr || elem.kind === TypeKind.Function
		|| elem.kind === TypeKind.BigInt) return true;
	if (elem.kind === TypeKind.Distinct && elem.typeReturn !== null) {
		return arrayElementNeedsCleanup(elem.typeReturn);
	}
	// Nested value array (Vec<T>[]): the element owns heap (its own buffer + its elements'
	// heap), so the box-site must pick the per-type <Name>ArrayDestroy walker — never the
	// free-only fallback (else every inner buffer leaks).
	if (elem.kind === TypeKind.Array) return true;
	if (elem.kind === TypeKind.Tuple) {
		for (const child of elem.typeChildren) {
			if (arrayElementNeedsCleanup(child)) return true;
		}
		return false;
	}
	let structElem = elem;
	if (elem.kind === TypeKind.GenericInstance && elem.typeExtra !== null && elem.typeExtra.kind === TypeKind.Struct) {
		structElem = elem.typeExtra;
	}
	if ((structElem.kind === TypeKind.Struct || structElem.kind === TypeKind.Union) && structElem.typeName !== "") {
		const bodyAsgn = elem.kind === TypeKind.GenericInstance && elem.typeReturn !== null && hasAsgnFlag(elem.typeReturn);
		return hasAsgnFlag(structElem) || bodyAsgn;
	}
	return false;
}

export function propagateToOwner(parent: Type, child: Type): void {
	if (child !== null && (child.typeFlags & TypeFlag.HasAsgn) !== 0) {
		parent.typeFlags = parent.typeFlags | TypeFlag.HasAsgn;
	}
}

// ===== Ownership Modifiers =====
// TypeKind.Sink/Lent have no producer since sink inference was removed (ea38c2a);
// the see-through arms stay for a future explicit `sink T`. skipModifier also
// unwraps Var, which is still constructed.

export function skipModifier(t: Type | null): Type | null {
	if (t === null) return t;
	if (t.kind === TypeKind.Sink || t.kind === TypeKind.Lent || t.kind === TypeKind.Var) return t.typeReturn;
	if (t.kind === TypeKind.Cursor) return t.typeReturn;
	if (t.kind === TypeKind.Alias) return t.typeReturn;
	return t;
}

// ===== Type Size Estimation (Reference: reference codegen utils parity) =====
// Returns estimated C struct size in bytes for reference pointer introduction threshold.
// Reference: size threshold = 24 bytes on 64-bit. Objects/tuples larger than this → pass by pointer.
let _sizeDepth: number = 0;

export function getTypeSize(t: Type): number {
	if (t === null) return 0;
	// Guard against recursive types (e.g. Type has Type[] fields)
	if (_sizeDepth > 8) return 64; // assume large → pass by pointer
	_sizeDepth = _sizeDepth + 1;
	const result = getTypeSizeInner(t);
	_sizeDepth = _sizeDepth - 1;
	return result;
}

function getTypeSizeInner(t: Type): number {
	return match (t.kind) {
		TypeKind.Number | TypeKind.Float32 | TypeKind.Float64 => 8,
		TypeKind.Int8 | TypeKind.Uint8 => 1,
		TypeKind.Int16 | TypeKind.Uint16 => 2,
		TypeKind.Int32 | TypeKind.Uint32 | TypeKind.Char => 4,
		TypeKind.Int64 | TypeKind.Uint64 => 8,
		TypeKind.Boolean => 1,
		TypeKind.String | TypeKind.StringLiteral => targetPtrSize + targetPtrSize, // msString: data ptr + length
		TypeKind.CString => targetPtrSize,
		TypeKind.Enum | TypeKind.EnumLiteral => 4, // C int
		TypeKind.Ref | TypeKind.Ptr | TypeKind.Borrow => targetPtrSize,
		TypeKind.Array => targetPtrSize + targetPtrSize, // msArray: data ptr + length
		TypeKind.Function => targetPtrSize + targetPtrSize, // msClosure: fn ptr + env ptr
		TypeKind.Struct => {
			// Sum of field sizes
			if (t.typeChildren === null) { return targetPtrSize; } else {
				let size = 0;
				for (const field of t.typeChildren) {
					size = size + getTypeSize(field);
				}
				return size;
			}
		},
		TypeKind.Tuple => {
			if (t.typeChildren === null) { return 0; } else {
				let size = 0;
				for (const elem of t.typeChildren) {
					size = size + getTypeSize(elem);
				}
				return size;
			}
		},
		TypeKind.Union => {
			// Union(Ref<T>, Null) collapses to bare T* in codegen (via unwrapRefNullUnion in
			// getTypeDesc). Size must match the C representation — not the abstract
			// tagged-union math — otherwise shouldIndirectParam misjudges struct fields
			// containing `T | null` (sees them as larger than they actually are in C).
			if (unwrapRefNullUnion(t) !== null) return targetPtrSize;
			// tag + max(member sizes)
			let maxSize = 0;
			if (t.typeChildren !== null) {
				for (const member of t.typeChildren) {
					const ms = getTypeSize(member);
					if (ms > maxSize) maxSize = ms;
				}
			}
			return 4 + maxSize;
		},
		TypeKind.Span => targetPtrSize + targetPtrSize, // ptr + length
		_ => targetPtrSize, // conservative fallback
	};
}

// ===== Generic Instantiation =====

// Substitute a generic parameter name with a concrete type throughout a type tree.
// Returns a new Type (does not mutate original).
function substituteStruct(t: Type, paramName: string, concrete: Type): Type {
	const newFieldTypes: Type[] = [];
	let changed = false;
	for (let ci = 0; ci < t.typeChildren.length; ci += 1) {
		const sub = substituteType(t.typeChildren[ci], paramName, concrete);
		newFieldTypes.push(sub);
		if (sub !== t.typeChildren[ci]) changed = true;
	}
	if (!changed) return t;
	// Rebuild via createMaybeType: it stamps IsMaybe + derives the substituted name.
	// createStruct drops IsMaybe → isMaybeType fails downstream (operatorLower, nullableLower).
	if ((t.typeFlags & TypeFlag.IsMaybe) !== 0) {
		return createMaybeType(newFieldTypes[0]);
	}
	const newNames: string[] = [];
	for (let ni = 0; ni < t.typeNames.length; ni += 1) {
		newNames.push(t.typeNames[ni]);
	}
	const result = createStruct(t.typeName, newNames, newFieldTypes, isStructType(t));
	result.typeReturn = t.typeReturn;
	result.typeExtra = t.typeExtra;
	// createStruct recomputes HasAsgn from substituted children; DuVariant is an
	// identity bit (set at createUnion) that must survive the rebuild or mono'd
	// generic-union payloads lose their DU ownership marker.
	const withDu: int32 = result.typeFlags | (t.typeFlags & (TypeFlag.DuVariant as int32));
	result.typeFlags = withDu;
	return result;
}

// Reference parity (instCopyType → newSons + dest[i] = src[i]):
// Copy type with independent arrays. Children copied via push(null) + indexed
// assignment so DRC generates =copy (incref) in C. JS gets independence from push.
function copyTypeForSubst(t: Type): Type {
	const result = emptyType();
	result.kind = t.kind;
	result.typeName = t.typeName;
	result.typeReturn = t.typeReturn;
	result.typeExtra = t.typeExtra;
	result.typeFlags = t.typeFlags - TypeFlag.Substituting;
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
		result.attachedOps.push("");
		result.attachedOps[oi] = t.attachedOps[oi];
	}
	return result;
}

// In-place substitute all children of a copied type.
function substituteChildrenInPlace(copy: Type, paramName: string, concrete: Type): void {
	for (let ci = 0; ci < copy.typeChildren.length; ci += 1) {
		copy.typeChildren[ci] = substituteType(copy.typeChildren[ci], paramName, concrete);
	}
}

// Cycle detection: flag on the Type itself.
// Reference parity: uses localCache (hash table). We use a flag bit — same principle
// (identity-based, no incref/decref on tracked types). O(1) check vs O(n) linear scan.
// Cannot use Type[] stack — DRC push/pop/decref frees rc=0 types (fatal in C binary).
function substituteIsSeen(t: Type): boolean {
	return (t.typeFlags & TypeFlag.Substituting) !== 0;
}

function substituteSetFlag(t: Type): void {
	t.typeFlags = t.typeFlags | TypeFlag.Substituting;
}

function substituteClearFlag(t: Type): void {
	if ((t.typeFlags & TypeFlag.Substituting) !== 0) {
		t.typeFlags = t.typeFlags - TypeFlag.Substituting;
	}
}

let _substCount: float64 = 0;
let _substTime: float64 = 0;
export function substituteTypeProfile(): float64[] { return [_substCount, _substTime]; }
export function substituteType(t: Type | null, paramName: string, concrete: Type): Type {
	_substCount = _substCount + 1;
	const _s0 = performance.now();
	const r = substituteTypeInner(t, paramName, concrete);
	_substTime = _substTime + (performance.now() - _s0);
	return r;
}
function substituteTypeInner(t: Type | null, paramName: string, concrete: Type): Type {
	if (t === null) return inferredType();
	if (t.kind === TypeKind.GenericParam && t.typeName === paramName) return concrete;
	if (substituteIsSeen(t)) return t;
	substituteSetFlag(t);
	const result = match (t.kind) {
			TypeKind.Number | TypeKind.String | TypeKind.Boolean |
			TypeKind.Void | TypeKind.Null | TypeKind.Unknown |
			TypeKind.Never | TypeKind.Error | TypeKind.None | TypeKind.Inferred |
			TypeKind.GenericParam | TypeKind.CString => t,
			TypeKind.Array => createArray(substituteType(t.typeReturn, paramName, concrete)),
			TypeKind.SizedArray => createSizedArray(substituteType(t.typeReturn, paramName, concrete), t.typeFlags - TypeFlag.Substituting),
			TypeKind.Span => createSpan(substituteType(t.typeReturn, paramName, concrete)),
			TypeKind.Varargs => t.typeChildren.length > 0
				? createVarargs(substituteType(t.typeChildren[0], paramName, concrete))
				: t,
			TypeKind.Function => {
				const fn = copyTypeForSubst(t);
				substituteChildrenInPlace(fn, paramName, concrete);
				fn.typeReturn = substituteType(t.typeReturn, paramName, concrete);
				substituteClearFlag(t);
				return fn;
			},
			TypeKind.Union | TypeKind.Tuple => {
				const copy = copyTypeForSubst(t);
				substituteChildrenInPlace(copy, paramName, concrete);
				substituteClearFlag(t);
				// Re-canonicalize `T | null` after substitution: when T resolves to a
				// value-type, collapse Union<T, Null> → Maybe<T>. Mirrors the path
				// in resolvePass.ms:260-266 that canonicalizes user-written
				// annotations. At decl time, T is a GenericParam (not Maybe-wrappable)
				// so the original Union<GP, Null> stays uncanonical; at substitute time
				// T is concrete and we can pick the right shape.
				if (t.kind === TypeKind.Union && copy.typeChildren.length === 2) {
					const a = copy.typeChildren[0];
					const b = copy.typeChildren[1];
					if (a !== null && b !== null) {
						if (b.kind === TypeKind.Null && isMaybeWrappable(a)) return createMaybeType(a);
						if (a.kind === TypeKind.Null && isMaybeWrappable(b)) return createMaybeType(b);
					}
				}
				return copy;
			},
			TypeKind.Ref => isAtomicRef(t)
				? createArc(substituteType(t.typeReturn, paramName, concrete))
				: createRef(substituteType(t.typeReturn, paramName, concrete)),
			TypeKind.Ptr => createPtr(substituteType(t.typeReturn, paramName, concrete)),
			TypeKind.Borrow => createBorrow(substituteType(t.typeReturn, paramName, concrete)),
			TypeKind.Struct => substituteStruct(t, paramName, concrete),
			TypeKind.GenericInstance => {
				// Substitute typeChildren and typeReturn (the instantiated body
				// produced by instantiateGenericBody). typeExtra (the
				// un-instantiated base) is intentionally NOT walked here — that
				// would cost ~20× compile time on self-host. Bug 16's narrowing
				// leak is fixed at the read site instead: callers like
				// inferGenericReturnWithExplicit + peelToStructOrUnion populate
				// typeReturn lazily via instantiateGenericBody, which now has
				// param-name entries for built-in Result/Promise/Iterator
				// (see parser/context.ms `getGenericDecl` fallbacks).
				const gi = copyTypeForSubst(t);
				substituteChildrenInPlace(gi, paramName, concrete);
				if (gi.typeReturn !== null) {
					gi.typeReturn = substituteType(gi.typeReturn, paramName, concrete);
				}
				substituteClearFlag(t);
				return gi;
			},
			TypeKind.Conditional => {
				// Substitute in all 4 children, then try to evaluate
				const cond = copyTypeForSubst(t);
				substituteChildrenInPlace(cond, paramName, concrete);
				substituteClearFlag(t);
				return evaluateConditionalType(cond);
			},
			_ => t,
		};
	substituteClearFlag(t);
	return result;
}

// Multi-binding substitution in ONE tree walk. Semantically identical to
// folding substituteType over each (name, concrete) pair — the concrete types
// are fully resolved (no free GenericParams) by contract at every call site,
// so simultaneous substitution equals sequential passes — but the tree is
// walked once instead of once per binding. inferGenericReturn folds bindings
// per call site; on self-host that was 21M single-param node walks (~56s).
export function substituteAllParams(t: Type | null, names: string[], concretes: Type[]): Type {
	if (t === null) return inferredType();
	if (t.kind === TypeKind.GenericParam) {
		for (let ni = 0; ni < names.length; ni += 1) {
			if (t.typeName === names[ni]) return concretes[ni];
		}
		return t;
	}
	if (substituteIsSeen(t)) return t;
	substituteSetFlag(t);
	const result = match (t.kind) {
			TypeKind.Number | TypeKind.String | TypeKind.Boolean |
			TypeKind.Void | TypeKind.Null | TypeKind.Unknown |
			TypeKind.Never | TypeKind.Error | TypeKind.None | TypeKind.Inferred |
			TypeKind.GenericParam | TypeKind.CString => t,
			TypeKind.Array => createArray(substituteAllParams(t.typeReturn, names, concretes)),
			TypeKind.SizedArray => createSizedArray(substituteAllParams(t.typeReturn, names, concretes), t.typeFlags - TypeFlag.Substituting),
			TypeKind.Span => createSpan(substituteAllParams(t.typeReturn, names, concretes)),
			TypeKind.Varargs => t.typeChildren.length > 0
				? createVarargs(substituteAllParams(t.typeChildren[0], names, concretes))
				: t,
			TypeKind.Function => {
				const fn = copyTypeForSubst(t);
				substituteChildrenInPlaceAll(fn, names, concretes);
				fn.typeReturn = substituteAllParams(t.typeReturn, names, concretes);
				substituteClearFlag(t);
				return fn;
			},
			TypeKind.Union | TypeKind.Tuple => {
				const copy = copyTypeForSubst(t);
				substituteChildrenInPlaceAll(copy, names, concretes);
				substituteClearFlag(t);
				// Re-canonicalize `T | null` after substitution (same rule as
				// substituteTypeInner): collapse Union<T, Null> → Maybe<T> when
				// the substituted member became a wrappable value-type.
				if (t.kind === TypeKind.Union && copy.typeChildren.length === 2) {
					const a = copy.typeChildren[0];
					const b = copy.typeChildren[1];
					if (a !== null && b !== null) {
						if (b.kind === TypeKind.Null && isMaybeWrappable(a)) return createMaybeType(a);
						if (a.kind === TypeKind.Null && isMaybeWrappable(b)) return createMaybeType(b);
					}
				}
				return copy;
			},
			TypeKind.Ref => isAtomicRef(t)
				? createArc(substituteAllParams(t.typeReturn, names, concretes))
				: createRef(substituteAllParams(t.typeReturn, names, concretes)),
			TypeKind.Ptr => createPtr(substituteAllParams(t.typeReturn, names, concretes)),
			TypeKind.Borrow => createBorrow(substituteAllParams(t.typeReturn, names, concretes)),
			TypeKind.Struct => substituteStructAll(t, names, concretes),
			TypeKind.GenericInstance => {
				// typeExtra intentionally NOT walked — same rationale as
				// substituteTypeInner (walking it cost ~20× compile time).
				const gi = copyTypeForSubst(t);
				substituteChildrenInPlaceAll(gi, names, concretes);
				if (gi.typeReturn !== null) {
					gi.typeReturn = substituteAllParams(gi.typeReturn, names, concretes);
				}
				substituteClearFlag(t);
				return gi;
			},
			TypeKind.Conditional => {
				const cond = copyTypeForSubst(t);
				substituteChildrenInPlaceAll(cond, names, concretes);
				substituteClearFlag(t);
				return evaluateConditionalType(cond);
			},
			_ => t,
		};
	substituteClearFlag(t);
	return result;
}

function substituteChildrenInPlaceAll(copy: Type, names: string[], concretes: Type[]): void {
	for (let ci = 0; ci < copy.typeChildren.length; ci += 1) {
		copy.typeChildren[ci] = substituteAllParams(copy.typeChildren[ci], names, concretes);
	}
}

function substituteStructAll(t: Type, names: string[], concretes: Type[]): Type {
	const newFieldTypes: Type[] = [];
	let changed = false;
	for (let ci = 0; ci < t.typeChildren.length; ci += 1) {
		const sub = substituteAllParams(t.typeChildren[ci], names, concretes);
		newFieldTypes.push(sub);
		if (sub !== t.typeChildren[ci]) changed = true;
	}
	if (!changed) return t;
	if ((t.typeFlags & TypeFlag.IsMaybe) !== 0) {
		return createMaybeType(newFieldTypes[0]);
	}
	const newNames: string[] = [];
	for (let ni = 0; ni < t.typeNames.length; ni += 1) {
		newNames.push(t.typeNames[ni]);
	}
	const result = createStruct(t.typeName, newNames, newFieldTypes, isStructType(t));
	result.typeReturn = t.typeReturn;
	result.typeExtra = t.typeExtra;
	const withDu: int32 = result.typeFlags | (t.typeFlags & (TypeFlag.DuVariant as int32));
	result.typeFlags = withDu;
	return result;
}

// Instantiate a generic type with concrete type arguments.
export function instantiateGeneric(t: Type, genericParamNames: string[], typeArgs: Type[]): Type {
	const limit = genericParamNames.length < typeArgs.length ? genericParamNames.length : typeArgs.length;
	if (limit === 0) return t;
	const names: string[] = [];
	const args: Type[] = [];
	for (let i = 0; i < limit; i += 1) {
		names.push(genericParamNames[i]);
		args.push(typeArgs[i]);
	}
	return substituteAllParams(t, names, args);
}

// ===== Type Unification =====
// Recursively match formal (may contain GenericParam) against concrete (always resolved).
// Extracts bindings into UnifyBindings (parallel arrays: names + types).

export interface UnifyBindings {
	names: string[];
	types: Type[];
}

export function createUnifyBindings(): UnifyBindings {
	return { names: [], types: [] };
}

// Merge `from` into `into`, skipping any name already present. Stable union:
// arg-driven bindings keep priority, explicit-type-arg bindings fill gaps.
export function mergeUnifyBindings(into: UnifyBindings, from: UnifyBindings): void {
	for (let i = 0; i < from.names.length; i += 1) {
		let alreadyBound = false;
		for (const existing of into.names) {
			if (existing === from.names[i]) { alreadyBound = true; break; }
		}
		if (!alreadyBound) {
			into.names.push(from.names[i]);
			into.types.push(from.types[i]);
		}
	}
}

let unifyDepth = 0;

let _unifyCount: float64 = 0;
let _unifyTime: float64 = 0;
export function unifyTypeProfile(): float64[] { return [_unifyCount, _unifyTime]; }
export function unifyType(formal: Type | null, concrete: Type | null, bindings: UnifyBindings): void {
	_unifyCount = _unifyCount + 1;
	const _u0 = performance.now();
	unifyTypeGuard(formal, concrete, bindings);
	_unifyTime = _unifyTime + (performance.now() - _u0);
}
function unifyTypeGuard(formal: Type | null, concrete: Type | null, bindings: UnifyBindings): void {
	if (formal === null || concrete === null) return;
	// Identity check — break circular type references (e.g., Doc → DocData → Doc)
	if (formal === concrete) return;
	// Depth guard — prevent infinite recursion on recursive types (e.g., JsonValue contains JsonValue[])
	if (unifyDepth > 20) return;
	unifyDepth = unifyDepth + 1;
	unifyTypeInner(formal, concrete, bindings);
	unifyDepth = unifyDepth - 1;
}

function unifyTypeInner(formal: Type | null, concrete: Type | null, bindings: UnifyBindings): void {
	if (formal === null) return;
	if (concrete === null) return;
	// Direct generic param match
	if (formal.kind === TypeKind.GenericParam) {
		bindings.names.push(formal.typeName);
		bindings.types.push(concrete);
		return;
	}
	// Array/Span/Ref/Ptr: unify element types
	if (formal.kind === concrete.kind
		&& (formal.kind === TypeKind.Array || formal.kind === TypeKind.SizedArray
			|| formal.kind === TypeKind.Span || formal.kind === TypeKind.Ref || formal.kind === TypeKind.Ptr)) {
		if (formal.typeReturn !== null && concrete.typeReturn !== null) {
			unifyType(formal.typeReturn, concrete.typeReturn, bindings);
		}
		return;
	}
	// GenericInstance: structural unification of type arguments
	// HashMap<K,V> (formal, with GenericParam children) vs HashMap<string,string> (concrete)
	// Base type must match: HashMap<K,V> unifies with HashMap<string,string> but NOT HashSet<string>
	if (formal.kind === TypeKind.GenericInstance && concrete.kind === TypeKind.GenericInstance) {
		// Affine and plain Promises share typeName "Promise" — their distinction
		// is in flag bits, not in the name. Simple equality covers both.
		const namesMatch = formal.typeName === concrete.typeName;
		if (!namesMatch) return;
		const limit = formal.typeChildren.length < concrete.typeChildren.length ? formal.typeChildren.length : concrete.typeChildren.length;
		for (let gi = 0; gi < limit; gi += 1) {
			unifyType(formal.typeChildren[gi], concrete.typeChildren[gi], bindings);
		}
		return;
	}
	// GenericInstance vs Struct (either direction) — try base type matching
	if (formal.kind === TypeKind.GenericInstance && concrete.kind === TypeKind.Struct) {
		if (formal.typeExtra !== null) {
			unifyType(formal.typeExtra, concrete, bindings);
		}
		return;
	}
	if (formal.kind === TypeKind.Struct && concrete.kind === TypeKind.GenericInstance) {
		// Struct("Map") with generic params vs GenericInstance("Map", [string, string])
		// Unify by matching formal's fields against the instantiated body's fields
		if (formal.typeName === concrete.typeName && concrete.typeReturn !== null) {
			const body = unwrapRef(concrete.typeReturn);
			if (body.kind === TypeKind.Struct) {
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
	if (formal.kind === TypeKind.Union && concrete.kind === TypeKind.Struct
			&& isMaybeType(concrete) && concrete.typeReturn !== null
			&& formal.typeChildren.length === 2) {
		const fa = formal.typeChildren[0];
		const fb = formal.typeChildren[1];
		if (fa !== null && fb !== null) {
			if (fb.kind === TypeKind.Null) { unifyType(fa, concrete.typeReturn, bindings); return; }
			if (fa.kind === TypeKind.Null) { unifyType(fb, concrete.typeReturn, bindings); return; }
		}
	}
	if (formal.kind === TypeKind.Struct && concrete.kind === TypeKind.Union
			&& isMaybeType(formal) && formal.typeReturn !== null
			&& concrete.typeChildren.length === 2) {
		const ca = concrete.typeChildren[0];
		const cb = concrete.typeChildren[1];
		if (ca !== null && cb !== null) {
			if (cb.kind === TypeKind.Null) { unifyType(formal.typeReturn, ca, bindings); return; }
			if (ca.kind === TypeKind.Null) { unifyType(formal.typeReturn, cb, bindings); return; }
		}
	}
	// Structural match — same kind, recurse into children
	if (formal.kind !== concrete.kind) return;
	if (formal.kind === TypeKind.Array || formal.kind === TypeKind.SizedArray || formal.kind === TypeKind.Span) {
		unifyType(formal.typeReturn, concrete.typeReturn, bindings);
		return;
	}
	// Result and Promise are now GenericInstance — handled above
	if (formal.kind === TypeKind.Function) {
		const fnLimit = formal.typeChildren.length < concrete.typeChildren.length ? formal.typeChildren.length : concrete.typeChildren.length;
		for (let i = 0; i < fnLimit; i += 1) {
			unifyType(formal.typeChildren[i], concrete.typeChildren[i], bindings);
		}
		unifyType(formal.typeReturn, concrete.typeReturn, bindings);
		return;
	}
	if (formal.kind === TypeKind.Ref || formal.kind === TypeKind.Ptr) {
		unifyType(formal.typeReturn, concrete.typeReturn, bindings);
		return;
	}
	if (formal.kind === TypeKind.Union || formal.kind === TypeKind.Struct) {
		// Structs with field names on both sides unify BY NAME: an object literal's
		// key order is the writer's choice (JSX attr order, etc.) and need not match
		// the formal's declaration order — positional pairing would silently bind
		// generic params against the wrong field's type.
		if (formal.kind === TypeKind.Struct
				&& formal.typeNames.length > 0 && concrete.typeNames.length > 0) {
			const fLimit = formal.typeNames.length < formal.typeChildren.length ? formal.typeNames.length : formal.typeChildren.length;
			const cLimit = concrete.typeNames.length < concrete.typeChildren.length ? concrete.typeNames.length : concrete.typeChildren.length;
			for (let i = 0; i < fLimit; i += 1) {
				for (let j = 0; j < cLimit; j += 1) {
					if (concrete.typeNames[j] === formal.typeNames[i]) {
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

// Cycle-safe: named Object/Union types don't contain GenericParams after resolution
let _hasGenericDepth = 0;
export function hasGenericParams(t: Type | null): boolean {
	if (t === null) return false;
	if (t.kind === TypeKind.GenericParam) return true;
	if (_hasGenericDepth > 20) return false;
	_hasGenericDepth = _hasGenericDepth + 1;
	const result = hasGenericParamsInner(t);
	_hasGenericDepth = _hasGenericDepth - 1;
	return result;
}

function hasGenericParamsInner(t: Type): boolean {
	// GenericInstance: check type args for GenericParam (e.g., HashMap<K,V> has GenericParam children)
	if (t.kind === TypeKind.GenericInstance) {
		for (let gi = 0; gi < t.typeChildren.length; gi += 1) {
			if (hasGenericParams(t.typeChildren[gi])) return true;
		}
		return false;
	}
	// Named types can't contain GenericParams (they're resolved) — skip to avoid cycles
	if ((t.kind === TypeKind.Struct || t.kind === TypeKind.Union) && t.typeName !== "") return false;
	if (t.typeReturn !== null && hasGenericParams(t.typeReturn)) return true;
	if (t.typeExtra !== null && hasGenericParams(t.typeExtra)) return true;
	for (let i = 0; i < t.typeChildren.length; i += 1) {
		if (hasGenericParams(t.typeChildren[i])) return true;
	}
	return false;
}

// ===== Type Query Helpers =====

export function isNumeric(t: Type | null): boolean {
	if (t === null) return false;
	return t.kind === TypeKind.Number || t.kind === TypeKind.Int8 ||
		t.kind === TypeKind.Int16 || t.kind === TypeKind.Int32 ||
		t.kind === TypeKind.Int64 || t.kind === TypeKind.Uint8 ||
		t.kind === TypeKind.Uint16 || t.kind === TypeKind.Uint32 ||
		t.kind === TypeKind.Uint64 || t.kind === TypeKind.Float32 ||
		t.kind === TypeKind.Float64 || t.kind === TypeKind.Char;
}

export function isIntegerType(t: Type | null): boolean {
	if (t === null) return false;
	return t.kind === TypeKind.Int8 || t.kind === TypeKind.Int16 ||
		t.kind === TypeKind.Int32 || t.kind === TypeKind.Int64 ||
		t.kind === TypeKind.Uint8 || t.kind === TypeKind.Uint16 ||
		t.kind === TypeKind.Uint32 || t.kind === TypeKind.Uint64;
}

// Integers a double cannot round-trip: everything up to 32 bits fits exactly in
// the 53-bit mantissa, 64-bit types do not.
export function isWideInteger(t: Type | null): boolean {
	if (t === null) return false;
	return t.kind === TypeKind.Int64 || t.kind === TypeKind.Uint64;
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
	if (!isIntegerType(source) && source.kind !== TypeKind.Number && source.kind !== TypeKind.Float64) return false;
	return integerRank(source) > integerRank(target);
}

// Widening into a 64-bit slot also carries a HiddenStdConv: the JS BigInt
// representation needs the boundary marked, and C emits it as a no-op cast.
export function isWideningInt64Conv(source: Type, target: Type): boolean {
	if (target.kind !== TypeKind.Int64 && target.kind !== TypeKind.Uint64) return false;
	if (!isIntegerType(source)) return false;
	return integerRank(source) < integerRank(target);
}


export function isBoolType(t: Type): boolean {
	return t.kind === TypeKind.Boolean;
}

export function isCallable(t: Type): boolean {
	return t.kind === TypeKind.Function;
}

export function getReturnType(t: Type): Type {
	if (t.kind === TypeKind.Function) {
		const ret = t.typeReturn;
		return ret !== null ? ret : inferredType();
	}
	return inferredType();
}

export function getElementType(t: Type): Type {
	if (t.kind === TypeKind.Array || t.kind === TypeKind.SizedArray || t.kind === TypeKind.Span || t.kind === TypeKind.Ptr) {
		const elem = t.typeReturn;
		return elem !== null ? elem : inferredType();
	}
	// @builtin("IndexableMap") subscript: `m[k]` returns V. Makes `{ [key: K]: V }`
	// work at runtime via .get() after the lowering in transform/native/nativeLower.ms.
	if (t.kind === TypeKind.GenericInstance && isIndexableMapType(t)
		&& t.typeChildren !== null && t.typeChildren.length === 2) {
		return t.typeChildren[1];
	}
	return inferredType();
}

// Collect unique GenericParam names from a type tree (used by getProperty for GenericInstance substitution)
let _collectGenericDepth = 0;
function collectGenericParamNames(t: Type | null, names: string[]): void {
	if (t === null) return;
	if (t === null) return;
	if (_collectGenericDepth > 20) return;
	if (t.kind === TypeKind.GenericParam) {
		let dup = false;
		let ni = 0;
		while (ni < names.length) { if (names[ni] === t.typeName) { dup = true; } ni = ni + 1; }
		if (!dup) names.push(t.typeName);
		return;
	}
	_collectGenericDepth = _collectGenericDepth + 1;
	if (t.typeReturn !== null) collectGenericParamNames(t.typeReturn, names);
	if (t.typeExtra !== null) collectGenericParamNames(t.typeExtra, names);
	let ci = 0;
	while (ci < t.typeChildren.length) {
		collectGenericParamNames(t.typeChildren[ci], names);
		ci = ci + 1;
	}
	_collectGenericDepth = _collectGenericDepth - 1;
}

let _gpCount: float64 = 0;
let _gpTime: float64 = 0;
export function getPropertyProfile(): float64[] { return [_gpCount, _gpTime]; }
export function getProperty(t: Type | null, name: string): Type {
	_gpCount = _gpCount + 1;
	const _g0 = performance.now();
	const r = getPropertyInner(t, name);
	_gpTime = _gpTime + (performance.now() - _g0);
	return r;
}
function getPropertyInner(t: Type | null, name: string): Type {
	if (t === null) return inferredType();
	// Unwrap Ref/Ptr to access inner Object's properties (class types are Ref<Object>)
	if (t.kind === TypeKind.Ref || t.kind === TypeKind.Ptr) {
		if (t.typeReturn !== null) return getProperty(t.typeReturn, name);
	}
	if (t.kind === TypeKind.Struct) {
		let i = 0;
		for (const propName of t.typeNames) {
			if (propName === name) {
				if (i < t.typeChildren.length) {
					const found = t.typeChildren[i];
					if (found === null) return inferredType();
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
	if (t.kind === TypeKind.GenericInstance) {
		// Primary: eagerly instantiated body (typeReturn) — fully concrete
		if (t.typeReturn !== null) {
			return getProperty(t.typeReturn, name);
		}
		// Fallback: lazy substitution for GenericInstances without instantiated body
		if (t.typeExtra !== null) {
			let baseProp = getProperty(t.typeExtra, name);
			if (isUnresolvedType(baseProp)) return baseProp;
			if (hasGenericParams(baseProp) && t.typeChildren.length > 0) {
				const paramNames: string[] = [];
				collectGenericParamNames(t.typeExtra, paramNames);
				let gi = 0;
				while (gi < paramNames.length) {
					if (gi < t.typeChildren.length) {
						baseProp = substituteType(baseProp, paramNames[gi], t.typeChildren[gi]);
					}
					gi = gi + 1;
				}
			}
			return baseProp;
		}
	}
	// Union field access: search all variants for the field.
	// For discriminated unions, the discriminant field maps to _tag.
	if (t.kind === TypeKind.Union && t.typeChildren !== null) {
		// Check discriminant field first (e.g. "kind" on a discriminated union)
		const tex = t.typeExtra;
		if (tex !== null && t.typeNames !== null && t.typeNames.length > 0) {
			if (t.typeNames[0] === name) {
				return tex; // discriminant field returns the enum type
			}
		}
		// Search variants for the field — return type if unambiguous across variants
		let foundType: Type | null = null;
		let ambiguous = false;
		for (const variant of t.typeChildren) {
			if (variant === null) continue;
			const ft = findFieldInVariant(variant, name);
			if (ft === null) continue;
			if (foundType === null) {
				foundType = ft;
			} else if (foundType.kind !== ft.kind) {
				ambiguous = true;
			}
		}
		if (foundType !== null) return foundType;
	}
	// Enum member access: Color.Red → returns the Enum type
	if (t.kind === TypeKind.Enum) {
		for (const member of t.typeNames) {
			if (member === name) return t;
		}
	}
	return inferredType();
}

// isPrimitiveKind — used by destructorLifting, analyzer/classify, and other DRC code
export function isPrimitiveKind(kind: TypeKind): boolean {
	return kind === TypeKind.Number
		|| kind === TypeKind.Boolean
		|| kind === TypeKind.Void
		|| kind === TypeKind.Null
		|| kind === TypeKind.Int8
		|| kind === TypeKind.Int16
		|| kind === TypeKind.Int32
		|| kind === TypeKind.Int64
		|| kind === TypeKind.Uint8
		|| kind === TypeKind.Uint16
		|| kind === TypeKind.Uint32
		|| kind === TypeKind.Uint64
		|| kind === TypeKind.Float32
		|| kind === TypeKind.Float64
		|| kind === TypeKind.Enum
		|| kind === TypeKind.EnumLiteral
		|| kind === TypeKind.Never
		|| kind === TypeKind.Unknown
		|| kind === TypeKind.Char
		|| kind === TypeKind.CString
		|| kind === TypeKind.StringLiteral
		|| kind === TypeKind.BooleanLiteral
		|| kind === TypeKind.Error
		|| kind === TypeKind.None
		|| kind === TypeKind.Inferred;
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
let _tnoTime: float64 = 0;
export function typeNameOfProfile(): float64[] { return [_tnoCount, _tnoTime]; }
export function typeNameOf(t: Type | null): string {
	_tnoCount = _tnoCount + 1;
	const _n0 = performance.now();
	const r = typeNameOfInner(t);
	_tnoTime = _tnoTime + (performance.now() - _n0);
	return r;
}
function typeNameOfInner(t: Type | null): string {
	if (t === null) return "";
	// Reference parity: ownership modifiers are transparent — unwrap before naming.
	// Bounded peel loop (not self-recursion): a malformed cyclic wrapper alias
	// whose typeReturn points back at itself would spin forever once tailCallLower
	// rewrites the self-tail-call into while(true). Mirrors the PEEL_MAX_DEPTH peelers.
	let cur: Type = t;
	let prefix = "";
	let _g = 0;
	while (cur !== null && _g < PEEL_MAX_DEPTH) {
		_g = _g + 1;
		if (cur.kind === TypeKind.Sink || cur.kind === TypeKind.Lent) {
			if (cur.typeReturn !== null) { cur = cur.typeReturn; continue; }
			return prefix;
		}
		if (cur.kind === TypeKind.Var) {
			if (cur.typeReturn !== null) { prefix = prefix + "out "; cur = cur.typeReturn; continue; }
			return prefix + "out";
		}
		if (cur.kind === TypeKind.Ref || cur.kind === TypeKind.Ptr) {
			if (cur.typeReturn !== null) { cur = cur.typeReturn; continue; }
			return prefix;
		}
		break;
	}
	const t2: Type = cur;
	if (t2.kind === TypeKind.Struct) return prefix + t2.typeName;
	if (t2.kind === TypeKind.GenericInstance) return prefix + t2.typeName;  // "Map" for receiver matching
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
		TypeKind.Span => "Span",
		TypeKind.Borrow => "Borrow",
		TypeKind.Tuple => "Tuple",
		TypeKind.CString => "cstring",
		TypeKind.StringLiteral => "\"" + t2.typeName + "\"",
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
			if (t2.typeChildren.length > 0) {
				let display = "";
				for (const child of t2.typeChildren) {
					if (display !== "") display = display + " | ";
					display = display + typeDisplayName(child);
				}
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
let _tdnTime: float64 = 0;
export function typeDisplayNameProfile(): float64[] { return [_tdnCount, _tdnTime]; }
export function typeDisplayName(t: Type | null): string {
	_tdnCount = _tdnCount + 1;
	const _d0 = performance.now();
	const r = typeDisplayNameInner(t);
	_tdnTime = _tdnTime + (performance.now() - _d0);
	return r;
}
function typeDisplayNameInner(t: Type | null): string {
	if (t === null) return "<null>";
	if (t.kind === TypeKind.Varargs && t.typeChildren.length > 0) {
		return "..." + typeDisplayName(t.typeChildren[0]);
	}
	const name = typeNameOf(t);
	// typeNameOf peels Ref and Ptr alike, which renders a pointer and its
	// pointee with the SAME text ("got QB, expected QB"). Ref stays hidden — an
	// interface IS Ref<Struct> here — but Ptr is a distinct spelling the reader
	// writes, so put it back. Bounded like typeNameOf: a self-referential
	// wrapper must not spin.
	if (t.kind === TypeKind.Ptr && name !== "") {
		let depth = 0;
		let cur: Type | null = t;
		while (cur !== null && cur.kind === TypeKind.Ptr && depth < PEEL_MAX_DEPTH) {
			depth = depth + 1;
			cur = cur.typeReturn;
		}
		let out = name;
		for (let i = 0; i < depth; i += 1) { out = "Ptr<" + out + ">"; }
		return out;
	}
	if (t.kind === TypeKind.Ref && t.typeReturn !== null && t.typeReturn.kind === TypeKind.Array) {
		const refElem = t.typeReturn.typeReturn;
		if (refElem !== null) return typeDisplayName(refElem) + "[]";
	}
	if (name !== "") return name;
	return match (t.kind) {
		TypeKind.Null => "null",
		TypeKind.Void => "void",
		TypeKind.Never => "never",
		TypeKind.Unknown => "unknown",
		TypeKind.Error => "<error>",
		TypeKind.None => "<none>",
		TypeKind.Inferred => "<inferring>",
		TypeKind.Function => "function",
		TypeKind.GenericParam => t.typeName !== "" ? t.typeName : "<T>",
		// Anonymous struct (object literal type) — typeName is "" so typeNameOf
		// returns empty. Diagnostics historically display these as "object".
		TypeKind.Struct => "object",
		_ => "<kind:" + t.kind.toString() + ">",
	};
}

// getBuiltinKind — read the @builtin("...") tag from a type's underlying class Symbol.
// Returns "" if the type has no builtin annotation. Walks transparent wrappers
// (Sink/Lent/Var/Distinct/Ref/Ptr) and GenericInstance → base class, mirroring
// typeNameOf's unwrap policy so `sink m: Map<K,V>` still registers as IndexableMap.
export function getBuiltinKind(t: Type | null): string {
	let cur: Type | null = t;
	let _g = 0;
	while (cur !== null && _g < PEEL_MAX_DEPTH) {
		_g = _g + 1;
		if (cur.sym !== null && cur.sym.builtinKind !== "") return cur.sym.builtinKind;
		if (cur.kind === TypeKind.GenericInstance && cur.typeExtra !== null) {
			cur = cur.typeExtra;
			continue;
		}
		// Transparent wrappers — unwrap to inner type before looking up the tag.
		if ((cur.kind === TypeKind.Ref || cur.kind === TypeKind.Ptr
				|| cur.kind === TypeKind.Sink || cur.kind === TypeKind.Lent
				|| cur.kind === TypeKind.Var || cur.kind === TypeKind.Distinct)
				&& cur.typeReturn !== null) {
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
	return getBuiltinKind(t) === "IndexableMap";
}

// alignTo — round up offset to alignment boundary
function alignTo(offset: number, align: number): number {
	if (align <= 1) return offset;
	const rem = offset % align;
	if (rem === 0) return offset;
	return offset + (align - rem);
}

// alignOfType — natural alignment for C ABI (target-aware)
export function alignOfType(t: Type): number {
	const ps = targetPtrSize;
	if (t.kind === TypeKind.Struct || t.kind === TypeKind.Tuple) {
		return alignOfStruct(t);
	}
	if (t.kind === TypeKind.Distinct && t.typeReturn !== null) {
		return alignOfType(t.typeReturn);
	}
	return match (t.kind) {
		TypeKind.Boolean | TypeKind.Char | TypeKind.Int8 | TypeKind.Uint8 => 1,
		TypeKind.Int16 | TypeKind.Uint16 => 2,
		TypeKind.Int32 | TypeKind.Uint32 | TypeKind.Float32 | TypeKind.Enum | TypeKind.EnumLiteral => 4,
		TypeKind.Number | TypeKind.Float64 => ps,
		TypeKind.Int64 | TypeKind.Uint64 => ps,
		TypeKind.CString | TypeKind.Ref | TypeKind.Ptr | TypeKind.Function => ps,
		TypeKind.String | TypeKind.Array | TypeKind.Span => ps,
		_ => 0,
	};
}

function alignOfStruct(t: Type): number {
	let maxAlign = 1;
	if (t.typeChildren !== null) {
		let i = 0;
		while (i < t.typeChildren.length) {
			const a = alignOfType(t.typeChildren[i]);
			if (a > maxAlign) maxAlign = a;
			i = i + 1;
		}
	}
	return maxAlign;
}

// sizeOfType — compile-time sizeof for primitive and compound types (target-aware C ABI)
// Mirrors standard reference implementation for size/alignment: fields are aligned, struct is padded to maxAlign.
export function sizeOfType(t: Type): number {
	const ps = targetPtrSize;
	if (t.kind === TypeKind.Struct || t.kind === TypeKind.Tuple) {
		return sizeOfStruct(t);
	}
	if (t.kind === TypeKind.Distinct && t.typeReturn !== null) {
		return sizeOfType(t.typeReturn);
	}
	return match (t.kind) {
		TypeKind.Boolean | TypeKind.Char | TypeKind.Int8 | TypeKind.Uint8 => 1,
		TypeKind.Int16 | TypeKind.Uint16 => 2,
		TypeKind.Int32 | TypeKind.Uint32 | TypeKind.Float32 | TypeKind.Enum | TypeKind.EnumLiteral => 4,
		TypeKind.Number | TypeKind.Int64 | TypeKind.Uint64 | TypeKind.Float64 => ps,
		TypeKind.String => ps * 2,
		TypeKind.CString | TypeKind.Ref | TypeKind.Ptr => ps,
		TypeKind.Function => ps * 2,
		TypeKind.Array | TypeKind.Span => ps * 2,
		_ => 0,
	};
}

function sizeOfStruct(t: Type): number {
	let offset = 0;
	let maxAlign = 1;
	if (t.typeChildren !== null) {
		let i = 0;
		while (i < t.typeChildren.length) {
			const fieldSize = sizeOfType(t.typeChildren[i]);
			const fieldAlign = alignOfType(t.typeChildren[i]);
			if (fieldAlign > maxAlign) maxAlign = fieldAlign;
			offset = alignTo(offset, fieldAlign);
			offset = offset + fieldSize;
			i = i + 1;
		}
	}
	if (offset === 0) return 0;
	return alignTo(offset, maxAlign);
}

// ===== Tests =====
test "primitive kinds" {
	assert numberType().kind === TypeKind.Number;
	assert stringType().kind === TypeKind.String;
	assert booleanType().kind === TypeKind.Boolean;
	assert voidType().kind === TypeKind.Void;
	assert nullType().kind === TypeKind.Null;
	assert neverType().kind === TypeKind.Never;
	assert errorType().kind === TypeKind.Error;
}

test "createArray" {
	const arrType = createArray(numberType());
	assert arrType.kind === TypeKind.Array;
	assert arrType.typeReturn !== null && arrType.typeReturn.kind === TypeKind.Number;
}

test "createSizedArray" {
	const arrType = createSizedArray(numberType(), 4);
	assert arrType.kind === TypeKind.SizedArray;
	assert arrType.typeReturn !== null && arrType.typeReturn.kind === TypeKind.Number;
	assert arrType.typeFlags === 4;
}

test "createSpan" {
	const spanType = createSpan(numberType());
	assert spanType.kind === TypeKind.Span;
	assert spanType.typeReturn !== null && spanType.typeReturn.kind === TypeKind.Number;
}

test "createFunction" {
	const fnType = createFunction([numberType(), stringType()], ["a", "b"], booleanType());
	assert fnType.kind === TypeKind.Function;
	assert fnType.typeChildren.length === 2;
	assert fnType.typeNames[0] === "a";
	assert fnType.typeReturn !== null && fnType.typeReturn.kind === TypeKind.Boolean;
}

test "createStruct" {
	const obj = createStruct("Point", ["x"], [numberType()], false);
	assert obj.kind === TypeKind.Struct;
	assert obj.typeName === "Point";
	assert obj.typeNames.length === 1;
	assert obj.typeChildren.length === 1;
	assert obj.typeFlags === 0;
}

test "createEnum" {
	const e = createEnum("Color", ["Red", "Green", "Blue"], null as unknown as number[]);
	assert e.kind === TypeKind.Enum;
	assert e.typeName === "Color";
	assert e.typeNames.length === 3;
}

test "createResult" {
	const r = createResult(numberType(), stringType());
	assert isResult(r);
	const ok = getResultOkType(r);
	assert ok !== null && ok.kind === TypeKind.Number;
	const err = getResultErrType(r);
	assert err !== null && err.kind === TypeKind.String;
}

test "createTypeRef" {
	const t = createTypeRef("MyType");
	assert t.kind === TypeKind.TypeReference;
	assert t.typeName === "MyType";
}

test "createRef and Ptr" {
	const r = createRef(numberType());
	assert r.kind === TypeKind.Ref;
	assert r.typeReturn !== null && r.typeReturn.kind === TypeKind.Number;
	const p = createPtr(stringType());
	assert p.kind === TypeKind.Ptr;
	assert p.typeReturn !== null && p.typeReturn.kind === TypeKind.String;
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
	assert getReturnType(fn).kind === TypeKind.Boolean;
	assert getReturnType(numberType()).kind === TypeKind.Inferred;
}

test "getElementType" {
	const arr = createArray(stringType());
	assert getElementType(arr).kind === TypeKind.String;
	assert getElementType(numberType()).kind === TypeKind.Inferred;
}

test "getProperty" {
	const obj = createStruct("Point", ["x", "y"], [numberType(), stringType()], false);
	assert getProperty(obj, "x").kind === TypeKind.Number;
	assert getProperty(obj, "y").kind === TypeKind.String;
	assert getProperty(obj, "z").kind === TypeKind.Inferred;
	assert getProperty(numberType(), "x").kind === TypeKind.Inferred;
}

test "substitute generic param" {
	const gp = createGenericParam("T");
	const result = substituteType(gp, "T", numberType());
	assert result.kind === TypeKind.Number;
}

test "substitute non-matching" {
	const gp = createGenericParam("T");
	const result = substituteType(gp, "U", numberType());
	assert result.kind === TypeKind.GenericParam;
}

test "substitute in array" {
	const arr = createArray(createGenericParam("T"));
	const result = substituteType(arr, "T", stringType());
	assert result.kind === TypeKind.Array;
	assert result.typeReturn !== null && result.typeReturn.kind === TypeKind.String;
}

test "substitute in function" {
	const fn = createFunction([createGenericParam("T")], ["a"], createGenericParam("T"));
	const result = substituteType(fn, "T", numberType());
	assert result.kind === TypeKind.Function;
	assert result.typeChildren[0].kind === TypeKind.Number;
	assert result.typeReturn !== null && result.typeReturn.kind === TypeKind.Number;
}

test "substitute in Result" {
	const r = createResult(createGenericParam("T"), createGenericParam("E"));
	const step1 = substituteType(r, "T", numberType());
	const step2 = substituteType(step1, "E", stringType());
	assert isResult(step2);
	const ok2 = getResultOkType(step2);
	assert ok2 !== null && ok2.kind === TypeKind.Number;
	const err2 = getResultErrType(step2);
	assert err2 !== null && err2.kind === TypeKind.String;
}

test "instantiateGeneric multi-param" {
	const r = createResult(createGenericParam("T"), createGenericParam("E"));
	const result = instantiateGeneric(r, ["T", "E"], [numberType(), stringType()]);
	assert isResult(result);
	const ok = getResultOkType(result);
	assert ok !== null && ok.kind === TypeKind.Number;
	const err = getResultErrType(result);
	assert err !== null && err.kind === TypeKind.String;
}

// substituteType keeps typeExtra un-substituted (would cost ~20× compile
// time on self-host), so callers that need the substituted body
// must invoke instantiateGenericBody themselves. Built-in Result/Promise/Iterator
// have no parser-side addGenericDecl entry — they get their param names from
// the hardcoded fallback in `parser/context.ms:getGenericDecl`.
test "instantiateGenericBody populates substituted Result body" {
	const r = createResult(createGenericParam("T"), stringType());
	// Bare Result<T, string> — typeReturn is null (no eager body).
	assert r.typeReturn === null;
	assert r.typeExtra !== null;
	const sub = substituteType(r, "T", numberType());
	assert sub.typeChildren[0].kind === TypeKind.Number;
	// substituteType is intentionally cheap — typeReturn stays null.
	assert sub.typeReturn === null;
	// Caller-side populate (mirrors the fix in inferGenericReturn /
	// inferGenericReturnWithExplicit). After this, peelToStructOrUnion sees
	// the substituted body via typeReturn.
	instantiateGenericBody(sub, "T,E");
	assert sub.typeReturn !== null;
	const body = peelToStructOrUnion(sub);
	assert body !== null && body.kind === TypeKind.Union;
	const okVariant = body.typeChildren[0];
	const valueField = findFieldInVariant(okVariant, "value");
	assert valueField !== null && valueField.kind === TypeKind.Number;
}

test "primitive unchanged" {
	const result = substituteType(numberType(), "T", stringType());
	assert result.kind === TypeKind.Number;
}

test "unify direct generic param" {
	const b = createUnifyBindings();
	unifyType(createGenericParam("T"), numberType(), b);
	assert b.names.length === 1;
	assert b.names[0] === "T";
	assert b.types[0].kind === TypeKind.Number;
}

test "unify Array<T> vs Array<string>" {
	const b = createUnifyBindings();
	unifyType(createArray(createGenericParam("T")), createArray(stringType()), b);
	assert b.names.length === 1;
	assert b.names[0] === "T";
	assert b.types[0].kind === TypeKind.String;
}

test "unify Result<T, E> vs Result<number, string>" {
	const b = createUnifyBindings();
	const formal = createResult(createGenericParam("T"), createGenericParam("E"));
	const concrete = createResult(numberType(), stringType());
	unifyType(formal, concrete, b);
	assert b.names.length === 2;
	assert b.names[0] === "T";
	assert b.types[0].kind === TypeKind.Number;
	assert b.names[1] === "E";
	assert b.types[1].kind === TypeKind.String;
}

test "unify mismatched kinds" {
	const b = createUnifyBindings();
	unifyType(createArray(createGenericParam("T")), numberType(), b);
	assert b.names.length === 0;
}

test "unify concrete no bindings" {
	const b = createUnifyBindings();
	unifyType(numberType(), numberType(), b);
	assert b.names.length === 0;
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
	assert getMinArity(fn1) === 2;
}

test "setMinArity stores correctly" {
	const fn2 = createFunction([numberType(), stringType()], ["a", "b"], voidType());
	setMinArity(fn2, 1);
	assert getMinArity(fn2) === 1;
}

test "setMinArity zero" {
	const fn3 = createFunction([numberType()], ["a"], voidType());
	setMinArity(fn3, 0);
	assert getMinArity(fn3) === 0;
}

test "preserves low bits" {
	const fn4 = createFunction([numberType()], ["a"], voidType());
	fn4.typeFlags = TypeFlag.IsStruct as int32;
	setMinArity(fn4, 1);
	assert getMinArity(fn4) === 1;
	assert (fn4.typeFlags & TypeFlag.IsStruct) !== 0;
}

test "createTuple" {
	const tup = createTuple([numberType(), stringType()]);
	assert tup.kind === TypeKind.Tuple;
	assert tup.typeChildren.length === 2;
	assert tup.typeChildren[0].kind === TypeKind.Number;
	assert tup.typeChildren[1].kind === TypeKind.String;
}

test "typeNameOf Tuple" {
	const tup = createTuple([numberType()]);
	assert typeNameOf(tup) === "Tuple";
}

test "substituteType Tuple" {
	const tup = createTuple([createGenericParam("T"), numberType()]);
	const result = substituteType(tup, "T", stringType());
	assert result.kind === TypeKind.Tuple;
	assert result.typeChildren[0].kind === TypeKind.String;
	assert result.typeChildren[1].kind === TypeKind.Number;
}

test "sizeOfType primitives 64-bit" {
	setTargetSizes(8, 8);
	assert sizeOfType(createPrimitive(TypeKind.Boolean)) === 1;
	assert sizeOfType(createPrimitive(TypeKind.Char)) === 1;
	assert sizeOfType(createPrimitive(TypeKind.Int32)) === 4;
	assert sizeOfType(createPrimitive(TypeKind.Uint32)) === 4;
	assert sizeOfType(createPrimitive(TypeKind.Float32)) === 4;
	assert sizeOfType(numberType()) === 8;
	assert sizeOfType(createPrimitive(TypeKind.Int64)) === 8;
	assert sizeOfType(createPrimitive(TypeKind.Float64)) === 8;
	assert sizeOfType(stringType()) === 16;
	assert sizeOfType(createArray(numberType())) === 16;
	assert sizeOfType(createPrimitive(TypeKind.Enum)) === 4;
}

test "sizeOfType primitives 32-bit" {
	setTargetSizes(4, 4);
	assert sizeOfType(numberType()) === 4;
	assert sizeOfType(stringType()) === 8;
	assert sizeOfType(createArray(numberType())) === 8;
	assert sizeOfType(createFunction([], [], numberType())) === 8;
	assert sizeOfType(createPrimitive(TypeKind.Ref)) === 4;
	assert sizeOfType(createPrimitive(TypeKind.Int32)) === 4;
	assert sizeOfType(createPrimitive(TypeKind.Int64)) === 4;
	setTargetSizes(8, 8);
}

test "sizeOfType object no padding" {
	const obj = createStruct("Pair", ["x", "y"], [createPrimitive(TypeKind.Int32), createPrimitive(TypeKind.Int32)], true);
	assert sizeOfType(obj) === 8;
}

test "sizeOfType object with padding" {
	// { char (1 byte) + padding(3) + int32 (4 bytes) } = 8
	const obj = createStruct("Mixed", ["a", "b"], [createPrimitive(TypeKind.Char), createPrimitive(TypeKind.Int32)], true);
	assert sizeOfType(obj) === 8;
}

test "sizeOfType object tail padding" {
	// { int64 (8 bytes) + char (1 byte) + padding(7) } = 16 (aligned to maxAlign=8)
	const obj = createStruct("Tail", ["x", "y"], [createPrimitive(TypeKind.Int64), createPrimitive(TypeKind.Char)], true);
	assert sizeOfType(obj) === 16;
}

test "sizeOfType function closure" {
	assert sizeOfType(createFunction([], [], numberType())) === 16;
}

test "alignOfType" {
	assert alignOfType(createPrimitive(TypeKind.Char)) === 1;
	assert alignOfType(createPrimitive(TypeKind.Int32)) === 4;
	assert alignOfType(numberType()) === 8;
}

test "alignOfType 32-bit" {
	setTargetSizes(4, 4);
	assert alignOfType(numberType()) === 4;
	assert alignOfType(createPrimitive(TypeKind.Ref)) === 4;
	assert alignOfType(createPrimitive(TypeKind.Int32)) === 4;
	setTargetSizes(8, 8);
}

// ===== Maybe<T> + Nullable Pointer Tests =====

test "createMaybeType for interface creates wrapper" {
	const inner = createStruct("Token", ["kind"], [numberType()], true);
	const maybe = createMaybeType(inner);
	assert maybe.kind === TypeKind.Struct;
	assert maybe.typeName === "Maybe_Token";
	assert maybe.typeNames.length === 2;
	assert maybe.typeNames[0] === "value";
	assert maybe.typeNames[1] === "present";
	assert isMaybeType(maybe);
	assert unwrapMaybeType(maybe).typeName === "Token";
}

test "createMaybeType for Ref returns bare pointer" {
	const refType = createRef(createStruct("Foo", [], [], true));
	const result = createMaybeType(refType);
	// Should return the Ref type unchanged — no wrapper
	assert result.kind === TypeKind.Ref;
	assert result === refType;
	assert !isMaybeType(result);
}

test "createMaybeType for Ptr returns bare pointer" {
	const ptrType = createPtr(createStruct("Bar", [], [], true));
	const result = createMaybeType(ptrType);
	// Should return the Ptr type unchanged — no wrapper
	assert result.kind === TypeKind.Ptr;
	assert result === ptrType;
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
	assert m1 === m2;
}
